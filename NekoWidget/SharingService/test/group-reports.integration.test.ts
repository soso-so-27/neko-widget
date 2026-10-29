import { beforeEach,describe,expect,it,vi } from 'vitest';
import { plusOwner,pauseOwner } from './group-billing-fixture';
import { base64urlDecode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupFields } from '../src/group-protocol';
import { queueLateGroupReportUpload } from '../src/group-reports';
import { runGroupReportCleanup } from '../src/group-report-cleanup';
import { apply,call,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person,type Reply } from './group-fixture';
import type { Env } from '../src/env';
import { authenticateGroupRequest } from '../src/group-auth';
import { drainGroupReportMail,runGroupReportOperations } from '../src/group-report-operations';
import * as reportNumbers from '../src/group-report-number';
import type { GroupReportMailEnv } from '../src/group-report-mail';

const reports={...testEnv,GROUP_REPORT_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES',GROUP_MODERATION_RUNTIME_ENABLED:'YES'};
type Window=Awaited<ReturnType<typeof create>>;
async function family() {
  const owner=await plusOwner(),bob=await person();let w=await create(owner);
  const invite=await invitation(owner,w),b=await apply(bob,w,invite);ok(b.response,201);
  const approved=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(approved.response);w=approved.next;
  return {owner,bob,w};
}
async function photo(owner:Person,w:Window) {
  const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
  const pid=w.roster.members.find(m=>m.personId===owner.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),pid,owner.deviceId,String(bytes.length)]);
  const body={operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    ciphertextSize:bytes.length,ciphertextSHA256:hash,senderSignature:await sign(owner.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),kind:'photo'};
  const reserved=ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/reserve`,body),201),id=reserved.momentId as string;
  ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/${id}/ciphertext`,bytes,randomBase64url(16),'PUT')));
  ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/${id}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}));
  return {id,bytes};
}
function root(w:Window) { return `/v3/group-windows/${w.windowId}/reports`; }
async function descriptor(momentId:string) {
  // Opaque bytes model the separately encrypted evidence. This receiver must
  // never fetch/decrypt the original photograph or accept a group generation key.
  const bytes=crypto.getRandomValues(new Uint8Array(93));
  return {bytes,body:{operationId:crypto.randomUUID(),momentId,reasonCode:'privacy',moderationKeyId:'moderation-v2',
    ciphertextSize:bytes.length,ciphertextSHA256:await sha256Base64url(bytes),reporterConsent:{version:1,acceptedAt:Math.floor(Date.now()/1000)}}};
}
async function reportCall(p:Person,path:string,body:unknown,settings:Env=reports,verb?:string) {
  return send(await signed(p,path,body,randomBase64url(16),verb),settings);
}
async function reserve(p:Person,w:Window,momentId:string) {
  const data=await descriptor(momentId),result=await reportCall(p,`${root(w)}/reserve`,data.body);
  return {...data,result,id:result.data.report?.id as string};
}
function accepted(result:Reply) { expect(result.data.error).toBeUndefined();expect([200,201]).toContain(result.status);return result.data.report; }
async function complete(p:Person,w:Window,r:Awaited<ReturnType<typeof reserve>>) {
  accepted(r.result);accepted(await reportCall(p,`${root(w)}/${r.id}/ciphertext`,r.bytes,reports,'PUT'));
  return accepted(await reportCall(p,`${root(w)}/${r.id}/commit`,{operationId:crypto.randomUUID()}));
}
async function gate(enabled:boolean) {
  await db.prepare('UPDATE personal_staging_runtime_gate SET generation=generation+1,report_ingestion_enabled=?,updated_at=unixepoch() WHERE singleton=1').bind(enabled?1:0).run();
}

