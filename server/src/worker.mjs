import { httpServerHandler } from 'cloudflare:node';
import { createMioServer, loadConfig } from './server.mjs';
import { reserveCloudBudget } from './cloud-budget.mjs';
import { authenticated, statusFromEnvironment, metadataHeaders, RELEASE } from './status.mjs';

let handler;
export default {
  async fetch(request, env, context) {
    try {
      // Status bypasses model initialization and D1, while retaining gateway and outer Access auth.
      const url = new URL(request.url);
      if (request.method === 'GET' && url.pathname === '/v1/status' && !url.search) {
        if (!authenticated(request.headers.get('authorization'), env.MIO_GATEWAY_TOKEN)) {
          return Response.json({ error: 'unauthorized' }, { status: 401, headers: {
            'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
            ...metadataHeaders({ provider: '', model: '', promptVersion: '2026-09-30.1' })
          } });
        }
        const status = statusFromEnvironment(env, loadConfig);
        return Response.json(status, { headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
          ...metadataHeaders(status) } });
      }
      if (!handler) {
        const config = loadConfig(env);
        const server = createMioServer({ config, serverOptions: {}, reserveBudget: () => reserveCloudBudget(env.MIO_LIMITS, config) });
        server.listen(8787);
        handler = httpServerHandler({ port: 8787 });
      }
      return await handler.fetch(request, env, context);
    } catch {
      // Never expose secrets or provider errors when an account is not configured yet.
      return Response.json({ error: 'gateway_not_configured' }, { status: 503, headers: { 'Cache-Control': 'no-store', 'X-Mio-Release': RELEASE } });
    }
  }
};
