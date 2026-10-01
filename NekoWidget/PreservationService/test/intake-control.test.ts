import { env } from 'cloudflare:workers';
import { beforeEach, expect, it } from 'vitest';
import { IntakeControl } from '../src/intake-control';
import pilot from '../operations/pilot-plan.json';

const db = (env as unknown as { DB: D1Database }).DB;
const base = Date.parse('2026-09-26T00:00:00Z');
const failure = { code: 'PRESERVATION_INTAKE_PAUSED', status: 503 };
beforeEach(async () => {
  await db.prepare('DELETE FROM pa_intake_control').run();
  await db.prepare('INSERT INTO pa_intake_control(singleton) VALUES(1)').run();
});
async function permit(now = base) {
  await db.prepare(`UPDATE pa_intake_control SET enabled=1,reviewed_at=?,valid_until=?,
    daily_attempt_limit=2,monthly_attempt_limit=3,monthly_bytes_limit=30 WHERE singleton=1`)
    .bind(now, now + 86_400_000).run();
}
it('keeps general registration and mutation closed until their explicit limits are configured', async () => {
  const control = new IntakeControl(db, () => base);
  await permit();
  await expect(control.createOwner(crypto.randomUUID(), 'a'.repeat(64), base)).rejects.toMatchObject(failure);
  await expect(control.admitMutation(crypto.randomUUID())).rejects.toMatchObject(failure);
});

it('serializes general registrations at the owner limit without a seven-day pilot grant', async () => {
  await permit();
  const before = (await db.prepare('SELECT count(*) AS count FROM pa_owners').first<{ count: number }>())!.count;
  await db.prepare(`UPDATE pa_intake_control SET maximum_owners=?,daily_registration_limit=10`)
    .bind(before+1).run();
  const control = new IntakeControl(db, () => base);
  const keys = [crypto.randomUUID(), crypto.randomUUID()].map(x => x.replaceAll('-', '').repeat(2));
  const attempts = await Promise.allSettled(keys.map(key => control.createOwner(crypto.randomUUID(), key, base)));
  expect(attempts.filter(x => x.status === 'fulfilled')).toHaveLength(1);
  expect((await db.prepare('SELECT count(*) AS count FROM pa_owners').first<{ count: number }>())!.count).toBe(before+1);
  await db.prepare('UPDATE pa_intake_control SET enabled=0').run();
  await expect(control.createOwner(crypto.randomUUID(), 'b'.repeat(64), base)).rejects.toMatchObject(failure);
});

