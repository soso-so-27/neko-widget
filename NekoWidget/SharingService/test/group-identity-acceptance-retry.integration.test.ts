import {it,expect} from 'vitest';
import {testEnv,db,person,signed,send} from './group-fixture';
import {randomBase64url} from '../src/encoding';
import {advanceIdentityDeletion} from '../src/group-identity-service';
const endpoint='/v3/group-identities/deletion-requests';
it('abandons a pre-seal failure without blocking another request, and recovers a sealed lost response',async()=>{
 const env={...testEnv,GROUP_IDENTITY_ERASURE_ENABLED:'YES'};
 const prefix='group-identity-deletions/v1/';
 await env.MEDIA!.put(prefix+'control',JSON.stringify({sequence:0,requestId:''}));
 const a=await person(),b=await person();
 const abandoned={operationId:crypto.randomUUID(),receipt:randomBase64url(32)};
 await db.prepare("CREATE TRIGGER synthetic_abort_delete BEFORE INSERT ON group_identity_report_seals BEGIN SELECT RAISE(ABORT,'synthetic abort'); END").run();
 try {expect((await send(await signed(a,endpoint,abandoned),env)).status).toBe(503);}
 finally {await db.prepare('DROP TRIGGER synthetic_abort_delete').run();}
 expect(await env.MEDIA!.head(prefix+'work/1')).toBeNull();
 expect(await env.MEDIA!.head(prefix+'requests/'+abandoned.operationId)).toBeNull();
 await db.prepare('UPDATE group_identity_deletion_acceptance SET accepted_at=unixepoch()-601 WHERE request_id=?').bind(abandoned.operationId).run();
 await advanceIdentityDeletion(env);
 expect(await db.prepare('SELECT 1 FROM group_identity_deletion_acceptance WHERE request_id=?').bind(abandoned.operationId).first()).toBeNull();
 expect((await env.MEDIA!.list({prefix:prefix+'preparing/'})).objects).toHaveLength(0);
 const payload={operationId:crypto.randomUUID(),receipt:randomBase64url(32)};
 const cut=new Proxy(env.MEDIA!,{get(target,property){
   if(property==='put')return async (...args:Parameters<R2Bucket['put']>)=>{
     if(args[0]===prefix+'control')throw Error('synthetic lost publication');return target.put(...args);
   };
   const x=Reflect.get(target,property);return typeof x==='function'?x.bind(target):x;
 }});
 expect((await send(await signed(b,endpoint,payload),{...env,MEDIA:cut})).status).toBe(503);
 expect(await db.prepare('SELECT 1 FROM group_identity_report_seals WHERE request_id=?').bind(payload.operationId).first()).not.toBeNull();
 await advanceIdentityDeletion(env);
 const status=await send(new Request('https://example.com'+endpoint+'/'+payload.operationId+'/status',{headers:{Authorization:'Bearer '+payload.receipt}}),env);
 expect(status.data).toMatchObject({state:'completed',requestId:payload.operationId});
 expect(await db.prepare('SELECT state FROM group_people WHERE id=?').bind(a.id).first('state')).toBe('active');
 expect(await db.prepare('SELECT state FROM group_people WHERE id=?').bind(b.id).first('state')).toBe('revoked');
});
