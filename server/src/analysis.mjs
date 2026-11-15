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
function date(value) {
  if (typeof value !== 'string') return false;
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$/u.exec(value);
  if (!parts) return false;
  const [year, month, day, hour, minute, second, offsetHour, offsetMinute] = parts.slice(1).map(part => Number(part ?? 0));
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  // Date.parse normalizes impossible days and 24:00; original calendar components must be valid.
  return month >= 1 && month <= 12 && day >= 1 && day <= days[month - 1]
    && hour <= 23 && minute <= 59 && second <= 59 && offsetHour <= 23 && offsetMinute <= 59
    && Number.isFinite(Date.parse(value));
}
// A day without a clock time ("YYYY-MM-DD"): an all-day event or a task due that day.
function day(value) {
  if (typeof value !== 'string') return false;
  const parts = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(value);
  return parts !== null && date(`${value}T00:00:00Z`);
}
const scheduled = value => value === null || date(value) || day(value);
export function validateAnalysisPayload(value) {
  if (!keys(value, ['mode', 'timeZone', 'fragments']) || !['everyday', 'lesson'].includes(value.mode)
      || !text(value.timeZone, 100) || !Array.isArray(value.fragments)
      || value.fragments.length < 1 || value.fragments.length > 16) throw new Error('invalid_analysis');
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
  // A backlog may send up to twelve new and three context sources in one call (2026-10-13).
  if (total > 16_000) throw new Error('analysis_too_large');
  return value;
}
// Tolerant quote lookup. Models often change case, spacing or punctuation in a quote, or join
// two passages with an ellipsis. Letters and digits must still match the source in order, and
// the evidence handed to the app is always the exact source substring, never the model's text.
const IGNORED = /[\s\p{P}\p{S}]/u;
function fold(value) {
  const units = []; const spans = [];
  let offset = 0; let cluster = ''; let start = 0;
  const flush = end => {
    if (!cluster) return;
    if (!IGNORED.test(cluster)) {
      for (const unit of cluster.normalize('NFKC').toLowerCase()) { units.push(unit); spans.push([start, end]); }
    }
    cluster = '';
  };
  for (const character of value) {
    if (cluster && /\p{M}/u.test(character)) cluster += character;
    else { flush(offset); cluster = character; start = offset; }
    offset += character.length;
  }
  flush(offset);
  return { folded: units.join(''), spans };
}
export function exactQuote(source, evidence) {
  if (typeof source !== 'string' || typeof evidence !== 'string' || !evidence.trim()) return null;
  if (source.includes(evidence)) return evidence;
  const haystack = fold(source);
  const pieces = [evidence, ...evidence.split(/…|\.{3,}|\[\.\.\.\]/u)].map(piece => fold(piece).folded)
    .filter((piece, index) => piece.length >= (index === 0 ? 4 : 8));
  pieces.sort((left, right) => right.length - left.length);
  for (const piece of pieces) {
    const index = haystack.folded.indexOf(piece);
    if (index < 0) continue;
    const quote = source.slice(haystack.spans[index][0], haystack.spans[index + piece.length - 1][1]);
    if (text(quote, 600)) return quote;
  }
  return null;
}
/** Returns repaired { sourceIDs, evidence } with an exact quote, or null when nothing grounds the item. */
function ground(item, sources) {
  if (!Array.isArray(item.sourceIDs) || typeof item.evidence !== 'string'
      || Buffer.byteLength(item.evidence, 'utf8') > 2_400) return null;
  const ids = [...new Set(item.sourceIDs.filter(id => typeof id === 'string' && sources.has(id)))].slice(0, 8);
  for (const id of ids) {
    const quote = exactQuote(sources.get(id), item.evidence);
    if (quote) return { sourceIDs: ids, evidence: quote };
  }
  // The quote may come from a fragment the model forgot to list; the source proves itself.
  for (const [id, source] of sources) {
    if (ids.includes(id) || ids.length >= 8) continue;
    const quote = exactQuote(source, item.evidence);
    if (quote) return { sourceIDs: [...ids, id], evidence: quote };
  }
  return null;
}
// A clock time without an offset is local time in the request's time zone.
function withOffset(value, timeZone) {
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?$/u.exec(value);
  if (!parts) return null;
  const [year, month, dayOfMonth, hour, minute, second] = parts.slice(1).map(part => Number(part ?? 0));
  const wall = Date.UTC(year, month - 1, dayOfMonth, hour, minute, second);
  let formatted;
  try {
    formatted = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', year: 'numeric',
      month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
      .formatToParts(new Date(wall)).map(part => [part.type, Number(part.value)]));
  } catch { return null; }
  const minutes = Math.round((Date.UTC(formatted.year, formatted.month - 1, formatted.day, formatted.hour,
    formatted.minute, formatted.second) - wall) / 60_000);
  const pad = number => String(Math.abs(number)).padStart(2, '0');
  const repaired = `${parts[1]}-${parts[2]}-${parts[3]}T${parts[4]}:${parts[5]}:${pad(second)}`
    + `${minutes < 0 ? '-' : '+'}${pad(Math.trunc(Math.abs(minutes) / 60))}:${pad(Math.abs(minutes) % 60)}`;
  return date(repaired) ? repaired : null;
}
function schedule(value, timeZone) {
  if (scheduled(value)) return { ok: true, value };
  const repaired = typeof value === 'string' ? withOffset(value.trim(), timeZone) : null;
  return repaired ? { ok: true, value: repaired } : { ok: false };
}
const CANDIDATE_KEYS = ['kind', 'title', 'body', 'scheduledAt', 'sourceIDs', 'evidence'];
/** One candidate with exact evidence, or null. An unusable candidate is dropped, never passed on. */
function cleanCandidate(item, sources, payload) {
  if (!['plan', 'task', 'note'].includes(item.kind) || !text(item.title, 240) || typeof item.body !== 'string') return null;
  const when = schedule(item.scheduledAt, payload.timeZone);
  const grounded = ground(item, sources);
  if (!when.ok || !grounded) return null;
  // The app shows the user's own words from the source; an overlong body is not worth the answer.
  return { ...item, body: text(item.body, 2_000, true) ? item.body : '', scheduledAt: when.value, ...grounded };
}
/**
 * Validates the shape strictly and each item on its own: an item without a grounded quote,
 * with an invalid date or over a limit is removed, and the rest of the answer is kept. One bad
 * item used to reject the whole answer, which stopped the app's analysis (2026-11-15).
 */
