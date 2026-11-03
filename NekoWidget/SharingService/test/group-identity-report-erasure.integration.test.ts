import {expect,it} from 'vitest';
import {db,testEnv} from './group-fixture';
import {randomBase64url} from '../src/encoding';
import {acceptIdentityFence} from '../src/group-identity-fence';
import {captureIdentityReportErasure,runIdentityReportErasure,clearIdentityReportErasure,prepareReportManifest,installReportManifest,sealIdentityReportAcceptance} from '../src/group-identity-report-erasure';

it('erases only the fixed, still eligible report set and recovers an interrupted moderation object removal',async()=>{
 const now=Math.floor(Date.now()/1000),space=randomBase64url(16);
 const a=randomBase64url(16),b=randomBase64url(16),r=randomBase64url(16);
 const sql=(s:string,...args:(string|number)[])=>db.prepare(s).bind(...args);
 for(const p of [a,b,r]) {
   await db.batch([sql("INSERT INTO group_people VALUES (?,?,'active',?)",p,'identity-'+p,now),
    sql("INSERT INTO group_person_devices VALUES (?,?,?,?,?,'active',?,NULL)",'d'+p,p,'sig'+p,'hpke'+p,'cert'+p,now)]);
 }
 await sql("INSERT INTO group_windows(space_id,owner_person_id,mode,revision,key_epoch,roster_hash,created_at,updated_at) VALUES (?,?,'active',1,1,'roster',?,?)",space,a,now,now).run();
 for(const p of [a,b,r])await db.batch([
  sql("INSERT INTO group_members VALUES (?,?,?,?,'active',1,NULL,'name')",'m'+p,space,p,p===a?'owner':'member'),
  sql("INSERT INTO group_window_devices VALUES (?,?,?,'active',1,NULL)",space,'d'+p,'m'+p),
 ]);
 await sql("INSERT INTO group_rosters VALUES (?,1,'previous',1,X'01','roster',?,'sig',?)",space,'d'+a,now).run();
 const moment=(id:string,sender:string)=>[
   sql("INSERT INTO group_moments VALUES (?,?,?,?,?,1,1,'roster',42,'hash','sig','photo','reserved',?,?,?,NULL,?,?,NULL)",
      id,space,id,'m'+sender,'d'+sender,'groups/v3/'+space+'/'+id+'/'+randomBase64url(32),now,now+600,now+30*86400,now+7*86400),
   sql("UPDATE group_moments SET state='uploaded' WHERE id=?",id),
   sql("UPDATE group_moments SET state='committed',committed_at=? WHERE id=?",now,id)];
 async function report(sender:string){
   const m=randomBase64url(16),id=randomBase64url(16),object='groups/reports/v3/'+id+'/'+randomBase64url(24);
   await db.batch([...moment(m,sender),sql("INSERT INTO group_moment_deliveries VALUES (?,?,?,1,'acknowledged',?,?)",m,'d'+r,'m'+r,now+86400,now),
    sql("INSERT INTO group_reports (id,space_id,moment_id,reporter_person_id,reporter_participant_id,reporter_device_id,accused_participant_id,reason_code,moderation_key_id,ciphertext_size,ciphertext_sha256,reporter_consent_version,reporter_consented_at,object_key,dedupe_key,state,created_at,upload_expires_at) VALUES (?,?,?,?,?,?,?,'privacy','moderation-v2',32,'hash',1,?,?,?,'reserved',?,?)",id,space,m,r,'m'+r,'d'+r,'m'+sender,now,object,id,now,now+3600),
    sql('INSERT INTO group_report_numbers(report_id) VALUES (?)',id),
    sql("UPDATE group_reports SET state='uploaded',uploaded_at=? WHERE id=?",now,id),
    sql("UPDATE group_reports SET state='committed',committed_at=?,content_expires_at=? WHERE id=?",now,now+604800,id)]);
   await testEnv.MODERATION_MEDIA!.put(object,'evidence');return {m,id,object};
 }
 const ordinary=await report(a),second=await report(a),stopped=await report(a),laterStopped=await report(a),unknown=await report(a),other=await report(b);
 async function stop(x:typeof ordinary,ch:string){
   const ref=ch.repeat(64);
   await db.batch([sql("INSERT INTO group_moderation_cases VALUES (?,?,1,0,'received',?)",ref,x.id,now),
    sql("INSERT INTO group_moderation_restrictions VALUES (?,?,?,'person',?,1,1,?,?)",randomBase64url(16),ref,space,a,now,now)]);
 }

 await stop(stopped,'1');
 // The evidence row and original moment were removed by historical GC. Only
 // its reporter remains identifiable. The reporter is a different person.
 await db.batch([sql('DELETE FROM group_reports WHERE id=?',unknown.id),sql('DELETE FROM group_moments WHERE id=?',unknown.m)]);
 await testEnv.MODERATION_MEDIA!.delete(unknown.object);
 const auth={requestId:crypto.randomUUID(),acceptedAt:now};
 const snapshot=await prepareReportManifest(testEnv,auth,a);
 await expect(installReportManifest(testEnv,auth,a,snapshot)).rejects.toThrow();
 const f={...await acceptIdentityFence(testEnv.MEDIA!,a,auth.requestId,randomBase64url(32),randomBase64url(32),now),nonce:crypto.randomUUID()};
 await expect(runIdentityReportErasure(testEnv,f,a)).rejects.toThrow();
 await expect(captureIdentityReportErasure(testEnv,f,b)).rejects.toThrow();
 const wrongSubject=await prepareReportManifest(testEnv,f,b);
 await expect(installReportManifest(testEnv,f,a,wrongSubject)).rejects.toThrow();
 await installReportManifest(testEnv,f,a,snapshot);
 await expect(installReportManifest(testEnv,f,a,{...snapshot,entries:[]})).rejects.toThrow();
 const manifest=await (await testEnv.MEDIA!.get('group-identity-deletions/v1/report-allowlists/'+f.requestId))!.text();
 for(const id of [ordinary.id,stopped.id,unknown.id,other.id,a,b,r])expect(manifest).not.toContain(id);
 expect(JSON.parse(manifest).entries).toHaveLength(3);
 // A populated terminal case exercises the retained audit FKs and counter
 // floor guards. These are local D1 fixtures, not operator authentication.
 const ref='3'.repeat(64),cred='4'.repeat(64),readId=crypto.randomUUID(),decisionId=crypto.randomUUID(),receipt=crypto.randomUUID();
 const challenge=(id:string,action:string,rid:string|null)=>db.prepare(`INSERT INTO group_moderation_challenges
 (id,operator_id,credential_id_sha256,enrollment_admission_id,access_session_sha256,policy_revision,value_sha256,
 case_reference,case_revision,source_sha256,receipt_id,action,queue_after,created_at,expires_at)
 VALUES (?,'operator',?,'enrollment','session',1,'value',?,0,'source',?,?,0,unixepoch(),unixepoch()+300)`).bind(id,cred,ref,rid,action);
 const consume=(id:string,n:number)=>[
   sql("INSERT INTO group_moderation_attempts VALUES (?,'assertion',unixepoch())",id),
   sql("INSERT INTO group_moderation_consumptions VALUES (?,'assertion',?,unixepoch())",id,n)];
 await db.batch([sql("INSERT INTO group_moderation_cases VALUES (?,?,1,0,'received',?)",ref,ordinary.id,now),
   sql('INSERT INTO group_operator_counter_floors VALUES (?,0)',cred),challenge(readId,'read',null),...consume(readId,8),
   ...['started','disclosure_ready','delivered'].map(phase=>sql('INSERT INTO group_moderation_read_events VALUES (?,?,unixepoch())',readId,phase)),
   sql('INSERT INTO group_moderation_receipts VALUES (?,?,unixepoch()+300)',receipt,readId),
   challenge(decisionId,'no_action',receipt),...consume(decisionId,9),
   sql("INSERT INTO group_moderation_decisions VALUES (?,?,?,1,'no_action','review_no_action_v1',unixepoch())",crypto.randomUUID(),decisionId,ref)]);
 expect(await sql('SELECT outcome FROM group_report_records WHERE report_id=?',ordinary.id).first('outcome')).toBe('no_action');
 // Restore just the older, now identifiable original moment. A fresh scan
 // would include this report, but its digest is absent from the frozen list.
 await db.batch(moment(unknown.m,a));
 expect(await sql('SELECT 1 FROM group_identity_report_candidates WHERE person_id=? AND report_id=?',a,unknown.id).first()).not.toBeNull();
 await captureIdentityReportErasure(testEnv,f,a);
 await stop(laterStopped,'2');
 // Stop and source decisions are taken with the first receipt nonce. A crash
 // in the atomic D1 transaction restores the complete record and no nonce.
 await sql('INSERT INTO group_identity_deletion_acceptance(request_id,subject_id,nonce,request_hash,accepted_at) VALUES (?,?,?,?,?)',
   f.requestId,a,f.nonce,f.requestHash,f.acceptedAt).run();
 await db.prepare("CREATE TRIGGER synthetic_fail_seal BEFORE DELETE ON group_report_numbers WHEN OLD.report_id='"+ordinary.id+"' BEGIN SELECT RAISE(ABORT,'injected'); END").run();
 await expect(sealIdentityReportAcceptance(testEnv,f,a,f.requestHash,snapshot)).rejects.toThrow(/injected/);
 expect(await sql('SELECT 1 FROM group_identity_report_seals WHERE request_id=?',f.requestId).first()).toBeNull();
 expect(await sql('SELECT nonce FROM group_identity_deletion_acceptance WHERE request_id=?',f.requestId).first('nonce')).toBe(f.nonce);
 await expect(runIdentityReportErasure(testEnv,f,a)).rejects.toThrow();
 expect(await sql('SELECT outcome FROM group_report_records WHERE report_id=?',ordinary.id).first('outcome')).toBe('no_action');
 await db.prepare('DROP TRIGGER synthetic_fail_seal').run();
 await sealIdentityReportAcceptance(testEnv,f,a,f.requestHash,snapshot);
 await expect(sealIdentityReportAcceptance(testEnv,f,a,f.requestHash,snapshot)).rejects.toThrow(/UNIQUE/);
 // The older pre-acceptance checkpoint cannot produce this nonce. An
 // independently published work item with a mismatch may not authorize any R2 deletion.
 await expect(runIdentityReportErasure(testEnv,{...f,nonce:crypto.randomUUID()},a)).rejects.toThrow();
 expect(await testEnv.MODERATION_MEDIA!.head(ordinary.object)).not.toBeNull();
 const broken=new Proxy(testEnv.MODERATION_MEDIA!,{get(t,k){if(k==='delete')return async()=>{throw new Error('R2 unavailable');};
   const v=Reflect.get(t,k);return typeof v==='function'?v.bind(t):v;}});
 await expect(runIdentityReportErasure({...testEnv,MODERATION_MEDIA:broken},f,a)).rejects.toThrow('R2 unavailable');
 expect(await sql('SELECT request_id FROM group_identity_report_object_work WHERE report_id=?',ordinary.id).first('request_id')).toBe(f.requestId);
 await expect(clearIdentityReportErasure(testEnv,f,a)).rejects.toThrow();
 // A foreign request ticket in a restored DB is not deletion authority.
 await sql('INSERT INTO group_identity_report_object_work VALUES (?,?,?)',f.requestId,other.id,other.object).run();
 await expect(runIdentityReportErasure(testEnv,f,a)).rejects.toThrow();
 expect(await testEnv.MODERATION_MEDIA!.head(other.object)).not.toBeNull();
 await sql('DELETE FROM group_identity_report_object_work WHERE request_id=? AND report_id=?',f.requestId,other.id).run();
 await runIdentityReportErasure(testEnv,f,a);await runIdentityReportErasure(testEnv,f,a);
 expect(await testEnv.MODERATION_MEDIA!.head(ordinary.object)).toBeNull();
 expect(await testEnv.MODERATION_MEDIA!.head(second.object)).toBeNull();
 expect(await sql('SELECT 1 FROM group_report_records WHERE report_id=?',second.id).first()).toBeNull();
 for(const table of ['group_moderation_challenges','group_moderation_decisions','group_moderation_cases'])
   expect(await sql('SELECT 1 FROM '+table+' WHERE case_reference=?',ref).first()).toBeNull();
 expect(await sql('SELECT 1 FROM group_report_events WHERE report_id=?',ordinary.id).first()).toBeNull();
 expect(await sql('SELECT sign_count FROM group_operator_counter_floors WHERE credential_id_sha256=?',cred).first('sign_count')).toBe(9);
 expect(await sql('SELECT 1 FROM group_reports WHERE id=?',ordinary.id).first()).toBeNull();
 expect(await sql('SELECT 1 FROM group_report_records WHERE report_id=?',ordinary.id).first()).toBeNull();
 expect(await sql('SELECT 1 FROM group_report_numbers WHERE report_id=?',ordinary.id).first()).toBeNull();
 for(const x of [stopped,laterStopped,unknown,other])expect(await sql('SELECT 1 FROM group_report_records WHERE report_id=?',x.id).first()).not.toBeNull();
 for(const x of [stopped,laterStopped,other])expect(await testEnv.MODERATION_MEDIA!.head(x.object)).not.toBeNull();
 expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
 await expect(clearIdentityReportErasure(testEnv,f,a)).rejects.toThrow();
 await sql('UPDATE group_identity_deletion_checkpoint SET sequence=1,request_id=? WHERE singleton=1',f.requestId).run();
 await clearIdentityReportErasure(testEnv,f,a);
 expect(await sql('SELECT 1 FROM group_identity_report_seals WHERE request_id=?',f.requestId).first()).toBeNull();
 await expect(runIdentityReportErasure(testEnv,f,a)).rejects.toThrow();
});
