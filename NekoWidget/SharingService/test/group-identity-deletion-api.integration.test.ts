import {describe,it,expect} from 'vitest';
import {advanceIdentityDeletion} from '../src/group-identity-service';
import {randomBase64url} from '../src/encoding';
import {testEnv,db,person,signed,send} from './group-fixture';

const url='https://example.com/v3/group-identities/deletion-requests';
const env={...testEnv,GROUP_IDENTITY_ERASURE_ENABLED:'YES'};
const key='group-identity-deletions/v1/control';
async function status(id:string,r:string){
 return send(new Request(url+'/'+id+'/status',{headers:{Authorization:'Bearer '+r}}),env);
}
describe('authenticated A1 erasure lifecycle',()=>{
 it('completes without waiting for unattributable old records, keeps a peer, and refuses a stale checkpoint',async()=>{
   await env.MEDIA!.put(key,JSON.stringify({sequence:0,requestId:''}));
   const a=await person(),b=await person(),id=crypto.randomUUID(),receipt=randomBase64url(32);
   // Legacy records can outlive both their original moment and their accused
   // pointer. A different reporter is still identifiable and must be preserved.
   const oldReport=randomBase64url(16),oldMoment=randomBase64url(16),now=Math.floor(Date.now()/1000);
   const space=randomBase64url(16),ap=randomBase64url(16),bp=randomBase64url(16);
   const q=(s:string,...v:(string|number)[])=>db.prepare(s).bind(...v);
   await db.batch([
     q("INSERT INTO group_windows(space_id,owner_person_id,mode,revision,key_epoch,roster_hash,created_at,updated_at) VALUES (?,?,'active',1,1,'test',?,?)",space,a.id,now,now),
     q("INSERT INTO group_members VALUES (?,?,?,'owner','active',1,NULL,'name')",ap,space,a.id),
     q("INSERT INTO group_members VALUES (?,?,?,'member','active',1,NULL,'name')",bp,space,b.id),
     q("INSERT INTO group_window_devices VALUES (?,?,?,'active',1,NULL)",space,a.deviceId,ap),
     q("INSERT INTO group_window_devices VALUES (?,?,?,'active',1,NULL)",space,b.deviceId,bp),
     q("INSERT INTO group_rosters VALUES (?,1,'prev',1,X'01','test',?,'sig',?)",space,a.deviceId,now),
     q("INSERT INTO group_moments VALUES (?,?,?,?,?,1,1,'test',42,'hash','sig','photo','reserved',?,?,?,NULL,?,?,NULL)",oldMoment,space,oldMoment,ap,a.deviceId,'groups/v3/'+space+'/'+oldMoment+'/'+randomBase64url(32),now,now+600,now+86400,now+86400),
     q("UPDATE group_moments SET state='uploaded' WHERE id=?",oldMoment),
     q("UPDATE group_moments SET state='committed',committed_at=? WHERE id=?",now,oldMoment),
     q("INSERT INTO group_moment_deliveries VALUES (?,?,?,1,'acknowledged',?,?)",oldMoment,b.deviceId,bp,now+86400,now),
     q("INSERT INTO group_reports (id,space_id,moment_id,reporter_person_id,reporter_participant_id,reporter_device_id,accused_participant_id,reason_code,moderation_key_id,ciphertext_size,ciphertext_sha256,reporter_consent_version,reporter_consented_at,object_key,dedupe_key,state,created_at,upload_expires_at) VALUES (?,?,?,?,?,?,?,'privacy','moderation-v2',32,'hash',1,?,?,?,'reserved',?,?)",oldReport,space,oldMoment,b.id,bp,b.deviceId,ap,now,'groups/reports/v3/'+oldReport+'/'+randomBase64url(24),oldReport,now,now+3600),
     q('INSERT INTO group_report_numbers(report_id) VALUES (?)',oldReport),
     q("UPDATE group_reports SET state='uploaded',uploaded_at=? WHERE id=?",now,oldReport),
     q("UPDATE group_reports SET state='committed',committed_at=?,content_expires_at=? WHERE id=?",now,now+604800,oldReport),
     q("DELETE FROM group_reports WHERE id=?",oldReport),
     q("DELETE FROM group_moments WHERE id=?",oldMoment),
   ]);
   const remaining=()=>db.prepare('SELECT * FROM group_report_records WHERE report_id=?').bind(oldReport).first();
   const old=await remaining();expect(old?.reporter_person_id).toBe(b.id);
   const payload={operationId:id,receipt};
   const request=()=>signed(a,new URL(url).pathname,payload);
   expect((await send(new Request(url,{method:'POST',body:JSON.stringify(payload)}),env)).status).toBe(401);
   const result=await send(await request(),env);
   expect(result.data).toMatchObject({requestId:id,state:'processing',completedAt:null});
   expect(result.status).toBe(202);
   expect((await status(id,randomBase64url(32))).status).toBe(404);
   expect((await status(id,receipt)).data).toMatchObject({state:'processing',acceptedAt:result.data.acceptedAt});
   // The receipt, not a still-valid identity key, recovers the lost 202.
   await advanceIdentityDeletion(env);
   const done=await status(id,receipt);
   expect(done.status).toBe(200);expect(done.data).toMatchObject({state:'completed',requestId:id,acceptedAt:result.data.acceptedAt});
   expect(done.data.completedAt-result.data.acceptedAt).toBeLessThan(60);
   await advanceIdentityDeletion(env);
   expect((await status(id,receipt)).data).toEqual(done.data);
   expect(await db.prepare('SELECT state FROM group_people WHERE id=?').bind(a.id).first('state')).toBe('revoked');
   expect(await db.prepare('SELECT state FROM group_people WHERE id=?').bind(b.id).first('state')).toBe('active');
   expect(await remaining()).toEqual(old);
   const slot=await (await env.MEDIA!.get('group-identity-deletions/v1/work/1'))!.text();
   expect(JSON.parse(slot)).toEqual({requestId:id,sequence:1,completedAt:done.data.completedAt});
   expect(await env.MEDIA!.head('group-identity-deletions/v1/report-allowlists/'+id)).toBeNull();
   expect((await send(await request(),env)).status).toBe(401);
   await db.prepare("UPDATE group_identity_deletion_checkpoint SET sequence=0,request_id=''").run();
   expect((await status(id,receipt)).status).toBe(503);
   expect((await send(await signed(b,'/v3/group-windows/list',{}),env)).status).toBe(503);
   await expect(advanceIdentityDeletion(env)).rejects.toMatchObject({status:503});
 });
});
