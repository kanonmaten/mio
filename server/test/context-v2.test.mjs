import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import * as analysis from '../src/analysis.mjs';
import { providerRequest } from '../src/provider.mjs';
import { createMioServer } from '../src/server.mjs';
const oldID = '00000000-0000-0000-0000-000000000001:0';
const newID = '00000000-0000-0000-0000-000000000002:0';
const decisionID = '00000000-0000-0000-0000-000000000003';
const token = 'fixture_gateway_token_01234567890123456789';
const config = { provider: 'openai', apiKey: 'fixture-key', gatewayToken: token, model: 'gpt-6-luna',
  requestsPerMinute: 6, requestsPerDay: 100, upstreamTimeoutMs: 1000, bodyTimeoutMs: 1000 };
const payload = { mode: 'everyday', timeZone: 'Europe/Stockholm',
  fragments: [{ id: newID, text: 'nej, torsdag i stället.', occurredAt: '2026-09-30T12:01:00Z' }],
  contextFragments: [{ id: oldID, text: 'Vi ses på biblioteket på tisdag klockan 15.', occurredAt: '2026-09-30T12:00:00Z' }],
  priorDecisions: [{ id: decisionID, kind: 'plan', sourceIDs: [oldID], isOpen: true }], contextLimited: false };
const result = { candidates: [{ kind: 'plan', title: 'Biblioteket', body: 'Kontrollera datum.', scheduledAt: null,
  sourceIDs: [oldID, newID], evidence: 'nej, torsdag i stället.', replacesID: decisionID }], highlights: [], uncertainties: [] };

test('v2 payload rejects unbounded context, overlapping sources, invalid decisions and unknown fields', () => {
  assert.equal(typeof analysis.validateAnalysisV2Payload, 'function');
  assert.equal(analysis.validateAnalysisV2Payload(payload), payload);
  const patchFragment = patch => [{ ...payload.contextFragments[0], ...patch }];
  for (const patch of [{ mode: 'lesson' }, { contextLimited: 'yes' }, { unexpected: true }, { fragments: [] },
    { contextFragments: patchFragment({ id: newID }) }, { contextFragments: patchFragment({ text: 'å'.repeat(2001) }) },
    { contextFragments: [{ ...payload.contextFragments[0], text: 'å'.repeat(1001) },
      { ...payload.contextFragments[0], id: oldID.replace(':0', ':1'), text: 'å'.repeat(1000) }] },
    { priorDecisions: Array(13).fill(payload.priorDecisions[0]) },
    { priorDecisions: [...payload.priorDecisions, ...payload.priorDecisions] },
    { priorDecisions: [{ ...payload.priorDecisions[0], id: 'invalid' }] },
    { priorDecisions: [{ ...payload.priorDecisions[0], sourceIDs: [newID] }] },
    { priorDecisions: [{ ...payload.priorDecisions[0], sourceIDs: [] }] },
    { priorDecisions: [{ ...payload.priorDecisions[0], sourceIDs: [oldID, oldID] }] },
    { priorDecisions: [{ ...payload.priorDecisions[0], isOpen: 1 }] },
    { priorDecisions: [{ ...payload.priorDecisions[0], kind: 'memory' }] },
    { fragments: Array.from({ length: 8 }, (_, index) => ({ ...payload.fragments[0], id: newID.replace(':0', `:${index}`) })) },
    { fragments: Array.from({ length: 3 }, (_, index) => ({ ...payload.fragments[0], id: newID.replace(':0', `:${index}`), text: 'ö'.repeat(1700) })) }
  ]) assert.throws(() => analysis.validateAnalysisV2Payload({ ...payload, ...patch }));
});

