import { RequestError, awaitWithSignal, cancelBody } from './execution-policy.mjs';
import { resolveTaskProfile } from './task-profiles.mjs';
import { createTaskRequest, validateTaskResult } from './tasks.mjs';
import { buildProviderRequest, normalizeProviderResponse, normalizeProviderError } from './adapters.mjs';
import { ProviderResponseError, ProviderCompatibilityError } from './provider.mjs';

const MAX_UPSTREAM_BYTES = 65_536;
const errorStatus = category => category === 'provider_quota' ? 429
  : category === 'provider_request_too_large' ? 413
  : ['provider_model_unavailable', 'provider_parameters'].includes(category) ? 422 : 502;

function providerFailure(response, data, now) {
  const error = normalizeProviderError({ status: response.status, data, headers: response.headers, now: now() });
  const failure = new RequestError(errorStatus(error.category), error.category, error.retryAfter ?? 60);
  // Only a wait the provider itself named may be honoured by the single retry below.
  failure.providerRetryAfter = error.retryAfter;
  return failure;
}

// Groq's free tier admits a request only when prompt + max_tokens fit the per-minute token
// budget, and the reservation counts whether or not the answer uses it. Three UTF-8 bytes per
// token overestimates Swedish text, so a request sized here is accepted by the provider.
const estimateTokens = value => Math.ceil(Buffer.byteLength(value, 'utf8') / 3);
const MINIMUM_ANSWER_TOKENS = Object.freeze({ ask: 300, everyday: 500, lesson: 1_200 });
export function fitToMinuteBudget(generation, taskID, tokensPerMinute) {
  if (tokensPerMinute == null) return generation;
  const prompt = generation.messages.reduce((sum, message) => sum + estimateTokens(message.content) + 8, 0)
    + estimateTokens(JSON.stringify(generation.structuredOutput.schema)) + 50;
  const room = tokensPerMinute - prompt;
  if (room < Math.min(generation.maxOutputTokens, MINIMUM_ANSWER_TOKENS[taskID])) {
    throw new RequestError(413, 'provider_request_too_large');
  }
  return room >= generation.maxOutputTokens ? generation : { ...generation, maxOutputTokens: room };
}

/** Milliseconds before the one retry, or null when the failure must be reported at once. */
function retryDelay(error, config) {
  if (!(error instanceof RequestError)) return null;
  if (error.code === 'provider_quota') {
    return Number.isFinite(error.providerRetryAfter) && error.providerRetryAfter <= 20
      ? error.providerRetryAfter * 1_000 + 250 : null;
  }
  return ['provider_infrastructure', 'provider_transport'].includes(error.code) ? config.retryDelayMs ?? 1_000 : null;
}

async function readUpstream(response, profile, signal, now) {
  const hasJSON = response.headers.get('content-type')?.toLowerCase().startsWith('application/json');
  if (Number(response.headers.get('content-length')) > MAX_UPSTREAM_BYTES || !response.body) {
    cancelBody(response.body);
    // An unreadable error envelope still keeps its status category (e.g. 429 + Retry-After).
    throw response.ok ? new RequestError(502, 'invalid_upstream_response') : providerFailure(response, undefined, now);
  }
  // Error envelopes have the same limits/deadline as successful envelopes. Only
  // normalized fixed codes leave this boundary; arbitrary error bodies never do.
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await awaitWithSignal(reader.read(), signal);
      if (done) break;
      size += value.byteLength;
      if (size > MAX_UPSTREAM_BYTES) {
        throw response.ok ? new RequestError(502, 'upstream_response_too_large') : providerFailure(response, undefined, now);
      }
      chunks.push(value);
    }
    let data;
    if (hasJSON) {
      try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch {
        if (response.ok) throw new RequestError(502, 'invalid_upstream_response');
      }
    }
    if (!response.ok) throw providerFailure(response, data, now);
    if (!hasJSON) throw new RequestError(502, 'invalid_upstream_response');
    try {
      const result = normalizeProviderResponse(data, profile, response.headers);
      if (result.refusal || result.finish === 'refused') throw new RequestError(502, 'provider_refusal');
      if (result.finish === 'truncated') throw new RequestError(502, 'provider_truncated');
      if (result.finish !== 'completed' || typeof result.text !== 'string') throw new RequestError(502, 'provider_invalid_response');
      return result;
    } catch (error) {
      if (error instanceof RequestError) throw error;
      if (error instanceof ProviderResponseError) throw new RequestError(errorStatus(error.category), error.category ?? 'provider_invalid_response');
      throw new RequestError(502, 'provider_invalid_response');
    }
  } finally {
    // Uncooperative cancellation is detached; it must never extend the deadline.
    reader.cancel().catch(() => {});
    reader.releaseLock();
    chunks.length = 0;
  }
}

