// Provider seam: one reviewed provider today (Groq, user decision 2026-10-11).
// Adding a provider later means one PROVIDERS entry, one reviewedModel case with
// documentation sources and, if its wire differs from chat completions, one adapter
// in adapters.mjs. A provider prefix or OpenAI-compatible URL is never proof of support.
export const PROVIDERS = Object.freeze({
  groq: Object.freeze(['https://api.groq.com/openai/v1', 'GROQ_API_KEY', 'chat'])
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
const record = (schemaDialect, sources, plain = false) => ({ schemaDialect, sources, plain });
function reviewedModel(provider, model) {
  switch (provider) {
    // Qwen 3.8 accepts reasoning_effort "none"; models that always think stay absent.
    case 'groq': return model === 'qwen/qwen3.8-27b' ? record('strict-json-schema',
      ['https://console.groq.com/docs/structured-outputs', 'https://console.groq.com/docs/reasoning']) : undefined;
  }
}
const isObject = value => value && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
function optionsFor(input = {}) {
  // Groq has no reviewed routing or retention options; any option is a configuration error.
  if (!isObject(input) || Object.keys(input).length) throw new ProviderCompatibilityError('provider_options_incompatible');
  return Object.freeze({});
}
export function providerProfile(config) {
  const provider = config?.provider ?? 'groq';
  validateProvider(provider);
  const model = config?.model;
  if (typeof model !== 'string' || model.length > 128 || !/^[A-Za-z0-9][A-Za-z0-9._:/-]*$/u.test(model)
      || model.includes('://') || /^(?:sk[-_]|gsk_|AIza|nvapi-)/iu.test(model)) {
    throw new ProviderCompatibilityError();
  }
  const reviewed = reviewedModel(provider, model);
  if (!reviewed) throw new ProviderCompatibilityError();
  const options = optionsFor(config.adapterOptions);
  return Object.freeze({ provider, base: PROVIDERS[provider][0], wire: PROVIDERS[provider][2], requestedModel: model,
    plain: reviewed.plain, schemaDialect: reviewed.schemaDialect, options, capabilities: CAPABILITIES,
    contractReview: Object.freeze({ reviewedAt: '2026-10-11', status: 'documentation-reviewed',
      sources: Object.freeze([...reviewed.sources]), liveTested: false }) });
}