export function validateAnalysisResult(value, payload, candidateKeys = CANDIDATE_KEYS) {
  if (!keys(value, ['candidates', 'highlights', 'uncertainties'])
      || !Array.isArray(value.candidates) || !Array.isArray(value.highlights) || !Array.isArray(value.uncertainties)
      || value.candidates.some(item => !keys(item, candidateKeys))
      || value.highlights.some(item => !keys(item, ['text', 'sourceIDs', 'evidence']))) throw new Error('invalid_analysis_result');
  const sources = new Map(payload.fragments.map(fragment => [fragment.id, fragment.text]));
  const candidates = value.candidates.map(item => cleanCandidate(item, sources, payload)).filter(Boolean).slice(0, 6);
  const highlights = payload.mode === 'everyday' ? [] : value.highlights.map(item => {
    const grounded = text(item.text, 1_500) ? ground(item, sources) : null;
    return grounded ? { ...item, ...grounded } : null;
  }).filter(Boolean).slice(0, 8);
  return { candidates, highlights, uncertainties: value.uncertainties.filter(item => text(item, 500)).slice(0, 6) };
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
    candidates: { type: 'array', items: object({
      ...ANALYSIS_FORMAT.schema.properties.candidates.items.properties,
      kind: { type: 'string', enum: ['plan', 'task'] }
    }) },
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
      || value.sections.length > 12 || !Array.isArray(value.candidates)) throw new Error('invalid_lesson_result');
  const checked = validateAnalysisResult({ candidates: value.candidates, highlights: [], uncertainties: value.uncertainties }, payload);
  const sources = new Map(payload.fragments.map(f => [f.id, f.text]));
  // Sections are the notes themselves: one that cannot be grounded rejects the part, and the
  // app retries or splits it. Homework candidates are extras and are dropped one by one.
  const sections = value.sections.map(section => {
    const grounded = keys(section, ['heading', 'body', 'sourceIDs', 'evidence']) && text(section.heading, 240)
      && text(section.body, 8_000) ? ground(section, sources) : null;
    if (!grounded) throw new Error('ungrounded_section');
    return { ...section, ...grounded };
  });
  return { candidates: checked.candidates.filter(item => ['plan', 'task'].includes(item.kind)),
    sections, uncertainties: checked.uncertainties };
}

