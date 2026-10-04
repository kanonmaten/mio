import { httpServerHandler } from 'cloudflare:node';
import { createMioServer, loadConfig } from './server.mjs';
import { reserveCloudBudgetOutcome, readCloudBudget } from './cloud-budget.mjs';
import { authenticated, statusFromEnvironment, gatewayStatusV2, metadataHeaders, RELEASE } from './status.mjs';

let handler;
const requestBindings = new Map();

async function statusQuota(database, config, signal) {
  let timer; let onCancel;
  try {
    return await Promise.race([
      readCloudBudget(database, config),
      new Promise(resolve => {
        timer = setTimeout(() => resolve(null), 2_000);
        onCancel = () => resolve(null);
        if (signal.aborted) onCancel(); else signal.addEventListener('abort', onCancel, { once: true });
      })
    ]);
  } catch { return null; }
  finally { clearTimeout(timer); if (onCancel) signal.removeEventListener('abort', onCancel); }
}

export default {
  async fetch(request, env, context) {
    try {
      // Protected discovery never initializes a model or reserves shared quota.
      const url = new URL(request.url);
      if (request.method === 'GET' && ['/v1/status', '/v2/status'].includes(url.pathname) && !url.search) {
        if (!authenticated(request.headers.get('authorization'), env.MIO_GATEWAY_TOKEN)) {
          return Response.json({ error: 'unauthorized' }, { status: 401, headers: {
            'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
            ...metadataHeaders({ provider: '', model: '', promptVersion: '2026-09-30.1' })
          } });
        }
        let status;
        if (url.pathname === '/v1/status') status = statusFromEnvironment(env, loadConfig);
        else {
          let config;
          try { config = loadConfig(env); }
          catch { config = { provider: env.MIO_AI_PROVIDER ?? 'openai', model: env.MIO_AI_MODEL ?? env.MIO_OPENAI_MODEL ?? '',
            taskProfiles: env.MIO_AI_TASK_PROFILES, globalConfigurationError: 'gateway_configuration_invalid' }; }
          status = gatewayStatusV2(config, config.globalConfigurationError ? null : await statusQuota(env.MIO_LIMITS, config, request.signal));
        }
        return Response.json(status, { headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
          ...metadataHeaders({ ...status, provider: status.provider ?? '', model: status.model ?? '', promptVersion: status.promptVersion ?? '' }) } });
      }
      const config = loadConfig(env);
      config.budgetDatabase = env.MIO_LIMITS;
      if (!handler) {
        const server = createMioServer({ config, serverOptions: {},
          reserveBudget: current => reserveCloudBudgetOutcome(current.budgetDatabase, current),
          configurationForRequest: request => requestBindings.get(request.headers['x-mio-runtime-request'])?.config,
          requestSignal: request => requestBindings.get(request.headers['x-mio-runtime-request'])?.signal });
        server.listen(8787);
        handler = httpServerHandler({ port: 8787 });
      }
      // The bridge does not propagate Request.signal. An opaque local binding also
      // captures current credentials/profiles for each request, including rotations.
      const id = crypto.randomUUID();
      requestBindings.set(id, { signal: request.signal, config });
      try {
        const headers = new Headers(request.headers);
        headers.set('X-Mio-Runtime-Request', id);
        return await handler.fetch(new Request(request, { headers }), env, context);
      } finally { requestBindings.delete(id); }
    } catch {
      return Response.json({ error: 'gateway_not_configured' }, { status: 503,
        headers: { 'Cache-Control': 'no-store', 'X-Mio-Release': RELEASE } });
    }
  }
};
