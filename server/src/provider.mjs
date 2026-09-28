import { ASK_SYSTEM, ANALYSIS_SYSTEM, LESSON_SYSTEM } from './prompts.mjs';
import { ANALYSIS_FORMAT, LESSON_FORMAT, ASK_FORMAT } from './analysis.mjs';

export const PROVIDERS = {
  openai: ['https://api.openai.com/v1', 'OPENAI_API_KEY', 'responses'],
  groq: ['https://api.groq.com/openai/v1', 'GROQ_API_KEY', 'chat'],
  vercel: ['https://ai-gateway.vercel.sh/v1', 'VERCEL_AI_GATEWAY_API_KEY', 'responses'],
  gemini: ['https://generativelanguage.googleapis.com/v1beta/openai', 'GEMINI_API_KEY', 'chat'],
  anthropic: ['https://api.anthropic.com/v1', 'ANTHROPIC_API_KEY', 'anthropic'],
  openrouter: ['https://openrouter.ai/api/v1', 'OPENROUTER_API_KEY', 'chat'],
  mistral: ['https://api.mistral.ai/v1', 'MISTRAL_API_KEY', 'chat'],
  deepseek: ['https://api.deepseek.com', 'DEEPSEEK_API_KEY', 'responses'],
  custom: [null, 'MIO_AI_API_KEY', 'chat']
};
export class ProviderCompatibilityError extends Error {
  constructor() { super('provider_model_incompatible'); }
}
export function validateProvider(provider) {
  if (!Object.hasOwn(PROVIDERS, provider)) throw new ProviderCompatibilityError();
}
// Conservative catalog: adding a model requires checking all three capabilities,
// not merely recognizing its vendor prefix. Live quality/account access is separate.
const openaiNone = /^(gpt-6-(luna|sol)|gpt-5\.1|gpt-5\.2|gpt-5\.4)(-\d{4}-\d{2}-\d{2})?$/u;
const openaiPlain = /^(gpt-4\.1(-mini|-nano)?|gpt-4o(-mini)?)(-\d{4}-\d{2}-\d{2})?$/u;
export function providerProfile(config) {
  const provider = config.provider ?? 'openai';
  validateProvider(provider);
  const model = config.model;
  let supported = false;
  let plain = false;
  switch (provider) {
    case 'openai': supported = openaiNone.test(model) || (plain = openaiPlain.test(model)); break;
    case 'groq': supported = model === 'qwen/qwen3.8-27b'; break;
    case 'gemini': supported = ['gemini-2.5-flash', 'gemini-2.5-flash-lite'].includes(model); break;
    case 'anthropic': supported = /^(claude-(sonnet-4-5|haiku-4-5|opus-4-5))(-\d{8})?$/u.test(model); break;
    case 'mistral': supported = ['mistral-small-latest', 'mistral-medium-latest', 'mistral-large-latest'].includes(model); break;
    case 'deepseek': supported = ['deepseek-flash', 'deepseek-v4-pro'].includes(model); break;
    case 'vercel':
    case 'openrouter': {
      const selected = model?.startsWith('openai/') ? model.slice(7) : '';
      supported = openaiNone.test(selected) || (plain = openaiPlain.test(selected));
      break;
    }
    case 'custom':
      // Explicit operator assertion for an endpoint outside the reviewed catalog.
      // Never fall back to prompt-only JSON. Unsupported parameters must fail closed.
      supported = config.compatibility === 'chat-none-strict';
      break;
  }
  if (!supported) throw new ProviderCompatibilityError();
  let base = PROVIDERS[provider][0];
  if (provider === 'custom') {
    try {
      const url = new URL(config.baseURL);
      if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
          || url.port || !url.hostname.includes('.') || /^[\d.]+$/u.test(url.hostname)
          || url.hostname.endsWith('.local') || url.hostname.endsWith('.localhost')) throw new Error();
      base = url.href.replace(/\/$/u, '');
    } catch { throw new ProviderCompatibilityError(); }
  }
  return { provider, plain, base, wire: PROVIDERS[provider][2] };
}
export function providerRequest({ config, mode, payload }) {
  const profile = providerProfile(config);
  const format = mode === 'lesson' ? LESSON_FORMAT : mode === 'analyze' ? ANALYSIS_FORMAT : ASK_FORMAT;
  const instructions = mode === 'lesson' ? LESSON_SYSTEM : mode === 'analyze' ? ANALYSIS_SYSTEM : ASK_SYSTEM;
  const maxTokens = mode === 'ask' ? 1_000 : 3_000;
  const headers = { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' };
  const content = JSON.stringify(payload);
  if (profile.wire === 'responses') {
    return { url: `${profile.base}/responses`, headers, profile, body: {
      model: config.model, store: false, temperature: 0, max_output_tokens: maxTokens,
      ...(!profile.plain ? { reasoning: { effort: 'none' } } : {}),
      ...(profile.provider === 'vercel' ? { providerOptions: { gateway: { only: ['openai'] } } } : {}),
      instructions, text: { format },
      input: [{ role: 'user', content: [{ type: 'input_text', text: content }] }], tools: []
    } };
  }
  if (profile.wire === 'anthropic') {
    return { url: `${profile.base}/messages`, profile,
      headers: { 'x-api-key': config.apiKey, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
      body: { model: config.model, temperature: 0, max_tokens: maxTokens,
        thinking: { type: 'disabled' }, system: instructions,
        output_config: { format: { type: 'json_schema', schema: format.schema } },
        messages: [{ role: 'user', content }] }
    };
  }
  const { type, ...schema } = format;
  return { url: `${profile.base}/chat/completions`, headers, profile, body: {
    model: config.model, temperature: 0, max_tokens: maxTokens, stream: false,
    ...(profile.provider === 'openrouter'
      ? { reasoning: { enabled: false }, provider: { require_parameters: true, allow_fallbacks: false, only: ['openai'] } }
      : !profile.plain ? { reasoning_effort: 'none' } : {}),
    response_format: { type, json_schema: schema },
    messages: [{ role: 'system', content: instructions }, { role: 'user', content }]
  } };
}

export class ProviderResponseError extends Error {}
export function providerResponseText(data, profile = { wire: 'responses' }) {
  let answer;
  // Reject observable thinking even if an upstream silently ignores its off switch.
  if ((data?.usage?.output_tokens_details?.reasoning_tokens ?? 0) > 0
      || (data?.usage?.completion_tokens_details?.reasoning_tokens ?? 0) > 0) {
    throw new ProviderResponseError('provider_model_incompatible');
  }
  if (profile.wire === 'responses') {
    if (data?.status !== 'completed' || !Array.isArray(data.output)
        || data.output.some(item => item.type !== 'message' || item.role !== 'assistant'
          || !Array.isArray(item.content) || item.content.some(part => part.type !== 'output_text'))) {
      throw new ProviderResponseError('incomplete_upstream_response');
    }
    answer = data.output.flatMap(item => item.content).map(part => part.text).join('\n');
  } else if (profile.wire === 'anthropic') {
    if (data?.stop_reason !== 'end_turn' || !Array.isArray(data.content)
        || data.content.some(part => part.type !== 'text')) throw new ProviderResponseError('incomplete_upstream_response');
    answer = data.content.map(part => part.text).join('\n');
  } else {
    const choice = data?.choices?.[0];
    if (data?.choices?.length !== 1 || choice?.finish_reason !== 'stop' || choice?.message?.role !== 'assistant'
        || choice.message.refusal || choice.message.tool_calls?.length
        || choice.message.reasoning || choice.message.reasoning_content || choice.message.reasoning_details?.length) {
      throw new ProviderResponseError('incomplete_upstream_response');
    }
    answer = choice.message.content;
  }
  if (typeof answer !== 'string' || !answer.trim() || Buffer.byteLength(answer, 'utf8') > 24_000) {
    throw new ProviderResponseError('invalid_upstream_answer');
  }
  return answer;
}
