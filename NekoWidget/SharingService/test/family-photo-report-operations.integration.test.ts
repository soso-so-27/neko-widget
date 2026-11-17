import {describe,it,expect} from 'vitest';
import {db,testEnv} from './group-fixture';
import {advanceFamilyPhotoReportDeadlines,familyPhotoStopped,drainFamilyPhotoReportMail,cleanupFamilyPhotoReportEvidence} from '../src/family-photo-report-operations';
import type {Env} from '../src/env';

async function report(age:number,outcome='received') {
 const id=crypto.randomUUID(),family=crypto.randomUUID(),asset=crypto.randomUUID();
 await db.prepare(`INSERT INTO family_photo_report_records
 (report_id,family_id,asset_id,committed_at,evidence_expires_at,revision,outcome)
 VALUES (?,?,?,unixepoch()-?,unixepoch()-?+604800,?,?)`)
 .bind(id,family,asset,age,age,outcome==='received'?0:1,outcome).run();
 return {id,family,asset};
}
describe('family photo report deadlines',()=>{
 it('sends fixed reminder text only, leaves failures retryable and sends nothing when email is OFF',async()=>{
  const a=await report(5*86400+1);await advanceFamilyPhotoReportDeadlines(db,false);
  const sent:unknown[]=[],env={...testEnv,GROUP_REPORT_EMAIL_ENABLED:'YES',GROUP_REPORT_EMAIL_TO:'owner@example.test',
   GROUP_REPORT_EMAIL_FROM:'reports@example.test',GROUP_REPORT_EMAIL:{send:async(value:unknown)=>{sent.push(value);}}} as unknown as Env;
  await drainFamilyPhotoReportMail({...env,GROUP_REPORT_EMAIL_ENABLED:'NO'});expect(sent).toHaveLength(0);
  // Other tests may leave synthetic obligations; isolate just this case's queue.
  await db.prepare("UPDATE family_photo_report_reminders SET state='cancelled' WHERE report_id<>?").bind(a.id).run();
  await drainFamilyPhotoReportMail(env);await drainFamilyPhotoReportMail(env);expect(sent).toHaveLength(2);
  for(const mail of sent){expect(JSON.stringify(mail)).not.toContain(a.id);expect(JSON.stringify(mail)).not.toContain(a.family);}
  expect((await db.prepare('SELECT state FROM family_photo_report_reminders WHERE report_id=?').bind(a.id).all()).results)
   .toEqual([{state:'sent'},{state:'sent'}]);
 });
 it('purges terminal metadata only after its deadline and retains a stopped asset record',async()=>{
  const terminal=await report(100,'no_action'),stopped=await report(100,'photo');
  await db.prepare('UPDATE family_photo_report_records SET retention_until=unixepoch()-1 WHERE report_id IN (?,?)')
   .bind(terminal.id,stopped.id).run();
  await cleanupFamilyPhotoReportEvidence(testEnv);
  expect(await db.prepare('SELECT 1 FROM family_photo_report_records WHERE report_id=?').bind(terminal.id).first()).toBeNull();
  expect(await familyPhotoStopped(db,stopped.family,stopped.asset)).toBe(true);
 });
 it('keeps enforcement OFF, then stops only the original asset once at seven days',async()=>{
  const a=await report(604801),replacement=crypto.randomUUID();
  await advanceFamilyPhotoReportDeadlines(db,false);
  expect(await familyPhotoStopped(db,a.family,a.asset)).toBe(false);
  await advanceFamilyPhotoReportDeadlines(db,true);
  await advanceFamilyPhotoReportDeadlines(db,true);
  expect(await familyPhotoStopped(db,a.family,a.asset)).toBe(true);
  expect(await familyPhotoStopped(db,a.family,replacement)).toBe(false);
  expect(await familyPhotoStopped(db,crypto.randomUUID(),a.asset)).toBe(false);
  expect(await db.prepare('SELECT revision,outcome FROM family_photo_report_records WHERE report_id=?').bind(a.id).first())
   .toEqual({revision:1,outcome:'photo'});
 });
 it('does not stop early or override an operator decision',async()=>{
  const early=await report(100),decided=await report(604801,'no_action');
  await advanceFamilyPhotoReportDeadlines(db,true);
  expect(await familyPhotoStopped(db,early.family,early.asset)).toBe(false);
  expect(await familyPhotoStopped(db,decided.family,decided.asset)).toBe(false);
  await expect(db.prepare('INSERT INTO family_photo_report_deadlines VALUES (?,?,?,unixepoch())')
   .bind(early.id,early.family,early.asset).run()).rejects.toThrow('family_photo_deadline_not_due');
 });
 it('creates one reminder at day one and day five and cancels pending reminders on stopping',async()=>{
  const a=await report(5*86400+1);
  await advanceFamilyPhotoReportDeadlines(db,true);
  await advanceFamilyPhotoReportDeadlines(db,true);
  expect((await db.prepare('SELECT day,state FROM family_photo_report_reminders WHERE report_id=? ORDER BY day').bind(a.id).all()).results)
   .toEqual([{day:1,state:'pending'},{day:5,state:'pending'}]);
 });
 it('rejects retargeting a deadline or mutating the original report identity',async()=>{
  const a=await report(604801);
  await expect(db.prepare('INSERT INTO family_photo_report_deadlines VALUES (?,?,?,unixepoch())')
   .bind(a.id,a.family,crypto.randomUUID()).run()).rejects.toThrow('family_photo_deadline_not_due');
  await expect(db.prepare('UPDATE family_photo_report_records SET asset_id=? WHERE report_id=?')
   .bind(crypto.randomUUID(),a.id).run()).rejects.toThrow('family_photo_report_target_immutable');
 });
});
