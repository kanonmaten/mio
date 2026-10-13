import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { configurationRevision, gatewayStatusV2, statusV2FromEnvironment, metadataHeaders } from '../src/status.mjs';

const MODEL = 'qwen/qwen3.8-27b';
const base = { provider: 'groq', model: MODEL, apiKey: 'fixture-upstream',
  gatewayToken: 'fixture_gateway_token_01234567890123456789', requestsPerMinute: 6, requestsPerDay: 100,
  upstreamTimeoutMs: 1000, bodyTimeoutMs: 1000, providerSecrets: { groq: 'fixture-upstream' } };

test('v2 status reports individual task contracts and safe fixed configuration failures', () => {
  const status = gatewayStatusV2({ ...base, taskProfiles: { lesson: { model: 'unreviewed-model' } } });
  assert.equal(status.protocolVersion, 2); assert.match(status.configurationRevision, /^[a-f0-9]{64}$/u);
  assert.deepEqual(Object.keys(status.tasks), ['ask', 'everyday', 'lesson']);
  for (const [task, contract] of [['ask', 'ask-v1'], ['everyday', 'analysis-context-v2'], ['lesson', 'lesson-notes-v1']]) {
    const item = status.tasks[task];
    assert.equal(item.configured, task !== 'lesson'); assert.equal(item.provider, 'groq');
    for (const required of ['reasoning-off', 'temperature-zero', 'strict-json', contract]) assert.ok(item.capabilities.includes(required));
    assert.equal(item.configurationError, task === 'lesson' ? 'provider_model_incompatible' : null);
    assert.equal(item.capabilities.includes('analysis-backlog-v1'), task === 'everyday');
  }
  assert.deepEqual(status.quota, { limit: 100, remaining: null, resetAt: null, unit: 'requests' });
  assert.equal(metadataHeaders(status)['X-Mio-Configuration-Revision'], status.configurationRevision);
  assert.ok(Object.values(metadataHeaders(status)).every(value => typeof value === 'string'));
  const serialized = JSON.stringify(status);
  assert.ok(!serialized.includes(base.apiKey)); assert.ok(!serialized.includes(base.gatewayToken));
  assert.ok(!serialized.includes('providerSecrets')); assert.ok(!serialized.includes('apiKey'));
});

test('revision is canonical, changes with effective task configuration and limits, and excludes credentials', () => {
  const profiles = { ask: { model: MODEL }, lesson: { model: 'unreviewed-model' } };
  const revision = configurationRevision({ ...base, taskProfiles: profiles });
  assert.equal(revision, configurationRevision({ ...base, taskProfiles: { lesson: { model: 'unreviewed-model' }, ask: { model: MODEL } } }));
  assert.equal(revision, configurationRevision({ ...base, apiKey: 'rotated-fixture', gatewayToken: 'rotated_gateway_token_01234567890123456789',
    providerSecrets: { groq: 'rotated-groq' }, taskProfiles: JSON.stringify(profiles) }));
  assert.notEqual(revision, configurationRevision({ ...base, taskProfiles: { ...profiles, lesson: { model: MODEL } } }));
  assert.notEqual(revision, configurationRevision({ ...base, requestsPerDay: 99, taskProfiles: profiles }));
  assert.notEqual(revision, configurationRevision({ ...base, tokensPerDay: 190000, taskProfiles: profiles }));
});

test('a token cap is reported with its unit and takes precedence over a request cap', () => {
  const status = gatewayStatusV2({ ...base, tokensPerDay: 190000 }, { limit: 190000, remaining: 1000, resetAt: '2026-10-12T00:00:00.000Z' });
  assert.deepEqual(status.quota, { limit: 190000, remaining: 1000, resetAt: '2026-10-12T00:00:00.000Z', unit: 'tokens' });
  assert.equal(gatewayStatusV2({ ...base, requestsPerDay: null, tokensPerDay: null }).quota, null);
});

