import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { createMioServer, loadConfig, validatePayload } from '../src/server.mjs';
import { resolveTaskProfile } from '../src/task-profiles.mjs';
import { createFileCounterStore, createMemoryCounterStore, emptyCounters } from '../src/state-store.mjs';
import { mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const token = 'fixture_gateway_token_01234567890123456789';
const defaults = { apiKey: 'fixture-upstream-credential', gatewayToken: token, model: 'qwen/qwen3.8-27b',
  requestsPerMinute: 30, requestsPerDay: 100, upstreamTimeoutMs: 1000, bodyTimeoutMs: 1000 };
const payload = { question: 'Vad betyder procent?', context: [{ label: 'Anteckning', text: 'Vi övar procent.' }] };
const completion = (text = 'Procent betyder hundradelar.') => new Response(JSON.stringify({
  choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify({ answer: text }) } }]
}), { headers: { 'Content-Type': 'application/json' } });

async function fixture(t, options = {}) {
  const calls = [];
  const server = createMioServer({ config: { ...defaults, ...options.config }, now: options.now, counterStore: options.counterStore,
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
  assert.equal(resolveTaskProfile(loadConfig({ GROQ_API_KEY: token, MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'example' }), 'ask').configured, false);
  assert.throws(() => loadConfig({ GROQ_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'example', MIO_REQUESTS_PER_DAY: '1000001' }));
  assert.equal(loadConfig({ GROQ_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'example' }).requestsPerDay, null);
  // Groq free tier: three requests per minute is the default, the token cap is optional.
  const defaultsFromEnv = loadConfig({ GROQ_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'qwen/qwen3.8-27b' });
  assert.equal(defaultsFromEnv.provider, 'groq');
  assert.equal(defaultsFromEnv.requestsPerMinute, 3);
  assert.equal(defaultsFromEnv.tokensPerDay, null);
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
  assert.equal(url, 'https://api.groq.com/openai/v1/chat/completions');
  assert.equal(init.redirect, 'manual');
  assert.equal(init.headers.Authorization, `Bearer ${defaults.apiKey}`);
  assert.ok(!JSON.stringify(init).includes(token));
  const request = JSON.parse(init.body);
  assert.equal(request.max_tokens, 1000);
  assert.equal(request.stream, false);
  assert.equal('tools' in request, false);
  assert.equal(request.messages.length, 2);
  assert.deepEqual(JSON.parse(request.messages[1].content), payload);
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

test('the daily cap is optional, but a configured cap must be a bounded positive integer', () => {
  const env = { GROQ_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'qwen/qwen3.8-27b' };
  for (const value of [undefined, '', '0']) assert.equal(loadConfig({ ...env, MIO_REQUESTS_PER_DAY: value }).requestsPerDay, null);
  assert.equal(loadConfig({ ...env, MIO_REQUESTS_PER_DAY: '2000' }).requestsPerDay, 2000);
  for (const value of ['-1', '1.5', 'many', '1000001']) assert.throws(() => loadConfig({ ...env, MIO_REQUESTS_PER_DAY: value }));
  assert.throws(() => loadConfig({ ...env, MIO_REQUESTS_PER_MINUTE: '61' }));
  for (const requestsPerDay of [0, 1.5, 1_000_001]) assert.throws(() => createMioServer({ config: { ...defaults, requestsPerDay } }));
  assert.doesNotThrow(() => createMioServer({ config: { ...defaults, requestsPerDay: null } }).close());
});

const usageCompletion = totalTokens => Response.json({ usage: { prompt_tokens: totalTokens - 10, completion_tokens: 10, total_tokens: totalTokens },
  choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify({ answer: 'Svar.' }) } }] });

