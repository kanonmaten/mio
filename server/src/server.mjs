import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import { validateAnalysisPayload, validateAnalysisV2Payload, validateLessonPayload } from './analysis.mjs';
import { PROVIDERS } from './provider.mjs';
import { RequestError, awaitWithSignal } from './execution-policy.mjs';
import { executeGeneration, generationMetadataHeaders } from './generation-execution.mjs';
import { taskConfigurationIdentifiers } from './task-profiles.mjs';

import { PROMPT_VERSION, ANALYSIS_V2_PROMPT_VERSION } from './prompts.mjs';
import { authenticated, gatewayStatus, gatewayStatusV2, configurationRevision, metadataHeaders } from './status.mjs';

const MAX_BODY_BYTES = 20_000;
function byteLength(value) { return Buffer.byteLength(value, 'utf8'); }
function exactKeys(value, expected) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === expected.length
    && expected.every(key => Object.hasOwn(value, key));
}

export function validatePayload(value) {
  if (!exactKeys(value, ['question', 'context'])
      || typeof value.question !== 'string' || !value.question.trim()
      || byteLength(value.question) > 2_000
      || !Array.isArray(value.context) || value.context.length > 6) {
    throw new RequestError(400, 'invalid_request');
  }
  let total = 0;
  for (const context of value.context) {
    if (!exactKeys(context, ['label', 'text'])
        || typeof context.label !== 'string' || !context.label.trim() || byteLength(context.label) > 200
        || typeof context.text !== 'string' || !context.text.trim() || byteLength(context.text) > 4_000) {
      throw new RequestError(400, 'invalid_context');
    }
    total += byteLength(context.label) + byteLength(context.text);
  }
  if (total > 10_000) throw new RequestError(400, 'invalid_context');
  return value;
}

const MAX_REQUESTS_PER_DAY = 1_000_000;

function positiveInteger(value, fallback, maximum) {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum) {
    throw new Error('Ogiltig numerisk serverinställning.');
  }
  return parsed;
}

// Unset or 0 means no local daily cap. The per-minute cap, concurrency limit and the
// provider's own limits still apply (user decision 2026-10-05, NVIDIA NIM has no daily quota).
function dailyLimit(value) {
  if (value === undefined || value === '' || value === '0') return null;
  return positiveInteger(value, null, MAX_REQUESTS_PER_DAY);
}

export function loadConfig(env = process.env) {
  const provider = env.MIO_AI_PROVIDER ?? 'openai';
  const providerSecrets = Object.fromEntries(Object.entries(PROVIDERS).map(([id, entry]) => [id, env[entry[1]] ?? ""]));
  const config = {
    provider,
    apiKey: providerSecrets[provider] ?? '',
    providerSecrets,
    taskProfiles: env.MIO_AI_TASK_PROFILES,
    baseURL: env.MIO_AI_BASE_URL,
    compatibility: env.MIO_AI_COMPATIBILITY,
    lessonIntervalSeconds: positiveInteger(env.MIO_LESSON_INTERVAL_SECONDS, 60, 3600),
    gatewayToken: env.MIO_GATEWAY_TOKEN ?? '',
    model: env.MIO_AI_MODEL ?? (provider === 'openai' ? env.MIO_OPENAI_MODEL : '') ?? '',
    port: positiveInteger(env.PORT, 8787, 65_535),
    requestsPerMinute: positiveInteger(env.MIO_REQUESTS_PER_MINUTE, provider === 'groq' ? 1 : 6, 60),
    requestsPerDay: dailyLimit(env.MIO_REQUESTS_PER_DAY),
    upstreamTimeoutMs: 40_000,
    bodyTimeoutMs: 5_000
  };
  validateConfig(config);
  return config;
}

function validateConfig(config) {
  // Generation configuration belongs to each task profile. An unavailable task
  // must not prevent protected model-free discovery or unrelated configured tasks.
  if (typeof config.gatewayToken !== 'string' || !/^[A-Za-z0-9_-]{32,256}$/u.test(config.gatewayToken)
      || config.gatewayToken.startsWith('sk-')) throw new Error('Konfigurera en separat MIO_GATEWAY_TOKEN.');
  if (config.lessonIntervalSeconds !== undefined && (!Number.isSafeInteger(config.lessonIntervalSeconds)
      || config.lessonIntervalSeconds < 60 || config.lessonIntervalSeconds > 3600)) throw new Error('Lektionsintervallet måste vara 60–3600 sekunder.');
  if (config.requestsPerMinute > 60 || config.upstreamTimeoutMs > 40_000 || config.bodyTimeoutMs > 5_000) throw new Error('Servergränserna får inte höja Mios minutkvot eller tidsgränser.');
  if (config.requestsPerDay != null && (!Number.isSafeInteger(config.requestsPerDay) || config.requestsPerDay < 1
      || config.requestsPerDay > MAX_REQUESTS_PER_DAY)) throw new Error('Ogiltig dagsgräns.');
  for (const field of ['requestsPerMinute', 'upstreamTimeoutMs', 'bodyTimeoutMs']) {
    if (!Number.isSafeInteger(config[field]) || config[field] < 1) throw new Error('Ogiltig servergräns.');
  }
}

