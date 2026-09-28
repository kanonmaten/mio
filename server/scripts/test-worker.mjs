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

// A separate isolate verifies the Groq Chat Completions adapter and new lesson route.
let groqCalls = 0;
const groqOptions = convertV4MiniflareOptions({
  modules: true, scriptPath: fileURLToPath(new URL('../dist/worker.js', import.meta.url)),
  compatibilityDate: '2025-09-01', compatibilityFlags: ['nodejs_compat'],
  bindings: { MIO_AI_PROVIDER: 'groq', MIO_AI_MODEL: 'qwen/qwen3.8-27b', GROQ_API_KEY: 'fixture-groq',
    MIO_GATEWAY_TOKEN: token, MIO_REQUESTS_PER_MINUTE: '6', MIO_REQUESTS_PER_DAY: '2', MIO_LESSON_INTERVAL_SECONDS: '120' },
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
  assert.equal((await sendGroq('/v1/lesson-notes', { ...payload, mode: 'lesson' })).status, 429);
  assert.equal(groqCalls, 2);
  console.log('Groq Worker runtime: strict ask, detailed lessons, metadata, pacing and shared D1 quota PASS. No external requests.');
} finally { await groqRuntime.dispose(); }
