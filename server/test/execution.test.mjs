import { generationMetadataHeaders } from '../src/generation-execution.mjs';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once, getEventListeners } from 'node:events';
import { request as httpRequest } from 'node:http';
import { createMioServer } from '../src/server.mjs';

const token = 'fixture_gateway_token_01234567890123456789';
const config = { apiKey: 'fixture-key', gatewayToken: token, model: 'gpt-6-luna',
  requestsPerMinute: 60, requestsPerDay: 100, upstreamTimeoutMs: 45, bodyTimeoutMs: 45 };
const body = JSON.stringify({ question: 'Syntetiskt prov', context: [] });
const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => Promise.withResolvers();
function completion() {
  return Response.json({ status: 'completed', output: [{ type: 'message', role: 'assistant',
    content: [{ type: 'output_text', text: '{"answer":"Syntetiskt svar"}' }] }] });
}
async function fixture(t, options) {
  const responses = [];
  const server = createMioServer({ config, ...options });
  server.on('request', (_, response) => responses.push(response));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const url = `http://127.0.0.1:${server.address().port}/v1/ask`;
  return { url, responses, send: () => fetch(url, { method: 'POST', headers, body, signal: AbortSignal.timeout(500) }) };
}

test('hung quota returns a budget-store failure at the deadline and releases both concurrency slots', async t => {
  let reservations = 0;
  let providerCalls = 0;
  const f = await fixture(t, { reserveBudget: () => { reservations++; return new Promise(() => {}); },
    fetchImpl: async () => { providerCalls++; return completion(); } });
  const results = await Promise.all([f.send(), f.send()]);
  for (const response of results) {
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: 'budget_store_failed' });
  }
  assert.equal((await f.send()).status, 503);
  assert.equal(reservations, 3);
  assert.equal(providerCalls, 0);
  await tick();
  assert.ok(f.responses.every(response => response.listenerCount('close') === 0));
});

test('late uncancellable quota completion cannot start inference or refund quota', async t => {
  const reservation = deferred();
  let providerCalls = 0;
  const f = await fixture(t, { reserveBudget: () => reservation.promise,
    fetchImpl: async () => { providerCalls++; return completion(); } });
  const response = await f.send();
  assert.equal(response.status, 503);
  reservation.resolve(true);
  await tick();
  assert.equal(providerCalls, 0);
  assert.deepEqual(await response.json(), { error: 'budget_store_failed' });
});

test('quota and response reading share one deadline even when transports ignore abort', async t => {
  const quota = deferred();
  let cancelled = 0;
  const stream = new ReadableStream({ cancel() { cancelled++; } });
  const f = await fixture(t, { reserveBudget: () => quota.promise,
    fetchImpl: async () => new Response(stream, { headers: { 'Content-Type': 'application/json' } }) });
  const pending = f.send();
  setTimeout(() => quota.resolve(true), 25);
  const response = await pending;
  assert.equal(response.status, 504);
  assert.deepEqual(await response.json(), { error: 'upstream_timeout' });
  await tick();
  assert.equal(cancelled, 1);
  assert.equal(stream.locked, false);
});

test('late transport completion is discarded and its body cancelled after the deadline', async t => {
  const transport = deferred();
  let cancelled = 0;
  const f = await fixture(t, { fetchImpl: () => transport.promise });
  const response = await f.send();
  assert.equal(response.status, 504);
  const stream = new ReadableStream({ cancel() { cancelled++; } });
  transport.resolve(new Response(stream, { headers: { 'Content-Type': 'application/json' } }));
  await tick();
  assert.equal(cancelled, 1);
  assert.equal((await response.json()).error, 'upstream_timeout');
});

test('Node socket disconnect during quota releases the slot and never starts a late provider call', async t => {
  const reservation = deferred();
  const entered = deferred();
  let providerCalls = 0;
  let reservations = 0;
  const f = await fixture(t, { config: { ...config, upstreamTimeoutMs: 500 },
    reserveBudget: () => { reservations++; entered.resolve(); return reservations <= 2 ? reservation.promise : true; },
    fetchImpl: async () => { providerCalls++; return completion(); } });
  const clients = [1, 2].map(() => {
    const client = httpRequest(f.url, { method: 'POST', headers });
    client.on('error', () => {}); client.end(body); return client;
  });
  await entered.promise;
  // Both requests must have reached the reservation before their sockets are closed.
  while (reservations < 2) await tick();
  for (const client of clients) client.destroy();
  await Promise.all(f.responses.map(response => once(response, 'close')));
  const response = await f.send();
  assert.equal(response.status, 200);
  reservation.resolve(true); await tick();
  assert.equal(providerCalls, 1);
});

