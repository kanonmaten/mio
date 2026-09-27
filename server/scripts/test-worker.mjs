// Runs the actual deploy bundle in workerd, with all outbound traffic intercepted.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const token = 'fixture_gateway_token_01234567890123456789';
const id = '00000000-0000-0000-0000-000000000001:0';
const payload = { mode: 'everyday', timeZone: 'Europe/Stockholm', fragments: [
  { id, text: 'Vi ses på biblioteket på tisdag klockan 15.', occurredAt: '2026-09-26T08:00:00Z' }
] };
const result = { candidates: [{ kind: 'plan', title: 'Biblioteket', body: 'Kontrollera tiden.',
  scheduledAt: '2026-09-29T15:00:00+02:00', sourceIDs: [id], evidence: payload.fragments[0].text }], highlights: [], uncertainties: [] };
let modelCalls = 0;
const options = convertV4MiniflareOptions({
  modules: true, scriptPath: fileURLToPath(new URL('../dist/worker.js', import.meta.url)),
  compatibilityDate: '2025-09-01', compatibilityFlags: ['nodejs_compat'],
  bindings: { OPENAI_API_KEY: 'fixture-not-a-real-key', MIO_GATEWAY_TOKEN: token, MIO_OPENAI_MODEL: 'fixture-model',
    MIO_REQUESTS_PER_MINUTE: '6', MIO_REQUESTS_PER_DAY: '2' },
  d1Databases: { MIO_LIMITS: 'test-limits' },
  outboundService: async request => {
    modelCalls++;
    assert.equal(request.url, 'https://api.openai.com/v1/responses');
    const body = await request.json();
    assert.equal(body.store, false); assert.deepEqual(body.tools, []);
    const text = body.text ? JSON.stringify(result) : 'Ett syntetiskt svar.';
    return Response.json({ status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }] });
  }
});
options.telemetry = { enabled: false };
options.cf = false;
const runtime = new Miniflare(options);
const send = (path, body, auth = token) => runtime.dispatchFetch(`https://mio.example${path}`, {
  method: 'POST', headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body)
});
try {
  const db = await runtime.getD1Database('MIO_LIMITS');
  await db.exec((await readFile(new URL('../cloudflare/schema.sql', import.meta.url), 'utf8')).replaceAll('\n', ' '));
  assert.equal((await runtime.dispatchFetch('https://mio.example/health')).status, 200);
  assert.equal((await send('/v1/ask', { question: 'Syntetiskt prov', context: [] }, 'wrong')).status, 401);
  assert.equal((await send('/v1/analyze', {})).status, 400);
  assert.equal(modelCalls, 0);
  const question = await send('/v1/ask', { question: 'Syntetiskt prov', context: [] });
  assert.equal(question.status, 200); assert.deepEqual(await question.json(), { answer: 'Ett syntetiskt svar.' });
  const analysis = await send('/v1/analyze', payload);
  assert.equal(analysis.status, 200); assert.deepEqual(await analysis.json(), result);
  assert.equal((await send('/v1/ask', { question: 'Över dagsgränsen', context: [] })).status, 429);
  assert.equal(modelCalls, 2);
  console.log('Worker runtime: health, auth, validation, ask, analyze and persistent budget PASS. No external requests.');
} finally { await runtime.dispose(); }
