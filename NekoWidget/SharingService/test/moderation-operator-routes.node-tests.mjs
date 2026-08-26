import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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
];
const migrations = await Promise.all(migrationNames.map((name) => readFile(
  join(projectDirectory, "migrations", name),
  "utf8",
)));

const reports = ["moderation-route-a", "moderation-route-b"];
const caseReferences = [digest("route-case-a"), digest("route-case-b")];
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

function database({ through = 15 } = {}) {
  identifierCounter = 1;
  const value = new DatabaseSync(":memory:");
  const clock = { now: 1_900_000_000 };
  clocks.set(value, clock);
  value.function("unixepoch", () => clock.now);
  value.exec("PRAGMA foreign_keys = ON");
  value.exec(`
    CREATE TABLE moment_report_tombstones (
      report_id TEXT PRIMARY KEY,
      committed_at INTEGER NOT NULL
    ) STRICT;
  `);
  value.prepare(`
    INSERT INTO moment_report_tombstones(report_id, committed_at)
    VALUES (?, unixepoch() - 60), (?, unixepoch() - 60)
  `).run(...reports);
  for (let index = 0; index < through - 11; index += 1) {
    value.exec(migrations[index]);
  }
  for (let index = 0; index < reports.length; index += 1) {
    value.prepare(`
      INSERT INTO moderation_operator_case_references(
        report_id, case_reference_hmac
      ) VALUES (?, ?)
    `).run(reports[index], caseReferences[index]);
  }
  return value;
}

function now(value) {
  return clocks.get(value).now;
}

function advance(value, seconds) {
  clocks.get(value).now += seconds;
}

function registerOperator(value, label, roles) {
  const operatorID = uuid();
  const subjectHmac = digest(`${label}-subject`);
  const credentialID = digest(`${label}-credential`);
  value.prepare("INSERT INTO moderation_operators(operator_id) VALUES (?)")
    .run(operatorID);
  value.prepare(`
    INSERT INTO moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version, access_subject_hmac
    ) VALUES (?, 1, ?)
  `).run(operatorID, subjectHmac);
  value.prepare(`
    INSERT INTO moderation_operator_state_events(operator_id, event_type)
    VALUES (?, 'activated')
  `).run(operatorID);
  for (const role of roles) {
    value.prepare(`
      INSERT INTO moderation_operator_role_events(
        operator_id, role_code, event_type
      ) VALUES (?, ?, 'granted')
    `).run(operatorID, role);
  }
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
    subjectHmac,
    subjectHmacKeyVersion: 1,
    credentialID,
    signCount: 0,
  };
}

function reserveCase(value, actor, caseReference, {
  expiresIn = 300,
  sessionSHA256 = digest(`${actor.operatorID}-${caseReference}-session`),
} = {}) {
  const reservationID = uuid();
  value.prepare(`
    INSERT INTO moderation_case_reservations(
      reservation_id, case_reference_hmac, operator_id,
      access_subject_hmac_key_version, access_session_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, unixepoch() + ?)
  `).run(
    reservationID,
    caseReference,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    sessionSHA256,
    expiresIn,
  );
  return { reservationID, sessionSHA256 };
}

function prepareChallenge(value, actor, {
  actionID,
  actionType,
  caseReference,
  purpose,
  bodySHA256,
  sessionSHA256 = digest(`${actionID}-${purpose}-session`),
  expiresIn = 300,
}) {
  const challengeID = uuid();
  const pathname = `/operator/v1/evidence/${actionID}`;
  value.prepare(`
    INSERT INTO moderation_operator_challenges(
      challenge_id, operator_id, access_subject_hmac_key_version,
      credential_id_sha256, access_session_sha256,
      challenge_value_sha256, purpose, action_type, action_id,
      case_reference_hmac, method, pathname, body_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'POST', ?, ?, unixepoch() + ?)
  `).run(
    challengeID,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    actor.credentialID,
    sessionSHA256,
    digest(`${challengeID}-challenge`),
    purpose,
    actionType,
    actionID,
    caseReference,
    pathname,
    bodySHA256,
    expiresIn,
  );
  return { challengeID, pathname, sessionSHA256 };
}

function consumeChallenge(value, actor, challengeID) {
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
}

