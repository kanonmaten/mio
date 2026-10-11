// Compatibility facade. Task selection is kept outside the generic wire adapters.
import { createTaskRequest } from './tasks.mjs';
import { buildProviderRequest, normalizeProviderResponse, ProviderResponseError } from './adapters.mjs';
export { PROVIDERS, ProviderCompatibilityError, validateProvider, providerProfile } from './model-profiles.mjs';
export { ProviderResponseError } from './adapters.mjs';

export function providerRequest({ config, mode, payload }) {
  return buildProviderRequest(config, createTaskRequest(mode, payload));
}

export function providerResponseText(data, profile = { wire: 'chat' }) {
  const result = normalizeProviderResponse(data, profile);
  if (result.finish !== 'completed') {
    throw new ProviderResponseError(result.refusal ? 'provider_refusal' : 'provider_truncated');
  }
  return result.text;
}
