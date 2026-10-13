import assert from 'node:assert/strict';
import { test } from 'node:test';
import { providerProfile, providerRequest, providerResponseText } from '../src/provider.mjs';
const adapters = await import('../src/adapters.mjs').catch(error => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const tasks = await import('../src/tasks.mjs').catch(error => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const generic = () => ({
  messages: [{ role: 'system', content: 'Extract one label.' }, { role: 'user', content: 'Synthetic example.' }],
  structuredOutput: { type: 'json_schema', name: 'label', strict: true,
    schema: { type: 'object', properties: { label: { type: 'string' } }, required: ['label'], additionalProperties: false } },
  maxOutputTokens: 321,
  policy: { reasoning: 'off', temperature: 0, tools: 'none' }
});
const MODEL = 'qwen/qwen3.8-27b';
const config = (provider = 'groq', model = MODEL, adapterOptions = {}) => ({ provider, model, apiKey: 'synthetic-secret', adapterOptions });
const build = (...args) => {
  assert.equal(typeof adapters.buildProviderRequest, 'function', 'neutral request builder is required');
  return adapters.buildProviderRequest(...args);
};
const normalize = (...args) => {
  assert.equal(typeof adapters.normalizeProviderResponse, 'function', 'normalized response contract is required');
  return adapters.normalizeProviderResponse(...args);
};
const normalizeError = (...args) => {
  assert.equal(typeof adapters.normalizeProviderError, 'function', 'safe provider error contract is required');
  return adapters.normalizeProviderError(...args);
};
function response(patch = {}) {
  return { id: 'completion_123', model: 'returned-model-123',
    choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: '{"label":"a"}' } }],
    usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13, completion_tokens_details: { reasoning_tokens: 0 } }, ...patch };
}

test('exact catalog rejects invented snapshots and other providers without a substitute model', () => {
  for (const [provider, model] of [['groq', 'qwen/qwen3.8-27b-2099'], ['groq', 'qwen/qwen3.8'], ['groq', 'QWEN/QWEN3.8-27B'],
    ['openai', 'gpt-5.1-2025-11-13'], ['anthropic', 'claude-opus-4-5-20251101'], ['mistral', 'mistral-small-latest'],
    ['deepseek', 'deepseek-flash'], ['__proto__', MODEL], ['constructor', MODEL]]) {
    assert.throws(() => providerProfile(config(provider, model)));
    assert.throws(() => providerRequest({ config: config(provider, model), mode: 'ask', payload: { question: 'Synthetic' } }));
  }
});

test('reviewed Groq profile exposes policy, documentation sources and separate live verification', () => {
  const profile = providerProfile(config());
  assert.equal(profile.requestedModel, MODEL);
  assert.equal(profile.wire, 'chat');
  assert.deepEqual(profile.capabilities, ['reasoning-off', 'temperature-zero', 'strict-json']);
  assert.equal(profile.contractReview.liveTested, false);
  assert.ok(profile.contractReview.sources.length > 0);
  assert.ok(profile.contractReview.sources.every(url => url.startsWith('https://console.groq.com/')));
  assert.ok(Object.isFrozen(profile));
});

test('task definition owns prompt, schema, budget and validates domain independently', () => {
  assert.equal(typeof tasks.createTaskRequest, 'function');
  assert.equal(typeof tasks.validateTaskResult, 'function');
  const ask = tasks.createTaskRequest('ask', { question: 'Syntetisk fråga', context: [] });
  assert.equal(ask.maxOutputTokens, 1_000);
  assert.deepEqual(ask.policy, { reasoning: 'off', temperature: 0, tools: 'none' });
  assert.equal(ask.messages[1].content, '{"question":"Syntetisk fråga","context":[]}');
  assert.ok(Object.isFrozen(ask.policy));
  const lesson = tasks.createTaskRequest('lesson', { fragments: [] });
  assert.equal(lesson.maxOutputTokens, 3_000);
  assert.deepEqual(lesson.structuredOutput.schema.properties.candidates.items.properties.kind.enum, ['plan', 'task']);
  assert.equal(tasks.createTaskRequest('analyze-v2', {}).promptVersion, '2026-10-13.1');
  assert.deepEqual(tasks.validateTaskResult('ask', '{"answer":"Syntetiskt svar"}', {}), { answer: 'Syntetiskt svar' });
  for (const [mode, text, error] of [['ask', '{"answer":"x","action":"create"}', 'invalid_upstream_answer'],
    ['analyze', '{}', 'invalid_analysis_result'], ['lesson', '{}', 'invalid_lesson_result'],
    ['lesson', 'invalid JSON private text', 'invalid_lesson_result']]) {
    assert.throws(() => tasks.validateTaskResult(mode, text, {}), new RegExp(`^Error: ${error}$`, 'u'));
  }
  assert.throws(() => tasks.createTaskRequest('unknown', {}));
});

