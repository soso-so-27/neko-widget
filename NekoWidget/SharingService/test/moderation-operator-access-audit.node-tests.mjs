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
  "0016_moderation_operator_access_audit.sql",
];
const migrations = await Promise.all(migrationNames.map((name) => readFile(
  join(projectDirectory, "migrations", name),
  "utf8",
)));

const reports = ["access-audit-a", "access-audit-b", "access-audit-c"];
const caseReferences = reports.map((report) => digest(`${report}-case`));
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

function database({ through = 16 } = {}) {
  identifierCounter = 1;
  const value = new DatabaseSync(":memory:");
  clocks.set(value, { now: 1_910_000_000 });
  value.function("unixepoch", () => clocks.get(value).now);
  value.exec("PRAGMA foreign_keys = ON");
  value.exec(`
    CREATE TABLE moment_report_tombstones (
      report_id TEXT PRIMARY KEY,
      committed_at INTEGER NOT NULL
    ) STRICT;
  `);
  for (const report of reports) {
    value.prepare(`
      INSERT INTO moment_report_tombstones(report_id, committed_at)
      VALUES (?, unixepoch() - 60)
    `).run(report);
  }
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

function registerOperator(value, label, roles = ["triage"]) {
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

function rotateAlias(value, actor, label = uuid()) {
  const next = {
    ...actor,
    subjectHmacKeyVersion: actor.subjectHmacKeyVersion + 1,
    subjectHmac: digest(`${label}-rotated-subject`),
  };
  value.prepare(`
    INSERT INTO moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version, access_subject_hmac
    ) VALUES (?, ?, ?)
  `).run(
    next.operatorID,
    next.subjectHmacKeyVersion,
    next.subjectHmac,
  );
  return next;
}

function revokeOperator(value, actor) {
  value.prepare(`
    INSERT INTO moderation_operator_state_events(operator_id, event_type)
    VALUES (?, 'revoked')
  `).run(actor.operatorID);
}

function revokeCredential(value, actor) {
  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'revoked')
  `).run(actor.credentialID);
}

function admitSession(value, actor, {
  label = uuid(),
  lifetime = 900,
  tokenIssuedAt = now(value),
  tokenExpiresAt = tokenIssuedAt + lifetime,
  sessionSHA256 = digest(`${actor.operatorID}-${label}-access-session`),
} = {}) {
  value.prepare(`
    INSERT INTO moderation_operator_access_sessions(
      access_session_sha256, operator_id,
      access_subject_hmac_key_version, access_subject_hmac,
      token_issued_at, token_expires_at
    ) VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    sessionSHA256,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    actor.subjectHmac,
    tokenIssuedAt,
    tokenExpiresAt,
  );
  return sessionSHA256;
}

function reserveCase(value, actor, caseReference, sessionSHA256, expiresIn = 300) {
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
  return reservationID;
}

function issueChallenge(value, actor, {
  actionID = uuid(),
  actionType = "review_start",
  caseReference = caseReferences[0],
  purpose = "request",
  bodySHA256 = digest(`${actionID}-${purpose}-body`),
  sessionSHA256,
  expiresIn = 300,
} = {}) {
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
  return {
    challengeID,
    actionID,
    actionType,
    caseReference,
    purpose,
    bodySHA256,
    pathname,
    sessionSHA256,
  };
}

