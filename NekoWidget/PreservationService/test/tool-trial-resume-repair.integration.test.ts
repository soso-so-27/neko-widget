import { env } from 'cloudflare:workers';
import { expect, it, vi } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore } from '../src/storage';
import { ToolOwnerTrial, trialPilotAccess, TRIAL_DOCUMENT_ALLOWANCE, TRIAL_INDEX_ALLOWANCE } from '../src/tool-owner-trial';
import { PilotControl } from '../src/pilot-control';
import { randomToken, sha256, type ArchiveDocument, type KeyCustody, type ToolBackupPart } from '../src/contracts';
import type { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { OwnerDeletionJournal } from '../src/owner-deletion-journal';
import { OwnerDeletionExecutor, OwnerDeletionRequests } from '../src/owner-deletion';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { inspectOwnerD1Residue } from '../src/owner-d1-residue';
import { route } from '../src/index';

const {DB:db,ARCHIVE:bucket}=env as unknown as {DB:D1Database;ARCHIVE:R2Bucket};
const base=Date.parse('2026-10-14T13:41:23Z'), end=base+3600000;
const debt=17948504, repairBytes=6425264, budget=9448280;
const legacy:ArchiveDocument={formatVersion:1,text:'synthetic preserved old note',capturedAt:null,
  writtenAt:null,updatedAt:null,catNames:[],photoFile:null};
async function photo(snapshotId:string,size=4) {
  const raw='x'.repeat(size), part:ToolBackupPart={snapshotId,kind:'photo',path:`ShowcasePhotos/${crypto.randomUUID()}.jpg`,
    part:0,count:1,sha256:await sha256(raw),payload:''};
  const document:ArchiveDocument={...legacy,formatVersion:3,text:'ツールの保存データ',writtenAt:new Date(base).toISOString(),
    updatedAt:new Date(base).toISOString(),photoFile:'photo.jpg',toolBackup:part};
  return {id:crypto.randomUUID(),part,contentBytes:size,
    request:{document,photoBase64:btoa(raw),expectedRevision:null,consentVersion:'managed-preservation-v1'}};
}
type Photo=Awaited<ReturnType<typeof photo>>;
async function fixture(issue=true) {
  let now=base;
  await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=0,delete_intent_required=0 WHERE singleton=1').run();
  const seal=vi.fn(async(value:Uint8Array)=>value.slice()), open=vi.fn(async(value:Uint8Array)=>value.slice());
  const keys:KeyCustody={seal,open}, auth=new DurableAuth({db,keys,identityIndexSecret:randomToken(),now:()=>now});
  const identity={issuer:'https://appleid.apple.com',subject:crypto.randomUUID(),refreshToken:'synthetic'};
  const session=await auth.establish(identity);
  const photoProvider=vi.fn(async()=>true), copy=vi.fn(async()=>({}));
  const common={db,bucket,keys,auth,now:()=>now,membership:{status:async()=> 'active' as const},
    photos:{validateJPEG:photoProvider},quotaBytes:1073741824,maximumRecords:200};
  const oldID=crypto.randomUUID();
  await new ArchiveStore(common).put(session.token,oldID,{document:legacy,photoBase64:null,
    expectedRevision:null,consentVersion:'managed-preservation-v1'});
  const snapshot=crypto.randomUUID(), pending=await photo(snapshot,801110);
  await db.prepare(`INSERT INTO pa_tool_owner_trials(owner_id,owner_epoch,enabled,starts_at,ends_at,reviewed_at,
    valid_until,cost_evidence_sha256,byte_limit,attempt_limit,record_limit,snapshot_id,attempts,admitted_bytes)
    VALUES(?,0,1,?,?,?,?,?,20971520,400,200,?,27,17948504)`)
    .bind(session.ownerId,base-1000,end,base-1000,end,'a'.repeat(64),snapshot).run();
  const seeds: {id:string;part:ToolBackupPart;contentBytes:number}[]=[];
  const paths=['CareHandoff/plan.json','EvacuationPreparation/plan.json','VeterinaryVisits/state.json',
    'ShowcasePhotos/selected.json','LostCatDrafts/drafts.json'];
  for(let n=0;n<19;n++) {
    const id=crypto.randomUUID(),kind=n<5?'json':'photo',contentBytes=n<5?2:n===18?11484328-10-13*1000:1000;
    const part:ToolBackupPart={snapshotId:snapshot,kind,path:n<5?paths[n]!: `ShowcasePhotos/${crypto.randomUUID()}.jpg`,
      part:0,count:1,sha256:await sha256(kind==='json'?'{}':`synthetic-${n}`),payload:kind==='json'?btoa('{}'):''};
    seeds.push({id,part,contentBytes});
    await db.prepare(`INSERT INTO pa_tool_trial_records(owner_id,record_id,snapshot_id,kind,path,part,part_count,
      payload_sha256,input_fingerprint,content_bytes,committed) VALUES(?,?,?,?,?,0,1,?,?,?,1)`)
      .bind(session.ownerId,id,snapshot,kind,part.path,part.sha256,'b'.repeat(64),contentBytes).run();
    // Existing descriptors must pass the same authenticated metadata closure as
    // real records; index validation never downloads the seeded photo objects.
    const document:ArchiveDocument={...legacy,formatVersion:3,text:'synthetic prior tool piece',
      photoFile:kind==='photo'?'photo.jpg':null,toolBackup:part};
    const photoKey=kind==='photo'?`personal/${session.ownerId}/${id}/${crypto.randomUUID()}`:null;
    const metadata=await keys.seal(new TextEncoder().encode(JSON.stringify({version:1,
      ownerId:session.ownerId,recordId:id,revision:1,document,
      photoSHA256:kind==='photo'?part.sha256:null,photoBytes:kind==='photo'?contentBytes:0})),
      {ownerId:session.ownerId,purpose:'record',recordId:`${id}/document`});
    await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,
      metadata,photo_key,photo_bytes,quota_bytes) VALUES(?,?,1,?,?,?,?,?,0)`)
      .bind(session.ownerId,id,'b'.repeat(64),crypto.randomUUID(),metadata.buffer,photoKey,kind==='photo'?contentBytes:0).run();
  }
  const original=await sha256(JSON.stringify({document:pending.request.document,photoSHA256:pending.part.sha256}));
  await db.prepare(`INSERT INTO pa_tool_trial_records(owner_id,record_id,snapshot_id,kind,path,part,part_count,
    payload_sha256,input_fingerprint,content_bytes) VALUES(?,?,?,'photo',?,0,1,?,?,801110)`)
    .bind(session.ownerId,pending.id,snapshot,pending.part.path,pending.part.sha256,original).run();
  const trial=new ToolOwnerTrial(db,()=>now),pilot=new PilotControl(db,()=>now,'YES',JSON.stringify(['b'.repeat(64)]));
  const settings={...common,toolTrial:trial,pilotStorageAccess:trialPilotAccess(trial,pilot),
    ownerRecovery:{copyCurrent:copy} as unknown as OwnerRecoveryCopy,requireOwnerRecovery:true};
  const issueRepair=async()=> db.prepare(`INSERT INTO pa_tool_trial_resume_repairs(owner_id,owner_epoch,snapshot_id,enabled,
    issued_at,original_starts_at,ends_at,original_review_revision,original_cost_evidence_sha256,evidence_sha256,
    pending_record_id,pending_input_fingerprint,pending_payload_sha256,original_admitted_bytes,original_attempts,
    original_slots,repair_bytes,byte_limit,attempt_limit,record_limit)
    SELECT owner_id,owner_epoch,snapshot_id,1,?,starts_at,ends_at,review_revision,cost_evidence_sha256,?, ?,?,?,
      admitted_bytes,attempts,slot_generation,6425264,9448280,22,30 FROM pa_tool_owner_trials WHERE owner_id=?`)
    .bind(now,'c'.repeat(64),pending.id,original,pending.part.sha256,session.ownerId).run();
  if(issue) await issueRepair();
  seal.mockClear();open.mockClear();photoProvider.mockClear();copy.mockClear();
  return {identity,session,auth,trial,settings,archive:new ArchiveStore(settings),oldID,snapshot,pending,seeds,issueRepair,
    seal,photoProvider,copy,now:()=>now,setNow:(v:number)=>{now=v;}};
}
async function makeIndex(f:Awaited<ReturnType<typeof fixture>>,extras:Photo[]) {
  const pieces=[...f.seeds,f.pending,...extras];
  const data=JSON.stringify({version:1,snapshotID:f.snapshot.toUpperCase(),createdAt:1,
    files:pieces.map(p=>({path:p.part.path,bytes:p.contentBytes,sha256:p.part.sha256,records:[p.id.toUpperCase()]}))});
  return {id:f.snapshot,request:{document:{...legacy,formatVersion:3,text:'ツールの保存',
    writtenAt:new Date(base).toISOString(),updatedAt:new Date(base).toISOString(),toolBackup:{snapshotId:f.snapshot,
      kind:'index',path:'index.json',part:0,count:1,sha256:await sha256(data),payload:btoa(data)}},
    photoBase64:null,expectedRevision:null,consentVersion:'managed-preservation-v1'}};
}
it('issues only the exact incident once, retaining old debt and denying refill/reissue/legacy byte updates',async()=>{
  const f=await fixture();
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({byte_limit:budget,repair_bytes:repairBytes,
    admitted_bytes:0,original_admitted_bytes:debt,original_attempts:27,record_limit:30});
  await expect(f.issueRepair()).rejects.toThrow();
  for(const sql of ['DELETE FROM pa_tool_trial_resume_repairs WHERE owner_id=?',
    'UPDATE pa_tool_owner_trials SET admitted_bytes=admitted_bytes+1 WHERE owner_id=?',
    'UPDATE pa_tool_trial_resume_repairs SET repair_bytes=repair_bytes+1 WHERE owner_id=?'])
    await expect(db.prepare(sql).bind(f.session.ownerId).run()).rejects.toThrow();
  const unissued=await fixture(false);
  await db.prepare('UPDATE pa_tool_owner_trials SET attempts=28 WHERE owner_id=?').bind(unissued.session.ownerId).run();
  await expect(unissued.issueRepair()).rejects.toThrow();
  expect(await unissued.trial.repair(unissued.session.ownerId)).toBeNull();
  expect((await f.archive.read(f.session.token,f.oldID)).document).toEqual(legacy);
});
it('uses the repair total exclusively and pays before owner copy, KMS and JPEG on the pending legacy photo',async()=>{
  const f=await fixture();
  const check=async()=>{
    expect(await f.trial.grant(f.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:28});
    expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:803158});return {};
  };
  f.copy.mockImplementation(check);
  await f.archive.put(f.session.token,f.pending.id,f.pending.request);
  expect(f.photoProvider).toHaveBeenCalledOnce();expect(f.seal).toHaveBeenCalled();
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:28,slot_generation:20});
  expect((await f.trial.usage(f.session.ownerId))?.remainingBytes).toBe(budget-803158-10*TRIAL_DOCUMENT_ALLOWANCE-TRIAL_INDEX_ALLOWANCE);
});
it('rejects overflow before providers, never adding the original remaining bytes a second time',async()=>{
  const f=await fixture(),p=await photo(f.snapshot);
  await db.prepare('UPDATE pa_tool_trial_resume_repairs SET admitted_bytes=? WHERE owner_id=?')
    .bind(budget-TRIAL_DOCUMENT_ALLOWANCE-3,f.session.ownerId).run();
  await expect(f.archive.put(f.session.token,p.id,p.request)).rejects.toThrow();
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:budget-3});
  expect(f.copy).not.toHaveBeenCalled();expect(f.seal).not.toHaveBeenCalled();expect(f.photoProvider).not.toHaveBeenCalled();
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:28});
});
it('keeps failed provider and retry debit without refunding old or repair bytes',async()=>{
  const f=await fixture();f.copy.mockRejectedValueOnce(Error('synthetic provider interruption'));
  await expect(f.archive.put(f.session.token,f.pending.id,f.pending.request)).rejects.toThrow();
  await f.archive.put(f.session.token,f.pending.id,f.pending.request);
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:2*803158});
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:29,slot_generation:20});
  await expect(db.prepare('UPDATE pa_tool_trial_resume_repairs SET admitted_bytes=0 WHERE owner_id=?')
    .bind(f.session.ownerId).run()).rejects.toThrow();
});
it('charges malformed HTTP, wrong snapshot, old-record writes and 429 attempts without providers',async()=>{
  const f=await fixture(),p=await photo(crypto.randomUUID());
  await expect(route(new Request(`https://local/v1/records/${p.id}`,{method:'PUT',
    headers:{authorization:`Bearer ${f.session.token}`,'content-type':'application/json'},body:'{'}),
    {archive:f.archive,auth:f.auth,toolTrial:f.trial,verifier:{verifyNativeAuthorization:async()=>{throw Error('synthetic unused');}}})).rejects.toThrow();
  await expect(f.archive.put(f.session.token,p.id,p.request)).rejects.toThrow();
  await expect(f.archive.put(f.session.token,f.oldID,f.pending.request)).rejects.toThrow();
  await f.trial.deniedAttempt(f.session.ownerId);
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({attempts:31,admitted_bytes:debt});
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:4*2048+4+801110});
  expect(f.copy).not.toHaveBeenCalled();expect(f.seal).not.toHaveBeenCalled();expect(f.photoProvider).not.toHaveBeenCalled();
});
it('atomically permits only 22 lifetime additional attempts and retains debt across the calendar boundary',async()=>{
  const f=await fixture();
  const results=await Promise.allSettled(Array.from({length:23},()=>f.trial.deniedAttempt(f.session.ownerId)));
  expect(results.filter(r=>r.status==='fulfilled')).toHaveLength(22);
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({attempts:49,admitted_bytes:debt});
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:22*2048});
  expect(await f.trial.allowed(f.session.ownerId)).toBeNull();
  f.setNow(Date.parse('2026-11-01T00:00:00Z'));
  await expect(f.trial.deniedAttempt(f.session.ownerId)).rejects.toThrow();
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:22*2048});
});
it('never falls back on repair revocation, owner epoch change, paid link or original review change',async()=>{
  for(const mutate of [async(f:Awaited<ReturnType<typeof fixture>>)=>db.prepare('UPDATE pa_tool_trial_resume_repairs SET enabled=0 WHERE owner_id=?').bind(f.session.ownerId).run(),
    async(f:Awaited<ReturnType<typeof fixture>>)=>db.prepare('UPDATE pa_tool_owner_trials SET review_revision=review_revision+1 WHERE owner_id=?').bind(f.session.ownerId).run(),
    async(f:Awaited<ReturnType<typeof fixture>>)=>db.prepare('UPDATE pa_owners SET epoch=epoch+1 WHERE owner_id=?').bind(f.session.ownerId).run(),
    async(f:Awaited<ReturnType<typeof fixture>>)=>db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)').bind(f.session.ownerId,'synthetic-account',base).run()]) {
    const f=await fixture();await mutate(f);
    await expect(f.archive.put(f.session.token,f.pending.id,f.pending.request)).rejects.toThrow();
    expect(await f.trial.allowed(f.session.ownerId)).toBeNull();
    expect(f.copy).not.toHaveBeenCalled();expect(f.seal).not.toHaveBeenCalled();expect(f.photoProvider).not.toHaveBeenCalled();
    expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:0});
  }
});
it('serializes the last new slot; no eleventh new slot or unrelated snapshot is admitted',async()=>{
  const f=await fixture();
  for(let n=0;n<9;n++) {
    const p=await photo(f.snapshot);await f.trial.admit(f.session.ownerId,p.id,p.request);
  }
  const a=await photo(f.snapshot),b=await photo(f.snapshot);
  const results=await Promise.allSettled([f.trial.admit(f.session.ownerId,a.id,a.request),f.trial.admit(f.session.ownerId,b.id,b.request)]);
  expect(results.filter(r=>r.status==='fulfilled')).toHaveLength(1);
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({slot_generation:30,attempts:38,admitted_bytes:debt});
  expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:11*(2048+4)});
});
it('completes exactly the original 30 pieces; lost index response retry and GET preserve all debt',async()=>{
  const f=await fixture();await f.archive.put(f.session.token,f.pending.id,f.pending.request);
  const extras:Photo[]=[];
  for(let n=0;n<9;n++){const p=await photo(f.snapshot);extras.push(p);await f.archive.put(f.session.token,p.id,p.request);}
  const index=await makeIndex(f,extras);
  await f.archive.put(f.session.token,index.id,index.request);
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({completed_at:base,slot_generation:30,admitted_bytes:debt});
  const before=(await f.trial.repair(f.session.ownerId))!.admitted_bytes;
  await f.archive.put(f.session.token,index.id,index.request);
  expect((await f.trial.repair(f.session.ownerId))!.admitted_bytes).toBeGreaterThan(before);
  expect((await f.archive.read(f.session.token,index.id)).document.toolBackup).toEqual(index.request.document.toolBackup);
  const late=await photo(f.snapshot);
  await expect(f.archive.put(f.session.token,late.id,late.request)).rejects.toThrow();
  f.setNow(end);
  await expect(f.archive.put(f.session.token,index.id,index.request)).rejects.toThrow();
  const fresh=await f.auth.establish(f.identity);
  expect((await f.archive.read(fresh.token,index.id)).document.toolBackup).toEqual(index.request.document.toolBackup);
  expect((await f.archive.read(fresh.token,f.oldID)).document).toEqual(legacy);
});
it('rechecks repair revocation and expiry after providers, before reservation or commit',async()=>{
  for(const revoke of [false,true]) {
    const f=await fixture(),p=await photo(f.snapshot);
    const archive=new ArchiveStore({...f.settings,keys:{...f.settings.keys,seal:async(value:Uint8Array)=>{
      if(revoke) await db.prepare('UPDATE pa_tool_trial_resume_repairs SET enabled=0 WHERE owner_id=?').bind(f.session.ownerId).run();
      else f.setNow(end);
      return value.slice();}}});
    await expect(archive.put(f.session.token,p.id,p.request)).rejects.toThrow();
    expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,p.id).first()).toBeNull();
    expect(await f.trial.grant(f.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:28});
    expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:2052});
    const fresh=await f.auth.establish(f.identity);
    expect((await f.archive.read(fresh.token,f.oldID)).document).toEqual(legacy);
  }
});
it('allows legitimate owner erasure of repair history while retaining every other owner row',async()=>{
  const f=await fixture(),other=await fixture();
  await bucket.put('__owner_deletion/v1/format.json','{"version":1}');
  const journal=new OwnerDeletionJournal(bucket),requests=new OwnerDeletionRequests({db,journal,auth:f.auth,now:f.now});
  await requests.request(f.session.token,randomToken());
  const executor=new OwnerDeletionExecutor({enabled:true,db,bucket,journal,now:f.now,keys:f.settings.keys,
    recovery:{listOwnerVersionsPage:async()=>({versions:[],nextCursor:null})} as unknown as S3RecoveryCopy,
    revokeRefreshToken:async()=>{},versionPurge:{requestExactVersionDeletion:async()=>{}}});
  let done=false;for(let n=0;n<60;n++)if(await executor.step(f.session.ownerId)==='completed'){done=true;break;}
  expect(done).toBe(true);expect((await inspectOwnerD1Residue(db,f.session.ownerId)).contentTotal).toBe(0);
  expect(await other.trial.repair(other.session.ownerId)).toMatchObject({admitted_bytes:0});
  expect(await other.trial.grant(other.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:27});
});

