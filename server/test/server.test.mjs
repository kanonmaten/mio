import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { createMioServer, loadConfig, validatePayload } from '../src/server.mjs';
import { resolveTaskProfile } from '../src/task-profiles.mjs';

const token = 'fixture_gateway_token_01234567890123456789';
const defaults = { apiKey: 'fixture-upstream-credential', gatewayToken: token, model: 'gpt-6-luna',
  requestsPerMinute: 30, requestsPerDay: 100, upstreamTimeoutMs: 1000, bodyTimeoutMs: 1000 };
const payload = { question: 'Vad betyder procent?', context: [{ label: 'Anteckning', text: 'Vi övar procent.' }] };
const completion = (text = 'Procent betyder hundradelar.') => new Response(JSON.stringify({
  status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: JSON.stringify({ answer: text }) }] }]
}), { headers: { 'Content-Type': 'application/json' } });

async function fixture(t, options = {}) {
  const calls = [];
  const server = createMioServer({ config: { ...defaults, ...options.config }, now: options.now,
    fetchImpl: options.fetchImpl ?? (async (url, init) => { calls.push({ url, init }); return completion(); }) });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const ask = (body = payload, headers = {}) => fetch(`${base}/v1/ask`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body)
  });
  return { ask, base, calls, server };
}

test('transport settings stay bounded while invalid generation configuration remains discoverable', () => {
  assert.throws(() => loadConfig({}));
  assert.equal(resolveTaskProfile(loadConfig({ OPENAI_API_KEY: token, MIO_GATEWAY_TOKEN: token, MIO_OPENAI_MODEL: 'gpt-6-luna' }), 'ask').configured, false);
  assert.throws(() => loadConfig({ OPENAI_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_OPENAI_MODEL: 'example', MIO_REQUESTS_PER_DAY: '999999' }));
  assert.equal(loadConfig({ OPENAI_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_OPENAI_MODEL: 'example' }).requestsPerDay, 100);
});

test('payload preserves exactly approved text and refuses unknown fields', () => {
  assert.equal(validatePayload(payload), payload);
  for (const invalid of [{ ...payload, history: [] }, { question: ' ', context: [] },
    { question: 'å'.repeat(1001), context: [] }, { question: 'Hej', context: Array(7).fill(payload.context[0]) },
    { question: 'Hej', context: [{ label: 'a', text: '' }] },
    { question: 'Hej', context: [{ label: 'a', text: 'x'.repeat(4001) }] },
    { question: 'Hej', context: Array(3).fill({ label: 'a', text: 'x'.repeat(3500) }) }]) {
    assert.throws(() => validatePayload(invalid));
  }
});

test('health and unknown routes never contact OpenAI', async t => {
  const f = await fixture(t);
  assert.deepEqual(await (await fetch(`${f.base}/health`)).json(), { status: 'ok' });
  assert.equal((await fetch(`${f.base}/unknown`)).status, 404);
  assert.equal(f.calls.length, 0);
});

test('unauthorized requests cannot spend API credits or leak credentials', async t => {
  const f = await fixture(t);
  for (const auth of ['', 'Bearer wrong', `Bearer ${token}extra`]) {
    const r = await f.ask(payload, { Authorization: auth });
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: 'unauthorized' });
  }
  assert.equal(f.calls.length, 0);
});

test('success uses fixed upstream, no storage, no tools and only approved context', async t => {
  const f = await fixture(t);
  const response = await f.ask();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { answer: 'Procent betyder hundradelar.' });
  assert.equal(f.calls.length, 1);
  const { url, init } = f.calls[0];
  assert.equal(url, 'https://api.openai.com/v1/responses');
  assert.equal(init.redirect, 'manual');
  assert.equal(init.headers.Authorization, `Bearer ${defaults.apiKey}`);
  assert.ok(!JSON.stringify(init).includes(token));
  const request = JSON.parse(init.body);
  assert.equal(request.store, false);
  assert.equal(request.max_output_tokens, 1000);
  assert.deepEqual(request.tools, []);
  assert.deepEqual(JSON.parse(request.input[0].content[0].text), payload);
  assert.ok(!('previous_response_id' in request));
});

