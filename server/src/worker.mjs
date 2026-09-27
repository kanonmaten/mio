import { httpServerHandler } from 'cloudflare:node';
import { createMioServer, loadConfig } from './server.mjs';
import { reserveCloudBudget } from './cloud-budget.mjs';

let handler;
export default {
  async fetch(request, env, context) {
    try {
      if (!handler) {
        const config = loadConfig(env);
        const server = createMioServer({ config, serverOptions: {}, reserveBudget: () => reserveCloudBudget(env.MIO_LIMITS, config) });
        server.listen(8787);
        handler = httpServerHandler({ port: 8787 });
      }
      return await handler.fetch(request, env, context);
    } catch {
      // Never expose secrets or provider errors when an account is not configured yet.
      return Response.json({ error: 'gateway_not_configured' }, { status: 503, headers: { 'Cache-Control': 'no-store' } });
    }
  }
};
