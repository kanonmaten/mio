import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { providerRequest, providerResponseText, providerProfile } from '../src/provider.mjs';
import { createMioServer, loadConfig } from '../src/server.mjs';
import { validateLessonPayload, validateLessonResult, validateAskResult } from '../src/analysis.mjs';
import { resolveTaskProfile } from '../src/task-profiles.mjs';

const token = 'fixture_gateway_token_01234567890123456789';
const id = '00000000-0000-0000-0000-000000000001:0';
const payload = { mode: 'lesson', timeZone: 'Europe/Stockholm', fragments: [
  { id, text: 'Procent betyder hundradelar. 20 procent av 50 är 0,20 gånger 50 = 10. Gör uppgift 7 till fredag.', occurredAt: '2026-09-28T08:00:00Z' }
] };
const notes = { candidates: [{ kind: 'task', title: 'Gör uppgift 7', body: 'Till fredag.', scheduledAt: null,
  sourceIDs: [id], evidence: 'Gör uppgift 7 till fredag.' }], sections: [{ heading: 'Procent och beräkning',
  body: 'Procent betyder hundradelar.\n1. Skriv 20 % som 0,20.\n2. Multiplicera med 50.\n3. Resultatet är 10.',
  sourceIDs: [id], evidence: '20 procent av 50 är 0,20 gånger 50 = 10.' }], uncertainties: [] };
const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
function configFor(model = 'qwen/qwen3.8-27b') {
  return loadConfig({ MIO_AI_MODEL: model, GROQ_API_KEY: 'fixture-key', OPENAI_API_KEY: 'must-not-use-other-vendor-key',
    MIO_GATEWAY_TOKEN: token });
}
function envelope(value) {
  return { choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify(value) } }] };
}

test('groq: correct secret, endpoint, strict schema, temperature and reasoning policy', () => {
  const config = configFor();
  assert.equal(config.provider, 'groq');
  assert.equal(config.apiKey, 'fixture-key');
  for (const mode of ['ask', 'analyze', 'lesson']) {
    const request = providerRequest({ config, mode, payload });
    assert.equal(request.url, GROQ_URL);
    assert.equal(request.body.temperature, 0);
    assert.equal(request.body.model, 'qwen/qwen3.8-27b');
    assert.equal(request.body.reasoning_effort, 'none');
    assert.equal(request.body.stream, false);
    assert.equal(request.headers.Authorization, 'Bearer fixture-key');
    assert.ok(!JSON.stringify(request).includes(token));
    assert.ok(!JSON.stringify(request).includes('must-not-use-other-vendor-key'));
    const format = request.body.response_format.json_schema;
    assert.equal(request.body.response_format.type, 'json_schema');
    assert.equal(format.strict, true);
    assert.equal(format.schema.additionalProperties, false);
    if (mode === 'lesson') assert.deepEqual(format.schema.properties.candidates.items.properties.kind.enum, ['plan', 'task']);
    assert.deepEqual(format.schema.required, Object.keys(format.schema.properties));
    assert.equal(providerResponseText(envelope(notes), request.profile), JSON.stringify(notes));
  }
});

test('only the reviewed Groq model is accepted; other providers and models fail before a request is built', () => {
  for (const [provider, model] of [['groq', 'openai/gpt-oss-20b'], ['groq', 'invented'], ['groq', 'qwen/qwen3-32b'],
    ['openai', 'gpt-6-luna'], ['gemini', 'gemini-2.5-flash'], ['anthropic', 'claude-haiku-4-5'],
    ['openrouter', 'openai/gpt-4.1'], ['nvidia', 'deepseek-ai/deepseek-v4.1-flash'], ['custom', 'host/model'],
    ['groq', 'gsk_secretlooking'], ['groq', 'https://evil.example/model'], ['groq', '']]) {
    assert.throws(() => providerProfile({ provider, model }), /provider_model_incompatible/u);
  }
  assert.throws(() => providerProfile({ provider: 'groq', model: 'qwen/qwen3.8-27b', adapterOptions: { route: 'x' } }),
    /provider_options_incompatible/u);
  const profile = providerProfile({ provider: 'groq', model: 'qwen/qwen3.8-27b' });
  assert.equal(profile.contractReview.liveTested, false);
  assert.deepEqual(profile.capabilities, ['reasoning-off', 'temperature-zero', 'strict-json']);
});

