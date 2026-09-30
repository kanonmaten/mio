import assert from 'node:assert/strict';
import { test } from 'node:test';
import { loadConfig } from '../src/server.mjs';
const token = 'fixture_gateway_token_01234567890123456789';
const env = { MIO_AI_PROVIDER: 'groq', MIO_AI_MODEL: 'qwen/qwen3.8-27b', GROQ_API_KEY: 'fixture-key', MIO_GATEWAY_TOKEN: token };
test('status exposes safe configuration metadata despite invalid provider, key or limits', async () => {
  const { statusFromEnvironment, authenticated } = await import('../src/status.mjs');
  assert.equal(statusFromEnvironment(env, loadConfig).configured, true);
  for (const patch of [{ GROQ_API_KEY: '' }, { MIO_AI_MODEL: 'unreviewed-model' }, { MIO_REQUESTS_PER_DAY: '0' },
    { MIO_LESSON_INTERVAL_SECONDS: '59' }, { GROQ_API_KEY: token }]) {
    assert.equal(statusFromEnvironment({ ...env, ...patch }, loadConfig).configured, false);
  }
  const invalid = statusFromEnvironment({ ...env, MIO_AI_PROVIDER: 'private secret\n', MIO_AI_MODEL: 'secret\r\nCookie: password' }, loadConfig);
  assert.equal(invalid.provider, ''); assert.equal(invalid.model, ''); assert.equal(invalid.configured, false);
  assert.equal(authenticated(`Bearer ${token}`, token), true);
  assert.equal(authenticated(`Bearer ${token}`, ''), false);
  assert.equal(authenticated('Bearer wrong', token), false);
});
