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
  bindings: { OPENAI_API_KEY: 'fixture-not-a-real-key', MIO_GATEWAY_TOKEN: token, MIO_OPENAI_MODEL: 'gpt-6-luna',
    MIO_REQUESTS_PER_MINUTE: '6', MIO_REQUESTS_PER_DAY: '2' },
  d1Databases: { MIO_LIMITS: 'test-limits' },
  outboundService: async request => {
    modelCalls++;
    assert.equal(request.headers.get('cf-access-client-id'), null);
    assert.equal(request.headers.get('cf-access-client-secret'), null);
    assert.equal(request.url, 'https://api.openai.com/v1/responses');
    const body = await request.json();
    assert.equal(body.store, false); assert.deepEqual(body.tools, []);
    const text = body.text.format.name === 'mio_analysis' ? JSON.stringify(result) : JSON.stringify({ answer: 'Ett syntetiskt svar.' });
    return Response.json({ status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }] });
  }
});
options.telemetry = { enabled: false };
options.cf = false;
const runtime = new Miniflare(options);
const send = (path, body, auth = token) => runtime.dispatchFetch(`https://mio.example${path}`, {
  method: 'POST', headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json',
    'CF-Access-Client-Id': 'fixture.access', 'CF-Access-Client-Secret': 'fixture-secret' }, body: JSON.stringify(body)
});
try {
  const db = await runtime.getD1Database('MIO_LIMITS');
  await db.exec((await readFile(new URL('../cloudflare/schema.sql', import.meta.url), 'utf8')).replaceAll('\n', ' '));
  assert.equal((await runtime.dispatchFetch('https://mio.example/health')).status, 200);
  for (const route of ['ask', 'analyze', 'lesson-notes']) {
    assert.equal((await send(`/v1/${route}`, {}, 'wrong')).status, 401);
  }
  assert.equal((await send('/v1/analyze', {})).status, 400);
  assert.equal(modelCalls, 0);
  const status = await runtime.dispatchFetch('https://mio.example/v1/status', { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(status.status, 200); assert.equal((await status.json()).configured, true);
  assert.equal((await runtime.dispatchFetch('https://mio.example/v1/status')).status, 401);
  const question = await send('/v1/ask', { question: 'Syntetiskt prov', context: [] });
  assert.equal(question.status, 200); assert.deepEqual(await question.json(), { answer: 'Ett syntetiskt svar.' });
  const analysis = await send('/v1/analyze', payload);
  assert.equal(analysis.status, 200); assert.deepEqual(await analysis.json(), result);
  assert.equal((await send('/v1/ask', { question: 'Över dagsgränsen', context: [] })).status, 429);
  assert.equal(modelCalls, 2);
  console.log('Worker runtime: health, auth, validation, ask, analyze and persistent budget PASS. No external requests.');
} finally { await runtime.dispose(); }

// A separate isolate verifies the Groq Chat Completions adapter and new lesson route.
let groqCalls = 0;
const groqOptions = convertV4MiniflareOptions({
  modules: true, scriptPath: fileURLToPath(new URL('../dist/worker.js', import.meta.url)),
  compatibilityDate: '2025-09-01', compatibilityFlags: ['nodejs_compat'],
  bindings: { MIO_AI_PROVIDER: 'groq', MIO_AI_MODEL: 'qwen/qwen3.8-27b', GROQ_API_KEY: 'fixture-groq',
    MIO_GATEWAY_TOKEN: token, MIO_REQUESTS_PER_MINUTE: '6', MIO_REQUESTS_PER_DAY: '3', MIO_LESSON_INTERVAL_SECONDS: '120' },
  d1Databases: { MIO_LIMITS: 'test-groq-limits' },
  outboundService: async request => {
    groqCalls++;
    assert.equal(request.url, 'https://api.groq.com/openai/v1/chat/completions');
    assert.equal(request.headers.get('authorization'), 'Bearer fixture-groq');
    const body = await request.json();
    assert.equal(body.reasoning_effort, 'none'); assert.equal(body.temperature, 0);
    assert.equal(body.response_format.json_schema.strict, true);
    const output = body.response_format.json_schema.name === 'mio_lesson_notes_v1' ? {
      candidates: [], sections: [{ heading: 'Plan', body: 'Biblioteket på tisdag klockan 15.', sourceIDs: [id], evidence: 'Vi ses på biblioteket' }], uncertainties: []
    } : body.response_format.json_schema.name === 'mio_analysis_v2' ? {
      ...result, candidates: [{ ...result.candidates[0], replacesID: null }]
    } : { answer: 'Syntetiskt Groq-svar.' };
    return Response.json({ choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify(output) } }] });
  }
});
groqOptions.telemetry = { enabled: false }; groqOptions.cf = false;
const groqRuntime = new Miniflare(groqOptions);
try {
  const db = await groqRuntime.getD1Database('MIO_LIMITS');
  await db.exec((await readFile(new URL('../cloudflare/schema.sql', import.meta.url), 'utf8')).replaceAll('\n', ' '));
  const sendGroq = (path, body) => groqRuntime.dispatchFetch(`https://mio.example${path}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body)
  });
  const lesson = await sendGroq('/v1/lesson-notes', { ...payload, mode: 'lesson' });
  assert.equal(lesson.status, 200);
  const value = await lesson.json();
  assert.equal(value.sections[0].heading, 'Plan');
  assert.equal(value.metadata.provider, 'groq'); assert.equal(value.metadata.lessonIntervalSeconds, 120);
  const ask = await sendGroq('/v1/ask', { question: 'Syntetiskt prov', context: [] });
  assert.equal(ask.status, 200); assert.deepEqual(await ask.json(), { answer: 'Syntetiskt Groq-svar.' });
  const v2 = await sendGroq('/v2/analyze', { ...payload, contextFragments: [], priorDecisions: [], contextLimited: false });
  assert.equal(v2.status, 200); assert.equal((await v2.json()).candidates[0].replacesID, null);
  assert.equal(v2.headers.get('x-mio-prompt-version'), '2026-09-30.1');
  assert.equal((await sendGroq('/v1/lesson-notes', { ...payload, mode: 'lesson' })).status, 429);
  assert.equal(groqCalls, 3);
  console.log('Groq Worker runtime: strict ask, detailed lessons, metadata, pacing and shared D1 quota PASS. No external requests.');
} finally { await groqRuntime.dispose(); }

// Status must remain authenticated and readable even when model initialization fails.
for (const bindings of [
  { MIO_AI_PROVIDER: 'unknown-provider', MIO_AI_MODEL: 'valid-looking-unsupported' },
  { MIO_AI_PROVIDER: 'groq', MIO_AI_MODEL: 'unreviewed-model', GROQ_API_KEY: 'fixture-key' },
  { MIO_AI_PROVIDER: 'groq', MIO_AI_MODEL: 'qwen/qwen3.8-27b' }
]) {
  let calls = 0;
  const invalidOptions = convertV4MiniflareOptions({ modules: true,
    scriptPath: fileURLToPath(new URL('../dist/worker.js', import.meta.url)),
    compatibilityDate: '2025-09-01', compatibilityFlags: ['nodejs_compat'],
    bindings: { ...bindings, MIO_GATEWAY_TOKEN: token },
    outboundService: async () => { calls++; throw new Error('No upstream allowed'); }
  });
  invalidOptions.telemetry = { enabled: false }; invalidOptions.cf = false;
  const invalidRuntime = new Miniflare(invalidOptions);
  try {
    const unauthorized = await invalidRuntime.dispatchFetch('https://mio.example/v1/status');
    assert.equal(unauthorized.status, 401);
    assert.match(unauthorized.headers.get('x-mio-request-id'), /^[a-f0-9-]{36}$/u);
    const status = await invalidRuntime.dispatchFetch('https://mio.example/v1/status', {
      headers: { Authorization: `Bearer ${token}` }
    });
    assert.equal(status.status, 200);
    const metadata = await status.json();
    assert.equal(metadata.configured, false); assert.equal(metadata.protocolVersion, 2);
    assert.deepEqual(metadata.capabilities, ['analysis-context-v2', 'ask-v1', 'analysis-v1', 'lesson-notes-v1']);
    assert.equal(status.headers.get('cache-control'), 'no-store');
    assert.equal(status.headers.get('x-mio-release'), '2026-09-30.1');
    assert.match(status.headers.get('x-mio-request-id'), /^[a-f0-9-]{36}$/u);
    assert.equal(calls, 0);
  } finally { await invalidRuntime.dispose(); }
}
console.log('Worker invalid configuration: authenticated safe status, no quota/model side effects PASS.');