export async function executeGeneration({ config, mode, payload, fetchImpl, signal,
  reserveRequest, now = Date.now }) {
  const controller = new AbortController();
  const onCancel = () => controller.abort(signal.reason ?? new RequestError(499, 'request_cancelled'));
  if (signal.aborted) onCancel();
  else signal.addEventListener('abort', onCancel, { once: true });
  const started = performance.now();
  const expire = () => controller.abort(new RequestError(504, 'upstream_timeout'));
  const ensureCurrent = () => {
    if (performance.now() - started >= config.upstreamTimeoutMs) expire();
    controller.signal.throwIfAborted();
  };
  const timeout = setTimeout(expire, config.upstreamTimeoutMs);
  timeout.unref?.();
  try {
    ensureCurrent();
    const taskID = mode === 'lesson' ? 'lesson' : mode === 'ask' ? 'ask' : 'everyday';
    const selected = resolveTaskProfile(config, taskID);
    if (!selected.configured) throw new RequestError(422, 'task_configuration_invalid');
    const generation = fitToMinuteBudget(createTaskRequest(mode, payload), taskID, config.tokensPerMinute);
    // Options and immutable policy must be checked before consuming shared quota.
    const provider = buildProviderRequest(selected.config, generation);
    ensureCurrent();
    reserveRequest();
    ensureCurrent();
    const attempt = async () => {
      let upstream;
      try {
        upstream = await awaitWithSignal(fetchImpl(provider.url, { method: 'POST', headers: provider.headers,
          redirect: 'manual', signal: controller.signal, body: JSON.stringify(provider.body) }), controller.signal,
        value => cancelBody(value.body));
      } catch (error) {
        if (controller.signal.aborted) throw controller.signal.reason;
        throw new RequestError(502, 'provider_transport');
      }
      return readUpstream(upstream, provider.profile, controller.signal, now);
    };
    // One retry with the identical request (user decision 2026-11-15): after a short wait the
    // provider named, or a brief pause after a provider/network failure. Never a second retry,
    // never another model or other parameters, and only while the call's own deadline allows it.
    let normalized;
    for (let retried = false; ; retried = true) {
      try { normalized = await attempt(); break; }
      catch (error) {
        const delay = retried || controller.signal.aborted ? null : retryDelay(error, config);
        const remaining = config.upstreamTimeoutMs - (performance.now() - started);
        if (delay === null || remaining < delay + config.upstreamTimeoutMs / 5) throw error;
        await awaitWithSignal(new Promise(resolve => { setTimeout(resolve, delay).unref?.(); }), controller.signal);
      }
    }
    ensureCurrent();
    let result;
    try { result = validateTaskResult(mode, normalized.text, payload); }
    catch {
      throw new RequestError(502, mode === 'lesson' ? 'invalid_lesson_result'
        : mode === 'ask' ? 'invalid_upstream_answer' : 'invalid_analysis_result');
    }
    ensureCurrent();
    return { result, normalized, promptVersion: generation.promptVersion, config: selected.config };
  } catch (error) {
    if (error instanceof RequestError && error.code === 'budget_store_failed') throw error;
    if (controller.signal.aborted) throw controller.signal.reason;
    if (error instanceof RequestError) throw error;
    if (error instanceof ProviderCompatibilityError) throw new RequestError(422, 'task_configuration_invalid');
    throw new RequestError(502, 'provider_infrastructure');
  } finally {
    clearTimeout(timeout);
    signal.removeEventListener('abort', onCancel);
  }
}

export function generationMetadataHeaders(normalized) {
  const headers = {};
  const safeID = value => typeof value === 'string' && /^[A-Za-z0-9._:/-]{1,150}$/u.test(value) && !value.includes('://') && !/^(?:sk[-_]|gsk_|AIza|nvapi-)/iu.test(value);
  if (safeID(normalized.returnedModel)) headers['X-Mio-Returned-Model'] = normalized.returnedModel;
  const requestID = normalized.provenance?.requestID;
  if (safeID(requestID) && /^[A-Za-z0-9._:-]{1,128}$/u.test(requestID)) headers['X-Mio-Upstream-Request-ID'] = requestID;
  for (const [name, header] of [['inputTokens', 'Input'], ['outputTokens', 'Output'], ['reasoningTokens', 'Reasoning']]) {
    const value = normalized.usage?.[name];
    if (Number.isSafeInteger(value) && value >= 0 && value <= 1_000_000_000) headers[`X-Mio-Usage-${header}-Tokens`] = String(value);
  }
  return headers;
}
