import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const folder = await mkdtemp(join(tmpdir(), 'mio-worker-regressions-'));
try {
  const bundle = join(folder, 'worker.mjs');
  await build({ entryPoints: [fileURLToPath(new URL('../test/worker-cancellation-entry.mjs', import.meta.url))],
    outfile: bundle, bundle: true, format: 'esm', platform: 'neutral', external: ['node:*', 'cloudflare:*'],
    define: { 'process.argv': '[]' }, logLevel: 'silent' });
  for (const scenario of ['cancel-quota', 'cancel-before', 'cancel-body', 'cancel-fetch', 'cancel-response', 'body', 'quota']) {
    let modelCalls = 0;
    const options = convertV4MiniflareOptions({ rootPath: folder, modules: true, scriptPath: bundle,
      compatibilityDate: '2025-09-01', compatibilityFlags: ['nodejs_compat'],
      bindings: { MIO_AI_PROVIDER: 'openai', MIO_AI_MODEL: 'gpt-6-luna', OPENAI_API_KEY: 'fixture-key',
        MIO_GATEWAY_TOKEN: 'fixture_gateway_token_01234567890123456789' },
      outboundService: async () => {
        modelCalls++;
        const answer = { status: 'completed', output: [{ type: 'message', role: 'assistant',
          content: [{ type: 'output_text', text: '{"answer":"Syntetiskt svar"}' }] }] };
        if (modelCalls === 1 && scenario === 'cancel-fetch') {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
        if (modelCalls === 1 && scenario === 'cancel-response') {
          let timer;
          const bytes = new TextEncoder().encode(JSON.stringify(answer));
          return new Response(new ReadableStream({
            start(stream) {
              stream.enqueue(bytes.slice(0, 10));
              timer = setTimeout(() => { stream.enqueue(bytes.slice(10)); stream.close(); }, 100);
            },
            cancel() { clearTimeout(timer); }
          }), { headers: { 'Content-Type': 'application/json' } });
        }
        return Response.json(answer);
      }
    });
    options.telemetry = { enabled: false }; options.cf = false;
    const runtime = new Miniflare(options);
    try {
      const started = performance.now();
      const response = await runtime.dispatchFetch(`https://fixture.example/cancel?scenario=${scenario}${scenario === 'cancel-before' ? '&before' : ''}`);
      if (scenario === 'quota') {
        assert.deepEqual(await response.json(), { results: [
          { status: 504, body: { error: 'upstream_timeout' } }, { status: 504, body: { error: 'upstream_timeout' } }
        ], recovered: 200, quotaCalls: 3 });
        assert.ok(performance.now() - started < 42_000, 'The production 40s deadline must bound hung D1 in workerd');
        assert.equal(modelCalls, 1);
        continue;
      }
      const expectedStatus = scenario === 'body' ? 408 : 499;
      assert.equal(response.status, expectedStatus);
      assert.deepEqual(await response.json(), { error: scenario === 'body' ? 'request_timeout' : 'request_cancelled' });
      const reachedProvider = ['cancel-fetch', 'cancel-response'].includes(scenario);
      assert.equal(response.headers.get('x-test-quota-calls'), scenario === 'cancel-quota' || reachedProvider ? '1' : '0');
      if (reachedProvider) assert.equal(response.headers.get('x-test-recovered-status'), '200');
      // Give the uncancellable reservation time to finish; it must never make a provider call.
      await new Promise(resolve => setTimeout(resolve, 60));
      assert.equal(modelCalls, reachedProvider ? 2 : 0);
    } finally { await runtime.dispose(); }
  }
  console.log('Worker execution: Request.signal before/during body, D1, fetch and response reading; 5s body limit, 40s hung D1, slot recovery PASS. No external requests.');
} finally { await rm(folder, { recursive: true, force: true }); }
