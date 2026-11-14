import { env } from 'cloudflare:workers';
import { beforeEach, expect, it } from 'vitest';
import { renewIntake } from '../src/intake-renewal';
import { renewalPolicy as p, forecastYen, measuredCostYen, type CostObservation } from '../src/intake-renewal-policy';
import worker from '../src/intake-renewal-worker';
import { IntakeControl } from '../src/intake-control';
const db = (env as unknown as { DB: D1Database }).DB;
const base = Date.parse('2026-11-04T06:00:00Z');
const evidence = (at = base): CostObservation => ({ collectedAt: at, awsMonthlyUsd: 1,
  cloudflareMonthlyUsd: 1, awsPages: 1, oldestCoveredAt: at - 86400000, includesEntireAccounts: true });
beforeEach(async () => {
  await db.batch([db.prepare('DELETE FROM pa_intake_renewal'),
    db.prepare('INSERT INTO pa_intake_renewal(singleton,enabled,approved_until) VALUES(1,1,?)').bind(base + 30*86400000),
    db.prepare('DELETE FROM pa_intake_control'), db.prepare('INSERT INTO pa_intake_control(singleton) VALUES(1)')]);
  const keys = Object.keys(p.limits);
  await db.prepare('UPDATE pa_intake_control SET '+keys.map(k=>k+'=?').join(',')+',enabled=1,reviewed_at=?,valid_until=?,monthly_attempts=3,monthly_bytes=123')
    .bind(...Object.values(p.limits),base-1000,base+100000).run();
});
const state = () => db.prepare('SELECT enabled,reviewed_at,valid_until,monthly_attempts,monthly_bytes FROM pa_intake_control').first<any>();
it('renews only approved limits, preserves counters, avoids model-only warning and bounds lifetime', async () => {
  expect(await renewIntake(db,()=>base,async()=>evidence())).toBe('renewed');
  expect(await state()).toMatchObject({enabled:1,reviewed_at:base,valid_until:base+p.lifetimeMs,monthly_attempts:3,monthly_bytes:123});
  expect(await db.prepare('SELECT warning FROM pa_intake_renewal').first()).toEqual({warning:0});
});
it('provider failure closes new writes before IO and does not touch owner records', async () => {
  const ownersBefore = (await db.prepare('SELECT * FROM pa_owners').all()).results;
  expect(await renewIntake(db,()=>base,async()=>{expect((await state()).enabled).toBe(0);throw Error('offline');})).toBe('closed');
  expect(await state()).toMatchObject({enabled:0,monthly_attempts:3,monthly_bytes:123});
  expect(await db.prepare('SELECT last_result FROM pa_intake_renewal').first()).toEqual({last_result:'cost-unavailable'});
  await expect(new IntakeControl(db,()=>base).admit(1)).rejects.toMatchObject({code:'PRESERVATION_INTAKE_PAUSED'});
  expect((await db.prepare('SELECT * FROM pa_owners').all()).results).toEqual(ownersBefore);
});
it('one concurrent claim makes at most one bounded provider call per six-hour slot', async () => {
  let calls=0;
  const rs=await Promise.all(Array.from({length:5},()=>renewIntake(db,()=>base,async()=>{calls++;return evidence();})));
  expect(calls).toBe(1);expect(rs.filter(r=>r==='renewed')).toHaveLength(1);
  expect(await renewIntake(db,()=>base+1000,async()=>{throw Error('must not call');})).toBe('not-due');
});
it('stale, future and over-budget evidence never renews', async () => {
  for(const change of [{collectedAt:base-60000},{collectedAt:base+1},{oldestCoveredAt:base-3*86400000},{awsMonthlyUsd:1000}]){
    await db.prepare('UPDATE pa_intake_renewal SET last_slot=-1').run();
    expect(await renewIntake(db,()=>base,async()=>({...evidence(),...change}))).toBe('closed');
    expect((await state()).enabled).toBe(0);
  }
  expect(()=>forecastYen({...evidence(),awsPages:3},base)).toThrow();
});
it('expiry while collecting cannot reopen, even with a fresh observation', async () => {
  let clock=base;
  expect(await renewIntake(db,()=>clock,async()=>{clock+=p.leaseMs;return evidence(clock);})).toBe('closed');
  expect((await state()).enabled).toBe(0);
});
it('operator stop or changed limits wins against a late collection', async () => {
  expect(await renewIntake(db,()=>base,async()=>{
    await db.prepare('UPDATE pa_intake_renewal SET enabled=0,generation=generation+1').run();return evidence();
  })).toBe('superseded');
  expect((await state()).enabled).toBe(0);
  await db.prepare('UPDATE pa_intake_renewal SET enabled=1,last_slot=-1,lease_until=0').run();
  expect(await renewIntake(db,()=>base,async()=>{
    await db.prepare('UPDATE pa_intake_control SET daily_attempt_limit=1').run();return evidence();
  })).toBe('superseded');expect((await state()).enabled).toBe(0);
});
it('expired authorization and malformed limits consume no paid calls', async () => {
  let calls=0;
  await db.prepare('UPDATE pa_intake_renewal SET approved_until=?').bind(base).run();
  expect(await renewIntake(db,()=>base,async()=>{calls++;return evidence();})).toBe('not-due');
  await db.prepare('UPDATE pa_intake_renewal SET approved_until=?').bind(base+86400000).run();
  await db.prepare('UPDATE pa_intake_control SET maximum_owners=101').run();
  expect(await renewIntake(db,()=>base,async()=>{calls++;return evidence();})).toBe('closed');expect(calls).toBe(0);
  expect(await db.prepare('SELECT last_result FROM pa_intake_renewal').first()).toEqual({last_result:'limits'});
});
it('cannot grant time past authorization or reset an exhausted counter', async () => {
  await db.prepare('UPDATE pa_intake_renewal SET approved_until=?').bind(base+1000).run();
  expect(await renewIntake(db,()=>base,async()=>evidence())).toBe('superseded');
  await db.prepare('UPDATE pa_intake_renewal SET approved_until=?,last_slot=-1').bind(base+86400000).run();
  await db.prepare("UPDATE pa_intake_control SET month='2026-11',monthly_attempts=?").bind(p.limits.monthly_attempt_limit).run();
  await renewIntake(db,()=>base,async()=>evidence());
  await expect(new IntakeControl(db,()=>base).admit(1)).rejects.toMatchObject({code:'PRESERVATION_INTAKE_PAUSED'});
  expect((await state()).monthly_attempts).toBe(p.limits.monthly_attempt_limit);
});
it('public entry is 404 and OFF scheduled invocation touches no dependency', async () => {
  expect(worker.fetch().status).toBe(404);
  const noDB=new Proxy({} as D1Database,{get(){throw Error('must not read');}});
  await worker.scheduled({} as ScheduledController,{ENVIRONMENT:'production',INTAKE_RENEWAL_ENABLED:'NO',DB:noDB});
  await worker.scheduled({} as ScheduledController,{ENVIRONMENT:'staging',INTAKE_RENEWAL_ENABLED:'YES',DB:noDB});
});

