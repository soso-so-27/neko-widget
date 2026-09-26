import { ServiceError } from './contracts';

const closed = () => new ServiceError('PILOT_WRITES_PAUSED', 503);
const denied = () => new ServiceError('PILOT_PARTICIPANT_REQUIRED', 403);
const dayMs = 86_400_000;
const eligible = `singleton=1 AND enabled=1 AND starts_at<=? AND ends_at>?
  AND ends_at<=starts_at+604800000 AND reviewed_at<=? AND reviewed_at>?
  AND valid_until>? AND valid_until<=reviewed_at+86400000 AND forecast_yen<2200`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

/** Private, default-closed pilot write policy, not a monetary billing cap.
 * Identity entries are the existing HMAC(verified Apple issuer, subject), not
 * emails, bearer tokens, caller-supplied owner IDs or a first-come signup list.
 * Validation is lazy so missing pilot config cannot strand existing readers.
 */
export class PilotControl {
  constructor(private readonly db: D1Database, private readonly now: () => number,
    private readonly mode: string | undefined, private readonly identityKeysJSON: string | undefined) {}

  private settings(): { now: number; keys: [string, string, string]; times: number[] } {
    if (this.mode !== 'YES') throw closed();
    const now = this.now();
    if (!Number.isSafeInteger(now) || now < 0 || now >= 253_402_300_800_000) throw closed();
    try {
      if (!this.identityKeysJSON || this.identityKeysJSON.length > 256) throw closed();
      const values: unknown = JSON.parse(this.identityKeysJSON);
      if (!Array.isArray(values) || values.length < 1 || values.length > 3
        || values.some(key => typeof key !== 'string' || !/^[0-9a-f]{64}$/u.test(key))
        || new Set(values).size !== values.length) throw closed();
      const keys: [string, string, string] = [values[0] as string,
        (values[1] as string | undefined) ?? '', (values[2] as string | undefined) ?? ''];
      return { now, keys, times: [now, now, now, now - dayMs, now] };
    } catch { throw closed(); }
  }

  async createOwner(ownerId: string, identityKey: string, _authNow: number): Promise<void> {
    const s = this.settings();
    if (!uuid.test(ownerId) || !s.keys.includes(identityKey) || !identityKey) throw denied();
    try {
      // The count and current stop policy are checked by the INSERT itself.
      // Competing registrations cannot take the fourth slot or race a stop.
      await this.db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,created_at)
        SELECT ?,?,0,0,? FROM pa_pilot_control WHERE ${eligible}
          AND (SELECT count(*) FROM pa_owners)<3
        ON CONFLICT(identity_key) DO NOTHING`)
        .bind(ownerId, identityKey, s.now, ...s.times).run();
      const present = await this.db.prepare('SELECT 1 AS present FROM pa_owners WHERE identity_key=?')
        .bind(identityKey).first<{ present: number }>();
      if (!present) throw closed();
    } catch { throw closed(); }
  }

  async admitMutation(ownerId: string): Promise<void> {
    const s = this.settings();
    if (!uuid.test(ownerId)) throw denied();
    const day = new Date(s.now).toISOString().slice(0, 10);
    const month = day.slice(0, 7);
    try {
      // Count new saves, edits and retries BEFORE decoding/KMS/recovery calls.
      // No refund after a failure: a retry storm must also exhaust the allowance.
      const result = await this.db.prepare(`UPDATE pa_pilot_control SET
        daily_mutations=CASE WHEN day=? THEN daily_mutations+1 ELSE 1 END,
        monthly_mutations=CASE WHEN month=? THEN monthly_mutations+1 ELSE 1 END,
        day=?,month=? WHERE ${eligible} AND day<=? AND month<=?
        AND (CASE WHEN day=? THEN daily_mutations ELSE 0 END)<100
        AND (CASE WHEN month=? THEN monthly_mutations ELSE 0 END)<500
        AND EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=? AND disabled=0
          AND identity_key IN (?,?,?)) RETURNING singleton`)
        .bind(day, month, day, month, ...s.times, day, month, day, month, ownerId, ...s.keys)
        .first<{ singleton: number }>();
      if (result?.singleton !== 1) throw closed();
    } catch { throw closed(); }
  }
}
