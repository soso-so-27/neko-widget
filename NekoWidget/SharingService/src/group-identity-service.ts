import {ApiError,jsonResponse} from './errors';
import type {Env} from './env';
import {authenticateGroupRequest} from './group-auth';
import {exactKeys} from './validation';
import {parseJsonBody,readBody,rejectQuery} from './http';
import {base64urlDecode} from './encoding';
import {prepareIdentityClaim,matchesAuthenticatedClaim,persistIdentityClaim,type Claim,lookupIdentityFence,personIsFenced} from './group-identity-fence';
import {checkedDeletionRead} from './group-identity-read-barrier';
import {captureDeletedDeliveries,deletedDeliveryStatements,type DeliveryMarker} from './group-deleted-delivery';
import {eraseGroupIdentityData,prepareIdentityErasurePhotos} from './group-identity-erasure';
import {prepareReportManifest,installReportManifest,sealIdentityReportAcceptance,runIdentityReportErasure,clearIdentityReportErasure} from './group-identity-report-erasure';

const prefix='group-identity-deletions/v1/';
const path='/v3/group-identities/deletion-requests';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const bad=()=>new ApiError(503,'deletion_recovery_required','Group data is temporarily unavailable.');
const missing=()=>new ApiError(404,'not_found','The deletion request was not found.');
function media(env:Env){if(!env.MEDIA)throw bad();return env.MEDIA;}
type Tip={sequence:number;requestId:string}
type Work={requestId:string;acceptedAt:number;personId:string;nonce:string;sequence:number;claim:Claim;markers:DeliveryMarker[];reports:Awaited<ReturnType<typeof prepareReportManifest>>;photos:Awaited<ReturnType<typeof prepareIdentityErasurePhotos>>};
async function tip(env:Env) {
 const obj=await media(env).get(prefix+'control');if(!obj||obj.size>256)throw bad();
 const t=await obj.json<Tip>();if(!Number.isSafeInteger(t.sequence)||t.sequence<0||(t.sequence===0?t.requestId!=='':!uuid.test(t.requestId)))throw bad();
 return {...t,etag:obj.etag};
}
async function cursor(env:Env) {
 const row=await env.DB.prepare('SELECT sequence,request_id AS requestId FROM group_identity_deletion_checkpoint WHERE singleton=1').first<Tip>();
 if(!row)throw bad();return row;
}
const same=(a:Tip,b:Tip)=>a.sequence===b.sequence&&a.requestId===b.requestId;
const workKey=(n:number)=>prefix+'work/'+n;
async function record<T>(env:Env,key:string):Promise<T|null> {
 const object=await media(env).get(key);if(!object)return null;
 if(object.size<1||object.size>16*1024*1024)throw bad();
 try{return await object.json<T>();}catch{throw bad();}
}
async function snapshot<T>(env:Env,key:string,make:()=>Promise<T>) {
 const current=await record<T>(env,key);if(current!==null)return current;
 const value=await make(),bucket=media(env);
 if(await bucket.put(key,JSON.stringify(value),{onlyIf:{etagDoesNotMatch:'*'}}))return value;
 const stored=await record<T>(env,key);if(stored===null)throw bad();return stored;
}
export const deletionRequired=(env:Env)=>env.GROUP_IDENTITY_ERASURE_ENABLED==='YES';
export async function protectedGroupRead<T>(env:Env,action:()=>Promise<T>):Promise<T> {
 return deletionRequired(env)?checkedDeletionRead(env.DB,media(env),action):action();
}
export async function requireCurrentIdentity(env:Env,person:string) {
 if(!deletionRequired(env))return;
 await protectedGroupRead(env,async()=>{
   if(await personIsFenced(media(env),person))throw new ApiError(401,'invalid_authentication','Group authentication failed.');
 });
}
export const isIdentityDeletionPath=(p:string)=>p===path||p.startsWith(path+'/');
async function receiptResult(env:Env,id:string,receipt:string) {
 const state=await lookupIdentityFence(media(env),id,receipt);
 const done=await record<{completedAt:number;sequence:number}>(env,prefix+'completed/'+id);
 if(!done){
   const control=await tip(env);if(control.requestId!==id)throw bad();
   const work=await record<Work|End>(env,workKey(control.sequence));
   if(!work||work.requestId!==id)throw bad();
   if('completedAt' in work){
     if(!same(await cursor(env),work))throw bad();
     await finishReceipt(env,work);return {...state,state:'completed' as const,completedAt:work.completedAt};
   }
   await requireReportSeal(env,work);return state;
 }
 if(!Number.isSafeInteger(done.completedAt)||done.completedAt<state.acceptedAt||!Number.isSafeInteger(done.sequence)||done.sequence<1)throw bad();
 const applied=await cursor(env);if(applied.sequence<done.sequence || (applied.sequence===done.sequence&&applied.requestId!==id))throw bad();
 return {...state,state:'completed' as const,completedAt:done.completedAt};
}
function validateWork(w:Work,n:number) {
 if(!w || !uuid.test(w.requestId)||w.sequence!==n || typeof w.personId!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(w.personId) ||
 !Number.isSafeInteger(w.acceptedAt)||w.acceptedAt<=0||!uuid.test(w.nonce))throw bad();
}
async function source(env:Env,w:Work) {
 const row=await env.DB.prepare('SELECT 1 FROM group_identity_deletion_acceptance WHERE request_id=? AND subject_id=? AND nonce=? AND accepted_at=? AND request_hash=?')
 .bind(w.requestId,w.personId,w.nonce,w.acceptedAt,w.claim.requestHash).first();
 if(!row || !await matchesAuthenticatedClaim(w.claim,w.personId,w.requestId,w.acceptedAt))throw bad(); // Never recapture from a restored snapshot that predates acceptance.
}
interface End {sequence:number;requestId:string;completedAt:number}
async function finishReceipt(env:Env,e:End){
 if(!Number.isSafeInteger(e.completedAt)||e.completedAt<=0||!uuid.test(e.requestId))throw bad();
 await snapshot(env,prefix+'completed/'+e.requestId,async()=>({sequence:e.sequence,completedAt:e.completedAt}));
}
async function requireReportSeal(env:Env,w:Work){
 const row=await env.DB.prepare('SELECT 1 FROM group_identity_report_seals WHERE request_id=? AND nonce=?').bind(w.requestId,w.nonce).first();
 if(!row)throw bad();
}
async function finalize(env:Env,w:Work){
 const bucket=media(env),k=workKey(w.sequence);
 const current=await bucket.get(k);if(!current)throw bad();
 const v=await current.json<Work|End>();
 if('completedAt' in v){await finishReceipt(env,v);return;}
 validateWork(v,w.sequence);if(v.requestId!==w.requestId)throw bad();
 await clearIdentityReportErasure(env,w,w.personId);
 await env.DB.prepare('DELETE FROM group_identity_deletion_acceptance WHERE request_id=? AND nonce=?').bind(w.requestId,w.nonce).run();
 const end:End={sequence:w.sequence,requestId:w.requestId,completedAt:Math.floor(Date.now()/1000)};
 // Permanently erase the scratch manifest, without reopening the slot to a
 // delayed writer still using an earlier checkpoint. A crash here is resumable.
 if(!await bucket.put(k,JSON.stringify(end),{onlyIf:{etagMatches:current.etag}}))throw bad();
 await finishReceipt(env,end);
}
const intentKey=(nonce:string)=>prefix+'preparing/'+nonce;
async function publishSealed(env:Env,work:Work,control:Awaited<ReturnType<typeof tip>>){
 validateWork(work,control.sequence+1);await source(env,work);await requireReportSeal(env,work);
 const bucket=media(env),slot=await snapshot(env,workKey(work.sequence),async()=>work);
 if(slot.nonce!==work.nonce||slot.requestId!==work.requestId)throw bad();
 await persistIdentityClaim(bucket,work.claim);
 if(!await bucket.put(prefix+'control',JSON.stringify({sequence:work.sequence,requestId:work.requestId}),{onlyIf:{etagMatches:control.etag}})
    && !same(await tip(env),work))throw bad();
 await bucket.delete(intentKey(work.nonce));
}
// All steps are retryable. Cron and authenticated status checks can resume
// immediately; no report retention timer forms part of this state machine.
export async function advanceIdentityDeletion(env:Env) {
 if(!deletionRequired(env))return;
 const control=await tip(env),applied=await cursor(env),bucket=media(env);
 if(same(control,applied)) {
   if(control.sequence){
     const previous=await record<Work|End>(env,workKey(control.sequence));
     if(!previous || previous.requestId!==control.requestId || previous.sequence!==control.sequence)throw bad();
     if('completedAt' in previous) await finishReceipt(env,previous);
     else {validateWork(previous,control.sequence);if(previous.requestId!==control.requestId)throw bad();await finalize(env,previous);}
   }
   // A pre-seal crash never occupies the global slot or publishes a
   // processing receipt. Once its atomic seal exists, cron can publish it
   // from the original manifest without making a new deletion decision.
   let next=await record<Work>(env,workKey(control.sequence+1));
   if(!next){
     const pending=await env.DB.prepare(`SELECT a.nonce FROM group_identity_deletion_acceptance a
       JOIN group_identity_report_seals s ON s.request_id=a.request_id AND s.nonce=a.nonce LIMIT 1`).first<{nonce:string}>();
     if(pending){next=await record<Work>(env,intentKey(pending.nonce));if(!next)throw bad();}
   }
   if(next){await publishSealed(env,next,control);return advanceIdentityDeletion(env);}
   const expired=await env.DB.prepare(`DELETE FROM group_identity_deletion_acceptance
     WHERE accepted_at<unixepoch()-600 AND NOT EXISTS(SELECT 1 FROM group_identity_report_seals s
       WHERE s.request_id=group_identity_deletion_acceptance.request_id AND s.nonce=group_identity_deletion_acceptance.nonce)
     RETURNING nonce`).all<{nonce:string}>();
   for(const a of expired.results)await bucket.delete(intentKey(a.nonce));
   // Covers a restore which removed an abandoned preparation row. Only one
   // preparing request is admitted. Never remove a live or sealed request.
   const loose=await bucket.list({prefix:prefix+'preparing/',limit:32});
   for(const obj of loose.objects)if(obj.uploaded.getTime()<Date.now()-600_000){
     const nonce=obj.key.slice((prefix+'preparing/').length);
     if(uuid.test(nonce)&&!await env.DB.prepare('SELECT 1 FROM group_identity_deletion_acceptance WHERE nonce=?').bind(nonce).first())
       await bucket.delete(obj.key);
   }
   return;
 }
 if(control.sequence!==applied.sequence+1 || await record(env,prefix+'completed/'+control.requestId))throw bad();
 const work=await record<Work>(env,workKey(control.sequence));if(!work || work.requestId!==control.requestId)throw bad();
 validateWork(work,control.sequence);await source(env,work);
 const progress=await env.DB.prepare('SELECT data_erased,head_cursor FROM group_identity_deletion_acceptance WHERE request_id=? AND nonce=?')
   .bind(work.requestId,work.nonce).first<{data_erased:number;head_cursor:number}>();if(!progress)throw bad();
 if(!progress.data_erased) {
   if(Math.floor(Date.now()/1000)<work.acceptedAt+86400){
     const statements=deletedDeliveryStatements(env.DB,work.markers,work.sequence,work.acceptedAt);
     for(let i=0;i<statements.length;i+=50)await env.DB.batch(statements.slice(i,i+50));
   }
   await installReportManifest(env,work,work.personId,work.reports);
   await runIdentityReportErasure(env,work,work.personId);
   const sliceEnds=Date.now()+15_000;
   for(let n=0;;n++){
     if(!(await eraseGroupIdentityData(env,work)).morePhotos)break;
     if(n>=7||Date.now()>=sliceEnds)return;
   }
   await env.DB.prepare('UPDATE group_identity_deletion_acceptance SET data_erased=1 WHERE request_id=? AND nonce=?')
     .bind(work.requestId,work.nonce).run();
 }
 // Persist progress: a large collection must not re-read the same first page
 // on every cron invocation if the runtime's subrequest budget is exhausted.
 const end=Math.min(work.photos.length,progress.head_cursor+16);
 for(let i=progress.head_cursor;i<end;i+=8){
   const objects=work.photos.slice(i,Math.min(end,i+8)).flatMap(p=>[p.objectKey,p.objectKey+'.caption']);
   if((await Promise.all(objects.map(k=>bucket.head(k)))).some(Boolean))throw bad();
 }
 await env.DB.prepare('UPDATE group_identity_deletion_acceptance SET head_cursor=MAX(head_cursor,?) WHERE request_id=? AND nonce=?')
   .bind(end,work.requestId,work.nonce).run();
 if(end<work.photos.length)return;
 await env.DB.prepare('UPDATE group_identity_deletion_checkpoint SET sequence=?,request_id=? WHERE singleton=1 AND sequence=? AND request_id=?')
    .bind(work.sequence,work.requestId,applied.sequence,applied.requestId).run();
 if(!same(await cursor(env),work))throw bad();
 await finalize(env,work);
}
export async function identityDeletionAPI(request:Request,env:Env,ctx?:ExecutionContext):Promise<Response>{
 if(!deletionRequired(env))throw missing();
 const url=new URL(request.url);rejectQuery(url);
 const nudge=()=>{if(ctx)ctx.waitUntil(advanceIdentityDeletion(env));};
 if(request.method==='GET' && url.pathname.startsWith(path+'/') && url.pathname.endsWith('/status')){
   const id=url.pathname.slice(path.length+1,-7),auth=request.headers.get('Authorization');
   if(!uuid.test(id)||!auth?.startsWith('Bearer '))throw missing();
   if((await readBody(request,0)).length)throw new ApiError(400,'invalid_request','Invalid request.');
   const result=await receiptResult(env,id,auth.slice(7));if(result.state==='processing')nudge();return jsonResponse(result);
 }
 if(request.method!=='POST'||url.pathname!==path)throw missing();
 const {actor,body}=await authenticateGroupRequest(request,env,1024);
 const data=parseJsonBody(request,body);exactKeys(data,['operationId','receipt']);
 const id=data.operationId,receipt=data.receipt;
 if(typeof id!=='string'||!uuid.test(id)||typeof receipt!=='string'||receipt.length!==43)throw new ApiError(400,'invalid_request','Invalid deletion request.');
 base64urlDecode(receipt,32);
 const claim=await prepareIdentityClaim(media(env),actor.personId,id,receipt,actor.requestHash,actor.now);
 await advanceIdentityDeletion(env);
 const control=await tip(env),applied=await cursor(env);
 const prior=await media(env).head(prefix+'requests/'+id);
 if(prior){
   const status=await receiptResult(env,id,receipt);nudge();return jsonResponse({protocolVersion:3,requestId:id,state:'processing',acceptedAt:status.acceptedAt,completedAt:null},202);
 }
 if(!same(control,applied))throw bad();
 const nonce=crypto.randomUUID();
 await env.DB.prepare('INSERT INTO group_identity_deletion_acceptance(request_id,subject_id,nonce,request_hash,accepted_at) VALUES (?,?,?,?,?) ON CONFLICT(request_id) DO NOTHING')
 .bind(id,actor.personId,nonce,actor.requestHash,claim.acceptedAt).run();
 const anchor=await env.DB.prepare('SELECT nonce,accepted_at FROM group_identity_deletion_acceptance WHERE request_id=? AND subject_id=? AND request_hash=?')
 .bind(id,actor.personId,actor.requestHash).first<{nonce:string;accepted_at:number}>();
 if(!anchor)throw new ApiError(409,'idempotency_conflict','The deletion request has different content.');
 const proof=anchor.nonce;claim.acceptedAt=anchor.accepted_at;
 const [markers,reports,photos]=await protectedGroupRead(env,()=>Promise.all([
   captureDeletedDeliveries(env.DB,actor.personId,control.sequence+1,claim.acceptedAt),
   prepareReportManifest(env,{requestId:id,acceptedAt:claim.acceptedAt},actor.personId),
   prepareIdentityErasurePhotos(env,actor.personId),
 ]));
 const work:Work={requestId:id,personId:actor.personId,acceptedAt:claim.acceptedAt,sequence:control.sequence+1,nonce:proof,claim,markers,reports,photos};
 if(Date.now()/1000-claim.acceptedAt>=300 || JSON.stringify(work).length>15*1024*1024)throw bad();
 // The R2 intent is per nonce; a failed pre-acceptance request cannot
 // permanently occupy the globally ordered journal or revoke someone's key.
 const winner=await media(env).put(intentKey(proof),JSON.stringify(work),{onlyIf:{etagDoesNotMatch:'*'}});
 if(winner){
   await sealIdentityReportAcceptance(env,work,work.personId,work.claim.requestHash,work.reports);
 }else{
   // Never replay the erasure transaction from a restored pre-stop snapshot.
   await requireReportSeal(env,work);
 }
 const frozen=await record<Work>(env,intentKey(proof));if(!frozen||frozen.claim.requestHash!==actor.requestHash)throw bad();
 await publishSealed(env,frozen,control);
 nudge();
 return jsonResponse({protocolVersion:3,requestId:id,state:'processing',acceptedAt:claim.acceptedAt,completedAt:null},202);
}
