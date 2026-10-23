import { describe,expect,it } from 'vitest';
import { plusOwner,pauseOwner } from './group-billing-fixture';
import { base64urlDecode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupFields } from '../src/group-protocol';
import { groupHeartTranscript } from '../src/group-hearts';
import { cleanupExpiredGroupPush,drainGroupNotifications } from '../src/group-push';
import { apply,call,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person } from './group-fixture';
import type { Env } from '../src/env';

type Window=Awaited<ReturnType<typeof create>>;
async function setup() {
  const owner=await plusOwner(),bob=await person();let w=await create(owner);
  const invited=await invitation(owner,w),joined=await apply(bob,w,invited);ok(joined.response,201);
  const approved=await transition(owner,w,'admit',joined.id,[...w.roster.members,joined.member]);ok(approved.response);w=approved.next;
  const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
  const raw=new Uint8Array(await crypto.subtle.exportKey('pkcs8',keys.privateKey));
  const pem=`-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...raw))}\n-----END PRIVATE KEY-----`;
  const settings:Env={...testEnv,GROUP_APNS_RUNTIME_ENABLED:'YES',APNS_RUNTIME_ENABLED:'YES',
    APNS_PROVIDER_CREDENTIAL_JSON:JSON.stringify({keyId:'A1B2C3D4E5',teamId:'Z9Y8X7W6V5',bundleId:'jp.nekowidget.app',environment:'production',privateKey:pem}),
    APNS_TOKEN_KEYRING_JSON:JSON.stringify({current:'test',keys:{test:randomBase64url(32)}})};
  return {owner,bob,w,settings};
}
async function register(p:Person,w:Window,settings:Env,token=randomBase64url(32),remove=false) {
  const path=`/v3/group-windows/${w.windowId}/push-subscription${remove?'/remove':''}`;
  const body=remove?{operationId:crypto.randomUUID()}:{operationId:crypto.randomUUID(),token,environment:'production'};
  const result=await send(await signed(p,path,body),settings);return {token,result};
}
async function photo(owner:Person,w:Window,settings:Env) {
  const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
  const pid=w.roster.members.find(m=>m.personId===owner.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),pid,owner.deviceId,String(bytes.length)]);
  const body={operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,ciphertextSize:bytes.length,
    ciphertextSHA256:hash,senderSignature:await sign(owner.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),kind:'photo'};
  const r=ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/reserve`,body),settings),201),id=r.momentId as string;
  ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/${id}/ciphertext`,bytes,randomBase64url(16),'PUT'),settings));
  ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/${id}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,
    keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}),settings));return id;
}
async function heart(p:Person,w:Window,id:string,settings:Env,active=true) {
  const operationId=crypto.randomUUID(),participantId=w.roster.members.find(m=>m.personId===p.id)!.participantId;
  const body={operationId,active,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    reactorSignature:await sign(p.signing.privateKey,groupHeartTranscript({windowId:w.windowId,momentId:id,participantId,deviceId:p.deviceId,
      active,operationId,keyEpoch:w.roster.keyEpoch,rosterHash:w.hash}))};
  ok(await send(await signed(p,`/v3/group-windows/${w.windowId}/moments/${id}/hearts`,body),settings));
}
async function apnsGate(active:boolean) {
  await db.prepare('UPDATE personal_staging_runtime_gate SET generation=generation+1,apns_enabled=?,updated_at=unixepoch() WHERE singleton=1').bind(active?1:0).run();
}
const noNetwork:typeof fetch=async()=>{throw new Error('Unexpected APNs request');};
describe('group-only push registration and just-before-send eligibility',()=>{
  it('encrypts physical tokens and sends only a generic payload plus an opaque window route',async()=>{
    const {owner,bob,w,settings}=await setup(),r=await register(bob,w,settings);ok(r.result);
    const stored=await db.prepare('SELECT * FROM group_push_subscriptions WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first();
    expect(JSON.stringify(stored)).not.toContain(r.token);
    const id=await photo(owner,w,settings);await pauseOwner(owner);
    let sent=0;const transport:typeof fetch=async(url,init)=>{
      sent++;expect(String(url)).toMatch(/^https:\/\/api.push.apple.com\/3\/device\/[0-9a-f]{64}$/);
      expect(init!.headers).toMatchObject({'apns-topic':'jp.nekowidget.app','apns-push-type':'alert'});
      expect(JSON.parse(init!.body as string)).toEqual({aps:{alert:{title:'ねこのまど',body:'新しい一枚が届きました。'},'content-available':1,'mutable-content':1},
        neko:{v:3,kind:'moment',windowId:w.windowId}});
      expect(init!.body).not.toContain(id);return new Response(null,{status:200});
    };
    expect((await drainGroupNotifications(settings,undefined,transport)).accepted).toBe(1);expect(sent).toBe(1);
    expect((await drainGroupNotifications(settings,undefined,noNetwork)).leased).toBe(0);
  });
  it('retains subscription generations across removal, rejects old queues and clears expired tokens',async()=>{
    const {owner,bob,w,settings}=await setup(),r=await register(bob,w,settings);ok(r.result);
    await photo(owner,w,settings);ok((await register(bob,w,settings,r.token)).result);
    const generation=async()=> (await db.prepare('SELECT generation FROM group_push_subscriptions WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first<{generation:number}>())!.generation;
    expect(await generation()).toBe(1);
    ok((await register(bob,w,{...settings,GROUP_APNS_RUNTIME_ENABLED:'NO'},r.token,true)).result);
    expect(await generation()).toBe(2);ok((await register(bob,w,settings,r.token)).result);expect(await generation()).toBe(3);
    expect((await drainGroupNotifications(settings,undefined,noNetwork)).skipped).toBe(1);
    await cleanupExpiredGroupPush(settings,Math.floor(Date.now()/1000)+36*86400);
    const row=await db.prepare('SELECT token_ciphertext,token_nonce,token_digest,generation FROM group_push_subscriptions WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first();
    expect(row).toEqual({token_ciphertext:'',token_nonce:'',token_digest:'',generation:3});
  });
  it.each(['block','left','new-token','delivery-expired','new-roster','actor-revoked','window-closed','gate'] as const)(
    'rechecks %s after token decryption and makes no APNs request',async(reason)=>{
      const {owner,bob,w,settings}=await setup();ok((await register(bob,w,settings)).result);const id=await photo(owner,w,settings);
      const change=async()=>{
        if(reason==='block')ok(await call(bob,`/v3/group-windows/${w.windowId}/blocks/${w.roster.members[0]!.participantId}`,{operationId:crypto.randomUUID(),active:true}));
        if(reason==='left') {
          const op=crypto.randomUUID();ok(await call(bob,`/v3/group-windows/${w.windowId}/leave`,{operationId:op,expectedRevision:w.roster.revision,
            selfSignature:await sign(bob.signing.privateKey,groupFields(['NW3.LEAVE',w.windowId,w.roster.members[1]!.participantId,String(w.roster.revision),op]))}));
        }
        if(reason==='new-token')ok((await register(bob,w,settings)).result);
        if(reason==='delivery-expired')await db.prepare('UPDATE group_moment_deliveries SET access_expires_at=unixepoch()-1 WHERE moment_id=? AND device_id=?').bind(id,bob.deviceId).run();
        if(reason==='new-roster')await db.prepare('UPDATE group_window_devices SET added_revision=? WHERE space_id=? AND device_id=?').bind(w.roster.revision+1,w.windowId,bob.deviceId).run();
        if(reason==='actor-revoked')await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(owner.deviceId).run();
        if(reason==='window-closed')await db.prepare("UPDATE group_windows SET mode='closed' WHERE space_id=?").bind(w.windowId).run();
        if(reason==='gate')await apnsGate(false);
      };
      try { expect((await drainGroupNotifications(settings,undefined,noNetwork,{beforeSend:change})).skipped).toBe(1); }
      finally { if(reason==='gate')await apnsGate(true); }
    });
  it('suppresses a cancelled heart and binds a re-added heart to its new operation',async()=>{
    const {owner,bob,w,settings}=await setup(),id=await photo(owner,w,settings);ok((await register(owner,w,settings)).result);
    await heart(bob,w,id,settings);await heart(bob,w,id,settings,false);await heart(bob,w,id,settings);
    let sent=0;const transport:typeof fetch=async(_url,init)=>{sent++;expect(JSON.parse(init!.body as string).neko.kind).toBe('heart');return new Response(null,{status:200});};
    const result=await drainGroupNotifications(settings,undefined,transport);
    expect(result.accepted).toBe(1);expect(result.skipped).toBe(1);expect(sent).toBe(1);
  });
  it('retries transient failure and does not invalidate a newer token after an old 410 response',async()=>{
    const {owner,bob,w,settings}=await setup();ok((await register(bob,w,settings)).result);await photo(owner,w,settings);
    const now=Math.floor(Date.now()/1000),unavailable:typeof fetch=async()=>new Response('{}',{status:429});
    expect((await drainGroupNotifications(settings,now,unavailable)).retried).toBe(1);
    const invalid:typeof fetch=async()=>{ok((await register(bob,w,settings)).result);return new Response('{"reason":"Unregistered"}',{status:410});};
    expect((await drainGroupNotifications(settings,now+31,invalid)).invalidated).toBe(1);
    expect((await db.prepare('SELECT expires_at FROM group_push_subscriptions WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first<{expires_at:number}>())!.expires_at).toBeGreaterThan(now);
  });
  it('keeps the new opt-in OFF without reading group push schema or using provider secrets',async()=>{
    const inaccessible=new Proxy(db,{get(){throw new Error('No schema access when disabled');}});
    expect((await drainGroupNotifications({...testEnv,DB:inaccessible},undefined,noNetwork)).leased).toBe(0);
    const {bob,w,settings}=await setup();expect((await register(bob,w,{...settings,GROUP_APNS_RUNTIME_ENABLED:'NO'})).result.status).toBe(503);
  });
  it('does not replay a rejected registration after gates reopen or keep another identity on the same physical token',async()=>{
    const {owner,bob,w,settings}=await setup(),token=randomBase64url(32),path=`/v3/group-windows/${w.windowId}/push-subscription`;
    const body={operationId:crypto.randomUUID(),token,environment:'production'},request=await signed(bob,path,body);
    const copy=await signed(bob,path,body,request.headers.get('neko-nonce')!);
    expect((await send(request,{...settings,GROUP_APNS_RUNTIME_ENABLED:'NO'})).status).toBe(503);
    expect((await send(copy,settings)).data.error.code).toBe('replay');
    ok((await register(bob,w,settings,token)).result);await photo(owner,w,settings);
    const charlie=await person(),invite=await invitation(owner,w),joined=await apply(charlie,w,invite);ok(joined.response,201);
    const admitted=await transition(owner,w,'admit',joined.id,[...w.roster.members,joined.member]);ok(admitted.response);
    ok((await register(charlie,admitted.next,settings,token)).result);
    expect((await drainGroupNotifications(settings,undefined,noNetwork)).skipped).toBe(1);
    expect((await db.prepare('SELECT expires_at FROM group_push_subscriptions WHERE space_id=? AND device_id=?').bind(w.windowId,bob.deviceId).first<{expires_at:number}>())?.expires_at).toBe(0);
  });
});
