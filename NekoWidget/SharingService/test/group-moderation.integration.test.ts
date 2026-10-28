import { describe,expect,it } from 'vitest';
import type { Env } from '../src/env';
import { base64urlDecode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupFields } from '../src/group-protocol';
import { route } from '../src/index';
import { errorResponse } from '../src/errors';
import { drainGroupNotifications } from '../src/group-push';
import { groupModerationChecks,groupModerationPredicate,requireGroupMediaAllowed } from '../src/group-moderation';
import { plusOwner } from './group-billing-fixture';
import { apply,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person } from './group-fixture';

const enabled:Env={...testEnv,GROUP_MODERATION_RUNTIME_ENABLED:'YES'};
type Window=Awaited<ReturnType<typeof create>>;
type Target='window'|'person'|'photo';
async function family(owner?:Person,bob?:Person) {
  owner??=await plusOwner();bob??=await person();let w=await create(owner);
  const invite=await invitation(owner,w),joined=await apply(bob,w,invite);ok(joined.response,201);
  const accepted=await transition(owner,w,'admit',joined.id,[...w.roster.members,joined.member]);ok(accepted.response);w=accepted.next;
  return {owner,bob,w};
}
const base=(w:Window)=>`/v3/group-windows/${w.windowId}`;
async function request(p:Person,path:string,body?:unknown,settings:Env=enabled,method?:string) {
  return send(await signed(p,path,body,randomBase64url(16),method),settings);
}
async function reserve(p:Person,w:Window,settings:Env=enabled) {
  const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
  const participant=w.roster.members.find(m=>m.personId===p.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),participant,p.deviceId,String(bytes.length)]);
  const body={operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    ciphertextSize:bytes.length,ciphertextSHA256:hash,senderSignature:await sign(p.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),kind:'photo'};
  const result=await request(p,base(w)+'/moments/reserve',body,settings);
  return {id:result.data.momentId as string,bytes,hash,body,result};
}
type Photo=Awaited<ReturnType<typeof reserve>>;
const upload=(p:Person,w:Window,photo:Photo,settings=enabled)=>request(p,base(w)+`/moments/${photo.id}/ciphertext`,photo.bytes,settings,'PUT');
const commit=(p:Person,w:Window,photo:Photo,settings=enabled)=>request(p,base(w)+`/moments/${photo.id}/commit`,{
  operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,ciphertextSHA256:photo.hash},settings);
async function delivered(p:Person,w:Window,settings=enabled) {
  const photo=await reserve(p,w,settings);ok(photo.result,201);ok(await upload(p,w,photo,settings));ok(await commit(p,w,photo,settings));return photo;
}
async function download(p:Person,w:Window,id:string,settings=enabled) {
  try { return await route(await signed(p,base(w)+`/moments/${id}/ciphertext`),settings); }
  catch(error) { return errorResponse(error); }
}
async function restrict(w:Window,kind:Target,target:string,caseReference=crypto.randomUUID()) {
  const id=crypto.randomUUID();
  await db.prepare(`INSERT INTO group_moderation_restrictions
    (id,case_reference,space_id,target_kind,target_id,active,revision,created_at,updated_at) VALUES (?,?,?,?,?,1,1,unixepoch(),unixepoch())`)
    .bind(id,caseReference,w.windowId,kind,target).run();return id;
}
async function release(id:string) {
  await db.prepare('UPDATE group_moderation_restrictions SET active=0,revision=revision+1,updated_at=unixepoch() WHERE id=?').bind(id).run();
}
function mediaRace(settings:Env,operation:'get'|'put'|'head',change:()=>Promise<void>):Env {
  let changed=false;
  const media=new Proxy(settings.MEDIA!,{get(target,key) {
    const method=Reflect.get(target,key);if(typeof method!=='function')return method;
    return async(...args:unknown[])=>{const result=await method.apply(target,args);
      if(key===operation && !changed){changed=true;await change();}return result;};
  }});
  return {...settings,MEDIA:media};
}
async function pushSettings():Promise<Env> {
  const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
  const raw=new Uint8Array(await crypto.subtle.exportKey('pkcs8',pair.privateKey));
  const pem=`-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...raw))}\n-----END PRIVATE KEY-----`;
  return {...enabled,GROUP_APNS_RUNTIME_ENABLED:'YES',APNS_RUNTIME_ENABLED:'YES',
    APNS_PROVIDER_CREDENTIAL_JSON:JSON.stringify({keyId:'A1B2C3D4E5',teamId:'Z9Y8X7W6V5',bundleId:'jp.nekowidget.app',environment:'production',privateKey:pem}),
    APNS_TOKEN_KEYRING_JSON:JSON.stringify({current:'test',keys:{test:randomBase64url(32)}})};
}

