// Only four integer counters are stored. No text, credential, IP or user profile.
// A single atomic statement prevents concurrent Worker instances from overspending the limit.
export const RESERVE_SQL = `
INSERT INTO mio_budget (id, minute, minute_count, day, day_count) VALUES (1, ?, 1, ?, 1)
ON CONFLICT(id) DO UPDATE SET
  minute = excluded.minute,
  minute_count = CASE WHEN mio_budget.minute = excluded.minute THEN mio_budget.minute_count + 1 ELSE 1 END,
  day = excluded.day,
  day_count = CASE WHEN mio_budget.day = excluded.day THEN mio_budget.day_count + 1 ELSE 1 END
WHERE (mio_budget.minute != excluded.minute OR mio_budget.minute_count < ?)
  AND (mio_budget.day != excluded.day OR mio_budget.day_count < ?)
RETURNING id`;

export const READ_SQL = 'SELECT minute, minute_count, day, day_count FROM mio_budget WHERE id = ?';

function validateCounters(row) {
  if (row && !['minute', 'minute_count', 'day', 'day_count'].every(field => Number.isSafeInteger(row[field]) && row[field] >= 0)) {
    throw new Error('Invalid quota counters');
  }
  return row;
}

async function readCounters(database) { return validateCounters(await database.prepare(READ_SQL).bind(1).first()); }

export async function reserveCloudBudgetOutcome(database, config, now = Date.now()) {
  if (!database) throw new Error('Missing quota database');
  const minute = Math.floor(now / 60_000); const day = Math.floor(now / 86_400_000);
  const result = await database.prepare(RESERVE_SQL).bind(
    // No daily cap binds an unreachable bound, so the counters stay comparable over time.
    minute, day, config.requestsPerMinute, config.requestsPerDay ?? Number.MAX_SAFE_INTEGER
  ).first();
  if (result?.id === 1) return { allowed: true };
  // The failed atomic statement changed nothing. A later read only classifies the
  // denial; it never refunds or resets a reservation made by another request.
  const row = await readCounters(database);
  if (config.requestsPerDay != null && row?.day === day && row.day_count >= config.requestsPerDay) return { allowed: false, reason: 'local_day_limit' };
  if (row?.minute === minute && row.minute_count >= config.requestsPerMinute) return { allowed: false, reason: 'local_minute_limit' };
  return { allowed: false, reason: 'local_request_limit' };
}

export async function reserveCloudBudget(database, config, now = Date.now()) {
  return (await reserveCloudBudgetOutcome(database, config, now)).allowed;
}

export async function readCloudBudget(database, config, now = Date.now()) {
  const limit = config.requestsPerDay ?? null;
  if (limit === null) return null;
  if (!Number.isSafeInteger(limit) || limit < 1 || !Number.isSafeInteger(now) || now < 0) throw new Error('Invalid quota observation');
  if (!database) return { limit, remaining: null, resetAt: null };
  const day = Math.floor(now / 86_400_000);
  const reset = new Date((day + 1) * 86_400_000);
  if (!Number.isFinite(reset.getTime())) throw new Error('Invalid quota observation');
  const row = await readCounters(database);
  return { limit, remaining: Math.max(0, limit - (row?.day === day ? row.day_count : 0)),
    resetAt: reset.toISOString() };
}