function createAction(value, actor, {
  actionType,
  caseReference,
  sessionSHA256,
  expiresIn = 900,
}) {
  const actionID = uuid();
  const requestSHA256 = digest(`${actionID}-request`);
  const challenge = prepareChallenge(value, actor, {
    actionID,
    actionType,
    caseReference,
    purpose: "request",
    bodySHA256: requestSHA256,
    sessionSHA256,
  });
  consumeChallenge(value, actor, challenge.challengeID);
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
    actor.operatorID,
    challenge.challengeID,
    requestSHA256,
    challenge.pathname,
    needsApproval ? 1 : 0,
    needsApproval ? "privacy_approver" : null,
    expiresIn,
  );
  return { actionID, actionType, caseReference, actor };
}

function approveAction(value, action, approver) {
  const approvalSHA256 = digest(`${action.actionID}-approval`);
  const challenge = prepareChallenge(value, approver, {
    actionID: action.actionID,
    actionType: action.actionType,
    caseReference: action.caseReference,
    purpose: "approve",
    bodySHA256: approvalSHA256,
  });
  consumeChallenge(value, approver, challenge.challengeID);
  value.prepare(`
    INSERT INTO moderation_operator_action_approvals(
      action_id, operator_id, approval_challenge_id, approval_sha256,
      approval_method, approval_pathname
    ) VALUES (?, ?, ?, ?, 'POST', ?)
  `).run(
    action.actionID,
    approver.operatorID,
    challenge.challengeID,
    approvalSHA256,
    challenge.pathname,
  );
}

function createIntent(value, action, {
  eventID = uuid(),
  artifactSHA256 = digest(`${eventID}-artifact`),
  outcomeCode = null,
} = {}) {
  return value.prepare(`
    INSERT INTO moderation_evidence_event_intents(
      event_id, case_reference_hmac, sequence, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
      previous_event_sha256, artifact_sha256, case_outcome_code,
      legacy_backfill
    ) VALUES (
      ?, ?,
      COALESCE((
        SELECT MAX(sequence) + 1
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = ?
      ), 1),
      ?, ?, ?, ?, unixepoch(),
      COALESCE((
        SELECT event_sha256
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = ?
         ORDER BY sequence DESC LIMIT 1
      ), ?),
      ?, ?, 0
    ) RETURNING *
  `).get(
    eventID,
    action.caseReference,
    action.caseReference,
    action.actionID,
    action.actionType,
    action.actor.subjectHmacKeyVersion,
    action.actor.subjectHmac,
    action.caseReference,
    genesis,
    artifactSHA256,
    outcomeCode,
  );
}

function finalizeIntent(value, intent, overrides = {}) {
  const event = {
    case_reference_hmac: intent.case_reference_hmac,
    sequence: intent.sequence,
    event_id: intent.event_id,
    action_id: intent.action_id,
    action_type: intent.action_type,
    actor_subject_hmac_key_version: intent.actor_subject_hmac_key_version,
    actor_subject_hmac: intent.actor_subject_hmac,
    occurred_at: intent.occurred_at,
    previous_event_sha256: intent.previous_event_sha256,
    artifact_sha256: intent.artifact_sha256,
    ...overrides,
  };
  const eventSHA256 = digest(JSON.stringify(event));
  value.prepare(`
    INSERT INTO moderation_evidence_ledger_events(
      case_reference_hmac, sequence, event_id, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
      previous_event_sha256, artifact_sha256, event_sha256
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    event.case_reference_hmac,
    event.sequence,
    event.event_id,
    event.action_id,
    event.action_type,
    event.actor_subject_hmac_key_version,
    event.actor_subject_hmac,
    event.occurred_at,
    event.previous_event_sha256,
    event.artifact_sha256,
    eventSHA256,
  );
  return eventSHA256;
}

function fixture() {
  const value = database();
  const triage = registerOperator(value, "triage", ["triage"]);
  const reviewer = registerOperator(value, "reviewer", ["evidence_reviewer"]);
  const approver = registerOperator(value, "approver", ["privacy_approver"]);
  return { value, triage, reviewer, approver };
}

function materializeReviewStart(value, triage, caseReference) {
  const reservation = reserveCase(value, triage, caseReference);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference,
    sessionSHA256: reservation.sessionSHA256,
  });
  const intent = createIntent(value, action);
  const eventSHA256 = finalizeIntent(value, intent);
  return { reservation, action, intent, eventSHA256 };
}

test("0015 applies and adds only fail-closed operator database foundations", () => {
  const value = database();
  const names = value.prepare(`
    SELECT name FROM sqlite_schema
     WHERE type = 'table'
       AND name IN (
         'moderation_case_reservations',
         'moderation_case_reservation_consumptions',
         'moderation_evidence_event_intents',
         'moderation_evidence_event_finalizations',
         'moderation_operator_case_event_links'
       )
     ORDER BY name
  `).all().map((row) => row.name);
  assert.equal(names.length, 5);
  assert.equal(value.prepare("PRAGMA foreign_keys").get().foreign_keys, 1);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
  `).get().count, 0);
});

