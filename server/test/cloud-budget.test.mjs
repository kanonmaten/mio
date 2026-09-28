import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { once } from 'node:events';
import { reserveCloudBudget } from '../src/cloud-budget.mjs';
import { createMioServer } from '../src/server.mjs';

function database(t) {
  const sql = new DatabaseSync(':memory:');
  sql.exec(readFileSync(new URL('../cloudflare/schema.sql', import.meta.url), 'utf8'));
  t.after(() => sql.close());
  return { prepare: query => ({ bind: (...params) => ({ first: async () => sql.prepare(query).get(...params) }) }) };
}

test('cloud budget uses atomic persisted minute/day counters and UTC rollover', async t => {
  const db = database(t);
  const config = { requestsPerMinute: 2, requestsPerDay: 3 };
  assert.equal(await reserveCloudBudget(db, config, 0), true);
  assert.equal(await reserveCloudBudget(db, config, 1), true);
  assert.equal(await reserveCloudBudget(db, config, 2), false);
  assert.equal(await reserveCloudBudget(db, config, 60_000), true);
  assert.equal(await reserveCloudBudget(db, config, 120_000), false);
  assert.equal(await reserveCloudBudget(db, config, 86_400_000), true);
});

test('independent concurrent reservations share one hard daily count', async t => {
  const db = database(t);
  const results = await Promise.all(Array.from({ length: 20 }, () => reserveCloudBudget(db, { requestsPerMinute: 60, requestsPerDay: 5 }, 0)));
  assert.equal(results.filter(Boolean).length, 5);
  await assert.rejects(reserveCloudBudget(undefined, { requestsPerMinute: 6, requestsPerDay: 100 }));
});

test('failed or exhausted cloud budget cannot make a provider call; auth runs first', async t => {
  const config = { apiKey: 'fixture-upstream', gatewayToken: 'fixture_gateway_token_01234567890123456789', model: 'gpt-6-luna',
    requestsPerMinute: 60, requestsPerDay: 100, upstreamTimeoutMs: 1000, bodyTimeoutMs: 1000 };
  let budgetCalls = 0;
  let fail = false;
  const server = createMioServer({ config, reserveBudget: async () => {
    budgetCalls++;
    if (fail) throw new Error('private database diagnostic');
    return false;
  }, fetchImpl: async () => { assert.fail('No provider call without quota'); } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const send = token => fetch(`http://127.0.0.1:${server.address().port}/v1/ask`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ question: 'Syntetiskt prov', context: [] })
  });
  assert.equal((await send('invalid')).status, 401);
  assert.equal(budgetCalls, 0);
  assert.equal((await send(config.gatewayToken)).status, 429);
  fail = true;
  const response = await send(config.gatewayToken);
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'upstream_unavailable' });
});
