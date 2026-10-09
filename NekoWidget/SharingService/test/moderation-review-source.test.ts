import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { base64urlEncode } from "../src/encoding";
import { deriveModerationOperatorCaseReference } from "../src/moderation-operator-case-reference";
import { readLocalModerationReviewSource, type LocalModerationReviewReference } from "../src/moderation-review-source";

const db = (env as unknown as { DB: D1Database }).DB;
const migrations = (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS;
const id = (bytes = 16) => base64urlEncode(crypto.getRandomValues(new Uint8Array(bytes)));
beforeEach(async () => { await reset(); await applyD1Migrations(db, migrations); });

// Minimal real FK/admission/commit chain from the existing durable/triage
// fixtures. Only synthetic metadata: no object upload, image, secret or grant.
async function world() {
  const space = id(), owner = id(), ownerDevice = id(), moment = id();
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{ now: number }>())!.now;
  await db.batch([
    db.prepare("INSERT INTO moment_space_lineages(id,created_at) VALUES (?,?)").bind(space, now),
    db.prepare("INSERT INTO moment_spaces(space_id,lineage_id,state,created_at,updated_at) VALUES (?,?,'active',?,?)")
      .bind(space, space, now, now),
    db.prepare("INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES (?,?,'owner','active',?,?)")
      .bind(owner, space, now, now),
    db.prepare("INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at) VALUES (?,?,?,?,'active',?,?)")
      .bind(ownerDevice, owner, id(32), id(32), now, now),
    db.prepare(`INSERT INTO moments(id,client_moment_id,space_id,sender_participant_id,sender_device_id,kind,key_epoch,state,
      object_key,ciphertext_size,ciphertext_sha256,client_moderation_version,sender_policy_version,sender_policy_accepted_at,
      quota_day_key,quota_counted,reservation_attempt,reserve_request_hash,created_at,upload_expires_at,uploaded_at,committed_at,unreceived_expires_at)
      VALUES (?,?,?,?,?,'live',1,'committed',?,32,?,1,1,?,1,0,1,?,?,?,?,?,?)`)
      .bind(moment, crypto.randomUUID(), space, owner, ownerDevice, `moments/${moment}`, id(32), now,
        id(32), now, now + 3600, now, now, now + 604800),
  ]);
  return { space, owner, moment, now };
}

async function bindReference(report: string, reference: LocalModerationReviewReference) {
  await db.prepare(`INSERT INTO moderation_operator_versioned_case_references(report_id,case_reference_hmac,
    case_reference_hmac_key_version,derivation_protocol_version,derivation_domain)
    VALUES (?,?,?,1,'NW.MODERATION-OPERATOR.CASE-REFERENCE')`)
    .bind(report, reference.caseReferenceHmac, reference.caseReferenceHmacKeyVersion).run();
}

async function fixture(context = world(), withReference = true) {
  const { space, owner, moment, now } = await context;
  const reporter = id(), device = id(), report = id(), digest = id(32);
  const objectKey = `v2/${space}/reports/${id(24)}`;
  const reference = await deriveModerationOperatorCaseReference(
    { reportId: report, caseReferenceHmacKeyVersion: 1 }, new Uint8Array(32).fill(7));
  await db.batch([
    db.prepare("INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES (?,?,'member','active',?,?)")
      .bind(reporter, space, now, now),
    db.prepare("INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at) VALUES (?,?,?,?,'active',?,?)")
      .bind(device, reporter, id(32), id(32), now, now),
    db.prepare("INSERT INTO moment_deliveries(moment_id,recipient_participant_id,state,created_at,access_expires_at) VALUES (?,?,'pending',?,?)")
      .bind(moment, reporter, now, now + 604800),
    db.prepare(`INSERT INTO moment_reports(id,moment_id,space_id,lineage_id,reporter_participant_id,reporter_device_id,
      accused_participant_id,reason_code,moderation_key_id,state,object_key,ciphertext_size,ciphertext_sha256,
      reporter_consent_version,reporter_consented_at,quota_day_key,reserve_request_hash,dedupe_key,created_at,upload_expires_at)
      VALUES (?,?,?,?,?,?,?,'privacy','moderation-v1','reserved',?,32,?,1,?,1,?,?,?,?)`)
      .bind(report, moment, space, space, reporter, device, owner, objectKey, digest, now, id(32), id(32), now, now + 3600),
    db.prepare("UPDATE moment_reports SET state='uploaded',uploaded_at=? WHERE id=?").bind(now, report),
    db.prepare("INSERT INTO moment_report_commit_events(id,report_id,reporter_participant_id,committed_at,content_expires_at) VALUES (?,?,?,?,?)")
      .bind(crypto.randomUUID(), report, reporter, now, now + 604800),
  ]);
  const ref = { caseReferenceHmac: reference.caseReferenceHmac, caseReferenceHmacKeyVersion: reference.caseReferenceHmacKeyVersion };
  if (withReference) await bindReference(report, ref);
  return { report, moment, reporter, digest, objectKey, now, reference: ref };
}