it('rejects a new slot inserted after the index checked its exact generation, before providers',async()=>{
  const f=await fixture();await f.archive.put(f.session.token,f.pending.id,f.pending.request);
  const extras:Photo[]=[];
  for(let n=0;n<9;n++){const p=await photo(f.snapshot);extras.push(p);await f.archive.put(f.session.token,p.id,p.request);}
  const index=await makeIndex(f,extras),late=await photo(f.snapshot);
  const inspected=f.trial as unknown as {checkIndex:(owner:string,part:ToolBackupPart)=>Promise<number>};
  const check=inspected.checkIndex.bind(f.trial);
  inspected.checkIndex=async(owner,part)=>{const generation=await check(owner,part);
    await f.trial.admit(f.session.ownerId,late.id,late.request);return generation;};
  f.copy.mockClear();f.seal.mockClear();f.photoProvider.mockClear();
  await expect(f.archive.put(f.session.token,index.id,index.request)).rejects.toThrow();
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({completed_at:null,slot_generation:30,admitted_bytes:debt});
  expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,index.id).first()).toBeNull();
  expect(f.copy).not.toHaveBeenCalled();expect(f.seal).not.toHaveBeenCalled();
});
it('rejects repair revocation after R2 accepted the photo, preserving all debit and previous records',async()=>{
  const f=await fixture(),p=await photo(f.snapshot);let wrote=false;
  const raced=new Proxy(bucket,{get(target,key){
    if(key==='put')return async(...args:Parameters<R2Bucket['put']>)=>{
      const stored=await target.put(...args);wrote=true;
      await db.prepare('UPDATE pa_tool_trial_resume_repairs SET enabled=0 WHERE owner_id=?').bind(f.session.ownerId).run();return stored;};
    const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
  await expect(new ArchiveStore({...f.settings,bucket:raced}).put(f.session.token,p.id,p.request)).rejects.toThrow();
  expect(wrote).toBe(true);expect(await f.trial.repair(f.session.ownerId)).toMatchObject({admitted_bytes:2052});
  expect(await f.trial.grant(f.session.ownerId)).toMatchObject({admitted_bytes:debt,attempts:28});
  expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,p.id).first()).toBeNull();
  expect((await f.archive.read(f.session.token,f.oldID)).document).toEqual(legacy);
});
