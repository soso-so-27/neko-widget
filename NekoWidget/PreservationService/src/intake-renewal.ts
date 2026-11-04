import { renewalPolicy as p, forecastYen, measuredCostYen, type CostObservation } from './intake-renewal-policy';
type Row = Record<string, number | string | null>;
export type RenewalResult = 'disabled' | 'not-due' | 'renewed' | 'closed' | 'superseded';
/** This service has no owner/session/content operations. A failed acquisition
 * closes new admission; existing auth/read/export bypass IntakeControl. */
export async function renewIntake(db: D1Database, now: () => number,
  collect: () => Promise<CostObservation>): Promise<RenewalResult> {
  const start = now(), claim = crypto.randomUUID();
  if (!Number.isSafeInteger(start) || start < 0) throw Error('Invalid clock');
  const slot = Math.floor(start / p.intervalMs);
  // D1 batches are atomic. Only one owner of a six-hour slot can call paid APIs.
  const result = await db.batch([
    db.prepare(`UPDATE pa_intake_renewal SET generation=generation+1,claim_id=?,
      lease_until=?,last_slot=?,last_result='checking' WHERE singleton=1 AND enabled=1
      AND approved_until>? AND lease_until<=? AND last_slot<? RETURNING generation`)
      .bind(claim, start + p.leaseMs, slot, start, start, slot),
    db.prepare(`UPDATE pa_intake_control SET enabled=0,valid_until=reviewed_at
      WHERE singleton=1 AND EXISTS(SELECT 1 FROM pa_intake_renewal WHERE singleton=1 AND claim_id=?)`).bind(claim),
    db.prepare('SELECT * FROM pa_intake_control WHERE singleton=1'),
  ]);
  const generation = (result[0]?.results[0] as { generation: number } | undefined)?.generation;
  if (generation === undefined) return 'not-due';
  const before = result[2]?.results[0] as Row | undefined;
  let forecast: number | null = null, warning = false;
  let failure = 'closed';
  try {
    if (!before || !Object.entries(p.limits).every(([k, v]) => before[k] === v)) throw Error('Unapproved limits');
    const observation = await collect(), observedAt = now();
    forecast = forecastYen(observation, observedAt);
    warning = measuredCostYen(observation, observedAt) >= p.warningYen;
    const finished = now();
    if (finished < start || finished >= start + p.leaseMs) { failure = 'expired'; throw Error('Expired'); }
    if (forecast >= p.stopYen) throw Error('Over budget');
    const validUntil = finished + p.lifetimeMs;
    // Match every observed field, including live counters and operator edits.
    // Any concurrent admission/control change leaves the already-closed row closed.
    const columns = Object.keys(before);
    if (!columns.every(k => /^[a-z_]+$/.test(k))) throw Error('Unexpected schema');
    const checks = columns.map(k => `"${k}" IS ?`).join(' AND ');
    const rows = await db.batch([
      db.prepare(`UPDATE pa_intake_control SET enabled=1,reviewed_at=?,valid_until=?,forecast_yen=?
        WHERE singleton=1 AND ${checks}
        AND EXISTS(SELECT 1 FROM pa_intake_renewal WHERE singleton=1 AND enabled=1
          AND generation=? AND claim_id=? AND lease_until>? AND approved_until>=?)
        RETURNING singleton`).bind(finished, validUntil, forecast, ...columns.map(k => before[k]!),
          generation, claim, finished, validUntil),
      db.prepare(`UPDATE pa_intake_renewal SET last_result=CASE WHEN changes()=1 THEN 'renewed' ELSE 'superseded' END,
        checked_at=?,forecast_yen=?,warning=?,lease_until=0 WHERE singleton=1 AND generation=? AND claim_id=?`)
        .bind(finished, forecast, warning ? 1 : 0, generation, claim),
    ]);
    return rows[0]?.results.length === 1 ? 'renewed' : 'superseded';
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'COST_CREDENTIAL_REJECTED') failure = 'credentials';
    // Do not undo a newer operator generation or a newer completed review.
    await db.prepare(`UPDATE pa_intake_renewal SET last_result=?,checked_at=?,
      forecast_yen=?,warning=?,lease_until=0 WHERE singleton=1 AND generation=? AND claim_id=?`)
      .bind(failure, now(), forecast, warning ? 1 : 0, generation, claim).run();
    return 'closed';
  }
}
