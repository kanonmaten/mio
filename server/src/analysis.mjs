// Transcript text is untrusted source material, never an instruction or a tool request.
export { ANALYSIS_SYSTEM as ANALYSIS_INSTRUCTIONS } from './prompts.mjs';

const sourceFields = {
  sourceIDs: { type: 'array', items: { type: 'string' } },
  evidence: { type: 'string' }
};
function object(properties) {
  return { type: 'object', properties, required: Object.keys(properties), additionalProperties: false };
}
export const ANALYSIS_FORMAT = {
  type: 'json_schema', name: 'mio_analysis', strict: true,
  schema: object({
    candidates: { type: 'array', items: object({
      kind: { type: 'string', enum: ['plan', 'task', 'note'] },
      title: { type: 'string' }, body: { type: 'string' },
      scheduledAt: { type: ['string', 'null'] }, ...sourceFields
    }) },
    highlights: { type: 'array', items: object({ text: { type: 'string' }, ...sourceFields }) },
    uncertainties: { type: 'array', items: { type: 'string' } }
  })
};
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === names.length && names.every(key => Object.hasOwn(value, key));
const text = (value, max, empty = false) => typeof value === 'string'
  && (empty || value.trim().length > 0) && Buffer.byteLength(value, 'utf8') <= max;
const date = value => typeof value === 'string'
  && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/u.test(value)
  && Number.isFinite(Date.parse(value));
export function validateAnalysisPayload(value) {
  if (!keys(value, ['mode', 'timeZone', 'fragments']) || !['everyday', 'lesson'].includes(value.mode)
      || !text(value.timeZone, 100) || !Array.isArray(value.fragments)
      || value.fragments.length < 1 || value.fragments.length > 8) throw new Error('invalid_analysis');
  try { new Intl.DateTimeFormat('sv-SE', { timeZone: value.timeZone }); }
  catch { throw new Error('invalid_timezone'); }
  const ids = new Set();
  let total = 0;
  for (const fragment of value.fragments) {
    if (!keys(fragment, ['id', 'text', 'occurredAt']) || !text(fragment.id, 80)
        || !/^[A-Fa-f0-9-]{36}:\d{1,6}$/u.test(fragment.id)
        || ids.has(fragment.id) || !text(fragment.text, 4_000) || !date(fragment.occurredAt)) {
      throw new Error('invalid_fragment');
    }
    ids.add(fragment.id); total += Buffer.byteLength(fragment.text, 'utf8');
  }
  if (total > 10_000) throw new Error('analysis_too_large');
  return value;
}
export function validateAnalysisResult(value, payload) {
  if (!keys(value, ['candidates', 'highlights', 'uncertainties'])
      || !Array.isArray(value.candidates) || value.candidates.length > 6
      || !Array.isArray(value.highlights) || value.highlights.length > 8
      || !Array.isArray(value.uncertainties) || value.uncertainties.length > 6
      || value.uncertainties.some(item => !text(item, 500))
      || (payload.mode === 'everyday' && value.highlights.length)) throw new Error('invalid_analysis_result');
  const sources = new Map(payload.fragments.map(fragment => [fragment.id, fragment.text]));
  function grounded(item) {
    return Array.isArray(item.sourceIDs) && item.sourceIDs.length > 0 && item.sourceIDs.length <= 8
      && new Set(item.sourceIDs).size === item.sourceIDs.length
      && item.sourceIDs.every(id => sources.has(id)) && text(item.evidence, 600)
      && item.sourceIDs.some(id => sources.get(id).includes(item.evidence));
  }
  for (const item of value.candidates) {
    if (!keys(item, ['kind', 'title', 'body', 'scheduledAt', 'sourceIDs', 'evidence'])
        || !['plan', 'task', 'note'].includes(item.kind) || !text(item.title, 240)
        || !text(item.body, 2_000, true) || !(item.scheduledAt === null || date(item.scheduledAt))
        || !grounded(item)) throw new Error('ungrounded_candidate');
  }
  for (const item of value.highlights) {
    if (!keys(item, ['text', 'sourceIDs', 'evidence']) || !text(item.text, 1_500) || !grounded(item)) {
      throw new Error('ungrounded_highlight');
    }
  }
  return value;
}

export const ASK_FORMAT = {
  type: 'json_schema', name: 'mio_answer', strict: true,
  schema: object({ answer: { type: 'string' } })
};
export function validateAskResult(value) {
  if (!keys(value, ['answer']) || !text(value.answer, 16_000)) throw new Error('invalid_answer');
  return value;
}
export const LESSON_FORMAT = {
  type: 'json_schema', name: 'mio_lesson_notes_v1', strict: true,
  schema: object({
    candidates: ANALYSIS_FORMAT.schema.properties.candidates,
    sections: { type: 'array', items: object({
      heading: { type: 'string' }, body: { type: 'string' }, ...sourceFields
    }) },
    uncertainties: ANALYSIS_FORMAT.schema.properties.uncertainties
  })
};
export function validateLessonPayload(value) {
  validateAnalysisPayload(value);
  if (value.mode !== 'lesson' || value.fragments.reduce((sum, f) => sum + Buffer.byteLength(f.text, 'utf8'), 0) > 3_500) {
    throw new Error('invalid_lesson');
  }
  return value;
}
export function validateLessonResult(value, payload) {
  if (!keys(value, ['candidates', 'sections', 'uncertainties']) || !Array.isArray(value.sections)
      || value.sections.length > 12 || !Array.isArray(value.candidates)
      || value.candidates.some(item => !['plan', 'task'].includes(item.kind))) throw new Error('invalid_lesson_result');
  validateAnalysisResult({ candidates: value.candidates, highlights: [], uncertainties: value.uncertainties }, payload);
  const sources = new Map(payload.fragments.map(f => [f.id, f.text]));
  for (const section of value.sections) {
    if (!keys(section, ['heading', 'body', 'sourceIDs', 'evidence']) || !text(section.heading, 240)
        || !text(section.body, 8_000) || !text(section.evidence, 600)
        || !Array.isArray(section.sourceIDs) || section.sourceIDs.length < 1 || section.sourceIDs.length > 8
        || new Set(section.sourceIDs).size !== section.sourceIDs.length
        || section.sourceIDs.some(id => !sources.has(id))
        || !section.sourceIDs.some(id => sources.get(id).includes(section.evidence))) throw new Error('ungrounded_section');
  }
  return value;
}