test('removed provider environment variables are ignored and never reused as Groq credentials or model', () => {
  const env = { MIO_GATEWAY_TOKEN: token, OPENAI_API_KEY: 'fixture', MIO_OPENAI_MODEL: 'gpt-6-luna' };
  const missingKey = loadConfig({ ...env, MIO_AI_MODEL: 'qwen/qwen3.8-27b' });
  assert.equal(missingKey.provider, 'groq');
  assert.equal(missingKey.apiKey, '');
  assert.equal(resolveTaskProfile(missingKey, 'ask').configured, false);
  const missingModel = loadConfig({ ...env, GROQ_API_KEY: 'fixture' });
  assert.equal(missingModel.model, '');
  assert.equal(resolveTaskProfile(missingModel, 'ask').configured, false);
  assert.equal(resolveTaskProfile(loadConfig({ ...env, GROQ_API_KEY: 'fixture', MIO_AI_MODEL: 'qwen/qwen3.8-27b' }), 'ask').configured, true);
  assert.equal(resolveTaskProfile(loadConfig({ ...env, MIO_AI_PROVIDER: 'openai', GROQ_API_KEY: 'fixture',
    MIO_AI_MODEL: 'qwen/qwen3.8-27b' }), 'ask').configured, false);
});

test('the chat adapter rejects truncation, refusals, tools and observable reasoning', () => {
  const profile = { wire: 'chat' };
  let data = envelope(notes); data.choices[0].finish_reason = 'length';
  assert.throws(() => providerResponseText(data, profile));
  data = envelope(notes); data.choices[0].finish_reason = 'content_filter';
  assert.throws(() => providerResponseText(data, profile));
  data = envelope(notes); data.usage = { completion_tokens_details: { reasoning_tokens: 5 } };
  assert.throws(() => providerResponseText(data, profile));
  for (const patch of [{ refusal: 'No' }, { tool_calls: [{}] }, { function_call: {} }, { reasoning_content: 'thought' }, { reasoning: 'thought' }]) {
    const value = envelope(notes); Object.assign(value.choices[0].message, patch);
    assert.throws(() => providerResponseText(value, profile));
  }
  assert.throws(() => providerResponseText({ choices: [] }, profile));
});

test('detailed notes retain worked steps and exact grounding; invented evidence and notes-as-homework fail', () => {
  assert.equal(validateLessonPayload(payload), payload);
  assert.equal(validateLessonResult(notes, payload), notes);
  for (const patch of [{ evidence: 'påhittat' }, { sourceIDs: ['unknown'] }, { heading: '' },
    { body: 'x'.repeat(8001) }, { sourceIDs: [id, id] }, { slides: [] }]) {
    assert.throws(() => validateLessonResult({ ...notes, sections: [{ ...notes.sections[0], ...patch }] }, payload));
  }
  assert.throws(() => validateLessonResult({ ...notes, candidates: [{ ...notes.candidates[0], kind: 'note' }] }, payload));
  assert.throws(() => validateLessonPayload({ ...payload, mode: 'everyday' }));
  assert.throws(() => validateLessonPayload({ ...payload, fragments: [{ ...payload.fragments[0], text: 'å'.repeat(1751) }] }));
  assert.throws(() => validateAskResult({ answer: 'test', action: 'create' }));
  assert.throws(() => validateAskResult({ answer: '' }));
});

async function fixture(t, { model = 'qwen/qwen3.8-27b', fetchImpl, interval = 60 } = {}) {
  let calls = 0;
  const config = { ...configFor(model), requestsPerMinute: 60, lessonIntervalSeconds: interval };
  const server = createMioServer({ config, fetchImpl: async (url, init) => {
    calls++; return fetchImpl ? fetchImpl(url, init) : Response.json(envelope(notes));
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return { calls: () => calls, send: (value = payload, auth = token) => fetch(`http://127.0.0.1:${server.address().port}/v1/lesson-notes`, {
    method: 'POST', headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' }, body: JSON.stringify(value)
  }) };
}

test('lesson HTTP contract authenticates, validates and adds server-owned provenance and pacing', async t => {
  const f = await fixture(t, { interval: 120 });
  assert.equal((await f.send(payload, 'wrong')).status, 401);
  assert.equal((await f.send({ ...payload, mode: 'everyday' })).status, 400);
  assert.equal(f.calls(), 0);
  const response = await f.send(); assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.sections, notes.sections);
  assert.deepEqual(body.candidates, notes.candidates);
  assert.deepEqual(body.metadata, { provider: 'groq', model: 'qwen/qwen3.8-27b', promptVersion: '2026-10-13.2', lessonIntervalSeconds: 120 });
  assert.equal(f.calls(), 1);
});

test('incompatible model fails locally without spending a request', async t => {
  const f = await fixture(t, { model: 'openai/gpt-oss-20b' });
  const response = await f.send(); assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: 'task_configuration_invalid' });
  assert.equal(f.calls(), 0);
});

test('upstream rejection is a compatibility error, not permission to remove strict parameters', async t => {
  const f = await fixture(t, { fetchImpl: () => new Response('private details', { status: 400 }) });
  const response = await f.send(); assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: 'provider_parameters' });
  assert.equal(f.calls(), 1);
});

test('quota Retry-After is bounded, forwarded and never automatically retried', async t => {
  const f = await fixture(t, { fetchImpl: () => new Response('private quota data', { status: 429, headers: { 'Retry-After': '123' } }) });
  const response = await f.send(); assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '123');
  assert.deepEqual(await response.json(), { error: 'provider_quota' });
  assert.equal(f.calls(), 1);
});
