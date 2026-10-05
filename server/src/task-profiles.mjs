import { providerProfile } from './provider.mjs';

export const TASK_IDS = Object.freeze(['ask', 'everyday', 'lesson']);
const PROFILE_FIELDS = new Set(['provider', 'model', 'adapterOptions', 'baseURL', 'compatibility']);
const plainObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
const credentialShapedIdentifier = value => /^(?:sk[-_]|gsk_|AIza|nvapi-)/iu.test(value);
export const safeProviderIdentifier = value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,64}$/u.test(value)
  && !credentialShapedIdentifier(value) ? value : '';
export const safeModelIdentifier = value => typeof value === 'string' && /^[A-Za-z0-9._:/-]{1,150}$/u.test(value)
  && !value.includes('://') && !credentialShapedIdentifier(value) ? value : '';

function profileOverrides(config) {
  if (config.taskProfiles === undefined) return {};
  let profiles = config.taskProfiles;
  try { if (typeof profiles === 'string') profiles = JSON.parse(profiles); }
  catch { return null; }
  if (!plainObject(profiles) || Object.keys(profiles).some(key => !TASK_IDS.includes(key))) return null;
  return profiles;
}

function effectiveTaskConfig(config, task) {
  if (!TASK_IDS.includes(task)) return { configurationError: 'task_profile_invalid' };
  const profiles = profileOverrides(config);
  if (!profiles) return { configurationError: 'task_profiles_invalid' };
  const override = Object.hasOwn(profiles, task) ? profiles[task] : {};
  if (!plainObject(override) || Object.keys(override).some(key => !PROFILE_FIELDS.has(key))) {
    return { configurationError: 'task_profile_invalid' };
  }
  const provider = Object.hasOwn(override, 'provider') ? override.provider : config.provider ?? 'openai';
  const model = Object.hasOwn(override, 'model') ? override.model : config.model;
  if (!safeProviderIdentifier(provider) || !safeModelIdentifier(model)) return { configurationError: 'task_profile_invalid' };
  // Historical global endpoint hints remain backward compatible. An explicit
  // task override must not promise an endpoint assertion its adapter ignores.
  if (provider !== 'custom' && ['baseURL', 'compatibility'].some(field => Object.hasOwn(override, field))) {
    return { configurationError: 'provider_options_incompatible' };
  }
  const inherited = provider === (config.provider ?? 'openai') && model === config.model;
  const effective = { ...config, provider, model };
  // Adapter defaults may inherit within a provider and are revalidated for the
  // selected model. An endpoint assertion belongs to the exact provider/model.
  for (const field of ['adapterOptions', 'baseURL', 'compatibility']) {
    if (Object.hasOwn(override, field)) effective[field] = override[field];
    else if (field === 'adapterOptions' ? provider !== (config.provider ?? 'openai') : !inherited) delete effective[field];
  }
  if (provider !== (config.provider ?? 'openai')) effective.apiKey = config.providerSecrets?.[provider];
  delete effective.taskProfiles;
  delete effective.providerSecrets;
  return { config: effective, configurationError: null };
}

export function taskConfigurationIdentifiers(config, task) {
  const profiles = profileOverrides(config);
  const override = profiles && plainObject(profiles[task]) ? profiles[task] : {};
  return { provider: safeProviderIdentifier(Object.hasOwn(override, 'provider') ? override.provider : config.provider ?? 'openai'),
    model: safeModelIdentifier(Object.hasOwn(override, 'model') ? override.model : config.model) };
}

export function resolveTaskProfile(config, task) {
  if (config.globalConfigurationError === 'gateway_configuration_invalid') {
    return { configured: false, config: null, configurationError: 'gateway_configuration_invalid' };
  }
  const effective = effectiveTaskConfig(config, task);
  const failed = configurationError => ({ configured: false, config: null, configurationError });
  if (effective.configurationError) return failed(effective.configurationError);
  const selected = effective.config;
  if (selected.adapterOptions !== undefined && !plainObject(selected.adapterOptions)) return failed('provider_options_incompatible');
  try {
    const profile = providerProfile(selected);
    // Older facade implementations did not validate options. Never silently drop
    // requested requirements during adapter rollout.
    if (selected.adapterOptions && Object.keys(selected.adapterOptions).length && profile.options === undefined) {
      return failed('provider_options_incompatible');
    }
    if (typeof selected.apiKey !== 'string' || !selected.apiKey.trim() || /[\r\n]/u.test(selected.apiKey)
        || selected.apiKey === config.gatewayToken) return failed('provider_secret_missing');
    return { configured: true, config: selected, configurationError: null };
  } catch (error) {
    return failed(error?.message === 'provider_options_incompatible' ? 'provider_options_incompatible' : 'provider_model_incompatible');
  }
}

export function taskProfiles(config) {
  return Object.fromEntries(TASK_IDS.map(task => [task, resolveTaskProfile(config, task)]));
}