it('measured 5000 yen warns without adding model floor or preservation reserve', async () => {
  const o={...evidence(),awsMonthlyUsd:14,cloudflareMonthlyUsd:0};
  expect(measuredCostYen(o,base)).toBeGreaterThanOrEqual(5000);
  expect(forecastYen(o,base)).toBe(8610);
  expect(await renewIntake(db,()=>base,async()=>o)).toBe('renewed');
  expect(await db.prepare('SELECT warning FROM pa_intake_renewal').first()).toEqual({warning:1});
});
it('forecast at or above 10000 closes even while measured cost is less', async () => {
  const o={...evidence(),awsMonthlyUsd:23,cloudflareMonthlyUsd:0};
  expect(measuredCostYen(o,base)).toBeLessThan(10000);
  expect(forecastYen(o,base)).toBeGreaterThanOrEqual(10000);
  expect(await renewIntake(db,()=>base,async()=>o)).toBe('closed');
  expect((await state()).enabled).toBe(0);
  expect(await db.prepare('SELECT last_result FROM pa_intake_renewal').first()).toEqual({last_result:'budget'});
});

it('future cost API budget is not actual warning spending and stop forecast stays unchanged',async()=>{
 const o={...evidence(),awsMonthlyUsd:12,cloudflareMonthlyUsd:0};
 expect(measuredCostYen(o,base)).toBeCloseTo(4664);
 expect(forecastYen(o,base)).toBe(8610);
 expect(await renewIntake(db,()=>base,async()=>o)).toBe('renewed');
 expect(await db.prepare('SELECT warning FROM pa_intake_renewal').first()).toEqual({warning:0});
 const high={...o,awsMonthlyUsd:23};expect(forecastYen(high,base)).toBe(Math.ceil((23+5+9.5+2.48)*160*1.1+3000));
});
