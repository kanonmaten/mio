import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { providerRequest, providerResponseText, providerProfile } from '../src/provider.mjs';
import { createMioServer, loadConfig } from '../src/server.mjs';
import { validateLessonPayload, validateLessonResult, validateAskResult } from '../src/analysis.mjs';

const token = 'fixture_gateway_token_01234567890123456789';
const id = '00000000-0000-0000-0000-000000000001:0';
const payload = { mode: 'lesson', timeZone: 'Europe/Stockholm', fragments: [
  { id, text: 'Procent betyder hundradelar. 20 procent av 50 är 0,20 gånger 50 = 10. Gör uppgift 7 till fredag.', occurredAt: '2026-09-28T08:00:00Z' }
] };
const notes = { candidates: [{ kind: 'task', title: 'Gör uppgift 7', body: 'Till fredag.', scheduledAt: null,
  sourceIDs: [id], evidence: 'Gör uppgift 7 till fredag.' }], sections: [{ heading: 'Procent och beräkning',
  body: 'Procent betyder hundradelar.\n1. Skriv 20 % som 0,20.\n2. Multiplicera med 50.\n3. Resultatet är 10.',
  sourceIDs: [id], evidence: '20 procent av 50 är 0,20 gånger 50 = 10.' }], uncertainties: [] };
const configs = [
  ['openai', 'gpt-6-luna', 'OPENAI_API_KEY', 'https://api.openai.com/v1/responses', 'responses'],
  ['groq', 'qwen/qwen3.8-27b', 'GROQ_API_KEY', 'https://api.groq.com/openai/v1/chat/completions', 'chat'],
  ['vercel', 'openai/gpt-6-luna', 'VERCEL_AI_GATEWAY_API_KEY', 'https://ai-gateway.vercel.sh/v1/responses', 'responses'],
  ['gemini', 'gemini-2.5-flash', 'GEMINI_API_KEY', 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions', 'chat'],
  ['anthropic', 'claude-haiku-4-5', 'ANTHROPIC_API_KEY', 'https://api.anthropic.com/v1/messages', 'anthropic'],
  ['openrouter', 'openai/gpt-6-luna', 'OPENROUTER_API_KEY', 'https://openrouter.ai/api/v1/chat/completions', 'chat'],
  ['mistral', 'mistral-small-latest', 'MISTRAL_API_KEY', 'https://api.mistral.ai/v1/chat/completions', 'chat'],
  ['deepseek', 'deepseek-flash', 'DEEPSEEK_API_KEY', 'https://api.deepseek.com/responses', 'responses'],
  ['custom', 'host/model:version', 'MIO_AI_API_KEY', 'https://inference.example/v1/chat/completions', 'chat']
];
function configFor(provider, model, key) {
  return loadConfig({ MIO_AI_PROVIDER: provider, MIO_AI_MODEL: model, [key]: 'fixture-key',
    OPENAI_API_KEY: key === 'OPENAI_API_KEY' ? 'fixture-key' : 'must-not-use-other-vendor-key',
    MIO_GATEWAY_TOKEN: token, MIO_AI_BASE_URL: 'https://inference.example/v1', MIO_AI_COMPATIBILITY: 'chat-none-strict' });
}
function envelope(wire, value) {
  const text = JSON.stringify(value);
  if (wire === 'chat') return { choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: text } }] };
  if (wire === 'anthropic') return { stop_reason: 'end_turn', content: [{ type: 'text', text }] };
  return { status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }] };
}
for (const [provider, model, key, url, wire] of configs) {
  test(`${provider}: correct secret, endpoint, strict schema, temperature and reasoning policy`, () => {
    const config = configFor(provider, model, key);
    assert.equal(config.apiKey, 'fixture-key');
    for (const mode of ['ask', 'analyze', 'lesson']) {
      const request = providerRequest({ config, mode, payload });
      assert.equal(request.url, url);
      assert.equal(request.body.temperature, 0);
      assert.equal(request.body.model, model);
      if (provider === 'vercel') assert.deepEqual(request.body.providerOptions.gateway.only, ['openai']);
      assert.ok(!JSON.stringify(request).includes(token));
      assert.ok(!JSON.stringify(request).includes('must-not-use-other-vendor-key'));
      const format = wire === 'responses' ? request.body.text.format : wire === 'chat'
        ? request.body.response_format.json_schema : request.body.output_config.format;
      assert.equal(format.schema.additionalProperties, false);
      assert.deepEqual(format.schema.required, Object.keys(format.schema.properties));
      if (wire !== 'anthropic') assert.equal(format.strict, true);
      if (wire === 'responses') assert.deepEqual(request.body.reasoning, { effort: 'none' });
      else if (wire === 'anthropic') assert.deepEqual(request.body.thinking, { type: 'disabled' });
      else if (provider === 'openrouter') {
        assert.deepEqual(request.body.reasoning, { enabled: false });
        assert.equal(request.body.provider.require_parameters, true);
        assert.equal(request.body.provider.allow_fallbacks, false);
        assert.deepEqual(request.body.provider.only, ['openai']);
      } else assert.equal(request.body.reasoning_effort, 'none');
      assert.equal(providerResponseText(envelope(wire, notes), request.profile), JSON.stringify(notes));
    }
  });
}

