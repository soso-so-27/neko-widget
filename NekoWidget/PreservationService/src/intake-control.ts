import { ServiceError } from './contracts';

const paused = () => new ServiceError('PRESERVATION_INTAKE_PAUSED', 503);
const dayMs = 24 * 60 * 60 * 1000;

/** A fail-closed, global admission counter, not a claim about currency costs.
 * Operator review must be refreshed from usage/cost evidence within 24 hours.
 * Every admitted attempt consumes its allowance even if downstream work fails;
 * otherwise repeated invalid JPEGs or outages could evade the work limit.
 * No user identifiers/content are stored. Pausing does not erase any data.
 */
export class IntakeControl {
  constructor(private readonly db: D1Database, private readonly now: () => number) {}

  async admit(plannedBytes: number): Promise<void> {
    const now = this.now();
    if (!Number.isSafeInteger(now) || now < 0 || now > 8_640_000_000_000_000
      || !Number.isSafeInteger(plannedBytes) || plannedBytes < 1
      || plannedBytes > 32 * 1024 * 1024) throw paused();
    const day = new Date(now).toISOString().slice(0, 10);
    const month = day.slice(0, 7);
    try {
      // One conditional statement serializes concurrent admissions. A clock
      // rollback cannot open an older/reset budget window.
      const admitted = await this.db.prepare(`UPDATE pa_intake_control SET
        daily_attempts=CASE WHEN day=? THEN daily_attempts+1 ELSE 1 END,
        monthly_attempts=CASE WHEN month=? THEN monthly_attempts+1 ELSE 1 END,
        monthly_bytes=CASE WHEN month=? THEN monthly_bytes+? ELSE ? END,
        day=?,month=? WHERE singleton=1 AND enabled=1
        AND reviewed_at<=? AND reviewed_at>? AND valid_until>? AND valid_until<=reviewed_at+?
        AND day<=? AND month<=?
        AND (CASE WHEN day=? THEN daily_attempts ELSE 0 END)<daily_attempt_limit
        AND (CASE WHEN month=? THEN monthly_attempts ELSE 0 END)<monthly_attempt_limit
        AND (CASE WHEN month=? THEN monthly_bytes ELSE 0 END)<=monthly_bytes_limit-?
        RETURNING singleton`).bind(day, month, month, plannedBytes, plannedBytes,
        day, month, now, now - dayMs, now, dayMs, day, month, day, month, month, plannedBytes)
        .first<{ singleton: number }>();
      if (admitted?.singleton !== 1) throw paused();
    } catch { throw paused(); }
  }
}