it('caps general PUT attempts including retries across daily and monthly boundaries', async () => {
  await permit();
  const ownerId=crypto.randomUUID(), identity=crypto.randomUUID().replaceAll('-', '').repeat(2);
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)').bind(ownerId,identity,base).run();
  await db.prepare('UPDATE pa_intake_control SET daily_mutation_limit=1,monthly_mutation_limit=2').run();
  let now=base;
  const control=new IntakeControl(db,()=>now);
  const attempts=await Promise.allSettled([control.admitMutation(ownerId),control.admitMutation(ownerId)]);
  expect(attempts.filter(x=>x.status==='fulfilled')).toHaveLength(1);
  now+=86_400_000;
  await permit(now);
  await control.admitMutation(ownerId);
  now+=86_400_000;
  await permit(now);
  await expect(control.admitMutation(ownerId)).rejects.toMatchObject(failure);
  // Neither disabled nor caller-invented owners may consume a mutation grant.
  await db.prepare('UPDATE pa_intake_control SET monthly_mutation_limit=10').run();
  await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(ownerId).run();
  await expect(control.admitMutation(ownerId)).rejects.toMatchObject(failure);
  await expect(control.admitMutation(crypto.randomUUID())).rejects.toMatchObject(failure);
});
it('defaults closed and refuses missing, expired or implausibly long operator review', async () => {
  const control = new IntakeControl(db, () => base);
  await expect(control.admit(10)).rejects.toMatchObject(failure);
  await permit();
  await db.prepare('UPDATE pa_intake_control SET valid_until=?').bind(base).run();
  await expect(control.admit(10)).rejects.toMatchObject(failure);
  await db.prepare('UPDATE pa_intake_control SET valid_until=?').bind(base + 86_400_001).run();
  await expect(control.admit(10)).rejects.toMatchObject(failure);
  await db.prepare('DELETE FROM pa_intake_control').run();
  await expect(control.admit(10)).rejects.toMatchObject(failure);
});
it('serializes competing admissions at the daily and byte limits', async () => {
  await permit();
  const control = new IntakeControl(db, () => base);
  const replies = await Promise.allSettled([control.admit(15), control.admit(15), control.admit(15)]);
  expect(replies.filter(r => r.status === 'fulfilled')).toHaveLength(2);
  expect(replies.filter(r => r.status === 'rejected')).toHaveLength(1);
  expect(await db.prepare('SELECT daily_attempts,monthly_attempts,monthly_bytes FROM pa_intake_control').first())
    .toEqual({ daily_attempts: 2, monthly_attempts: 2, monthly_bytes: 30 });
});
it('enforces the byte allowance independently of the attempt allowance', async () => {
  await permit();
  await db.prepare('UPDATE pa_intake_control SET daily_attempt_limit=10,monthly_attempt_limit=10').run();
  const control = new IntakeControl(db, () => base);
  await control.admit(20);
  await expect(control.admit(11)).rejects.toMatchObject(failure);
  await control.admit(10);
});
it('does not refund attempts on failures and needs review before a new day/month', async () => {
  await permit();
  let now = base;
  const control = new IntakeControl(db, () => now);
  await control.admit(10); await control.admit(10);
  await expect(control.admit(1)).rejects.toMatchObject(failure);
  now += 86_400_000;
  await expect(control.admit(10)).rejects.toMatchObject(failure);
  await permit(now); await control.admit(10);
  now += 86_400_000; await permit(now);
  await expect(control.admit(1)).rejects.toMatchObject(failure);
  now = Date.parse('2026-10-01T00:00:00Z'); await permit(now);
  await control.admit(30);
  now = base; await permit(now);
  await expect(control.admit(1)).rejects.toMatchObject(failure);
});
it('rejects oversized/invalid requests without consuming allowance and allows an operator stop', async () => {
  await permit();
  const control = new IntakeControl(db, () => base);
  for (const size of [0, -1, 1.5, NaN, 32 * 1024 * 1024 + 1]) {
    await expect(control.admit(size)).rejects.toMatchObject(failure);
  }
  await control.admit(10);
  await db.prepare('UPDATE pa_intake_control SET enabled=0').run();
  await expect(control.admit(10)).rejects.toMatchObject(failure);
  expect(await db.prepare('SELECT monthly_attempts FROM pa_intake_control').first())
    .toEqual({ monthly_attempts: 1 });
});

it('enforces the proposed pilot limits at concurrent daily/monthly/byte boundaries', async () => {
  const p = pilot.archive;
  await db.prepare(`UPDATE pa_intake_control SET enabled=1,reviewed_at=?,valid_until=?,
    daily_attempt_limit=?,monthly_attempt_limit=?,monthly_bytes_limit=?,
    day='2026-09-26',month='2026-09',daily_attempts=?,monthly_attempts=?,monthly_bytes=0`)
    .bind(base, base + p.reviewLifetimeHours * 3_600_000, p.dailyNewIntakeAttempts,
      p.monthlyNewIntakeAttempts, p.monthlyNewIntakeBytes,
      p.dailyNewIntakeAttempts - 1, p.monthlyNewIntakeAttempts - 1).run();
  const control = new IntakeControl(db, () => base);
  const replies = await Promise.allSettled([control.admit(1024), control.admit(1024)]);
  expect(replies.filter(reply => reply.status === 'fulfilled')).toHaveLength(1);
  await db.prepare(`UPDATE pa_intake_control SET daily_attempts=0,monthly_attempts=0,
    monthly_bytes=?`).bind(p.monthlyNewIntakeBytes - 1024).run();
  await control.admit(1024);
  await expect(control.admit(1)).rejects.toMatchObject(failure);
  await db.prepare('UPDATE pa_intake_control SET enabled=0').run();
  await expect(control.admit(1)).rejects.toMatchObject(failure);
});
