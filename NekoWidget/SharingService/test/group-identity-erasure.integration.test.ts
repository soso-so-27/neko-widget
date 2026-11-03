import {beforeAll,describe,expect,it} from 'vitest';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {groupCaptionTranscript} from '../src/group-captions';
import {cleanupDissolvedFamilyRosters} from '../src/family-notebook-roster-cleanup';
import {familyInvitationProof} from '../src/family-notebook-admission';
import {groupDeviceAuthorization,groupFields} from '../src/group-protocol';
import {familyRosterBytes,verifyFamilyRoster,type VerifiedFamilyCryptoRoster} from '../src/family-notebook-crypto';
import {eraseGroupIdentityCredentials,eraseGroupIdentityData,listIdentityErasurePhotos,prepareIdentityErasurePhotos} from '../src/group-identity-erasure';
import {acceptIdentityFence} from '../src/group-identity-fence';
import {plusOwner} from './group-billing-fixture';
import {apply,call,create,db,invitation,key,ok,person,send,sign,signed,testEnv,transition,type Person} from './group-fixture';

// These component tests create real person fences. Provision their independent
// journal first, exactly as required before a fence is written.
beforeAll(async()=>{await testEnv.MEDIA!.put('group-identity-deletions/v1/control',JSON.stringify({sequence:0,requestId:''}),{onlyIf:{etagDoesNotMatch:'*'}});});

async function fence(p:Person){
  const claim={personId:p.id,requestId:crypto.randomUUID(),acceptedAt:Math.floor(Date.now()/1000)};
  await acceptIdentityFence(testEnv.MEDIA!,p.id,claim.requestId,randomBase64url(32),randomBase64url(32),claim.acceptedAt);
  return claim;
}
async function signedRoster(familyId:string,signer:Person,people:Person[],prior?:VerifiedFamilyCryptoRoster){
  const members=await Promise.all(people.map(async p=>{
    const device={id:p.deviceId,signingPublicKey:p.signing.publicKey,hpkePublicKey:p.hpke,personAuthorization:''};
    device.personAuthorization=await sign(p.identity.privateKey,groupDeviceAuthorization(familyId,p.id,device));
    return {personId:p.id,identityPublicKey:p.identity.publicKey,devices:[device]};
  }));
  const roster={familyId,epoch:(prior?.packet.roster.epoch??0)+1,previousHash:prior?.hash??'A'.repeat(43),keyCommitment:randomBase64url(32),members};
  const signature=await sign(signer.signing.privateKey,groupFields(['FNB1.ROSTER.SIGN',familyRosterBytes(roster),signer.deviceId]));
  return verifyFamilyRoster({roster,signerDeviceId:signer.deviceId,signature},prior);
}
async function windowWithMember(owner:Person,member:Person){
  const w=await create(owner),join=await apply(member,w,await invitation(owner,w));ok(join.response,201);
  const admitted=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(admitted.response);
  return admitted.next;
}