test('groq adapter preserves explicit native generation contract without task information', () => {
  const request = build(config(), generic());
  assert.equal(request.url, 'https://api.groq.com/openai/v1/chat/completions');
  assert.equal(request.profile.requestedModel, MODEL);
  assert.ok(!JSON.stringify(request.body).includes('mio_'));
  assert.equal(request.body.model, MODEL);
  assert.equal(request.body.temperature, 0);
  assert.equal(request.body.max_tokens, 321);
  assert.equal(request.body.response_format.type, 'json_schema');
  assert.equal(request.body.response_format.json_schema.strict, true);
  assert.equal(request.body.response_format.json_schema.schema.additionalProperties, false);
  assert.equal(request.body.stream, false);
  assert.equal(request.body.reasoning_effort, 'none');
  assert.equal(Object.hasOwn(request.body, 'tools'), false);
  assert.equal(request.headers.Authorization, 'Bearer synthetic-secret');
  assert.deepEqual(request.body.messages, generic().messages);
  assert.equal(normalize(response(), request.profile).text, '{"label":"a"}');
});

test('adapter cannot weaken policy, allow tools or silently discard schema keywords', () => {
  for (const patch of [{ reasoning: 'hidden' }, { temperature: 1 }, { tools: 'auto' }, { unknown: false }]) {
    assert.throws(() => build(config(), { ...generic(), policy: { ...generic().policy, ...patch } }));
  }
  const schema = generic(); schema.structuredOutput.strict = false;
  assert.throws(() => build(config(), schema));
});

test('Groq accepts no routing or retention options; any option is a configuration error', () => {
  for (const opts of [{ apiKey: 'private' }, { headers: { Secret: 'x' } }, { allowFallbacks: true }, [], 'x']) {
    assert.throws(() => providerProfile(config('groq', MODEL, opts)), /provider_options_incompatible/u);
  }
  assert.doesNotThrow(() => providerProfile(config('groq', MODEL, {})));
});

test('normalization retains requested and returned identity, numeric usage and bounded provenance only', () => {
  const profile = providerProfile(config());
  const result = normalize(response(), profile, new Headers({ 'x-request-id': 'req_abc', 'x-private': 'secret' }));
  assert.deepEqual(result, { text: '{"label":"a"}', finish: 'completed', refusal: false,
    requestedModel: MODEL, returnedModel: 'returned-model-123',
    usage: { inputTokens: 10, outputTokens: 3, totalTokens: 13, reasoningTokens: 0 },
    provenance: { responseID: 'completion_123', requestID: 'req_abc' } });
  const unsafe = normalize(response({ model: 'private prompt\n' + 'x'.repeat(180), id: 'url?secret=1',
    usage: { prompt_tokens: -1, completion_tokens: '3', total_tokens: Number.POSITIVE_INFINITY } }), profile,
    new Headers({ 'x-request-id': 'private?token=1' }));
  assert.equal(unsafe.returnedModel, undefined);
  assert.equal(unsafe.usage, undefined);
  assert.equal(unsafe.provenance, undefined);
});

