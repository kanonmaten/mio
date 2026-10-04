export const PROVIDERS = Object.freeze({
  openai: Object.freeze(['https://api.openai.com/v1', 'OPENAI_API_KEY', 'responses']),
  groq: Object.freeze(['https://api.groq.com/openai/v1', 'GROQ_API_KEY', 'chat']),
  vercel: Object.freeze(['https://ai-gateway.vercel.sh/v1', 'VERCEL_AI_GATEWAY_API_KEY', 'responses']),
  gemini: Object.freeze(['https://generativelanguage.googleapis.com/v1beta', 'GEMINI_API_KEY', 'gemini']),
  anthropic: Object.freeze(['https://api.anthropic.com/v1', 'ANTHROPIC_API_KEY', 'anthropic']),
  openrouter: Object.freeze(['https://openrouter.ai/api/v1', 'OPENROUTER_API_KEY', 'chat']),
  mistral: Object.freeze(['https://api.mistral.ai/v1', 'MISTRAL_API_KEY', 'chat']),
  deepseek: Object.freeze(['https://api.deepseek.com', 'DEEPSEEK_API_KEY', 'responses']),
  custom: Object.freeze([null, 'MIO_AI_API_KEY', 'chat'])
});
export class ProviderCompatibilityError extends Error {
  constructor(category = 'provider_model_incompatible') {
    super(category); this.category = category;
  }
}
export function validateProvider(provider) {
  if (typeof provider !== 'string' || !Object.hasOwn(PROVIDERS, provider)) throw new ProviderCompatibilityError();
}
const CAPABILITIES = Object.freeze(['reasoning-off', 'temperature-zero', 'strict-json']);
const openai = new Map();
function addOpenAI(alias, snapshots, plain = false) {
  const reviewed = Object.freeze({ plain, schemaDialect: 'strict-json-schema',
    sources: Object.freeze([`https://developers.openai.com/api/docs/models/${alias}`,
      'https://developers.openai.com/api/docs/guides/latest-model']) });
  for (const id of [alias, ...snapshots]) openai.set(id, reviewed);
}
// Only IDs explicitly listed by the native model documentation are eligible.
addOpenAI('gpt-6-luna', []);
addOpenAI('gpt-6-sol', []);
addOpenAI('gpt-5.1', ['gpt-5.1-2025-11-13']);
addOpenAI('gpt-5.2', ['gpt-5.2-2025-12-11']);
addOpenAI('gpt-5.4', ['gpt-5.4-2026-03-05']);
addOpenAI('gpt-4.1', ['gpt-4.1-2025-04-14'], true);
addOpenAI('gpt-4.1-mini', ['gpt-4.1-mini-2025-04-14'], true);
addOpenAI('gpt-4.1-nano', ['gpt-4.1-nano-2025-04-14'], true);
addOpenAI('gpt-4o', ['gpt-4o-2024-08-06', 'gpt-4o-2024-11-20'], true);
addOpenAI('gpt-4o-mini', ['gpt-4o-mini-2024-07-18'], true);
const vercel = new Set(['openai/gpt-6-luna', 'openai/gpt-6-sol', 'openai/gpt-5.2', 'openai/gpt-5.4',
  'openai/gpt-4.1', 'openai/gpt-4.1-mini', 'openai/gpt-4.1-nano', 'openai/gpt-4o', 'openai/gpt-4o-mini']);
const router = new Set(['openai/gpt-4.1', 'openai/gpt-4.1-mini', 'openai/gpt-4.1-nano',
  'openai/gpt-4o', 'openai/gpt-4o-mini', 'openai/gpt-4o-2024-08-06', 'openai/gpt-4o-2024-11-20',
  'openai/gpt-4o-mini-2024-07-18']);
const claude = new Set(['claude-sonnet-4-5', 'claude-sonnet-4-5-20250929',
  'claude-haiku-4-5', 'claude-haiku-4-5-20251001', 'claude-opus-4-5', 'claude-opus-4-5-20251101']);
