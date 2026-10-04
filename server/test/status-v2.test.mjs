import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { once } from 'node:events';
import { configurationRevision, gatewayStatusV2, statusV2FromEnvironment, metadataHeaders } from '../src/status.mjs';
import { readCloudBudget, reserveCloudBudget, reserveCloudBudgetOutcome } from '../src/cloud-budget.mjs';

const base = { provider: 'openai', model: 'gpt-4.1', apiKey: 'fixture-upstream',
  gatewayToken: 'fixture_gateway_token_01234567890123456789', requestsPerMinute: 6, requestsPerDay: 100,
  upstreamTimeoutMs: 1000, bodyTimeoutMs: 1000, providerSecrets: { groq: 'fixture-groq', custom: 'fixture-custom' } };

test('v2 status reports individual task contracts and safe fixed configuration failures', () => {
  const status = gatewayStatusV2({ ...base, taskProfiles: { lesson: { model: 'unreviewed-model' } } });
  assert.equal(status.protocolVersion, 2); assert.match(status.configurationRevision, /^[a-f0-9]{64}$/u);
  assert.deepEqual(Object.keys(status.tasks), ['ask', 'everyday', 'lesson']);
  for (const [task, contract] of [['ask', 'ask-v1'], ['everyday', 'analysis-context-v2'], ['lesson', 'lesson-notes-v1']]) {
    const item = status.tasks[task];
    assert.equal(item.configured, task !== 'lesson'); assert.equal(item.provider, 'openai');
    for (const required of ['reasoning-off', 'temperature-zero', 'strict-json', contract]) assert.ok(item.capabilities.includes(required));
    assert.equal(item.configurationError, task === 'lesson' ? 'provider_model_incompatible' : null);
  }
  assert.deepEqual(status.quota, { limit: 100, remaining: null, resetAt: null });
  assert.equal(metadataHeaders(status)['X-Mio-Configuration-Revision'], status.configurationRevision);
  assert.ok(Object.values(metadataHeaders(status)).every(value => typeof value === 'string'));
  const serialized = JSON.stringify(status);
  assert.ok(!serialized.includes(base.apiKey)); assert.ok(!serialized.includes(base.gatewayToken));
  assert.ok(!serialized.includes('providerSecrets')); assert.ok(!serialized.includes('apiKey'));
});

test('revision is canonical, changes with effective task configuration and limits, and excludes credentials', () => {
  const profiles = { ask: { model: 'gpt-4.1-mini' }, everyday: { provider: 'groq', model: 'qwen/qwen3.8-27b' } };
  const revision = configurationRevision({ ...base, taskProfiles: profiles });
  assert.equal(revision, configurationRevision({ ...base, taskProfiles: { everyday: { model: 'qwen/qwen3.8-27b', provider: 'groq' }, ask: { model: 'gpt-4.1-mini' } } }));
  assert.equal(revision, configurationRevision({ ...base, apiKey: 'rotated-fixture', gatewayToken: 'rotated_gateway_token_01234567890123456789',
    providerSecrets: { groq: 'rotated-groq', custom: 'rotated-custom' }, taskProfiles: JSON.stringify(profiles) }));
  assert.notEqual(revision, configurationRevision({ ...base, taskProfiles: { ...profiles, ask: { model: 'gpt-4.1-nano' } } }));
  assert.notEqual(revision, configurationRevision({ ...base, requestsPerDay: 99, taskProfiles: profiles }));
});

test('validated adapter option changes invalidate review while credential rotation does not', () => {
  const config = { ...base, providerSecrets: { ...base.providerSecrets, anthropic: 'fixture-anthropic' },
    taskProfiles: { ask: { provider: 'anthropic', model: 'claude-haiku-4-5', adapterOptions: { serviceTier: 'standard_only' } } } };
  const status = gatewayStatusV2(config);
  assert.equal(status.tasks.ask.configured, true);
  assert.notEqual(status.configurationRevision, configurationRevision({ ...config,
    taskProfiles: { ask: { ...config.taskProfiles.ask, adapterOptions: { serviceTier: 'auto' } } } }));
  assert.equal(status.configurationRevision, configurationRevision({ ...config,
    providerSecrets: { ...config.providerSecrets, anthropic: 'rotated-anthropic' } }));
});

test('custom endpoint identity affects revision without publishing any URL or secret fingerprint', () => {
  const custom = { ...base, provider: 'custom', model: 'operator-reviewed', apiKey: 'fixture-custom',
    baseURL: 'https://private.fixture.invalid/v1', compatibility: 'chat-none-strict' };
  const status = gatewayStatusV2(custom);
  assert.notEqual(status.configurationRevision, configurationRevision({ ...custom, baseURL: 'https://other.fixture.invalid/v1' }));
  assert.equal(status.configurationRevision, configurationRevision({ ...custom, apiKey: 'new-fixture-custom' }));
  assert.ok(!JSON.stringify(status).includes('private.fixture.invalid'));
});

test('unsafe public identifiers and arbitrary quota values are never reflected in status', () => {
  const status = gatewayStatusV2({ ...base, provider: 'private\nheader', model: 'https://private.fixture.invalid/model' },
    { limit: 100, remaining: -1, resetAt: 'private arbitrary body' });
  assert.equal(status.tasks.ask.provider, ''); assert.equal(status.tasks.ask.model, '');
  assert.deepEqual(status.quota, { limit: 100, remaining: null, resetAt: null });
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
  const status = statusV2FromEnvironment({ MIO_AI_PROVIDER: 'openai', MIO_AI_MODEL: 'gpt-4.1', MIO_REQUESTS_PER_DAY: '0',
    MIO_AI_TASK_PROFILES: JSON.stringify({ ask: { provider: 'groq', model: 'qwen/qwen3.8-27b' } }) },
    () => { throw new Error('private credential or configuration text'); }, { remaining: 5, resetAt: '2026-10-03T00:00:00.000Z' });
  for (const task of Object.values(status.tasks)) {
    assert.equal(task.configured, false); assert.equal(task.configurationError, 'gateway_configuration_invalid');
  }
  assert.equal(status.tasks.ask.provider, 'groq'); assert.equal(status.tasks.ask.model, 'qwen/qwen3.8-27b');
  assert.deepEqual(status.quota, { limit: 100, remaining: null, resetAt: null });
  assert.ok(!JSON.stringify(status).includes('private credential'));
});

