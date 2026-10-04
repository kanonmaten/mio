import { ASK_SYSTEM, ANALYSIS_SYSTEM, ANALYSIS_V2_SYSTEM, LESSON_SYSTEM,
  PROMPT_VERSION, ANALYSIS_V2_PROMPT_VERSION } from './prompts.mjs';
import { ASK_FORMAT, ANALYSIS_FORMAT, ANALYSIS_V2_FORMAT, LESSON_FORMAT,
  validateAskResult, validateAnalysisResult, validateAnalysisV2Result, validateLessonResult } from './analysis.mjs';

const POLICY = Object.freeze({ reasoning: 'off', temperature: 0, tools: 'none' });
const definitions = Object.freeze({
  ask: { system: ASK_SYSTEM, format: ASK_FORMAT, limit: 1_000, version: PROMPT_VERSION, validate: validateAskResult },
  analyze: { system: ANALYSIS_SYSTEM, format: ANALYSIS_FORMAT, limit: 3_000, version: PROMPT_VERSION, validate: validateAnalysisResult },
  'analyze-v2': { system: ANALYSIS_V2_SYSTEM, format: ANALYSIS_V2_FORMAT, limit: 3_000,
    version: ANALYSIS_V2_PROMPT_VERSION, validate: validateAnalysisV2Result },
  lesson: { system: LESSON_SYSTEM, format: LESSON_FORMAT, limit: 3_000, version: PROMPT_VERSION, validate: validateLessonResult }
});
function definition(mode) {
  if (!Object.hasOwn(definitions, mode)) throw new Error('invalid_task');
  return definitions[mode];
}
function freeze(value) {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}
export function createTaskRequest(mode, payload) {
  const task = definition(mode);
  return freeze({
    messages: [{ role: 'system', content: task.system }, { role: 'user', content: JSON.stringify(payload) }],
    structuredOutput: structuredClone(task.format), maxOutputTokens: task.limit,
    policy: POLICY, promptVersion: task.version
  });
}
export function validateTaskResult(mode, text, payload) {
  const error = mode === 'lesson' ? 'invalid_lesson_result'
    : ['analyze', 'analyze-v2'].includes(mode) ? 'invalid_analysis_result' : 'invalid_upstream_answer';
  try {
    // Wire parsing never substitutes for the task's independent grounded-domain validator.
    if (typeof text !== 'string') throw new Error();
    return definition(mode).validate(JSON.parse(text), payload);
  } catch { throw new Error(error); }
}
