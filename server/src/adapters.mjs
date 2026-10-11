import { providerProfile, ProviderCompatibilityError } from './model-profiles.mjs';

const isObject = value => value && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
const sameKeys = (value, keys) => isObject(value) && Object.keys(value).length === keys.length
  && keys.every(key => Object.hasOwn(value, key));
const incompatible = () => { throw new ProviderCompatibilityError('provider_options_incompatible'); };

// This is the reviewed schema subset used by the current text contract. Reject
// extensions locally instead of deleting keywords or relying on SDK transforms.
function validateSchema(schema, depth = 0) {
  if (!isObject(schema) || depth > 20
      || Object.keys(schema).some(key => !['type', 'properties', 'required', 'additionalProperties', 'items', 'enum', 'description'].includes(key))) incompatible();
  const types = Array.isArray(schema.type) ? schema.type : [schema.type];
  if (!types.length || types.some(type => !['object', 'array', 'string', 'number', 'integer', 'boolean', 'null'].includes(type))
      || new Set(types).size !== types.length) incompatible();
  if (Object.hasOwn(schema, 'description') && typeof schema.description !== 'string') incompatible();
  if (Object.hasOwn(schema, 'enum') && (!Array.isArray(schema.enum) || !schema.enum.length
      || schema.enum.some(value => (!['string', 'number', 'boolean'].includes(typeof value) && value !== null)
        || (typeof value === 'number' && !Number.isFinite(value))))) incompatible();
  if (types.includes('object')) {
    if (!isObject(schema.properties) || schema.additionalProperties !== false || !Array.isArray(schema.required)
        || new Set(schema.required).size !== schema.required.length
        || schema.required.length !== Object.keys(schema.properties).length
        || schema.required.some(key => typeof key !== 'string' || !Object.hasOwn(schema.properties, key))) incompatible();
    for (const value of Object.values(schema.properties)) validateSchema(value, depth + 1);
  } else if (['properties', 'required', 'additionalProperties'].some(key => Object.hasOwn(schema, key))) incompatible();
  if (types.includes('array')) validateSchema(schema.items, depth + 1);
  else if (Object.hasOwn(schema, 'items')) incompatible();
}

function validateGeneration(generation) {
  if (!isObject(generation) || Object.keys(generation).some(key => !['messages', 'structuredOutput', 'maxOutputTokens', 'policy', 'promptVersion'].includes(key))
      || !sameKeys(generation.policy, ['reasoning', 'temperature', 'tools'])
      || generation.policy.reasoning !== 'off' || generation.policy.temperature !== 0 || generation.policy.tools !== 'none'
      || !Number.isSafeInteger(generation.maxOutputTokens) || generation.maxOutputTokens < 1 || generation.maxOutputTokens > 65_536
      || !Array.isArray(generation.messages) || !generation.messages.length) incompatible();
  let ordinary = false;
  for (const message of generation.messages) {
    if (!sameKeys(message, ['role', 'content']) || !['system', 'user', 'assistant'].includes(message.role)
        || typeof message.content !== 'string' || !message.content.trim()) incompatible();
    if (message.role === 'system' && ordinary) incompatible();
    if (message.role !== 'system') ordinary = true;
  }
  if (!ordinary) incompatible();
  const format = generation.structuredOutput;
  if (!sameKeys(format, ['type', 'name', 'strict', 'schema']) || format.type !== 'json_schema'
      || format.strict !== true || typeof format.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/u.test(format.name)
      || format.schema?.type !== 'object') incompatible();
  validateSchema(format.schema);
}

export function buildProviderRequest(config, generation) {
  const profile = providerProfile(config);
  validateGeneration(generation);
  if (profile.wire !== 'chat') incompatible();
  const { type, ...jsonSchema } = structuredClone(generation.structuredOutput);
  return { url: `${profile.base}/chat/completions`, profile,
    headers: { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' }, body: {
      model: profile.requestedModel, temperature: 0, max_tokens: generation.maxOutputTokens, stream: false,
      // Reasoning must be off, not hidden; responses that still carry reasoning are rejected below.
      ...(!profile.plain ? { reasoning_effort: 'none' } : {}),
      response_format: { type, json_schema: jsonSchema }, messages: generation.messages.map(message => ({ ...message }))
    } };
}

export class ProviderResponseError extends Error {
  constructor(category = 'provider_invalid_response') { super(category); this.category = category; }
}
const invalid = () => { throw new ProviderResponseError(); };
const reasoningViolation = () => { throw new ProviderResponseError('provider_parameters'); };
const safeID = (value, model = false) => typeof value === 'string'
  && (model ? /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/u : /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u).test(value)
  && !value.includes('://') && !/^(?:sk[-_]|gsk_|AIza|nvapi-)/iu.test(value) ? value : undefined;
