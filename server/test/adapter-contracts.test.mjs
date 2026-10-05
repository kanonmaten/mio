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
const config = (provider, model, adapterOptions = {}) => ({ provider, model, apiKey: 'synthetic-secret', adapterOptions,
  ...(provider === 'custom' ? { compatibility: 'chat-none-strict', baseURL: 'https://synthetic.example/v1' } : {}) });
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
function response(wire, patch = {}) {
  if (wire === 'gemini') return { modelVersion: 'gemini-2.5-flash', responseId: 'generation_123',
    candidates: [{ index: 0, finishReason: 'STOP', content: { role: 'model', parts: [{ text: '{"label":"a"}' }] } }],
    usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 3, totalTokenCount: 13, thoughtsTokenCount: 0 }, ...patch };
  if (wire === 'anthropic') return { id: 'msg_123', model: 'claude-haiku-4-5-20251001', role: 'assistant',
    stop_reason: 'end_turn', content: [{ type: 'text', text: '{"label":"a"}' }],
    usage: { input_tokens: 10, output_tokens: 3, cache_read_input_tokens: 2 }, ...patch };
  if (wire === 'responses') return { id: 'resp_123', model: 'returned-model-123', status: 'completed',
    output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '{"label":"a"}' }] }],
    usage: { input_tokens: 10, output_tokens: 3, total_tokens: 13, output_tokens_details: { reasoning_tokens: 0 } }, ...patch };
  return { id: 'completion_123', model: 'returned-model-123',
    choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: '{"label":"a"}' } }],
    usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13, completion_tokens_details: { reasoning_tokens: 0 } }, ...patch };
}

test('exact catalog rejects invented snapshots even within a retained model family', () => {
  for (const [provider, model] of [['openai', 'gpt-4.1-2099-99-99'], ['openai', 'gpt-6-luna-2026-09-01'],
    ['anthropic', 'claude-haiku-4-5-20999999'], ['vercel', 'openai/gpt-4.1-2025-04-14'],
    ['openrouter', 'openai/gpt-4o-2024-05-13']]) assert.throws(() => providerProfile(config(provider, model)));
});

test('reviewed exact snapshots expose per-model policy and separate live verification', () => {
  for (const [provider, model] of [['openai', 'gpt-5.1-2025-11-13'], ['openai', 'gpt-5.2-2025-12-11'],
    ['openai', 'gpt-5.4-2026-03-05'], ['openai', 'gpt-4.1-mini-2025-04-14'],
    ['anthropic', 'claude-opus-4-5-20251101'], ['openrouter', 'openai/gpt-4o-2024-08-06']]) {
    const profile = providerProfile(config(provider, model));
    assert.equal(profile.requestedModel, model);
    assert.deepEqual(profile.capabilities, ['reasoning-off', 'temperature-zero', 'strict-json']);
    assert.equal(profile.contractReview.liveTested, false);
    assert.ok(profile.contractReview.sources.every(url => url.startsWith('https://')));
  }
});

test('unestablished strict or reasoning-off contracts fail locally without a substitute model', () => {
  for (const [provider, model] of [['mistral', 'mistral-small-latest'], ['mistral', 'mistral-medium-latest'],
    ['mistral', 'mistral-large-latest'], ['deepseek', 'deepseek-flash'], ['deepseek', 'deepseek-v4-pro'],
    ['openrouter', 'openai/gpt-6-luna'], ['vercel', 'openai/gpt-5.1']]) {
    assert.throws(() => providerRequest({ config: config(provider, model), mode: 'ask', payload: { question: 'Synthetic' } }));
  }
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
  assert.equal(tasks.createTaskRequest('analyze-v2', {}).promptVersion, '2026-09-30.1');
  assert.deepEqual(tasks.validateTaskResult('ask', '{"answer":"Syntetiskt svar"}', {}), { answer: 'Syntetiskt svar' });
  for (const [mode, text, error] of [['ask', '{"answer":"x","action":"create"}', 'invalid_upstream_answer'],
    ['analyze', '{}', 'invalid_analysis_result'], ['lesson', '{}', 'invalid_lesson_result'],
    ['lesson', 'invalid JSON private text', 'invalid_lesson_result']]) {
    assert.throws(() => tasks.validateTaskResult(mode, text, {}), new RegExp(`^Error: ${error}$`, 'u'));
  }
  assert.throws(() => tasks.createTaskRequest('unknown', {}));
});