function attemptAssertion(value, actor, challenge, {
  assertionSHA256 = digest(`${challenge.challengeID}-assertion`),
} = {}) {
  value.prepare(`
    INSERT INTO moderation_operator_assertion_attempts(
      challenge_id, operator_id, access_session_sha256,
      credential_id_sha256, assertion_sha256
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    challenge.challengeID,
    actor.operatorID,
    challenge.sessionSHA256,
    actor.credentialID,
    assertionSHA256,
  );
  return assertionSHA256;
}

function consumeChallenge(value, actor, challenge, assertionSHA256) {
  actor.signCount += 1;
  value.prepare(`
    INSERT INTO moderation_operator_challenge_consumptions(
      challenge_id, operator_id, credential_id_sha256,
      verified_assertion_sha256, authenticator_sign_count
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    challenge.challengeID,
    actor.operatorID,
    actor.credentialID,
    assertionSHA256,
    actor.signCount,
  );
}

function consumeSecureChallenge(value, actor, challenge) {
  const assertionSHA256 = attemptAssertion(value, actor, challenge);
  consumeChallenge(value, actor, challenge, assertionSHA256);
}

function insertAction(value, actor, challenge, { expiresIn = 900 } = {}) {
  const needsApproval = challenge.actionType !== "review_start";
  value.prepare(`
    INSERT INTO moderation_operator_actions(
      action_id, case_reference_hmac, action_type,
      requester_operator_id, request_challenge_id, request_sha256,
      request_method, request_pathname, required_approvals,
      required_approver_role, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, 'POST', ?, ?, ?, unixepoch() + ?)
  `).run(
    challenge.actionID,
    challenge.caseReference,
    challenge.actionType,
    actor.operatorID,
    challenge.challengeID,
    challenge.bodySHA256,
    challenge.pathname,
    needsApproval ? 1 : 0,
    needsApproval ? "privacy_approver" : null,
    expiresIn,
  );
  return {
    actionID: challenge.actionID,
    actionType: challenge.actionType,
    caseReference: challenge.caseReference,
    actor,
    challenge,
  };
}

function createSecureAction(value, actor, {
  actionType = "review_start",
  caseReference = caseReferences[0],
  sessionSHA256,
  expiresIn = 900,
} = {}) {
  const actionID = uuid();
  const requestSHA256 = digest(`${actionID}-request`);
  const challenge = issueChallenge(value, actor, {
    actionID,
    actionType,
    caseReference,
    purpose: "request",
    bodySHA256: requestSHA256,
    sessionSHA256,
  });
  consumeSecureChallenge(value, actor, challenge);
  return insertAction(value, actor, challenge, { expiresIn });
}

function prepareApproval(value, action, approver, sessionSHA256) {
  const approvalSHA256 = digest(`${action.actionID}-approval`);
  const challenge = issueChallenge(value, approver, {
    actionID: action.actionID,
    actionType: action.actionType,
    caseReference: action.caseReference,
    purpose: "approve",
    bodySHA256: approvalSHA256,
    sessionSHA256,
  });
  consumeSecureChallenge(value, approver, challenge);
  return { challenge, approvalSHA256 };
}

function recordApproval(value, action, approver, prepared) {
  value.prepare(`
    INSERT INTO moderation_operator_action_approvals(
      action_id, operator_id, approval_challenge_id, approval_sha256,
      approval_method, approval_pathname
    ) VALUES (?, ?, ?, ?, 'POST', ?)
  `).run(
    action.actionID,
    approver.operatorID,
    prepared.challenge.challengeID,
    prepared.approvalSHA256,
    prepared.challenge.pathname,
  );
}

function createIntent(value, action, eventID = uuid()) {
  return value.prepare(`
    INSERT INTO moderation_evidence_event_intents(
      event_id, case_reference_hmac, sequence, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
      previous_event_sha256, artifact_sha256, case_outcome_code,
      legacy_backfill
    ) VALUES (
      ?, ?, COALESCE((
        SELECT MAX(sequence) + 1 FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = ?
      ), 1), ?, ?, ?, ?, unixepoch(), COALESCE((
        SELECT event_sha256 FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = ? ORDER BY sequence DESC LIMIT 1
      ), ?), ?, NULL, 0
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
    digest(`${eventID}-artifact`),
  );
}

function finalizeIntent(value, intent) {
  const eventSHA256 = digest(JSON.stringify({
    event_id: intent.event_id,
    action_id: intent.action_id,
    occurred_at: intent.occurred_at,
  }));
  value.prepare(`
    INSERT INTO moderation_evidence_ledger_events(
      case_reference_hmac, sequence, event_id, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
      previous_event_sha256, artifact_sha256, event_sha256
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    intent.case_reference_hmac,
    intent.sequence,
    intent.event_id,
    intent.action_id,
    intent.action_type,
    intent.actor_subject_hmac_key_version,
    intent.actor_subject_hmac,
    intent.occurred_at,
    intent.previous_event_sha256,
    intent.artifact_sha256,
    eventSHA256,
  );
  return eventSHA256;
}

function createExport(value, action) {
  const exportID = uuid();
  const ledger = value.prepare(`
    SELECT COUNT(*) AS event_count,
           (SELECT event_sha256
              FROM moderation_evidence_ledger_events
             WHERE case_reference_hmac = ?
             ORDER BY sequence DESC LIMIT 1) AS chain_head
      FROM moderation_evidence_ledger_events
     WHERE case_reference_hmac = ?
  `).get(action.caseReference, action.caseReference);
  value.prepare(`
    INSERT INTO moderation_evidence_exports(
      export_id, case_reference_hmac, action_id,
      actor_subject_hmac_key_version, actor_subject_hmac,
      event_count, chain_head_sha256, export_sha256,
      signing_key_id, signature
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'moderation-evidence-v1', ?)
  `).run(
    exportID,
    action.caseReference,
    action.actionID,
    action.actor.subjectHmacKeyVersion,
    action.actor.subjectHmac,
    ledger.event_count,
    ledger.chain_head,
    digest(`${exportID}-export`),
    Buffer.alloc(64, 7).toString("base64url"),
  );
}

function prepareApprovedExport(value, label) {
  const requester = registerOperator(
    value,
    `${label}-requester`,
    ["evidence_reviewer"],
  );
  const approver = registerOperator(
    value,
    `${label}-approver`,
    ["privacy_approver"],
  );
  const action = createSecureAction(value, requester, {
    actionType: "evidence_export",
    sessionSHA256: admitSession(value, requester),
  });
  const approval = prepareApproval(
    value,
    action,
    approver,
    admitSession(value, approver),
  );
  recordApproval(value, action, approver, approval);
  finalizeIntent(value, createIntent(value, action));
  return { action, requester, approver };
}

function startAudit(value, actor, sessionSHA256, {
  operation = "case_read",
  requestSHA256 = digest(`${operation}-${uuid()}-request`),
  caseReference = null,
} = {}) {
  const auditRequestID = uuid();
  value.prepare(`
    INSERT INTO moderation_operator_access_audit_starts(
      audit_request_id, operator_id, access_session_sha256,
      operation_code, request_sha256, case_reference_hmac
    ) VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    auditRequestID,
    actor.operatorID,
    sessionSHA256,
    operation,
    requestSHA256,
    caseReference,
  );
  return { auditRequestID, operation, requestSHA256, caseReference };
}

function finishAudit(value, actor, sessionSHA256, started, {
  outcome = "succeeded",
  status = 200,
  ...overrides
} = {}) {
  value.prepare(`
    INSERT INTO moderation_operator_access_audit_finishes(
      audit_request_id, operator_id, access_session_sha256,
      operation_code, request_sha256, case_reference_hmac,
      outcome_code, status_code
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    overrides.auditRequestID ?? started.auditRequestID,
    overrides.operatorID ?? actor.operatorID,
    overrides.sessionSHA256 ?? sessionSHA256,
    overrides.operation ?? started.operation,
    overrides.requestSHA256 ?? started.requestSHA256,
    Object.hasOwn(overrides, "caseReference")
      ? overrides.caseReference
      : started.caseReference,
    outcome,
    status,
  );
}

function prepareLegacyChallenge(value, actor, {
  actionID,
  caseReference,
  sessionSHA256,
} = {}) {
  const challengeID = uuid();
  const bodySHA256 = digest(`${actionID}-legacy-request`);
  const pathname = `/operator/v1/evidence/${actionID}`;
  value.prepare(`
    INSERT INTO moderation_operator_challenges(
      challenge_id, operator_id, access_subject_hmac_key_version,
      credential_id_sha256, access_session_sha256,
      challenge_value_sha256, purpose, action_type, action_id,
      case_reference_hmac, method, pathname, body_sha256, expires_at
    ) VALUES (?, ?, 1, ?, ?, ?, 'request', 'review_start', ?, ?,
              'POST', ?, ?, unixepoch() + 300)
  `).run(
    challengeID,
    actor.operatorID,
    actor.credentialID,
    sessionSHA256,
    digest(`${challengeID}-challenge`),
    actionID,
    caseReference,
    pathname,
    bodySHA256,
  );
  return {
    challengeID,
    actionID,
    actionType: "review_start",
    caseReference,
    bodySHA256,
    pathname,
    sessionSHA256,
  };
}

function consumeLegacyChallenge(value, actor, challenge) {
  actor.signCount += 1;
  value.prepare(`
    INSERT INTO moderation_operator_challenge_consumptions(
      challenge_id, operator_id, credential_id_sha256,
      verified_assertion_sha256, authenticator_sign_count
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    challenge.challengeID,
    actor.operatorID,
    actor.credentialID,
    digest(`${challenge.challengeID}-legacy-assertion`),
    actor.signCount,
  );
}

function createLegacyReviewAction(value, actor, caseReference) {
  const sessionSHA256 = digest(`${actor.operatorID}-${caseReference}-legacy-session`);
  reserveCase(value, actor, caseReference, sessionSHA256);
  const actionID = uuid();
  const challenge = prepareLegacyChallenge(value, actor, {
    actionID,
    caseReference,
    sessionSHA256,
  });
  consumeLegacyChallenge(value, actor, challenge);
  value.prepare(`
    INSERT INTO moderation_operator_actions(
      action_id, case_reference_hmac, action_type,
      requester_operator_id, request_challenge_id, request_sha256,
      request_method, request_pathname, required_approvals,
      required_approver_role, expires_at
    ) VALUES (?, ?, 'review_start', ?, ?, ?, 'POST', ?, 0, NULL,
              unixepoch() + 900)
  `).run(
    actionID,
    caseReference,
    actor.operatorID,
    challenge.challengeID,
    challenge.bodySHA256,
    challenge.pathname,
  );
  return {
    actionID,
    actionType: "review_start",
    caseReference,
    actor,
    challenge,
  };
}

test("0016 is additive, empty on migration, and stores no raw identity material", () => {
  const value = database();
  const expectedTables = [
    "moderation_operator_access_sessions",
    "moderation_operator_challenge_access_links",
    "moderation_case_reservation_access_links",
    "moderation_operator_assertion_attempts",
    "moderation_operator_access_audit_starts",
    "moderation_operator_access_audit_finishes",
  ];
  for (const table of expectedTables) {
    assert.equal(
      value.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get().count,
      0,
    );
    const columns = value.prepare(`PRAGMA table_info(${table})`).all()
      .map((column) => column.name);
    for (const forbidden of [
      "jwt", "email", "name", "kid", "raw_subject", "raw_assertion",
      "credential_id", "access_token", "profile",
    ]) {
      assert.equal(columns.includes(forbidden), false, `${table}.${forbidden}`);
    }
    assert.equal(columns.some((column) => column.startsWith("raw_")), false);
  }
  assert.deepEqual(
    value.prepare(`
      SELECT name FROM sqlite_master
       WHERE type = 'table' AND name LIKE 'moderation_operator_access_%'
       ORDER BY name
    `).all().map((row) => row.name),
    [
      "moderation_operator_access_audit_finishes",
      "moderation_operator_access_audit_starts",
      "moderation_operator_access_migration_fence",
      "moderation_operator_access_sessions",
    ],
  );
  const fence = value.prepare(`
    SELECT migration_version, challenge_rowid_high_water,
           reservation_rowid_high_water
      FROM moderation_operator_access_migration_fence
  `).get();
  assert.equal(fence.migration_version, 16);
  assert.equal(fence.challenge_rowid_high_water, 0);
  assert.equal(fence.reservation_rowid_high_water, 0);
  const challengeRateIndex = value.prepare(`
    SELECT name FROM pragma_index_list('moderation_operator_challenges')
     WHERE name = 'moderation_operator_challenges_operator_issued_at'
  `).get();
  assert.equal(
    challengeRateIndex.name,
    "moderation_operator_challenges_operator_issued_at",
  );
  assert.deepEqual(value.prepare(`
    SELECT name FROM pragma_index_info(
      'moderation_operator_challenges_operator_issued_at'
    ) ORDER BY seqno
  `).all().map(({ name }) => name), [
    "operator_id",
    "issued_at",
    "challenge_id",
  ]);
});

test("Access admission is DB-timed, current-alias-only, bounded, and append-only", () => {
  const value = database();
  const actor = registerOperator(value, "session-bounds");
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_access_sessions(
      access_session_sha256, operator_id,
      access_subject_hmac_key_version, access_subject_hmac,
      token_issued_at, token_expires_at, admitted_at
    ) VALUES (?, ?, 1, ?, unixepoch(), unixepoch() + 900, unixepoch() - 1)
  `).run(digest("spoofed-time"), actor.operatorID, actor.subjectHmac),
  /database admission time/);
  assert.throws(() => admitSession(value, actor, { lifetime: 901 }),
    /CHECK constraint failed/);

  const first = admitSession(value, actor, { label: "live-1" });
  admitSession(value, actor, { label: "live-2" });
  admitSession(value, actor, { label: "live-3" });
  admitSession(value, actor, { label: "live-4" });
  assert.throws(() => admitSession(value, actor, { label: "live-5" }),
    /too many live access sessions/);
  assert.throws(() => value.prepare(`
    UPDATE moderation_operator_access_sessions
       SET token_expires_at = token_expires_at + 1
     WHERE access_session_sha256 = ?
  `).run(first), /append-only/);
  assert.throws(() => value.prepare(`
    DELETE FROM moderation_operator_access_sessions
     WHERE access_session_sha256 = ?
  `).run(first), /cannot be deleted/);

  advance(value, 901);
  for (let group = 0; group < 2; group += 1) {
    for (let index = 0; index < 4; index += 1) {
      admitSession(value, actor, { label: `rate-${group}-${index}` });
    }
    advance(value, 901);
  }
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_access_sessions
     WHERE operator_id = ?
  `).get(actor.operatorID).count, 12);
  assert.throws(() => admitSession(value, actor, { label: "rate-13" }),
    /admission rate exceeded/);
  advance(value, 899);
  assert.doesNotThrow(() => admitSession(value, actor, {
    label: "outside-rolling-hour",
  }));
});

test("old aliases and revoked operators cannot admit or continue sessions", () => {
  const value = database();
  const actor = registerOperator(value, "alias-rotation");
  const oldSession = admitSession(value, actor, { label: "old-alias" });
  const currentActor = rotateAlias(value, actor, "alias-rotation-v2");
  assert.throws(() => admitSession(value, actor, { label: "stale" }),
    /alias is not current/);
  assert.throws(() => issueChallenge(value, currentActor, {
    sessionSHA256: oldSession,
  }), /live access session/);
  assert.throws(() => reserveCase(
    value,
    actor,
    caseReferences[0],
    oldSession,
  ), /live access session/);

  const fresh = admitSession(value, currentActor, { label: "fresh-alias" });
  assert.doesNotThrow(() => reserveCase(
    value,
    currentActor,
    caseReferences[0],
    fresh,
  ));
  revokeOperator(value, currentActor);
  assert.throws(() => startAudit(value, currentActor, fresh),
    /live access session/);
});

test("alias rotation invalidates every pre-intent admission boundary", () => {
  const consumptionValue = database();
  const consumptionActor = registerOperator(consumptionValue, "rotate-consume");
  const consumptionSession = admitSession(consumptionValue, consumptionActor);
  const consumptionChallenge = issueChallenge(
    consumptionValue,
    consumptionActor,
    { sessionSHA256: consumptionSession },
  );
  const assertion = attemptAssertion(
    consumptionValue,
    consumptionActor,
    consumptionChallenge,
  );
  rotateAlias(consumptionValue, consumptionActor);
  assert.throws(() => consumeChallenge(
    consumptionValue,
    consumptionActor,
    consumptionChallenge,
    assertion,
  ), /exact assertion attempt/);

  const actionValue = database();
  const actionActor = registerOperator(actionValue, "rotate-action");
  const actionSession = admitSession(actionValue, actionActor);
  reserveCase(actionValue, actionActor, caseReferences[0], actionSession);
  const actionChallenge = issueChallenge(actionValue, actionActor, {
    sessionSHA256: actionSession,
  });
  consumeSecureChallenge(actionValue, actionActor, actionChallenge);
  rotateAlias(actionValue, actionActor);
  assert.throws(() => insertAction(
    actionValue,
    actionActor,
    actionChallenge,
  ), /admitted assertion attempt/);

  const intentValue = database();
  const intentActor = registerOperator(intentValue, "rotate-intent");
  const intentSession = admitSession(intentValue, intentActor);
  reserveCase(intentValue, intentActor, caseReferences[0], intentSession);
  const action = createSecureAction(intentValue, intentActor, {
    sessionSHA256: intentSession,
  });
  rotateAlias(intentValue, intentActor);
  assert.throws(() => createIntent(intentValue, action),
    /admitted request attempt/);

  const approvalValue = database();
  const requester = registerOperator(
    approvalValue,
    "rotate-approval-requester",
    ["evidence_reviewer"],
  );
  const approver = registerOperator(
    approvalValue,
    "rotate-approval-approver",
    ["privacy_approver"],
  );
  const requesterSession = admitSession(approvalValue, requester);
  const approverSession = admitSession(approvalValue, approver);
  const approvalAction = createSecureAction(approvalValue, requester, {
    actionType: "evidence_export",
    sessionSHA256: requesterSession,
  });
  const preparedApproval = prepareApproval(
    approvalValue,
    approvalAction,
    approver,
    approverSession,
  );
  rotateAlias(approvalValue, approver);
  assert.throws(() => recordApproval(
    approvalValue,
    approvalAction,
    approver,
    preparedApproval,
  ), /admitted assertion attempt/);

  const approvedIntentValue = database();
  const approvedIntentRequester = registerOperator(
    approvedIntentValue,
    "rotate-approved-intent-requester",
    ["evidence_reviewer"],
  );
  const approvedIntentApprover = registerOperator(
    approvedIntentValue,
    "rotate-approved-intent-approver",
    ["privacy_approver"],
  );
  const approvedIntentAction = createSecureAction(
    approvedIntentValue,
    approvedIntentRequester,
    {
      actionType: "evidence_export",
      sessionSHA256: admitSession(
        approvedIntentValue,
        approvedIntentRequester,
      ),
    },
  );
  const approvedIntentApproval = prepareApproval(
    approvedIntentValue,
    approvedIntentAction,
    approvedIntentApprover,
    admitSession(approvedIntentValue, approvedIntentApprover),
  );
  recordApproval(
    approvedIntentValue,
    approvedIntentAction,
    approvedIntentApprover,
    approvedIntentApproval,
  );
  rotateAlias(approvedIntentValue, approvedIntentApprover);
  assert.throws(() => createIntent(
    approvedIntentValue,
    approvedIntentAction,
  ), /unauditable approval attempt/);
});

test("operator and credential revocation after attempt reject consumption", () => {
  for (const revoke of [revokeOperator, revokeCredential]) {
    const value = database();
    const actor = registerOperator(value, `post-attempt-${revoke.name}`);
    const session = admitSession(value, actor);
    const challenge = issueChallenge(value, actor, {
      sessionSHA256: session,
    });
    const assertion = attemptAssertion(value, actor, challenge);
    revoke(value, actor);
    assert.throws(() => consumeChallenge(
      value,
      actor,
      challenge,
      assertion,
    ), /not active|exact assertion attempt/);
  }
});

test("export requires the requester's current alias at generation time", () => {
  const currentValue = database();
  const current = prepareApprovedExport(currentValue, "current-export");
  assert.doesNotThrow(() => createExport(currentValue, current.action));

  const rotatedValue = database();
  const rotated = prepareApprovedExport(rotatedValue, "rotated-export");
  rotateAlias(rotatedValue, rotated.requester);
  assert.throws(() => createExport(rotatedValue, rotated.action),
    /admitted request attempt/);

  const rotatedApproverValue = database();
  const rotatedApprover = prepareApprovedExport(
    rotatedApproverValue,
    "rotated-approver-export",
  );
  rotateAlias(rotatedApproverValue, rotatedApprover.approver);
  assert.throws(() => createExport(
    rotatedApproverValue,
    rotatedApprover.action,
  ), /unauditable approval attempt/);
});

test("challenge issue and one-shot assertion verification are exact and fail closed", () => {
  const value = database();
  const actor = registerOperator(value, "assertion");
  const intruder = registerOperator(value, "intruder");
  const session = admitSession(value, actor);
  const intruderSession = admitSession(value, intruder);

  assert.throws(() => issueChallenge(value, actor, {
    sessionSHA256: digest("not-admitted"),
  }), /live access session/);
  const challenge = issueChallenge(value, actor, { sessionSHA256: session });
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_assertion_attempts(
      challenge_id, operator_id, access_session_sha256,
      credential_id_sha256, assertion_sha256, attempted_at
    ) VALUES (?, ?, ?, ?, ?, unixepoch() - 1)
  `).run(
    challenge.challengeID,
    actor.operatorID,
    session,
    actor.credentialID,
    digest("spoofed-attempt-time"),
  ), /database time/);
  assert.throws(() => attemptAssertion(value, actor, {
    ...challenge,
    sessionSHA256: intruderSession,
  }), /live challenge/);
  assert.throws(() => attemptAssertion(value, intruder, challenge),
    /live challenge/);

  const failedDigest = attemptAssertion(value, actor, challenge);
  assert.throws(() => attemptAssertion(value, actor, challenge, {
    assertionSHA256: digest("second-try"),
  }), /cannot be replayed/);
  assert.throws(() => consumeChallenge(
    value,
    actor,
    challenge,
    digest("different-assertion"),
  ), /exact assertion attempt/);
  actor.signCount -= 1;
  assert.doesNotThrow(() => consumeChallenge(
    value,
    actor,
    challenge,
    failedDigest,
  ));
  assert.throws(() => value.prepare(`
    UPDATE moderation_operator_assertion_attempts
       SET assertion_sha256 = ? WHERE challenge_id = ?
  `).run(digest("mutated"), challenge.challengeID), /append-only/);
  assert.throws(() => value.prepare(`
    DELETE FROM moderation_operator_assertion_attempts WHERE challenge_id = ?
  `).run(challenge.challengeID), /cannot be deleted/);
});

