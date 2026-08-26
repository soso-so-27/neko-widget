import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const projectDirectory = join(import.meta.dirname, "..");
const migrations = await Promise.all([
  "0012_moderation_case_lifecycle.sql",
  "0013_moderation_operator_control_plane.sql",
  "0014_moderation_evidence_ledger.sql",
].map((filename) => readFile(join(
  projectDirectory,
  "migrations",
  filename,
), "utf8")));

const reportA = "moderation-report-ledger-a";
const reportB = "moderation-report-ledger-b";
const caseA = digest("case-a");
const caseB = digest("case-b");
const genesis = "0".repeat(64);
const clocks = new WeakMap();
let identifierCounter = 1;

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function uuid() {
  const suffix = String(identifierCounter).padStart(12, "0");
  identifierCounter += 1;
  return `00000000-0000-4000-8000-${suffix}`;
}

function signature(character) {
  return Buffer.alloc(64, character.charCodeAt(0)).toString("base64url");
}

function database() {
  identifierCounter = 1;
  const value = new DatabaseSync(":memory:");
  const clock = { now: 1_800_000_000 };
  clocks.set(value, clock);
  value.function("unixepoch", () => clock.now);
  value.exec("PRAGMA foreign_keys = ON");
  assert.equal(value.prepare("PRAGMA foreign_keys").get().foreign_keys, 1);
  value.exec(`
    CREATE TABLE moment_report_tombstones (
      report_id TEXT PRIMARY KEY,
      committed_at INTEGER NOT NULL
    ) STRICT;
  `);
  value.prepare(`
    INSERT INTO moment_report_tombstones(report_id, committed_at)
    VALUES (?, unixepoch() - 60), (?, unixepoch() - 60)
  `).run(reportA, reportB);
  for (const migration of migrations) value.exec(migration);
  value.prepare(`
    INSERT INTO moderation_operator_case_references(
      report_id, case_reference_hmac
    ) VALUES (?, ?), (?, ?)
  `).run(reportA, caseA, reportB, caseB);
  return value;
}

function advanceDatabaseTime(value, seconds) {
  const clock = clocks.get(value);
  assert.ok(clock);
  clock.now += seconds;
}

function registerOperator(value, label, role) {
  const operatorID = uuid();
  const actorSubjectHmac = digest(`${label}-subject`);
  const actorSubjectHmacKeyVersion = 1;
  const credentialID = digest(`${label}-credential`);
  value.prepare(`INSERT INTO moderation_operators(operator_id) VALUES (?)`).run(operatorID);
  value.prepare(`
    INSERT INTO moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version, access_subject_hmac
    ) VALUES (?, ?, ?)
  `).run(operatorID, actorSubjectHmacKeyVersion, actorSubjectHmac);
  value.prepare(`
    INSERT INTO moderation_operator_state_events(operator_id, event_type)
    VALUES (?, 'activated')
  `).run(operatorID);
  value.prepare(`
    INSERT INTO moderation_operator_role_events(
      operator_id, role_code, event_type
    ) VALUES (?, ?, 'granted')
  `).run(operatorID, role);
  value.prepare(`
    INSERT INTO moderation_operator_credentials(
      credential_id_sha256, operator_id, public_key_cose,
      registration_sign_count
    ) VALUES (?, ?, ?, 0)
  `).run(credentialID, operatorID, Buffer.alloc(64, 7));
  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'registered')
  `).run(credentialID);
  return {
    operatorID,
    actorSubjectHmac,
    actorSubjectHmacKeyVersion,
    credentialID,
    signCount: 0,
  };
}

function consumeBoundChallenge(value, {
  actor,
  actionID,
  actionType,
  caseReference,
  purpose,
  bodySHA256,
}) {
  const challengeID = uuid();
  const pathname = `/operator/v1/evidence/${actionID}`;
  value.prepare(`
    INSERT INTO moderation_operator_challenges(
      challenge_id, operator_id, access_subject_hmac_key_version,
      credential_id_sha256, access_session_sha256,
      challenge_value_sha256, purpose, action_type, action_id,
      case_reference_hmac, method, pathname, body_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'POST', ?, ?, unixepoch() + 300)
  `).run(
    challengeID,
    actor.operatorID,
    actor.actorSubjectHmacKeyVersion,
    actor.credentialID,
    digest(`${challengeID}-session`),
    digest(`${challengeID}-challenge`),
    purpose,
    actionType,
    actionID,
    caseReference,
    pathname,
    bodySHA256,
  );
  actor.signCount += 1;
  value.prepare(`
    INSERT INTO moderation_operator_challenge_consumptions(
      challenge_id, operator_id, credential_id_sha256,
      verified_assertion_sha256, authenticator_sign_count
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    challengeID,
    actor.operatorID,
    actor.credentialID,
    digest(`${challengeID}-assertion`),
    actor.signCount,
  );
  return { challengeID, pathname };
}

