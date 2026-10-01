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

  /** Called only after Apple identity verification, in explicit general mode.
   * Existing owners bypass admission in DurableAuth so a stop cannot strand
   * their sign-in, reads or exports. Count disabled owners too: their copies
   * and retention costs do not disappear merely because access is disabled.
   */
  async createOwner(ownerId: string, identityKey: string, _authNow: number): Promise<void> {
    const now = this.now();
    if (!Number.isSafeInteger(now) || now < 0 || now >= 253_402_300_800_000
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(ownerId)
      || !/^[0-9a-f]{64}$/u.test(identityKey)) throw paused();
    const day = new Date(now).toISOString().slice(0, 10);
    try {
      const result = await this.db.batch([
        this.db.prepare(`UPDATE pa_intake_control SET registration_day=?,
          daily_registrations=CASE WHEN registration_day=? THEN daily_registrations+1 ELSE 1 END
          WHERE singleton=1 AND enabled=1 AND reviewed_at<=? AND reviewed_at>?
          AND valid_until>? AND valid_until<=reviewed_at+? AND registration_day<=?
          AND (CASE WHEN registration_day=? THEN daily_registrations ELSE 0 END)<daily_registration_limit
          AND (SELECT count(*) FROM pa_owners)<maximum_owners`)
          .bind(day, day, now, now-dayMs, now, dayMs, day, day),
        this.db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,created_at)
          SELECT ?,?,0,0,? WHERE changes()=1 ON CONFLICT(identity_key) DO NOTHING`)
          .bind(ownerId, identityKey, now),
        this.db.prepare('SELECT 1 AS present FROM pa_owners WHERE identity_key=?').bind(identityKey),
      ]);
      if (!(result[2]?.results[0] as { present: number } | undefined)?.present) throw paused();
    } catch { throw paused(); }
  }

  /** Bounds PUTs including edits and retries before KMS/backup work. This is a
   * usage counter, not a currency cap; a failed admitted attempt is not refunded.
   */
  async admitMutation(ownerId: string): Promise<void> {
    const now = this.now();
    if (!Number.isSafeInteger(now) || now < 0 || now >= 253_402_300_800_000) throw paused();
    const day = new Date(now).toISOString().slice(0, 10), month = day.slice(0, 7);
    try {
      const row = await this.db.prepare(`UPDATE pa_intake_control SET mutation_day=?,mutation_month=?,
        daily_mutations=CASE WHEN mutation_day=? THEN daily_mutations+1 ELSE 1 END,
        monthly_mutations=CASE WHEN mutation_month=? THEN monthly_mutations+1 ELSE 1 END
        WHERE singleton=1 AND enabled=1 AND reviewed_at<=? AND reviewed_at>?
        AND valid_until>? AND valid_until<=reviewed_at+? AND mutation_day<=? AND mutation_month<=?
        AND (CASE WHEN mutation_day=? THEN daily_mutations ELSE 0 END)<daily_mutation_limit
        AND (CASE WHEN mutation_month=? THEN monthly_mutations ELSE 0 END)<monthly_mutation_limit
        AND EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=? AND disabled=0)
        RETURNING singleton`).bind(day, month, day, month, now, now-dayMs, now, dayMs,
          day, month, day, month, ownerId).first<{ singleton: number }>();
      if (row?.singleton !== 1) throw paused();
    } catch { throw paused(); }
  }

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