// Synthetic historical state only. Preserve and restore the exact installed
// trigger; production does not acquire a clock override or weaker update guard.
async function withoutTestTrigger(name:'group_report_record_update'|'group_report_number_immutable',seed:()=>Promise<unknown>) {
  const trigger=await db.prepare("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?").bind(name).first<{sql:string}>();
  expect(trigger?.sql).toBeTruthy();
  await db.prepare(`DROP TRIGGER ${name}`).run();
  try { await seed(); } finally { await db.prepare(trigger!.sql).run(); }
}
async function seedReportDeadline(id:string,remaining:number,outcome:'received'|'no_action'='received') {
  await withoutTestTrigger('group_report_record_update',()=>db.prepare(`UPDATE group_report_records
    SET committed_at=unixepoch()+?-604800,evidence_expires_at=unixepoch()+?,outcome=?,revision=?,
      decided_at=CASE WHEN ?='received' THEN NULL ELSE unixepoch() END,
      retention_until=CASE WHEN ?='received' THEN NULL ELSE unixepoch('now','+1 year') END
    WHERE report_id=?`).bind(remaining,remaining,outcome,outcome==='received'?0:1,outcome,outcome,id).run());
}
async function mailRows(id:string) {
  return (await db.prepare(`SELECT kind,state,attempts,available_at,lease_token,lease_until,sent_at
    FROM group_report_mail_outbox WHERE report_id=? ORDER BY kind`).bind(id).all()).results;
}
function mailSettings():GroupReportMailEnv&{DB:D1Database} {
  return {DB:db,GROUP_REPORT_EMAIL_ENABLED:'YES',GROUP_REPORT_EMAIL_FROM:'notices@example.com',GROUP_REPORT_EMAIL_TO:'operator@example.com'};
}