test('v2 candidates require new evidence sources and explicit unambiguous open replacement', () => {
  assert.equal(typeof analysis.validateAnalysisV2Result, 'function');
  assert.equal(analysis.validateAnalysisV2Result(result, payload), result);
  for (const patch of [{ sourceIDs: [oldID], evidence: 'Vi ses' }, { sourceIDs: ['invented'] },
    { replacesID: null }, { replacesID: 'invalid' }, { replacesID: '00000000-0000-0000-0000-000000000004' },
    { kind: 'task' }, { sourceIDs: [newID] }, { evidence: 'never said' }]) {
    assert.throws(() => analysis.validateAnalysisV2Result({ ...result, candidates: [{ ...result.candidates[0], ...patch }] }, payload));
  }
  const { replacesID, ...missing } = result.candidates[0];
  assert.throws(() => analysis.validateAnalysisV2Result({ ...result, candidates: [missing] }, payload));
  assert.throws(() => analysis.validateAnalysisV2Result(result, { ...payload, priorDecisions: [{ ...payload.priorDecisions[0], isOpen: false }] }));
  assert.throws(() => analysis.validateAnalysisV2Result(result, { ...payload, priorDecisions: [...payload.priorDecisions,
    { ...payload.priorDecisions[0], id: '00000000-0000-0000-0000-000000000004' }] }));
  assert.throws(() => analysis.validateAnalysisV2Result({ ...result, candidates: [...result.candidates, ...result.candidates] }, payload));
  assert.doesNotThrow(() => analysis.validateAnalysisV2Result({ ...result, candidates: [{ ...result.candidates[0], sourceIDs: [newID], replacesID: null }] }, payload));
  assert.doesNotThrow(() => analysis.validateAnalysisV2Result({ ...result, candidates: [{ ...result.candidates[0], replacesID: null }] }, { ...payload, priorDecisions: [] }));
  assert.doesNotThrow(() => analysis.validateAnalysisV2Result({ ...result, candidates: [{ ...result.candidates[0], sourceIDs: [newID], replacesID: null }] }, { ...payload, priorDecisions: [{ ...payload.priorDecisions[0], isOpen: false }] }));
});

test('v2 upstream receives its strict replacement schema while legacy schema stays unchanged', () => {
  const request = providerRequest({ config, mode: 'analyze-v2', payload });
  assert.equal(request.body.text.format.name, 'mio_analysis_v2');
  const candidate = request.body.text.format.schema.properties.candidates.items;
  assert.equal(candidate.additionalProperties, false);
  assert.ok(candidate.required.includes('replacesID'));
  assert.deepEqual(candidate.properties.replacesID.type, ['string', 'null']);
  assert.deepEqual(JSON.parse(request.body.input[0].content[0].text), payload);
  assert.equal(request.body.reasoning.effort, 'none');
  assert.equal(request.body.temperature, 0);
  assert.equal('replacesID' in analysis.ANALYSIS_FORMAT.schema.properties.candidates.items.properties, false);
});

async function fixture(t, output = result) {
  let calls = 0, budgets = 0;
  const server = createMioServer({ config, reserveBudget: async () => { budgets++; return true; }, fetchImpl: async () => {
    calls++;
    return Response.json({ status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: JSON.stringify(output) }] }] });
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  return { calls: () => calls, budgets: () => budgets, get: auth => fetch(`${base}/v1/status`, { headers: { Authorization: `Bearer ${auth}` } }),
    send: (body = payload, auth = token) => fetch(`${base}/v2/analyze`, { method: 'POST', headers: {
      Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json', 'X-Mio-Request-ID': 'untrusted' }, body: JSON.stringify(body) }) };
}

test('v2 HTTP endpoint validates before quota and returns sanitized metadata on success and failure', async t => {
  const f = await fixture(t);
  assert.equal((await f.send(payload, 'wrong')).status, 401);
  assert.equal((await f.send({ ...payload, contextLimited: 5 })).status, 400);
  assert.equal(f.calls(), 0); assert.equal(f.budgets(), 0);
  const r = await f.send(); assert.equal(r.status, 200); assert.deepEqual(await r.json(), result);
  for (const response of [r, await f.send(payload, 'wrong')]) {
    assert.equal(response.headers.get('x-mio-release'), '2026-09-30.1');
    assert.equal(response.headers.get('x-mio-provider'), 'openai');
    assert.equal(response.headers.get('x-mio-model'), 'gpt-6-luna');
    assert.equal(response.headers.get('x-mio-prompt-version'), '2026-09-30.1');
    assert.match(response.headers.get('x-mio-request-id'), /^[a-f0-9-]{36}$/u);
  }
});

test('status authenticates without model calls or budget and advertises implemented context contract', async t => {
  const f = await fixture(t);
  assert.equal((await f.get('wrong')).status, 401);
  const r = await f.get(token); assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { protocolVersion: 2, release: '2026-09-30.1', configured: true,
    provider: 'openai', model: 'gpt-6-luna', promptVersion: '2026-09-30.1',
    capabilities: ['analysis-context-v2', 'ask-v1', 'analysis-v1', 'lesson-notes-v1'] });
  assert.equal(f.calls(), 0); assert.equal(f.budgets(), 0);
});

test('v2 invalid upstream replacement cannot escape as a proposal', async t => {
  const f = await fixture(t, { ...result, candidates: [{ ...result.candidates[0], replacesID: null }] });
  const r = await f.send(); assert.equal(r.status, 502);
  assert.deepEqual(await r.json(), { error: 'invalid_analysis_result' });
});