function database(t) {
  const sql = new DatabaseSync(':memory:');
  sql.exec(readFileSync(new URL('../cloudflare/schema.sql', import.meta.url), 'utf8'));
  t.after(() => sql.close());
  const queries = [];
  return { sql, queries, prepare: query => ({ bind: (...params) => ({ first: async () => {
    queries.push(query); return sql.prepare(query).get(...params);
  } }) }) };
}

test('read-only cloud quota reflects empty/current/rolled-over days without changing counters', async t => {
  const db = database(t); const config = { requestsPerMinute: 2, requestsPerDay: 3 };
  assert.deepEqual(await readCloudBudget(db, config, 0), { limit: 3, remaining: 3, resetAt: '1970-01-02T00:00:00.000Z' });
  assert.equal(await reserveCloudBudget(db, config, 0), true);
  const before = db.sql.prepare('SELECT * FROM mio_budget').get(); db.queries.length = 0;
  assert.deepEqual(await readCloudBudget(db, config, 0), { limit: 3, remaining: 2, resetAt: '1970-01-02T00:00:00.000Z' });
  assert.deepEqual(db.sql.prepare('SELECT * FROM mio_budget').get(), before);
  assert.ok(db.queries.every(sql => /^SELECT\b/u.test(sql.trim())));
  assert.deepEqual(await readCloudBudget(db, config, 86_400_000), { limit: 3, remaining: 3, resetAt: '1970-01-03T00:00:00.000Z' });
  assert.deepEqual(db.sql.prepare('SELECT * FROM mio_budget').get(), before);
});

test('unknown or unavailable quota stays explicit, while malformed stored counters fail safely', async t => {
  assert.deepEqual(await readCloudBudget(undefined, base, 0), { limit: 100, remaining: null, resetAt: null });
  const db = database(t);
  db.sql.exec('INSERT INTO mio_budget VALUES (1, 0, 0, 0, -1)');
  await assert.rejects(readCloudBudget(db, base, 0));
  await assert.rejects(readCloudBudget({ prepare: () => { throw new Error('private DB body'); } }, base, 0));
});

test('invalid quota clocks are rejected before querying the budget store', async () => {
  let reads = 0;
  const db = { prepare: () => { reads++; throw new Error('Unexpected budget access'); } };
  for (const now of [Number.MAX_SAFE_INTEGER, 8_640_000_000_000_000, -1, NaN, 1.5]) {
    await assert.rejects(readCloudBudget(db, base, now), /Invalid quota observation/u);
  }
  assert.equal(reads, 0);
});

test('detailed atomic cloud reservations distinguish minute and day limits without refunds', async t => {
  const db = database(t); const config = { requestsPerMinute: 1, requestsPerDay: 2 };
  assert.deepEqual(await reserveCloudBudgetOutcome(db, config, 0), { allowed: true });
  assert.deepEqual(await reserveCloudBudgetOutcome(db, config, 1), { allowed: false, reason: 'local_minute_limit' });
  assert.deepEqual(await reserveCloudBudgetOutcome(db, config, 60_000), { allowed: true });
  assert.deepEqual(await reserveCloudBudgetOutcome(db, config, 120_000), { allowed: false, reason: 'local_day_limit' });
  assert.equal(db.sql.prepare('SELECT day_count FROM mio_budget').get().day_count, 2);
  assert.equal(await reserveCloudBudget(db, config, 120_000), false);
});

test('ambiguous denials stay closed and failed denial classification never looks like an allowed reservation', async () => {
  const unknown = { prepare: () => ({ bind: () => ({ first: async () => undefined }) }) };
  assert.deepEqual(await reserveCloudBudgetOutcome(unknown, base, 0), { allowed: false, reason: 'local_request_limit' });
  let query = 0;
  const failed = { prepare: () => ({ bind: () => ({ first: async () => {
    if (query++ === 0) return undefined;
    throw new Error('private DB failure');
  } }) }) };
  await assert.rejects(reserveCloudBudgetOutcome(failed, base, 0));
});

test('protected v2 status makes no provider call or quota reservation and exposes revision metadata', async t => {
  const { createMioServer } = await import('../src/server.mjs');
  let fetches = 0; let reserves = 0;
  const server = createMioServer({ config: base, fetchImpl: async () => { fetches++; assert.fail('Discovery must not call a model'); },
    reserveBudget: async () => { reserves++; assert.fail('Discovery must not reserve quota'); } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const url = `http://127.0.0.1:${server.address().port}/v2/status`;
  assert.equal((await fetch(url)).status, 401);
  const response = await fetch(url, { headers: { Authorization: `Bearer ${base.gatewayToken}` } });
  assert.equal(response.status, 200); const status = await response.json();
  assert.equal(response.headers.get('X-Mio-Configuration-Revision'), status.configurationRevision);
  assert.deepEqual(Object.keys(status.tasks), ['ask', 'everyday', 'lesson']);
  assert.equal(fetches, 0); assert.equal(reserves, 0);
});
