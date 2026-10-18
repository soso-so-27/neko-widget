import { env } from 'cloudflare:workers';
import { expect, it, vi } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore } from '../src/storage';
import { ToolOwnerTrial, trialPilotAccess, trialOwnerAdmission, TRIAL_DOCUMENT_ALLOWANCE, TRIAL_INDEX_ALLOWANCE } from '../src/tool-owner-trial';
import { PilotControl } from '../src/pilot-control';
import { IntakeControl } from '../src/intake-control';
import { randomToken, sha256, type ArchiveDocument, type KeyCustody } from '../src/contracts';
import type { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { OwnerDeletionJournal } from '../src/owner-deletion-journal';
import { OwnerDeletionExecutor, OwnerDeletionRequests } from '../src/owner-deletion';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { inspectOwnerD1Residue } from '../src/owner-d1-residue';
import { MembershipLinks } from '../src/membership-links';
import worker, { route, type Env } from '../src/index';
import { validateDocument } from '../src/documents';

const {DB:db,ARCHIVE:bucket}=env as unknown as {DB:D1Database;ARCHIVE:R2Bucket};
const base=Date.parse('2026-10-31T23:59:00Z');
const legacy:ArchiveDocument={formatVersion:1,text:'synthetic prior note',capturedAt:null,writtenAt:null,updatedAt:null,catNames:[],photoFile:null};
async function fixture(options:{bytes?:number;attempts?:number;records?:number;duration?:number}={}) {
  let now=base;
  await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=0,delete_intent_required=0 WHERE singleton=1').run();
  const seal=vi.fn(async (value:Uint8Array)=>value.slice()),open=vi.fn(async (value:Uint8Array)=>value.slice());
  const keys:KeyCustody={seal,open};
  const authOptions={db,keys,identityIndexSecret:randomToken(),now:()=>now};
  const auth=new DurableAuth(authOptions);
  const identity={issuer:'https://appleid.apple.com',subject:crypto.randomUUID(),refreshToken:'synthetic-only'};
  const session=await auth.establish(identity);
  const photo=vi.fn(async()=>true),copy=vi.fn(async()=>({}));
  const common={db,bucket,keys,auth,now:()=>now,membership:{status:async()=> 'active' as const},
    photos:{validateJPEG:photo},quotaBytes:1073741824,maximumRecords:200};
  const oldID=crypto.randomUUID();
  await new ArchiveStore(common).put(session.token,oldID,{document:legacy,photoBase64:null,
    expectedRevision:null,consentVersion:'managed-preservation-v1'});
  await db.prepare(`INSERT INTO pa_tool_owner_trials(owner_id,owner_epoch,enabled,starts_at,ends_at,reviewed_at,
    valid_until,cost_evidence_sha256,byte_limit,attempt_limit,record_limit)
    VALUES(?,0,1,?,?,?,?,?, ?,?,?)`).bind(session.ownerId,now,now+(options.duration??86400000),now,
      now+(options.duration??86400000),'a'.repeat(64),options.bytes??20*1024*1024,options.attempts??30,options.records??20).run();
  const trial=new ToolOwnerTrial(db,()=>now);
  const pilot=new PilotControl(db,()=>now,'YES',JSON.stringify(['b'.repeat(64)]));
  const settings={...common,toolTrial:trial,pilotStorageAccess:trialPilotAccess(trial,pilot),
    mutationAdmission:pilot,intakeControl:new IntakeControl(db,()=>now),requireIntakeControl:true,
    globalActiveBytesLimit:3221225472,requireGlobalAdmissionLimit:true,
    ownerRecovery:{copyCurrent:copy} as unknown as OwnerRecoveryCopy,requireOwnerRecovery:true};
  seal.mockClear();open.mockClear();photo.mockClear();copy.mockClear();
  return {trial,auth,authOptions,identity,session,oldID,settings,archive:new ArchiveStore(settings),seal,photo,copy,
    now:()=>now,setNow:(value:number)=>{now=value;}};
}
async function piece(snapshotId=crypto.randomUUID(),path='CareHandoff/plan.json',data='{}') {
  const part={snapshotId,kind:'json' as const,path,part:0,count:1,sha256:await sha256(data),payload:btoa(data)};
  const document={...legacy,formatVersion:3 as const,text:'ツールの保存データ',writtenAt:new Date(base).toISOString(),
    updatedAt:new Date(base).toISOString(),toolBackup:part};
  return {id:crypto.randomUUID(),part,contentBytes:data.length,
    request:{document,photoBase64:null,expectedRevision:null,consentVersion:'managed-preservation-v1'}};
}
async function index(pieces:Awaited<ReturnType<typeof piece>>[]) {
  const first=pieces[0]!;
  const snapshotId=first.part.snapshotId;
  const bytes=JSON.stringify({version:1,snapshotID:snapshotId.toUpperCase(),createdAt:1,
    files:pieces.map(p=>({path:p.part.path,bytes:p.contentBytes,sha256:p.part.sha256,records:[p.id.toUpperCase()]}))});
  return {id:snapshotId,request:{...first.request,document:{...first.request.document,text:'ツールの保存',
    toolBackup:{snapshotId,kind:'index',path:'index.json',part:0,count:1,sha256:await sha256(bytes),payload:btoa(bytes)}}}};
}
it('resumes an admitted uncommitted piece when only JSON property order changed',async()=>{
  const f=await fixture(), p=await piece();
  const first=await f.trial.admit(f.session.ownerId,p.id,p.request);
  const reordered=Object.fromEntries(Object.entries(p.part).reverse());
  const resumed=await f.trial.admit(f.session.ownerId,p.id,{...p.request,
    document:{...p.request.document,toolBackup:reordered}});
  expect(resumed?.fingerprint).toBe(first?.fingerprint);
});
async function photoPiece() {
  const p=await piece(),raw=new Uint8Array([255,216,255,217]);
  const part={...p.part,kind:'photo' as const,path:`ShowcasePhotos/${crypto.randomUUID()}.jpg`,
    sha256:await sha256(raw),payload:''};
  return {...p,part,contentBytes:raw.length,request:{...p.request,photoBase64:btoa(String.fromCharCode(...raw)),
    document:{...p.request.document,photoFile:'photo.jpg' as const,toolBackup:part}}};
}
async function seedLegacySlot(f:Awaited<ReturnType<typeof fixture>>,p:Awaited<ReturnType<typeof photoPiece>>|Awaited<ReturnType<typeof piece>>) {
  // Pre-fix admission stored the exact validated wire order, before providers.
  const fingerprint=await sha256(JSON.stringify({document:validateDocument(p.request.document),
    photoSHA256:p.part.kind==='photo' ? p.part.sha256 : null}));
  await db.prepare('UPDATE pa_tool_owner_trials SET snapshot_id=?,attempts=1,admitted_bytes=? WHERE owner_id=?')
    .bind(p.part.snapshotId,TRIAL_DOCUMENT_ALLOWANCE+p.contentBytes,f.session.ownerId).run();
  await db.prepare(`INSERT INTO pa_tool_trial_records(owner_id,record_id,snapshot_id,kind,path,part,part_count,
    payload_sha256,input_fingerprint,content_bytes) VALUES(?,?,?,?,?,?,?,?,?,?)`)
    .bind(f.session.ownerId,p.id,p.part.snapshotId,p.part.kind,p.part.path,p.part.part,p.part.count,
      p.part.sha256,fingerprint,p.contentBytes).run();
  return fingerprint;
}
it('recovers a legacy interrupted photo and its lost ACK without changing its fingerprint or refunding debt',async()=>{
  const f=await fixture(),p=await photoPiece();
  p.request.document.text='猫'.repeat(400);
  // Last permutation forces the bounded worst-case compatibility search.
  p.request.document.toolBackup=Object.fromEntries(Object.entries(p.part).reverse()) as typeof p.part;
  const fingerprint=await seedLegacySlot(f,p);
  const changedOrder={...p.request,document:{...p.request.document,toolBackup:p.part}};
  const started=performance.now();
  await f.archive.put(f.session.token,p.id,changedOrder);
  const elapsed=performance.now()-started;
  expect(elapsed).toBeLessThan(10000);
  console.info(`Legacy photo full-order search and synthetic commit: ${elapsed.toFixed(0)} ms`);
  const before=(await f.trial.grant(f.session.ownerId))!;
  const saved=await db.prepare('SELECT input_fingerprint,committed FROM pa_tool_trial_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId,p.id).first();
  expect(saved).toEqual({input_fingerprint:fingerprint,committed:1});
  f.seal.mockClear();f.photo.mockClear();f.copy.mockClear();
  await f.archive.put(f.session.token,p.id,changedOrder);
  expect(f.seal).not.toHaveBeenCalled();expect(f.photo).not.toHaveBeenCalled();
  // Session access still refreshes owner recovery; no photo encryption or new revision occurs.
  expect((await f.archive.read(f.session.token,p.id)).revision).toBe(1);
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(before.attempts+1);
  expect((await f.trial.grant(f.session.ownerId))?.admitted_bytes).toBe(before.admitted_bytes+TRIAL_DOCUMENT_ALLOWANCE+p.contentBytes);
  expect((await f.archive.read(f.session.token,p.id)).document.toolBackup).toEqual(p.part);
});
it('keeps legacy JSON exact-order retries without searching permutations of JSON payloads',async()=>{
  const f=await fixture(),p=await piece();
  p.request.document.toolBackup=Object.fromEntries(Object.entries(p.part).reverse()) as typeof p.part;
  const fingerprint=await seedLegacySlot(f,p);
  expect((await f.trial.admit(f.session.ownerId,p.id,p.request))?.fingerprint).toBe(fingerprint);
  const digest=vi.spyOn(crypto.subtle,'digest');
  try {
    await expect(f.trial.admit(f.session.ownerId,p.id,{...p.request,document:{...p.request.document,toolBackup:p.part}}))
      .rejects.toMatchObject({code:'PILOT_WRITES_PAUSED'});
    expect(digest.mock.calls.length).toBeLessThanOrEqual(3);
  } finally { digest.mockRestore(); }
});
it('does not let legacy photo order compatibility change document content, photo bytes, tags, or owner',async()=>{
  const f=await fixture(),p=await photoPiece();
  p.request.document.toolBackup=Object.fromEntries(Object.entries(p.part).reverse()) as typeof p.part;
  const fingerprint=await seedLegacySlot(f,p);
  for (const change of [{text:'changed'}, {writtenAt:new Date(base+1000).toISOString()},
    {updatedAt:new Date(base+1000).toISOString()}, {capturedAt:new Date(base).toISOString()}, {catNames:['different']}]) {
    await expect(f.archive.put(f.session.token,p.id,{...p.request,document:{...p.request.document,...change,toolBackup:p.part}}))
      .rejects.toMatchObject({code:'PILOT_WRITES_PAUSED'});
  }
  for (const change of [{path:`ShowcasePhotos/${crypto.randomUUID()}.jpg`},{snapshotId:crypto.randomUUID()}]) {
    await expect(f.archive.put(f.session.token,p.id,{...p.request,document:{...p.request.document,toolBackup:{...p.part,...change}}}))
      .rejects.toMatchObject({code:'PILOT_WRITES_PAUSED'});
  }
  const bytes=new Uint8Array([255,216,255,218]);
  await expect(f.archive.put(f.session.token,p.id,{...p.request,photoBase64:btoa(String.fromCharCode(...bytes)),
    document:{...p.request.document,toolBackup:{...p.part,sha256:await sha256(bytes)}}}))
    .rejects.toMatchObject({code:'PILOT_WRITES_PAUSED'});
  const other=await fixture();
  // Another owner's new slot cannot borrow this owner's immutable fingerprint.
  const admitted=await other.trial.admit(other.session.ownerId,p.id,{...p.request,document:{...p.request.document,toolBackup:p.part}});
  expect(admitted?.fingerprint).not.toBe(fingerprint);
  expect(f.seal).not.toHaveBeenCalled();expect(f.photo).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();
  expect(await db.prepare('SELECT input_fingerprint,committed FROM pa_tool_trial_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId,p.id).first()).toEqual({input_fingerprint:fingerprint,committed:0});
});
it('binds the native wire snapshot tag once, completes its index last and retains old records/GET after expiry',async()=>{
  const f=await fixture(),p=await piece(),p2=await piece(p.part.snapshotId,'LostCatDrafts/drafts.json');
  expect(p.id).not.toBe(p.part.snapshotId);
  const usage=await f.archive.usage(f.session.token);
  expect(usage.toolSnapshots.maximumIndexVersion).toBe(3);
  expect(usage.storage.availableBytes).toBe(20*1024*1024-20*TRIAL_DOCUMENT_ALLOWANCE-TRIAL_INDEX_ALLOWANCE);
  expect(usage.storage.availableBytes).toBe(usage.storage.limitBytes-usage.storage.usedBytes-usage.storage.reservedBytes);
  expect(usage.records.maximumRecords).toBe(21);
  expect(usage.records.creationLimitReached).toBe(false);
  const membership=new MembershipLinks({db,auth:f.auth,authority:{} as never,audience:'neko-preservation-staging',
    now:f.now,pilotStorageAccess:trialPilotAccess(f.trial,new PilotControl(db,f.now,'YES','[]'))});
  const access=await membership.forSession(f.session.token);
  expect(access).toEqual({linked:false,status:'unknown',access:'pilot',pilotEndsAt:base+86400000});
  await f.archive.put(f.session.token,p.id,p.request);
  expect((await f.trial.grant(f.session.ownerId))?.snapshot_id).toBe(p.part.snapshotId);
  await f.archive.put(f.session.token,p2.id,p2.request);
  const admitted=await f.trial.admit(f.session.ownerId,p.id,p.request);
  const done=await index([p,p2]);await f.archive.put(f.session.token,done.id,done.request);
  expect((await f.trial.grant(f.session.ownerId))?.completed_at).toBe(base);
  const closed=f.trial.fence(admitted!);
  expect(await db.prepare(`SELECT 1 WHERE ${closed.sql}`).bind(...closed.bindings).first()).toBeNull();
  expect((await membership.forSession(f.session.token)).access).toBe('pilot'); // Lost final response can resume.
  expect((await f.archive.usage(f.session.token)).storage.availableBytes).toBe(0);
  const before=(await f.trial.grant(f.session.ownerId))!;
  await f.archive.put(f.session.token,done.id,done.request); // Stable retry is debited too.
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(before.attempts+1);
  const extra=await piece(p.part.snapshotId,'VeterinaryVisits/state.json');
  await expect(f.archive.put(f.session.token,extra.id,extra.request)).rejects.toThrow();
  expect((await f.archive.read(f.session.token,f.oldID)).document).toEqual(legacy);
  f.setNow(base+86400000);
  const renewed=await f.auth.establish(f.identity);
  expect(await membership.forSession(renewed.token)).toEqual({linked:false,status:'unknown'});
  expect((await f.archive.read(renewed.token,done.id)).document.toolBackup?.snapshotId).toBe(p.part.snapshotId);
  await expect(f.archive.put(renewed.token,p.id,p.request)).rejects.toMatchObject({code:'PILOT_WRITES_PAUSED'});
});
it('charges actual HTTP 429 retries before rejected body decoding or any provider',async()=>{
  const f=await fixture(),p=await piece();
  await bucket.put('__owner_deletion/v1/format.json','{"version":1}');
  const wrap=vi.fn(),unwrap=vi.fn();
  const environment={DB:db,ARCHIVE:bucket,PRESERVATION_ENABLED:'YES',ENVIRONMENT:'staging',PILOT_MODE:'YES',
    PILOT_STORAGE_ACCESS_ENABLED:'YES',PILOT_REGISTRATION_ENABLED:'YES',PILOT_IDENTITY_KEYS_JSON:JSON.stringify(['a'.repeat(64)]),
    IDENTITY_INDEX_SECRET:randomToken(),APPLE_CREDENTIALS_JSON:JSON.stringify({teamId:'synthetic',keyId:'synthetic',clientId:'synthetic',privateKey:'synthetic'}),
    PRESERVATION_LINK_AUDIENCE:'neko-preservation-staging',REQUEST_LIMITER:{limit:async()=>({success:false})},
    KEY_WRAPPER:{wrap,unwrap},KEY_WRAPPER_CALLER_SECRET:randomToken(),PHOTO_VALIDATOR:{validateJPEG:vi.fn()},MEMBERSHIP_AUTHORITY:{},
    OWNER_QUOTA_BYTES:'1073741824',MAXIMUM_RECORDS:'200'} as unknown as Env;
  // The normal route requires this policy before work; rate denial must not touch it.
  const clock=vi.spyOn(Date,'now').mockReturnValue(base);
  try { for(let n=0;n<2;n++) {
    const response=await worker.fetch(new Request(`https://local/v1/records/${p.id}`,{method:'PUT',
      headers:{authorization:`Bearer ${f.session.token}`,'CF-Connecting-IP':'192.0.2.1'},body:JSON.stringify(p.request)}),environment);
    expect(response.status).toBe(429);
  } } finally { clock.mockRestore(); }
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(2);
  expect((await f.trial.grant(f.session.ownerId))?.admitted_bytes).toBe(2*TRIAL_DOCUMENT_ALLOWANCE);
  expect((await f.trial.grant(f.session.ownerId))?.snapshot_id).toBeNull();
  expect(wrap).not.toHaveBeenCalled();expect(unwrap).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();
});
it('charges authenticated HTTP body/queue/UUID rejection once and a valid upload only through normal admission',async()=>{
  const f=await fixture(),p=await piece();
  const services={auth:f.auth,archive:f.archive,verifier:{} as never,toolTrial:f.trial};
  const headers={authorization:`Bearer ${f.session.token}`,'content-type':'application/json'};
  const malformed=new Request(`https://local/v1/records/${p.id}`,{method:'PUT',headers,body:'{'});
  await expect(route(malformed,services)).rejects.toMatchObject({code:'INVALID_REQUEST'});
  const contentType=new Request(`https://local/v1/records/${p.id}`,{method:'PUT',
    headers:{authorization:headers.authorization,'content-type':'text/plain'},body:'{}'});
  await expect(route(contentType,services)).rejects.toMatchObject({code:'INVALID_REQUEST'});
  const badID=new Request('https://local/v1/records/a',{method:'PUT',headers,body:JSON.stringify(p.request)});
  await expect(route(badID,services)).rejects.toThrow();
  const oversized=new Request(`https://local/v1/records/${p.id}`,{method:'PUT',headers,
    body:new Uint8Array(29*1024*1024+1)});
  await expect(route(oversized,services)).rejects.toMatchObject({code:'REQUEST_TOO_LARGE'});
  const controller=new AbortController();controller.abort();
  const aborted=new Request(`https://local/v1/records/${p.id}`,{method:'PUT',headers,body:'{}',signal:controller.signal});
  await expect(route(aborted,services)).rejects.toMatchObject({code:'PRESERVATION_BUSY'});
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(5);
  expect((await f.trial.grant(f.session.ownerId))?.admitted_bytes).toBe(5*TRIAL_DOCUMENT_ALLOWANCE);
  expect((await f.trial.grant(f.session.ownerId))?.snapshot_id).toBeNull();
  expect(f.seal).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();expect(f.photo).not.toHaveBeenCalled();
  const invalidSession=new Request(`https://local/v1/records/${p.id}`,{method:'PUT',
    headers:{...headers,authorization:`Bearer ${randomToken()}`},body:'{'});
  await expect(route(invalidSession,services)).rejects.toMatchObject({code:'unauthorized'});
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(5);
  await route(new Request(`https://local/v1/records/${p.id}`,{method:'PUT',headers,body:JSON.stringify(p.request)}),services);
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(6);
  expect((await f.trial.grant(f.session.ownerId))?.admitted_bytes).toBe(6*TRIAL_DOCUMENT_ALLOWANCE+p.contentBytes);
});
it('keeps failed provider debit and slot debt; retry cannot restore lifetime capacity',async()=>{
  const f=await fixture(),p=await piece();
  const fail=new ArchiveStore({...f.settings,ownerRecovery:{copyCurrent:async()=>{throw Error('synthetic outage');}} as unknown as OwnerRecoveryCopy});
  await expect(fail.put(f.session.token,p.id,p.request)).rejects.toThrow();
  const spent=(await f.trial.grant(f.session.ownerId))!;
  expect(spent.attempts).toBe(1);expect(spent.admitted_bytes).toBe(TRIAL_DOCUMENT_ALLOWANCE+p.contentBytes);
  expect((await db.prepare('SELECT count(*) AS n FROM pa_tool_trial_records WHERE owner_id=?').bind(f.session.ownerId).first<{n:number}>())?.n).toBe(1);
  await f.archive.put(f.session.token,p.id,p.request);
  const retried=(await f.trial.grant(f.session.ownerId))!;
  expect(retried.attempts).toBe(2);expect(retried.admitted_bytes).toBe(2*spent.admitted_bytes);
});
it('consumes a known trial attempt before local recovery configuration or write policy rejection',async()=>{
  const f=await fixture(),p=await piece();
  const {ownerRecovery:_unused,...withoutRecovery}=f.settings;
  const missingRecovery=new ArchiveStore(withoutRecovery);
  await expect(missingRecovery.put(f.session.token,p.id,p.request)).rejects.toThrow();
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(1);
  expect((await f.trial.grant(f.session.ownerId))?.admitted_bytes).toBe(TRIAL_DOCUMENT_ALLOWANCE+p.contentBytes);
  const stoppedPolicy=new ArchiveStore({...f.settings,requireRecovery:true,recovery:{} as never});
  await expect(stoppedPolicy.put(f.session.token,p.id,p.request)).rejects.toMatchObject({code:'RECOVERY_POLICY_INACTIVE'});
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(2);
  expect(f.seal).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();expect(f.photo).not.toHaveBeenCalled();
});
it('charges malformed, wrong-snapshot, duplicate and rate-denied attempts without providers or refunds across midnight/review',async()=>{
  const f=await fixture({attempts:5}),p=await piece();
  await expect(f.archive.put(f.session.token,p.id,{bad:true})).rejects.toThrow();
  expect(f.seal).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();expect(f.photo).not.toHaveBeenCalled();
  expect((await f.trial.grant(f.session.ownerId))?.snapshot_id).toBeNull();
  await f.archive.put(f.session.token,p.id,p.request);
  await f.archive.put(f.session.token,p.id,p.request);
  const other=await piece();f.seal.mockClear();f.copy.mockClear();
  await expect(f.archive.put(f.session.token,other.id,other.request)).rejects.toThrow();
  expect(f.seal).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();
  const spent=(await f.trial.grant(f.session.ownerId))!;
  f.setNow(base+120000);
  await db.prepare(`UPDATE pa_tool_owner_trials SET reviewed_at=?,review_revision=review_revision+1,
    cost_evidence_sha256=? WHERE owner_id=?`).bind(f.now(),'c'.repeat(64),f.session.ownerId).run();
  await f.trial.deniedAttempt(f.session.ownerId);
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(5);
  expect((await f.trial.grant(f.session.ownerId))!.admitted_bytes).toBeGreaterThan(spent.admitted_bytes);
  await expect(f.trial.admit(f.session.ownerId,p.id,p.request)).rejects.toThrow();
  await expect(db.prepare('UPDATE pa_tool_owner_trials SET attempts=0 WHERE owner_id=?').bind(f.session.ownerId).run()).rejects.toThrow();
  await expect(db.prepare('DELETE FROM pa_tool_owner_trials WHERE owner_id=?').bind(f.session.ownerId).run()).rejects.toThrow();
});
it('rejects old-record writes, payload overflow and missing/disabled/changed owner before any KMS/S3/JPEG',async()=>{
  const f=await fixture({bytes:TRIAL_DOCUMENT_ALLOWANCE+1}),p=await piece();
  await expect(f.archive.put(f.session.token,p.id,p.request)).rejects.toThrow();
  expect(f.seal).not.toHaveBeenCalled();expect(f.copy).not.toHaveBeenCalled();expect(f.photo).not.toHaveBeenCalled();
  const g=await fixture(),q=await piece();
  await expect(g.archive.put(g.session.token,g.oldID,q.request)).rejects.toThrow();
  await expect(g.archive.put(g.session.token,g.oldID,{...q.request,expectedRevision:1})).rejects.toThrow();
  expect(g.seal).not.toHaveBeenCalled();expect(g.copy).not.toHaveBeenCalled();
  await db.prepare('UPDATE pa_tool_owner_trials SET enabled=0,review_revision=review_revision+1 WHERE owner_id=?').bind(g.session.ownerId).run();
  await expect(g.trial.admit(g.session.ownerId,q.id,q.request)).rejects.toThrow();
  await expect(db.prepare(`INSERT INTO pa_tool_owner_trials(owner_id,owner_epoch,starts_at,ends_at,reviewed_at,
    valid_until,cost_evidence_sha256,byte_limit,attempt_limit,record_limit) VALUES(?,0,1,2,1,2,?,10,1,2)`)
    .bind(crypto.randomUUID(),'a'.repeat(64)).run()).rejects.toThrow();
});
it('serializes first binding and record slots; an index cannot overtake a newly admitted piece',async()=>{
  const f=await fixture({records:2}),a=await piece(),b=await piece();
  const raced=await Promise.allSettled([f.trial.admit(f.session.ownerId,a.id,a.request),f.trial.admit(f.session.ownerId,b.id,b.request)]);
  expect(raced.filter(x=>x.status==='fulfilled')).toHaveLength(1);
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(2);
  const winner=(await f.trial.grant(f.session.ownerId))!.snapshot_id;
  expect([a.part.snapshotId,b.part.snapshotId]).toContain(winner);
  const g=await fixture(),p=await piece();await g.archive.put(g.session.token,p.id,p.request);
  const done=await index([p]);
  let newAdmission:Awaited<ReturnType<ToolOwnerTrial['admit']>>;
  const late=await piece(p.part.snapshotId,'LostCatDrafts/drafts.json');
  const options={...g.settings,ownerRecovery:{copyCurrent:vi.fn(async()=>{
    newAdmission=await g.trial.admit(g.session.ownerId,late.id,late.request);return {};
  })} as unknown as OwnerRecoveryCopy};
  await expect(new ArchiveStore(options).put(g.session.token,done.id,done.request)).rejects.toThrow();
  expect((await g.trial.grant(g.session.ownerId))?.completed_at).toBeNull();
  expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(g.session.ownerId,done.id).first()).toBeNull();
  expect(newAdmission!).toBeTruthy();
});
it('rechecks expiration and review at reservation/atomic commit after provider work; no old data changes',async()=>{
  const f=await fixture({duration:1000}),p=await piece();
  const options={...f.settings,photos:{validateJPEG:async()=>true},keys:{...f.settings.keys,
    seal:async(value:Uint8Array)=>{f.setNow(base+1000);return value.slice();}}};
  await expect(new ArchiveStore(options).put(f.session.token,p.id,p.request)).rejects.toThrow();
  expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,p.id).first()).toBeNull();
  expect((await f.trial.grant(f.session.ownerId))?.attempts).toBe(1);
  expect((await f.archive.read(f.session.token,f.oldID)).document).toEqual(legacy);
  const g=await fixture(),q=await piece();
  const change={...g.settings,keys:{...g.settings.keys,seal:async(value:Uint8Array)=>{
    await db.prepare(`UPDATE pa_tool_owner_trials SET review_revision=review_revision+1,cost_evidence_sha256=? WHERE owner_id=?`)
      .bind('d'.repeat(64),g.session.ownerId).run();return value.slice();}}};
  await expect(new ArchiveStore(change).put(g.session.token,q.id,q.request)).rejects.toThrow();
  expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(g.session.ownerId,q.id).first()).toBeNull();
});
it('rejects an expired atomic commit after R2 accepted a photo, preserving debit/slot and old records',async()=>{
  const f=await fixture({duration:1000}),p=await piece();
  const raw=new Uint8Array([255,216,255,217]);
  const request={...p.request,photoBase64:btoa(String.fromCharCode(...raw)),document:{...p.request.document,
    photoFile:'photo.jpg',toolBackup:{...p.part,kind:'photo',path:`ShowcasePhotos/${crypto.randomUUID()}.jpg`,
      sha256:await sha256(raw),payload:''}}};
  let wrote=false;
  const raced=new Proxy(bucket,{get(target,key){
    if(key==='put')return async (...args:Parameters<R2Bucket['put']>)=>{
      const stored=await target.put(...args);wrote=true;f.setNow(base+1000);return stored;
    };
    const value=Reflect.get(target,key);
    return typeof value==='function' ? value.bind(target) : value;
  }});
  await expect(new ArchiveStore({...f.settings,bucket:raced}).put(f.session.token,p.id,request)).rejects.toThrow();
  expect(wrote).toBe(true);
  expect(await db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,p.id).first()).toBeNull();
  expect((await f.trial.grant(f.session.ownerId))?.admitted_bytes).toBe(TRIAL_DOCUMENT_ALLOWANCE+raw.length);
  expect((await db.prepare('SELECT committed FROM pa_tool_trial_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId,p.id).first<{committed:number}>())?.committed).toBe(0);
  expect((await f.archive.read(f.session.token,f.oldID)).document).toEqual(legacy);
});
it('never admits a new Apple owner after issuance, preserves existing login, and supports authorized account erasure',async()=>{
  const f=await fixture(),p=await piece();await f.archive.put(f.session.token,p.id,p.request);
  const creator=vi.fn(async()=>{});
  const auth=new DurableAuth({...f.authOptions,ownerAdmission:trialOwnerAdmission(f.trial,{createOwner:creator})});
  await expect(auth.establish({...f.identity,subject:crypto.randomUUID()})).rejects.toThrow();
  expect(creator).not.toHaveBeenCalled();await expect(auth.establish(f.identity)).resolves.toMatchObject({ownerId:f.session.ownerId});
  await bucket.put('__owner_deletion/v1/format.json','{"version":1}');
  const journal=new OwnerDeletionJournal(bucket),requests=new OwnerDeletionRequests({db,journal,auth:f.auth,now:f.now});
  const receipt=randomToken();await requests.request(f.session.token,receipt);
  const executor=new OwnerDeletionExecutor({enabled:true,db,bucket,journal,now:f.now,keys:f.settings.keys,
    recovery:{listOwnerVersionsPage:async()=>({versions:[],nextCursor:null})} as unknown as S3RecoveryCopy,
    revokeRefreshToken:async()=>{},versionPurge:{requestExactVersionDeletion:async()=>{}}});
  let done=false;
  for(let n=0;n<60;n++)if(await executor.step(f.session.ownerId)==='completed'){done=true;break;}
  expect(done).toBe(true);
  expect((await inspectOwnerD1Residue(db,f.session.ownerId)).contentTotal).toBe(0);
});