test("reservation is not review start and review action consumes its exact lease", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
  `).get().count, 0);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_evidence_ledger_events
  `).get().count, 0);

  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  assert.deepEqual({ ...value.prepare(`
    SELECT reservation_id, action_id
      FROM moderation_case_reservation_consumptions
  `).get() }, {
    reservation_id: reservation.reservationID,
    action_id: action.actionID,
  });

  assert.throws(() => createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  }), /one active bound reservation/u);
});

test("case and operator reservation races fail closed", () => {
  const { value, triage } = fixture();
  const other = registerOperator(value, "other-triage", ["triage"]);
  reserveCase(value, triage, caseReferences[0]);
  assert.throws(
    () => reserveCase(value, other, caseReferences[0]),
    /already reserved/u,
  );
  assert.throws(
    () => reserveCase(value, triage, caseReferences[1]),
    /already has an active reservation/u,
  );
});

test("reservation expiry is inclusive at the bound and rejected afterward", () => {
  const first = fixture();
  const lease = reserveCase(first.value, first.triage, caseReferences[0]);
  const actionID = uuid();
  const bodySHA256 = digest("boundary-action");
  const challenge = prepareChallenge(first.value, first.triage, {
    actionID,
    actionType: "review_start",
    caseReference: caseReferences[0],
    purpose: "request",
    bodySHA256,
    sessionSHA256: lease.sessionSHA256,
  });
  advance(first.value, 300);
  consumeChallenge(first.value, first.triage, challenge.challengeID);
  first.value.prepare(`
    INSERT INTO moderation_operator_actions(
      action_id, case_reference_hmac, action_type,
      requester_operator_id, request_challenge_id, request_sha256,
      request_method, request_pathname, required_approvals,
      required_approver_role, expires_at
    ) VALUES (?, ?, 'review_start', ?, ?, ?, 'POST', ?, 0, NULL,
              unixepoch() + 900)
  `).run(
    actionID,
    caseReferences[0],
    first.triage.operatorID,
    challenge.challengeID,
    bodySHA256,
    challenge.pathname,
  );

  const second = fixture();
  const expired = reserveCase(second.value, second.triage, caseReferences[0]);
  advance(second.value, 301);
  assert.throws(() => createAction(second.value, second.triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: expired.sessionSHA256,
  }), /one active bound reservation/u);
});

test("an unfinished review blocks one case and operator only until its DB deadline", () => {
  const { value, triage } = fixture();
  const other = registerOperator(value, "deadline-other", ["triage"]);
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  const intent = createIntent(value, action);

  assert.throws(
    () => reserveCase(value, other, caseReferences[0]),
    /already reserved/u,
  );
  assert.throws(
    () => reserveCase(value, triage, caseReferences[1]),
    /already has an active reservation/u,
  );

  advance(value, 121);
  assert.throws(() => finalizeIntent(value, intent), /open intent/u);
  assert.doesNotThrow(() => reserveCase(value, other, caseReferences[0]));
  assert.doesNotThrow(() => reserveCase(value, triage, caseReferences[1]));
});

test("one operator cannot leave pending evidence across multiple cases", () => {
  const { value, reviewer, approver } = fixture();
  const first = createAction(value, reviewer, {
    actionType: "evidence_export",
    caseReference: caseReferences[0],
  });
  approveAction(value, first, approver);
  createIntent(value, first);

  const second = createAction(value, reviewer, {
    actionType: "evidence_export",
    caseReference: caseReferences[1],
  });
  approveAction(value, second, approver);
  assert.throws(() => createIntent(value, second), /operator already has/u);
  advance(value, 121);
  assert.equal(createIntent(value, second).sequence, 1);
});