export const ANALYSIS_V2_FORMAT = {
  ...ANALYSIS_FORMAT, name: 'mio_analysis_v2',
  schema: object({ ...ANALYSIS_FORMAT.schema.properties,
    candidates: { type: 'array', items: object({
      ...ANALYSIS_FORMAT.schema.properties.candidates.items.properties,
      replacesID: { type: ['string', 'null'] }
    }) }
  })
};
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/iu.test(value);
export function validateAnalysisV2Payload(value) {
  if (!keys(value, ['mode', 'timeZone', 'fragments', 'contextFragments', 'priorDecisions', 'contextLimited'])
      || value.mode !== 'everyday' || typeof value.contextLimited !== 'boolean'
      || !Array.isArray(value.fragments) || value.fragments.length < 1 || !Array.isArray(value.contextFragments)
      || !Array.isArray(value.priorDecisions) || value.priorDecisions.length > 12) throw new Error('invalid_analysis');
  // The existing source contract also enforces disjoint IDs and the shared sixteen-source/UTF-8 budget.
  validateAnalysisPayload({ mode: value.mode, timeZone: value.timeZone,
    fragments: [...value.fragments, ...value.contextFragments] });
  if (value.contextFragments.reduce((sum, f) => sum + Buffer.byteLength(f.text, 'utf8'), 0) > 4_000) {
    throw new Error('context_too_large');
  }
  const contextIDs = new Set(value.contextFragments.map(f => f.id));
  const decisionIDs = new Set();
  for (const decision of value.priorDecisions) {
    if (!keys(decision, ['id', 'kind', 'sourceIDs', 'isOpen']) || !uuid(decision.id)
        || decisionIDs.has(decision.id.toLowerCase()) || !['plan', 'task', 'note'].includes(decision.kind)
        || typeof decision.isOpen !== 'boolean' || !Array.isArray(decision.sourceIDs)
        || decision.sourceIDs.length < 1 || decision.sourceIDs.length > 8
        || new Set(decision.sourceIDs).size !== decision.sourceIDs.length
        || !decision.sourceIDs.every(id => contextIDs.has(id))) throw new Error('invalid_prior_decision');
    decisionIDs.add(decision.id.toLowerCase());
  }
  return value;
}
export function validateAnalysisV2Result(value, payload) {
  const checked = validateAnalysisResult(value, { mode: 'everyday', timeZone: payload.timeZone,
    fragments: [...payload.fragments, ...payload.contextFragments] }, [...CANDIDATE_KEYS, 'replacesID']);
  const newIDs = new Set(payload.fragments.map(f => f.id));
  const replacements = new Set();
  // Each rule below protects a decision the user already made. A candidate that breaks one is
  // dropped; the other candidates in the same answer are unaffected.
  const candidates = checked.candidates.filter(candidate => {
    if (!candidate.sourceIDs.some(id => newIDs.has(id))
        || !(candidate.replacesID === null || uuid(candidate.replacesID))) return false;
    const linked = payload.priorDecisions.filter(decision => decision.sourceIDs.some(id => candidate.sourceIDs.includes(id)));
    // Shared sources cannot identify which event changed. Closed events must never be revived.
    if (linked.length > 1 || linked.some(decision => !decision.isOpen)
        || (linked.length && candidate.replacesID === null)) return false;
    if (candidate.replacesID !== null) {
      const id = candidate.replacesID.toLowerCase();
      const decision = payload.priorDecisions.find(item => item.id.toLowerCase() === id);
      if (!decision?.isOpen || decision.kind !== candidate.kind || linked[0] !== decision
          || replacements.has(id)) return false;
      replacements.add(id);
    }
    return true;
  });
  return { ...checked, candidates };
}
