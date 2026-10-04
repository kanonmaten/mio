import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolveTaskProfile, taskProfiles } from '../src/task-profiles.mjs';

const base = { provider: 'openai', model: 'gpt-4.1', apiKey: 'fixture-openai',
  gatewayToken: 'fixture_gateway_token_01234567890123456789', requestsPerMinute: 6, requestsPerDay: 100,
  providerSecrets: { openai: 'fixture-openai', groq: 'fixture-groq', custom: 'fixture-custom' } };

test('absent task overrides preserve the global configuration for every existing task', () => {
  for (const task of ['ask', 'everyday', 'lesson']) {
    const result = resolveTaskProfile(base, task);
    assert.equal(result.configured, true); assert.equal(result.configurationError, null);
    assert.equal(result.config.provider, 'openai'); assert.equal(result.config.model, 'gpt-4.1');
    assert.equal(result.config.apiKey, base.apiKey);
  }
});

test('raw or object profiles route only their selected task to its designated provider secret', () => {
  const overrides = { everyday: { provider: 'groq', model: 'qwen/qwen3.8-27b' } };
  for (const taskProfiles of [overrides, JSON.stringify(overrides)]) {
    const config = { ...base, taskProfiles };
    const everyday = resolveTaskProfile(config, 'everyday');
    assert.equal(everyday.configured, true);
    assert.equal(everyday.config.provider, 'groq'); assert.equal(everyday.config.apiKey, 'fixture-groq');
    assert.equal(resolveTaskProfile(config, 'ask').config.provider, 'openai');
    assert.equal(resolveTaskProfile(config, 'lesson').config.provider, 'openai');
  }
});

test('a bad individual task disables only that task and never falls back to the global model', () => {
  const results = taskProfiles({ ...base, taskProfiles: { lesson: { model: 'unreviewed-model' } } });
  assert.equal(results.ask.configured, true); assert.equal(results.everyday.configured, true);
  assert.equal(results.lesson.configured, false); assert.equal(results.lesson.config, null);
  assert.equal(results.lesson.configurationError, 'provider_model_incompatible');
});

test('a model-only override inherits same-provider adapter defaults and validates them for its selected model', () => {
  const result = resolveTaskProfile({ ...base, adapterOptions: {}, taskProfiles: { ask: { model: 'gpt-4.1-mini' } } }, 'ask');
  assert.equal(result.configured, true); assert.deepEqual(result.config.adapterOptions, {});
  assert.equal(result.config.apiKey, base.apiKey);
});

test('provider switching requires its own designated secret and strips inherited adapter settings', () => {
  const overrides = { ask: { provider: 'groq', model: 'qwen/qwen3.8-27b' } };
  const result = resolveTaskProfile({ ...base, adapterOptions: { unsupportedForNextProvider: true },
    baseURL: 'https://private.fixture.invalid/v1', compatibility: 'chat-none-strict', taskProfiles: overrides }, 'ask');
  assert.equal(result.configured, true); assert.equal(result.config.apiKey, 'fixture-groq');
  assert.equal(result.config.adapterOptions, undefined); assert.equal(result.config.baseURL, undefined);
  assert.equal(result.config.compatibility, undefined);
  const unavailable = resolveTaskProfile({ ...base, providerSecrets: { openai: 'fixture-openai' }, taskProfiles: overrides }, 'ask');
  assert.equal(unavailable.configured, false); assert.equal(unavailable.config, null);
  assert.equal(unavailable.configurationError, 'provider_secret_missing');
});

test('embedded secrets, unknown fields, malformed overrides and unsupported required options fail closed', () => {
  for (const override of [null, [], 'groq', { apiKey: 'private-fixture' }, { headers: {} },
    { model: 'https://private.invalid/model' }, { adapterOptions: { temperature: 1 } }]) {
    const results = taskProfiles({ ...base, taskProfiles: { ask: override } });
    assert.equal(results.ask.configured, false); assert.equal(results.ask.config, null);
    assert.match(results.ask.configurationError, /^(task_profile_invalid|provider_options_incompatible)$/u);
    assert.equal(results.everyday.configured, true); assert.equal(results.lesson.configured, true);
  }
});

test('explicit endpoint assertions cannot be silently ignored by a non-custom task profile', () => {
  const legacy = { ...base, baseURL: 'https://legacy.fixture.invalid/v1', compatibility: 'chat-none-strict' };
  for (const override of [{ baseURL: 'https://different.fixture.invalid/v1' }, { compatibility: 'chat-none-strict' }]) {
    const results = taskProfiles({ ...legacy, taskProfiles: { ask: override } });
    assert.equal(results.ask.configured, false); assert.equal(results.ask.config, null);
    assert.equal(results.ask.configurationError, 'provider_options_incompatible');
    assert.equal(results.everyday.configured, true); assert.equal(results.lesson.configured, true);
  }
});

test('malformed or unknown top-level profile keys do not silently discard routing configuration', () => {
  for (const profiles of ['{broken', 'null', '[]', { unexpected: { model: 'gpt-4.1' } }]) {
    for (const result of Object.values(taskProfiles({ ...base, taskProfiles: profiles }))) {
      assert.equal(result.configured, false); assert.equal(result.config, null);
      assert.equal(result.configurationError, 'task_profiles_invalid');
    }
  }
});

test('custom endpoint and assertion inherit only with the same provider and model', () => {
  const custom = { ...base, provider: 'custom', model: 'operator-reviewed', apiKey: 'fixture-custom',
    baseURL: 'https://private.fixture.invalid/v1', compatibility: 'chat-none-strict' };
  assert.equal(resolveTaskProfile(custom, 'ask').configured, true);
  const changed = resolveTaskProfile({ ...custom, taskProfiles: { ask: { model: 'different-review' } } }, 'ask');
  assert.equal(changed.configured, false); assert.equal(changed.config, null);
  const explicit = resolveTaskProfile({ ...custom, taskProfiles: { ask: { model: 'different-review',
    baseURL: custom.baseURL, compatibility: custom.compatibility } } }, 'ask');
  assert.equal(explicit.configured, true);
});

test('unknown tasks and missing or unsafe provider secrets produce fixed errors without secret output', () => {
  assert.equal(resolveTaskProfile(base, 'unimplemented').configurationError, 'task_profile_invalid');
  assert.equal(resolveTaskProfile({ ...base, taskProfiles: { ask: { provider: 'unreviewed-provider', model: 'gpt-4.1' } } }, 'ask').configurationError,
    'provider_model_incompatible');
  for (const apiKey of ['', 'fixture\r\nheader', base.gatewayToken]) {
    const result = resolveTaskProfile({ ...base, apiKey }, 'ask');
    assert.equal(result.configured, false); assert.equal(result.config, null);
    assert.equal(result.configurationError, 'provider_secret_missing');
  }
});