function createAction(value, {
  requester,
  caseReference,
  actionType = "review_start",
  expiresIn = 900,
}) {
  const actionID = uuid();
  const requestSHA256 = digest(`${actionID}-request`);
  const request = consumeBoundChallenge(value, {
    actor: requester,
    actionID,
    actionType,
    caseReference,
    purpose: "request",
    bodySHA256: requestSHA256,
  });
  const needsApproval = actionType !== "review_start";
  value.prepare(`
    INSERT INTO moderation_operator_actions(
      action_id, case_reference_hmac, action_type,
      requester_operator_id, request_challenge_id, request_sha256,
      request_method, request_pathname, required_approvals,
      required_approver_role, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, 'POST', ?, ?, ?, unixepoch() + ?)
  `).run(
    actionID,
    caseReference,
    actionType,
    requester.operatorID,
    request.challengeID,
    requestSHA256,
    request.pathname,
    needsApproval ? 1 : 0,
    needsApproval ? "privacy_approver" : null,
    expiresIn,
  );
  return { actionID, actionType, requester, caseReference };
}

function approveAction(value, action, approver) {
  const approvalSHA256 = digest(`${action.actionID}-approval`);
  const approval = consumeBoundChallenge(value, {
    actor: approver,
    actionID: action.actionID,
    actionType: action.actionType,
    caseReference: action.caseReference,
    purpose: "approve",
    bodySHA256: approvalSHA256,
  });
  value.prepare(`
    INSERT INTO moderation_operator_action_approvals(
      action_id, operator_id, approval_challenge_id, approval_sha256,
      approval_method, approval_pathname
    ) VALUES (?, ?, ?, ?, 'POST', ?)
  `).run(
    action.actionID,
    approver.operatorID,
    approval.challengeID,
    approvalSHA256,
    approval.pathname,
  );
}

/**
 * The canonical occurredAt is read from the database and persisted inside the
 * same transaction. A future D1 adapter must preserve this property (for
 * example through one transactional batch/reservation), rather than trusting
 * a client wall clock.
 */
