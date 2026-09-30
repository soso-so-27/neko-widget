import { env } from 'cloudflare:workers';
import { beforeEach, expect, it } from 'vitest';
import { PilotControl } from '../src/pilot-control';
import plan from '../operations/pilot-plan.json';

const db = (env as unknown as { DB: D1Database }).DB;
const base = Date.parse('2026-09-26T00:00:00Z');
const day = 86_400_000;
const keys = ['1', '2', '3', '4'].map(value => value.repeat(64));
const owners = [1, 2, 3, 4].map(value => `00000000-0000-4000-8000-${String(value).padStart(12, '0')}`);
const paused = { code: 'PILOT_WRITES_PAUSED', status: 503 };
beforeEach(async () => {
  // Exact synthetic owners in isolated local D1 only, never a remote database.
  for (const owner of owners) {
    // Owner creation also creates a generation row through migration 0015.
    await db.prepare('DELETE FROM pa_owner_recovery_generations WHERE owner_id=?').bind(owner).run();
    await db.prepare('DELETE FROM pa_owners WHERE owner_id=?').bind(owner).run();
  }
  await db.prepare('DELETE FROM pa_pilot_control').run();
  await db.prepare('INSERT INTO pa_pilot_control(singleton) VALUES(1)').run();
});
async function permit(now = base) {
  await db.prepare(`UPDATE pa_pilot_control SET enabled=1,starts_at=?,ends_at=?,
    reviewed_at=?,valid_until=?,forecast_yen=1773 WHERE singleton=1`)
    .bind(base, base + plan.trialDays * day, now, now + day).run();
}
const control = (now = base, allowed = keys.slice(0, 3), mode: string | undefined = 'YES') =>
  new PilotControl(db, () => now, mode, JSON.stringify(allowed));

it('limits approved identities to three owners atomically, including competing configurations', async () => {
  await permit();
  const attempts = await Promise.allSettled(owners.map((owner, i) =>
    control(base, [keys[i]!]).createOwner(owner, keys[i]!, base)));
  expect(attempts.filter(reply => reply.status === 'fulfilled')).toHaveLength(3);
  expect((await db.prepare('SELECT count(*) AS total FROM pa_owners').first())?.total).toBe(3);
});

it('refuses new owners for missing config, nonparticipants, stopped or stale review and the exact end', async () => {
  await permit();
  for (const allowed of [[], keys, ['email@example.test'], [keys[0]!, keys[0]!]]) {
    await expect(control(base, allowed).createOwner(owners[0]!, keys[0]!, base)).rejects.toMatchObject(paused);
  }
  await expect(control(base, [keys[0]!], 'NO').createOwner(owners[0]!, keys[0]!, base)).rejects.toMatchObject(paused);
  await expect(control().createOwner(owners[3]!, keys[3]!, base))
    .rejects.toMatchObject({ code: 'PILOT_PARTICIPANT_REQUIRED' });
  await expect(control(base + day).createOwner(owners[0]!, keys[0]!, base)).rejects.toMatchObject(paused);
  await permit(base + 7 * day);
  await expect(control(base + 7 * day).createOwner(owners[0]!, keys[0]!, base)).rejects.toMatchObject(paused);
  await permit(); await db.prepare('UPDATE pa_pilot_control SET enabled=0').run();
  await expect(control().createOwner(owners[0]!, keys[0]!, base)).rejects.toMatchObject(paused);
  expect((await db.prepare('SELECT count(*) AS total FROM pa_owners').first())?.total).toBe(0);
});

it('reserves edits/retries at both boundaries and never refunds failed work', async () => {
  await permit(); await control().createOwner(owners[0]!, keys[0]!, base);
  const caps = plan.additionalControlsRequired;
  await db.prepare(`UPDATE pa_pilot_control SET day='2026-09-26',month='2026-09',
    daily_mutations=?,monthly_mutations=?`)
    .bind(caps.dailyMutationAttemptsIncludingEditsAndRetries - 1,
      caps.monthlyMutationAttemptsIncludingEditsAndRetries - 1).run();
  const attempts = await Promise.allSettled([1, 2, 3].map(() => control().admitMutation(owners[0]!)));
  expect(attempts.filter(reply => reply.status === 'fulfilled')).toHaveLength(1);
  await permit(base + day);
  await expect(control(base + day).admitMutation(owners[0]!)).rejects.toMatchObject(paused);
  expect((await db.prepare('SELECT monthly_mutations FROM pa_pilot_control').first())?.monthly_mutations).toBe(500);
});

it('rechecks participant removal, cost threshold, missing row and clock rollback on every write', async () => {
  await permit(); await control().createOwner(owners[0]!, keys[0]!, base);
  await expect(control(base, [keys[1]!]).admitMutation(owners[0]!)).rejects.toMatchObject(paused);
  await db.prepare('UPDATE pa_pilot_control SET forecast_yen=?')
    .bind(plan.currency.pauseNewIntakeForecastYen).run();
  await expect(control().admitMutation(owners[0]!)).rejects.toMatchObject(paused);
  await db.prepare('UPDATE pa_pilot_control SET forecast_yen=?')
    .bind(plan.currency.pauseNewIntakeForecastYen - 1).run();
  await control().admitMutation(owners[0]!);
  await expect(control(base - 1).admitMutation(owners[0]!)).rejects.toMatchObject(paused);
  await db.prepare('DELETE FROM pa_pilot_control').run();
  await expect(control().admitMutation(owners[0]!)).rejects.toMatchObject(paused);
});

it('keeps verified pending registrations separate from owners and sessions, expiring in ten minutes', async () => {
  const pending = new PilotControl(db, () => base, 'YES', undefined, true);
  await expect(pending.createOwner(owners[0]!, keys[0]!, base))
    .rejects.toMatchObject({ code: 'PILOT_REGISTRATION_PENDING', status: 403 });
  const first = await db.prepare('SELECT reference,expires_at FROM pa_pilot_registrations WHERE identity_key=?')
    .bind(keys[0]!).first<{ reference: string; expires_at: number }>();
  expect(first?.expires_at).toBe(base + 600_000);
  expect((await db.prepare('SELECT count(*) total FROM pa_owners').first())?.total).toBe(0);
  expect((await db.prepare('SELECT count(*) total FROM pa_sessions').first())?.total).toBe(0);
  await expect(pending.createOwner(owners[0]!, keys[0]!, base))
    .rejects.toMatchObject({ registrationReference: first!.reference });
  const later = new PilotControl(db, () => base + 600_000, 'YES', undefined, true);
  await expect(later.createOwner(owners[0]!, keys[0]!, base))
    .rejects.toMatchObject({ code: 'PILOT_REGISTRATION_PENDING' });
  expect((await db.prepare('SELECT reference FROM pa_pilot_registrations WHERE identity_key=?')
    .bind(keys[0]!).first())?.reference).not.toBe(first!.reference);
});
