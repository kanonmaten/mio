import { createHash, timingSafeEqual, randomUUID } from 'node:crypto';
import { PROVIDERS, providerProfile } from './provider.mjs';
import { ANALYSIS_V2_PROMPT_VERSION } from './prompts.mjs';

export const RELEASE = '2026-09-30.1';
const safeModel = value => typeof value === 'string' && /^[A-Za-z0-9._:/-]{1,150}$/u.test(value) ? value : '';
export function gatewayStatus(config, valid = true) {
  const provider = config.provider ?? 'openai';
  let configured = valid;
  try { providerProfile(config); } catch { configured = false; }
  return { protocolVersion: 2, release: RELEASE, configured,
    provider: Object.hasOwn(PROVIDERS, provider) ? provider : '', model: safeModel(config.model),
    promptVersion: ANALYSIS_V2_PROMPT_VERSION,
    capabilities: ['analysis-context-v2', 'ask-v1', 'analysis-v1', 'lesson-notes-v1'] };
}
export function statusFromEnvironment(env, parseConfig) {
  try { return gatewayStatus(parseConfig(env)); }
  catch {
    const provider = env.MIO_AI_PROVIDER ?? 'openai';
    return gatewayStatus({ provider,
      model: env.MIO_AI_MODEL ?? (provider === 'openai' ? env.MIO_OPENAI_MODEL : '') }, false);
  }
}
export function authenticated(supplied, token) {
  if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{32,256}$/u.test(token) || token.startsWith('sk-')
      || typeof supplied !== 'string' || supplied.length > 263) return false;
  return timingSafeEqual(createHash('sha256').update(supplied).digest(),
    createHash('sha256').update(`Bearer ${token}`).digest());
}
export function metadataHeaders(status, promptVersion = status.promptVersion) {
  return { 'X-Mio-Release': RELEASE, 'X-Mio-Provider': status.provider, 'X-Mio-Model': status.model,
    'X-Mio-Prompt-Version': promptVersion, 'X-Mio-Request-ID': randomUUID() };
}
