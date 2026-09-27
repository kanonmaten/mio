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

export async function reserveCloudBudget(database, config, now = Date.now()) {
  if (!database) throw new Error('Missing quota database');
  const result = await database.prepare(RESERVE_SQL).bind(
    Math.floor(now / 60_000), Math.floor(now / 86_400_000), config.requestsPerMinute, config.requestsPerDay
  ).first();
  return result?.id === 1;
}
