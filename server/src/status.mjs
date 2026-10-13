import { createHash, timingSafeEqual, randomUUID } from 'node:crypto';
import { PROVIDERS, providerProfile } from './provider.mjs';
import { ANALYSIS_V2_PROMPT_VERSION, PROMPT_VERSION } from './prompts.mjs';
import { TASK_IDS, resolveTaskProfile, taskProfiles, taskConfigurationIdentifiers, safeModelIdentifier, safeProviderIdentifier } from './task-profiles.mjs';

export const RELEASE = '2026-10-13.1';
export function gatewayStatus(config, valid = true) {
  // Older clients only call /v1/analyze, so v1 status describes the effective everyday task.
  const { provider, model } = valid ? taskConfigurationIdentifiers(config, 'everyday')
    : { provider: config.provider ?? 'groq', model: safeModelIdentifier(config.model) };
  const configured = valid && resolveTaskProfile(config, 'everyday').configured;
  return { protocolVersion: 2, release: RELEASE, configured,
    provider: Object.hasOwn(PROVIDERS, provider) ? provider : '', model,
    promptVersion: ANALYSIS_V2_PROMPT_VERSION,
    capabilities: ['analysis-context-v2', 'ask-v1', 'analysis-v1', 'lesson-notes-v1'] };
}
export function statusFromEnvironment(env, parseConfig) {
  try { return gatewayStatus(parseConfig(env)); }
  catch {
    return gatewayStatus({ provider: env.MIO_AI_PROVIDER ?? 'groq', model: env.MIO_AI_MODEL ?? '' }, false);
  }
}

export function statusV2FromEnvironment(env, parseConfig, quota = null) {
  try { return gatewayStatusV2(parseConfig(env), quota); }
  catch {
    return gatewayStatusV2({ provider: env.MIO_AI_PROVIDER ?? 'groq', model: env.MIO_AI_MODEL ?? '',
      taskProfiles: env.MIO_AI_TASK_PROFILES,
      globalConfigurationError: 'gateway_configuration_invalid' }, null);
  }
}
export function authenticated(supplied, token) {
  if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{32,256}$/u.test(token) || token.startsWith('sk-')
      || typeof supplied !== 'string' || supplied.length > 263) return false;
  return timingSafeEqual(createHash('sha256').update(supplied).digest(),
    createHash('sha256').update(`Bearer ${token}`).digest());
}
export function metadataHeaders(status, promptVersion = status.promptVersion ?? '') {
  return { 'X-Mio-Release': RELEASE, 'X-Mio-Provider': safeProviderIdentifier(status.provider), 'X-Mio-Model': safeModelIdentifier(status.model),
    'X-Mio-Prompt-Version': typeof promptVersion === 'string' && /^[A-Za-z0-9._-]{1,80}$/u.test(promptVersion) ? promptVersion : '',
    'X-Mio-Request-ID': randomUUID(),
    ...(/^[a-f0-9]{64}$/u.test(status.configurationRevision ?? '') ? { 'X-Mio-Configuration-Revision': status.configurationRevision } : {}) };
}

const taskPromptVersion = task => task === 'everyday' ? ANALYSIS_V2_PROMPT_VERSION : PROMPT_VERSION;
const taskCapabilities = task => ['reasoning-off', 'temperature-zero', 'strict-json',
  task === 'ask' ? 'ask-v1' : task === 'everyday' ? 'analysis-context-v2' : 'lesson-notes-v1'];
// null means no daily cap; status then reports quota as null instead of an invented limit.
// A token cap (the binding Groq free-tier limit) takes precedence over a request cap.
const positiveLimit = value => Number.isSafeInteger(value) && value > 0 ? value : null;
const quotaUnit = config => positiveLimit(config.tokensPerDay) ? 'tokens' : positiveLimit(config.requestsPerDay) ? 'requests' : null;
const quotaLimit = config => positiveLimit(config.tokensPerDay) ?? positiveLimit(config.requestsPerDay);
const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
function safeResetAt(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T00:00:00\.000Z$/u.test(value)) return null;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) && date.toISOString() === value ? value : null;
}

export function configurationRevision(config) {
  const tasks = Object.fromEntries(TASK_IDS.map(task => {
    const selected = resolveTaskProfile(config, task);
    const identifiers = taskConfigurationIdentifiers(config, task);
    const profile = selected.configured ? providerProfile(selected.config) : null;
    return [task, { ...identifiers, configured: selected.configured, configurationError: selected.configurationError,
      promptVersion: taskPromptVersion(task), capabilities: taskCapabilities(task),
      options: profile?.options ?? {},
      // The endpoint identity affects review even though neither it nor credentials
      // are published. Only providerProfile's validated credential-free base is used.
      endpoint: profile?.base ?? null }];
  }));
  const publicConfiguration = { protocolVersion: 2, release: RELEASE, tasks,
    limits: { requestsPerMinute: config.requestsPerMinute ?? 3, requestsPerDay: positiveLimit(config.requestsPerDay),
      tokensPerDay: positiveLimit(config.tokensPerDay),
      lessonIntervalSeconds: config.lessonIntervalSeconds ?? 60, upstreamTimeoutMs: config.upstreamTimeoutMs ?? 40_000,
      bodyTimeoutMs: config.bodyTimeoutMs ?? 5_000, concurrency: 2 } };
  return createHash('sha256').update(JSON.stringify(canonical(publicConfiguration))).digest('hex');
}

export function gatewayStatusV2(config, quota = null) {
  const selected = taskProfiles(config);
  const tasks = Object.fromEntries(TASK_IDS.map(task => [task, {
    configured: selected[task].configured, ...taskConfigurationIdentifiers(config, task),
    promptVersion: taskPromptVersion(task), capabilities: taskCapabilities(task),
    configurationError: selected[task].configurationError
  }]));
  const limit = quotaLimit(config);
  if (limit === null) return { protocolVersion: 2, release: RELEASE, configurationRevision: configurationRevision(config), tasks, quota: null };
  const remaining = Number.isSafeInteger(quota?.remaining) && quota.remaining >= 0 && quota.remaining <= limit ? quota.remaining : null;
  const resetAt = safeResetAt(quota?.resetAt);
  return { protocolVersion: 2, release: RELEASE, configurationRevision: configurationRevision(config), tasks,
    quota: { limit, remaining, resetAt, unit: quotaUnit(config) } };
}