function appendEvent(value, {
  caseReference,
  sequence,
  previousDigest,
  action,
  eventID = uuid(),
  artifactSHA256 = digest(`${eventID}-artifact`),
  eventSHA256,
  actorSubjectHmacKeyVersion = action.requester.actorSubjectHmacKeyVersion,
  actorSubjectHmac = action.requester.actorSubjectHmac,
}) {
  value.exec("BEGIN IMMEDIATE");
  try {
    const occurredAt = value.prepare(`SELECT unixepoch() AS value`).get().value;
    const canonicalEventDigest = eventSHA256 ?? digest(JSON.stringify({
      caseReference,
      sequence,
      eventID,
      actionID: action.actionID,
      actionType: action.actionType,
      actorSubjectHmacKeyVersion,
      actorSubjectHmac,
      occurredAt,
      previousDigest,
      artifactSHA256,
    }));
    value.prepare(`
      INSERT INTO moderation_evidence_ledger_events(
        case_reference_hmac, sequence, event_id, action_id, action_type,
        actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
        previous_event_sha256, artifact_sha256, event_sha256
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      caseReference,
      sequence,
      eventID,
      action.actionID,
      action.actionType,
      actorSubjectHmacKeyVersion,
      actorSubjectHmac,
      occurredAt,
      previousDigest,
      artifactSHA256,
      canonicalEventDigest,
    );
    value.exec("COMMIT");
    return { eventID, eventSHA256: canonicalEventDigest, action, occurredAt };
  } catch (error) {
    value.exec("ROLLBACK");
    throw error;
  }
}

function insertExport(value, {
  action,
  exportID = uuid(),
  caseReference = action.caseReference,
  eventCount,
  chainHead,
  exportSHA256 = digest(`${exportID}-export`),
  signingKeyID = "moderation-evidence-v1",
  signatureValue = signature(exportID.at(-1) ?? "x"),
  actorSubjectHmacKeyVersion = action.requester.actorSubjectHmacKeyVersion,
  actorSubjectHmac = action.requester.actorSubjectHmac,
}) {
  value.prepare(`
    INSERT INTO moderation_evidence_exports(
      export_id, case_reference_hmac, action_id,
      actor_subject_hmac_key_version, actor_subject_hmac,
      event_count, chain_head_sha256, export_sha256,
      signing_key_id, signature
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    exportID,
    caseReference,
    action.actionID,
    actorSubjectHmacKeyVersion,
    actorSubjectHmac,
    eventCount,
    chainHead,
    exportSHA256,
    signingKeyID,
    signatureValue,
  );
  return { exportID, exportSHA256, signatureValue };
}

function basicLedger() {
  const value = database();
  const triage = registerOperator(value, "triage", "triage");
  const actionA1 = createAction(value, { requester: triage, caseReference: caseA });
  const eventA1 = appendEvent(value, {
    caseReference: caseA,
    sequence: 1,
    previousDigest: genesis,
    action: actionA1,
  });
  const actionB1 = createAction(value, { requester: triage, caseReference: caseB });
  const eventB1 = appendEvent(value, {
    caseReference: caseB,
    sequence: 1,
    previousDigest: genesis,
    action: actionB1,
  });
  return { value, triage, eventA1, eventB1 };
}

function addExportAuthorization(value, previousEvent, sequence) {
  const reviewer = registerOperator(value, `reviewer-${sequence}`, "evidence_reviewer");
  const approver = registerOperator(value, `approver-${sequence}`, "privacy_approver");
  const action = createAction(value, {
    requester: reviewer,
    caseReference: caseA,
    actionType: "evidence_export",
  });
  approveAction(value, action, approver);
  const event = appendEvent(value, {
    caseReference: caseA,
    sequence,
    previousDigest: previousEvent.eventSHA256,
    action,
  });
  return { action, event, reviewer, approver };
}

function exportableLedger() {
  const base = basicLedger();
  return { ...base, ...addExportAuthorization(base.value, base.eventA1, 2) };
}

test("keeps a case-local chain and records database-timed content deletion evidence", () => {
  const { value, eventA1 } = basicLedger();
  const reviewer = registerOperator(value, "reviewer", "evidence_reviewer");
  const approver = registerOperator(value, "approver", "privacy_approver");
  const deletionAction = createAction(value, {
    requester: reviewer,
    caseReference: caseA,
    actionType: "content_delete",
  });
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: deletionAction,
  }), /not fully approved/u);
  approveAction(value, deletionAction, approver);
  const deletionEvent = appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: deletionAction,
  });
  assert.equal(deletionEvent.occurredAt, value.prepare(
    `SELECT unixepoch() AS value`,
  ).get().value);
  assert.deepEqual(value.prepare(`
    SELECT sequence, action_type, actor_subject_hmac_key_version,
           previous_event_sha256, event_sha256, occurred_at
      FROM moderation_evidence_ledger_events
     WHERE case_reference_hmac = ? ORDER BY sequence
  `).all(caseA).map((row) => ({ ...row })), [
    {
      sequence: 1,
      action_type: "review_start",
      actor_subject_hmac_key_version: 1,
      previous_event_sha256: genesis,
      event_sha256: eventA1.eventSHA256,
      occurred_at: eventA1.occurredAt,
    },
    {
      sequence: 2,
      action_type: "content_delete",
      actor_subject_hmac_key_version: 1,
      previous_event_sha256: eventA1.eventSHA256,
      event_sha256: deletionEvent.eventSHA256,
      occurred_at: deletionEvent.occurredAt,
    },
  ]);
  value.close();
});