const tokenCount = value => Number.isSafeInteger(value) && value >= 0 && value <= 1_000_000_000 ? value : undefined;
const header = (headers, name) => typeof headers?.get === 'function' ? headers.get(name)
  : isObject(headers) ? Object.entries(headers).find(([key]) => key.toLowerCase() === name)?.[1] : undefined;

function metadata(data, profile, headers) {
  const returnedModel = safeID(data?.model, true);
  const responseID = safeID(data?.id);
  const requestID = safeID(header(headers, 'x-request-id') ?? header(headers, 'request-id'));
  const raw = data?.usage;
  const values = {
    inputTokens: raw?.prompt_tokens,
    outputTokens: raw?.completion_tokens,
    totalTokens: raw?.total_tokens,
    reasoningTokens: raw?.completion_tokens_details?.reasoning_tokens,
    cachedInputTokens: raw?.prompt_tokens_details?.cached_tokens
  };
  const usage = Object.fromEntries(Object.entries(values).filter(([, value]) => tokenCount(value) !== undefined));
  return { ...(returnedModel ? { returnedModel } : {}),
    ...(Object.keys(usage).length ? { usage } : {}),
    ...(requestID || responseID ? { provenance: { ...(responseID ? { responseID } : {}), ...(requestID ? { requestID } : {}) } } : {}) };
}

export function normalizeProviderResponse(data, profile, headers) {
  if (!isObject(data) || !isObject(profile)) invalid();
  // Hiding reasoning text does not satisfy an explicit reasoning-off contract.
  for (const value of [data.usage?.output_tokens_details?.reasoning_tokens, data.usage?.completion_tokens_details?.reasoning_tokens]) {
    if (typeof value === 'number' && value > 0) reasoningViolation();
  }
  if (profile.wire !== 'chat') invalid();
  let finish = 'completed';
  if (!Array.isArray(data.choices) || data.choices.length !== 1) invalid();
  const choice = data.choices[0], message = choice?.message;
  if (!isObject(message) || message.role !== 'assistant' || message.tool_calls?.length || message.function_call) invalid();
  if (message.reasoning || message.reasoning_content || message.reasoning_details?.length) reasoningViolation();
  if (message.refusal || choice.finish_reason === 'content_filter') finish = 'refused';
  else if (choice.finish_reason === 'length') finish = 'truncated';
  else if (choice.finish_reason !== 'stop') invalid();
  let text = [message.content];
  if (finish === 'completed') {
    if (!text?.length || text.some(value => typeof value !== 'string')) invalid();
    text = text.join('\n');
    if (!text.trim() || Buffer.byteLength(text, 'utf8') > 24_000) invalid();
  } else text = null;
  return { text, finish, refusal: finish === 'refused', requestedModel: profile.requestedModel,
    ...metadata(data, profile, headers) };
}

export function normalizeProviderError({ status, data, headers, now = Date.now() }) {
  const code = data?.error?.code ?? data?.error?.type ?? data?.error?.status;
  let category;
  if (status === 401 || ['authentication_error', 'invalid_api_key', 'UNAUTHENTICATED'].includes(code)) category = 'provider_authentication';
  // Exhausted billing is an account problem, not a temporary quota; retrying cannot help.
  else if ([402, 403].includes(status) || ['permission_error', 'billing_hard_limit_reached', 'insufficient_quota', 'PERMISSION_DENIED'].includes(code)) category = 'provider_account';
  else if (status === 404 || ['model_not_found', 'model_not_available', 'not_found_error', 'NOT_FOUND'].includes(code)) category = 'provider_model_unavailable';
  else if (status === 429 || ['rate_limit_error', 'rate_limit_exceeded', 'RESOURCE_EXHAUSTED'].includes(code)) category = 'provider_quota';
  else if ([400, 422].includes(status) || ['invalid_request_error', 'unsupported_parameter'].includes(code)) category = 'provider_parameters';
  else category = 'provider_infrastructure';
  const value = header(headers, 'retry-after');
  let retryAfter;
  if (typeof value === 'string' && /^\d+$/u.test(value.trim())) retryAfter = Math.min(3_600, Number(value));
  else if (typeof value === 'string' && /^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/u.test(value)) {
    const date = Date.parse(value);
    if (Number.isFinite(date) && Number.isFinite(now)) retryAfter = Math.max(0, Math.min(3_600, Math.ceil((date - now) / 1_000)));
  }
  return { category, ...(retryAfter !== undefined ? { retryAfter } : {}) };
}