test("challenge issuance is limited to 12 per operator per rolling 300 seconds", () => {
  const value = database();
  const actor = registerOperator(value, "challenge-rate");
  const session = admitSession(value, actor);
  for (let index = 0; index < 12; index += 1) {
    const challenge = issueChallenge(value, actor, {
      actionID: uuid(),
      sessionSHA256: session,
    });
    consumeSecureChallenge(value, actor, challenge);
  }
  assert.throws(() => issueChallenge(value, actor, {
    actionID: uuid(),
    sessionSHA256: session,
  }), /challenge issue rate exceeded/);
  advance(value, 300);
  assert.doesNotThrow(() => issueChallenge(value, actor, {
    actionID: uuid(),
    sessionSHA256: session,
  }));
});

test("audit start and finish are append-only, sanitized and exactly paired", () => {
  const value = database();
  const actor = registerOperator(value, "audit-pair");
  const other = registerOperator(value, "audit-other");
  const session = admitSession(value, actor);
  const otherSession = admitSession(value, other);
  const started = startAudit(value, actor, session, {
    operation: "case_read",
    caseReference: caseReferences[0],
  });
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_access_audit_starts(
      audit_request_id, operator_id, access_session_sha256,
      operation_code, request_sha256, started_at
    ) VALUES (?, ?, ?, 'case_read', ?, unixepoch() - 1)
  `).run(uuid(), actor.operatorID, session, digest("spoofed-audit-start")),
  /database time/);
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_access_audit_finishes(
      audit_request_id, operator_id, access_session_sha256,
      operation_code, request_sha256, case_reference_hmac,
      outcome_code, status_code, finished_at
    ) VALUES (?, ?, ?, ?, ?, ?, 'succeeded', 200, unixepoch() - 1)
  `).run(
    started.auditRequestID,
    actor.operatorID,
    session,
    started.operation,
    started.requestSHA256,
    started.caseReference,
  ), /database time/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    operatorID: other.operatorID,
  }), /exactly match/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    sessionSHA256: otherSession,
  }), /exactly match/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    operation: "case_reserve",
  }), /exactly match/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    requestSHA256: digest("swapped-request"),
  }), /exactly match/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    caseReference: caseReferences[1],
  }), /exactly match/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    outcome: "succeeded",
    status: 403,
  }), /CHECK constraint failed/);
  assert.throws(() => finishAudit(value, actor, session, started, {
    outcome: "rejected",
    status: 400,
  }), /CHECK constraint failed/);
  assert.doesNotThrow(() => finishAudit(value, actor, session, started));
  assert.throws(() => finishAudit(value, actor, session, started),
    /already finished/);
  const rejected = startAudit(value, actor, session);
  assert.doesNotThrow(() => finishAudit(value, actor, session, rejected, {
    outcome: "rejected_forbidden",
    status: 403,
  }));
  const dependency = startAudit(value, actor, session);
  assert.doesNotThrow(() => finishAudit(value, actor, session, dependency, {
    outcome: "failed_dependency",
    status: 503,
  }));
  assert.throws(() => value.prepare(`
    UPDATE moderation_operator_access_audit_starts
       SET operation_code = 'case_reserve' WHERE audit_request_id = ?
  `).run(started.auditRequestID), /append-only/);
  assert.throws(() => value.prepare(`
    DELETE FROM moderation_operator_access_audit_finishes
     WHERE audit_request_id = ?
  `).run(started.auditRequestID), /cannot be deleted/);
});