test("rejects expired actions and mismatched actor pseudonym key versions", () => {
  const { value, triage, eventA1 } = basicLedger();
  const expiring = createAction(value, {
    requester: triage,
    caseReference: caseA,
    expiresIn: 1,
  });
  advanceDatabaseTime(value, 2);
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: expiring,
  }), /action or actor does not match case/u);
  const current = createAction(value, { requester: triage, caseReference: caseA });
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: current,
    actorSubjectHmacKeyVersion: 2,
  }), /action or actor does not match case/u);
  value.close();
});

test("rejects gaps, reordering, cross-case heads and event/action replay", () => {
  const { value, triage, eventA1, eventB1 } = basicLedger();
  const next = createAction(value, { requester: triage, caseReference: caseA });
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: next,
    eventSHA256: genesis,
  }), /CHECK constraint failed/u);
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 3,
    previousDigest: eventA1.eventSHA256,
    action: next,
  }), /sequence must be contiguous/u);
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventB1.eventSHA256,
    action: next,
  }), /previous digest does not match case head/u);
  const duplicated = createAction(value, { requester: triage, caseReference: caseA });
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: duplicated,
    eventID: eventA1.eventID,
  }), /cannot be replayed or replaced/u);
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: eventA1.action,
  }), /cannot be replayed or replaced/u);
  const wrongCase = createAction(value, { requester: triage, caseReference: caseB });
  assert.throws(() => appendEvent(value, {
    caseReference: caseA,
    sequence: 2,
    previousDigest: eventA1.eventSHA256,
    action: wrongCase,
  }), /action or actor does not match case/u);
  value.close();
});

test("exports only the exact head through an approved evidence-export action", () => {
  const { value, action, event, eventB1 } = exportableLedger();
  assert.throws(() => insertExport(value, {
    action,
    eventCount: 3,
    chainHead: event.eventSHA256,
  }), /event count does not match case ledger/u);
  assert.throws(() => insertExport(value, {
    action,
    eventCount: 2,
    chainHead: eventB1.eventSHA256,
  }), /chain head does not match case ledger/u);
  const first = insertExport(value, {
    action,
    eventCount: 2,
    chainHead: event.eventSHA256,
  });
  assert.deepEqual({ ...value.prepare(`
    SELECT action_id, actor_subject_hmac_key_version, signing_key_id
      FROM moderation_evidence_exports WHERE export_id = ?
  `).get(first.exportID) }, {
    action_id: action.actionID,
    actor_subject_hmac_key_version: 1,
    signing_key_id: "moderation-evidence-v1",
  });
  const second = addExportAuthorization(value, event, 3);
  insertExport(value, {
    action: second.action,
    eventCount: 3,
    chainHead: second.event.eventSHA256,
    signingKeyID: "moderation-evidence-v1",
  });
  value.close();
});

test("rejects unapproved, expired and credential-revoked export actions", () => {
  {
    const { value, eventA1 } = basicLedger();
    const reviewer = registerOperator(value, "unapproved-reviewer", "evidence_reviewer");
    const action = createAction(value, {
      requester: reviewer,
      caseReference: caseA,
      actionType: "evidence_export",
    });
    assert.throws(() => insertExport(value, {
      action,
      eventCount: 1,
      chainHead: eventA1.eventSHA256,
    }), /not fully approved/u);
    value.close();
  }
  {
    const { value, action, event } = exportableLedger();
    advanceDatabaseTime(value, 901);
    assert.throws(() => insertExport(value, {
      action,
      eventCount: 2,
      chainHead: event.eventSHA256,
    }), /action or requester is not active/u);
    value.close();
  }
  {
    const { value, action, event, reviewer } = exportableLedger();
    value.prepare(`
      INSERT INTO moderation_operator_credential_events(
        credential_id_sha256, event_type
      ) VALUES (?, 'revoked')
    `).run(reviewer.credentialID);
    assert.throws(() => insertExport(value, {
      action,
      eventCount: 2,
      chainHead: event.eventSHA256,
    }), /action or requester is not active/u);
    value.close();
  }
});