test('unsafe public identifiers and arbitrary quota values are never reflected in status', () => {
  const status = gatewayStatusV2({ ...base, provider: 'private\nheader', model: 'https://private.fixture.invalid/model' },
    { limit: 100, remaining: -1, resetAt: 'private arbitrary body' });
  assert.equal(status.tasks.ask.provider, ''); assert.equal(status.tasks.ask.model, '');
  assert.deepEqual(status.quota, { limit: 100, remaining: null, resetAt: null, unit: 'requests' });
  for (const resetAt of ['2026-99-01T00:00:00.000Z', '2026-02-30T00:00:00.000Z']) {
    assert.equal(gatewayStatusV2(base, { remaining: 99, resetAt }).quota.resetAt, null);
  }
});

test('credential-shaped configured identifiers never enter public discovery or metadata headers', () => {
  for (const prefix of ['sk-', 'SK-', 'sk_', 'Sk_', 'gsk_', 'GSK_', 'AIza', 'aIzA']) {
    const privateValue = `${prefix}fixture-private`;
    const modelStatus = gatewayStatusV2({ ...base, taskProfiles: { lesson: { model: privateValue } } });
    const providerStatus = gatewayStatusV2({ ...base, taskProfiles: { lesson: { provider: privateValue } } });
    assert.equal(modelStatus.tasks.lesson.model, '');
    assert.equal(providerStatus.tasks.lesson.provider, '');
    assert.equal(modelStatus.tasks.ask.configured, true); assert.equal(providerStatus.tasks.ask.configured, true);
    assert.ok(!JSON.stringify(modelStatus).includes(privateValue)); assert.ok(!JSON.stringify(providerStatus).includes(privateValue));
    const headers = metadataHeaders({ provider: privateValue, model: privateValue });
    assert.equal(headers['X-Mio-Provider'], ''); assert.equal(headers['X-Mio-Model'], '');
  }
});

test('environment discovery distinguishes global configuration failures without exposing private parse errors', () => {
  const status = statusV2FromEnvironment({ MIO_AI_PROVIDER: 'groq', MIO_AI_MODEL: MODEL, MIO_REQUESTS_PER_DAY: '0',
    MIO_AI_TASK_PROFILES: JSON.stringify({ ask: { provider: 'groq', model: 'qwen/qwen3.8-27b' } }) },
    () => { throw new Error('private credential or configuration text'); }, { remaining: 5, resetAt: '2026-10-03T00:00:00.000Z' });
  for (const task of Object.values(status.tasks)) {
    assert.equal(task.configured, false); assert.equal(task.configurationError, 'gateway_configuration_invalid');
  }
  assert.equal(status.tasks.ask.provider, 'groq'); assert.equal(status.tasks.ask.model, 'qwen/qwen3.8-27b');
  assert.equal(status.quota, null);
  assert.ok(!JSON.stringify(status).includes('private credential'));
});

test('protected v2 status makes no provider call or quota reservation and exposes revision metadata', async t => {
  const { createMioServer } = await import('../src/server.mjs');
  let fetches = 0; let saves = 0;
  const counterStore = { load: () => ({ minute: -1, minuteCount: 0, day: -1, dayCount: 0, dayTokens: 0 }),
    save: () => { saves++; assert.fail('Discovery must not reserve quota'); } };
  const server = createMioServer({ config: base, counterStore, fetchImpl: async () => { fetches++; assert.fail('Discovery must not call a model'); } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const url = `http://127.0.0.1:${server.address().port}/v2/status`;
  assert.equal((await fetch(url)).status, 401);
  const response = await fetch(url, { headers: { Authorization: `Bearer ${base.gatewayToken}` } });
  assert.equal(response.status, 200); const status = await response.json();
  assert.equal(response.headers.get('X-Mio-Configuration-Revision'), status.configurationRevision);
  assert.deepEqual(Object.keys(status.tasks), ['ask', 'everyday', 'lesson']);
  assert.equal(fetches, 0); assert.equal(saves, 0);
});

test('v1 status describes the effective everyday task profile for older clients', async () => {
  const { gatewayStatus } = await import('../src/status.mjs');
  const base = { apiKey: 'fixture-key', gatewayToken: 'fixture_gateway_token_01234567890123456789', model: MODEL };
  assert.equal(gatewayStatus(base).configured, true);
  const broken = gatewayStatus({ ...base, taskProfiles: { everyday: { model: 'not-a-reviewed-model' } } });
  assert.equal(broken.configured, false, 'v1 must not report an everyday task that /v1/analyze refuses');
  assert.equal(broken.model, 'not-a-reviewed-model');
});