test('unknown and mandatory-thinking models fail before an API request is built', () => {
  for (const [provider, model] of [['groq', 'openai/gpt-oss-20b'], ['groq', 'invented'],
    ['openai', 'gpt-6-astra'], ['gemini', 'gemini-2.5-pro'], ['gemini', 'gemini-3-flash'],
    ['anthropic', 'claude-opus-4-7'], ['deepseek', 'deepseek-reasoner']]) {
    assert.throws(() => providerProfile({ provider, model }), /provider_model_incompatible/u);
  }
  assert.throws(() => providerProfile({ provider: 'custom', model: 'test' }));
});

test('custom endpoint requires explicit compatibility and HTTPS without credentials or redirect tricks', () => {
  for (const baseURL of ['http://example.com/v1', 'https://user:pass@example.com/v1',
    'https://example.com/v1?key=private', 'https://example.com/#x', 'https://localhost/v1',
    'https://127.0.0.1/v1', 'https://[::1]/v1', 'https://example.com:444/v1']) {
    assert.throws(() => providerProfile({ provider: 'custom', model: 'model', compatibility: 'chat-none-strict', baseURL }));
  }
});

test('neutral model wins; non-OpenAI presets never reuse legacy OpenAI credentials or model', () => {
  assert.equal(loadConfig({ OPENAI_API_KEY: 'fixture', MIO_GATEWAY_TOKEN: token,
    MIO_OPENAI_MODEL: 'gpt-6-luna' }).model, 'gpt-6-luna');
  const env = { MIO_AI_PROVIDER: 'groq', MIO_GATEWAY_TOKEN: token, OPENAI_API_KEY: 'fixture', MIO_OPENAI_MODEL: 'gpt-6-luna' };
  assert.throws(() => loadConfig(env));
  assert.throws(() => loadConfig({ ...env, GROQ_API_KEY: 'fixture' }));
  assert.equal(loadConfig({ ...env, GROQ_API_KEY: 'fixture', MIO_AI_MODEL: 'qwen/qwen3.8-27b' }).model, 'qwen/qwen3.8-27b');
});

test('all response adapters reject truncation, refusals, tools and observable reasoning', () => {
  for (const wire of ['responses', 'chat', 'anthropic']) {
    let data = envelope(wire, notes);
    if (wire === 'responses') data.status = 'incomplete';
    if (wire === 'chat') data.choices[0].finish_reason = 'length';
    if (wire === 'anthropic') data.stop_reason = 'max_tokens';
    assert.throws(() => providerResponseText(data, { wire }));
    data = envelope(wire, notes);
    data.usage = { output_tokens_details: { reasoning_tokens: 5 } };
    assert.throws(() => providerResponseText(data, { wire }));
  }
  for (const patch of [{ refusal: 'No' }, { tool_calls: [{}] }, { reasoning_content: 'thought' }]) {
    const data = envelope('chat', notes); Object.assign(data.choices[0].message, patch);
    assert.throws(() => providerResponseText(data, { wire: 'chat' }));
  }
  const refusal = envelope('responses', notes); refusal.output[0].content.push({ type: 'refusal', refusal: 'No' });
  assert.throws(() => providerResponseText(refusal));
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
  const config = { ...configFor('groq', model, 'GROQ_API_KEY'), requestsPerMinute: 60, lessonIntervalSeconds: interval };
  const server = createMioServer({ config, fetchImpl: async (url, init) => {
    calls++; return fetchImpl ? fetchImpl(url, init) : Response.json(envelope('chat', notes));
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
  assert.deepEqual(body.metadata, { provider: 'groq', model: 'qwen/qwen3.8-27b', promptVersion: '2026-09-28.1', lessonIntervalSeconds: 120 });
  assert.equal(f.calls(), 1);
});

test('incompatible model fails locally without spending a request', async t => {
  const f = await fixture(t, { model: 'openai/gpt-oss-20b' });
  const response = await f.send(); assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: 'provider_model_incompatible' });
  assert.equal(f.calls(), 0);
});

test('upstream rejection is a compatibility error, not permission to remove strict parameters', async t => {
  const f = await fixture(t, { fetchImpl: () => new Response('private details', { status: 400 }) });
  const response = await f.send(); assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: 'provider_model_incompatible' });
  assert.equal(f.calls(), 1);
});

test('quota Retry-After is bounded, forwarded and never automatically retried', async t => {
  const f = await fixture(t, { fetchImpl: () => new Response('private quota data', { status: 429, headers: { 'Retry-After': '123' } }) });
  const response = await f.send(); assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '123');
  assert.deepEqual(await response.json(), { error: 'upstream_unavailable' });
  assert.equal(f.calls(), 1);
});