test("audit start quotas are exact per session and per operator", () => {
  const sessionValue = database();
  const sessionActor = registerOperator(sessionValue, "session-audit-rate");
  const session = admitSession(sessionValue, sessionActor);
  for (let index = 0; index < 30; index += 1) {
    startAudit(sessionValue, sessionActor, session);
  }
  assert.throws(() => startAudit(sessionValue, sessionActor, session),
    /session request rate exceeded/);
  advance(sessionValue, 60);
  assert.doesNotThrow(() => startAudit(sessionValue, sessionActor, session));

  const operatorValue = database();
  const operator = registerOperator(operatorValue, "operator-audit-rate");
  const sessions = [0, 1, 2].map((index) => admitSession(
    operatorValue,
    operator,
    { label: `operator-rate-${index}` },
  ));
  for (const currentSession of sessions) {
    for (let index = 0; index < 20; index += 1) {
      startAudit(operatorValue, operator, currentSession);
    }
  }
  const fourth = admitSession(operatorValue, operator, { label: "fourth" });
  assert.throws(() => startAudit(operatorValue, operator, fourth),
    /operator request rate exceeded/);
});

test("secure post-0016 review can proceed without treating audit rows as authorization", () => {
  const value = database();
  const actor = registerOperator(value, "secure-review");
  const session = admitSession(value, actor);
  reserveCase(value, actor, caseReferences[0], session);
  const action = createSecureAction(value, actor, {
    sessionSHA256: session,
  });
  const intent = createIntent(value, action);
  const eventSHA256 = finalizeIntent(value, intent);
  assert.equal(value.prepare(`
    SELECT event_sha256 FROM moderation_evidence_ledger_events
     WHERE action_id = ?
  `).get(action.actionID).event_sha256, eventSHA256);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
     WHERE report_id = ? AND event_type = 'review_started'
  `).get(reports[0]).count, 1);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_access_audit_starts
  `).get().count, 0);
});

