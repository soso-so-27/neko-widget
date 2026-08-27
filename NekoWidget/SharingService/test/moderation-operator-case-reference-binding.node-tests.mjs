import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const projectDirectory = join(import.meta.dirname, "..");
const migrationNames = [
  "0012_moderation_case_lifecycle.sql",
  "0013_moderation_operator_control_plane.sql",
  "0014_moderation_evidence_ledger.sql",
  "0015_moderation_operator_routes.sql",
  "0016_moderation_operator_access_audit.sql",
  "0017_moderation_operator_enrollment_trust.sql",
  "0018_moderation_operator_case_reference_binding.sql",
];
const migrations = await Promise.all(migrationNames.map((name) => readFile(
  join(projectDirectory, "migrations", name),
  "utf8",
)));

const domain = "NW.MODERATION-OPERATOR.CASE-REFERENCE";
const reports = [1, 2, 3].map((byte) => Buffer.alloc(16, byte).toString("base64url"));
const references = ["1".repeat(64), "2".repeat(64), "3".repeat(64)];

function database({ legacyReference = true } = {}) {
  const value = new DatabaseSync(":memory:");
  value.exec(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE moment_report_tombstones (
      report_id TEXT PRIMARY KEY,
      committed_at INTEGER NOT NULL
    ) STRICT;
  `);
  const insertReport = value.prepare(`
    INSERT INTO moment_report_tombstones(report_id, committed_at)
    VALUES (?, unixepoch() - 60)
  `);
  for (const report of reports) insertReport.run(report);
  for (let index = 0; index < migrations.length - 1; index += 1) {
    value.exec(migrations[index]);
  }
  if (legacyReference) {
    value.prepare(`
      INSERT INTO moderation_operator_case_references(
        report_id, case_reference_hmac
      ) VALUES (?, ?)
    `).run(reports[0], references[0]);
  }
  value.exec(migrations.at(-1));
  return value;
}

function insertVersionedReference(value, {
  report = reports[1],
  reference = references[1],
  keyVersion = 7,
  protocolVersion = 1,
  derivationDomain = domain,
} = {}) {
  value.prepare(`
    INSERT INTO moderation_operator_versioned_case_references(
      report_id, case_reference_hmac, case_reference_hmac_key_version,
      derivation_protocol_version, derivation_domain
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    report,
    reference,
    keyVersion,
    protocolVersion,
    derivationDomain,
  );
}

test("0018 leaves legacy references unbound and creates new bindings atomically", () => {
  const value = database();
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count
      FROM moderation_operator_versioned_case_references
  `).get().count, 0);

  assert.throws(
    () => insertVersionedReference(value, {
      report: reports[0],
      reference: references[0],
    }),
    /legacy case reference cannot be version-bound/,
  );
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_case_references(
        report_id, case_reference_hmac
      ) VALUES (?, ?)
    `).run(reports[2], references[2]),
    /atomic version binding/,
  );

  insertVersionedReference(value);
  assert.deepEqual({ ...value.prepare(`
    SELECT report_id, case_reference_hmac, case_reference_hmac_key_version,
           derivation_protocol_version, derivation_domain
      FROM moderation_operator_versioned_case_references
  `).get() }, {
    report_id: reports[1],
    case_reference_hmac: references[1],
    case_reference_hmac_key_version: 7,
    derivation_protocol_version: 1,
    derivation_domain: domain,
  });
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count
      FROM moderation_operator_case_references
     WHERE report_id = ? AND case_reference_hmac = ?
  `).get(reports[1], references[1]).count, 1);
});

test("versioned references reject invalid derivation metadata and mutation", () => {
  const value = database({ legacyReference: false });
  assert.throws(
    () => insertVersionedReference(value, { keyVersion: 0 }),
    /CHECK constraint failed/,
  );
  assert.throws(
    () => insertVersionedReference(value, { protocolVersion: 2 }),
    /CHECK constraint failed/,
  );
  assert.throws(
    () => insertVersionedReference(value, { derivationDomain: `${domain}.OTHER` }),
    /CHECK constraint failed/,
  );

  insertVersionedReference(value);
  assert.throws(
    () => value.exec(`
      UPDATE moderation_operator_versioned_case_references
         SET case_reference_hmac_key_version = 8
    `),
    /versioned case references are immutable/,
  );
  assert.throws(
    () => value.exec("DELETE FROM moderation_operator_versioned_case_references"),
    /versioned case references cannot be deleted/,
  );
});

test("every externally insertable case boundary has a version-binding gate", () => {
  const value = database();
  const expectedTriggers = [
    "moderation_operator_challenges_require_versioned_case_reference",
    "moderation_operator_challenge_consumptions_require_versioned_case_reference",
    "moderation_operator_assertion_attempts_require_versioned_case_reference",
    "moderation_operator_actions_require_versioned_case_reference",
    "moderation_operator_action_approvals_require_versioned_case_reference",
    "moderation_case_reservations_require_versioned_case_reference",
    "moderation_case_reservation_consumptions_require_versioned_case_reference",
    "moderation_evidence_event_intents_require_versioned_case_reference",
    "moderation_evidence_event_finalizations_require_versioned_case_reference",
    "moderation_case_events_require_versioned_case_reference",
    "moderation_evidence_ledger_events_require_versioned_case_reference",
    "moderation_evidence_exports_require_versioned_case_reference",
    "moderation_operator_case_event_links_require_versioned_case_reference",
    "moderation_operator_access_audit_starts_require_versioned_case_reference",
    "moderation_operator_access_audit_finishes_require_versioned_case_reference",
  ];
  const lookup = value.prepare(`
    SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?
  `);
  for (const trigger of expectedTriggers) {
    const row = lookup.get(trigger);
    assert.ok(row, `missing trigger ${trigger}`);
    assert.match(row.sql, /moderation_operator_versioned_case_references/);
  }

  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_case_events(report_id, event_type, outcome_code)
      VALUES (?, 'review_started', NULL)
    `).run(reports[0]),
    /case event requires a versioned case reference/,
  );
});