describe('fenced credential erasure phase',()=>{
  it('revokes only the fenced person while preserving other recipients, signed packets and family history',async()=>{
    const owner=await plusOwner(),subject=await person(),window=await windowWithMember(owner,subject);
    const family=crypto.randomUUID(),r1=await signedRoster(family,owner,[owner,subject]),r2=await signedRoster(family,owner,[owner],r1);
    const groupPackets=()=>db.prepare('SELECT * FROM group_roster_packets WHERE space_id=? ORDER BY revision').bind(window.windowId).all();
    const groupBefore=(await groupPackets()).results;
    await db.prepare("INSERT INTO family_notebook_spaces VALUES (?,2,'active',?,NULL,NULL,unixepoch(),unixepoch())").bind(family,owner.id).run();
    for(const p of [owner,subject])await db.prepare('INSERT INTO family_notebook_crypto_devices VALUES (?,?,?,?,?,?,?)')
      .bind(family,p.deviceId,p.id,p.identity.publicKey,p.signing.publicKey,p.hpke,'synthetic-certificate').run();
    for(const r of [r1,r2])await db.prepare('INSERT INTO family_notebook_crypto_rosters VALUES (?,?,?,?)')
      .bind(family,r.packet.roster.epoch,r.hash,JSON.stringify(r.packet)).run();
    await db.prepare('INSERT INTO family_notebook_crypto_heads VALUES (?,2)').bind(family).run();
    for(const p of [owner,subject])await db.prepare('INSERT INTO family_notebook_crypto_envelopes VALUES (?,1,1,?,?,?)')
      .bind(family,p.deviceId,subject.deviceId,JSON.stringify({fixtureCiphertext:p.id})).run();
    await db.prepare('INSERT INTO family_notebook_crypto_operations VALUES (?,1,?,1,?,?,?)')
      .bind(family,crypto.randomUUID(),owner.id,owner.deviceId,'{"fixtureCiphertext":"other-history"}').run();
    const familyBefore=(await db.prepare('SELECT * FROM family_notebook_crypto_rosters WHERE family_id=? ORDER BY epoch').bind(family).all()).results;
    for(const table of ['group_push_subscriptions','group_join_push_subscriptions'])for(const p of [owner,subject])
      await db.prepare(`INSERT INTO ${table} VALUES (?,?, 'cipher','nonce','digest','key','development',1,?)`).bind(window.windowId,p.deviceId,Math.floor(Date.now()/1000)+3600).run();
    const claim=await fence(subject);
    await eraseGroupIdentityCredentials(testEnv,claim);
    expect((await groupPackets()).results).toEqual(groupBefore);
    expect((await db.prepare('SELECT * FROM family_notebook_crypto_rosters WHERE family_id=? ORDER BY epoch').bind(family).all()).results).toEqual(familyBefore);
    expect((await verifyFamilyRoster(r2.packet,r1)).hash).toBe(r2.hash);
    expect((await db.prepare('SELECT * FROM family_notebook_crypto_operations WHERE family_id=?').bind(family).first())?.packet).toBe('{"fixtureCiphertext":"other-history"}');
    expect((await db.prepare('SELECT recipient_device_id,signer_device_id FROM family_notebook_crypto_envelopes WHERE family_id=?').bind(family).all()).results)
      .toEqual([{recipient_device_id:owner.deviceId,signer_device_id:subject.deviceId}]);
    expect((await db.prepare('SELECT device_id FROM family_notebook_crypto_devices WHERE family_id=?').bind(family).all()).results).toEqual([{device_id:owner.deviceId}]);
    expect((await db.prepare('SELECT state,identity_public_key FROM group_people WHERE id=?').bind(subject.id).first())).toEqual({state:'revoked',identity_public_key:'deleted:'+subject.id});
    expect(await db.prepare('SELECT state,signing_public_key,hpke_public_key,authorization FROM group_person_devices WHERE id=?').bind(subject.deviceId).first())
      .toEqual({state:'revoked',signing_public_key:'deleted:'+subject.deviceId,hpke_public_key:'deleted:'+subject.deviceId,authorization:''});
    expect((await call(subject,`/v3/group-windows/${window.windowId}`)).status).toBe(401);
    ok(await call(owner,`/v3/group-windows/${window.windowId}`));
    await eraseGroupIdentityCredentials(testEnv,claim);
    for(const table of ['group_push_subscriptions','group_join_push_subscriptions']){
      expect(await db.prepare(`SELECT generation,token_ciphertext FROM ${table} WHERE device_id=?`).bind(subject.deviceId).first()).toEqual({generation:2,token_ciphertext:''});
      expect(await db.prepare(`SELECT generation,token_ciphertext FROM ${table} WHERE device_id=?`).bind(owner.deviceId).first()).toEqual({generation:1,token_ciphertext:'cipher'});
    }
    // A later normal window close/revocation must not restore report-only access.
    await db.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=3 WHERE space_id=? AND device_id=?").bind(window.windowId,subject.deviceId).run();
    expect(await db.prepare('SELECT 1 FROM group_report_access WHERE device_id=?').bind(subject.deviceId).first()).toBeNull();
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
  it('requires the matching independent fence, rolls back an interruption, and resumes with no command left',async()=>{
    const subject=await person(),other=await person(),claim=await fence(subject);
    for(const wrong of [{...claim,personId:other.id},{...claim,acceptedAt:claim.acceptedAt+1},{...claim,requestId:crypto.randomUUID()}])
      await expect(eraseGroupIdentityCredentials(testEnv,wrong)).rejects.toThrow();
    await expect(db.prepare("UPDATE group_person_devices SET signing_public_key='bad' WHERE id=?").bind(subject.deviceId).run()).rejects.toThrow('group_device_identity_immutable');
    await db.prepare("CREATE TRIGGER synthetic_erasure_interrupt BEFORE DELETE ON group_identity_erasure_commands BEGIN SELECT RAISE(ABORT,'synthetic_interrupt'); END").run();
    try{await expect(eraseGroupIdentityCredentials(testEnv,claim)).rejects.toThrow('synthetic_interrupt');}
    finally{await db.prepare('DROP TRIGGER synthetic_erasure_interrupt').run();}
    expect(await db.prepare('SELECT state,identity_public_key FROM group_people WHERE id=?').bind(subject.id).first()).toEqual({state:'active',identity_public_key:subject.identity.publicKey});
    expect(await db.prepare('SELECT signing_public_key FROM group_person_devices WHERE id=?').bind(subject.deviceId).first()).toEqual({signing_public_key:subject.signing.publicKey});
    expect(await db.prepare('SELECT 1 FROM group_identity_erasure_commands').first()).toBeNull();
    await eraseGroupIdentityCredentials(testEnv,claim);
    expect(await db.prepare('SELECT 1 FROM group_identity_erasure_commands').first()).toBeNull();
    expect(await db.prepare('SELECT state,identity_public_key FROM group_people WHERE id=?').bind(other.id).first()).toEqual({state:'active',identity_public_key:other.identity.publicKey});
    await expect(db.prepare("UPDATE group_people SET identity_public_key=?,state='active' WHERE id=?").bind(subject.identity.publicKey,subject.id).run()).rejects.toThrow('group_person_identity_immutable');
  });
});

async function photo(sender:Person,w:Awaited<ReturnType<typeof create>>){
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
const familySettings={...testEnv,FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'YES'};
async function familyRequest(p:Person,f:string,subpath:string,body?:unknown){
  const path='/v3/family-notebooks'+(f?'/'+f:'')+subpath;
  return send(await signed(p,path,body),familySettings);
}
async function setupFamily(owner:Person,other:Person){
  await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1 AND enabled=0').run();
  const id=crypto.randomUUID();ok(await familyRequest(owner,'','',{operationId:crypto.randomUUID(),familyId:id}));
  const proof=await key(),invite=crypto.randomUUID(),join=crypto.randomUUID();
  ok(await familyRequest(owner,id,'/invitations',{operationId:invite,expectedGeneration:1,proofPublicKey:proof.publicKey,encryptedPreview:randomBase64url(48)}));
  ok(await familyRequest(other,id,`/invitations/${invite}/join`,{operationId:join,expectedGeneration:1,encryptedDisplayName:randomBase64url(48),
    proofSignature:await sign(proof.privateKey,familyInvitationProof(id,invite,other.id,other.deviceId,'join',join))}));
  ok(await familyRequest(owner,id,`/requests/${join}/approve`,{operationId:crypto.randomUUID(),expectedGeneration:1}));
  return {id,invite,join};
}
describe('identity deletion dependency closure',()=>{
  it('closes owned windows, leaves other groups and families, removes only own photos including captions and keeps the other account',async()=>{
    const a=await plusOwner(),b=await plusOwner(),own=await windowWithMember(a,b),other=await windowWithMember(b,a);
    const mine=await photo(a,own),theirs=await photo(b,own),f=await setupFamily(a,b),claim=await fence(a);
    const otherBilling=await db.prepare('SELECT * FROM group_billing_connections WHERE person_id=?').bind(b.id).first();
    const original=await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(theirs.id).first();
    const otherHistory=(await db.prepare('SELECT packet_json FROM group_roster_packets WHERE space_id=? ORDER BY revision').bind(other.windowId).all()).results;
    const inv=(await listIdentityErasurePhotos(testEnv,claim));expect(inv.map(p=>p.momentId)).toEqual([mine.id]);
    const r=await eraseGroupIdentityData(testEnv,claim);expect(r.morePhotos).toBe(false);
    expect(await testEnv.MEDIA!.head(mine.row.object_key)).toBeNull();expect(await testEnv.MEDIA!.head(mine.row.object_key+'.caption')).toBeNull();
    expect(await db.prepare('SELECT id FROM group_moments WHERE id=?').bind(mine.id).first()).toBeNull();
    expect(await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(theirs.id).first()).toEqual(original);
    expect(new Uint8Array(await (await testEnv.MEDIA!.get(theirs.row.object_key))!.arrayBuffer())).toEqual(theirs.bytes);
    expect(new Uint8Array(await (await testEnv.MEDIA!.get(theirs.row.object_key+'.caption'))!.arrayBuffer())).toEqual(theirs.captionBytes);
    expect((await db.prepare('SELECT mode FROM group_windows WHERE space_id=?').bind(own.windowId).first())?.mode).toBe('closed');
    expect((await db.prepare('SELECT expires_at FROM group_report_access WHERE space_id=? AND device_id=?').bind(own.windowId,b.deviceId).first<{expires_at:number}>())!.expires_at).toBeGreaterThan(claim.acceptedAt);
    expect(await db.prepare('SELECT mode,rotation_required FROM group_windows WHERE space_id=?').bind(other.windowId).first()).toEqual({mode:'active',rotation_required:1});
    expect((await db.prepare('SELECT packet_json FROM group_roster_packets WHERE space_id=? ORDER BY revision').bind(other.windowId).all()).results).toEqual(otherHistory);
    expect((await db.prepare('SELECT state,display_name_ciphertext FROM group_members WHERE person_id=?').bind(a.id).all()).results)
      .toEqual([{state:'left',display_name_ciphertext:''},{state:'left',display_name_ciphertext:''}]);
    expect(await db.prepare('SELECT * FROM group_billing_connections WHERE person_id=?').bind(b.id).first()).toEqual(otherBilling);
    expect(await db.prepare('SELECT 1 FROM billing_accounts WHERE id=?').bind(a.account.id).first()).not.toBeNull();
    expect(await db.prepare('SELECT 1 FROM group_billing_connections WHERE person_id=?').bind(a.id).first()).toBeNull();
    expect(await db.prepare('SELECT generation,state,payer_person_id,payer_absent_since_generation FROM family_notebook_spaces WHERE id=?').bind(f.id).first())
      .toEqual({generation:3,state:'active',payer_person_id:null,payer_absent_since_generation:3});
    expect((await db.prepare('SELECT person_id,state FROM family_notebook_members WHERE family_id=?').bind(f.id).all()).results).toEqual([{person_id:b.id,state:'active'}]);
    expect((await db.prepare('SELECT creator_person_id,proof_public_key,encrypted_preview FROM family_notebook_invitations WHERE id=?').bind(f.invite).first())?.encrypted_preview).toBe('');
    expect(await db.prepare('SELECT ciphertext FROM family_notebook_admission_events WHERE actor_person_id=?').bind(a.id).first()).toBeNull();
    expect(await eraseGroupIdentityData(testEnv,claim)).toEqual({morePhotos:false});
    expect((await db.prepare('SELECT generation FROM family_notebook_spaces WHERE id=?').bind(f.id).first())?.generation).toBe(3);
    await db.prepare('DELETE FROM family_notebook_join_requests WHERE id=? AND person_id=?').bind(f.join,b.id).run();
    expect(await db.prepare('SELECT 1 FROM family_notebook_invitations WHERE id=?').bind(f.invite).first()).toBeNull();
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
  it('moves the exact dissolved family deadline before deleting its actor receipt, preserving the full 30 days',async()=>{
    const a=await plusOwner(),b=await person(),f=await setupFamily(a,b);
    const r=await signedRoster(f.id,a,[a,b]);
    await db.prepare('INSERT INTO family_notebook_crypto_rosters VALUES (?,1,?,?)').bind(f.id,r.hash,JSON.stringify(r.packet)).run();
    await db.prepare('INSERT INTO family_notebook_crypto_operations VALUES (?,1,?,1,?,?,?)').bind(f.id,crypto.randomUUID(),b.id,b.deviceId,'{"ciphertext":"other-history"}').run();
    const state=ok(await familyRequest(a,f.id,'/dissolve',{operationId:crypto.randomUUID(),expectedGeneration:2}));
    expect(state).toBeTruthy();
    const before=await db.prepare("SELECT resulting_generation,recorded_at FROM family_notebook_governance_events WHERE family_id=? AND action='dissolve'").bind(f.id).first<{resulting_generation:number;recorded_at:number}>();
    expect(before).not.toBeNull();await eraseGroupIdentityData(testEnv,await fence(a));
    expect(await db.prepare('SELECT generation,closed_at FROM group_erased_family_dissolutions WHERE family_id=?').bind(f.id).first())
      .toEqual({generation:before!.resulting_generation,closed_at:before!.recorded_at});
    expect(await db.prepare('SELECT 1 FROM family_notebook_governance_events WHERE actor_person_id=?').bind(a.id).first()).toBeNull();
    await cleanupDissolvedFamilyRosters(testEnv,before!.recorded_at+30*86400-1);
    expect((await db.prepare('SELECT packet FROM family_notebook_crypto_operations WHERE family_id=?').bind(f.id).first())?.packet).toBe('{"ciphertext":"other-history"}');
    await cleanupDissolvedFamilyRosters(testEnv,before!.recorded_at+30*86400);
    expect(await db.prepare('SELECT 1 FROM family_notebook_crypto_operations WHERE family_id=?').bind(f.id).first()).toBeNull();
    expect(await db.prepare('SELECT 1 FROM group_erased_family_dissolutions WHERE family_id=?').bind(f.id).first()).toBeNull();
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
});

describe('bounded physical erasure and retry',()=>{
  it('resumes after physical deletion but a rolled-back D1 batch and drains nine owned photos in two slices',async()=>{
    const a=await plusOwner(),w=await create(a),v=await create(a),all=[];
    for(let i=0;i<9;i++)all.push(await photo(a,i<5?w:v));
    const acceptedInventory=await prepareIdentityErasurePhotos(testEnv,a.id);
    const claim=await fence(a),manifest=await listIdentityErasurePhotos(testEnv,claim,'',32);
    expect(acceptedInventory).toEqual(manifest);
    expect(manifest).toHaveLength(9);
    expect(await listIdentityErasurePhotos(testEnv,claim,manifest[7]!.momentId,8)).toEqual([manifest[8]]);
    await db.prepare("CREATE TRIGGER synthetic_photo_erasure_interrupt BEFORE DELETE ON group_moments BEGIN SELECT RAISE(ABORT,'photo_interrupt'); END").run();
    try{await expect(eraseGroupIdentityData(testEnv,claim)).rejects.toThrow('photo_interrupt');}
    finally{await db.prepare('DROP TRIGGER synthetic_photo_erasure_interrupt').run();}
    expect(await listIdentityErasurePhotos(testEnv,claim,'',32)).toEqual(manifest);
    expect(await testEnv.MEDIA!.head(manifest[0]!.objectKey)).toBeNull();
    expect(await testEnv.MEDIA!.head(manifest[0]!.objectKey+'.caption')).toBeNull();
    expect(await testEnv.MEDIA!.head(manifest[8]!.objectKey)).not.toBeNull();
    expect(await eraseGroupIdentityData(testEnv,claim)).toEqual({morePhotos:true});
    expect(await listIdentityErasurePhotos(testEnv,claim,'',32)).toEqual([manifest[8]]);
    expect(await eraseGroupIdentityData(testEnv,claim)).toEqual({morePhotos:false});
    expect(await db.prepare('SELECT 1 FROM group_rosters WHERE space_id IN (?,?)').bind(w.windowId,v.windowId).first()).toBeNull();
    for(const p of all){expect(await testEnv.MEDIA!.head(p.row.object_key)).toBeNull();expect(await testEnv.MEDIA!.head(p.row.object_key+'.caption')).toBeNull();}
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  },20000);
});

describe('pre-fence photo inventory',()=>{
  it('pages all 33 owned records without reading a different sender into the inventory',async()=>{
    const a=await plusOwner(),b=await plusOwner(),aw=await create(a),bw=await create(b),ids=[];
    const now=Math.floor(Date.now()/1000);
    // Metadata-only fixture. Exercise the actual D1 day/roster/recipient
    // guards and page boundary without creating 34 unnecessary R2 bodies.
    for(let i=0;i<34;i++){
      const own=i<33,p=own?a:b,w=own?aw:bw,id=randomBase64url(16),hash=randomBase64url(32),time=now-(12-Math.floor(i/3))*86400;
      await db.prepare(`INSERT INTO group_moments VALUES(?,?,?,?,?,?,?,?,?,?,?,'photo','reserved',?,?,?,NULL,?,?,NULL)`)
        .bind(id,w.windowId,randomBase64url(16),w.roster.members[0]!.participantId,p.deviceId,w.roster.keyEpoch,w.roster.revision,w.hash,48,hash,
          randomBase64url(64),`groups/v3/${w.windowId}/${id}/${hash}`,time,time+3600,time+30*86400,time+3600).run();
      if(own)ids.push(id);
    }
    const inventory=await prepareIdentityErasurePhotos(testEnv,a.id);
    expect(inventory.map(p=>p.momentId)).toEqual(ids.sort());
    expect(inventory.every(p=>p.windowId===aw.windowId)).toBe(true);
  });
});
