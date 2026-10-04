import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { createMioServer, loadConfig } from '../src/server.mjs';

const token = 'fixture_gateway_token_01234567890123456789';
const env = { MIO_AI_PROVIDER: 'openai', MIO_AI_MODEL: 'gpt-6-luna', OPENAI_API_KEY: 'fixture-openai',
  GROQ_API_KEY: 'fixture-groq', MIO_GATEWAY_TOKEN: token, MIO_REQUESTS_PER_MINUTE: '60' };
const approved = { question: 'Syntetiskt godkänt prov', context: [] };
const auth = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
function completion(request) {
  const text = JSON.stringify({ answer: 'Syntetiskt svar' });
  return Response.json(request.response_format
    ? { model: request.model, choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: text } }],
      usage: { prompt_tokens: 7, completion_tokens: 3, completion_tokens_details: { reasoning_tokens: 0 } } }
    : { model: request.model, status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }],
      usage: { input_tokens: 7, output_tokens: 3, output_tokens_details: { reasoning_tokens: 0 } } },
    { headers: { 'x-request-id': 'fixture-upstream-request' } });
}
async function fixture(t, patch = {}, options = {}) {
  const calls = []; let reservations = 0;
  const config = loadConfig({ ...env, ...patch });
  const server = createMioServer({ config, readQuota: () => ({ limit: 100, remaining: 100, resetAt: "2026-10-03T00:00:00.000Z" }), reserveBudget: () => { reservations++; return true; },
    fetchImpl: async (url, request) => { const body = JSON.parse(request.body); calls.push({ url, request, body }); return completion(body); }, ...options });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, calls, reservations: () => reservations, ask: (headers = {}) => fetch(`${base}/v1/ask`,
    { method: 'POST', headers: { ...auth, ...headers }, body: JSON.stringify(approved) }) };
}

test('ask uses its selected provider secret and exact approved input without fallback', async t => {
  const f = await fixture(t, { MIO_AI_TASK_PROFILES: JSON.stringify({ ask: { provider: 'groq', model: 'qwen/qwen3.8-27b' } }) });
  const response = await f.ask();
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { answer: 'Syntetiskt svar' });
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].url, 'https://api.groq.com/openai/v1/chat/completions');
  assert.equal(f.calls[0].request.headers.Authorization, 'Bearer fixture-groq');
  assert.equal(f.calls[0].body.model, 'qwen/qwen3.8-27b');
  assert.deepEqual(JSON.parse(f.calls[0].body.messages.at(-1).content), approved);
  assert.equal(response.headers.get('x-mio-provider'), 'groq');
  assert.equal(response.headers.get('x-mio-returned-model'), 'qwen/qwen3.8-27b');
  assert.equal(response.headers.get('x-mio-usage-input-tokens'), '7');
  assert.equal(response.headers.get('x-mio-upstream-request-id'), 'fixture-upstream-request');
});

test('invalid selected task is rejected before quota and provider traffic', async t => {
  const f = await fixture(t, { MIO_AI_TASK_PROFILES: JSON.stringify({ ask: { provider: 'openai', model: 'gpt-4.1-2099-99-99' } }) });
  const response = await f.ask();
  assert.equal(response.status, 422);
  assert.equal((await response.json()).error, 'task_configuration_invalid');
  assert.equal(f.reservations(), 0); assert.equal(f.calls.length, 0);
});

test('protected model-free status and stale revision never reserve quota or start inference', async t => {
  const f = await fixture(t);
  const rejected = await fetch(`${f.base}/v2/status`);
  assert.equal(rejected.status, 401);
  const response = await fetch(`${f.base}/v2/status`, { headers: auth });
  assert.equal(response.status, 200);
  const status = await response.json();
  assert.match(status.configurationRevision, /^[a-f0-9]{64}$/u);
  assert.equal(status.quota.limit, 100); assert.equal(status.quota.remaining, 100);
  assert.equal(status.tasks.ask.configured, true);
  const changed = await f.ask({ 'X-Mio-Configuration-Revision': '0'.repeat(64) });
  assert.equal(changed.status, 409); assert.equal((await changed.json()).error, 'configuration_changed');
  assert.equal(f.reservations(), 0); assert.equal(f.calls.length, 0);
});

