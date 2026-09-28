import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { validateAnalysisPayload, validateAnalysisResult, validateLessonPayload, validateLessonResult, validateAskResult } from './analysis.mjs';
import { providerRequest, providerResponseText, ProviderResponseError, ProviderCompatibilityError, validateProvider, providerProfile, PROVIDERS } from './provider.mjs';

import { PROMPT_VERSION } from './prompts.mjs';

const MAX_BODY_BYTES = 20_000;
const MAX_UPSTREAM_BYTES = 65_536;


class RequestError extends Error {
  constructor(status, code, retryAfter = 60) { super(code); this.status = status; this.code = code; this.retryAfter = retryAfter; }
}

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

function positiveInteger(value, fallback, maximum) {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum) {
    throw new Error('Ogiltig numerisk serverinställning.');
  }
  return parsed;
}

export function loadConfig(env = process.env) {
  const provider = env.MIO_AI_PROVIDER ?? 'openai';
  validateProvider(provider);
  const config = {
    provider,
    apiKey: env[PROVIDERS[provider][1]] ?? '',
    baseURL: env.MIO_AI_BASE_URL,
    compatibility: env.MIO_AI_COMPATIBILITY,
    lessonIntervalSeconds: positiveInteger(env.MIO_LESSON_INTERVAL_SECONDS, 60, 3600),
    gatewayToken: env.MIO_GATEWAY_TOKEN ?? '',
    model: env.MIO_AI_MODEL ?? (provider === 'openai' ? env.MIO_OPENAI_MODEL : '') ?? '',
    port: positiveInteger(env.PORT, 8787, 65_535),
    requestsPerMinute: positiveInteger(env.MIO_REQUESTS_PER_MINUTE, provider === 'groq' ? 1 : 6, 60),
    requestsPerDay: positiveInteger(env.MIO_REQUESTS_PER_DAY, 100, 1_000),
    upstreamTimeoutMs: 40_000,
    bodyTimeoutMs: 5_000
  };
  validateConfig(config);
  return config;
}

