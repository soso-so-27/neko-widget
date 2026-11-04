import { env } from 'cloudflare:workers';
import { beforeEach, expect, it } from 'vitest';
import { notifyIntakeState } from '../src/intake-notifications';
import { sendGroupReportMail } from '../../SharingService/src/group-report-mail';
import { renewIntake } from '../src/intake-renewal';
import { renewalPolicy } from '../src/intake-renewal-policy';
import { ServiceError } from '../src/contracts';
const DB=(env as unknown as {DB:D1Database}).DB, now=Date.parse('2026-11-04T06:00:00Z');
const config={DB,GROUP_REPORT_EMAIL_ENABLED:'YES'};
beforeEach(async()=>{await DB.batch([
 DB.prepare('DELETE FROM pa_intake_notification'),DB.prepare('INSERT INTO pa_intake_notification(singleton) VALUES(1)'),
 DB.prepare('DELETE FROM pa_intake_renewal'),DB.prepare('INSERT INTO pa_intake_renewal(singleton) VALUES(1)'),
 DB.prepare('DELETE FROM pa_intake_control'),DB.prepare('INSERT INTO pa_intake_control(singleton) VALUES(1)')]);});
it('never-enabled deployment is quiet; OFF observes status without sending or altering intake',async()=>{
 let sent=0;const logs:object[]=[];
 await notifyIntakeState(config,now,async()=>{sent++;},x=>logs.push(x));expect(sent).toBe(0);expect(logs).toEqual([]);
 await DB.prepare("UPDATE pa_intake_renewal SET last_result='closed'").run();
 const before=await DB.prepare('SELECT * FROM pa_intake_control').first();
 await notifyIntakeState({...config,GROUP_REPORT_EMAIL_ENABLED:'NO'},now,async()=>{sent++;},x=>logs.push(x));
 expect(sent).toBe(0);expect(logs).toEqual([{event:'preservation_intake_status',kind:'closed',at:now}]);
 expect(await DB.prepare('SELECT * FROM pa_intake_control').first()).toEqual(before);
});
it('each of warning, closure, expiry and credential rejection uses a fixed mail kind',async()=>{
 const kinds:string[]=[];
 for(const kind of ['warning','closed','expired','credentials']){
  await DB.prepare("UPDATE pa_intake_renewal SET warning=?,last_result=?").bind(kind==='warning'?1:0,kind==='warning'?'renewed':kind).run();
  await notifyIntakeState(config,now+kinds.length*21600000,async(_,k)=>{kinds.push(k);},()=>{});
 }
 expect(kinds).toEqual(['warning','closed','expired','credentials']);
});
it('concurrent sends are claimed once and repeated state is quiet; recovery rearms it',async()=>{
 await DB.prepare('UPDATE pa_intake_renewal SET warning=1').run();let calls=0;
 await Promise.all(Array.from({length:5},()=>notifyIntakeState(config,now,async()=>{calls++;},()=>{})));
 expect(calls).toBe(1);await notifyIntakeState(config,now+21600000,async()=>{calls++;},()=>{});expect(calls).toBe(1);
 await DB.prepare('UPDATE pa_intake_renewal SET warning=0').run();await notifyIntakeState(config,now+21600000,async()=>{calls++;},()=>{});
 await DB.prepare('UPDATE pa_intake_renewal SET warning=1').run();await notifyIntakeState(config,now+21600000,async()=>{calls++;},()=>{});expect(calls).toBe(2);
});
it('failed send is bounded to one attempt per six hours and provider details never enter logs',async()=>{
 await DB.prepare("UPDATE pa_intake_renewal SET last_result='credentials'").run();let calls=0;const logs:object[]=[];
 const send=async()=>{calls++;throw Error('secret@example.invalid token-content');};
 await notifyIntakeState(config,now,send,x=>logs.push(x));await notifyIntakeState(config,now+1,send,x=>logs.push(x));expect(calls).toBe(1);
 await notifyIntakeState(config,now+21600000,send,x=>logs.push(x));expect(calls).toBe(2);expect(JSON.stringify(logs)).not.toContain('secret');
});
it('expired authorization alerts without calling cost APIs or reopening intake',async()=>{
 await DB.prepare('UPDATE pa_intake_renewal SET approved_until=?').bind(now-1).run();const kinds:string[]=[];
 await notifyIntakeState(config,now,async(_,k)=>{kinds.push(k);},()=>{});expect(kinds).toEqual(['expired']);
 expect(await DB.prepare('SELECT enabled FROM pa_intake_control').first()).toEqual({enabled:0});
});
it('rejected cost credentials persist a scrubbed reason and keep writes closed',async()=>{
 await DB.prepare('UPDATE pa_intake_renewal SET enabled=1,approved_until=?').bind(now+86400000).run();
 const keys=Object.keys(renewalPolicy.limits);await DB.prepare('UPDATE pa_intake_control SET '+keys.map(k=>k+'=?').join(',')).bind(...Object.values(renewalPolicy.limits)).run();
 expect(await renewIntake(DB,()=>now,async()=>{throw new ServiceError('COST_CREDENTIAL_REJECTED',503);})).toBe('closed');
 expect(await DB.prepare('SELECT last_result FROM pa_intake_renewal').first()).toEqual({last_result:'credentials'});
});
it('operator mail only uses configured single recipient and fixed text; invalid headers fail',async()=>{
 const messages:any[]=[];const mail={GROUP_REPORT_EMAIL_ENABLED:'YES',GROUP_REPORT_EMAIL_TO:'owner@example.invalid',GROUP_REPORT_EMAIL_FROM:'notices@example.invalid',GROUP_REPORT_EMAIL:{send:async(x:any)=>{messages.push(x);}} as unknown as SendEmail};
 await sendGroupReportMail(mail,'warning');expect(messages[0]).toEqual({from:'notices@example.invalid',to:'owner@example.invalid',subject:'保存の実測費用が警戒額に達しました',text:'保存の実測費用が警戒額に達しました'});
 await expect(sendGroupReportMail({...mail,GROUP_REPORT_EMAIL_TO:'x@example.invalid\r\nBcc: y@example.invalid'},'closed')).rejects.toThrow();expect(messages).toHaveLength(1);
});

it('a concurrent collector still checking does not emit a false closure',async()=>{
 await DB.prepare("UPDATE pa_intake_renewal SET last_result='checking',approved_until=?,lease_until=?").bind(now+86400000,now+60000).run();
 let calls=0;const logs:object[]=[];await notifyIntakeState(config,now,async()=>{calls++;},x=>logs.push(x));expect(calls).toBe(0);expect(logs).toEqual([]);
});