const supported = [
  ['openai', 'gpt-6-luna', 'responses', 'https://api.openai.com/v1/responses'],
  ['groq', 'qwen/qwen3.8-27b', 'chat', 'https://api.groq.com/openai/v1/chat/completions'],
  ['vercel', 'openai/gpt-6-luna', 'responses', 'https://ai-gateway.vercel.sh/v1/responses'],
  ['gemini', 'gemini-2.5-flash', 'gemini', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent'],
  ['anthropic', 'claude-haiku-4-5', 'anthropic', 'https://api.anthropic.com/v1/messages'],
  ['openrouter', 'openai/gpt-4.1', 'chat', 'https://openrouter.ai/api/v1/chat/completions'],
  ['custom', 'synthetic/model:version', 'chat', 'https://synthetic.example/v1/chat/completions']
];
for (const [provider, model, wire, url] of supported) {
  test(`${provider} generic adapter preserves explicit native generation contract without task information`, () => {
    const request = build(config(provider, model), generic());
    assert.equal(request.url, url);
    assert.equal(request.profile.requestedModel, model);
    assert.ok(!JSON.stringify(request.body).includes('mio_'));
    if (wire === 'gemini') {
      assert.equal(request.body.generationConfig.temperature, 0);
      assert.equal(request.body.generationConfig.maxOutputTokens, 321);
      assert.equal(request.body.generationConfig.responseMimeType, 'application/json');
      assert.equal(request.body.generationConfig.responseJsonSchema.additionalProperties, false);
      assert.deepEqual(request.body.generationConfig.thinkingConfig, { thinkingBudget: 0 });
      assert.equal(request.headers['x-goog-api-key'], 'synthetic-secret');
      assert.equal(request.body.systemInstruction.parts[0].text, 'Extract one label.');
      assert.equal(request.body.contents[0].parts[0].text, 'Synthetic example.');
    } else {
      assert.equal(request.body.model, model);
      assert.equal(request.body.temperature, 0);
      if (wire === 'anthropic') {
        assert.equal(request.body.max_tokens, 321);
        assert.deepEqual(request.body.thinking, { type: 'disabled' });
        assert.equal(request.body.output_config.format.schema.additionalProperties, false);
        assert.equal(request.headers['anthropic-version'], '2023-06-01');
      } else if (wire === 'responses') {
        assert.equal(request.body.max_output_tokens, 321);
        assert.deepEqual(request.body.reasoning, { effort: 'none' });
        assert.equal(request.body.store, false);
        assert.equal(request.body.text.format.strict, true);
        assert.deepEqual(request.body.tools, []);
      } else {
        assert.equal(request.body.max_tokens, 321);
        assert.equal(request.body.response_format.json_schema.strict, true);
        assert.equal(request.body.stream, false);
        if (provider === 'openrouter') {
          assert.equal(request.body.provider.require_parameters, true);
          assert.equal(request.body.provider.allow_fallbacks, false);
          assert.deepEqual(request.body.provider.only, ['openai']);
        } else assert.equal(request.body.reasoning_effort, 'none');
      }
    }
    assert.equal(normalize(response(wire), request.profile).text, '{"label":"a"}');
  });
}

test('plain direct OpenAI profile does not send unsupported reasoning controls', () => {
  const request = build(config('openai', 'gpt-4.1'), generic());
  assert.equal(Object.hasOwn(request.body, 'reasoning'), false);
  assert.equal(request.body.temperature, 0);
  assert.equal(request.body.text.format.strict, true);
});

test('adapter cannot weaken policy, allow tools or silently discard schema keywords', () => {
  for (const patch of [{ reasoning: 'hidden' }, { temperature: 1 }, { tools: 'auto' }, { unknown: false }]) {
    assert.throws(() => build(config('openai', 'gpt-6-luna'), { ...generic(), policy: { ...generic().policy, ...patch } }));
  }
  const schema = generic(); schema.structuredOutput.strict = false;
  assert.throws(() => build(config('openai', 'gpt-6-luna'), schema));
  const unsupported = generic(); unsupported.structuredOutput.schema.properties.label.maxLength = 40;
  assert.throws(() => build(config('anthropic', 'claude-haiku-4-5'), unsupported), /provider_options_incompatible/u);
  assert.equal(unsupported.structuredOutput.schema.properties.label.maxLength, 40);
});

test('native public routing and retention controls are validated and forwarded exactly', () => {
  const router = build(config('openrouter', 'openai/gpt-4.1', { dataCollection: 'deny', zeroDataRetention: true }), generic());
  assert.equal(router.body.provider.data_collection, 'deny');
  assert.equal(router.body.provider.zdr, true);
  const vercel = build(config('vercel', 'openai/gpt-6-luna', { zeroDataRetention: true, disallowPromptTraining: true }), generic());
  assert.deepEqual(vercel.body.providerOptions.gateway,
    { only: ['openai'], zeroDataRetention: true, disallowPromptTraining: true });
  const anthropic = build(config('anthropic', 'claude-haiku-4-5', { serviceTier: 'standard_only' }), generic());
  assert.equal(anthropic.body.service_tier, 'standard_only');
  for (const [provider, model, opts] of [['openai', 'gpt-6-luna', { apiKey: 'private' }],
    ['gemini', 'gemini-2.5-flash', { safetySettings: [] }], ['vercel', 'openai/gpt-6-luna', { only: ['other'] }],
    ['openrouter', 'openai/gpt-4.1', { allowFallbacks: true }], ['anthropic', 'claude-haiku-4-5', { serviceTier: 'private' }],
    ['custom', 'synthetic/model', { headers: { Secret: 'x' } }]]) {
    assert.throws(() => providerProfile(config(provider, model, opts)), /provider_options_incompatible/u);
  }
});

test('normalization retains requested and returned identity, numeric usage and bounded provenance only', () => {
  const profile = providerProfile(config('openai', 'gpt-6-luna'));
  const result = normalize(response('responses'), profile, new Headers({ 'x-request-id': 'req_abc', 'x-private': 'secret' }));
  assert.deepEqual(result, { text: '{"label":"a"}', finish: 'completed', refusal: false,
    requestedModel: 'gpt-6-luna', returnedModel: 'returned-model-123',
    usage: { inputTokens: 10, outputTokens: 3, totalTokens: 13, reasoningTokens: 0 },
    provenance: { responseID: 'resp_123', requestID: 'req_abc' } });
  const unsafe = normalize(response('responses', { model: 'private prompt\n' + 'x'.repeat(180), id: 'url?secret=1',
    usage: { input_tokens: -1, output_tokens: '3', total_tokens: Number.POSITIVE_INFINITY } }), profile,
    new Headers({ 'x-request-id': 'private?token=1' }));
  assert.equal(unsafe.returnedModel, undefined);
  assert.equal(unsafe.usage, undefined);
  assert.equal(unsafe.provenance, undefined);
});

for (const wire of ['responses', 'chat', 'anthropic', 'gemini']) {
  test(`${wire} distinguishes refusal/truncation and rejects tools, thinking and malformed success`, () => {
    const profile = { wire, requestedModel: 'requested' };
    let refusal = response(wire), truncated = response(wire), thinking = response(wire), tools = response(wire);
    if (wire === 'responses') {
      refusal.output[0].content = [{ type: 'refusal', refusal: 'private refusal text' }];
      truncated.status = 'incomplete'; truncated.incomplete_details = { reason: 'max_output_tokens' };
      thinking.output.unshift({ type: 'reasoning', content: [] }); tools.output.push({ type: 'function_call', arguments: '{}' });
    } else if (wire === 'chat') {
      refusal.choices[0].message.refusal = 'private refusal text';
      truncated.choices[0].finish_reason = 'length'; thinking.choices[0].message.reasoning_content = 'private thought';
      tools.choices[0].message.tool_calls = [{ type: 'function' }];
    } else if (wire === 'anthropic') {
      refusal.stop_reason = 'refusal'; truncated.stop_reason = 'max_tokens';
      thinking.content.unshift({ type: 'thinking', thinking: '' }); tools.content.push({ type: 'tool_use' });
    } else {
      refusal = { promptFeedback: { blockReason: 'SAFETY' } }; truncated.candidates[0].finishReason = 'MAX_TOKENS';
      thinking.candidates[0].content.parts[0].thought = true;
      tools.candidates[0].content.parts.push({ functionCall: { name: 'private_tool' } });
    }
    const r = normalize(refusal, profile);
    assert.equal(r.finish, 'refused'); assert.equal(r.refusal, true); assert.equal(r.text, null);
    assert.ok(!JSON.stringify(r).includes('private refusal'));
    assert.equal(normalize(truncated, profile).finish, 'truncated');
    for (const invalid of [thinking, tools, {}]) assert.throws(() => normalize(invalid, profile));
    const positive = response(wire);
    if (wire === 'gemini') positive.usageMetadata.thoughtsTokenCount = 1;
    else positive.usage = { completion_tokens_details: { reasoning_tokens: 1 } };
    assert.throws(() => normalize(positive, profile), error => error.category === 'provider_parameters');
    assert.throws(() => providerResponseText(truncated, profile));
  });
}

test('safe error normalization preserves distinct fixed categories without provider text', () => {
  for (const [status, data, category] of [[401, {}, 'provider_authentication'], [403, {}, 'provider_account'],
    [402, {}, 'provider_account'], [404, {}, 'provider_model_unavailable'], [400, {}, 'provider_parameters'],
    [422, {}, 'provider_parameters'], [429, {}, 'provider_quota'], [529, {}, 'provider_infrastructure'],
    [400, { error: { code: 'model_not_found' } }, 'provider_model_unavailable'],
    [400, { error: { type: 'authentication_error' } }, 'provider_authentication']]) {
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
  const profile = providerProfile(config('openai', 'gpt-6-luna'));
  for (const value of ['https://private.example/path', 'http://private.example/path', 'sk-private-token', 'sk_proj_private', 'gsk_private']) {
    const result = normalize(response('responses', { id: value, model: value }), profile,
      new Headers({ 'x-request-id': value }));
    assert.equal(result.returnedModel, undefined);
    assert.equal(result.provenance, undefined);
    assert.ok(!JSON.stringify(result).includes(value));
  }
});

test('native Gemini blocked candidates can omit content without masquerading as malformed success', () => {
  const profile = providerProfile(config('gemini', 'gemini-2.5-flash'));
  const result = normalize({ candidates: [{ index: 0, finishReason: 'SAFETY' }], responseId: 'generation_123' }, profile);
  assert.equal(result.finish, 'refused');
  assert.equal(result.text, null);
  assert.equal(result.refusal, true);
});

test('native provider error codes retain category when generic HTTP 400 obscures it', () => {
  for (const [data, category] of [
    [{ error: { status: 'UNAUTHENTICATED', message: 'private body' } }, 'provider_authentication'],
    [{ error: { status: 'PERMISSION_DENIED' } }, 'provider_account'],
    [{ error: { status: 'RESOURCE_EXHAUSTED' } }, 'provider_quota'],
    [{ error: { status: 'NOT_FOUND' } }, 'provider_model_unavailable'],
    [{ error: { code: 'insufficient_quota' } }, 'provider_account'],
    [{ error: { status: 'INVALID_ARGUMENT', details: [{ reason: 'API_KEY_INVALID' }] } }, 'provider_authentication']
  ]) assert.deepEqual(normalizeError({ status: 400, data }), { category });
  // OpenAI reports exhausted billing as HTTP 429; retrying after a delay cannot help.
  assert.deepEqual(normalizeError({ status: 429, data: { error: { code: 'insufficient_quota' } } }), { category: 'provider_account' });
});

test('operator asserted custom models cannot be URLs or accidentally copied credentials', () => {
  for (const model of ['https://private.example/model', 'sk-private-token', 'gsk_private']) {
    assert.throws(() => build(config('custom', model), generic()), /provider_model_incompatible/u);
  }
  const request = build(config('custom', 'host/model:version'), generic());
  assert.equal(request.body.model, 'host/model:version');
});

test('schema scalar values cannot silently change during JSON serialization', () => {
  for (const enumValue of [Number.NaN, Number.POSITIVE_INFINITY, undefined]) {
    const generation = generic();
    generation.structuredOutput.schema.properties.label = { type: 'number', enum: [enumValue] };
    assert.throws(() => build(config('openai', 'gpt-6-luna'), generation), /provider_options_incompatible/u);
  }
});
