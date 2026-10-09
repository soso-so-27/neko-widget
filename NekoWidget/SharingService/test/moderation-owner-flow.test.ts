import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { fixture, encoder, hex } from "./fixtures/moderation-operator";
import { verifyCloudflareAccessJWT } from "../src/moderation-operator-auth";
import { actorSQL, admitSession, type Actor } from "../src/moderation-operator-identity";
import { routeLocalModerationOperatorTriage } from "../src/moderation-operator-triage-local";
import { readLocalModerationReviewSource } from "../src/moderation-review-source";
import { runDurableModerationAdvisory } from "../src/moderation-ai-durable";

const db = (env as unknown as { DB: D1Database }).DB;
const migrations = (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS;
beforeEach(async () => { await reset(); await applyD1Migrations(db, migrations); });
const digest = () => hex(crypto.getRandomValues(new Uint8Array(32)));
const count = async (table: string) => (await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>())!.n;

// These are DB boundary tests, not cryptographic admission or rendered-human
// evidence. The shared fixture supplies the real pre-existing FK/enrollment/
// report commit chain. Host receipt writes below model a trusted verifier;
// HTTP integration tests separately exercise the actual Access/WebAuthn flow.
async function ownerFixture() {
  const f = await fixture();
  const access = await verifyCloudflareAccessJWT(f.token, f.local.access);
  const actor = (await db.prepare(actorSQL).bind(access.operatorSubjectHmac, access.subjectHmacKeyVersion).first<Actor>())!;
  await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
    VALUES (1,?,?,COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0))`)
    .bind(f.operatorId, actor.enrollment_admission_id).run();
  await admitSession(db, access, actor).run();
  const source = (await readLocalModerationReviewSource(db, { caseReferenceHmac: f.caseReference, caseReferenceHmacKeyVersion: 1 }))!;
  return { ...f, access, actor, source, snapshotHash: await hex(encoder.encode(JSON.stringify(source))) };
}
type OwnerFixture = Awaited<ReturnType<typeof ownerFixture>>;
async function challenge(f: OwnerFixture, options: { purpose?: "content_read" | "decision"; receipt?: string; snapshot?: string; value?: string; session?: string } = {}) {
  const id = crypto.randomUUID(), value = options.value ?? await digest();
  await db.prepare(`INSERT INTO moderation_owner_challenges(challenge_id,policy_revision,operator_id,credential_id_sha256,
    enrollment_admission_id,access_session_sha256,challenge_value_sha256,purpose,case_reference_hmac,case_reference_hmac_key_version,
    source_sha256,source_committed_at,source_expires_at,source_snapshot_sha256,decision,reply_template,read_receipt_id,expires_at)
    SELECT ?,1,?,?,?,?,?,?,?,1,source_sha256,source_committed_at,expires_at,?,?,?,?,MIN(unixepoch()+300,?,expires_at)
    FROM moderation_advisory_live_sources WHERE case_reference_hmac=?`)
    .bind(id, f.operatorId, f.credentialDigest, f.actor.enrollment_admission_id, options.session ?? f.access.accessSessionSHA256,
      value, options.purpose ?? "content_read", f.caseReference, options.snapshot ?? f.snapshotHash,
      options.purpose === "decision" ? "no_action" : null, options.purpose === "decision" ? "review_no_action_v1" : null,
      options.receipt ?? null, f.access.expiresAt, f.caseReference).run();
  // INSERT SELECT zero rows must not be mistaken for a valid challenge.
  expect(await db.prepare("SELECT challenge_id FROM moderation_owner_challenges WHERE challenge_id=?").bind(id).first()).not.toBeNull();
  return { id, value };
}
async function consume(id: string, counter: number, hash?: string) {
  const assertion = hash ?? await digest();
  await db.prepare("INSERT INTO moderation_owner_assertion_attempts(challenge_id,assertion_sha256) VALUES (?,?)").bind(id, assertion).run();
  await db.prepare(`INSERT INTO moderation_owner_challenge_consumptions(challenge_id,verified_assertion_sha256,authenticator_sign_count)
    VALUES (?,?,?)`).bind(id, assertion, counter).run();
  return assertion;
}
async function claim(id: string) {
  const receipt = crypto.randomUUID();
  await db.prepare(`INSERT INTO moderation_owner_read_claims(challenge_id,read_receipt_id,expires_at)
    SELECT challenge_id,?,MIN(unixepoch()+60,expires_at) FROM moderation_owner_challenges WHERE challenge_id=?`).bind(receipt, id).run();
  return receipt;
}
const event = (receipt: string, phase: string) => db.prepare("INSERT INTO moderation_owner_read_events(read_receipt_id,phase) VALUES (?,?)").bind(receipt, phase).run();
const complete = (receipt: string) => db.prepare("INSERT INTO moderation_owner_read_receipts(read_receipt_id) VALUES (?)").bind(receipt).run();
async function ready(f = ownerFixture()) {
  const context = await f, read = await challenge(context);
  await consume(read.id, 1);
  const receipt = await claim(read.id);
  await event(receipt, "started"); await event(receipt, "disclosure_ready"); await complete(receipt);
  return { f: context, read, receipt };
}
async function decided() {
  const r = await ready();
  const decision = await challenge(r.f, { purpose: "decision", receipt: r.receipt });
  await consume(decision.id, 2);
  const id = crypto.randomUUID();
  await db.prepare("INSERT INTO moderation_owner_decisions(decision_id,challenge_id,case_reference_hmac) VALUES (?,?,?)")
    .bind(id, decision.id, r.f.caseReference).run();
  return { ...r, decision, id };
}
const current = (id: string) => db.prepare("SELECT challenge_id FROM moderation_owner_current_challenges WHERE challenge_id=?").bind(id).first();

describe("local owner D1 authority, source and one-shot boundaries", () => {
  it("starts empty and derives only a reviewed current owner's policy without granting legacy privacy roles", async () => {
    expect(await count("moderation_owner_policies")).toBe(0);
    const f = await ownerFixture();
    expect(await count("moderation_owner_current_policies")).toBe(1);
    expect(await db.prepare("SELECT role_code FROM moderation_operator_role_events WHERE role_code='privacy_approver'").first()).toBeNull();
    await expect(db.prepare(`INSERT OR REPLACE INTO moderation_owner_policies SELECT * FROM moderation_owner_policies`).run()).rejects.toThrow();
    await expect(db.prepare("UPDATE moderation_owner_policies SET session_rowid_floor=0").run()).rejects.toThrow();
    await expect(db.prepare("DELETE FROM moderation_owner_policies").run()).rejects.toThrow();
    await expect(db.prepare(`INSERT INTO moderation_owner_policies VALUES (2,?,?,unixepoch(),0)`)
      .bind(crypto.randomUUID(), f.actor.enrollment_admission_id).run()).rejects.toThrow();
    await expect(db.prepare(`INSERT INTO moderation_owner_challenges(challenge_id,domain) VALUES (?,'request')`).bind(crypto.randomUUID()).run()).rejects.toThrow();
  });

  it("rejects sessions admitted before the policy epoch and unknown owners", async () => {
    const f = await ownerFixture();
    await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
      VALUES (2,?,?,(SELECT MAX(rowid) FROM moderation_operator_access_sessions))`).bind(f.operatorId, f.actor.enrollment_admission_id).run();
    await expect(challenge(f)).rejects.toThrow();
    expect(await count("moderation_owner_source_snapshots")).toBe(0);
  });

  it("binds all mutable source metadata in a DB-derived short-lived snapshot", async () => {
    const f = await ownerFixture(), c = await challenge(f);
    const original = (await db.prepare("SELECT * FROM moment_reports WHERE id=?").bind(f.reportId).first())!;
    const changes: [string, unknown][] = [
      ["object_key", "different/object"], ["reason_code", "other"], ["moderation_key_id", "different-key"],
      ["ciphertext_size", 33], ["ciphertext_sha256", f.source.metadata.ciphertextSHA256.slice(0, -1) + (f.source.metadata.ciphertextSHA256.endsWith("A") ? "Q" : "A")],
      ["committed_at", Number(original.committed_at) + 1], ["content_expires_at", Number(original.content_expires_at) - 1],
    ];
    for (const [column, value] of changes) {
      await db.prepare(`UPDATE moment_reports SET ${column}=? WHERE id=?`).bind(value, f.reportId).run();
      expect(await current(c.id), column).toBeNull();
      await db.prepare(`UPDATE moment_reports SET ${column}=? WHERE id=?`).bind(original[column], f.reportId).run();
      expect(await current(c.id), column).not.toBeNull();
    }
    // Use valid FK identities from this report's moment to prove the identity
    // columns, not just digest/expiry, participate in the current-source guard.
    await db.prepare(`INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at)
      SELECT ?,space_id,'member','active',unixepoch(),unixepoch() FROM moment_participants WHERE id=?`)
      .bind(f.reportId, f.source.metadata.reporterParticipantId).run();
    await db.prepare("UPDATE moment_reports SET reporter_participant_id=? WHERE id=?").bind(f.reportId, f.reportId).run();
    expect(await current(c.id)).toBeNull();
    await db.prepare("UPDATE moment_reports SET reporter_participant_id=? WHERE id=?").bind(original.reporter_participant_id, f.reportId).run();
    await db.prepare(`INSERT INTO moments(id,client_moment_id,space_id,sender_participant_id,sender_device_id,kind,key_epoch,state,
      object_key,ciphertext_size,ciphertext_sha256,client_moderation_version,sender_policy_version,sender_policy_accepted_at,
      quota_day_key,quota_counted,reservation_attempt,reserve_request_hash,created_at,upload_expires_at,uploaded_at,committed_at,unreceived_expires_at)
      SELECT ?,?,space_id,sender_participant_id,sender_device_id,kind,key_epoch,state,?,ciphertext_size,ciphertext_sha256,
      client_moderation_version,sender_policy_version,sender_policy_accepted_at,quota_day_key,quota_counted,reservation_attempt,?,
      created_at,upload_expires_at,uploaded_at,committed_at,unreceived_expires_at FROM moments WHERE id=?`)
      .bind(f.reportId, crypto.randomUUID(), 'moments/'+f.reportId, await digest(), original.moment_id).run();
    await db.prepare("UPDATE moment_reports SET moment_id=? WHERE id=?").bind(f.reportId, f.reportId).run();
    expect(await current(c.id)).toBeNull();
    await expect(db.prepare("UPDATE moderation_owner_source_snapshots SET reporter_participant_id=?").bind(f.reportId).run()).rejects.toThrow();
    await expect(db.prepare("INSERT OR REPLACE INTO moderation_owner_source_snapshots SELECT * FROM moderation_owner_source_snapshots").run()).rejects.toThrow();
  });

  it.each(["alias", "credential", "operator", "triage", "policy", "deletion", "tombstone", "closed"])("revokes an already consumed scope on %s change", async mode => {
    const f = await ownerFixture(), c = await challenge(f); await consume(c.id, 1);
    if (mode === "alias") await db.prepare("INSERT INTO moderation_operator_subject_identities(operator_id,access_subject_hmac_key_version,access_subject_hmac) VALUES (?,2,?)").bind(f.operatorId, await digest()).run();
    if (mode === "credential") await db.prepare("INSERT INTO moderation_operator_credential_events(credential_id_sha256,event_type) VALUES (?,'revoked')").bind(f.credentialDigest).run();
    if (mode === "operator") await db.prepare("INSERT INTO moderation_operator_state_events(operator_id,event_type) VALUES (?,'revoked')").bind(f.operatorId).run();
    if (mode === "triage") await db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES (?,'triage','revoked')").bind(f.operatorId).run();
    if (mode === "policy") await db.prepare("INSERT INTO moderation_owner_policy_revocations(policy_revision) VALUES (1)").run();
    if (mode === "deletion") await db.prepare("INSERT INTO moment_object_deletions(object_key,object_type,owner_id,not_before,created_at) VALUES (?,'report',?,unixepoch()+600,unixepoch())").bind(f.source.objectKey, f.reportId).run();
    if (mode === "tombstone") await db.prepare("UPDATE moment_report_tombstones SET content_deleted_at=unixepoch() WHERE report_id=?").bind(f.reportId).run();
    if (mode === "closed") await db.prepare("UPDATE moment_reports SET closed_at=unixepoch() WHERE id=?").bind(f.reportId).run();
    expect(await current(c.id)).toBeNull();
    await expect(claim(c.id)).rejects.toThrow();
    expect(await count("moderation_owner_challenge_consumptions")).toBe(1);
  });

  it("burns attempts, uses shared counters, and prevents claim replacement/reset", async () => {
    const f = await ownerFixture(), a = await challenge(f);
    await consume(a.id, 3); const receipt = await claim(a.id);
    await expect(claim(a.id)).rejects.toThrow();
    await expect(db.prepare("DELETE FROM moderation_owner_assertion_attempts").run()).rejects.toThrow();
    await expect(db.prepare("INSERT OR REPLACE INTO moderation_owner_read_claims SELECT * FROM moderation_owner_read_claims").run()).rejects.toThrow();
    expect(await db.prepare("SELECT sign_count FROM moderation_operator_credential_counters WHERE credential_id_sha256=?").bind(f.credentialDigest).first()).toEqual({ sign_count: 3 });
    for (const counter of [0, 2, 3]) {
      const c = await challenge(f); await expect(consume(c.id, counter)).rejects.toThrow();
      expect(await db.prepare("SELECT challenge_id FROM moderation_owner_assertion_attempts WHERE challenge_id=?").bind(c.id).first()).not.toBeNull();
    }
    await event(receipt, "failed");
    await expect(event(receipt, "disclosure_ready")).rejects.toThrow();
    await expect(complete(receipt)).rejects.toThrow();
  });

  it("retains the zero-only authenticator rule across separate owner requests", async () => {
    const f = await ownerFixture();
    for (let n=0;n<2;n++) await consume((await challenge(f)).id, 0);
    await consume((await challenge(f)).id, 1);
    await expect(consume((await challenge(f)).id, 0)).rejects.toThrow();
  });

  it("requires ordered durable disclosure audit and forbids success/failure contradictions", async () => {
    const f = await ownerFixture(), c = await challenge(f); await consume(c.id, 1); const receipt = await claim(c.id);
    await expect(complete(receipt)).rejects.toThrow();
    await expect(event(receipt, "disclosure_ready")).rejects.toThrow();
    await event(receipt, "started"); await event(receipt, "disclosure_ready"); await complete(receipt);
    await expect(complete(receipt)).rejects.toThrow();
    await expect(event(receipt, "delivery_unknown")).rejects.toThrow();
    await expect(db.prepare("DELETE FROM moderation_owner_read_events").run()).rejects.toThrow();
  });

  it("requires the exact completed same-source read and never accepts restrict or escalation as terminal", async () => {
    const r = await ready();
    await expect(challenge(r.f, { purpose: "decision", receipt: crypto.randomUUID() })).rejects.toThrow();
    await expect(challenge(r.f, { purpose: "decision", receipt: r.receipt, snapshot: await digest() })).rejects.toThrow();
    const c = await challenge(r.f, { purpose: "decision", receipt: r.receipt });
    await expect(db.prepare("UPDATE moderation_owner_challenges SET decision='restrict' WHERE challenge_id=?").bind(c.id).run()).rejects.toThrow();
    await expect(db.prepare("INSERT INTO moderation_owner_decisions(decision_id,challenge_id,case_reference_hmac) VALUES (?,?,?)")
      .bind(crypto.randomUUID(), c.id, r.f.caseReference).run()).rejects.toThrow();
    expect(await count("moderation_owner_decisions")).toBe(0);
  });

  it("atomically derives the reporter-only saved reply, excludes AI/source, and does not grant or deliver anything", async () => {
    const r = await decided();
    const outbox = await db.prepare("SELECT * FROM moderation_owner_reply_outbox WHERE decision_id=?").bind(r.id).first();
    expect(outbox).toMatchObject({ report_id: r.f.reportId, recipient_participant_id: r.f.source.metadata.reporterParticipantId, template_code: "review_no_action_v1" });
    expect(Number(outbox!.expires_at)-Number(outbox!.created_at)).toBe(86400);
    expect(await readLocalModerationReviewSource(db, { caseReferenceHmac: r.f.caseReference, caseReferenceHmacKeyVersion: 1 })).toBeNull();
    expect(await db.prepare("SELECT * FROM moderation_advisory_live_sources").first()).toBeNull();
    expect(await count("moderation_case_events")).toBe(0);
    expect(await count("moderation_operator_actions")).toBe(0);
    await expect(db.prepare("INSERT OR REPLACE INTO moderation_owner_reply_outbox SELECT * FROM moderation_owner_reply_outbox").run()).rejects.toThrow();
    await expect(db.prepare("INSERT OR REPLACE INTO moderation_owner_decisions SELECT * FROM moderation_owner_decisions").run()).rejects.toThrow();
    await expect(db.prepare("DELETE FROM moderation_owner_decisions").run()).rejects.toThrow();
  });

  it("purges existing AI job payloads only at owner terminal completion", async () => {
    const r = await ready();
    await runDurableModerationAdvisory(db, {caseReferenceHmac:r.f.caseReference,caseReferenceHmacKeyVersion:1},
      {safetyRoute:'child_safety_hold'}, {apiKey:'unused-local'});
    expect(await count('moderation_advisory_jobs')).toBe(1);
    await expect(db.prepare('DELETE FROM moderation_advisory_jobs').run()).rejects.toThrow();
    const c=await challenge(r.f,{purpose:'decision',receipt:r.receipt}); await consume(c.id,2);
    await db.prepare('INSERT INTO moderation_owner_decisions(decision_id,challenge_id,case_reference_hmac) VALUES (?,?,?)')
      .bind(crypto.randomUUID(),c.id,r.f.caseReference).run();
    expect(await count('moderation_advisory_jobs')).toBe(0);
    expect(await count('moderation_advisory_attempts')).toBe(0);
    expect(await count('moderation_advisory_results')).toBe(0);
  });

  it("rolls back the entire final decision/outbox transaction on a later SQL error", async () => {
    const r = await ready(), c = await challenge(r.f, { purpose: "decision", receipt: r.receipt }); await consume(c.id, 2);
    await expect(db.batch([
      db.prepare("INSERT INTO moderation_owner_decisions(decision_id,challenge_id,case_reference_hmac) VALUES (?,?,?)").bind(crypto.randomUUID(), c.id, r.f.caseReference),
      db.prepare("SELECT json('deliberate test failure')"),
    ])).rejects.toThrow();
    expect(await count("moderation_owner_decisions")).toBe(0); expect(await count("moderation_owner_reply_outbox")).toBe(0);
    expect(await count("moderation_owner_challenge_consumptions")).toBe(2);
  });

  it.each(["closed", "tombstone", "delete", "pending"])("purges private snapshot/recipient on %s without resetting audit or counter", async mode => {
    const r = await decided();
    if (mode === "closed") await db.prepare("UPDATE moment_reports SET closed_at=unixepoch() WHERE id=?").bind(r.f.reportId).run();
    if (mode === "tombstone") await db.prepare("UPDATE moment_report_tombstones SET content_deleted_at=unixepoch() WHERE report_id=?").bind(r.f.reportId).run();
    if (mode === "delete") await db.prepare("DELETE FROM moment_reports WHERE id=?").bind(r.f.reportId).run();
    if (mode === "pending") await db.prepare("INSERT INTO moment_object_deletions(object_key,object_type,owner_id,not_before,created_at) VALUES (?,'report',?,unixepoch()+600,unixepoch())").bind(r.f.source.objectKey, r.f.reportId).run();
    expect(await count("moderation_owner_source_snapshots")).toBe(0); expect(await count("moderation_owner_reply_outbox")).toBe(0);
    expect(await count("moderation_owner_decisions")).toBe(1); expect(await count("moderation_owner_challenge_consumptions")).toBe(2);
  });

  it("limits abandoned owner challenges to the existing eight-active boundary", async () => {
    const f = await ownerFixture();
    for (let n=0;n<8;n++) await challenge(f);
    await expect(challenge(f)).rejects.toThrow();
    expect(await count("moderation_owner_challenges")).toBe(8);
    const response = await routeLocalModerationOperatorTriage(f.request(f.operationPath, "POST"), f.local);
    expect(response.status).toBeGreaterThanOrEqual(400);
    expect(await count("moderation_operator_challenges")).toBe(0);
  });

  it("keeps the twelve-issued quota even when every challenge was consumed", async () => {
    const f = await ownerFixture();
    for (let n=1;n<=12;n++) await consume((await challenge(f)).id, n);
    await expect(challenge(f)).rejects.toThrow();
    expect(await count("moderation_owner_challenges")).toBe(12);
  });

  it("rejects cross-domain challenge values in both directions", async () => {
    const f = await ownerFixture();
    const response = await routeLocalModerationOperatorTriage(f.request(f.operationPath, "POST"), f.local);
    expect(response.status).toBe(202);
    const old = (await db.prepare("SELECT challenge_value_sha256 FROM moderation_operator_challenges").first<{ challenge_value_sha256: string }>())!;
    await expect(challenge(f, { value: old.challenge_value_sha256 })).rejects.toThrow();
    const c = await challenge(f);
    await expect(db.prepare(`INSERT INTO moderation_operator_challenges SELECT ?,operator_id,access_subject_hmac_key_version,
      credential_id_sha256,access_session_sha256,?,purpose,action_type,?,case_reference_hmac,method,pathname,body_sha256,issued_at,expires_at
      FROM moderation_operator_challenges LIMIT 1`).bind(crypto.randomUUID(), c.value, crypto.randomUUID()).run()).rejects.toThrow();
  });

  it("enforces the shared counter directly at the legacy consumption boundary", async () => {
    const f = await ownerFixture(); await consume((await challenge(f)).id, 2);
    const begin = await routeLocalModerationOperatorTriage(f.request(f.operationPath, "POST"), f.local);
    const c = await begin.json<{ challenge: string; challengeId: string; assertionPath: string }>();
    const failed = await routeLocalModerationOperatorTriage(f.request(c.assertionPath, "POST", await f.assertion(c.challenge, { invalidSignature: true, counter: 3 })), f.local);
    expect(failed.status).toBe(400);
    const insert = (counter: number) => db.prepare(`INSERT INTO moderation_operator_challenge_consumptions(challenge_id,operator_id,credential_id_sha256,verified_assertion_sha256,authenticator_sign_count)
      SELECT challenge_id,operator_id,credential_id_sha256,assertion_sha256,? FROM moderation_operator_assertion_attempts WHERE challenge_id=?`).bind(counter, c.challengeId).run();
    for (const counter of [0, 1, 2]) await expect(insert(counter)).rejects.toThrow();
    await insert(3);
    expect(await db.prepare("SELECT sign_count FROM moderation_operator_credential_counters WHERE credential_id_sha256=?").bind(f.credentialDigest).first()).toEqual({ sign_count: 3 });
    await expect(consume((await challenge(f)).id, 3)).rejects.toThrow();
  });

  it("fails closed after claim expiry while permitting a minimal late failure audit", async () => {
    const f=await ownerFixture(), c=await challenge(f); await consume(c.id,1);
    const receipt=crypto.randomUUID();
    await db.prepare("INSERT INTO moderation_owner_read_claims(challenge_id,read_receipt_id,expires_at) VALUES (?,?,unixepoch()+1)")
      .bind(c.id,receipt).run();
    await event(receipt,'started');
    await new Promise(resolve=>setTimeout(resolve,1100));
    await expect(event(receipt,'disclosure_ready')).rejects.toThrow();
    await expect(complete(receipt)).rejects.toThrow();
    await event(receipt,'delivery_unknown');
    await expect(event(receipt,'failed')).rejects.toThrow();
    await expect(claim(c.id)).rejects.toThrow();
  });

  it("purges expired private rows without changing committed state or durable consumed receipts", async () => {
    const f=await ownerFixture();
    const expiry=(await db.prepare('SELECT unixepoch()+3 AS expiry').first<{expiry:number}>())!.expiry;
    await db.batch([
      db.prepare('UPDATE moment_reports SET content_expires_at=? WHERE id=?').bind(expiry,f.reportId),
      db.prepare('UPDATE moment_report_tombstones SET content_expires_at=? WHERE report_id=?').bind(expiry,f.reportId),
    ]);
    const r=await ready(Promise.resolve(f)), c=await challenge(f,{purpose:'decision',receipt:r.receipt}); await consume(c.id,2);
    await db.prepare('INSERT INTO moderation_owner_decisions(decision_id,challenge_id,case_reference_hmac) VALUES (?,?,?)')
      .bind(crypto.randomUUID(),c.id,f.caseReference).run();
    expect(await db.prepare('SELECT expires_at FROM moderation_owner_reply_outbox').first()).toEqual({expires_at:expiry});
    await new Promise(resolve=>setTimeout(resolve,3100));
    await db.batch([
      db.prepare('DELETE FROM moderation_owner_source_snapshots WHERE expires_at<=unixepoch()'),
      db.prepare('DELETE FROM moderation_owner_reply_outbox WHERE expires_at<=unixepoch()'),
    ]);
    expect(await count('moderation_owner_source_snapshots')).toBe(0); expect(await count('moderation_owner_reply_outbox')).toBe(0);
    expect(await count('moderation_owner_read_receipts')).toBe(1); expect(await count('moderation_owner_decisions')).toBe(1);
    expect(await db.prepare('SELECT state,closed_at FROM moment_reports WHERE id=?').bind(f.reportId).first())
      .toEqual({state:'committed',closed_at:null});
  });

  it("rejects cross-domain assertion fingerprints before a second verification receipt", async () => {
    const f=await ownerFixture(); const c=await challenge(f); const ownerHash=await consume(c.id,1);
    const result=await routeLocalModerationOperatorTriage(f.request(f.operationPath,'POST'),f.local);
    const old=await result.json<{challenge:string;challengeId:string;assertionPath:string}>();
    await expect(db.prepare(`INSERT INTO moderation_operator_assertion_attempts(challenge_id,operator_id,access_session_sha256,credential_id_sha256,assertion_sha256)
      SELECT challenge_id,operator_id,access_session_sha256,credential_id_sha256,? FROM moderation_operator_challenges WHERE challenge_id=?`)
      .bind(ownerHash,old.challengeId).run()).rejects.toThrow();
    expect((await routeLocalModerationOperatorTriage(f.request(old.assertionPath,'POST',await f.assertion(old.challenge,{counter:2})),f.local)).status).toBe(200);
    const legacy=(await db.prepare('SELECT verified_assertion_sha256 FROM moderation_operator_challenge_consumptions WHERE challenge_id=?')
      .bind(old.challengeId).first<{verified_assertion_sha256:string}>())!;
    const next=await challenge(f);
    await expect(consume(next.id,3,legacy.verified_assertion_sha256)).rejects.toThrow();
    await expect(db.prepare(`INSERT INTO moderation_operator_challenge_consumptions(challenge_id,operator_id,credential_id_sha256,verified_assertion_sha256,authenticator_sign_count)
      VALUES (?,?,?,?,3)`).bind(old.challengeId,f.operatorId,f.credentialDigest,ownerHash).run()).rejects.toThrow();
    expect(await count('moderation_owner_challenge_consumptions')).toBe(1);
    expect(await count('moderation_operator_challenge_consumptions')).toBe(1);
  });
});
