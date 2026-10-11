import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolveTaskProfile, taskProfiles } from '../src/task-profiles.mjs';

const MODEL = 'qwen/qwen3.8-27b';
const base = { provider: 'groq', model: MODEL, apiKey: 'fixture-groq',
  gatewayToken: 'fixture_gateway_token_01234567890123456789', requestsPerMinute: 6, requestsPerDay: 100,
  providerSecrets: { groq: 'fixture-groq' } };

test('absent task overrides preserve the global configuration for every existing task', () => {
  for (const task of ['ask', 'everyday', 'lesson']) {
    const result = resolveTaskProfile(base, task);
    assert.equal(result.configured, true); assert.equal(result.configurationError, null);
    assert.equal(result.config.provider, 'groq'); assert.equal(result.config.model, MODEL);
    assert.equal(result.config.apiKey, base.apiKey);
    assert.equal(result.config.providerSecrets, undefined); assert.equal(result.config.taskProfiles, undefined);
  }
});

test('raw or object profiles apply only to their selected task', () => {
  const overrides = { everyday: { model: 'unreviewed-model' } };
  for (const profiles of [overrides, JSON.stringify(overrides)]) {
    const results = taskProfiles({ ...base, taskProfiles: profiles });
    assert.equal(results.everyday.configured, false);
    assert.equal(results.ask.configured, true); assert.equal(results.lesson.configured, true);
  }
});

test('a bad individual task disables only that task and never falls back to the global model', () => {
  const results = taskProfiles({ ...base, taskProfiles: { lesson: { model: 'unreviewed-model' } } });
  assert.equal(results.ask.configured, true); assert.equal(results.everyday.configured, true);
  assert.equal(results.lesson.configured, false); assert.equal(results.lesson.config, null);
  assert.equal(results.lesson.configurationError, 'provider_model_incompatible');
});

test('switching a task to an unreviewed provider fails closed and never reuses the Groq secret', () => {
  for (const provider of ['openai', 'anthropic', 'custom', 'unreviewed-provider']) {
    const result = resolveTaskProfile({ ...base, providerSecrets: { groq: 'fixture-groq', [provider]: 'fixture-other' },
      taskProfiles: { ask: { provider, model: MODEL } } }, 'ask');
    assert.equal(result.configured, false); assert.equal(result.config, null);
    assert.equal(result.configurationError, 'provider_model_incompatible');
  }
});

test('embedded secrets, unknown fields, malformed overrides and unsupported options fail closed', () => {
  for (const override of [null, [], 'groq', { apiKey: 'private-fixture' }, { headers: {} }, { baseURL: 'https://x.invalid/v1' },
    { model: 'https://private.invalid/model' }, { adapterOptions: { temperature: 1 } }]) {
    const results = taskProfiles({ ...base, taskProfiles: { ask: override } });
    assert.equal(results.ask.configured, false); assert.equal(results.ask.config, null);
    assert.match(results.ask.configurationError, /^(task_profile_invalid|provider_options_incompatible)$/u);
    assert.equal(results.everyday.configured, true); assert.equal(results.lesson.configured, true);
  }
});

test('malformed or unknown top-level profile keys do not silently discard routing configuration', () => {
  for (const profiles of ['{broken', 'null', '[]', { unexpected: { model: MODEL } }]) {
    for (const result of Object.values(taskProfiles({ ...base, taskProfiles: profiles }))) {
      assert.equal(result.configured, false); assert.equal(result.config, null);
      assert.equal(result.configurationError, 'task_profiles_invalid');
    }
  }
});

test('unknown tasks and missing or unsafe provider secrets produce fixed errors without secret output', () => {
  assert.equal(resolveTaskProfile(base, 'unimplemented').configurationError, 'task_profile_invalid');
  for (const apiKey of ['', 'fixture\r\nheader', base.gatewayToken]) {
    const result = resolveTaskProfile({ ...base, apiKey }, 'ask');
    assert.equal(result.configured, false); assert.equal(result.config, null);
    assert.equal(result.configurationError, 'provider_secret_missing');
  }
});