function reply(response, status, body, retryAfter = 60) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Connection': 'close',
    ...(status === 429 ? { 'Retry-After': String(retryAfter) } : {})
  });
  response.end(JSON.stringify(body));
}

async function readBody(request, timeoutMs, validate = validatePayload, signal) {
  if (Number(request.headers['content-length']) > MAX_BODY_BYTES) {
    throw new RequestError(413, 'request_too_large');
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const finish = (error, value) => {
      clearTimeout(timer);
      request.removeListener('data', onData);
      request.removeListener('end', onEnd);
      request.removeListener('error', onError);
      signal?.removeEventListener('abort', onAbort);
      chunks.length = 0;
      if (error) { request.pause(); reject(error); }
      else resolve(value);
    };
    const onData = chunk => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) finish(new RequestError(413, 'request_too_large'));
      else chunks.push(chunk);
    };
    const onEnd = () => {
      try {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks));
        finish(undefined, validate(JSON.parse(text)));
      } catch (error) { finish(error instanceof RequestError ? error : new RequestError(400, 'invalid_json')); }
    };
    const onError = () => finish(new RequestError(400, 'invalid_json'));
    const onAbort = () => finish(signal.reason);
    const timer = setTimeout(() => finish(new RequestError(408, 'request_timeout')), timeoutMs);
    timer.unref?.();
    request.on('data', onData);
    request.once('end', onEnd);
    request.once('error', onError);
    if (signal?.aborted) onAbort();
    else signal?.addEventListener('abort', onAbort, { once: true });
  });
}

