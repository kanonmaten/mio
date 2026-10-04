// Test-only entry: exercise the shipped wrapper with an actual Worker Request.signal.
import worker from '../src/worker.mjs';

const token = 'fixture_gateway_token_01234567890123456789';
export default {
  async fetch(request, env, context) {
    let quotaCalls = 0;
    const controller = new AbortController();
    const requestBody = JSON.stringify({ question: 'Syntetiskt prov', context: [] });
    const options = new URL(request.url).searchParams;
    const scenario = options.get('scenario') ?? 'cancel-quota';
    const syntheticEnvironment = { ...env, MIO_LIMITS: { prepare: () => ({ bind: () => ({ first: async () => {
      quotaCalls++;
      if (scenario === 'quota' && quotaCalls <= 2) return new Promise(() => {});
      if (['cancel-fetch', 'cancel-response'].includes(scenario) && quotaCalls === 1) {
        setTimeout(() => controller.abort(), 30);
      }
      if (scenario !== 'cancel-quota') return { id: 1 };
      controller.abort();
      // A late, uncancellable D1 result must not turn cancellation into inference.
      await new Promise(resolve => setTimeout(resolve, 30));
      return { id: 1 };
    } }) }) } };
    if (options.has('before')) controller.abort();
    const send = () => worker.fetch(new Request('https://mio.example/v1/ask', {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
        'X-Mio-Runtime-Request': 'attacker-supplied-internal-binding' },
      body: scenario.endsWith('body') ? new ReadableStream({ start(stream) {
        stream.enqueue(new TextEncoder().encode('{"question":'));
      } }) : requestBody, signal: controller.signal
    }), syntheticEnvironment, context);
    if (scenario === 'quota') {
      const first = await Promise.all([send(), send()]);
      const results = await Promise.all(first.map(async response => ({ status: response.status, body: await response.json() })));
      const recovered = await send();
      return Response.json({ results, recovered: recovered.status, quotaCalls });
    }
    if (scenario === 'cancel-body') setTimeout(() => controller.abort(), 30);
    const response = await send();
    const headers = new Headers(response.headers);
    headers.set('X-Test-Quota-Calls', String(quotaCalls));
    if (['cancel-fetch', 'cancel-response'].includes(scenario)) {
      const recovered = await worker.fetch(new Request('https://mio.example/v1/ask', {
        method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: requestBody
      }), syntheticEnvironment, context);
      headers.set('X-Test-Recovered-Status', String(recovered.status));
    }
    return new Response(response.body, { status: response.status, headers });
  }
};
