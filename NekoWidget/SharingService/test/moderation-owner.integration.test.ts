import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fixture, type Fixture } from "./fixtures/moderation-operator";
import { routeLocalModerationOwner, type LocalModerationOwnerEnvironment, type LocalOwnerReviewHost } from "../src/moderation-owner-local";
import { routeLocalModerationOperatorTriage } from "../src/moderation-operator-triage-local";
import { runDurableModerationAdvisory } from "../src/moderation-ai-durable";
import { ownerAssertionPayload } from "../src/moderation-owner-browser";
import { base64urlDecode } from "../src/encoding";

const db = (env as unknown as { DB: D1Database }).DB;
beforeEach(async () => { await reset(); await applyD1Migrations(db, (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS); });
const image = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
// Only the trusted transport seam is synthetic here; Access and WebAuthn use
// real signatures and D1 executes all current source/policy/transaction guards.
// Canonical JPEG and actual crypto/render evidence are recorded separately.
const host: LocalOwnerReviewHost = async input => {
  await input.audit("started"); await input.readCurrentSource();
  await input.audit("disclosure_ready"); await input.readCurrentSource();
  return image.slice();
};
async function owner() {
  const f = await fixture();
  await policy(f);
  const local: LocalModerationOwnerEnvironment = { ...f.local, reviewEvidence: host };
  return { ...f, local, path: `/operator/owner/v1/cases/${f.caseReference}/1` };
}
async function policy(f: Fixture) {
  await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
    SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
      COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
    FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
    WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(f.operatorId, f.operatorId).run();
}
type Owner = Awaited<ReturnType<typeof owner>>;
interface Issued { challenge: string; challengeId: string; assertionPath: string; sourceSHA256: string }
async function issue(f: Owner, path: string): Promise<Issued> {
  const response = await routeLocalModerationOwner(f.request(path,"POST"), f.local);
  expect(response.status, await response.clone().text()).toBe(202);
  return response.json();
}
async function sign(f: Owner, issued: Issued, counter: number, invalidSignature = false) {
  return routeLocalModerationOwner(f.request(issued.assertionPath,"POST",await f.assertion(issued.challenge,{ counter, invalidSignature })),f.local);
}
async function read(f: Owner) {
  const issued = await issue(f, f.path+'/content-read');
  const response = await sign(f, issued, 1);
  expect(response.status, response.status===200?'':await response.clone().text()).toBe(200);
  expect(new Uint8Array(await response.arrayBuffer())).toEqual(image);
  return { issued, receipt: response.headers.get('X-Moderation-Read-Receipt')! };
}
async function count(table: string) { return (await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{n:number}>())!.n; }

describe('local signed owner review and reply draft', () => {
  it('does not infer owner content permission from an admitted triage role',async()=>{
    const f=await fixture();
    const path=`/operator/owner/v1/cases/${f.caseReference}/1/content-read`;
    expect((await routeLocalModerationOwner(f.request(path,'POST'),{...f.local,reviewEvidence:host})).status).toBe(403);
    expect(await count('moderation_owner_challenges')).toBe(0);
  });
  it('authenticates, consumes one read, and atomically saves the same-source decision and reporter reply draft',async()=>{
    const f=await owner();
    await runDurableModerationAdvisory(db,{caseReferenceHmac:f.caseReference,caseReferenceHmacKeyVersion:1},{safetyRoute:'unreviewed'},{apiKey:'unused-local'});
    const opened=await read(f);
    expect(await count('moderation_owner_read_claims')).toBe(1);
    expect(await count('moderation_owner_read_receipts')).toBe(1);
    const decision=await issue(f,f.path+'/decisions/no-action/'+opened.receipt);
    expect(decision.sourceSHA256).toBe(opened.issued.sourceSHA256);
    const result=await sign(f,decision,2);
    expect(result.status,await result.clone().text()).toBe(200);
    expect(await result.json()).toMatchObject({caseReferenceHmac:f.caseReference,outcome:'no_action',reply:'draft_saved',sent:false});
    const outbox=await db.prepare(`SELECT o.*,r.reporter_participant_id FROM moderation_owner_reply_outbox o JOIN moment_reports r ON r.id=o.report_id`).first();
    expect(outbox!.recipient_participant_id).toBe(outbox!.reporter_participant_id);
    expect(outbox!.template_code).toBe('review_no_action_v1');
    expect(await count('moderation_owner_decisions')).toBe(1);
    expect(await count('moderation_advisory_jobs')).toBe(0);
    expect(await count('moderation_advisory_live_sources')).toBe(0);
    const queue=await routeLocalModerationOperatorTriage(f.request('/operator/v1/cases/read','POST'),f.local);
    expect(await queue.json()).toMatchObject({cases:[]});
    expect((await routeLocalModerationOwner(f.request(f.path+'/content-read','POST'),f.local)).status).toBe(409);
    expect(await count('moderation_operator_actions')).toBe(0);
  });
  it('burns a bad proof before verification and refuses its reuse',async()=>{
    const f=await owner(),issued=await issue(f,f.path+'/content-read');
    expect((await sign(f,issued,1,true)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_assertion_attempts')).toBe(1);
    expect(await count('moderation_owner_challenge_consumptions')).toBe(0);
    expect((await sign(f,issued,1)).status).toBe(409);
  });
  it('passes the actual browser serializer output through the real assertion verifier',async()=>{
    const f=await owner(),issued=await issue(f,f.path+'/content-read');
    const signed=JSON.parse(await f.assertion(issued.challenge)) as {id:string;rawId:string;type:string;response:{clientDataJSON:string;authenticatorData:string;signature:string}};
    const bytes=(value:string)=>new Uint8Array(base64urlDecode(value)).buffer;
    const proof=ownerAssertionPayload({id:signed.id,rawId:bytes(signed.rawId),type:signed.type,
      authenticatorAttachment:null,getClientExtensionResults:()=>({}),response:{
        clientDataJSON:bytes(signed.response.clientDataJSON),authenticatorData:bytes(signed.response.authenticatorData),
        signature:bytes(signed.response.signature),userHandle:new Uint8Array([1,2,3]).buffer}});
    expect(proof).not.toHaveProperty('authenticatorAttachment');
    expect(proof.response).not.toHaveProperty('userHandle');
    const result=await routeLocalModerationOwner(f.request(issued.assertionPath,'POST',JSON.stringify(proof)),f.local);
    expect(result.status, result.status===200?'':await result.text()).toBe(200);
  });
  it('refuses replay after a successful image delivery without calling the host again',async()=>{
    const f=await owner();let calls=0;
    f.local.reviewEvidence=async input=>{calls++;return host(input)};
    const opened=await read(f);
    expect((await sign(f,opened.issued,2)).status).toBe(409);
    expect(calls).toBe(1);
  });
  it('times out a stalled host, wipes its late image, and never retries the consumed read',async()=>{
    const f=await owner(),issued=await issue(f,f.path+'/content-read');
    const proof=await f.assertion(issued.challenge,{counter:1});
    const lateImage=image.slice();
    let release!: (value:Uint8Array)=>void;
    const delayed=new Promise<Uint8Array>(resolve=>{release=resolve});
    let ready!: ()=>void;
    const hostReady=new Promise<void>(resolve=>{ready=resolve});
    let signal:AbortSignal|undefined,calls=0;
    f.local.reviewEvidence=async input=>{
      calls++;signal=input.signal;
      // Start the local clock only after the real Access/signature/claim DB
      // chain. The handler schedules its host deadline after this invocation.
      vi.useFakeTimers({toFake:['Date','setTimeout','clearTimeout']});
      await input.audit('started');ready();
      return delayed;
    };
    try{
      const pending=routeLocalModerationOwner(f.request(issued.assertionPath,'POST',proof),f.local);
      await Promise.race([hostReady,pending.then(()=>{throw Error('request ended before the stalled host')})]);
      await vi.advanceTimersByTimeAsync(60_000);
      const response=await pending;
      expect(response.status).toBe(503);
      expect(response.headers.get('X-Moderation-Read-Receipt')).toBeNull();
      expect(signal?.aborted).toBe(true);
      // SQLite time/transactions are not simulated. This checks a stalled host,
      // not cancellation or rollback of a D1 batch already sent for execution.
      vi.useRealTimers();
      expect(await count('moderation_owner_read_claims')).toBe(1);
      expect(await count('moderation_owner_read_receipts')).toBe(0);
      release(lateImage);
      await vi.waitFor(()=>expect(lateImage).toEqual(new Uint8Array(image.length)),{timeout:1_000,interval:5});
      expect(await count('moderation_owner_read_receipts')).toBe(0);
      const replay=await routeLocalModerationOwner(f.request(issued.assertionPath,'POST',proof),f.local);
      expect(replay.status).toBe(409);
      expect(calls).toBe(1);
      expect(await count('moderation_owner_assertion_attempts')).toBe(1);
      expect(await count('moderation_owner_challenge_consumptions')).toBe(1);
      expect(await count('moderation_owner_read_claims')).toBe(1);
    }finally{vi.useRealTimers();release(lateImage)}
  });
  it('refuses another Access session even for the same owner',async()=>{
    const f=await owner(),issued=await issue(f,f.path+'/content-read');
    const request=f.request(issued.assertionPath,'POST',await f.assertion(issued.challenge),{'Cf-Access-Jwt-Assertion':await f.sessionToken(600)});
    expect((await routeLocalModerationOwner(request,f.local)).status).toBe(409);
    expect(await count('moderation_owner_assertion_attempts')).toBe(0);
  });
  it('keeps a failed disclosure consumed when policy is revoked before release',async()=>{
    const f=await owner();f.local.reviewEvidence=async input=>{
      await input.audit('started');
      await db.prepare('INSERT INTO moderation_owner_policy_revocations(policy_revision) VALUES (1)').run();
      await input.readCurrentSource();return image.slice();
    };
    const issued=await issue(f,f.path+'/content-read');
    expect((await sign(f,issued,1)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_read_claims')).toBe(1);
    expect(await count('moderation_owner_read_receipts')).toBe(0);
  });
  it('rechecks object identity even when ciphertext hash and expiry did not change',async()=>{
    const f=await owner();f.local.reviewEvidence=async input=>{
      await input.audit('started');
      await db.prepare("UPDATE moment_reports SET object_key='reports/replaced' WHERE id=?").bind(f.reportId).run();
      await input.readCurrentSource();return image.slice();
    };
    const issued=await issue(f,f.path+'/content-read');
    expect((await sign(f,issued,1)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_read_receipts')).toBe(0);
  });
  it('requires the trusted disclosure audit before saving a receipt',async()=>{
    const f=await owner();f.local.reviewEvidence=async()=>image.slice();
    const issued=await issue(f,f.path+'/content-read');
    expect((await sign(f,issued,1)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_read_receipts')).toBe(0);
    expect(await count('moderation_owner_read_claims')).toBe(1);
  });
  it('rolls back decision and signature consumption if reply draft persistence fails',async()=>{
    const f=await owner(),opened=await read(f);
    const issued=await issue(f,f.path+'/decisions/no-action/'+opened.receipt);
    await db.exec("CREATE TRIGGER test_owner_outbox_failure BEFORE INSERT ON moderation_owner_reply_outbox BEGIN SELECT RAISE(ABORT,'simulated outbox failure'); END;");
    expect((await sign(f,issued,2)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_decisions')).toBe(0);
    expect(await count('moderation_owner_reply_outbox')).toBe(0);
    expect(await count('moderation_owner_challenge_consumptions')).toBe(1);
    expect(await count('moderation_owner_assertion_attempts')).toBe(2);
  });
  it('cannot turn a read or unrelated receipt into a decision',async()=>{
    const f=await owner(),opened=await read(f);
    const response=await routeLocalModerationOwner(f.request(f.path+'/decisions/no-action/'+crypto.randomUUID(),'POST'),f.local);
    expect(response.status).toBeGreaterThanOrEqual(400);
    const transplanted=opened.issued.assertionPath.replace('/content-read/',`/decisions/no-action/${opened.receipt}/`);
    expect((await routeLocalModerationOwner(f.request(transplanted,'POST',await f.assertion(opened.issued.challenge,{counter:2})),f.local)).status).toBe(409);
  });
  it('refuses unsupported restrictive outcomes and request-controlled payloads or origins',async()=>{
    const f=await owner();
    for(const [path,body,headers] of [
      [f.path+'/decisions/restrict/'+crypto.randomUUID(),undefined,{}],
      [f.path+'/content-read','{"recipient":"attacker"}',{}],
      [f.path+'/content-read',undefined,{Origin:'https://foreign.invalid'}],
      [f.path+'/content-read?recipient=attacker',undefined,{}],
    ] as const)expect((await routeLocalModerationOwner(f.request(path,'POST',body,headers),f.local)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_challenges')).toBe(0);
  });
  it('stays disabled without a trusted host or outside local environment',async()=>{
    const f=await owner();
    const {reviewEvidence: _host,...withoutHost}=f.local;
    for(const config of [withoutHost,{...f.local,environment:'production'},{...f.local,runtimeEnabled:'NO'}])
      expect((await routeLocalModerationOwner(f.request(f.path+'/content-read','POST'),config)).status).toBe(503);
    expect(await count('moderation_owner_challenges')).toBe(0);
  });
  it('uses owner counters in the legacy route and keeps monotonicity in both directions',async()=>{
    const f=await owner();await read(f);
    const start=await routeLocalModerationOperatorTriage(f.request(f.operationPath,'POST'),f.local);
    expect(start.status).toBe(202);
    const issued=await start.json() as Issued;
    const rejected=await routeLocalModerationOperatorTriage(f.request(issued.assertionPath,'POST',await f.assertion(issued.challenge,{counter:1})),f.local);
    expect(rejected.status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_operator_challenge_consumptions')).toBe(0);
    const second=await issue(f,f.path+'/content-read');
    expect((await sign(f,second,1)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_owner_challenge_consumptions')).toBe(1);
  });
});