test('explicit runtime cancellation during quota is distinct from deadline expiry', async t => {
  const controller = new AbortController();
  const entered = deferred();
  const quota = deferred();
  let providerCalls = 0;
  const f = await fixture(t, { requestSignal: () => controller.signal,
    reserveBudget: () => { entered.resolve(); return quota.promise; },
    fetchImpl: async () => { providerCalls++; return completion(); } });
  const pending = f.send(); await entered.promise; controller.abort();
  const response = await pending;
  assert.equal(response.status, 499);
  assert.deepEqual(await response.json(), { error: 'request_cancelled' });
  quota.resolve(true); await tick(); assert.equal(providerCalls, 0);
  assert.equal(getEventListeners(controller.signal, 'abort').length, 0);
});

test('slow chunked request body has its separate deadline and never reserves quota', async t => {
  let reservations = 0;
  const f = await fixture(t, { reserveBudget: async () => { reservations++; return true; } });
  const client = httpRequest(f.url, { method: 'POST', headers });
  client.on('error', () => {});
  client.write('{"question":');
  const [response] = await once(client, 'response');
  const chunks = []; for await (const chunk of response) chunks.push(chunk);
  assert.equal(response.statusCode, 408);
  assert.deepEqual(JSON.parse(Buffer.concat(chunks)), { error: 'request_timeout' });
  assert.equal(reservations, 0);
  client.destroy();
});

for (const stage of ['body', 'fetch', 'response']) {
  test(`Node disconnect during ${stage} cancels work and frees resources for the next request`, async t => {
    const entered = deferred();
    let calls = 0;
    let aborts = 0;
    let bodyCancellations = 0;
    const stream = new ReadableStream({ cancel() { bodyCancellations++; } });
    const f = await fixture(t, { config: { ...config, upstreamTimeoutMs: 500 }, fetchImpl: async (_, init) => {
      calls++;
      if (calls > 1 || stage === 'body') return completion();
      init.signal.addEventListener('abort', () => aborts++, { once: true });
      entered.resolve();
      if (stage === 'fetch') return new Promise(() => {});
      return new Response(stream, { headers: { 'Content-Type': 'application/json' } });
    } });
    const client = httpRequest(f.url, { method: 'POST', headers });
    client.on('error', () => {});
    if (stage === 'body') client.write('{"question":');
    else client.end(body);
    if (stage === 'body') {
      while (f.responses.length < 1) await tick();
    } else await entered.promise;
    const closed = once(f.responses[0], 'close');
    client.destroy(); await closed; await tick();
    const response = await f.send();
    assert.equal(response.status, 200);
    assert.equal(calls, stage === 'body' ? 1 : 2);
    assert.equal(aborts, stage === 'body' ? 0 : 1);
    assert.equal(bodyCancellations, stage === 'response' ? 1 : 0);
    if (stage === 'response') assert.equal(stream.locked, false);
    assert.ok(f.responses.every(item => item.listenerCount('close') === 0));
  });
}


test('public generation metadata drops URLs and credential-shaped identifiers', () => {
  for (const value of ['https://private.example/model', 'sk-private', 'sk_private', 'gsk_private', 'AIzaPrivate', 'SK_private', 'GSK_private', 'aizaPrivate']) {
    assert.deepEqual(generationMetadataHeaders({ returnedModel: value, provenance: { requestID: value } }), {});
  }
  assert.deepEqual(generationMetadataHeaders({ returnedModel: 'model-1', provenance: { requestID: 'req_1' },
    usage: { inputTokens: 4, outputTokens: 2, reasoningTokens: 0 } }), {
      'X-Mio-Returned-Model': 'model-1', 'X-Mio-Upstream-Request-ID': 'req_1',
      'X-Mio-Usage-Input-Tokens': '4', 'X-Mio-Usage-Output-Tokens': '2', 'X-Mio-Usage-Reasoning-Tokens': '0'
    });
});

test('oversized provider error envelopes keep their quota category and Retry-After', async t => {
  const f = await fixture(t, { fetchImpl: async () => new Response('x'.repeat(70_000), { status: 429,
    headers: { 'Content-Type': 'application/json', 'Retry-After': '7' } }) });
  const response = await f.send();
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '7');
  assert.deepEqual(await response.json(), { error: 'provider_quota' });
});