describe('group moderation hides outgoing content in the reported window only',()=>{
  it('OFF never queries the new schema; ON with unavailable schema fails closed',async()=>{
    const unavailable={...enabled,DB:new Proxy(db,{get(target,key) {
      if(key==='prepare')return (sql:string)=>{if(sql.includes('group_moderation_'))throw new Error('no such table: group_moderation_checks');return target.prepare(sql);};
      const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
    }})};
    const off={...unavailable,GROUP_MODERATION_RUNTIME_ENABLED:'NO'},f=await family();
    expect(groupModerationChecks(off,{spaceId:f.w.windowId})).toEqual([]);
    expect(groupModerationPredicate(off,{space:'p.space_id',photo:'p.id'})).toBe('1');
    await requireGroupMediaAllowed(off,{spaceId:f.w.windowId});
    const photo=await delivered(f.owner,f.w,off);expect((await download(f.bob,f.w,photo.id,off)).status).toBe(200);
    expect(ok(await request(f.bob,base(f.w)+'/moments/list',{after:null,limit:20},off)).items).toHaveLength(1);
    await expect(requireGroupMediaAllowed(unavailable,{spaceId:f.w.windowId})).rejects.toThrow('no such table');
    expect((await download(f.bob,f.w,photo.id,unavailable)).status).toBe(500);
  });
  it.each(['window','person','photo'] as const)('enforces %s on existing media, retries, inventory and new reservations',async kind=>{
    const {owner,bob,w}=await family(),photo=await delivered(owner,w);
    const before=await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(photo.id).first();
    const id=await restrict(w,kind,kind==='window'?w.windowId:kind==='person'?owner.id:photo.id);
    expect((await request(bob,base(w)+`/moments/${photo.id}`)).status).toBe(404);
    expect((await download(bob,w,photo.id)).status).toBe(404);
    expect((await upload(owner,w,photo)).status).toBe(404);
    expect((await commit(owner,w,photo)).status).toBe(404);
    expect((await request(owner,base(w)+'/moments/reserve',photo.body)).status).toBe(404);
    const listed=await request(bob,base(w)+'/moments/list',{after:null,limit:20});
    if(kind==='window')expect(listed.status).toBe(404);else expect(ok(listed).items).toHaveLength(0);
    const fresh=await reserve(owner,w);expect(fresh.result.status).toBe(kind==='photo'?201:404);
    expect(await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(photo.id).first()).toEqual(before);
    await release(id);const restored=await download(bob,w,photo.id);
    expect(restored.status).toBe(200);expect(new Uint8Array(await restored.arrayBuffer())).toEqual(photo.bytes);
  });
  it('person restriction leaves other windows and incoming photos intact; target scope cannot be retargeted',async()=>{
    const {owner,bob,w}=await family(),other=await family(owner,bob);
    const here=await delivered(owner,w),there=await delivered(owner,other.w),incoming=await delivered(bob,w);
    const id=await restrict(w,'person',owner.id);
    expect((await download(bob,w,here.id)).status).toBe(404);
    expect((await download(bob,other.w,there.id)).status).toBe(200);
    expect((await download(owner,w,incoming.id)).status).toBe(200);
    expect((await reserve(owner,other.w)).result.status).toBe(201);
    expect(ok(await request(owner,base(w)+'/moments/list',{after:null,limit:20})).items.map((p:{id:string})=>p.id)).toEqual([incoming.id]);
    await expect(restrict(w,'photo',there.id)).rejects.toThrow('group_moderation_invalid_target');
    await expect(restrict(w,'window',other.w.windowId)).rejects.toThrow('group_moderation_invalid_target');
    await expect(db.prepare('UPDATE group_moderation_restrictions SET target_id=?,revision=revision+1 WHERE id=?').bind(bob.id,id).run()).rejects.toThrow('group_moderation_invalid_revision');
  });
  it('release is case-specific and cannot revive content still restricted by another case',async()=>{
    const {owner,bob,w}=await family(),photo=await delivered(owner,w);
    const first=await restrict(w,'photo',photo.id),second=await restrict(w,'photo',photo.id);
    await release(first);expect((await download(bob,w,photo.id)).status).toBe(404);
    await release(second);expect((await download(bob,w,photo.id)).status).toBe(200);
    expect((await db.prepare('SELECT active,revision FROM group_moderation_restrictions WHERE id IN (?,?)').bind(first,second).all()).results)
      .toEqual([{active:0,revision:2},{active:0,revision:2}]);
  });
  it.each(['get','put','head'] as const)('rechecks restriction after R2 %s without deleting original data',async operation=>{
    const {owner,bob,w}=await family(),photo=operation==='get'?await delivered(owner,w):await reserve(owner,w);ok(photo.result,201);
    if(operation==='head')ok(await upload(owner,w,photo));
    let restriction='';const raced=mediaRace(enabled,operation,async()=>{restriction=await restrict(w,'photo',photo.id);});
    const reply=operation==='get'?await download(bob,w,photo.id,raced):operation==='put'?await upload(owner,w,photo,raced):await commit(owner,w,photo,raced);
    expect(reply.status).toBe(404);
    const row=await db.prepare('SELECT state,object_key FROM group_moments WHERE id=?').bind(photo.id).first<{state:string;object_key:string}>();
    expect(row?.state).toBe(operation==='get'?'committed':operation==='put'?'reserved':'uploaded');
    expect(await enabled.MEDIA!.head(row!.object_key)).not.toBeNull();
    await release(restriction);
    if(operation==='put')ok(await upload(owner,w,photo));
    if(operation!=='get')ok(await commit(owner,w,photo));
    expect((await download(bob,w,photo.id)).status).toBe(200);
  });
  it.each(['window','person','photo'] as const)('rechecks %s immediately before APNs; another window remains eligible',async kind=>{
    const {owner,bob,w}=await family(),settings=await pushSettings();
    ok(await request(bob,base(w)+'/push-subscription',{operationId:crypto.randomUUID(),token:randomBase64url(32),environment:'production'},settings));
    const photo=await delivered(owner,w,settings);let sent=0;
    const transport:typeof fetch=async()=>{sent++;return new Response(null,{status:200});};
    const result=await drainGroupNotifications(settings,undefined,transport,{beforeSend:async()=>{
      await restrict(w,kind,kind==='window'?w.windowId:kind==='person'?owner.id:photo.id);
    }});
    expect(result.skipped).toBe(1);expect(sent).toBe(0);
    const other=await family(owner,bob);
    ok(await request(bob,base(other.w)+'/push-subscription',{operationId:crypto.randomUUID(),token:randomBase64url(32),environment:'production'},settings));
    await delivered(owner,other.w,settings);
    expect((await drainGroupNotifications(settings,undefined,transport)).accepted).toBe(1);expect(sent).toBe(1);
  });
  it('a restricted window still accepts a report and self-leave, while delivered local bytes remain untouched',async()=>{
    const {owner,bob,w}=await family(),photo=await delivered(owner,w);await restrict(w,'window',w.windowId);
    const evidence=crypto.getRandomValues(new Uint8Array(60));
    const report=await request(bob,base(w)+'/reports/reserve',{operationId:crypto.randomUUID(),momentId:photo.id,reasonCode:'privacy',
      moderationKeyId:'moderation-v2',ciphertextSize:evidence.length,ciphertextSHA256:await sha256Base64url(evidence),
      reporterConsent:{version:1,acceptedAt:Math.floor(Date.now()/1000)}},
      {...enabled,GROUP_REPORT_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES'});
    ok(report,201);
    const operationId=crypto.randomUUID(),participant=w.roster.members.find(m=>m.personId===bob.id)!.participantId;
    ok(await request(bob,base(w)+'/leave',{operationId,expectedRevision:w.roster.revision,
      selfSignature:await sign(bob.signing.privateKey,groupFields(['NW3.LEAVE',w.windowId,participant,String(w.roster.revision),operationId]))}));
    expect(photo.bytes.length).toBe(48);
  });
});