test("rejects export ID, whole-export digest and signature replay", () => {
  const { value, action, event } = exportableLedger();
  const first = insertExport(value, {
    action,
    eventCount: 2,
    chainHead: event.eventSHA256,
  });
  const next = addExportAuthorization(value, event, 3);
  const fields = {
    action: next.action,
    eventCount: 3,
    chainHead: next.event.eventSHA256,
  };
  assert.throws(() => insertExport(value, {
    ...fields,
    exportID: first.exportID,
  }), /cannot be replayed or replaced/u);
  assert.throws(() => insertExport(value, {
    ...fields,
    exportSHA256: first.exportSHA256,
  }), /cannot be replayed or replaced/u);
  assert.throws(() => insertExport(value, {
    ...fields,
    signatureValue: first.signatureValue,
  }), /cannot be replayed or replaced/u);
  value.close();
});

test("blocks UPDATE, DELETE and INSERT OR REPLACE for ledger and export rows", () => {
  const { value, action, event, eventA1 } = exportableLedger();
  const exported = insertExport(value, {
    action,
    eventCount: 2,
    chainHead: event.eventSHA256,
  });
  assert.throws(() => value.exec(`
    UPDATE moderation_evidence_ledger_events
       SET artifact_sha256 = '${"f".repeat(64)}'
  `), /ledger events are append-only/u);
  assert.throws(() => value.exec(`DELETE FROM moderation_evidence_ledger_events`),
    /ledger events cannot be deleted/u);
  assert.throws(() => value.prepare(`
    INSERT OR REPLACE INTO moderation_evidence_ledger_events(
      case_reference_hmac, sequence, event_id, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
      previous_event_sha256, artifact_sha256, event_sha256
    ) SELECT case_reference_hmac, sequence, event_id, action_id, action_type,
             actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
             previous_event_sha256, ?, event_sha256
        FROM moderation_evidence_ledger_events WHERE event_id = ?
  `).run(digest("replacement-artifact"), eventA1.eventID),
  /cannot be replayed or replaced/u);
  assert.throws(() => value.exec(`
    UPDATE moderation_evidence_exports SET signing_key_id = 'moderation-evidence-v2'
  `), /exports are append-only/u);
  assert.throws(() => value.exec(`DELETE FROM moderation_evidence_exports`),
    /exports cannot be deleted/u);
  assert.throws(() => value.prepare(`
    INSERT OR REPLACE INTO moderation_evidence_exports(
      export_id, case_reference_hmac, action_id,
      actor_subject_hmac_key_version, actor_subject_hmac,
      event_count, chain_head_sha256, export_sha256,
      signing_key_id, signature, generated_at
    ) SELECT export_id, case_reference_hmac, action_id,
             actor_subject_hmac_key_version, actor_subject_hmac,
             event_count, chain_head_sha256, export_sha256,
             signing_key_id, signature, generated_at
        FROM moderation_evidence_exports WHERE export_id = ?
  `).run(exported.exportID), /cannot be replayed or replaced/u);
  value.close();
});

test("keeps case and actor pseudonyms under composite foreign-key protection", () => {
  const { value, triage, eventA1 } = basicLedger();
  for (const table of [
    "moderation_evidence_ledger_events",
    "moderation_evidence_exports",
  ]) {
    const foreignKeys = value.prepare(`PRAGMA foreign_key_list(${table})`).all();
    assert.ok(foreignKeys.some(
      (foreignKey) => foreignKey.table === "moderation_operator_case_references"
        && foreignKey.from === "case_reference_hmac",
    ));
    assert.ok(foreignKeys.some(
      (foreignKey) => foreignKey.table === "moderation_operator_subject_identities"
        && foreignKey.from === "actor_subject_hmac_key_version",
    ));
  }
  const action = createAction(value, { requester: triage, caseReference: caseA });
  assert.throws(() => appendEvent(value, {
    caseReference: digest("unknown-case"),
    sequence: 1,
    previousDigest: genesis,
    action,
  }), /action or actor does not match case|FOREIGN KEY constraint failed/u);
  assert.equal(value.prepare(`
    SELECT actor_subject_hmac FROM moderation_evidence_ledger_events
     WHERE event_id = ?
  `).get(eventA1.eventID).actor_subject_hmac, triage.actorSubjectHmac);
  value.close();
});