const gemini = new Set(['gemini-2.5-flash', 'gemini-2.5-flash-lite']);
const record = (schemaDialect, sources, plain = false) => ({ schemaDialect, sources, plain });
function reviewedModel(provider, model, compatibility) {
  switch (provider) {
    case 'openai': return openai.get(model);
    case 'groq': return model === 'qwen/qwen3.8-27b' ? record('strict-json-schema',
      ['https://console.groq.com/docs/structured-outputs', 'https://console.groq.com/docs/reasoning']) : undefined;
    case 'gemini': return gemini.has(model) ? record('gemini-json-schema',
      [`https://ai.google.dev/gemini-api/docs/models/${model}`,
        'https://ai.google.dev/gemini-api/docs/generate-content/thinking',
        'https://ai.google.dev/gemini-api/docs/generate-content/structured-output']) : undefined;
    case 'anthropic': return claude.has(model) ? record('anthropic-json-schema',
      ['https://platform.claude.com/docs/en/build-with-claude/structured-outputs',
        'https://platform.claude.com/docs/en/api/messages/create']) : undefined;
    case 'vercel': return vercel.has(model) ? { ...openai.get(model.slice(7)),
      sources: ['https://ai-gateway.vercel.sh/v1/models',
        'https://vercel.com/docs/ai-gateway/sdks-and-apis/responses', ...openai.get(model.slice(7)).sources] } : undefined;
    case 'openrouter': return router.has(model) ? { ...openai.get(model.slice(7)),
      sources: ['https://openrouter.ai/api/v1/models',
        'https://openrouter.ai/docs/guides/features/structured-outputs', ...openai.get(model.slice(7)).sources] } : undefined;
    // Retain their adapter boundaries; the exact existing profiles fail closed until mandatory
    // reasoning-off/strict-output semantics are established (separate from live model testing).
    case 'mistral':
    case 'deepseek': return undefined;
    case 'custom': return compatibility === 'chat-none-strict'
      ? record('strict-json-schema', [], false) : undefined;
  }
}
const isObject = value => value && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
function optionsFor(provider, input = {}) {
  if (!isObject(input)) throw new ProviderCompatibilityError('provider_options_incompatible');
  const allowed = provider === 'openrouter' ? ['dataCollection', 'zeroDataRetention']
    : provider === 'vercel' ? ['zeroDataRetention', 'disallowPromptTraining']
    : provider === 'anthropic' ? ['serviceTier'] : [];
  if (Object.keys(input).some(key => !allowed.includes(key))) throw new ProviderCompatibilityError('provider_options_incompatible');
  for (const [key, value] of Object.entries(input)) {
    const valid = key === 'serviceTier' ? ['auto', 'standard_only'].includes(value)
      : key === 'dataCollection' ? ['allow', 'deny'].includes(value) : typeof value === 'boolean';
    if (!valid) throw new ProviderCompatibilityError('provider_options_incompatible');
  }
  return Object.freeze({ ...input });
}
export function providerProfile(config) {
  const provider = config?.provider ?? 'openai';
  validateProvider(provider);
  const model = config?.model;
  if (typeof model !== 'string' || model.length > 128 || !/^[A-Za-z0-9][A-Za-z0-9._:/-]*$/u.test(model)
      || model.includes('://') || /^(?:sk[-_]|gsk_|AIza)/iu.test(model)) {
    throw new ProviderCompatibilityError();
  }
  const reviewed = reviewedModel(provider, model, config.compatibility);
  if (!reviewed) throw new ProviderCompatibilityError();
  const options = optionsFor(provider, config.adapterOptions);
  let base = PROVIDERS[provider][0];
  if (provider === 'custom') {
    try {
      const url = new URL(config.baseURL);
      if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.port
          || !url.hostname.includes('.') || /^[\d.]+$/u.test(url.hostname)
          || url.hostname.endsWith('.local') || url.hostname.endsWith('.localhost')) throw new Error();
      base = url.href.replace(/\/$/u, '');
    } catch { throw new ProviderCompatibilityError(); }
  }
  return Object.freeze({ provider, base, wire: PROVIDERS[provider][2], requestedModel: model,
    plain: reviewed.plain, schemaDialect: reviewed.schemaDialect, options, capabilities: CAPABILITIES,
    contractReview: Object.freeze({ reviewedAt: '2026-10-02',
      status: provider === 'custom' ? 'operator-asserted' : 'documentation-reviewed',
      sources: Object.freeze([...reviewed.sources]), liveTested: false }) });
}