test('the daily token cap counts reported usage and blocks before a provider call until the next UTC day', async t => {
  let time = Date.parse('2026-10-11T12:00:00Z');
  const f = await fixture(t, { config: { tokensPerDay: 1000, requestsPerDay: null }, now: () => time,
    fetchImpl: async (url, init) => { f.calls.push({ url, init }); return usageCompletion(600); } });
  assert.equal((await f.ask()).status, 200);
  assert.equal((await f.ask()).status, 200);
  time += 60_001;
  const limited = await f.ask();
  assert.equal(limited.status, 429);
  assert.deepEqual(await limited.json(), { error: 'local_token_limit' });
  assert.equal(Number(limited.headers.get('retry-after')), 12 * 3600 - 60);
  assert.equal(f.calls.length, 2);
  time = Date.parse('2026-10-12T00:00:01Z');
  assert.equal((await f.ask()).status, 200);
  assert.equal(f.calls.length, 3);
});

test('status reports the token quota with its unit and never a request count as tokens', async t => {
  let time = Date.parse('2026-10-11T12:00:00Z');
  const f = await fixture(t, { config: { tokensPerDay: 1000 }, now: () => time,
    fetchImpl: async () => usageCompletion(250) });
  assert.equal((await f.ask()).status, 200);
  const status = await (await fetch(`${f.base}/v2/status`, { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.deepEqual(status.quota, { limit: 1000, remaining: 750, resetAt: '2026-10-12T00:00:00.000Z', unit: 'tokens' });
});

test('counters survive a gateway restart so a restart cannot reset the daily allowance', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'mio-counters-'));
  const path = join(directory, 'counters.json');
  const time = Date.parse('2026-10-11T12:00:00Z');
  const first = await fixture(t, { config: { tokensPerDay: 1000 }, now: () => time,
    counterStore: createFileCounterStore(path), fetchImpl: async () => usageCompletion(900) });
  assert.equal((await first.ask()).status, 200);
  const saved = JSON.parse(readFileSync(path, 'utf8'));
  assert.deepEqual(Object.keys(saved).sort(), ['day', 'dayCount', 'dayTokens', 'minute', 'minuteCount']);
  assert.equal(saved.dayTokens, 900);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.ok(!readFileSync(path, 'utf8').includes('procent'));
  let restartedCalls = 0;
  const second = await fixture(t, { config: { tokensPerDay: 1000 }, now: () => time + 120_000,
    counterStore: createFileCounterStore(path), fetchImpl: async () => { restartedCalls++; return usageCompletion(900); } });
  assert.equal((await second.ask()).status, 200);
  assert.equal((await second.ask()).status, 429);
  assert.equal(restartedCalls, 1);
});

test('corrupt or foreign counter files start empty instead of crashing or trusting them', () => {
  const directory = mkdtempSync(join(tmpdir(), 'mio-counters-'));
  const path = join(directory, 'counters.json');
  for (const content of ['{broken', '[]', '{"day":1}', JSON.stringify({ ...emptyCounters(), dayTokens: -5 }),
    JSON.stringify({ ...emptyCounters(), dayTokens: 1.5 })]) {
    writeFileSync(path, content);
    assert.deepEqual(createFileCounterStore(path).load(), emptyCounters());
  }
  assert.deepEqual(createFileCounterStore(join(directory, 'missing.json')).load(), emptyCounters());
});

test('a failing counter store blocks provider traffic instead of spending unrecorded quota', async t => {
  const store = { ...createMemoryCounterStore(), save() { throw new Error('disk full'); } };
  const f = await fixture(t, { counterStore: store });
  const response = await f.ask();
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'budget_store_failed' });
  assert.equal(f.calls.length, 0);
});

test('the token cap is bounded and optional', () => {
  const env = { GROQ_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token, MIO_AI_MODEL: 'qwen/qwen3.8-27b' };
  for (const value of [undefined, '', '0']) assert.equal(loadConfig({ ...env, MIO_TOKENS_PER_DAY: value }).tokensPerDay, null);
  assert.equal(loadConfig({ ...env, MIO_TOKENS_PER_DAY: '190000' }).tokensPerDay, 190000);
  for (const value of ['-1', '1.5', 'many', '1000001']) assert.throws(() => loadConfig({ ...env, MIO_TOKENS_PER_DAY: value }));
});