/** Single private user, one process. Counters contain numbers only; no transcripts or IPs are kept. */
export function createMioServer({ config: baseConfig = loadConfig(), fetchImpl = fetch, now = Date.now,
  reserveBudget, readQuota, requestSignal, configurationForRequest,
  serverOptions = { maxHeaderSize: 8_192 } } = {}) {
  validateConfig(baseConfig);
  let minuteBucket = -1; let dayBucket = -1;
  let minuteCount = 0; let dayCount = 0; let active = 0;
  const activeControllers = new Set();

  function reserveRequest(config) {
    const time = now();
    if (minuteBucket !== Math.floor(time / 60_000)) { minuteBucket = Math.floor(time / 60_000); minuteCount = 0; }
    if (dayBucket !== Math.floor(time / 86_400_000)) { dayBucket = Math.floor(time / 86_400_000); dayCount = 0; }
    if (active >= 2) throw new RequestError(429, 'local_concurrency_limit');
    if (config.requestsPerDay != null && dayCount >= config.requestsPerDay) throw new RequestError(429, 'local_day_limit');
    if (minuteCount >= config.requestsPerMinute) throw new RequestError(429, 'local_minute_limit');
    minuteCount += 1; dayCount += 1;
  }

  const server = createServer(serverOptions, async (request, response) => {
    let controller; let runtimeSignal; let ownsSlot = false;
    const onCancel = () => controller.abort(new RequestError(499, 'request_cancelled'));
    const onClose = () => { if (!response.writableEnded) onCancel(); };
    try {
      const current = configurationForRequest?.(request) ?? baseConfig;
      // Each request captures its own server configuration, including rotating
      // credentials. No secret fingerprints are exported in public revisions.
      const config = { ...current, providerSecrets: { ...current.providerSecrets },
        taskProfiles: structuredClone(current.taskProfiles), adapterOptions: structuredClone(current.adapterOptions) };
      validateConfig(config);
      const revision = configurationRevision(config);
      const status = gatewayStatus(config);
      const promptVersion = ['/v2/analyze', '/v1/status', '/v2/status'].includes(request.url) ? ANALYSIS_V2_PROMPT_VERSION : PROMPT_VERSION;
      const taskID = request.url === '/v1/ask' ? 'ask' : request.url === '/v1/lesson-notes' ? 'lesson'
        : ['/v1/analyze', '/v2/analyze'].includes(request.url) ? 'everyday' : null;
      const identifiers = taskID ? taskConfigurationIdentifiers(config, taskID) : status;
      for (const [key, value] of Object.entries(metadataHeaders({ ...identifiers, configurationRevision: revision }, promptVersion))) response.setHeader(key, value);
      if (request.method === 'GET' && ['/v1/status', '/v2/status'].includes(request.url)) {
        if (!authenticated(request.headers.authorization, config.gatewayToken)) { reply(response, 401, { error: 'unauthorized' }); return; }
        if (request.url === '/v1/status') { reply(response, 200, status); return; }
        let quota = null;
        if (readQuota) {
          const guardController = new AbortController();
          const timer = setTimeout(() => guardController.abort(), Math.min(2_000, config.upstreamTimeoutMs));
          timer.unref?.();
          try { quota = await awaitWithSignal(Promise.resolve().then(() => readQuota(config)), guardController.signal); }
          catch { /* Unknown capacity is explicit; status never reserves or infers. */ }
          finally { clearTimeout(timer); }
        } else if (!reserveBudget && config.requestsPerDay != null) {
          const time = now();
          const used = dayBucket === Math.floor(time / 86_400_000) ? dayCount : 0;
          quota = { limit: config.requestsPerDay, remaining: Math.max(0, config.requestsPerDay - used),
            resetAt: new Date((Math.floor(time / 86_400_000) + 1) * 86_400_000).toISOString() };
        }
        reply(response, 200, gatewayStatusV2(config, quota)); return;
      }
      if (request.method === 'GET' && request.url === '/health') { reply(response, 200, { status: 'ok' }); return; }
      if (request.method !== 'POST' || !['/v1/ask', '/v1/analyze', '/v2/analyze', '/v1/lesson-notes'].includes(request.url)) {
        reply(response, 404, { error: 'not_found' }); return;
      }
      if (!authenticated(request.headers.authorization, config.gatewayToken)) { reply(response, 401, { error: 'unauthorized' }); return; }
      const observed = request.headers['x-mio-configuration-revision'];
      if (observed !== undefined && (typeof observed !== 'string' || !/^[a-f0-9]{64}$/u.test(observed))) {
        reply(response, 400, { error: 'invalid_configuration_revision' }); return;
      }
      if (observed !== undefined && observed !== revision) { reply(response, 409, { error: 'configuration_changed' }); return; }
      if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json' || request.headers['content-encoding']) {
        reply(response, 415, { error: 'json_required' }); return;
      }
      const isLesson = request.url === '/v1/lesson-notes';
      const isV2 = request.url === '/v2/analyze';
      const isAnalysis = isV2 || request.url === '/v1/analyze';
      controller = new AbortController(); activeControllers.add(controller);
      runtimeSignal = requestSignal?.(request);
      request.on('aborted', onCancel); response.on('close', onClose);
      if (runtimeSignal?.aborted) onCancel(); else runtimeSignal?.addEventListener('abort', onCancel, { once: true });
      const payload = await readBody(request, config.bodyTimeoutMs,
        isLesson ? validateLessonPayload : isV2 ? validateAnalysisV2Payload : isAnalysis ? validateAnalysisPayload : validatePayload, controller.signal);
      if (response.destroyed) return;
      const generated = await executeGeneration({ config, mode: isLesson ? 'lesson' : isV2 ? 'analyze-v2' : isAnalysis ? 'analyze' : 'ask',
        payload, fetchImpl, signal: controller.signal, now, reserveBudget,
        reserveRequest: () => { reserveRequest(config); active += 1; ownsSlot = true; } });
      for (const [key, value] of Object.entries({ 'X-Mio-Provider': generated.config.provider ?? 'openai', 'X-Mio-Model': generated.config.model,
        'X-Mio-Prompt-Version': generated.promptVersion, 'X-Mio-Configuration-Revision': revision,
        ...generationMetadataHeaders(generated.normalized) })) response.setHeader(key, value);
      reply(response, 200, isLesson ? { ...generated.result, metadata: { provider: generated.config.provider ?? 'openai',
        model: generated.config.model, promptVersion: generated.promptVersion,
        lessonIntervalSeconds: Math.max(60, config.lessonIntervalSeconds ?? 60) } } : generated.result);
    } catch (error) {
      // Arbitrary upstream bodies, credentials, source text and full URLs stay private.
      if (error instanceof RequestError) reply(response, error.status, { error: error.code }, error.retryAfter);
      else reply(response, 500, { error: 'request_failed' });
    } finally {
      if (ownsSlot) active -= 1;
      request.removeListener('aborted', onCancel); response.removeListener('close', onClose);
      runtimeSignal?.removeEventListener('abort', onCancel);
      if (controller) activeControllers.delete(controller);
    }
  });
  server.requestTimeout = 10_000;
  server.headersTimeout = 5_000;
  server.keepAliveTimeout = 1_000;
  server.maxRequestsPerSocket = 1;
  server.on('clientError', (_, socket) => socket.destroy());
  server.on('close', () => { for (const controller of activeControllers) controller.abort(new RequestError(499, 'request_cancelled')); });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const config = loadConfig();
    const server = createMioServer({ config });
    server.on('error', () => { console.error('Mio-servern kunde inte starta. Kontrollera port och inställningar.'); process.exitCode = 1; });
    // HTTPS terminates at the local reverse proxy. Never expose this HTTP listener publicly.
    server.listen(config.port, '127.0.0.1', () => console.log('Mio-servern kör på loopback bakom din HTTPS-proxy.'));
    const shutdown = () => { server.closeAllConnections(); server.close(); };
    process.once('SIGINT', shutdown);
    process.once('SIGTERM', shutdown);
  } catch {
    console.error('Mio-servern är avstängd: kontrollera serverns miljövariabler enligt README.');
    process.exitCode = 1;
  }
}