test("an action cannot outlive the Access session that authorized it", () => {
  const value = database();
  const actor = registerOperator(value, "action-session-bound");
  const session = admitSession(value, actor, { lifetime: 60 });
  reserveCase(value, actor, caseReferences[0], session);
  assert.throws(() => createSecureAction(value, actor, {
    sessionSHA256: session,
    expiresIn: 61,
  }), /exceeds access session lifetime/);
});

test("an admitted intent survives later alias and authorization revocation", () => {
  const value = database();
  const actor = registerOperator(value, "resume-after-auth-change");
  const session = admitSession(value, actor, { lifetime: 1 });
  reserveCase(value, actor, caseReferences[0], session);
  const action = createSecureAction(value, actor, {
    sessionSHA256: session,
    expiresIn: 1,
  });
  const intent = createIntent(value, action);
  rotateAlias(value, actor);
  revokeCredential(value, actor);
  advance(value, 2);
  revokeOperator(value, actor);
  assert.doesNotThrow(() => finalizeIntent(value, intent));
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
     WHERE report_id = ? AND event_type = 'review_started'
  `).get(reports[0]).count, 1);
});

test("pre-0016 completed evidence remains while unfinished work cannot advance", () => {
  const value = database({ through: 15 });
  const actor = registerOperator(value, "legacy");
  const completed = createLegacyReviewAction(value, actor, caseReferences[0]);
  const completedIntent = createIntent(value, completed);
  const completedHead = finalizeIntent(value, completedIntent);
  const unfinished = createLegacyReviewAction(value, actor, caseReferences[1]);
  const orphanChallenge = prepareLegacyChallenge(value, actor, {
    actionID: uuid(),
    caseReference: caseReferences[2],
    sessionSHA256: digest("legacy-orphan-session"),
  });

  value.exec(migrations[4]);
  assert.equal(value.prepare(`
    SELECT event_sha256 FROM moderation_evidence_ledger_events
     WHERE action_id = ?
  `).get(completed.actionID).event_sha256, completedHead);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
     WHERE report_id = ? AND event_type = 'review_started'
  `).get(reports[0]).count, 1);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_access_sessions
  `).get().count, 0);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_assertion_attempts
  `).get().count, 0);

  assert.throws(() => createIntent(value, unfinished),
    /admitted request attempt/);
  assert.throws(() => consumeLegacyChallenge(value, actor, orphanChallenge),
    /exact assertion attempt/);
  admitSession(value, actor, {
    label: "legacy-retrofit",
    sessionSHA256: orphanChallenge.sessionSHA256,
  });
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_challenge_access_links(
      challenge_id, access_session_sha256
    ) VALUES (?, ?)
  `).run(
    orphanChallenge.challengeID,
    orphanChallenge.sessionSHA256,
  ), /does not match a new challenge/);
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_assertion_attempts(
      challenge_id, operator_id, access_session_sha256,
      credential_id_sha256, assertion_sha256
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    orphanChallenge.challengeID,
    actor.operatorID,
    orphanChallenge.sessionSHA256,
    actor.credentialID,
    digest("legacy-late-attempt"),
  ), /live challenge/);
  assert.throws(() => value.prepare(`
    UPDATE moderation_evidence_ledger_events
       SET artifact_sha256 = ? WHERE action_id = ?
  `).run(digest("tamper"), completed.actionID), /append-only/);
});
