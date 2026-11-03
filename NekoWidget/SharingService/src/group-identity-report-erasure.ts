import { sha256Base64url } from './encoding';
import { ApiError } from './errors';
import type { Env } from './env';
import { groupFields } from './group-protocol';
import { readPersonIdentityFence } from './group-identity-fence';
import { GROUP_REPORT_OBJECT_KEY } from './group-reports';

export interface IdentityReportFence { requestId:string; acceptedAt:number }
interface Candidate {report_id:string;record_revision:number;case_revision:number;record_outcome:string;case_outcome:string}
type Entry=[string,number,number,string,string];
export interface Manifest {requestId:string;acceptedAt:number;subjectDigest:string;entries:Entry[]}
const unavailable=()=>new ApiError(503,'identity_report_erasure_unavailable','The deletion could not be verified.');
const key=(f:IdentityReportFence)=>'group-identity-deletions/v1/report-allowlists/'+f.requestId;
const maxBytes=8*1024*1024;
const digest=(f:IdentityReportFence,id:string)=>sha256Base64url(groupFields(['NW3.IDENTITY-REPORT-ERASURE.V1',f.requestId,id]));
const subjectDigest=(f:IdentityReportFence,person:string)=>sha256Base64url(groupFields(['NW3.IDENTITY-REPORT-SUBJECT.V1',f.requestId,person]));
async function verified(env:Env,f:IdentityReportFence,person:string) {
 if(!env.MEDIA)throw unavailable();
 const current=await readPersonIdentityFence(env.MEDIA,person);
 if(!current || current.requestId!==f.requestId || current.acceptedAt!==f.acceptedAt)throw unavailable();
 return env.MEDIA;
}
function validate(m:Manifest,f:IdentityReportFence,subject:string):void {
 if(!m || Object.keys(m).sort().join(',')!=='acceptedAt,entries,requestId,subjectDigest'
   || m.requestId!==f.requestId || m.acceptedAt!==f.acceptedAt || m.subjectDigest!==subject || !Array.isArray(m.entries))throw unavailable();
 const eligible=['absent','received','no_action','release'];
 const seen=new Set<string>();
 for(const e of m.entries) {
   if(!Array.isArray(e)||e.length!==5||typeof e[0]!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(e[0])
     ||seen.has(e[0])||![e[1],e[2]].every(n=>Number.isSafeInteger(n)&&n>=-1)
     ||!eligible.includes(e[3])||!eligible.includes(e[4]))throw unavailable();
   seen.add(e[0]);
 }
}
async function read(store:R2Bucket,f:IdentityReportFence,subject:string):Promise<Manifest|null> {
 const obj=await store.get(key(f));if(!obj)return null;
 if(obj.size<1 || obj.size>maxBytes)throw unavailable();
 const m=await obj.json<Manifest>();validate(m,f,subject);
 return m;
}
async function* candidates(env:Env,f:IdentityReportFence,person:string) {
 let cursor='';
 while(true) {
   const rows=await env.DB.prepare(`SELECT report_id,record_revision,case_revision,record_outcome,case_outcome
     FROM group_identity_report_candidates WHERE person_id=? AND created_at<=? AND report_id>?
     ORDER BY report_id LIMIT 100`).bind(person,f.acceptedAt,cursor).all<Candidate>();
   for(const row of rows.results)yield row;
   if(rows.results.length<100)return;
   cursor=rows.results[rows.results.length-1]!.report_id;
 }
}
// This reads D1 only. The authenticated acceptance operation atomically fixes
// this result in the independent slot before making any destructive change.
export async function prepareReportManifest(env:Env,f:IdentityReportFence,personId:string):Promise<Manifest> {
 if(!Number.isSafeInteger(f.acceptedAt)||f.acceptedAt<=0)throw unavailable();
 const entries:Entry[]=[];
 for await(const r of candidates(env,f,personId)) {
   entries.push([await digest(f,r.report_id),r.record_revision,r.case_revision,r.record_outcome,r.case_outcome]);
 }
 const m={requestId:f.requestId,acceptedAt:f.acceptedAt,subjectDigest:await subjectDigest(f,personId),entries};
 if(JSON.stringify(m).length>maxBytes)throw unavailable();
 return m;
}
// The caller must supply the exact contents of the accepted immutable slot on
// restart. An already installed but different manifest must never be reused.
export async function installReportManifest(env:Env,f:IdentityReportFence,personId:string,m:Manifest):Promise<void> {
 const store=await verified(env,f,personId),subject=await subjectDigest(f,personId);
 validate(m,f,subject);
 const value=JSON.stringify(m);if(value.length>maxBytes)throw unavailable();
 const written=await store.put(key(f),value,{onlyIf:{etagDoesNotMatch:'*'}});
 if(!written){
   const existing=await read(store,f,subject);
   if(!existing || JSON.stringify(existing.entries)!==JSON.stringify(m.entries))throw unavailable();
 }
}
export async function captureIdentityReportErasure(env:Env,f:IdentityReportFence,personId:string):Promise<void> {
 const store=await verified(env,f,personId);
 if(await read(store,f,await subjectDigest(f,personId)))return;
 await installReportManifest(env,f,personId,await prepareReportManifest(env,f,personId));
}
async function drainObjects(env:Env,f:IdentityReportFence,allowed:ReadonlyMap<string,Entry>) {
 for(;;) {
   const work=await env.DB.prepare('SELECT report_id,object_key FROM group_identity_report_object_work WHERE request_id=? ORDER BY report_id,object_key LIMIT 30')
     .bind(f.requestId).all<{report_id:string;object_key:string}>();
   if(!work.results.length)return;
   if(!env.MODERATION_MEDIA)throw unavailable();
   for(const {report_id,object_key} of work.results) {
     if(!allowed.has(await digest(f,report_id)) || !GROUP_REPORT_OBJECT_KEY.test(object_key)
       ||object_key.split('/')[3]!==report_id)throw unavailable();
     // Any restored report/case means this work no longer reflects the
     // atomic D1 erasure. Leave its evidence in place behind the restore barrier.
     const live=await env.DB.prepare(`SELECT 1 FROM group_reports WHERE id=?
       UNION ALL SELECT 1 FROM group_report_records WHERE report_id=?
       UNION ALL SELECT 1 FROM group_moderation_cases WHERE report_id=?
       UNION ALL SELECT 1 FROM group_moderation_restrictions WHERE active=1 AND case_reference='deadline:'||? LIMIT 1`)
       .bind(report_id,report_id,report_id,report_id).first();
     if(live)throw unavailable();
     await env.MODERATION_MEDIA.delete(object_key);
     if(await env.MODERATION_MEDIA.head(object_key))throw unavailable();
     await env.DB.batch([
       env.DB.prepare('DELETE FROM group_report_object_deletions WHERE report_id=? AND object_key=?').bind(report_id,object_key),
       env.DB.prepare('DELETE FROM group_identity_report_object_work WHERE request_id=? AND report_id=? AND object_key=?')
         .bind(f.requestId,report_id,object_key),
     ]);
   }
 }
}
export async function runIdentityReportErasure(env:Env,f:IdentityReportFence,personId:string):Promise<void> {
 const store=await verified(env,f,personId);
 const m=await read(store,f,await subjectDigest(f,personId));if(!m)throw unavailable();
 const allowed=new Map(m.entries.map(e=>[e[0],e]));
 await drainObjects(env,f,allowed);
 for await(const r of candidates(env,f,personId)) {
   const entry=allowed.get(await digest(f,r.report_id));
   if(!entry)continue;
   // A later terminal decision is still eligible. A regressed revision or
   // two outcomes for one revision cannot establish current authority.
   if(r.record_revision<entry[1] || r.case_revision<entry[2]
     || (r.record_revision===entry[1] && r.record_outcome!==entry[3])
     || (r.case_revision===entry[2] && r.case_outcome!==entry[4]))throw unavailable();
   await env.DB.prepare('INSERT INTO group_identity_report_erase_commands VALUES (?,?,?,?,?,?,?,?)')
    .bind(r.report_id,personId,f.requestId,f.acceptedAt,r.record_revision,r.case_revision,r.record_outcome,r.case_outcome).run();
 }
 await drainObjects(env,f,allowed);
}
// Caller has already checkpointed all erasure work and committed completion.
// An older checkpoint must stop at the global restore barrier.
export async function clearIdentityReportErasure(env:Env,f:IdentityReportFence,personId:string):Promise<void> {
 const store=await verified(env,f,personId);
 if(await env.DB.prepare('SELECT 1 FROM group_identity_report_object_work WHERE request_id=? LIMIT 1').bind(f.requestId).first())throw unavailable();
 await store.delete(key(f));
 if(await store.head(key(f)))throw unavailable();
}