test('invalid JSON, content types and too large bodies are rejected locally', async t => {
  const f = await fixture(t);
  assert.equal((await f.ask('{broken')).status, 400);
  assert.equal((await f.ask(payload, { 'Content-Type': 'text/plain' })).status, 415);
  assert.equal((await f.ask(payload, { 'Content-Encoding': 'gzip' })).status, 415);
  assert.equal((await f.ask('x'.repeat(20001))).status, 413);
  assert.equal(f.calls.length, 0);
});

test('upstream errors expose only fixed error codes and never retry', async t => {
  let calls = 0;
  const f = await fixture(t, { fetchImpl: async () => { calls++; return new Response('private upstream details', { status: 500 }); } });
  const r = await f.ask();
  assert.equal(r.status, 502);
  assert.deepEqual(await r.json(), { error: 'provider_infrastructure' });
  assert.equal(calls, 1);
});

test('incomplete answers are not shown as complete', async t => {
  const f = await fixture(t, { fetchImpl: async () => new Response(JSON.stringify({ status: 'incomplete', output: [] }), { headers: { 'Content-Type': 'application/json' } }) });
  const r = await f.ask();
  assert.equal(r.status, 502);
  assert.deepEqual(await r.json(), { error: 'provider_invalid_response' });
});

test('upstream response size is bounded even without content length', async t => {
  const f = await fixture(t, { fetchImpl: async () => new Response('x'.repeat(65537), { headers: { 'Content-Type': 'application/json' } }) });
  const r = await f.ask();
  assert.equal(r.status, 502);
  assert.deepEqual(await r.json(), { error: 'upstream_response_too_large' });
});

test('oversized answer is rejected independently of JSON size', async t => {
  const f = await fixture(t, { fetchImpl: async () => completion('a'.repeat(16001)) });
  assert.equal((await f.ask()).status, 502);
});

test('per-minute limit resets on next bucket without retaining user data', async t => {
  let time = 0;
  const f = await fixture(t, { config: { requestsPerMinute: 1 }, now: () => time });
  assert.equal((await f.ask()).status, 200);
  const limited = await f.ask();
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('retry-after'), '60');
  time = 60001;
  assert.equal((await f.ask()).status, 200);
  assert.equal(f.calls.length, 2);
});

test('daily limit remains after minute bucket changes', async t => {
  let time = 0;
  const f = await fixture(t, { config: { requestsPerDay: 1 }, now: () => time });
  assert.equal((await f.ask()).status, 200);
  time = 60001;
  assert.equal((await f.ask()).status, 429);
  time = 86400001;
  assert.equal((await f.ask()).status, 200);
});

test('timeout cancels upstream and returns a sanitized error', async t => {
  let aborted = false;
  const f = await fixture(t, { config: { upstreamTimeoutMs: 20 }, fetchImpl: async (_, init) =>
    new Promise((_, reject) => init.signal.addEventListener('abort', () => { aborted = true; reject(new Error('private transport error')); }, { once: true })) });
  const r = await f.ask();
  assert.equal(r.status, 504);
  assert.equal(aborted, true);
  assert.deepEqual(await r.json(), { error: 'upstream_timeout' });
});

test('invalid upstream JSON and redirects never become answers', async t => {
  const f = await fixture(t, { fetchImpl: async () => new Response('', { status: 302, headers: { Location: 'https://elsewhere.invalid' } }) });
  const r = await f.ask();
  assert.equal(r.status, 502);
  assert.deepEqual(await r.json(), { error: 'provider_infrastructure' });
});

test('the shared daily cap cannot be raised through environment or direct configuration', () => {
  const env = { OPENAI_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'gpt-6-luna' };
  assert.throws(() => loadConfig({ ...env, MIO_REQUESTS_PER_DAY: '101' }));
  assert.throws(() => createMioServer({ config: { ...defaults, requestsPerDay: 101 } }));
});
