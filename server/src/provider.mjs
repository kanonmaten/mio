import { ASK_SYSTEM, ANALYSIS_SYSTEM } from './prompts.mjs';
import { ANALYSIS_FORMAT } from './analysis.mjs';

// Provider-specific wire format lives here; /v1/ask and /v1/analyze stay stable for iOS.
// New providers must preserve grounding, limits, no tools and retention controls.
export function validateProvider(provider) {
  if (provider !== 'openai') throw new Error('Endast OpenAI-adaptern finns ännu.');
}
export function providerRequest({ config, mode, payload }) {
  validateProvider(config.provider ?? 'openai');
  const analysis = mode === 'analyze';
  return {
    url: 'https://api.openai.com/v1/responses',
    headers: { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' },
    body: {
      model: config.model, store: false,
      max_output_tokens: analysis ? 3_000 : 1_000,
      instructions: analysis ? ANALYSIS_SYSTEM : ASK_SYSTEM,
      ...(analysis ? { text: { format: ANALYSIS_FORMAT } } : {}),
      input: [{ role: 'user', content: [{ type: 'input_text', text: JSON.stringify(payload) }] }],
      tools: []
    }
  };
}

export class ProviderResponseError extends Error {}

export function providerResponseText(data) {
  if (data?.status !== 'completed' || !Array.isArray(data.output)) {
    throw new ProviderResponseError('incomplete_upstream_response');
  }
  const answer = data.output
    .filter(item => item?.type === 'message' && item.role === 'assistant' && Array.isArray(item.content))
    .flatMap(item => item.content)
    .filter(part => part?.type === 'output_text' && typeof part.text === 'string')
    .map(part => part.text).join('\n');
  if (!answer.trim() || Buffer.byteLength(answer, 'utf8') > 16_000) {
    throw new ProviderResponseError('invalid_upstream_answer');
  }
  return answer;
}