test("DB-timed intent survives clock advance and finalizes case atomically", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  const intent = createIntent(value, action);
  assert.equal(intent.occurred_at, now(value));
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
  `).get().count, 0);

  advance(value, 120);
  const eventSHA256 = finalizeIntent(value, intent);
  assert.equal(value.prepare(`
    SELECT event_sha256 FROM moderation_evidence_event_finalizations
     WHERE event_id = ?
  `).get(intent.event_id).event_sha256, eventSHA256);
  assert.deepEqual({ ...value.prepare(`
    SELECT event_type, outcome_code FROM moderation_case_events
     WHERE report_id = ?
  `).get(reports[0]) }, { event_type: "review_started", outcome_code: null });
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_case_event_links
     WHERE action_id = ?
  `).get(action.actionID).count, 1);
});

test("finalization resumes after action expiry and operator revocation within its fixed window", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
    expiresIn: 10,
  });
  const intent = createIntent(value, action);
  advance(value, 11);
  value.prepare(`
    INSERT INTO moderation_operator_state_events(operator_id, event_type)
    VALUES (?, 'revoked')
  `).run(triage.operatorID);
  assert.doesNotThrow(() => finalizeIntent(value, intent));
});

test("a database clock rollback cannot create a backward evidence chain", () => {
  const { value, triage, reviewer, approver } = fixture();
  materializeReviewStart(value, triage, caseReferences[0]);
  advance(value, -1);
  const action = createAction(value, reviewer, {
    actionType: "evidence_export",
    caseReference: caseReferences[0],
  });
  approveAction(value, action, approver);
  assert.throws(() => createIntent(value, action), /time precedes the case head/u);
});

test("an action cannot record evidence under a different subject alias version", () => {
  const { value, triage } = fixture();
  const secondSubjectHmac = digest("triage-second-subject");
  value.prepare(`
    INSERT INTO moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version, access_subject_hmac
    ) VALUES (?, 2, ?)
  `).run(triage.operatorID, secondSubjectHmac);
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  assert.throws(() => createIntent(value, {
    ...action,
    actor: {
      ...triage,
      subjectHmacKeyVersion: 2,
      subjectHmac: secondSubjectHmac,
    },
  }), /action or actor does not match/u);
});

test("canonical field tampering and replay fail without consuming the pending intent", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  const intent = createIntent(value, action);
  for (const overrides of [
    { case_reference_hmac: caseReferences[1] },
    { sequence: intent.sequence + 1 },
    { event_id: uuid() },
    { action_id: uuid() },
    { action_type: "evidence_export" },
    { actor_subject_hmac_key_version: 2 },
    { actor_subject_hmac: digest("tampered-actor") },
    { occurred_at: intent.occurred_at + 1 },
    { previous_event_sha256: digest("tampered-head") },
    { artifact_sha256: digest("tampered-artifact") },
  ]) {
    assert.throws(() => finalizeIntent(value, intent, overrides));
  }
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_evidence_event_finalizations
     WHERE event_id = ?
  `).get(intent.event_id).count, 0);
  finalizeIntent(value, intent);
  assert.throws(() => finalizeIntent(value, intent), /replayed|UNIQUE/u);
});

test("one pending intent locks only its own case head", () => {
  const { value, triage, reviewer, approver } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const start = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  createIntent(value, start);

  const sameCase = createAction(value, reviewer, {
    actionType: "evidence_export",
    caseReference: caseReferences[0],
  });
  approveAction(value, sameCase, approver);
  assert.throws(() => createIntent(value, sameCase), /pending evidence intent/u);

  const otherCase = createAction(value, reviewer, {
    actionType: "evidence_export",
    caseReference: caseReferences[1],
  });
  approveAction(value, otherCase, approver);
  assert.equal(createIntent(value, otherCase).sequence, 1);
});

test("review decisions stay disabled until their outcome joins the canonical evidence", () => {
  const { value, triage, reviewer, approver } = fixture();
  materializeReviewStart(value, triage, caseReferences[0]);
  advance(value, 1);
  const decision = createAction(value, reviewer, {
    actionType: "review_decision",
    caseReference: caseReferences[0],
  });
  approveAction(value, decision, approver);
  assert.throws(
    () => createIntent(value, decision, { outcomeCode: "warning" }),
    /domain-changing evidence is not enabled/u,
  );
  assert.deepEqual(value.prepare(`
    SELECT event_type, outcome_code FROM moderation_case_events
    WHERE report_id = ? ORDER BY recorded_at, event_type
  `).all(reports[0]).map((row) => ({ ...row })), [
    { event_type: "review_started", outcome_code: null },
  ]);
});

test("content deletion cannot create an evidence intent before domain outbox", () => {
  const { value, reviewer, approver } = fixture();
  const action = createAction(value, reviewer, {
    actionType: "content_delete",
    caseReference: caseReferences[0],
  });
  approveAction(value, action, approver);
  assert.throws(() => createIntent(value, action), /not enabled/u);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_evidence_event_intents
  `).get().count, 0);
});