test('chat wire distinguishes refusal/truncation and rejects tools, thinking and malformed success', () => {
  const profile = { wire: 'chat', requestedModel: 'requested' };
  const refusal = response(), filtered = response(), truncated = response(), thinking = response(),
    reasoning = response(), tools = response(), functionCall = response();
  refusal.choices[0].message.refusal = 'private refusal text';
  filtered.choices[0].finish_reason = 'content_filter';
  truncated.choices[0].finish_reason = 'length';
  thinking.choices[0].message.reasoning_content = 'private thought';
  reasoning.choices[0].message.reasoning = 'private thought';
  tools.choices[0].message.tool_calls = [{ type: 'function' }];
  functionCall.choices[0].message.function_call = { name: 'private_tool' };
  for (const value of [refusal, filtered]) {
    const r = normalize(value, profile);
    assert.equal(r.finish, 'refused'); assert.equal(r.refusal, true); assert.equal(r.text, null);
    assert.ok(!JSON.stringify(r).includes('private refusal'));
  }
  assert.equal(normalize(truncated, profile).finish, 'truncated');
  for (const invalid of [thinking, reasoning, tools, functionCall, {}, { choices: [] }]) assert.throws(() => normalize(invalid, profile));
  assert.equal(normalize(response({ choices: [{ finish_reason: 'stop', message: { role: 'assistant',
    content: '{"label":"a"}', reasoning_content: null } }] }), profile).text, '{"label":"a"}');
  const positive = response(); positive.usage = { completion_tokens_details: { reasoning_tokens: 1 } };
  assert.throws(() => normalize(positive, profile), error => error.category === 'provider_parameters');
  assert.throws(() => providerResponseText(truncated, profile));
});

test('safe error normalization preserves distinct fixed categories without provider text', () => {
  for (const [status, data, category] of [[401, {}, 'provider_authentication'], [403, {}, 'provider_account'],
    [402, {}, 'provider_account'], [404, {}, 'provider_model_unavailable'], [400, {}, 'provider_parameters'],
    [422, {}, 'provider_parameters'], [429, {}, 'provider_quota'], [529, {}, 'provider_infrastructure'],
    [400, { error: { code: 'model_not_found' } }, 'provider_model_unavailable'],
    [400, { error: { code: 'invalid_api_key' } }, 'provider_authentication'],
    [400, { error: { code: 'rate_limit_exceeded' } }, 'provider_quota']]) {
    assert.deepEqual(normalizeError({ status, data: { ...data, private: 'secret transcript' } }), { category });
  }
});

test('Retry-After accepts bounded seconds and HTTP dates and drops malformed values', () => {
  const now = Date.parse('2026-10-02T10:00:00Z');
  for (const [value, expected] of [['123', 123], ['99999999', 3600],
    ['Fri, 02 Oct 2026 10:02:00 GMT', 120], ['Fri, 02 Oct 2026 09:59:00 GMT', 0], ['-1', undefined],
    ['private-token', undefined], ['1.5', undefined]]) {
    const result = normalizeError({ status: 429, headers: new Headers({ 'retry-after': value }), now });
    assert.equal(result.category, 'provider_quota'); assert.equal(result.retryAfter, expected);
  }
});

test('operational metadata drops full URLs and common credential prefixes', () => {
  const profile = providerProfile(config());
  for (const value of ['https://private.example/path', 'http://private.example/path', 'sk-private-token', 'sk_proj_private', 'gsk_private']) {
    const result = normalize(response({ id: value, model: value }), profile, new Headers({ 'x-request-id': value }));
    assert.equal(result.returnedModel, undefined);
    assert.equal(result.provenance, undefined);
    assert.ok(!JSON.stringify(result).includes(value));
  }
});

test('models cannot be URLs or accidentally copied credentials', () => {
  for (const model of ['https://private.example/model', 'sk-private-token', 'gsk_private', 'nvapi-secret']) {
    assert.throws(() => build(config('groq', model), generic()), /provider_model_incompatible/u);
  }
});

test('schema scalar values cannot silently change during JSON serialization', () => {
  for (const enumValue of [Number.NaN, Number.POSITIVE_INFINITY, undefined]) {
    const generation = generic();
    generation.structuredOutput.schema.properties.label = { type: 'number', enum: [enumValue] };
    assert.throws(() => build(config(), generation), /provider_options_incompatible/u);
  }
});