test('budget store failure is distinct and cannot trigger provider traffic', async t => {
  const f = await fixture(t, {}, { reserveBudget: () => { throw new Error('private arbitrary store failure'); } });
  const response = await f.ask();
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'budget_store_failed' });
  assert.equal(f.calls.length, 0);
});

for (const [status, category] of [[401, 'provider_authentication'], [402, 'provider_account'],
  [404, 'provider_model_unavailable'], [400, 'provider_parameters'], [429, 'provider_quota'], [500, 'provider_infrastructure']]) {
  test(`provider HTTP ${status} returns bounded category ${category}`, async t => {
    const f = await fixture(t, {}, { fetchImpl: async () => Response.json({ error: { message: 'private arbitrary body' } }, { status }) });
    const response = await f.ask();
    assert.equal((await response.json()).error, category);
  });
}

test('local daily capacity is observed without changing reservations or counters', async t => {
  const f = await fixture(t, {}, { reserveBudget: undefined, readQuota: undefined });
  const status = () => fetch(`${f.base}/v2/status`, { headers: auth }).then(response => response.json());
  assert.equal((await status()).quota.remaining, 100);
  assert.equal((await f.ask()).status, 200);
  assert.equal((await status()).quota.remaining, 99);
  assert.equal((await status()).quota.remaining, 99);
  assert.equal(f.calls.length, 1);
});

test('request snapshots use current task configuration and credential rotations independently', async t => {
  let current = loadConfig(env);
  const f = await fixture(t, {}, { configurationForRequest: () => current });
  const discover = () => fetch(`${f.base}/v2/status`, { headers: auth }).then(response => response.json());
  const first = await discover();
  const secondKey = 'fixture-rotated-openai';
  current = loadConfig({ ...env, OPENAI_API_KEY: secondKey });
  assert.equal((await discover()).configurationRevision, first.configurationRevision, 'Secrets must not enter revision fingerprints');
  assert.equal((await f.ask({ 'X-Mio-Configuration-Revision': first.configurationRevision })).status, 200);
  assert.equal(f.calls.at(-1).request.headers.Authorization, `Bearer ${secondKey}`);
  current = loadConfig({ ...env, MIO_AI_TASK_PROFILES: JSON.stringify({ ask: { provider: 'groq', model: 'qwen/qwen3.8-27b' } }) });
  const changed = await discover();
  assert.notEqual(changed.configurationRevision, first.configurationRevision);
  assert.equal((await f.ask({ 'X-Mio-Configuration-Revision': first.configurationRevision })).status, 409);
  assert.equal(f.calls.length, 1);
  assert.equal((await f.ask({ 'X-Mio-Configuration-Revision': changed.configurationRevision })).status, 200);
  assert.equal(f.calls.at(-1).body.model, 'qwen/qwen3.8-27b');
});

for (const [variable, expected] of [['MIO_REQUESTS_PER_MINUTE', 'local_minute_limit'], ['MIO_REQUESTS_PER_DAY', 'local_day_limit']]) {
  test(`${variable} denial remains distinguishable`, async t => {
    const f = await fixture(t, { [variable]: '1' }, { reserveBudget: undefined, readQuota: undefined });
    assert.equal((await f.ask()).status, 200);
    const exhausted = await f.ask();
    assert.equal(exhausted.status, 429); assert.equal((await exhausted.json()).error, expected);
    assert.equal(f.calls.length, 1);
  });
}

test('unknown external quota and malformed revisions never pretend capacity or start provider work', async t => {
  const f = await fixture(t, {}, { readQuota: undefined });
  const status = await fetch(`${f.base}/v2/status`, { headers: auth }).then(response => response.json());
  assert.equal(status.quota.remaining, null); assert.equal(status.quota.resetAt, null);
  const response = await f.ask({ 'X-Mio-Configuration-Revision': 'secret\tvalue' });
  assert.equal(response.status, 400); assert.equal((await response.json()).error, 'invalid_configuration_revision');
  assert.equal(f.calls.length, 0); assert.equal(f.reservations(), 0);
});