function validateConfig(config) {
  validateProvider(config.provider ?? 'openai');
  if (typeof config.apiKey !== 'string' || !config.apiKey.trim()
      || /[\r\n]/u.test(config.apiKey)
      || typeof config.gatewayToken !== 'string'
      || !/^[A-Za-z0-9_-]{32,256}$/u.test(config.gatewayToken)
      || config.gatewayToken.startsWith('sk-')
      || config.gatewayToken === config.apiKey
      || typeof config.model !== 'string' || !/^[A-Za-z0-9._:/-]{1,150}$/u.test(config.model)) {
    throw new Error('Konfigurera leverantörens API-nyckel, en separat MIO_GATEWAY_TOKEN och MIO_AI_MODEL.');
  }
  if (config.lessonIntervalSeconds !== undefined && (!Number.isSafeInteger(config.lessonIntervalSeconds)
      || config.lessonIntervalSeconds < 60 || config.lessonIntervalSeconds > 3600)) throw new Error('Lektionsintervallet måste vara 60–3600 sekunder.');
  for (const field of ['requestsPerMinute', 'requestsPerDay', 'upstreamTimeoutMs', 'bodyTimeoutMs']) {
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

async function readBody(request, timeoutMs, validate = validatePayload) {
  if (Number(request.headers['content-length']) > MAX_BODY_BYTES) {
    throw new RequestError(413, 'request_too_large');
  }
  let timer;
  try {
    return await Promise.race([
      (async () => {
        const chunks = [];
        let size = 0;
        for await (const chunk of request) {
          size += chunk.length;
          if (size > MAX_BODY_BYTES) throw new RequestError(413, 'request_too_large');
          chunks.push(chunk);
        }
        try {
          const text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks));
          return validate(JSON.parse(text));
        } catch (error) {
          if (error instanceof RequestError) throw error;
          throw new RequestError(400, 'invalid_json');
        }
      })(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new RequestError(408, 'request_timeout')), timeoutMs);
        timer.unref?.();
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function readUpstream(response, profile) {
  if (!response.ok) {
    await response.body?.cancel();
    const seconds = Number(response.headers.get('retry-after'));
    if ([400, 422].includes(response.status)) throw new RequestError(422, 'provider_model_incompatible');
    throw new RequestError(response.status === 429 ? 429 : 502, 'upstream_unavailable',
      Number.isFinite(seconds) && seconds > 0 ? Math.min(Math.ceil(seconds), 86400) : 60);
  }
  if (!response.headers.get('content-type')?.toLowerCase().startsWith('application/json')
      || Number(response.headers.get('content-length')) > MAX_UPSTREAM_BYTES || !response.body) {
    await response.body?.cancel();
    throw new RequestError(502, 'invalid_upstream_response');
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_UPSTREAM_BYTES) throw new RequestError(502, 'upstream_response_too_large');
      chunks.push(value);
    }
    let data;
    try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new RequestError(502, 'invalid_upstream_response'); }
    try { return providerResponseText(data, profile); }
    catch (error) {
      if (error instanceof ProviderResponseError) throw new RequestError(error.message === 'provider_model_incompatible' ? 422 : 502, error.message);
      throw new RequestError(502, 'invalid_upstream_response');
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

/** Single private user, one process. Counters contain numbers only; no transcripts or IPs are kept. */
export function createMioServer({ config = loadConfig(), fetchImpl = fetch, now = Date.now, reserveBudget, serverOptions = { maxHeaderSize: 8_192 } } = {}) {
  validateConfig(config);
  const expectedDigest = createHash('sha256').update(`Bearer ${config.gatewayToken}`).digest();
  let minuteBucket = -1;
  let dayBucket = -1;
  let minuteCount = 0;
  let dayCount = 0;
  let active = 0;
  const activeControllers = new Set();

  function authenticate(request) {
    const supplied = request.headers.authorization;
    if (typeof supplied !== 'string' || supplied.length > 263) return false;
    const suppliedDigest = createHash('sha256').update(supplied).digest();
    return timingSafeEqual(suppliedDigest, expectedDigest);
  }

  function reserveRequest() {
    const time = now();
    if (minuteBucket !== Math.floor(time / 60_000)) {
      minuteBucket = Math.floor(time / 60_000); minuteCount = 0;
    }
    if (dayBucket !== Math.floor(time / 86_400_000)) {
      dayBucket = Math.floor(time / 86_400_000); dayCount = 0;
    }
    if (minuteCount >= config.requestsPerMinute || dayCount >= config.requestsPerDay || active >= 2) {
      throw new RequestError(429, 'request_limit');
    }
    minuteCount += 1;
    dayCount += 1;
  }

  const server = createServer(serverOptions, async (request, response) => {
    try {
      if (request.method === 'GET' && request.url === '/health') {
        reply(response, 200, { status: 'ok' }); return;
      }
      if (request.method !== 'POST' || !['/v1/ask', '/v1/analyze', '/v1/lesson-notes'].includes(request.url)) {
        reply(response, 404, { error: 'not_found' }); return;
      }
      if (!authenticate(request)) { reply(response, 401, { error: 'unauthorized' }); return; }
      if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json'
          || request.headers['content-encoding']) {
        reply(response, 415, { error: 'json_required' }); return;
      }
      const isLesson = request.url === '/v1/lesson-notes';
      const isAnalysis = request.url === '/v1/analyze';
      const payload = await readBody(request, config.bodyTimeoutMs, isLesson ? validateLessonPayload : isAnalysis ? validateAnalysisPayload : validatePayload);
      if (response.destroyed) return;
      providerProfile(config);
      reserveRequest();
      active += 1;
      const controller = new AbortController();
      activeControllers.add(controller);
      const timeout = setTimeout(() => controller.abort(), config.upstreamTimeoutMs);
      timeout.unref?.();
      const onClose = () => { if (!response.writableEnded) controller.abort(); };
      response.on('close', onClose);
      try {
        if (reserveBudget && !(await reserveBudget())) throw new RequestError(429, 'request_limit');
        if (controller.signal.aborted || response.destroyed) return;
        const provider = providerRequest({ config, mode: isLesson ? 'lesson' : isAnalysis ? 'analyze' : 'ask', payload });
        const upstream = await fetchImpl(provider.url, {
          method: 'POST',
          headers: provider.headers,
          redirect: 'manual',
          signal: controller.signal,
          body: JSON.stringify(provider.body)
        });
        const answer = await readUpstream(upstream, provider.profile);
        if (isLesson) {
          let result;
          try { result = validateLessonResult(JSON.parse(answer), payload); }
          catch { throw new RequestError(502, 'invalid_lesson_result'); }
          reply(response, 200, { ...result, metadata: { provider: config.provider ?? 'openai', model: config.model,
            promptVersion: PROMPT_VERSION, lessonIntervalSeconds: Math.max(60, config.lessonIntervalSeconds ?? 60) } });
        } else if (isAnalysis) {
          let result;
          try { result = validateAnalysisResult(JSON.parse(answer), payload); }
          catch { throw new RequestError(502, 'invalid_analysis_result'); }
          reply(response, 200, result);
        } else {
          let result;
          try { result = validateAskResult(JSON.parse(answer)); }
          catch { throw new RequestError(502, 'invalid_upstream_answer'); }
          reply(response, 200, result);
        }
      } catch (error) {
        if (controller.signal.aborted) throw new RequestError(504, 'upstream_timeout');
        if (error instanceof RequestError) throw error;
        throw new RequestError(502, 'upstream_unavailable');
      } finally {
        clearTimeout(timeout);
        response.removeListener('close', onClose);
        activeControllers.delete(controller);
        active -= 1;
      }
    } catch (error) {
      // Upstream bodies, error messages, credentials and user text must never enter logs or errors.
      if (error instanceof ProviderCompatibilityError) reply(response, 422, { error: 'provider_model_incompatible' });
      else if (error instanceof RequestError) reply(response, error.status, { error: error.code }, error.retryAfter);
      else reply(response, 500, { error: 'request_failed' });
    }
  });
  server.requestTimeout = 10_000;
  server.headersTimeout = 5_000;
  server.keepAliveTimeout = 1_000;
  server.maxRequestsPerSocket = 1;
  server.on('clientError', (_, socket) => socket.destroy());
  server.on('close', () => { for (const controller of activeControllers) controller.abort(); });
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