describe("local moderation review source snapshot", () => {
  it("returns exactly the private DB metadata snapshot without granting or mutating anything", async () => {
    const f = await fixture();
    const snapshot = await readLocalModerationReviewSource(db, f.reference);
    expect(snapshot).toEqual({ schema: "jp.nekowidget.moderation-review-source.v1", ...f.reference, objectKey: f.objectKey,
      metadata: { schema: "jp.nekowidget.moderation-export.v1", protocolVersion: 2,
        envelopeDomain: "NW2.MODERATION-REPORT", algorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
        reportId: f.report, momentId: f.moment, reporterParticipantId: f.reporter, reasonCode: "privacy",
        moderationKeyId: "moderation-v1", ciphertextSize: 32, ciphertextSHA256: f.digest,
        committedAt: f.now, contentExpiresAt: f.now + 604800 } });
    expect(Object.getPrototypeOf(snapshot)).toBe(Object.prototype);
    expect(Object.getPrototypeOf(snapshot!.metadata)).toBe(Object.prototype);
    expect(await db.prepare("SELECT state,closed_at FROM moment_reports WHERE id=?").bind(f.report).first())
      .toEqual({ state: "committed", closed_at: null });
    for (const table of ["moderation_case_events", "moderation_operator_actions", "moderation_operator_role_events", "moment_object_deletions"]) {
      expect((await db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).first<{ count: number }>())!.count).toBe(0);
    }
  });

  it("rejects an unknown case, wrong HMAC key version and missing versioned reference", async () => {
    const f = await fixture();
    expect(await readLocalModerationReviewSource(db, { ...f.reference, caseReferenceHmac: "f".repeat(64) })).toBeNull();
    expect(await readLocalModerationReviewSource(db, { ...f.reference, caseReferenceHmacKeyVersion: 2 })).toBeNull();
    const unbound = await fixture(world(), false);
    expect(await readLocalModerationReviewSource(db, unbound.reference)).toBeNull();
  });

  it("keeps separate reporters and ciphertexts on the same moment bound to their exact report", async () => {
    const context = world(); const a = await fixture(context), b = await fixture(context);
    const first = await readLocalModerationReviewSource(db, a.reference);
    const second = await readLocalModerationReviewSource(db, b.reference);
    expect(first!.metadata).toMatchObject({ reportId: a.report, momentId: a.moment, reporterParticipantId: a.reporter, ciphertextSHA256: a.digest });
    expect(second!.metadata).toMatchObject({ reportId: b.report, momentId: a.moment, reporterParticipantId: b.reporter, ciphertextSHA256: b.digest });
    expect(first!.objectKey).toBe(a.objectKey); expect(second!.objectKey).toBe(b.objectKey);
    await db.prepare("INSERT INTO moment_object_deletions(object_key,object_type,owner_id,not_before,created_at) VALUES (?,'report',?,unixepoch(),unixepoch())")
      .bind(a.objectKey, a.report).run();
    expect(await readLocalModerationReviewSource(db, a.reference)).toBeNull();
    expect(await readLocalModerationReviewSource(db, b.reference)).toEqual(second);
  });

  it.each(["expired", "deleted", "closed"])("refuses %s report content even while metadata rows remain", async state => {
    const f = await fixture();
    if (state === "closed") await db.prepare("UPDATE moment_reports SET closed_at=unixepoch() WHERE id=?").bind(f.report).run();
    else {
      await db.prepare("UPDATE moment_reports SET state='expired',closed_at=unixepoch() WHERE id=?").bind(f.report).run();
      if (state === "deleted") await db.prepare("UPDATE moment_reports SET state='deleted' WHERE id=?").bind(f.report).run();
    }
    expect(await readLocalModerationReviewSource(db, f.reference)).toBeNull();
  });

  it("refuses a tombstone-only report after its full row was removed", async () => {
    const f = await fixture();
    await db.prepare("DELETE FROM moment_reports WHERE id=?").bind(f.report).run();
    expect(await db.prepare("SELECT report_id FROM moment_report_tombstones WHERE report_id=?").bind(f.report).first()).not.toBeNull();
    expect(await readLocalModerationReviewSource(db, f.reference)).toBeNull();
  });

  it.each(["deleted", "commit_mismatch", "expiry_mismatch"])("keeps the live view tombstone %s exclusion", async change => {
    const f = await fixture();
    const update = change === "deleted" ? "content_deleted_at=unixepoch()" : change === "commit_mismatch"
      ? "committed_at=committed_at+1" : "content_expires_at=content_expires_at+1";
    await db.prepare(`UPDATE moment_report_tombstones SET ${update} WHERE report_id=?`).bind(f.report).run();
    expect(await readLocalModerationReviewSource(db, f.reference)).toBeNull();
  });

  it("rejects exactly at the DB TTL boundary before cleanup changes report state", async () => {
    const f = await fixture();
    await db.batch([
      db.prepare("UPDATE moment_reports SET content_expires_at=unixepoch() WHERE id=?").bind(f.report),
      db.prepare("UPDATE moment_report_tombstones SET content_expires_at=unixepoch() WHERE report_id=?").bind(f.report),
    ]);
    expect(await db.prepare("SELECT state FROM moment_reports WHERE id=?").bind(f.report).first()).toEqual({ state: "committed" });
    expect(await readLocalModerationReviewSource(db, f.reference)).toBeNull();
  });

  it.each(["pending", "deleted", "future", "same_key_wrong_owner", "same_report_changed_key"])("rejects %s deletion records", async mode => {
    const f = await fixture();
    await db.prepare(`INSERT INTO moment_object_deletions(object_key,object_type,owner_id,state,not_before,created_at,deleted_at)
      VALUES (?,'report',?,?,unixepoch()+?,unixepoch(),?)`)
      .bind(mode === "same_report_changed_key" ? `old/${f.objectKey}` : f.objectKey,
        mode === "same_key_wrong_owner" ? id() : f.report, mode === "deleted" ? "deleted" : "pending",
        mode === "future" ? 86400 : 0, mode === "deleted" ? f.now : null).run();
    // The old live view alone still admits it; the adapter must add this guard.
    expect(await db.prepare("SELECT report_id FROM moderation_advisory_live_sources WHERE report_id=?").bind(f.report).first()).not.toBeNull();
    expect(await readLocalModerationReviewSource(db, f.reference)).toBeNull();
  });

  it("keeps a legacy terminal decision excluded after applying later authority migrations", async () => {
    await reset();
    await applyD1Migrations(db, migrations.filter(migration => migration.name < "0015"));
    const f = await fixture(world(), false);
    await db.batch([
      db.prepare("INSERT INTO moderation_case_events(report_id,event_type) VALUES (?,'review_started')").bind(f.report),
      db.prepare("INSERT INTO moderation_case_events(report_id,event_type,outcome_code) VALUES (?,'review_decided','no_action')").bind(f.report),
    ]);
    await applyD1Migrations(db, migrations);
    await bindReference(f.report, f.reference);
    expect(await readLocalModerationReviewSource(db, f.reference)).toBeNull();
    expect((await db.prepare("SELECT COUNT(*) AS count FROM moderation_case_events WHERE report_id=?").bind(f.report).first<{ count: number }>())!.count).toBe(2);
  });

  it("owns the reference before awaiting and returns fresh independent plain objects", async () => {
    const a = await fixture(), b = await fixture(); const mutable = { ...a.reference };
    const reading = readLocalModerationReviewSource(db, mutable); Object.assign(mutable, b.reference);
    const first = await reading;
    expect(first!.caseReferenceHmac).toBe(a.reference.caseReferenceHmac);
    first!.metadata.reportId = b.report;
    expect((await readLocalModerationReviewSource(db, a.reference))!.metadata.reportId).toBe(a.report);
  });

  it("rejects malformed/nonplain/accessor references without executing getters or querying D1", async () => {
    const prepare = vi.fn(); const fakeDB = { prepare } as unknown as D1Database;
    const reference = { caseReferenceHmac: "a".repeat(64), caseReferenceHmacKeyVersion: 1 };
    const getter = vi.fn(() => reference.caseReferenceHmac);
    const accessor = { get caseReferenceHmac() { return getter(); }, caseReferenceHmacKeyVersion: 1 };
    for (const value of [null, [], Object.create(reference), accessor, { ...reference, extra: 1 },
      { ...reference, caseReferenceHmac: "A".repeat(64) }, { ...reference, caseReferenceHmac: "a".repeat(63) },
      ...[0, -1, 1.5, NaN, 0x8000_0000, "1"].map(version => ({ ...reference, caseReferenceHmacKeyVersion: version }))]) {
      expect(await readLocalModerationReviewSource(fakeDB, value as LocalModerationReviewReference)).toBeNull();
    }
    expect(getter).not.toHaveBeenCalled(); expect(prepare).not.toHaveBeenCalled();
  });

  it("fails closed without disclosing a private database error", async () => {
    const broken = { prepare: () => { throw new Error("private_SQL_and_report_identifier"); } } as unknown as D1Database;
    expect(await readLocalModerationReviewSource(broken, { caseReferenceHmac: "a".repeat(64), caseReferenceHmacKeyVersion: 1 })).toBeNull();
  });
});
