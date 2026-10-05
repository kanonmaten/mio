import { RequestError, awaitWithSignal, cancelBody } from './execution-policy.mjs';
import { resolveTaskProfile } from './task-profiles.mjs';
import { createTaskRequest, validateTaskResult } from './tasks.mjs';
import { buildProviderRequest, normalizeProviderResponse, normalizeProviderError } from './adapters.mjs';
import { ProviderResponseError, ProviderCompatibilityError } from './provider.mjs';

const MAX_UPSTREAM_BYTES = 65_536;
const errorStatus = category => category === 'provider_quota' ? 429
  : ['provider_model_unavailable', 'provider_parameters'].includes(category) ? 422 : 502;

function providerFailure(response, data, now) {
  const error = normalizeProviderError({ status: response.status, data, headers: response.headers, now: now() });
  return new RequestError(errorStatus(error.category), error.category, error.retryAfter ?? 60);
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
  reserveRequest, reserveBudget, now = Date.now }) {
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
    const generation = createTaskRequest(mode, payload);
    // Options and immutable policy must be checked before consuming shared quota.
    const provider = buildProviderRequest(selected.config, generation);
    ensureCurrent();
    reserveRequest();
    if (reserveBudget) {
      let reservation;
      try { reservation = await awaitWithSignal(Promise.resolve().then(() => reserveBudget(config)), controller.signal); }
      catch (error) {
        const reason = controller.signal.reason;
        // A budget store that outlives the deadline is a store failure, not a provider
        // timeout. Its late result is discarded: no inference and no refund attempt.
        if (controller.signal.aborted && !(reason instanceof RequestError && reason.code === 'upstream_timeout')) throw reason;
        throw new RequestError(503, 'budget_store_failed');
      }
      if (reservation === false || reservation?.allowed === false) {
        const reason = ['local_minute_limit', 'local_day_limit', 'local_request_limit'].includes(reservation?.reason)
          ? reservation.reason : 'local_request_limit';
        throw new RequestError(429, reason);
      }
      if (reservation !== true && reservation?.allowed !== true) throw new RequestError(503, 'budget_store_failed');
    }
    // D1 may ignore cancellation and consume quota late. Never infer or refund then.
    ensureCurrent();
    let upstream;
    try {
      upstream = await awaitWithSignal(fetchImpl(provider.url, { method: 'POST', headers: provider.headers,
        redirect: 'manual', signal: controller.signal, body: JSON.stringify(provider.body) }), controller.signal,
      value => cancelBody(value.body));
    } catch (error) {
      if (controller.signal.aborted) throw controller.signal.reason;
      throw new RequestError(502, 'provider_transport');
    }
    const normalized = await readUpstream(upstream, provider.profile, controller.signal, now);
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
  const safeID = value => typeof value === 'string' && /^[A-Za-z0-9._:/-]{1,150}$/u.test(value) && !value.includes('://') && !/^(?:sk[-_]|gsk_|AIza)/iu.test(value);
  if (safeID(normalized.returnedModel)) headers['X-Mio-Returned-Model'] = normalized.returnedModel;
  const requestID = normalized.provenance?.requestID;
  if (safeID(requestID) && /^[A-Za-z0-9._:-]{1,128}$/u.test(requestID)) headers['X-Mio-Upstream-Request-ID'] = requestID;
  for (const [name, header] of [['inputTokens', 'Input'], ['outputTokens', 'Output'], ['reasoningTokens', 'Reasoning']]) {
    const value = normalized.usage?.[name];
    if (Number.isSafeInteger(value) && value >= 0 && value <= 1_000_000_000) headers[`X-Mio-Usage-${header}-Tokens`] = String(value);
  }
  return headers;
}