test("transaction failure rolls back action, lease consumption and intent", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  value.exec("BEGIN IMMEDIATE");
  try {
    const action = createAction(value, triage, {
      actionType: "review_start",
      caseReference: caseReferences[0],
      sessionSHA256: reservation.sessionSHA256,
    });
    createIntent(value, action);
    value.exec("INSERT INTO moderation_cases(report_id, committed_at, review_due_at) VALUES ('invalid', 1, 2)");
    value.exec("COMMIT");
    assert.fail("transaction should have failed");
  } catch {
    value.exec("ROLLBACK");
  }
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_actions
  `).get().count, 0);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_reservation_consumptions
  `).get().count, 0);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_evidence_event_intents
  `).get().count, 0);
});

test("a later transaction failure rolls back ledger, finalization and case transition", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
    sessionSHA256: reservation.sessionSHA256,
  });
  const intent = createIntent(value, action);

  value.exec("BEGIN IMMEDIATE");
  try {
    finalizeIntent(value, intent);
    value.exec("INSERT INTO moderation_cases(report_id, committed_at, review_due_at) VALUES ('invalid', 1, 2)");
    value.exec("COMMIT");
    assert.fail("transaction should have failed");
  } catch {
    value.exec("ROLLBACK");
  }

  for (const table of [
    "moderation_evidence_ledger_events",
    "moderation_evidence_event_finalizations",
    "moderation_case_events",
    "moderation_operator_case_event_links",
  ]) {
    assert.equal(value.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get().count, 0);
  }
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_evidence_event_intents
     WHERE event_id = ?
  `).get(intent.event_id).count, 1);
});

test("case lifecycle rows cannot be inserted without finalized operator evidence", () => {
  const { value } = fixture();
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_case_events(report_id, event_type, outcome_code)
    VALUES (?, 'review_started', NULL)
  `).run(reports[0]), /requires finalized operator evidence/u);
});

test("0015 backfills existing ledger without inventing case lifecycle events", () => {
  const value = database({ through: 14 });
  const triage = registerOperator(value, "legacy-triage", ["triage"]);
  const action = createAction(value, triage, {
    actionType: "review_start",
    caseReference: caseReferences[0],
  });
  const eventID = uuid();
  const eventSHA256 = digest("legacy-event");
  value.prepare(`
    INSERT INTO moderation_evidence_ledger_events(
      case_reference_hmac, sequence, event_id, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
      previous_event_sha256, artifact_sha256, event_sha256
    ) VALUES (?, 1, ?, ?, 'review_start', 1, ?, unixepoch(), ?, ?, ?)
  `).run(
    caseReferences[0],
    eventID,
    action.actionID,
    triage.subjectHmac,
    genesis,
    digest("legacy-artifact"),
    eventSHA256,
  );
  value.exec(migrations[3]);
  assert.deepEqual({ ...value.prepare(`
    SELECT legacy_backfill FROM moderation_evidence_event_intents
     WHERE event_id = ?
  `).get(eventID) }, { legacy_backfill: 1 });
  assert.equal(value.prepare(`
    SELECT event_sha256 FROM moderation_evidence_event_finalizations
     WHERE event_id = ?
  `).get(eventID).event_sha256, eventSHA256);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
  `).get().count, 0);
});

test("new operator foundation rows are append-only", () => {
  const { value, triage } = fixture();
  const reservation = reserveCase(value, triage, caseReferences[0]);
  assert.throws(() => value.prepare(`
    UPDATE moderation_case_reservations SET expires_at = expires_at + 1
     WHERE reservation_id = ?
  `).run(reservation.reservationID), /append-only/u);
  assert.throws(() => value.prepare(`
    DELETE FROM moderation_case_reservations WHERE reservation_id = ?
  `).run(reservation.reservationID), /cannot be deleted/u);
});
