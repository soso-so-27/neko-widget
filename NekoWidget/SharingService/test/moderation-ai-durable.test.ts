import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { runDurableModerationAdvisory, readDurableModerationAdvisory, purgeExpiredModerationAdvisories } from "../src/moderation-ai-durable";
import { base64urlEncode } from "../src/encoding";
import { deriveModerationOperatorCaseReference } from "../src/moderation-operator-case-reference";
import { MODERATION_ADVISORY_MODEL, moderationAdvisoryCategories } from "../src/moderation-ai-advisory";

const db = (env as unknown as {DB: D1Database}).DB;
beforeEach(async () => {
  await reset();
  await applyD1Migrations(db, (env as unknown as {TEST_MIGRATIONS: D1Migration[]}).TEST_MIGRATIONS);
});

const id = () => base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
const sha = () => base64urlEncode(crypto.getRandomValues(new Uint8Array(32)));
async function fixture(lifetime = 604800) {
  const space=id(), owner=id(), receiver=id(), ownerDevice=id(), receiverDevice=id(), moment=id(), report=id();
  const hmac = (await deriveModerationOperatorCaseReference({reportId:report,caseReferenceHmacKeyVersion:1},new Uint8Array(32).fill(7))).caseReferenceHmac;
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{now:number}>())!.now;
  // Synthetic encrypted report, following the real FK/admission/commit chain.
  // This does NOT claim decrypted-image screening or live operator admission.
  await db.batch([
    db.prepare("INSERT INTO moment_space_lineages(id,created_at) VALUES (?,?)").bind(space,now),
    db.prepare("INSERT INTO moment_spaces(space_id,lineage_id,state,created_at,updated_at) VALUES (?,?,'active',?,?)").bind(space,space,now,now),
    ...[owner,receiver].map((p,i)=> db.prepare("INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES (?, ?, ?, 'active',?,?)").bind(p,space,i===0?'owner':'member',now,now)),
    ...[[owner,ownerDevice],[receiver,receiverDevice]].map(([p,d])=>db.prepare("INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at) VALUES (?,?,?,?,'active',?,?)").bind(d!,p!,sha(),sha(),now,now)),
    db.prepare(`INSERT INTO moments(id,client_moment_id,space_id,sender_participant_id,sender_device_id,kind,key_epoch,state,
      object_key,ciphertext_size,ciphertext_sha256,client_moderation_version,sender_policy_version,sender_policy_accepted_at,
      quota_day_key,quota_counted,reservation_attempt,reserve_request_hash,created_at,upload_expires_at,uploaded_at,committed_at,unreceived_expires_at)
      VALUES (?,?,?,?,?,'live',1,'committed',?,32,?,1,1,?,1,0,1,?,?,?, ?,?,?)`)
      .bind(moment,crypto.randomUUID(),space,owner,ownerDevice,`moments/${moment}`,sha(),now,sha(),now,now+3600,now,now,now+604800),
    db.prepare("INSERT INTO moment_deliveries(moment_id,recipient_participant_id,state,created_at,access_expires_at) VALUES (?,?,'pending',?,?)").bind(moment,receiver,now,now+604800),
    db.prepare(`INSERT INTO moment_reports(id,moment_id,space_id,lineage_id,reporter_participant_id,reporter_device_id,
      accused_participant_id,reason_code,moderation_key_id,state,object_key,ciphertext_size,ciphertext_sha256,
      reporter_consent_version,reporter_consented_at,quota_day_key,reserve_request_hash,dedupe_key,created_at,upload_expires_at)
      VALUES (?,?,?,?,?,?,?,'privacy','moderation-v1','reserved',?,32,?,1,?,1,?,?,?,?)`)
      .bind(report,moment,space,space,receiver,receiverDevice,owner,`reports/${report}`,sha(),now,sha(),sha(),now,now+3600),
    db.prepare("UPDATE moment_reports SET state='uploaded',uploaded_at=? WHERE id=?").bind(now,report),
    db.prepare("INSERT INTO moment_report_commit_events(id,report_id,reporter_participant_id,committed_at,content_expires_at) VALUES (?,?,?,?,?)")
      .bind(crypto.randomUUID(),report,receiver,now,now+lifetime),
    db.prepare(`INSERT INTO moderation_operator_versioned_case_references(report_id,case_reference_hmac,case_reference_hmac_key_version,derivation_protocol_version,derivation_domain)
      VALUES (?,?,1,1,'NW.MODERATION-OPERATOR.CASE-REFERENCE')`).bind(report,hmac),
  ]);
  return {report, moment, expiresAt:now+lifetime, reference:{caseReferenceHmac:hmac,caseReferenceHmacKeyVersion:1}};
}
function response(flag = false) {
  return new Response(JSON.stringify({id:"modr-fixture",model:MODERATION_ADVISORY_MODEL,results:[{
    flagged:flag, categories:Object.fromEntries(moderationAdvisoryCategories.map(k=>[k,flag&&k==='violence'])),
    category_scores:Object.fromEntries(moderationAdvisoryCategories.map(k=>[k,flag&&k==='violence'?0.8:0])),
    category_applied_input_types:Object.fromEntries(moderationAdvisoryCategories.map(k=>[k,['text']])),
  }]}),{headers:{'content-type':'application/json'}});
}
const evidence = () => ({safetyRoute:'general_review' as const,text:'synthetic report text'});
const options = () => ({apiKey:'test-only-secret'});
function deferred<T>() {let resolve!:(value:T)=>void;const promise=new Promise<T>(r=>{resolve=r;});return {promise,resolve};}
async function count(table: string) {return (await db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).first<{count:number}>())!.count;}

