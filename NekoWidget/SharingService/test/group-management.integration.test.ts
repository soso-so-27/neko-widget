import { describe,expect,it } from 'vitest';
import { plusOwner,pauseOwner } from './group-billing-fixture';
import { base64urlDecode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupFields } from '../src/group-protocol';
import { groupCloseTranscript,groupRenameTranscript } from '../src/group-management';
import { apply,call,cipher,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person } from './group-fixture';

const settings={...testEnv,GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED:'YES'};
type Window=Awaited<ReturnType<typeof create>>;
async function family() {
  const owner=await plusOwner(),bob=await person();let w=await create(owner);
  const invited=await invitation(owner,w),joined=await apply(bob,w,invited);ok(joined.response,201);
  const approved=await transition(owner,w,'admit',joined.id,[...w.roster.members,joined.member]);ok(approved.response);w=approved.next;
  return {owner,bob,w};
}
async function rename(owner:Person,w:Window,expectedNameRevision=0) {
  const operationId=crypto.randomUUID(),encryptedName=cipher();
  return {operationId,expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,expectedNameRevision,encryptedName,
    ownerSignature:await sign(owner.signing.privateKey,groupRenameTranscript({windowId:w.windowId,revision:w.roster.revision,keyEpoch:w.roster.keyEpoch,
      rosterHash:w.hash,nameRevision:expectedNameRevision+1,operationId,ciphertextSHA256:await sha256Base64url(base64urlDecode(encryptedName))}))};
}
async function close(owner:Person,w:Window) {
  const operationId=crypto.randomUUID();return {operationId,expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,
    ownerSignature:await sign(owner.signing.privateKey,groupCloseTranscript({windowId:w.windowId,revision:w.roster.revision,keyEpoch:w.roster.keyEpoch,rosterHash:w.hash,operationId}))};
}
async function manage(p:Person,w:Window,body:unknown,closing=false) {
  return send(await signed(p,`/v3/group-windows/${w.windowId}/${closing?'close':'name'}`,body),settings);
}
async function photo(owner:Person,w:Window) {
  const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16),pid=w.roster.members[0]!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),pid,owner.deviceId,String(bytes.length)]);
  const r=ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/reserve`,{operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,
    rosterRevision:w.roster.revision,ciphertextSize:bytes.length,ciphertextSHA256:hash,kind:'photo',senderSignature:await sign(owner.signing.privateKey,
      groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)]))}),201),id=r.momentId as string;
  ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/${id}/ciphertext`,bytes,randomBase64url(16),'PUT')));
  ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/${id}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}));
  return id;
}
describe('owner-only encrypted names and terminal soft closure',()=>{
  it('matches the public native management transcript vectors',()=>{
    const input={windowId:'AAAAAAAAAAAAAAAAAAAAAA',revision:7,keyEpoch:3,
      rosterHash:'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
      operationId:'11111111-1111-4111-8111-111111111111'};
    const hex=(bytes:Uint8Array)=>Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
    expect(hex(groupRenameTranscript({...input,nameRevision:9,ciphertextSHA256:'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI'})))
      .toBe('000f4e57332e57494e444f572d4e414d4500164141414141414141414141414141414141414141414100013700013300200101010101010101010101010101010101010101010101010101010101010101000139002431313131313131312d313131312d343131312d383131312d31313131313131313131313100200202020202020202020202020202020202020202020202020202020202020202');
    expect(hex(groupCloseTranscript(input))).toBe('00104e57332e57494e444f572d434c4f534500164141414141414141414141414141414141414141414100013700013300200101010101010101010101010101010101010101010101010101010101010101002431313131313131312d313131312d343131312d383131312d313131313131313131313131');
  });
  it('changes only the encrypted name with an owner proof, monotonic CAS and no roster/key rotation',async()=>{
    const {owner,bob,w}=await family(),body=await rename(owner,w);ok(await manage(owner,w,body));
    const read=ok(await send(await signed(bob,`/v3/group-windows/${w.windowId}`),settings));
    expect(read.window).toMatchObject({encryptedName:body.encryptedName,nameRevision:1,revision:w.roster.revision,keyEpoch:w.roster.keyEpoch,
      nameProof:{signerDeviceId:owner.deviceId,operationId:body.operationId,signature:body.ownerSignature}});
    expect(ok(await manage(owner,w,body)).nameRevision).toBe(1);
    expect((await manage(owner,w,await rename(owner,w))).data.error.code).toBe('stale_name_revision');
    ok(await manage(owner,w,await rename(owner,w,1)));
    expect((await db.prepare('SELECT COUNT(*) n FROM group_window_names WHERE space_id=?').bind(w.windowId).first<{n:number}>())?.n).toBe(1);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_rosters WHERE space_id=?').bind(w.windowId).first<{n:number}>())?.n).toBe(2);
  });
  it('rejects non-owner, ciphertext tampering, stale generations and rotation-required names',async()=>{
    const {owner,bob,w}=await family(),body=await rename(owner,w);
    expect((await manage(bob,w,body)).status).toBe(403);
    expect((await manage(owner,w,{...body,encryptedName:cipher()})).data.error.code).toBe('invalid_proof');
    expect((await manage(owner,w,{...body,keyEpoch:body.keyEpoch+1})).data.error.code).toBe('stale_revision');
    await db.prepare('UPDATE group_windows SET rotation_required=1 WHERE space_id=?').bind(w.windowId).run();
    expect((await manage(owner,w,body)).data.error.code).toBe('stale_epoch');
    expect(await db.prepare('SELECT space_id FROM group_window_names WHERE space_id=?').bind(w.windowId).first()).toBeNull();
  });
  it('starts a new name counter after a signed membership/key rotation',async()=>{
    const {owner,w}=await family();ok(await manage(owner,w,await rename(owner,w)));
    const rotated=await transition(owner,w,'rotate',w.windowId,w.roster.members);ok(rotated.response);
    const read=ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}`),settings));
    expect(read.window.nameRevision).toBe(0);expect(read.window.nameProof).toBeNull();
    ok(await manage(owner,rotated.next,await rename(owner,rotated.next)));
  });
  it('serializes competing name writes rather than silently losing one',async()=>{
    const {owner,w}=await family(),a=await rename(owner,w),b=await rename(owner,w);
    const results=await Promise.all([manage(owner,w,a),manage(owner,w,b)]);
    expect(results.map(r=>r.status).sort()).toEqual([200,409]);
    expect((await db.prepare('SELECT name_revision FROM group_window_names WHERE space_id=?').bind(w.windowId).first<{name_revision:number}>())?.name_revision).toBe(1);
  });
  it('closes only this window, cancels invitations/joins, preserves photo bytes/TTL and report-only access',async()=>{
    const {owner,bob,w}=await family(),id=await photo(owner,w),other=await create(owner),guest=await person(),invited=await invitation(owner,w),pending=await apply(guest,w,invited);ok(pending.response,201);
    const before=await db.prepare('SELECT object_key,unreceived_expires_at,cleanup_at,state FROM group_moments WHERE id=?').bind(id).first<{object_key:string;unreceived_expires_at:number;cleanup_at:number;state:string}>();
    await pauseOwner(owner);const body=await close(owner,w);ok(await manage(owner,w,body,true));
    expect(ok(await manage(owner,w,body,true)).state).toBe('closed');
    expect((await call(bob,`/v3/group-windows/${w.windowId}`)).status).toBe(404);
    expect((await call(owner,`/v3/group-windows/${w.windowId}/keys/${w.roster.keyEpoch}`)).status).toBe(404);
    ok(await call(owner,`/v3/group-windows/${other.windowId}`));
    expect(ok(await call(guest,`/v3/group-windows/${w.windowId}/join-status`,{requestId:pending.id})).state).toBe('cancelled');
    expect((await db.prepare('SELECT revoked_at FROM group_invitations WHERE id=?').bind(invited.id).first<{revoked_at:number|null}>())?.revoked_at).not.toBeNull();
    expect(await db.prepare('SELECT object_key,unreceived_expires_at,cleanup_at,state FROM group_moments WHERE id=?').bind(id).first()).toEqual(before);
    expect(await testEnv.MEDIA!.head(before!.object_key)).not.toBeNull();
    expect((await db.prepare("SELECT COUNT(*) n FROM group_members WHERE space_id=? AND state='active'").bind(w.windowId).first<{n:number}>())?.n).toBe(0);
    const evidence=crypto.getRandomValues(new Uint8Array(64));
    ok(await send(await signed(bob,`/v3/group-windows/${w.windowId}/reports/reserve`,{operationId:crypto.randomUUID(),momentId:id,reasonCode:'privacy',moderationKeyId:'moderation-v2',
      ciphertextSize:evidence.length,ciphertextSHA256:await sha256Base64url(evidence),reporterConsent:{version:1,acceptedAt:Math.floor(Date.now()/1000)}}),
      {...settings,GROUP_REPORT_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES',GROUP_MODERATION_RUNTIME_ENABLED:'YES'}),201);
  });
  it('rejects an unauthorized or stale close without changing any membership',async()=>{
    const {owner,bob,w}=await family(),body=await close(owner,w);
    expect((await manage(bob,w,body,true)).status).toBe(403);
    expect((await manage(owner,w,{...body,ownerSignature:randomBase64url(64)},true)).data.error.code).toBe('invalid_proof');
    expect((await manage(owner,w,{...body,expectedRevision:body.expectedRevision+1},true)).data.error.code).toBe('stale_revision');
    expect((await db.prepare("SELECT COUNT(*) n FROM group_members WHERE space_id=? AND state='active'").bind(w.windowId).first<{n:number}>())?.n).toBe(2);
  });
  it('leaves management OFF by default',async()=>{
    const {owner,w}=await family(),body=await close(owner,w);
    expect((await send(await signed(owner,`/v3/group-windows/${w.windowId}/close`,body))).data.error.code).toBe('group_management_disabled');
    expect(ok(await call(owner,`/v3/group-windows/${w.windowId}`)).window.nameProof).toBeUndefined();
  });
});