describe('group encrypted report receiver (independent gate OFF by default)',()=>{
  it('stores selected evidence only in the moderation bucket, binds ownership and deduplicates one report',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);accepted(r.result);
    expect(JSON.stringify(r.result.data)).not.toMatch(/object_key|objectKey|groups\/reports/);
    const path=`${root(w)}/${r.id}`;
    expect((await reportCall(owner,`${path}/ciphertext`,r.bytes,reports,'PUT')).status).toBe(404);
    expect((await reportCall(bob,`${path}/ciphertext`,new Uint8Array(r.bytes.length),reports,'PUT')).data.error.code).toBe('ciphertext_descriptor_mismatch');
    expect((await reportCall(bob,`${path}/commit`,{operationId:crypto.randomUUID()})).data.error.code).toBe('report_not_ready');
    const committed=await complete(bob,w,r);
    const row=await db.prepare('SELECT object_key,content_expires_at,committed_at FROM group_reports WHERE id=?').bind(r.id).first<{object_key:string;content_expires_at:number;committed_at:number}>();
    expect(row!.content_expires_at-row!.committed_at).toBe(7*86400);
    expect(new Uint8Array(await (await reports.MODERATION_MEDIA!.get(row!.object_key))!.arrayBuffer())).toEqual(r.bytes);
    expect(await reports.MEDIA!.head(row!.object_key)).toBeNull();
    const original=await db.prepare('SELECT object_key FROM group_moments WHERE id=?').bind(p.id).first<{object_key:string}>();
    expect(new Uint8Array(await (await reports.MEDIA!.get(original!.object_key))!.arrayBuffer())).toEqual(p.bytes);
    expect(accepted(await reportCall(bob,`${root(w)}/reserve`,r.body)).id).toBe(r.id);
    expect(accepted(await reportCall(bob,`${path}/commit`,{operationId:crypto.randomUUID()})).contentExpiresAt).toBe(committed.contentExpiresAt);
    expect((await reserve(bob,w,p.id)).result.data.error.code).toBe('already_reported');
    expect((await db.prepare("SELECT COUNT(*) n FROM group_members WHERE space_id=? AND state='active'").bind(w.windowId).first<{n:number}>())?.n).toBe(2);
    expect((await db.prepare('SELECT attempts FROM group_report_daily_usage WHERE person_id=?').bind(bob.id).first<{attempts:number}>())?.attempts).toBe(1);
    expect((await send(await signed(bob,`${path}/ciphertext`),reports)).status).toBe(405);
  });
  it('rejects self reports, other windows and people who never received the moment',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),stranger=await person(),other=await create(owner),d=await descriptor(p.id);
    expect((await reportCall(owner,`${root(w)}/reserve`,d.body)).status).toBe(404);
    expect((await reportCall(stranger,`${root(w)}/reserve`,d.body)).status).toBe(404);
    expect((await reportCall(bob,`${root(other)}/reserve`,d.body)).status).toBe(404);
    const invite=await invitation(owner,w),joined=await apply(stranger,w,invite);ok(joined.response,201);
    ok((await transition(owner,w,'admit',joined.id,[...w.roster.members,joined.member])).response);
    expect((await reportCall(stranger,`${root(w)}/reserve`,d.body)).status).toBe(404);
  });
  it('keeps reporting independent of blocks, creator Plus and the media reception gate',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w);
    ok(await call(bob,`/v3/group-windows/${w.windowId}/blocks/${w.roster.members[0]!.participantId}`,{operationId:crypto.randomUUID(),active:true}));
    await pauseOwner(owner);
    const d=await descriptor(p.id),r=await reportCall(bob,`${root(w)}/reserve`,d.body,{...reports,GROUP_RUNTIME_ENABLED:'NO',MOMENT_RUNTIME_ENABLED:'NO'});
    accepted(r);
  });
  it('limits revoked credentials to their own report scope for 24 hours, without extending grants',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),pid=w.roster.members[1]!.participantId;
    const operationId=crypto.randomUUID(),before=Math.floor(Date.now()/1000);
    ok(await call(bob,`/v3/group-windows/${w.windowId}/leave`,{operationId,expectedRevision:w.roster.revision,
      selfSignature:await sign(bob.signing.privateKey,groupFields(['NW3.LEAVE',w.windowId,pid,String(w.roster.revision),operationId]))}));
    const grant=await db.prepare('SELECT expires_at FROM group_report_access WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first<{expires_at:number}>();
    expect(grant!.expires_at).toBeGreaterThanOrEqual(before+86400);expect(grant!.expires_at).toBeLessThanOrEqual(before+86402);
    expect((await call(bob,`/v3/group-windows/${w.windowId}`)).status).toBe(404);
    await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(bob.deviceId).run();
    expect((await db.prepare('SELECT expires_at FROM group_report_access WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first<{expires_at:number}>())?.expires_at).toBe(grant!.expires_at);
    const r=await reserve(bob,w,p.id);await complete(bob,w,r);
    expect((await call(bob,`/v3/group-windows/${w.windowId}`)).status).toBe(401);
    const other=await create(owner),d=await descriptor(p.id);
    expect((await reportCall(bob,`${root(other)}/reserve`,d.body)).status).toBe(401);
    await db.prepare('UPDATE group_report_access SET expires_at=unixepoch()-1 WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).run();
    expect((await reportCall(bob,`${root(w)}/${r.id}/commit`,{operationId:crypto.randomUUID()})).status).toBe(401);
  });
  it('fails closed on gate changes, rejects unknown fields/keys/consent and consumes rejected signed nonces',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),d=await descriptor(p.id),path=`${root(w)}/reserve`;
    expect((await reportCall(bob,path,d.body,testEnv)).data.error.code).toBe('group_reports_disabled');
    expect((await reportCall(bob,path,d.body,{...reports,GROUP_MODERATION_RUNTIME_ENABLED:'NO'})).data.error.code).toBe('group_moderation_disabled');
    expect((await reportCall(bob,path,{...d.body,groupKey:randomBase64url(32)})).data.error.code).toBe('invalid_fields');
    expect((await reportCall(bob,path,{...d.body,moderationKeyId:'moderation-v1'})).data.error.code).toBe('moderation_key_required');
    expect((await reportCall(bob,path,{...d.body,reporterConsent:{version:2,acceptedAt:Math.floor(Date.now()/1000)}})).data.error.code).toBe('reporter_consent_required');
    const request=await signed(bob,path,d.body),copy=await signed(bob,path,d.body,request.headers.get('neko-nonce')!);await gate(false);
    expect((await send(request,reports)).status).toBe(503);await gate(true);
    expect((await send(copy,reports)).data.error.code).toBe('replay');
    expect((await reportCall(bob,path,{...d.body,ciphertextSize:1048577})).status).toBe(400);
    expect(await db.prepare('SELECT id FROM group_reports WHERE moment_id=?').bind(p.id).first()).toBeNull();
  });
  it('resolves simultaneous identical reservations and commits once',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),d=await descriptor(p.id);
    const rs=await Promise.all([reportCall(bob,`${root(w)}/reserve`,d.body),reportCall(bob,`${root(w)}/reserve`,d.body)]);
    const id=accepted(rs[0]!).id;expect(accepted(rs[1]!).id).toBe(id);
    const path=`${root(w)}/${id}`;
    accepted(await reportCall(bob,`${path}/ciphertext`,d.bytes,reports,'PUT'));
    const body={operationId:crypto.randomUUID()},cs=await Promise.all([reportCall(bob,`${path}/commit`,body),reportCall(bob,`${path}/commit`,body)]);
    expect(accepted(cs[0]!)).toEqual(accepted(cs[1]!));
    expect((await db.prepare('SELECT COUNT(*) n FROM group_report_tombstones WHERE report_id=?').bind(id).first<{n:number}>())?.n).toBe(1);
  });
  it('charges attempts across group windows by person and does not charge retries',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),q=await photo(owner,w);
    await db.prepare('INSERT INTO group_report_daily_usage VALUES (?,?,9)').bind(bob.id,Math.floor(Date.now()/86400000)).run();
    const r=await reserve(bob,w,p.id);accepted(r.result);
    accepted(await reportCall(bob,`${root(w)}/reserve`,r.body));
    expect((await reserve(bob,w,q.id)).result.data.error.code).toBe('report_daily_quota_exceeded');
  });
  it('rechecks the gate generation after asynchronous object access before accepting a commit',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);accepted(r.result);
    accepted(await reportCall(bob,`${root(w)}/${r.id}/ciphertext`,r.bytes,reports,'PUT'));
    const storage=reports.MODERATION_MEDIA!;
    const racing=new Proxy(storage,{get(target,property){
      if(property==='head')return async(key:string)=>{const object=await target.head(key);await gate(false);return object;};
      const value=Reflect.get(target,property);return typeof value==='function'?value.bind(target):value;
    }});
    try {
      expect((await reportCall(bob,`${root(w)}/${r.id}/commit`,{operationId:crypto.randomUUID()},{...reports,MODERATION_MEDIA:racing})).status).toBe(503);
      expect((await db.prepare('SELECT state FROM group_reports WHERE id=?').bind(r.id).first<{state:string}>())?.state).toBe('uploaded');
      expect(await db.prepare('SELECT report_id FROM group_report_tombstones WHERE report_id=?').bind(r.id).first()).toBeNull();
    } finally { await gate(true); }
  });
  it('deletes only expired report ciphertext with gates OFF, including a write arriving after cleanup',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id),committed=await complete(bob,w,r);
    const row=await db.prepare('SELECT object_key FROM group_reports WHERE id=?').bind(r.id).first<{object_key:string}>();
    const original=await db.prepare('SELECT object_key FROM group_moments WHERE id=?').bind(p.id).first<{object_key:string}>();
    const settings={...reports,GROUP_REPORT_RUNTIME_ENABLED:'NO',REPORT_INGESTION_RUNTIME_ENABLED:'NO'};
    await runGroupReportCleanup(settings,committed.contentExpiresAt-1);
    expect(await reports.MODERATION_MEDIA!.head(row!.object_key)).not.toBeNull();
    await runGroupReportCleanup(settings,committed.contentExpiresAt+1);
    expect(await reports.MODERATION_MEDIA!.head(row!.object_key)).toBeNull();
    expect(await reports.MEDIA!.head(original!.object_key)).not.toBeNull();
    await reports.MODERATION_MEDIA!.put(row!.object_key,r.bytes);
    await queueLateGroupReportUpload(reports,r.id,row!.object_key);
    await runGroupReportCleanup(settings,committed.contentExpiresAt+2);
    expect(await reports.MODERATION_MEDIA!.head(row!.object_key)).toBeNull();
    await runGroupReportCleanup(settings,committed.contentExpiresAt+172802);
    expect(await db.prepare('SELECT id FROM group_reports WHERE id=?').bind(r.id).first()).toBeNull();
    expect(await db.prepare('SELECT report_id FROM group_report_tombstones WHERE report_id=?').bind(r.id).first()).not.toBeNull();
  });
  it('keeps ordinary authentication independent of the additive report schema',async()=>{
    const p=await person(),request=await signed(p,'/v3/group-windows/list',{after:null,limit:10});
    const beforeMigration=new Proxy(db,{get(target,property){
      if(property==='prepare')return (query:string)=>{
        if(query.includes('group_report'))throw new Error('report schema not installed');return target.prepare(query);
      };
      const value=Reflect.get(target,property);return typeof value==='function'?value.bind(target):value;
    }});
    expect((await authenticateGroupRequest(request,{...testEnv,DB:beforeMigration})).actor.deviceId).toBe(p.deviceId);
  });
  it('replays a reserved report after its original consent timestamp ages without admitting new stale consent',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),q=await photo(owner,w),r=await reserve(bob,w,p.id);accepted(r.result);
    const fresh=await descriptor(q.id),now=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(now+600000);
    try {
      expect(accepted(await reportCall(bob,`${root(w)}/reserve`,r.body)).id).toBe(r.id);
      expect((await reportCall(bob,`${root(w)}/reserve`,fresh.body)).data.error.code).toBe('reporter_consent_required');
      expect(await db.prepare('SELECT id FROM group_reports WHERE moment_id=?').bind(q.id).first()).toBeNull();
      expect((await db.prepare('SELECT attempts FROM group_report_daily_usage WHERE person_id=?').bind(bob.id).first<{attempts:number}>())?.attempts).toBe(1);
    } finally { clock.mockRestore(); }
  });
  describe('acceptance records and fixed notification obligations',()=>{
  beforeEach(async()=>{
    // This file shares its local D1 between tests. A drain visits the entire
    // queue, so discard only prior synthetic mail obligations before each case.
    await db.prepare('DELETE FROM group_report_mail_outbox').run();
  });
  it('assigns a stable number at reserve and commits the record and one mail obligation atomically',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id),reserved=accepted(r.result);
    expect(reserved.receiptNumber).toMatch(/^R-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$/);
    expect(await db.prepare('SELECT report_id FROM group_report_records WHERE report_id=?').bind(r.id).first()).toBeNull();
    expect(await mailRows(r.id)).toEqual([]);
    accepted(await reportCall(bob,`${root(w)}/${r.id}/ciphertext`,r.bytes,reports,'PUT'));
    // Failing the last write must roll back the accepted report and its record.
    await db.prepare("CREATE TRIGGER test_reject_report_mail BEFORE INSERT ON group_report_mail_outbox BEGIN SELECT RAISE(ABORT,'synthetic_mail_failure'); END").run();
    try {
      expect((await reportCall(bob,`${root(w)}/${r.id}/commit`,{operationId:crypto.randomUUID()})).status).toBe(500);
      expect(await db.prepare('SELECT state,committed_at FROM group_reports WHERE id=?').bind(r.id).first())
        .toEqual({state:'uploaded',committed_at:null});
      expect(await db.prepare('SELECT report_id FROM group_report_records WHERE report_id=?').bind(r.id).first()).toBeNull();
      expect(await mailRows(r.id)).toEqual([]);
    } finally { await db.prepare('DROP TRIGGER test_reject_report_mail').run(); }
    const committed=await complete(bob,w,r);
    expect(committed.receiptNumber).toBe(reserved.receiptNumber);
    expect(await db.prepare('SELECT report_id,outcome,committed_at,evidence_expires_at FROM group_report_records WHERE report_id=?').bind(r.id).first())
      .toEqual({report_id:r.id,outcome:'received',committed_at:committed.committedAt,evidence_expires_at:committed.contentExpiresAt});
    expect(await mailRows(r.id)).toMatchObject([{kind:'received',state:'pending',attempts:0}]);
    expect(accepted(await reportCall(bob,`${root(w)}/${r.id}/commit`,{operationId:crypto.randomUUID()})).receiptNumber).toBe(reserved.receiptNumber);
    expect(await mailRows(r.id)).toHaveLength(1);
  });

  it('keeps the number and obligation when the accepted response is lost and the same operation is retried',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id),number=accepted(r.result).receiptNumber;
    const reservedAgain=accepted(await reportCall(bob,`${root(w)}/reserve`,r.body));
    expect(reservedAgain.receiptNumber).toBe(number);
    accepted(await reportCall(bob,`${root(w)}/${r.id}/ciphertext`,r.bytes,reports,'PUT'));
    const commit={operationId:crypto.randomUUID()};
    // The client discards this server response, then signs a fresh nonce for the
    // same operation ID. This is transport response loss, not a second report.
    await reportCall(bob,`${root(w)}/${r.id}/commit`,commit);
    expect(await db.prepare('SELECT outcome FROM group_report_records WHERE report_id=?').bind(r.id).first()).toEqual({outcome:'received'});
    const replayed=accepted(await reportCall(bob,`${root(w)}/${r.id}/commit`,commit));
    expect(replayed.receiptNumber).toBe(number);
    expect(replayed.state).toBe('committed');
    expect(await mailRows(r.id)).toHaveLength(1);
    expect((await db.prepare('SELECT attempts FROM group_report_daily_usage WHERE person_id=?').bind(bob.id).first<{attempts:number}>())?.attempts).toBe(1);
  });

  it('leaves pending mail untouched when delivery is OFF or unset',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);await complete(bob,w,r);
    const before=await mailRows(r.id),sendMail=vi.fn(async()=>{});
    await drainGroupReportMail({...mailSettings(),GROUP_REPORT_EMAIL_ENABLED:'NO'},sendMail);
    const unset=mailSettings();delete unset.GROUP_REPORT_EMAIL_ENABLED;
    await drainGroupReportMail(unset,sendMail);
    expect(sendMail).not.toHaveBeenCalled();
    expect(await mailRows(r.id)).toEqual(before);
  });

  it('backs off a failed send and retries only the fixed kind, without carrying report data to the sender',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);await complete(bob,w,r);
    const settings=mailSettings();
    const sendMail=vi.fn(async(_env:GroupReportMailEnv,_kind:'received'|'undecided')=>{})
      .mockRejectedValueOnce(Error('synthetic provider failure'));
    await drainGroupReportMail(settings,sendMail);
    const failed=await mailRows(r.id);
    expect(failed).toMatchObject([{kind:'received',state:'pending',attempts:1,lease_token:null,lease_until:null,sent_at:null}]);
    expect(Number(failed[0]!.available_at)).toBeGreaterThan(Math.floor(Date.now()/1000));
    await drainGroupReportMail(settings,sendMail);
    expect(sendMail.mock.calls).toEqual([[settings,'received']]);
    await db.prepare('UPDATE group_report_mail_outbox SET available_at=unixepoch() WHERE report_id=?').bind(r.id).run();
    await drainGroupReportMail(settings,sendMail);
    await drainGroupReportMail(settings,sendMail);
    expect(sendMail.mock.calls).toEqual([[settings,'received'],[settings,'received']]);
    expect(await mailRows(r.id)).toMatchObject([{kind:'received',state:'sent',attempts:2,lease_token:null,lease_until:null}]);
    expect(Object.keys(settings).sort()).toEqual(['DB','GROUP_REPORT_EMAIL_ENABLED','GROUP_REPORT_EMAIL_FROM','GROUP_REPORT_EMAIL_TO']);
  });

  it('leases a pending message before awaiting the provider so simultaneous drains send only once',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);await complete(bob,w,r);
    const settings=mailSettings();let entered!:()=>void,finish!:()=>void;
    const started=new Promise<void>(resolve=>{entered=resolve;}),acceptedByProvider=new Promise<void>(resolve=>{finish=resolve;});
    const sendMail=vi.fn(async()=>{entered();await acceptedByProvider;});
    const first=drainGroupReportMail(settings,sendMail);
    try {
      await started;
      expect(await mailRows(r.id)).toMatchObject([{state:'leased',attempts:1}]);
      await drainGroupReportMail(settings,sendMail);
      expect(sendMail).toHaveBeenCalledTimes(1);
    } finally { finish();await first; }
    expect(await mailRows(r.id)).toMatchObject([{state:'sent',attempts:1,lease_token:null,lease_until:null}]);
  });

  it('enqueues one undecided reminder at 48 hours, excludes decisions, and cancels a queued reminder after a decision',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),q=await photo(owner,w);
    const waiting=await reserve(bob,w,p.id),decided=await reserve(bob,w,q.id);
    await complete(bob,w,waiting);await complete(bob,w,decided);
    // A one-minute outside margin avoids a wall-clock second rollover making
    // the pre-boundary assertion flaky; the due fixture is exactly 48 hours.
    await seedReportDeadline(waiting.id,172860);
    await seedReportDeadline(decided.id,172800,'no_action');
    await runGroupReportOperations(reports);
    expect((await mailRows(waiting.id)).map(row=>row.kind)).toEqual(['received']);
    expect((await mailRows(decided.id)).map(row=>row.kind)).toEqual(['received']);
    await seedReportDeadline(waiting.id,172800);
    await runGroupReportOperations(reports);await runGroupReportOperations(reports);
    expect((await mailRows(waiting.id)).map(row=>row.kind)).toEqual(['received','undecided']);
    expect((await mailRows(decided.id)).map(row=>row.kind)).toEqual(['received']);
    // The normal immutable-update guard has been restored after each seed.
    await expect(db.prepare('UPDATE group_report_records SET evidence_expires_at=evidence_expires_at+1 WHERE report_id=?').bind(waiting.id).run())
      .rejects.toThrow(/report_record_immutable/);
    await seedReportDeadline(waiting.id,172800,'no_action');
    const sendMail=vi.fn(async(_env:GroupReportMailEnv,_kind:'received'|'undecided')=>{});
    await drainGroupReportMail(mailSettings(),sendMail);
    expect(sendMail.mock.calls.map(args=>args[1])).toEqual(['received','received']);
    expect(await mailRows(waiting.id)).toMatchObject([{kind:'received',state:'sent'},{kind:'undecided',state:'cancelled',attempts:0}]);
  });

  it('regenerates only a colliding receipt number without consuming a second quota attempt',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),q=await photo(owner,w),first=await reserve(bob,w,p.id);
    const existing=accepted(first.result).receiptNumber;
    const unique=existing==='R-0000-0000-00'?'R-0000-0000-01':'R-0000-0000-00';
    const numbers=vi.spyOn(reportNumbers,'newGroupReceiptNumber').mockReturnValueOnce(existing).mockReturnValueOnce(unique);
    try {
      const second=await reserve(bob,w,q.id);
      expect(accepted(second.result).receiptNumber).toBe(unique);
      expect(numbers).toHaveBeenCalledTimes(2);
      expect((await db.prepare('SELECT COUNT(*) n FROM group_reports WHERE reporter_person_id=?').bind(bob.id).first<{n:number}>())?.n).toBe(2);
      expect((await db.prepare('SELECT attempts FROM group_report_daily_usage WHERE person_id=?').bind(bob.id).first<{attempts:number}>())?.attempts).toBe(2);
    } finally { numbers.mockRestore(); }
  });

  it('fills an old NULL number once under concurrent access and refuses to change the issued number',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);accepted(r.result);
    await withoutTestTrigger('group_report_number_immutable',()=>db.prepare('UPDATE group_report_numbers SET receipt_number=NULL WHERE report_id=?').bind(r.id).run());
    const values=await Promise.all([reportNumbers.groupReceiptNumber(db,r.id),reportNumbers.groupReceiptNumber(db,r.id)]);
    expect(values[0]).toMatch(/^R-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$/);
    expect(values[1]).toBe(values[0]);
    expect(accepted(await reportCall(bob,`${root(w)}/reserve`,r.body)).receiptNumber).toBe(values[0]);
    const different=values[0]==='R-0000-0000-00'?'R-0000-0000-01':'R-0000-0000-00';
    await expect(db.prepare('UPDATE group_report_numbers SET receipt_number=? WHERE report_id=?').bind(different,r.id).run()).rejects.toThrow(/append_only/);
    await expect(db.prepare('UPDATE group_report_numbers SET receipt_number=NULL WHERE report_id=?').bind(r.id).run()).rejects.toThrow(/append_only/);
    expect(await reportNumbers.groupReceiptNumber(db,r.id)).toBe(values[0]);
    expect(await mailRows(r.id)).toEqual([]);
  });
  });

  // Keep the irreversible installation fixture last: it intentionally closes
  // the shared test database's report-key policy for all subsequent requests.
  it('rejects an owner-scope/key change during upload and does not accept further reports',async()=>{
    const {owner,bob,w}=await family(),p=await photo(owner,w),r=await reserve(bob,w,p.id);accepted(r.result);
    const storage=reports.MODERATION_MEDIA!;
    const racing=new Proxy(storage,{get(target,property){
      if(property==='put')return async(...args:Parameters<R2Bucket['put']>)=>{
        const object=await target.put(...args);
        // Local test only: installation without a current adopted decryptor
        // closes the exact same policy used by legacy moderation-v2 reports.
        await db.prepare('INSERT INTO moderation_owner_scope_installation VALUES (1,?)').bind('a'.repeat(64)).run();
        return object;
      };
      const value=Reflect.get(target,property);return typeof value==='function'?value.bind(target):value;
    }});
    expect((await reportCall(bob,`${root(w)}/${r.id}/ciphertext`,r.bytes,{...reports,MODERATION_MEDIA:racing},'PUT')).data.error.code).toBe('moderation_key_required');
    expect((await db.prepare('SELECT state FROM group_reports WHERE id=?').bind(r.id).first<{state:string}>())?.state).toBe('reserved');
    expect((await reportCall(bob,`${root(w)}/reserve`,r.body)).data.error.code).toBe('moderation_key_required');
  });
});
