import {describe,expect,it} from 'vitest';
import {plusOwner} from './group-billing-fixture';
import {apply,call,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person} from './group-fixture';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {groupFields} from '../src/group-protocol';
import {groupCaptionTranscript} from '../src/group-captions';
import {groupCloseTranscript} from '../src/group-management';
import {runGroupRelayCleanup} from '../src/group-cleanup';

const off={...testEnv,GROUP_RUNTIME_ENABLED:'NO',GROUP_MODERATION_RUNTIME_ENABLED:'NO',GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED:'NO'};
type Window=Awaited<ReturnType<typeof create>>;
async function family(){
  const owner=await plusOwner(),member=await person();let w=await create(owner);
  const join=await apply(member,w,await invitation(owner,w));ok(join.response,201);
  const accepted=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(accepted.response);w=accepted.next;
  return {owner,member,w};
}
async function close(owner:Person,w:Window){
  const operationId=crypto.randomUUID(),body={operationId,expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,
    ownerSignature:await sign(owner.signing.privateKey,groupCloseTranscript({windowId:w.windowId,revision:w.roster.revision,keyEpoch:w.roster.keyEpoch,rosterHash:w.hash,operationId}))};
  ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/close`,body),{...testEnv,GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED:'YES'}));
}
async function photo(sender:Person,w:Window){
  const bytes=crypto.getRandomValues(new Uint8Array(48)),captionBytes=crypto.getRandomValues(new Uint8Array(52));
  const hash=await sha256Base64url(bytes),captionHash=await sha256Base64url(captionBytes),clientMomentId=randomBase64url(16);
  const participantId=w.roster.members.find(m=>m.personId===sender.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),participantId,sender.deviceId,String(bytes.length)]);
  const body={operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    ciphertextSize:bytes.length,ciphertextSHA256:hash,senderSignature:await sign(sender.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),kind:'photo',
    caption:{ciphertextSize:captionBytes.length,ciphertextSHA256:captionHash,senderSignature:await sign(sender.signing.privateKey,
      groupCaptionTranscript({windowId:w.windowId,clientMomentId,keyEpoch:w.roster.keyEpoch,rosterHash:w.hash,participantId,deviceId:sender.deviceId,photoHash:hash,size:captionBytes.length,hash:captionHash}))}};
  const path=`/v3/group-windows/${w.windowId}`,id=ok(await call(sender,path+'/moments/reserve',body),201).momentId as string;
  for(const [suffix,data] of [['ciphertext',bytes],['caption-ciphertext',captionBytes]] as const)
    ok(await send(await signed(sender,`${path}/moments/${id}/${suffix}`,data,randomBase64url(16),'PUT')));
  ok(await call(sender,`${path}/moments/${id}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}));
  const row=(await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(id).first<{object_key:string;cleanup_at:number}>())!;
  return {id,row,bytes,captionBytes};
}
async function counts(w:Window){
  return Promise.all(['group_key_envelopes','group_roster_packets','group_rosters'].map(async table=>
    (await db.prepare(`SELECT COUNT(*) n FROM ${table} WHERE space_id=?`).bind(w.windowId).first<{n:number}>())!.n));
}
describe('closed roster cleanup shares final relay-metadata transaction',()=>{
  it('waits for moments=0 without changing other-person photo/sidecar/deadline, then purges with runtime OFF',async()=>{
    const f=await family(),p=await photo(f.member,f.w);await close(f.owner,f.w);
    await runGroupRelayCleanup(off);
    expect(await counts(f.w)).toEqual([3,2,2]);
    expect(await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(p.id).first()).toEqual(p.row);
    expect(new Uint8Array(await (await testEnv.MEDIA!.get(p.row.object_key))!.arrayBuffer())).toEqual(p.bytes);
    expect(new Uint8Array(await (await testEnv.MEDIA!.get(p.row.object_key+'.caption'))!.arrayBuffer())).toEqual(p.captionBytes);
    await runGroupRelayCleanup(off,p.row.cleanup_at+1);
    expect(await counts(f.w)).toEqual([3,2,2]);
    expect(await db.prepare('SELECT id FROM group_moments WHERE id=?').bind(p.id).first()).not.toBeNull();
    await runGroupRelayCleanup(off,p.row.cleanup_at+172802);
    expect(await db.prepare('SELECT id FROM group_moments WHERE id=?').bind(p.id).first()).toBeNull();
    expect(await counts(f.w)).toEqual([0,0,0]);
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
  it('leaves an open empty window and its exact signed packets unchanged',async()=>{
    const f=await family(),before=await db.prepare('SELECT * FROM group_roster_packets WHERE space_id=? ORDER BY revision').bind(f.w.windowId).all();
    await runGroupRelayCleanup(off);
    expect(await counts(f.w)).toEqual([3,2,2]);
    expect((await db.prepare('SELECT * FROM group_roster_packets WHERE space_id=? ORDER BY revision').bind(f.w.windowId).all()).results).toEqual(before.results);
  });
  it('handles already-closed empty windows idempotently without requiring a fresh close',async()=>{
    const f=await family();await close(f.owner,f.w);
    expect(await counts(f.w)).toEqual([3,2,2]);
    await runGroupRelayCleanup(off);expect(await counts(f.w)).toEqual([0,0,0]);
    await runGroupRelayCleanup(off);expect(await counts(f.w)).toEqual([0,0,0]);
  });
  it('rolls back final moment deletion and all roster deletions together, then resumes',async()=>{
    const f=await family(),p=await photo(f.member,f.w);await close(f.owner,f.w);
    await runGroupRelayCleanup(off,p.row.cleanup_at+1);
    await db.prepare(`CREATE TRIGGER synthetic_roster_interrupt BEFORE DELETE ON group_rosters
      WHEN OLD.space_id='${f.w.windowId}' BEGIN SELECT RAISE(ABORT,'synthetic_roster_interrupt'); END`).run();
    try{await expect(runGroupRelayCleanup(off,p.row.cleanup_at+172802)).rejects.toThrow('synthetic_roster_interrupt');}
    finally{await db.prepare('DROP TRIGGER synthetic_roster_interrupt').run();}
    expect(await counts(f.w)).toEqual([3,2,2]);
    expect((await db.prepare('SELECT state FROM group_moments WHERE id=?').bind(p.id).first())?.state).toBe('expired');
    await runGroupRelayCleanup(off,p.row.cleanup_at+172802);expect(await counts(f.w)).toEqual([0,0,0]);
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
  it('clears a newly-empty window in the same batch even behind fifty already-empty windows',async()=>{
    const f=await family(),p=await photo(f.member,f.w);await close(f.owner,f.w);
    await runGroupRelayCleanup(off,p.row.cleanup_at+1);
    // Synthetic old closed windows sort before all protocol window IDs.
    for(let i=0;i<51;i++){
      const id=`!backlog-${String(i).padStart(3,'0')}`;
      await db.batch([
        db.prepare(`INSERT INTO group_windows(space_id,owner_person_id,mode,revision,key_epoch,roster_hash,created_at,updated_at)
          SELECT ?,owner_person_id,'closed',revision,key_epoch,roster_hash,created_at,updated_at FROM group_windows WHERE space_id=?`).bind(id,f.w.windowId),
        db.prepare(`INSERT INTO group_rosters SELECT ?,revision,previous_hash,key_epoch,canonical_bytes,roster_hash,signer_device_id,signature,created_at
          FROM group_rosters WHERE space_id=?`).bind(id,f.w.windowId),
      ]);
    }
    await runGroupRelayCleanup(off,p.row.cleanup_at+172802);
    expect(await db.prepare('SELECT id FROM group_moments WHERE id=?').bind(p.id).first()).toBeNull();
    expect(await counts(f.w)).toEqual([0,0,0]);
    expect((await db.prepare("SELECT COUNT(DISTINCT space_id) n FROM group_rosters WHERE space_id LIKE '!backlog-%'").first())?.n).toBe(1);
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
});
