import {describe,it,expect} from 'vitest';
import {person,signed,send,testEnv,db} from './group-fixture';
import {groupReportingAvailabilityPath as path} from '../src/group-reporting-availability';

describe('signed group reporting availability',()=>{
  const enabled={...testEnv,GROUP_REPORT_RUNTIME_ENABLED:'YES',GROUP_MODERATION_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES'};
  it('requires both operator and intake gates, but does not restore or require media membership',async()=>{
    const actor=await person();
    const active=await send(await signed(actor,path),{...enabled,GROUP_RUNTIME_ENABLED:'NO',MOMENT_RUNTIME_ENABLED:'NO'});
    expect(active.status).toBe(200);expect(active.data).toEqual({protocolVersion:3,reportingAvailable:true});
    for(const key of ['GROUP_REPORT_RUNTIME_ENABLED','GROUP_MODERATION_RUNTIME_ENABLED','REPORT_INGESTION_RUNTIME_ENABLED'] as const){
      const result=await send(await signed(actor,path),{...enabled,[key]:'NO'});
      expect(result.status).toBe(200);expect(result.data).toEqual({protocolVersion:3,reportingAvailable:false});
    }
    await db.prepare('UPDATE personal_staging_runtime_gate SET report_ingestion_enabled=0 WHERE singleton=1').run();
    expect((await send(await signed(actor,path),enabled)).data.reportingAvailable).toBe(false);
    await db.prepare('UPDATE personal_staging_runtime_gate SET report_ingestion_enabled=1 WHERE singleton=1').run();
  });
  it('does not expose an authenticated affordance to anonymous or revoked identities',async()=>{
    const actor=await person();
    expect((await send(new Request('https://example.test'+path),enabled)).status).toBe(401);
    await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(actor.deviceId).run();
    expect((await send(await signed(actor,path),enabled)).status).toBe(401);
  });
  it('rejects stale signed requests rather than caching an earlier availability result',async()=>{
    const actor=await person(),request=await signed(actor,path);
    expect((await send(new Request(request.url,{headers:request.headers}),enabled)).data.reportingAvailable).toBe(true);
    const repeated=await send(request,enabled);
    expect(repeated.status).toBe(401);
    expect(repeated.data.reportingAvailable).toBeUndefined();
  });
});