describe("report-bound durable advisory", () => {
  it("persists only bounded advisory metadata and leaves the report/case undecided", async () => {
    const f=await fixture(); const fetch=vi.spyOn(globalThis,'fetch').mockResolvedValue(response(true));
    const result=await runDurableModerationAdvisory(db,f.reference,evidence(),options());
    expect(result).toMatchObject({state:'recorded',status:'owner_review_required',advisory:{reason:'advisory_ready',priorityHint:'raise',canCloseCase:false,canDeleteContent:false,canApproveAction:false}});
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(await readDurableModerationAdvisory(db,f.reference)).toEqual(result);
    const rows=JSON.stringify(await db.prepare('SELECT * FROM moderation_advisory_jobs JOIN moderation_advisory_results USING(job_id)').all());
    expect(rows).not.toContain(evidence().text);expect(rows).not.toContain(options().apiKey);expect(rows).not.toContain('reports/');
    expect(await count('moderation_case_events')).toBe(0);
    expect(await db.prepare('SELECT state FROM moment_reports WHERE id=?').bind(f.report).first()).toEqual({state:'committed'});
  });
  it("deduplicates both concurrent calls and a later retry, with exactly one provider request", async () => {
    const f=await fixture();const fetch=vi.spyOn(globalThis,'fetch').mockImplementation(async()=>response());
    const results=await Promise.all([1,2].map(()=>runDurableModerationAdvisory(db,f.reference,evidence(),options())));
    expect(results.some(r=>r.state==='recorded')).toBe(true);
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'recorded'});
    expect(fetch).toHaveBeenCalledTimes(1);expect(await count('moderation_advisory_jobs')).toBe(1);expect(await count('moderation_advisory_attempts')).toBe(1);
  });
  it.each(['unreviewed','child_safety_hold'] as const)("persists %s without a provider request", async safetyRoute=>{
    const f=await fixture();const fetch=vi.spyOn(globalThis,'fetch');
    expect(await runDurableModerationAdvisory(db,f.reference,{safetyRoute},options())).toMatchObject({state:'recorded',advisory:{reason:safetyRoute==='unreviewed'?'safety_route_unreviewed':'child_safety_hold',requestSHA256:null}});
    expect(fetch).not.toHaveBeenCalled();
  });
  it("keeps unknown delivery consumed even when the result write fails", async()=>{
    const f=await fixture();const fetch=vi.spyOn(globalThis,'fetch').mockResolvedValue(response());
    await db.exec("CREATE TRIGGER fixture_result_failure BEFORE INSERT ON moderation_advisory_results BEGIN SELECT RAISE(ABORT,'fixture database unavailable'); END;");
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'unavailable'});
    await db.exec("DROP TRIGGER fixture_result_failure;");
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'already_claimed'});
    expect(fetch).toHaveBeenCalledTimes(1);expect(await count('moderation_advisory_results')).toBe(0);
    await expect(db.prepare('DELETE FROM moderation_advisory_attempts').run()).rejects.toThrow();
    await expect(db.prepare('DELETE FROM moderation_advisory_jobs').run()).rejects.toThrow();
  });
  it("records provider failure for owner review and never retries it automatically", async()=>{
    const f=await fixture();const fetch=vi.spyOn(globalThis,'fetch').mockRejectedValue(new Error('private network details'));
    const first=await runDurableModerationAdvisory(db,f.reference,evidence(),options());
    expect(first).toMatchObject({state:'recorded',advisory:{reason:'provider_unavailable'}});
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toEqual(first);
    expect(fetch).toHaveBeenCalledTimes(1);expect(JSON.stringify(first)).not.toContain('private network details');
  });
  it("does not send for unknown case, wrong key version or already expired source", async()=>{
    const f=await fixture();const fetch=vi.spyOn(globalThis,'fetch');
    expect(await runDurableModerationAdvisory(db,{...f.reference,caseReferenceHmac:'f'.repeat(64)},evidence(),options())).toMatchObject({state:'stale'});
    expect(await runDurableModerationAdvisory(db,{...f.reference,caseReferenceHmacKeyVersion:2},evidence(),options())).toMatchObject({state:'stale'});
    await db.prepare('UPDATE moment_reports SET content_expires_at=unixepoch()-1 WHERE id=?').bind(f.report).run();
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'stale'});
    expect(fetch).not.toHaveBeenCalled();
  });
  it.each(['source_changed','expired','deleted'])("rejects a late result after %s",async change=>{
    const f=await fixture();const pending=deferred<Response>();const started=deferred<void>();
    vi.spyOn(globalThis,'fetch').mockImplementation(()=>{started.resolve();return pending.promise;});
    const task=runDurableModerationAdvisory(db,f.reference,evidence(),options());await started.promise;
    if(change==='source_changed')await db.prepare('UPDATE moment_reports SET ciphertext_sha256=? WHERE id=?').bind(sha(),f.report).run();
    if(change==='expired')await db.prepare("UPDATE moment_reports SET state='expired',closed_at=unixepoch() WHERE id=?").bind(f.report).run();
    if(change==='deleted')await db.prepare('DELETE FROM moment_reports WHERE id=?').bind(f.report).run();
    pending.resolve(response(true));expect(await task).toMatchObject({state:'stale'});
    expect(await count('moderation_advisory_results')).toBe(0);
    expect(await readDurableModerationAdvisory(db,f.reference)).toMatchObject({state:'stale'});
    expect(await count('moderation_cases')).toBe(1);
  });
  it("keeps reversed completion attached to its case, and rejects a superseded edition",async()=>{
    const a=await fixture(),b=await fixture();const wait=deferred<Response>(),started=deferred<void>();
    const fetch=vi.spyOn(globalThis,'fetch').mockImplementationOnce(()=>{started.resolve();return wait.promise;}).mockImplementation(async()=>response(true));
    const old=runDurableModerationAdvisory(db,a.reference,evidence(),options());await started.promise;
    const other=await runDurableModerationAdvisory(db,b.reference,evidence(),options());
    const latest=await runDurableModerationAdvisory(db,a.reference,{...evidence(),text:'new screened edition'},options());
    wait.resolve(response());expect(await old).toMatchObject({state:'stale'});
    expect(latest.advisory?.case).toMatchObject({...a.reference,evidenceVersion:2});
    expect(other.advisory?.case).toMatchObject({...b.reference,evidenceVersion:1});
    expect(await runDurableModerationAdvisory(db,a.reference,evidence(),options())).toMatchObject({state:'stale'});
    expect(fetch).toHaveBeenCalledTimes(3);
  });
  it("snapshots caller evidence before any DB/network await",async()=>{
    const f=await fixture();const input={...evidence(),jpeg:new Uint8Array([255,216,255,217])};
    const fetch=vi.spyOn(globalThis,'fetch').mockResolvedValue(response());
    const task=runDurableModerationAdvisory(db,f.reference,input,options());input.text='mutated';input.jpeg.fill(0);f.reference.caseReferenceHmac='d'.repeat(64);
    expect(await task).toMatchObject({state:'recorded'});
    const body=fetch.mock.calls[0]![1]!.body as string;
    expect(body).toContain(evidence().text);expect(body).not.toContain('mutated');expect(body).toContain('/9j/2Q==');
  });
  it("cascades derived rows when retained content is deleted, leaving the minimal receipt",async()=>{
    const f=await fixture();vi.spyOn(globalThis,'fetch').mockResolvedValue(response());
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'recorded'});
    await db.prepare('UPDATE moment_report_tombstones SET content_deleted_at=unixepoch() WHERE report_id=?').bind(f.report).run();
    for(const t of ['moderation_advisory_jobs','moderation_advisory_attempts','moderation_advisory_results'])expect(await count(t)).toBe(0);
    expect(await count('moderation_cases')).toBe(1);expect(await count('moment_report_tombstones')).toBe(1);
  });
  it("refuses result replacement and keeps deletion/review authority untouched",async()=>{
    const f=await fixture();vi.spyOn(globalThis,'fetch').mockResolvedValue(response());
    await runDurableModerationAdvisory(db,f.reference,evidence(),options());
    await expect(db.prepare("UPDATE moderation_advisory_results SET result_json='{}'").run()).rejects.toThrow();
    await expect(db.prepare('DELETE FROM moderation_advisory_results').run()).rejects.toThrow();
    await expect(db.prepare('INSERT OR REPLACE INTO moderation_advisory_results SELECT * FROM moderation_advisory_results').run()).rejects.toThrow();
    await expect(db.prepare(`INSERT OR REPLACE INTO moderation_advisory_jobs
      SELECT ?,report_id,case_reference_hmac,case_reference_hmac_key_version,evidence_version+1,evidence_sha256,
        source_sha256,source_committed_at,expires_at,safety_route,request_sha256,policy,unixepoch() FROM moderation_advisory_jobs`)
      .bind(crypto.randomUUID()).run()).rejects.toThrow();
    await expect(db.prepare("INSERT INTO moderation_case_events(report_id,event_type,outcome_code) VALUES (?,'review_decided','no_action')").bind(f.report).run()).rejects.toThrow();
    expect(await count('moderation_case_events')).toBe(0);
    expect(await purgeExpiredModerationAdvisories(db)).toBe(0);
  });
  it("hides and purges derived data at the actual DB deadline even before report cleanup runs",async()=>{
    const f=await fixture(3);vi.spyOn(globalThis,'fetch').mockResolvedValue(response());
    expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'recorded'});
    await new Promise(resolve=>setTimeout(resolve,Math.max(0,f.expiresAt*1000-Date.now()+100)));
    expect(await db.prepare('SELECT state FROM moment_reports WHERE id=?').bind(f.report).first()).toEqual({state:'committed'});
    expect(await readDurableModerationAdvisory(db,f.reference)).toMatchObject({state:'stale'});
    expect(await purgeExpiredModerationAdvisories(db)).toBe(1);
    for(const t of ['moderation_advisory_jobs','moderation_advisory_attempts','moderation_advisory_results'])expect(await count(t)).toBe(0);
    expect(await count('moderation_cases')).toBe(1);
  });
  it("rejects moving an attempt to another job and saving another case's result",async()=>{
    const a=await fixture(),b=await fixture();vi.spyOn(globalThis,'fetch').mockResolvedValue(response());
    const result=await runDurableModerationAdvisory(db,a.reference,evidence(),options());
    expect(result.state).toBe('recorded');
    await db.exec("CREATE TRIGGER fixture_pause_claim BEFORE INSERT ON moderation_advisory_attempts BEGIN SELECT RAISE(ABORT,'fixture crash before claim'); END;");
    expect(await runDurableModerationAdvisory(db,b.reference,evidence(),options())).toMatchObject({state:'unavailable'});
    await db.exec('DROP TRIGGER fixture_pause_claim;');
    expect(await readDurableModerationAdvisory(db,b.reference)).toMatchObject({state:'queued'});
    const jobB=(await db.prepare('SELECT job_id FROM moderation_advisory_current_jobs WHERE report_id=?').bind(b.report).first<{job_id:string}>())!.job_id;
    const attemptA=(await db.prepare('SELECT attempt_id FROM moderation_advisory_attempts WHERE job_id=?').bind(result.jobId!).first<{attempt_id:string}>())!.attempt_id;
    await expect(db.prepare('INSERT OR REPLACE INTO moderation_advisory_attempts(job_id,attempt_id) VALUES (?,?)').bind(jobB,attemptA).run()).rejects.toThrow();
    expect(await readDurableModerationAdvisory(db,a.reference)).toEqual(result);
    const attemptB=crypto.randomUUID();
    await db.prepare('INSERT INTO moderation_advisory_attempts(job_id,attempt_id) VALUES (?,?)').bind(jobB,attemptB).run();
    await expect(db.prepare('INSERT INTO moderation_advisory_results(job_id,attempt_id,result_json) VALUES (?,?,?)').bind(jobB,attemptB,JSON.stringify(result.advisory)).run()).rejects.toThrow();
    expect(await readDurableModerationAdvisory(db,b.reference)).toMatchObject({state:'already_claimed'});
    expect(await count('moderation_advisory_results')).toBe(1);
  });
  it.each([false,true])("keeps final readback failure private (existing claim=%s)",async existing=>{
    const f=await fixture();const fetch=vi.spyOn(globalThis,'fetch').mockImplementation(async()=>response());
    if(existing)expect(await runDurableModerationAdvisory(db,f.reference,evidence(),options())).toMatchObject({state:'recorded'});
    // All writes/admission use real D1. Only the final query fails, as a lost
    // DB connection could fail after a successful commit or losing a claim.
    const failingDB={batch:db.batch.bind(db),prepare:(sql:string)=>sql.includes('SELECT j.job_id,r.result_json')
      ? {bind:()=>({first:async()=>{throw new Error('synthetic_private_DB_error');}})}
      : db.prepare(sql)} as unknown as D1Database;
    const result=await runDurableModerationAdvisory(failingDB,f.reference,evidence(),options());
    expect(result).toEqual({state:'unavailable',status:'owner_review_required'});
    expect(fetch).toHaveBeenCalledTimes(1);expect(await count('moderation_advisory_results')).toBe(1);
  });
});
afterEach(() => vi.restoreAllMocks());

