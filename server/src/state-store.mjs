import { readFileSync, writeFileSync, renameSync } from 'node:fs';

// Only integer counters are stored: no text, credential, IP or user profile.
const FIELDS = ['minute', 'minuteCount', 'day', 'dayCount', 'dayTokens'];
export const emptyCounters = () => ({ minute: -1, minuteCount: 0, day: -1, dayCount: 0, dayTokens: 0 });

export function validCounters(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && FIELDS.every(field => Number.isSafeInteger(value[field]) && value[field] >= (field.endsWith('Count') || field === 'dayTokens' ? 0 : -1));
}

export function createMemoryCounterStore(initial = emptyCounters()) {
  let saved = { ...initial };
  return { load: () => ({ ...saved }), save: value => { saved = { ...value }; } };
}

/** Survives gateway restarts so a restart cannot reset the daily Groq allowance. */
export function createFileCounterStore(path) {
  return {
    load() {
      try {
        const value = JSON.parse(readFileSync(path, 'utf8'));
        return validCounters(value) ? Object.fromEntries(FIELDS.map(field => [field, value[field]])) : emptyCounters();
      } catch { return emptyCounters(); }
    },
    save(value) {
      // Atomic replace: a crash mid-write leaves the previous counters, never a torn file.
      const temporary = `${path}.tmp`;
      writeFileSync(temporary, JSON.stringify(Object.fromEntries(FIELDS.map(field => [field, value[field]]))), { mode: 0o600 });
      renameSync(temporary, path);
    }
  };
}
