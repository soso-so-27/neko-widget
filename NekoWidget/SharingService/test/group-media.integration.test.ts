import {plusOwner,pauseOwner} from './group-billing-fixture';
import {describe,expect,it} from 'vitest';
import {base64urlDecode,randomBase64url,sha256Base64url,verifyEd25519} from '../src/encoding';
import {groupFields} from '../src/group-protocol';
import {groupHeartTranscript} from '../src/group-hearts';
import {route} from '../src/index';
import {errorResponse} from '../src/errors';
import {cleanLateGroupUpload,runGroupRelayCleanup} from '../src/group-cleanup';
import {apply,call,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person} from './group-fixture';

type Window=Awaited<ReturnType<typeof create>>;
async function family() {
  const owner=await plusOwner(),bob=await person();let w=await create(owner);
  const invite=await invitation(owner,w),b=await apply(bob,w,invite);ok(b.response,201);
  const approved=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(approved.response);w=approved.next;
  return {owner,bob,w};
}
async function reserve(sender:Person,w:Window,size=48) {
  const bytes=crypto.getRandomValues(new Uint8Array(size)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
  const participantId=w.roster.members.find(m=>m.personId===sender.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),participantId,sender.deviceId,String(size)]);
  const body={operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    ciphertextSize:size,ciphertextSHA256:hash,senderSignature:await sign(sender.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),kind:'photo'};
  const result=await call(sender,`/v3/group-windows/${w.windowId}/moments/reserve`,body);
  return {result,bytes,body,id:result.data.momentId as string};
}
async function upload(sender:Person,w:Window,p:Awaited<ReturnType<typeof reserve>>,bytes=p.bytes) {
  return send(await signed(sender,`/v3/group-windows/${w.windowId}/moments/${p.id}/ciphertext`,bytes,randomBase64url(16),'PUT'));
}
async function commit(sender:Person,w:Window,p:Awaited<ReturnType<typeof reserve>>,operationId=crypto.randomUUID()) {
  return call(sender,`/v3/group-windows/${w.windowId}/moments/${p.id}/commit`,{operationId,expectedRevision:w.roster.revision,
    keyEpoch:w.roster.keyEpoch,ciphertextSHA256:p.body.ciphertextSHA256});
}
async function delivered(sender:Person,w:Window) {
  const p=await reserve(sender,w);ok(p.result,201);ok(await upload(sender,w,p));ok(await commit(sender,w,p));return p;
}
async function binary(p:Person,path:string) {
  try{return await route(await signed(p,path),testEnv);}catch(e){return errorResponse(e);}
}
async function heart(p:Person,w:Window,momentId:string,active=true) {
  const operationId=crypto.randomUUID(),participantId=w.roster.members.find(m=>m.personId===p.id)!.participantId;
  return {operationId,active,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    reactorSignature:await sign(p.signing.privateKey,groupHeartTranscript({windowId:w.windowId,momentId,participantId,deviceId:p.deviceId,
      active,operationId,keyEpoch:w.roster.keyEpoch,rosterHash:w.hash}))};
}
describe('group encrypted relay and creator Plus commit boundary (runtime stays OFF outside test)',()=>{
  it('returns signed hearts in the POST and checks current delivery even on receipt replay',async()=>{
    const {owner,bob,w}=await family(),p=await delivered(owner,w),path=`/v3/group-windows/${w.windowId}/moments/${p.id}/hearts`;
    const body=await heart(bob,w,p.id),reply=ok(await call(bob,path,body));
    const h=reply.moment.hearts[0];
    expect(reply.moment.id).toBe(p.id);
    expect(h).toMatchObject({reactorDeviceId:bob.deviceId,active:true,operationId:body.operationId});
    expect(await verifyEd25519(bob.signing.publicKey,h.reactorSignature,groupHeartTranscript({
      windowId:w.windowId,momentId:p.id,participantId:h.reactorParticipantId,deviceId:h.reactorDeviceId,
      active:h.active,operationId:h.operationId,keyEpoch:h.keyEpoch,rosterHash:h.rosterHash}))).toBe(true);
    const replay=ok(await call(bob,path,body));expect(replay.moment.hearts).toEqual(reply.moment.hearts);
    const ownerId=w.roster.members[0]!.participantId;
    ok(await call(bob,`/v3/group-windows/${w.windowId}/blocks/${ownerId}`,{operationId:crypto.randomUUID(),active:true}));
    expect((await call(bob,path,body)).status).not.toBe(200);
  });
  it('allows a rejected stale heart to be re-signed with the SAME operation ID, once committed it is immutable',async()=>{
    const {owner,bob,w}=await family(),p=await delivered(owner,w),path=`/v3/group-windows/${w.windowId}/moments/${p.id}/hearts`;
    const body=await heart(bob,w,p.id),rotated=await transition(owner,w,'rotate',w.windowId,w.roster.members);
    ok(rotated.response);
    expect((await call(bob,path,body)).data.error.code).toBe('stale_epoch');
    const next=rotated.next,participantId=next.roster.members.find(m=>m.personId===bob.id)!.participantId;
    const updated={...body,keyEpoch:next.roster.keyEpoch,rosterRevision:next.roster.revision,
      reactorSignature:await sign(bob.signing.privateKey,groupHeartTranscript({windowId:w.windowId,momentId:p.id,
        participantId,deviceId:bob.deviceId,active:true,operationId:body.operationId,keyEpoch:next.roster.keyEpoch,rosterHash:next.hash}))};
    expect(ok(await call(bob,path,updated)).moment.hearts[0].operationId).toBe(body.operationId);
    expect((await call(bob,path,body)).data.error.code).toBe('idempotency_conflict');
  });
  it('delivers one immutable ciphertext only to original eligible phones and ACK never extends retention',async()=>{
    const {owner,bob,w}=await family(),p=await delivered(owner,w),path=`/v3/group-windows/${w.windowId}/moments/${p.id}`;
    const response=await binary(bob,`${path}/ciphertext`);expect(response.status).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(p.bytes);
    expect(response.headers.get('cache-control')).toBe('no-store');
    const list=ok(await call(bob,`/v3/group-windows/${w.windowId}/moments/list`,{after:null,limit:50}));
    expect(list.items[0]).toMatchObject({id:p.id,senderParticipantId:w.roster.members[0]!.participantId,senderDeviceId:owner.deviceId,ciphertextSHA256:p.body.ciphertextSHA256});
    const ack=()=>call(bob,`${path}/ack`,{operationId:crypto.randomUUID(),ciphertextSHA256:p.body.ciphertextSHA256});
    ok(await ack());
    const first=await db.prepare('SELECT access_expires_at,acknowledged_at FROM group_moment_deliveries WHERE moment_id=? AND device_id=?').bind(p.id,bob.deviceId).first();
    ok(await ack());
    expect(await db.prepare('SELECT access_expires_at,acknowledged_at FROM group_moment_deliveries WHERE moment_id=? AND device_id=?').bind(p.id,bob.deviceId).first()).toEqual(first);
    expect(ok(await call(owner,`${path}`)).moment.hearts).toEqual([]);
  });
  it('rejects changed upload bytes, wrong sender, reused nonce and oversized ciphertext',async()=>{
    const {owner,bob,w}=await family(),p=await reserve(owner,w);ok(p.result,201);
    expect((await upload(owner,w,p,new Uint8Array(48))).data.error.code).toBe('hash_mismatch');
    expect((await upload(bob,w,p)).status).toBe(404);
    const request=await signed(owner,`/v3/group-windows/${w.windowId}/moments/${p.id}/ciphertext`,p.bytes,randomBase64url(16),'PUT');
    ok(await send(request));
    expect((await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/${p.id}/ciphertext`,p.bytes,request.headers.get('neko-nonce')!,'PUT'))).data.error.code).toBe('replay');
    expect((await upload(owner,w,p,new Uint8Array(1048577))).status).toBe(413);
  });
  it('pauses NEW commits from every participant while reads, hearts, membership and prior commit receipts survive',async()=>{
    const {owner,bob,w}=await family(),old=await delivered(owner,w),ownerPhoto=await reserve(owner,w),guestPhoto=await reserve(bob,w);
    ok(ownerPhoto.result,201);ok(guestPhoto.result,201);ok(await upload(owner,w,ownerPhoto));ok(await upload(bob,w,guestPhoto));
    await pauseOwner(owner);
    for(const [sender,p] of [[owner,ownerPhoto],[bob,guestPhoto]] as const)expect((await commit(sender,w,p)).data.error.code).toBe('window_paused');
    expect((await db.prepare("SELECT COUNT(*) n FROM group_moments WHERE space_id=? AND state='committed'").bind(w.windowId).first<{n:number}>())?.n).toBe(1);
    expect((await binary(bob,`/v3/group-windows/${w.windowId}/moments/${old.id}/ciphertext`)).status).toBe(200);
    ok(await call(bob,`/v3/group-windows/${w.windowId}/moments/${old.id}/hearts`,await heart(bob,w,old.id)));
    ok(await commit(owner,w,old));
    expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/members/list`,{after:null,limit:50})).items).toHaveLength(2);
  });
  it('does not give new people or extra phones historical deliveries or keys',async()=>{
    const {owner,bob,w:initial}=await family();let w=initial;const p=await delivered(owner,w),cat=await person();
    const invite=await invitation(owner,w),join=await apply(cat,w,invite);ok(join.response,201);
    let a=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(a.response);w=a.next;
    expect(ok(await call(cat,`/v3/group-windows/${w.windowId}/moments/list`,{after:null,limit:50})).items).toEqual([]);
    expect((await binary(cat,`/v3/group-windows/${w.windowId}/moments/${p.id}/ciphertext`)).status).toBe(410);
    const phone=await person(bob.identity),extra=await apply(phone,w,invite);ok(extra.response,201);
    const b=w.roster.members.find(m=>m.personId===bob.id)!;
    extra.member={...b,devices:[...b.devices,extra.member.devices[0]!]};
    a=await transition(owner,w,'admit',extra.id,w.roster.members.map(m=>m.personId===bob.id?extra.member:m));ok(a.response);w=a.next;
    expect(ok(await call(phone,`/v3/group-windows/${w.windowId}/moments/list`,{after:null,limit:50})).items).toEqual([]);
    expect((await call(phone,`/v3/group-windows/${w.windowId}/keys/2`)).status).toBe(403);
  });
  it('rejects a reserved old epoch and a sender removed after upload without creating deliveries',async()=>{
    const {owner,bob,w:initial}=await family();let w=initial;const p=await reserve(bob,w);ok(p.result,201);ok(await upload(bob,w,p));
    const removed=await transition(owner,w,'remove',w.roster.members[1]!.participantId,[w.roster.members[0]!]);ok(removed.response);w=removed.next;
    expect((await commit(bob,initial,p)).status).toBe(404);
    const mine=await reserve(owner,w);ok(mine.result,201);ok(await upload(owner,w,mine));
    const rotated=await transition(owner,w,'rotate',w.windowId,w.roster.members);ok(rotated.response);
    expect((await commit(owner,w,mine)).data.error.code).toBe('stale_revision');
    expect((await db.prepare('SELECT COUNT(*) n FROM group_moment_deliveries WHERE moment_id IN (?,?)').bind(p.id,mine.id).first<{n:number}>())?.n).toBe(0);
  });
  it('serializes simultaneous hearts as one per person with one quota charge, and cancel remains usable while paused',async()=>{
    const {owner,bob,w}=await family(),p=await delivered(owner,w),path=`/v3/group-windows/${w.windowId}/moments/${p.id}/hearts`;
    const first=await heart(bob,w,p.id),second=await heart(bob,w,p.id);
    const results=await Promise.all([call(bob,path,first),call(bob,path,second)]);for(const r of results)ok(r);
    const pid=w.roster.members[1]!.participantId;
    expect((await db.prepare('SELECT used FROM group_heart_usage WHERE space_id=? AND participant_id=?').bind(w.windowId,pid).first<{used:number}>())?.used).toBe(1);
    expect((await db.prepare("SELECT COUNT(*) n FROM group_notification_events WHERE moment_id=? AND kind='heart'").bind(p.id).first<{n:number}>())?.n).toBe(1);
    await pauseOwner(owner);
    ok(await call(bob,path,await heart(bob,w,p.id,false)));
    expect(ok(await call(bob,`${path}/list`,{after:null,limit:50})).items[0].active).toBe(false);
    ok(await call(bob,path,await heart(bob,w,p.id)));
    expect((await db.prepare('SELECT used FROM group_heart_usage WHERE space_id=? AND participant_id=?').bind(w.windowId,pid).first<{used:number}>())?.used).toBe(2);
    expect((await call(bob,path,{...await heart(bob,w,p.id),reactorSignature:randomBase64url(64)})).status).toBe(400);
    const request=await signed(bob,path,await heart(bob,w,p.id));expect((await send(request,{...testEnv,REACTION_RUNTIME_ENABLED:'NO'})).status).toBe(503);
  });
  it('commits concurrent retries once and enforces five photos per person per day',async()=>{
    const owner=await plusOwner(),w=await create(owner),p=await reserve(owner,w);ok(p.result,201);ok(await upload(owner,w,p));
    const results=await Promise.all([commit(owner,w,p),commit(owner,w,p)]);for(const r of results)ok(r);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_moment_deliveries WHERE moment_id=?').bind(p.id).first<{n:number}>())?.n).toBe(1);
    for(let i=0;i<4;i++)ok((await reserve(owner,w)).result,201);
    expect((await reserve(owner,w)).result.data.error.code).toBe('daily_limit');
    expect((await db.prepare("SELECT COUNT(*) n FROM group_notification_events WHERE moment_id=? AND kind='new_moment'").bind(p.id).first<{n:number}>())?.n).toBe(1);
  });
  it('rechecks personal blocks at ciphertext download and keeps other copies available',async()=>{
    const {owner,bob,w}=await family(),p=await delivered(owner,w),path=`/v3/group-windows/${w.windowId}`,ownerId=w.roster.members[0]!.participantId;
    ok(await call(bob,`${path}/blocks/${ownerId}`,{operationId:crypto.randomUUID(),active:true}));
    expect((await binary(bob,`${path}/moments/${p.id}/ciphertext`)).status).toBe(410);
    expect(ok(await call(bob,`${path}/moments/list`,{after:null,limit:50})).items).toEqual([]);
    expect((await binary(owner,`${path}/moments/${p.id}/ciphertext`)).status).toBe(200);
  });
  it('cleans only expired relay copies, retries late uploads and never treats pausing as deletion',async()=>{
    const {owner,bob,w}=await family(),p=await delivered(owner,w),path=`/v3/group-windows/${w.windowId}/moments/${p.id}`;
    const row=await db.prepare('SELECT object_key,cleanup_at FROM group_moments WHERE id=?').bind(p.id).first<{object_key:string;cleanup_at:number}>();
    await cleanLateGroupUpload(testEnv,p.id,row!.object_key);
    expect(await testEnv.MEDIA!.head(row!.object_key)).not.toBeNull();
    await pauseOwner(owner);
    await runGroupRelayCleanup({...testEnv,GROUP_RUNTIME_ENABLED:'NO'});
    expect((await binary(bob,`${path}/ciphertext`)).status).toBe(200);
    // Both main-app durable receipts shorten relay retention, without extending
    // the original 30-day maximum. The cleanup candidate is an indexed deadline.
    for(const recipient of [owner,bob])ok(await call(recipient,`${path}/ack`,{operationId:crypto.randomUUID(),ciphertextSHA256:p.body.ciphertextSHA256}));
    const after=await db.prepare('SELECT cleanup_at FROM group_moments WHERE id=?').bind(p.id).first<{cleanup_at:number}>();
    expect(after!.cleanup_at).toBeLessThan(row!.cleanup_at);
    await runGroupRelayCleanup(testEnv,after!.cleanup_at+1);
    expect(await testEnv.MEDIA!.head(row!.object_key)).toBeNull();
    expect((await db.prepare('SELECT state FROM group_moments WHERE id=?').bind(p.id).first<{state:string}>())?.state).toBe('expired');
    // A write completing after the first deletion must invalidate the old
    // completion and leave a durable retry, including after metadata GC.
    await testEnv.MEDIA!.put(row!.object_key,p.bytes);
    await cleanLateGroupUpload(testEnv,p.id,row!.object_key);
    await runGroupRelayCleanup(testEnv,after!.cleanup_at+2);
    expect(await testEnv.MEDIA!.head(row!.object_key)).toBeNull();
    await runGroupRelayCleanup(testEnv,after!.cleanup_at+172802);
    expect(await db.prepare('SELECT id FROM group_moments WHERE id=?').bind(p.id).first()).toBeNull();
    await testEnv.MEDIA!.put(row!.object_key,p.bytes);
    await cleanLateGroupUpload(testEnv,p.id,row!.object_key);
    await runGroupRelayCleanup(testEnv,after!.cleanup_at+172803);
    expect(await testEnv.MEDIA!.head(row!.object_key)).toBeNull();
    expect((await db.prepare('SELECT COUNT(*) n FROM group_members WHERE space_id=?').bind(w.windowId).first<{n:number}>())?.n).toBe(2);
  });
});