describe("durable advisory D1 assumptions", () => {
  it("rolls back the whole batch when a trigger rejects a stale result", async () => {
    await db.exec("CREATE TABLE probe_parent(id INTEGER PRIMARY KEY, current INTEGER); CREATE TABLE probe_result(id INTEGER PRIMARY KEY REFERENCES probe_parent(id) ON DELETE CASCADE); CREATE TRIGGER probe_guard BEFORE INSERT ON probe_result WHEN NOT EXISTS (SELECT 1 FROM probe_parent WHERE id=NEW.id AND current=1) BEGIN SELECT RAISE(ABORT, 'stale'); END;");
    await db.prepare("INSERT INTO probe_parent VALUES (1,0)").run();
    await expect(db.batch([db.prepare("INSERT INTO probe_parent VALUES (2,1)"), db.prepare("INSERT INTO probe_result VALUES (1)")])).rejects.toThrow();
    expect(await db.prepare("SELECT id FROM probe_parent WHERE id=2").first()).toBeNull();
  });
  it("allows only one concurrent claimant and cascades its result on parent deletion", async () => {
    await db.exec("CREATE TABLE probe_job(id INTEGER PRIMARY KEY); CREATE TABLE probe_claim(id INTEGER PRIMARY KEY REFERENCES probe_job(id) ON DELETE CASCADE);");
    await db.prepare("INSERT INTO probe_job VALUES (1)").run();
    const calls = await Promise.all([1,2].map(() => db.prepare("INSERT INTO probe_claim SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM probe_claim WHERE id=1)").run()));
    expect(calls.map(r => r.meta.changes).sort()).toEqual([0,1]);
    await db.prepare("DELETE FROM probe_job WHERE id=1").run();
    expect(await db.prepare("SELECT id FROM probe_claim").first()).toBeNull();
  });
});
