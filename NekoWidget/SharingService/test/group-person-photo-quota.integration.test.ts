import { describe,expect,it } from 'vitest';
import { plusOwner } from './group-billing-fixture';
import { base64urlDecode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupFields } from '../src/group-protocol';
import { groupCloseTranscript } from '../src/group-management';
import { call,create,db,ok,person,send,sign,signed,testEnv,type Person } from './group-fixture';

type Window=Awaited<ReturnType<typeof create>>;
async function descriptor(p:Person,w:Window) {
  const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
  const pid=w.roster.members.find(m=>m.personId===p.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),pid,p.deviceId,String(bytes.length)]);
  return {bytes,body:{operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,ciphertextSize:bytes.length,
    ciphertextSHA256:hash,senderSignature:await sign(p.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),kind:'photo'}};
}
async function reserve(p:Person,w:Window) {
  const data=await descriptor(p,w),result=await call(p,`/v3/group-windows/${w.windowId}/moments/reserve`,data.body);
  return {...data,result,id:result.data.momentId as string};
}
async function upload(p:Person,w:Window,r:Awaited<ReturnType<typeof reserve>>) {
  ok(await send(await signed(p,`/v3/group-windows/${w.windowId}/moments/${r.id}/ciphertext`,r.bytes,randomBase64url(16),'PUT')));
}
async function commit(p:Person,w:Window,r:Awaited<ReturnType<typeof reserve>>) {
  return call(p,`/v3/group-windows/${w.windowId}/moments/${r.id}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,
    keyEpoch:w.roster.keyEpoch,ciphertextSHA256:r.body.ciphertextSHA256});
}
async function delivered(p:Person,w:Window) {
  const r=await reserve(p,w);ok(r.result,201);await upload(p,w,r);ok(await commit(p,w,r));return r;
}
describe('five group photos per person per UTC day, across windows and phones',()=>{
  it('holds one shared quota for multiple windows and registered phones, while identical retries are free',async()=>{
    const owner=await plusOwner(),otherPhone=await person(owner.identity),a=await create(owner),b=await create(otherPhone);
    let first:Awaited<ReturnType<typeof reserve>>|undefined;
    for(let i=0;i<4;i++){const r=await reserve(owner,a);ok(r.result,201);first??=r;}
    ok((await reserve(otherPhone,b)).result,201);
    expect((await reserve(owner,a)).result.data.error.code).toBe('daily_limit');
    expect((await reserve(otherPhone,b)).result.data.error.code).toBe('daily_limit');
    expect(ok(await call(owner,`/v3/group-windows/${a.windowId}/moments/reserve`,first!.body)).momentId).toBe(first!.id);
  });
  it('does not combine unrelated people into one quota',async()=>{
    const alice=await plusOwner(),bob=await plusOwner(),a=await create(alice),b=await create(bob);
    for(let i=0;i<5;i++)ok((await reserve(alice,a)).result,201);
    for(let i=0;i<5;i++)ok((await reserve(bob,b)).result,201);
  });
  it('serializes simultaneous reservations in different windows at the last available slot',async()=>{
    const owner=await plusOwner(),a=await create(owner),b=await create(owner);
    for(let i=0;i<4;i++)ok((await reserve(owner,a)).result,201);
    const results=await Promise.all([reserve(owner,a),reserve(owner,b)]);
    expect(results.map(r=>r.result.status).sort()).toEqual([201,409]);
  });
  it('rechecks the commit day for an earlier-day lease and never publishes a sixth photo',async()=>{
    const owner=await plusOwner(),a=await create(owner),b=await create(owner),old=await reserve(owner,a);ok(old.result,201);
    // Local fixture models a live upload lease crossing UTC midnight. No gate
    // or authority is bypassed; each upload/commit still uses real signatures.
    await db.prepare('UPDATE group_moments SET created_at=? WHERE id=?').bind(Math.floor(Date.now()/86400000)*86400-1,old.id).run();
    const current:Awaited<ReturnType<typeof reserve>>[]=[];
    for(let i=0;i<5;i++){const r=await reserve(owner,b);ok(r.result,201);current.push(r);}
    await upload(owner,a,old);ok(await commit(owner,a,old));
    for(const r of current.slice(0,4)){await upload(owner,b,r);ok(await commit(owner,b,r));}
    const last=current[4]!;await upload(owner,b,last);
    expect((await commit(owner,b,last)).data.error.code).toBe('daily_limit');
    expect((await db.prepare('SELECT state FROM group_moments WHERE id=?').bind(last.id).first<{state:string}>())?.state).toBe('uploaded');
  });
  it('does not count the previous UTC day against the next day',async()=>{
    const owner=await plusOwner(),a=await create(owner),b=await create(owner),ids:string[]=[];
    for(let i=0;i<5;i++)ids.push((await delivered(owner,a)).id);
    for(const id of ids)await db.prepare('UPDATE group_moments SET committed_at=? WHERE id=?').bind(Math.floor(Date.now()/86400000)*86400-1,id).run();
    ok((await reserve(owner,b)).result,201);
  });
  it('does not reset the person quota by closing and recreating a window',async()=>{
    const owner=await plusOwner(),a=await create(owner);
    for(let i=0;i<5;i++)await delivered(owner,a);
    const operationId=crypto.randomUUID(),ownerSignature=await sign(owner.signing.privateKey,groupCloseTranscript({windowId:a.windowId,
      revision:a.roster.revision,keyEpoch:a.roster.keyEpoch,rosterHash:a.hash,operationId}));
    ok(await send(await signed(owner,`/v3/group-windows/${a.windowId}/close`,{operationId,expectedRevision:a.roster.revision,keyEpoch:a.roster.keyEpoch,ownerSignature}),
      {...testEnv,GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED:'YES'}));
    const b=await create(owner);expect((await reserve(owner,b)).result.data.error.code).toBe('daily_limit');
  });
});
