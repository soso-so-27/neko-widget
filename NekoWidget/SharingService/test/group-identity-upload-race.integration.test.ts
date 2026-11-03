import {it,expect} from 'vitest';
import type {Env} from '../src/env';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {groupFields} from '../src/group-protocol';
import {groupCaptionTranscript} from '../src/group-captions';
import {advanceIdentityDeletion} from '../src/group-identity-service';
import {plusOwner} from './group-billing-fixture';
import {apply,create,db,invitation,ok,send,sign,signed,testEnv,transition,type Person} from './group-fixture';

type Window=Awaited<ReturnType<typeof create>>;
const env={...testEnv,GROUP_IDENTITY_ERASURE_ENABLED:'YES',GROUP_REPORT_RUNTIME_ENABLED:'YES',
 GROUP_MODERATION_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES'};
const root='/v3/group-identities/deletion-requests';
const call=async(p:Person,path:string,body:unknown,e:Env=env,verb='POST')=>
 send(await signed(p,path,body,randomBase64url(16),verb),e);
async function reserve(sender:Person,w:Window){
 const bytes=crypto.getRandomValues(new Uint8Array(48)),caption=crypto.getRandomValues(new Uint8Array(60));
 const hash=await sha256Base64url(bytes),captionHash=await sha256Base64url(caption),client=randomBase64url(16);
 const pid=w.roster.members.find(m=>m.personId===sender.id)!.participantId;
 const aad=groupFields(['NW3.PHOTO',w.windowId,client,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),pid,sender.deviceId,String(bytes.length)]);
 const base='/v3/group-windows/'+w.windowId+'/moments';
 const res=await call(sender,base+'/reserve',{operationId:crypto.randomUUID(),clientMomentId:client,keyEpoch:w.roster.keyEpoch,
  rosterRevision:w.roster.revision,ciphertextSize:bytes.length,ciphertextSHA256:hash,kind:'photo',
  senderSignature:await sign(sender.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),
  caption:{ciphertextSize:caption.length,ciphertextSHA256:captionHash,senderSignature:await sign(sender.signing.privateKey,
    groupCaptionTranscript({windowId:w.windowId,clientMomentId:client,keyEpoch:w.roster.keyEpoch,rosterHash:w.hash,participantId:pid,
      deviceId:sender.deviceId,photoHash:hash,size:caption.length,hash:captionHash}))}});
 const id=ok(res,201).momentId as string;
 return {id,bytes,caption,hash,path:base+'/'+id,key:'groups/v3/'+w.windowId+'/'+id+'/'+hash};
}
function latch(){let open!:()=>void;const promise=new Promise<void>(resolve=>{open=resolve;});return {promise,open};}
type Pause={stage:'after-placeholder'|'before-bytes';reached:ReturnType<typeof latch>;cas:number;rejectedCAS:number;placeholderETag?:string};
// Intercept the ordering only. Both placeholder and final CAS execute against
// the same real local R2 bucket, with the exact options supplied by the Worker.
function intercept(bucket:R2Bucket,pauses:Map<string,Pause>,resume:ReturnType<typeof latch>):R2Bucket {
 return new Proxy(bucket,{get(target,prop){
   if(prop==='put')return async(key:string,data:Parameters<R2Bucket['put']>[1],options:R2PutOptions={})=>{
     const p=pauses.get(key);
     if(!p)return target.put(key,data,options);
     if(options.customMetadata?.scope==='neko-upload-reservation-v1'){
       const result=await target.put(key,data,options);
       expect(result).not.toBeNull();p.placeholderETag=result!.etag;
       if(p.stage==='after-placeholder'){p.reached.open();await resume.promise;}
       return result;
     }
     expect(options.onlyIf).toEqual({etagMatches:p.placeholderETag});
     p.cas++;
     if(p.stage==='before-bytes'){p.reached.open();await resume.promise;}
     const result=await target.put(key,data,options);
     if(!result)p.rejectedCAS++;
     return result;
   };
   const v=Reflect.get(target,prop);return typeof v==='function'?v.bind(target):v;
 }});
}
it('does not recreate photo, caption or report bytes when signed deletion completes during three signed uploads',async()=>{
 await env.MEDIA!.put('group-identity-deletions/v1/control',JSON.stringify({sequence:0,requestId:''}));
 const owner=await plusOwner(),other=await plusOwner(),w=await create(owner);
 let otherWindow=await create(other);
 const joined=await apply(owner,otherWindow,await invitation(other,otherWindow));ok(joined.response,201);
 const admitted=await transition(other,otherWindow,'admit',joined.id,[...otherWindow.roster.members,joined.member]);
 ok(admitted.response);otherWindow=admitted.next;
 const unrelated=await reserve(other,otherWindow);
 ok(await call(other,unrelated.path+'/ciphertext',unrelated.bytes,env,'PUT'));
 ok(await call(other,unrelated.path+'/caption-ciphertext',unrelated.caption,env,'PUT'));
 ok(await call(other,unrelated.path+'/commit',{operationId:crypto.randomUUID(),expectedRevision:otherWindow.roster.revision,
  keyEpoch:otherWindow.roster.keyEpoch,ciphertextSHA256:unrelated.hash}));
 const unrelatedBefore=await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(unrelated.id).first();
 const original=await reserve(owner,w),reportBytes=crypto.getRandomValues(new Uint8Array(81));
 const reports='/v3/group-windows/'+otherWindow.windowId+'/reports';
 const reservation=ok(await call(owner,reports+'/reserve',{operationId:crypto.randomUUID(),momentId:unrelated.id,reasonCode:'privacy',
  moderationKeyId:'moderation-v2',ciphertextSize:reportBytes.length,ciphertextSHA256:await sha256Base64url(reportBytes),
  reporterConsent:{version:1,acceptedAt:Math.floor(Date.now()/1000)}}),201);
 const reportId=reservation.report.id as string;
 const reportKey=await db.prepare('SELECT object_key FROM group_reports WHERE id=?').bind(reportId).first<string>('object_key');
 expect(reportKey).toBeTruthy();
 const pauses=new Map<string,Pause>([original.key,original.key+'.caption',reportKey!].map((key,i)=>
  [key,{stage:i===0?'after-placeholder':'before-bytes',reached:latch(),cas:0,rejectedCAS:0}]));
 const resume=latch(),racing={...env,MEDIA:intercept(env.MEDIA!,pauses,resume),MODERATION_MEDIA:intercept(env.MODERATION_MEDIA!,pauses,resume)};
 const writes=[
   call(owner,original.path+'/ciphertext',original.bytes,racing,'PUT'),
   call(owner,original.path+'/caption-ciphertext',original.caption,racing,'PUT'),
   call(owner,reports+'/'+reportId+'/ciphertext',reportBytes,racing,'PUT'),
 ];
 try {
   for(const [i,p] of [...pauses.values()].entries()){
     await Promise.race([p.reached.promise,writes[i]!.then(r=>{throw new Error('upload stopped before reservation: '+JSON.stringify(r));})]);
   }
   for(const [key,p] of pauses){
     const bucket=key===reportKey?env.MODERATION_MEDIA!:env.MEDIA!;
     expect((await bucket.head(key))?.etag).toBe(p.placeholderETag);
     expect((await bucket.head(key))?.customMetadata?.scope).toBe('neko-upload-reservation-v1');
   }
   const id=crypto.randomUUID(),receipt=randomBase64url(32);
   const accepted=await call(owner,root,{operationId:id,receipt});
   expect(accepted).toMatchObject({status:202,data:{state:'processing',requestId:id}});
   await advanceIdentityDeletion(env);
   const status=await send(new Request('https://group.invalid'+root+'/'+id+'/status',{headers:{Authorization:'Bearer '+receipt}}),env);
   expect(status).toMatchObject({status:200,data:{state:'completed',requestId:id}});
   expect(await env.MEDIA!.head(original.key)).toBeNull();
   expect(await env.MEDIA!.head(original.key+'.caption')).toBeNull();
   expect(await env.MODERATION_MEDIA!.head(reportKey!)).toBeNull();
 }finally{resume.open();}
 const results=await Promise.all(writes);
 for(const result of results)expect(result.status).toBeGreaterThanOrEqual(400);
 expect(pauses.get(original.key)?.cas).toBe(0);
 for(const k of [original.key+'.caption',reportKey!])expect(pauses.get(k)).toMatchObject({cas:1,rejectedCAS:1});
 expect(await env.MEDIA!.head(original.key)).toBeNull();expect(await env.MEDIA!.head(original.key+'.caption')).toBeNull();
 expect(await env.MODERATION_MEDIA!.head(reportKey!)).toBeNull();
 expect(await db.prepare('SELECT 1 FROM group_moments WHERE id=?').bind(original.id).first()).toBeNull();
 expect(await db.prepare('SELECT 1 FROM group_reports WHERE id=?').bind(reportId).first()).toBeNull();
 expect(await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(unrelated.id).first()).toEqual(unrelatedBefore);
 expect(new Uint8Array(await (await env.MEDIA!.get(unrelated.key))!.arrayBuffer())).toEqual(unrelated.bytes);
 expect(new Uint8Array(await (await env.MEDIA!.get(unrelated.key+'.caption'))!.arrayBuffer())).toEqual(unrelated.caption);
},30000);
