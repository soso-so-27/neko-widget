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
  "0017_moderation_operator_enrollment_trust.sql",
];
const migrations = await Promise.all(migrationNames.map((name) => readFile(
  join(projectDirectory, "migrations", name),
  "utf8",
)));
const caseReferenceBindingMigration = await readFile(join(
  projectDirectory,
  "migrations",
  "0018_moderation_operator_case_reference_binding.sql",
), "utf8");

const clocks = new WeakMap();
let identifierCounter = 1;
const reports = Array.from(
  { length: 5 },
  (_, index) => `enrollment-test-report-${index}`,
);
const caseReferences = reports.map((report) => digest(`${report}-case`));

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function uuid() {
  const suffix = String(identifierCounter).padStart(12, "0");
  identifierCounter += 1;
  return `00000000-0000-4000-8000-${suffix}`;
}

function database({ through = 17 } = {}) {
  identifierCounter = 1;
  const value = new DatabaseSync(":memory:");
  clocks.set(value, { now: 1_920_000_000 });
  value.function("unixepoch", () => clocks.get(value).now);
  value.exec(`
    PRAGMA foreign_keys = ON;
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
  const publicKey = Buffer.alloc(64, label.length % 251);
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
  `).run(credentialID, operatorID, publicKey);
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
    publicKey,
    registrationSignCount: 0,
    signCount: 0,
  };
}

function addCredential(value, actor, label) {
  const credentialID = digest(`${label}-credential`);
  const publicKey = Buffer.alloc(64, (label.length + 17) % 251);
  value.prepare(`
    INSERT INTO moderation_operator_credentials(
      credential_id_sha256, operator_id, public_key_cose,
      registration_sign_count
    ) VALUES (?, ?, ?, 0)
  `).run(credentialID, actor.operatorID, publicKey);
  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'registered')
  `).run(credentialID);
  return {
    ...actor,
    credentialID,
    publicKey,
    registrationSignCount: 0,
  };
}

function rotateAlias(value, actor, label) {
  const next = {
    ...actor,
    subjectHmacKeyVersion: actor.subjectHmacKeyVersion + 1,
    subjectHmac: digest(`${label}-subject`),
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

function requestEnrollment(value, actor, {
  kind = "enrollment",
  label = uuid(),
  expiresIn = 900,
  registrationSignCount = actor.registrationSignCount,
  credentialID = actor.credentialID,
  publicKeySnapshot = actor.publicKey,
  supersededAdmissionID = null,
  supersededCredentialID = null,
} = {}) {
  const requestID = uuid();
  value.prepare(`
    INSERT INTO moderation_operator_enrollment_requests(
      enrollment_request_id, enrollment_kind, request_schema_version,
      canonical_request_sha256, target_operator_id,
      target_access_subject_hmac_key_version, target_access_subject_hmac,
      target_credential_id_sha256, target_public_key_cose_sha256,
      target_public_key_cose_snapshot,
      target_registration_sign_count, attestation_evidence_sha256,
      attestation_policy_revision, authenticator_aaguid_sha256,
      superseded_enrollment_admission_id,
      superseded_credential_id_sha256, expires_at
    ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, unixepoch() + ?)
  `).run(
    requestID,
    kind,
    digest(`${label}-canonical-request`),
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    actor.subjectHmac,
    credentialID,
    digest(actor.publicKey),
    publicKeySnapshot,
    registrationSignCount,
    digest(`${label}-attestation-evidence`),
    digest(`${label}-aaguid`),
    supersededAdmissionID,
    supersededCredentialID,
    expiresIn,
  );
  return requestID;
}

function allowAuthority(value, keyID, label = keyID, policyRevision = 1) {
  const fingerprint = digest(`${label}-authority-public-key`);
  value.prepare(`
    INSERT INTO moderation_operator_enrollment_offline_authorities(
      offline_authority_key_id, authority_policy_revision,
      authority_public_key_fingerprint_sha256
    ) VALUES (?, ?, ?)
  `).run(keyID, policyRevision, fingerprint);
  return { keyID, policyRevision, fingerprint };
}

function offlineApprove(value, requestID, authority, label = authority.keyID) {
  value.prepare(`
    INSERT INTO moderation_operator_enrollment_offline_approvals(
      enrollment_request_id, offline_authority_key_id,
      authority_policy_revision, authority_public_key_fingerprint_sha256,
      authority_signature_sha256
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    requestID,
    authority.keyID,
    authority.policyRevision,
    authority.fingerprint,
    digest(`${label}-offline-signature`),
  );
}

function admit(value, requestID, label = requestID) {
  const admissionID = uuid();
  value.prepare(`
    INSERT INTO moderation_operator_enrollment_admissions(
      enrollment_admission_id, enrollment_request_id,
      admission_provenance_sha256
    ) VALUES (?, ?, ?)
  `).run(admissionID, requestID, digest(`${label}-admission-provenance`));
  return admissionID;
}

function bootstrap(value, actor, label = "bootstrap") {
  const requestID = requestEnrollment(value, actor, {
    kind: "initial_bootstrap",
    label,
  });
  const authorityA = allowAuthority(value, "OFFLINE_A", `${label}-a`);
  const authorityB = allowAuthority(value, "OFFLINE_B", `${label}-b`);
  offlineApprove(value, requestID, authorityA, `${label}-a`);
  offlineApprove(value, requestID, authorityB, `${label}-b`);
  const admissionID = admit(value, requestID, label);
  return { requestID, admissionID };
}

function admitSession(value, actor, label = uuid(), lifetime = 900) {
  const sessionSHA256 = digest(`${label}-access-session`);
  value.prepare(`
    INSERT INTO moderation_operator_access_sessions(
      access_session_sha256, operator_id,
      access_subject_hmac_key_version, access_subject_hmac,
      token_issued_at, token_expires_at
    ) VALUES (?, ?, ?, ?, unixepoch(), unixepoch() + ?)
  `).run(
    sessionSHA256,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    actor.subjectHmac,
    lifetime,
  );
  return sessionSHA256;
}

function adminApprove(value, requestID, approver, {
  admissionID,
  sessionSHA256,
  label = requestID,
} = {}) {
  value.prepare(`
    INSERT INTO moderation_operator_enrollment_admin_approvals(
      enrollment_request_id, approver_operator_id, approver_admission_id,
      approver_access_session_sha256, approver_credential_id_sha256,
      approval_signature_sha256
    ) VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    requestID,
    approver.operatorID,
    admissionID,
    sessionSHA256,
    approver.credentialID,
    digest(`${label}-admin-signature`),
  );
}

function issueChallenge(value, actor, sessionSHA256, label = uuid()) {
  const challengeID = uuid();
  const actionID = uuid();
  value.prepare(`
    INSERT INTO moderation_operator_challenges(
      challenge_id, operator_id, access_subject_hmac_key_version,
      credential_id_sha256, access_session_sha256,
      challenge_value_sha256, purpose, action_type, action_id,
      case_reference_hmac, method, pathname, body_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, 'request', 'review_start', ?, ?,
              'POST', ?, ?, unixepoch() + 300)
  `).run(
    challengeID,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    actor.credentialID,
    sessionSHA256,
    digest(`${label}-challenge`),
    actionID,
    caseReferences[0],
    `/operator/v1/evidence/${actionID}`,
    digest(`${label}-body`),
  );
  return challengeID;
}

function recordAttempt(value, actor, sessionSHA256, challengeID, label = uuid()) {
  const assertionSHA256 = digest(`${label}-assertion`);
  value.prepare(`
    INSERT INTO moderation_operator_assertion_attempts(
      challenge_id, operator_id, access_session_sha256,
      credential_id_sha256, assertion_sha256
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    challengeID,
    actor.operatorID,
    sessionSHA256,
    actor.credentialID,
    assertionSHA256,
  );
  return assertionSHA256;
}

function consumeAttempt(value, actor, challengeID, assertionSHA256) {
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
    assertionSHA256,
    actor.signCount,
  );
}

function prepareBoundChallenge(value, actor, sessionSHA256, {
  actionID = uuid(),
  actionType = "review_start",
  purpose = "request",
  label = uuid(),
  caseReference = caseReferences[0],
} = {}) {
  const challengeID = uuid();
  const bodySHA256 = digest(`${label}-body`);
  const pathname = `/operator/v1/evidence/${actionID}`;
  value.prepare(`
    INSERT INTO moderation_operator_challenges(
      challenge_id, operator_id, access_subject_hmac_key_version,
      credential_id_sha256, access_session_sha256,
      challenge_value_sha256, purpose, action_type, action_id,
      case_reference_hmac, method, pathname, body_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'POST', ?, ?, unixepoch()+300)
  `).run(
    challengeID,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    actor.credentialID,
    sessionSHA256,
    digest(`${label}-challenge`),
    purpose,
    actionType,
    actionID,
    caseReference,
    pathname,
    bodySHA256,
  );
  return {
    actionID,
    actionType,
    bodySHA256,
    challengeID,
    pathname,
    sessionSHA256,
    caseReference,
  };
}

function insertBoundAction(value, actor, challenge) {
  const needsApproval = challenge.actionType !== "review_start";
  value.prepare(`
    INSERT INTO moderation_operator_actions(
      action_id, case_reference_hmac, action_type,
      requester_operator_id, request_challenge_id, request_sha256,
      request_method, request_pathname, required_approvals,
      required_approver_role, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, 'POST', ?, ?, ?, unixepoch()+900)
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
  );
  return { ...challenge, actor };
}

function insertActionApproval(value, action, approver, challenge) {
  value.prepare(`
    INSERT INTO moderation_operator_action_approvals(
      action_id, operator_id, approval_challenge_id, approval_sha256,
      approval_method, approval_pathname
    ) VALUES (?, ?, ?, ?, 'POST', ?)
  `).run(
    action.actionID,
    approver.operatorID,
    challenge.challengeID,
    challenge.bodySHA256,
    challenge.pathname,
  );
}

function createEvidenceIntent(value, action) {
  const eventID = uuid();
  return value.prepare(`
    INSERT INTO moderation_evidence_event_intents(
      event_id, case_reference_hmac, sequence, action_id, action_type,
      actor_subject_hmac_key_version, actor_subject_hmac,
      previous_event_sha256, artifact_sha256, case_outcome_code,
      legacy_backfill
    ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, NULL, 0)
    RETURNING *
  `).get(
    eventID,
    action.caseReference,
    action.actionID,
    action.actionType,
    action.actor.subjectHmacKeyVersion,
    action.actor.subjectHmac,
    "0".repeat(64),
    digest(`${eventID}-artifact`),
  );
}

function insertLedgerEvent(value, intent) {
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
    digest(`${intent.event_id}-event`),
  );
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

function reserveCase(
  value,
  actor,
  sessionSHA256,
  label = uuid(),
  caseReference = caseReferences[0],
) {
  value.prepare(`
    INSERT INTO moderation_case_reservations(
      reservation_id, case_reference_hmac, operator_id,
      access_subject_hmac_key_version, access_session_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, unixepoch() + 300)
  `).run(
    uuid(),
    caseReference,
    actor.operatorID,
    actor.subjectHmacKeyVersion,
    sessionSHA256,
  );
}

test("0017 is additive, empty, and does not trust pre-0017 rows", () => {
  const value = database({ through: 16 });
  const legacy = registerOperator(
    value,
    "legacy",
    ["security_admin", "triage"],
  );
  const legacySession = admitSession(value, legacy, "legacy-before-0017");
  const legacyChallenge = issueChallenge(
    value,
    legacy,
    legacySession,
    "legacy-before-0017",
  );
  const attemptedChallenge = prepareBoundChallenge(
    value,
    legacy,
    legacySession,
    { label: "legacy-attempted" },
  );
  const attemptedAssertion = recordAttempt(
    value,
    legacy,
    legacySession,
    attemptedChallenge.challengeID,
    "legacy-attempted",
  );
  const consumedActor = registerOperator(value, "legacy-consumed-actor");
  const consumedSession = admitSession(
    value,
    consumedActor,
    "legacy-consumed-session",
  );
  const consumedChallenge = prepareBoundChallenge(
    value,
    consumedActor,
    consumedSession,
    { label: "legacy-consumed", caseReference: caseReferences[3] },
  );
  const consumedAssertion = recordAttempt(
    value,
    consumedActor,
    consumedSession,
    consumedChallenge.challengeID,
    "legacy-consumed",
  );
  consumeAttempt(
    value,
    consumedActor,
    consumedChallenge.challengeID,
    consumedAssertion,
  );

  const actionActor = registerOperator(value, "legacy-action-actor");
  const actionSession = admitSession(value, actionActor, "legacy-action-session");
  reserveCase(
    value,
    actionActor,
    actionSession,
    "legacy-action-reservation",
    caseReferences[1],
  );
  const actionChallenge = prepareBoundChallenge(
    value,
    actionActor,
    actionSession,
    { label: "legacy-action", caseReference: caseReferences[1] },
  );
  const actionAssertion = recordAttempt(
    value,
    actionActor,
    actionSession,
    actionChallenge.challengeID,
    "legacy-action",
  );
  consumeAttempt(
    value,
    actionActor,
    actionChallenge.challengeID,
    actionAssertion,
  );
  const oldAction = insertBoundAction(value, actionActor, actionChallenge);

  const intentActor = registerOperator(value, "legacy-intent-actor");
  const intentSession = admitSession(value, intentActor, "legacy-intent-session");
  reserveCase(
    value,
    intentActor,
    intentSession,
    "legacy-intent-reservation",
    caseReferences[2],
  );
  const intentChallenge = prepareBoundChallenge(
    value,
    intentActor,
    intentSession,
    { label: "legacy-intent", caseReference: caseReferences[2] },
  );
  const intentAssertion = recordAttempt(
    value,
    intentActor,
    intentSession,
    intentChallenge.challengeID,
    "legacy-intent",
  );
  consumeAttempt(
    value,
    intentActor,
    intentChallenge.challengeID,
    intentAssertion,
  );
  const intentAction = insertBoundAction(value, intentActor, intentChallenge);
  const oldIntent = createEvidenceIntent(value, intentAction);

  const exportRequester = registerOperator(
    value,
    "legacy-export-requester",
    ["evidence_reviewer"],
  );
  const exportApprover = registerOperator(
    value,
    "legacy-export-approver",
    ["privacy_approver"],
  );
  const exportRequesterSession = admitSession(
    value,
    exportRequester,
    "legacy-export-requester-session",
  );
  const exportApproverSession = admitSession(
    value,
    exportApprover,
    "legacy-export-approver-session",
  );
  const exportChallenge = prepareBoundChallenge(
    value,
    exportRequester,
    exportRequesterSession,
    {
      label: "legacy-export",
      actionType: "evidence_export",
      caseReference: caseReferences[4],
    },
  );
  const exportAssertion = recordAttempt(
    value,
    exportRequester,
    exportRequesterSession,
    exportChallenge.challengeID,
    "legacy-export",
  );
  consumeAttempt(
    value,
    exportRequester,
    exportChallenge.challengeID,
    exportAssertion,
  );
  const oldExportAction = insertBoundAction(
    value,
    exportRequester,
    exportChallenge,
  );
  const exportApprovalChallenge = prepareBoundChallenge(
    value,
    exportApprover,
    exportApproverSession,
    {
      actionID: oldExportAction.actionID,
      actionType: "evidence_export",
      purpose: "approve",
      label: "legacy-export-approval",
      caseReference: caseReferences[4],
    },
  );
  const exportApprovalAssertion = recordAttempt(
    value,
    exportApprover,
    exportApproverSession,
    exportApprovalChallenge.challengeID,
    "legacy-export-approval",
  );
  consumeAttempt(
    value,
    exportApprover,
    exportApprovalChallenge.challengeID,
    exportApprovalAssertion,
  );
  insertActionApproval(
    value,
    oldExportAction,
    exportApprover,
    exportApprovalChallenge,
  );
  const exportIntent = createEvidenceIntent(value, oldExportAction);
  insertLedgerEvent(value, exportIntent);

  const pendingApprovalChallenge = prepareBoundChallenge(
    value,
    exportApprover,
    exportApproverSession,
    {
      actionID: oldExportAction.actionID,
      actionType: "evidence_export",
      purpose: "approve",
      label: "legacy-pending-approval",
      caseReference: caseReferences[4],
    },
  );
  const pendingApprovalAssertion = recordAttempt(
    value,
    exportApprover,
    exportApproverSession,
    pendingApprovalChallenge.challengeID,
    "legacy-pending-approval",
  );
  consumeAttempt(
    value,
    exportApprover,
    pendingApprovalChallenge.challengeID,
    pendingApprovalAssertion,
  );

  reserveCase(
    value,
    consumedActor,
    consumedSession,
    "legacy-pending-action-reservation",
    caseReferences[3],
  );
  value.exec(migrations[5]);

  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count
      FROM moderation_operator_enrollment_admissions
  `).get().count, 0);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_access_sessions
     WHERE access_session_sha256 = ?
  `).get(legacySession).count, 1);
  assert.throws(
    () => admitSession(value, legacy, "legacy-after-0017"),
    /requires admitted enrollment/,
  );
  assert.throws(
    () => issueChallenge(value, legacy, legacySession, "legacy-challenge"),
    /requires exact enrollment admission/,
  );
  const legacyTrust = bootstrap(value, legacy, "legacy-explicit-bootstrap");
  assert.throws(
    () => issueChallenge(value, legacy, legacySession, "legacy-post-admission"),
    /requires exact enrollment admission/,
  );
  assert.throws(
    () => reserveCase(value, legacy, legacySession, "legacy-reservation"),
    /requires enrolled access session/,
  );
  assert.throws(
    () => recordAttempt(
      value,
      legacy,
      legacySession,
      legacyChallenge,
      "legacy-post-admission",
    ),
    /requires enrolled challenge/,
  );
  assert.throws(
    () => consumeAttempt(
      value,
      consumedActor,
      attemptedChallenge.challengeID,
      attemptedAssertion,
    ),
    /requires enrolled attempt/,
  );
  assert.throws(
    () => insertBoundAction(value, consumedActor, consumedChallenge),
    /requires enrolled assertion chain/,
  );
  assert.throws(
    () => createEvidenceIntent(value, oldAction),
    /requires enrolled assertion chain/,
  );
  assert.throws(
    () => insertLedgerEvent(value, oldIntent),
    /requires enrolled assertion chain/,
  );
  assert.throws(
    () => createExport(value, oldExportAction),
    /requires enrolled assertion chain/,
  );
  assert.throws(
    () => insertActionApproval(
      value,
      oldExportAction,
      exportApprover,
      pendingApprovalChallenge,
    ),
    /requires enrolled assertion chain/,
  );
  const target = registerOperator(value, "legacy-session-target");
  const targetRequest = requestEnrollment(value, target, {
    label: "legacy-session-target",
  });
  assert.throws(
    () => adminApprove(value, targetRequest, legacy, {
      admissionID: legacyTrust.admissionID,
      sessionSHA256: legacySession,
      label: "legacy-session-approval",
    }),
    /not currently trusted/,
  );
  const currentSession = admitSession(value, legacy, "legacy-current-session");
  assert.doesNotThrow(
    () => reserveCase(value, legacy, currentSession, "legacy-current"),
  );
  assert.doesNotThrow(
    () => issueChallenge(value, legacy, currentSession, "legacy-current"),
  );
});

test("initial bootstrap requires two distinct offline authorities", () => {
  const value = database();
  const admin = registerOperator(value, "bootstrap-admin", ["security_admin"]);
  const requestID = requestEnrollment(value, admin, {
    kind: "initial_bootstrap",
    label: "bootstrap-two-of-n",
  });
  const authorityA = allowAuthority(value, "OFFLINE_A", "bootstrap-a");
  const authorityB = allowAuthority(value, "OFFLINE_B", "bootstrap-b");
  const retiredC = allowAuthority(value, "OFFLINE_C", "bootstrap-c-old");
  const authorityC = allowAuthority(value, "OFFLINE_C", "bootstrap-c", 2);
  const authorityD = allowAuthority(value, "OFFLINE_D", "bootstrap-d-old");
  assert.throws(
    () => offlineApprove(value, requestID, {
      keyID: "UNLISTED_1",
      policyRevision: 1,
      fingerprint: digest("unlisted"),
    }, "unlisted"),
    /reviewed live authority|FOREIGN KEY constraint failed/,
  );
  assert.throws(
    () => offlineApprove(value, requestID, retiredC, "retired-authority"),
    /reviewed live authority/,
  );
  offlineApprove(value, requestID, authorityA, "bootstrap-a");
  offlineApprove(value, requestID, authorityD, "bootstrap-d-old");
  allowAuthority(value, "OFFLINE_D", "bootstrap-d-new", 2);
  assert.throws(
    () => admit(value, requestID, "authority-rotated-after-approval"),
    /requires two offline authorities/,
  );
  assert.throws(
    () => offlineApprove(value, requestID, authorityA, "duplicate-key"),
    /replayed or replaced/,
  );
  assert.throws(
    () => offlineApprove(value, requestID, authorityB, "bootstrap-a"),
    /replayed or replaced/,
  );
  offlineApprove(value, requestID, authorityB, "bootstrap-b");
  const admissionID = admit(value, requestID, "two-approvals");
  const session = admitSession(value, admin, "trusted-admin");
  assert.doesNotThrow(() => issueChallenge(value, admin, session, "trusted"));
  assert.equal(typeof admissionID, "string");
  assert.throws(
    () => offlineApprove(value, requestID, authorityC, "too-late"),
    /already admitted/,
  );
});

test("normal enrollment requires non-self security-admin provenance", () => {
  const value = database();
  const admin = registerOperator(value, "admin", ["security_admin"]);
  const { admissionID } = bootstrap(value, admin, "admin-bootstrap");
  const adminSession = admitSession(value, admin, "admin-session");
  const target = registerOperator(value, "target");
  const requestID = requestEnrollment(value, target, { label: "target" });
  const parallelRequestID = requestEnrollment(value, target, {
    label: "target-parallel",
  });

  assert.throws(
    () => adminApprove(value, requestID, target, {
      admissionID,
      sessionSHA256: adminSession,
      label: "self",
    }),
    /non-self request/,
  );
  adminApprove(value, requestID, admin, {
    admissionID,
    sessionSHA256: adminSession,
    label: "admin-approves-target",
  });
  adminApprove(value, parallelRequestID, admin, {
    admissionID,
    sessionSHA256: adminSession,
    label: "admin-approves-parallel-target",
  });
  assert.throws(
    () => adminApprove(value, requestID, admin, {
      admissionID,
      sessionSHA256: adminSession,
      label: "duplicate-admin",
    }),
    /replayed or replaced/,
  );
  admit(value, requestID, "target-admission");
  assert.throws(
    () => admit(value, parallelRequestID, "parallel-target-admission"),
    /recovery is required/,
  );
  assert.doesNotThrow(() => admitSession(value, target, "target-session"));
});

test("approval cannot survive security-admin revocation before admission", () => {
  const value = database();
  const admin = registerOperator(value, "revoked-admin", ["security_admin"]);
  const trust = bootstrap(value, admin, "revoked-admin-bootstrap");
  const adminSession = admitSession(value, admin, "revoked-admin-session");
  const target = registerOperator(value, "revoked-admin-target");
  const requestID = requestEnrollment(value, target, {
    label: "revoked-admin-target",
  });
  adminApprove(value, requestID, admin, {
    admissionID: trust.admissionID,
    sessionSHA256: adminSession,
    label: "approval-before-revocation",
  });
  value.prepare(`
    INSERT INTO moderation_operator_role_events(
      operator_id, role_code, event_type
    ) VALUES (?, 'security_admin', 'revoked')
  `).run(admin.operatorID);
  assert.throws(
    () => admit(value, requestID, "after-admin-revocation"),
    /current distinct security admins/,
  );

  const expiryValue = database();
  const expiryAdmin = registerOperator(
    expiryValue,
    "expired-approver",
    ["security_admin"],
  );
  const expiryTrust = bootstrap(
    expiryValue,
    expiryAdmin,
    "expired-approver-bootstrap",
  );
  const expirySession = admitSession(
    expiryValue,
    expiryAdmin,
    "expired-approver-session",
    1,
  );
  const expiryTarget = registerOperator(expiryValue, "expired-target");
  const expiryRequest = requestEnrollment(expiryValue, expiryTarget, {
    label: "expired-target",
  });
  adminApprove(expiryValue, expiryRequest, expiryAdmin, {
    admissionID: expiryTrust.admissionID,
    sessionSHA256: expirySession,
    label: "approval-before-expiry",
  });
  advance(expiryValue, 1);
  assert.throws(
    () => admit(expiryValue, expiryRequest, "after-session-expiry"),
    /current distinct security admins/,
  );

  const bootstrapValue = database();
  const bootstrapAdmin = registerOperator(
    bootstrapValue,
    "revoked-bootstrap",
    ["security_admin"],
  );
  const bootstrapRequest = requestEnrollment(bootstrapValue, bootstrapAdmin, {
    kind: "initial_bootstrap",
    label: "revoked-bootstrap",
  });
  const authorityA = allowAuthority(
    bootstrapValue,
    "OFFLINE_A",
    "revoked-bootstrap-a",
  );
  const authorityB = allowAuthority(
    bootstrapValue,
    "OFFLINE_B",
    "revoked-bootstrap-b",
  );
  offlineApprove(
    bootstrapValue,
    bootstrapRequest,
    authorityA,
    "revoked-bootstrap-a",
  );
  offlineApprove(
    bootstrapValue,
    bootstrapRequest,
    authorityB,
    "revoked-bootstrap-b",
  );
  bootstrapValue.prepare(`
    INSERT INTO moderation_operator_role_events(
      operator_id, role_code, event_type
    ) VALUES (?, 'security_admin', 'revoked')
  `).run(bootstrapAdmin.operatorID);
  assert.throws(
    () => admit(bootstrapValue, bootstrapRequest, "revoked-bootstrap"),
    /security admin is not current/,
  );
});

test("wrong target, expiration and request replay fail closed", () => {
  const value = database();
  const admin = registerOperator(value, "expiry-admin", ["security_admin"]);
  const boot = bootstrap(value, admin, "expiry-bootstrap");
  const adminSession = admitSession(value, admin, "expiry-admin-session");
  const target = registerOperator(value, "wrong-target");
  assert.throws(
    () => requestEnrollment(value, target, {
      label: "wrong-counter",
      registrationSignCount: 7,
    }),
    /target tuple does not exist/,
  );
  assert.throws(
    () => requestEnrollment(value, target, {
      label: "wrong-public-key",
      publicKeySnapshot: Buffer.alloc(64, 255),
    }),
    /target tuple does not exist/,
  );
  assert.throws(() => value.prepare(`
    INSERT INTO moderation_operator_enrollment_requests(
      enrollment_request_id, enrollment_kind, request_schema_version,
      canonical_request_sha256, target_operator_id,
      target_access_subject_hmac_key_version, target_access_subject_hmac,
      target_credential_id_sha256, target_public_key_cose_sha256,
      target_public_key_cose_snapshot,
      target_registration_sign_count, attestation_evidence_sha256,
      attestation_policy_revision, authenticator_aaguid_sha256, expires_at
    ) VALUES (?, 'enrollment', 1, ?, ?, ?, ?, ?, ?, ?, 0, ?, 1, ?, unixepoch()+60)
  `).run(
    uuid(), digest("wrong-operator-credential-request"), target.operatorID,
    target.subjectHmacKeyVersion, target.subjectHmac, admin.credentialID,
    digest(admin.publicKey), admin.publicKey,
    digest("attestation"), digest("aaguid"),
  ), /target tuple does not exist/);

  const requestID = requestEnrollment(value, target, {
    label: "expires",
    expiresIn: 1,
  });
  advance(value, 1);
  assert.throws(
    () => adminApprove(value, requestID, admin, {
      admissionID: boot.admissionID,
      sessionSHA256: adminSession,
      label: "expired",
    }),
    /live non-self request/,
  );
  assert.throws(
    () => admit(value, requestID, "expired"),
    /target is not current/,
  );
  assert.throws(() => value.prepare(`
    INSERT OR REPLACE INTO moderation_operator_enrollment_requests
    SELECT * FROM moderation_operator_enrollment_requests
     WHERE enrollment_request_id = ?
  `).run(requestID), /database time|replayed or replaced/);
});

test("a direct credential, alias rotation, and revocation cannot bypass admission", () => {
  const value = database();
  const admin = registerOperator(value, "recovery-admin", ["security_admin"]);
  const adminTrust = bootstrap(value, admin, "recovery-admin-bootstrap");
  const adminSession = admitSession(value, admin, "recovery-admin-session");
  const secondAdmin = registerOperator(
    value,
    "recovery-admin-two",
    ["security_admin"],
  );
  const secondAdminRequest = requestEnrollment(value, secondAdmin, {
    label: "recovery-admin-two",
  });
  adminApprove(value, secondAdminRequest, admin, {
    admissionID: adminTrust.admissionID,
    sessionSHA256: adminSession,
    label: "recovery-admin-two-approval",
  });
  const secondAdminAdmission = admit(
    value,
    secondAdminRequest,
    "recovery-admin-two",
  );
  const secondAdminSession = admitSession(
    value,
    secondAdmin,
    "recovery-admin-two-session",
  );
  let target = registerOperator(value, "recovery-target");
  let requestID = requestEnrollment(value, target, { label: "first-target" });
  adminApprove(value, requestID, admin, {
    admissionID: adminTrust.admissionID,
    sessionSHA256: adminSession,
    label: "first-target-approval",
  });
  const firstAdmission = admit(value, requestID, "first-target");
  const targetSession = admitSession(value, target, "first-target-session");
  const originalTarget = target;

  const replacementCredential = addCredential(value, target, "replacement");
  assert.throws(
    () => issueChallenge(
      value,
      replacementCredential,
      targetSession,
      "unadmitted-credential",
    ),
    /requires exact enrollment admission/,
  );
  assert.throws(
    () => requestEnrollment(value, originalTarget, {
      kind: "recovery",
      label: "same-credential-recovery",
      supersededAdmissionID: firstAdmission,
      supersededCredentialID: originalTarget.credentialID,
    }),
    /CHECK constraint failed/,
  );
  assert.throws(
    () => requestEnrollment(value, replacementCredential, {
      kind: "recovery",
      label: "wrong-operator-superseded",
      supersededAdmissionID: adminTrust.admissionID,
      supersededCredentialID: admin.credentialID,
    }),
    /current superseded credential/,
  );
  requestID = requestEnrollment(value, replacementCredential, {
    kind: "recovery",
    label: "credential-recovery",
    supersededAdmissionID: firstAdmission,
    supersededCredentialID: originalTarget.credentialID,
  });
  assert.throws(
    () => adminApprove(value, requestID, target, {
      admissionID: firstAdmission,
      sessionSHA256: targetSession,
      label: "self-recovery",
    }),
    /non-self request/,
  );
  adminApprove(value, requestID, admin, {
    admissionID: adminTrust.admissionID,
    sessionSHA256: adminSession,
    label: "credential-recovery-admin",
  });
  assert.throws(
    () => admit(value, requestID, "credential-recovery-one-admin"),
    /current distinct security admins/,
  );
  adminApprove(value, requestID, secondAdmin, {
    admissionID: secondAdminAdmission,
    sessionSHA256: secondAdminSession,
    label: "credential-recovery-second-admin",
  });
  admit(value, requestID, "credential-recovery");
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count
      FROM moderation_operator_credential_events
     WHERE credential_id_sha256 = ? AND event_type = 'revoked'
  `).get(originalTarget.credentialID).count, 1);
  assert.throws(
    () => issueChallenge(
      value,
      originalTarget,
      targetSession,
      "superseded-credential",
    ),
    /not active|live access session|exact enrollment admission/,
  );
  const recoveredSession = admitSession(
    value,
    replacementCredential,
    "recovered-session",
  );
  assert.doesNotThrow(() => issueChallenge(
    value,
    replacementCredential,
    recoveredSession,
    "admitted-credential",
  ));

  const anotherCredential = addCredential(
    value,
    replacementCredential,
    "another-replacement",
  );
  assert.throws(
    () => requestEnrollment(value, anotherCredential, {
      kind: "recovery",
      label: "already-revoked-superseded",
      supersededAdmissionID: firstAdmission,
      supersededCredentialID: originalTarget.credentialID,
    }),
    /current superseded credential/,
  );

  target = rotateAlias(value, replacementCredential, "rotated");
  assert.throws(
    () => admitSession(value, target, "rotated-without-recovery"),
    /requires admitted enrollment/,
  );
  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'revoked')
  `).run(target.credentialID);
  assert.throws(
    () => admitSession(value, target, "revoked-credential"),
    /requires admitted enrollment/,
  );
});

test("emergency revocation remains recoverable without duplicate revocation", () => {
  const value = database();
  const admin = registerOperator(value, "emergency-admin", ["security_admin"]);
  const adminTrust = bootstrap(value, admin, "emergency-admin-bootstrap");
  const adminSession = admitSession(value, admin, "emergency-admin-session");
  const secondAdmin = registerOperator(
    value,
    "emergency-admin-two",
    ["security_admin"],
  );
  const secondAdminRequest = requestEnrollment(value, secondAdmin, {
    label: "emergency-admin-two",
  });
  adminApprove(value, secondAdminRequest, admin, {
    admissionID: adminTrust.admissionID,
    sessionSHA256: adminSession,
    label: "emergency-admin-two-approval",
  });
  const secondAdminAdmission = admit(
    value,
    secondAdminRequest,
    "emergency-admin-two",
  );
  const secondAdminSession = admitSession(
    value,
    secondAdmin,
    "emergency-admin-two-session",
  );

  const target = registerOperator(value, "emergency-target");
  const firstRequest = requestEnrollment(value, target, {
    label: "emergency-target",
  });
  adminApprove(value, firstRequest, admin, {
    admissionID: adminTrust.admissionID,
    sessionSHA256: adminSession,
    label: "emergency-target-approval",
  });
  const firstAdmission = admit(value, firstRequest, "emergency-target");
  const targetSession = admitSession(value, target, "emergency-target-session");
  const replacement = addCredential(value, target, "emergency-replacement");

  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'revoked')
  `).run(target.credentialID);
  assert.throws(
    () => issueChallenge(
      value,
      target,
      targetSession,
      "emergency-revoked-credential",
    ),
    /not active|live access session|exact enrollment admission/,
  );

  const recoveryRequest = requestEnrollment(value, replacement, {
    kind: "recovery",
    label: "emergency-recovery",
    supersededAdmissionID: firstAdmission,
    supersededCredentialID: target.credentialID,
  });
  adminApprove(value, recoveryRequest, admin, {
    admissionID: adminTrust.admissionID,
    sessionSHA256: adminSession,
    label: "emergency-recovery-admin",
  });
  adminApprove(value, recoveryRequest, secondAdmin, {
    admissionID: secondAdminAdmission,
    sessionSHA256: secondAdminSession,
    label: "emergency-recovery-admin-two",
  });
  admit(value, recoveryRequest, "emergency-recovery");

  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count
      FROM moderation_operator_credential_events
     WHERE credential_id_sha256 = ? AND event_type = 'revoked'
  `).get(target.credentialID).count, 1);
  assert.throws(
    () => issueChallenge(
      value,
      target,
      targetSession,
      "emergency-old-key-after-recovery",
    ),
    /not active|live access session|exact enrollment admission/,
  );
  const replacementSession = admitSession(
    value,
    replacement,
    "emergency-replacement-session",
  );
  assert.doesNotThrow(() => issueChallenge(
    value,
    replacement,
    replacementSession,
    "emergency-new-key-after-recovery",
  ));
});

test("enrollment records are append-only and omit raw identity material", () => {
  const value = database();
  const admin = registerOperator(value, "immutable", ["security_admin"]);
  const trust = bootstrap(value, admin, "immutable-bootstrap");
  const adminSession = admitSession(value, admin, "immutable-admin-session");
  const target = registerOperator(value, "immutable-target");
  const targetRequest = requestEnrollment(value, target, {
    label: "immutable-target",
  });
  adminApprove(value, targetRequest, admin, {
    admissionID: trust.admissionID,
    sessionSHA256: adminSession,
    label: "immutable-admin-approval",
  });
  const tables = [
    "moderation_operator_enrollment_requests",
    "moderation_operator_enrollment_offline_authorities",
    "moderation_operator_enrollment_offline_approvals",
    "moderation_operator_enrollment_admin_approvals",
    "moderation_operator_enrollment_admissions",
  ];
  for (const table of tables) {
    const columns = value.prepare(`PRAGMA table_info(${table})`).all()
      .map((column) => column.name);
    for (const forbidden of [
      "access_jwt", "email", "name", "user_handle", "credential_id",
      "attestation_object", "attestation_certificate", "certificate",
    ]) {
      assert.equal(columns.includes(forbidden), false, `${table}.${forbidden}`);
    }
    assert.throws(
      () => value.exec(`UPDATE ${table} SET rowid = rowid`),
      /append-only/,
    );
    assert.throws(
      () => value.exec(`DELETE FROM ${table}`),
      /cannot be deleted/,
    );
  }
  assert.equal(typeof trust.admissionID, "string");
});

test("0018 blocks legacy chain resumption and permits only versioned completion", () => {
  const value = database();
  const actor = registerOperator(
    value,
    "case-reference-actor",
    ["security_admin", "triage"],
  );
  bootstrap(value, actor, "case-reference-bootstrap");
  const session = admitSession(value, actor, "case-reference-session");

  reserveCase(
    value,
    actor,
    session,
    "case-reference-legacy-reservation",
    caseReferences[0],
  );
  const legacyChallenge = prepareBoundChallenge(value, actor, session, {
    label: "case-reference-legacy",
    caseReference: caseReferences[0],
  });
  const legacyAssertion = recordAttempt(
    value,
    actor,
    session,
    legacyChallenge.challengeID,
    "case-reference-legacy",
  );
  consumeAttempt(value, actor, legacyChallenge.challengeID, legacyAssertion);
  const legacyAction = insertBoundAction(value, actor, legacyChallenge);
  const legacyIntent = createEvidenceIntent(value, legacyAction);

  value.exec(caseReferenceBindingMigration);

  assert.throws(
    () => insertLedgerEvent(value, legacyIntent),
    /evidence event requires a versioned case reference/,
  );

  // Isolate the three 0018 gates under test. Without this, the missing legacy
  // ledger/finalization rows also make the older 0012/0015 BEFORE triggers
  // reject, and SQLite does not guarantee the order of same-time triggers.
  value.exec(`
    SAVEPOINT isolate_0018_gates;
    DROP TRIGGER moderation_evidence_event_finalizations_validate;
    DROP TRIGGER moderation_case_events_validate_transition;
    DROP TRIGGER moderation_case_events_require_operator_evidence;
    DROP TRIGGER moderation_operator_case_event_links_validate;
  `);
  for (const gate of [
    "moderation_evidence_event_finalizations_require_versioned_case_reference",
    "moderation_case_events_require_versioned_case_reference",
    "moderation_operator_case_event_links_require_versioned_case_reference",
  ]) {
    assert.equal(value.prepare(`
      SELECT COUNT(*) AS count FROM sqlite_schema
       WHERE type = 'trigger' AND name = ?
    `).get(gate).count, 1, `${gate} must remain installed`);
  }
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_evidence_event_finalizations(
        event_id, event_sha256
      ) VALUES (?, ?)
    `).run(legacyIntent.event_id, digest("legacy-finalization")),
    /evidence finalization requires a versioned case reference/,
  );
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_case_events(report_id, event_type, outcome_code)
      VALUES (?, 'review_started', NULL)
    `).run(reports[0]),
    /case event requires a versioned case reference/,
  );
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_case_event_links(
        event_id, action_id, report_id, event_type
      ) VALUES (?, ?, ?, 'review_started')
    `).run(
      legacyIntent.event_id,
      legacyAction.actionID,
      reports[0],
    ),
    /case event link requires a versioned case reference/,
  );
  value.exec(`
    ROLLBACK TO isolate_0018_gates;
    RELEASE isolate_0018_gates;
  `);
  for (const restored of [
    "moderation_evidence_event_finalizations_validate",
    "moderation_case_events_validate_transition",
    "moderation_case_events_require_operator_evidence",
    "moderation_operator_case_event_links_validate",
  ]) {
    assert.equal(value.prepare(`
      SELECT COUNT(*) AS count FROM sqlite_schema
       WHERE type = 'trigger' AND name = ?
    `).get(restored).count, 1, `${restored} must be restored`);
  }

  const auditRequestID = uuid();
  value.prepare(`
    INSERT INTO moderation_operator_access_audit_starts(
      audit_request_id, operator_id, access_session_sha256,
      operation_code, request_sha256, case_reference_hmac
    ) VALUES (?, ?, ?, 'case_read', ?, NULL)
  `).run(auditRequestID, actor.operatorID, session, digest("null-case-audit"));
  value.prepare(`
    INSERT INTO moderation_operator_access_audit_finishes(
      audit_request_id, operator_id, access_session_sha256,
      operation_code, request_sha256, case_reference_hmac,
      outcome_code, status_code
    ) VALUES (?, ?, ?, 'case_read', ?, NULL, 'rejected_invalid', 400)
  `).run(auditRequestID, actor.operatorID, session, digest("null-case-audit"));
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_access_audit_finishes
     WHERE audit_request_id = ?
  `).get(auditRequestID).count, 1);
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_access_audit_starts(
        audit_request_id, operator_id, access_session_sha256,
        operation_code, request_sha256, case_reference_hmac
      ) VALUES (?, ?, ?, 'case_read', ?, ?)
    `).run(
      uuid(),
      actor.operatorID,
      session,
      digest("legacy-case-audit"),
      caseReferences[0],
    ),
    /access audit requires a versioned case reference/,
  );

  advance(value, 301);
  const versionedSession = admitSession(
    value,
    actor,
    "case-reference-versioned-session",
  );
  const versionedReport = Buffer.alloc(16, 9).toString("base64url");
  const versionedReference = digest("case-reference-versioned");
  value.prepare(`
    INSERT INTO moment_report_tombstones(report_id, committed_at)
    VALUES (?, unixepoch() - 60)
  `).run(versionedReport);
  value.prepare(`
    INSERT INTO moderation_operator_versioned_case_references(
      report_id, case_reference_hmac, case_reference_hmac_key_version,
      derivation_protocol_version, derivation_domain
    ) VALUES (?, ?, 4, 1, 'NW.MODERATION-OPERATOR.CASE-REFERENCE')
  `).run(versionedReport, versionedReference);

  reserveCase(
    value,
    actor,
    versionedSession,
    "case-reference-versioned-reservation",
    versionedReference,
  );
  const versionedChallenge = prepareBoundChallenge(value, actor, versionedSession, {
    label: "case-reference-versioned",
    caseReference: versionedReference,
  });
  const versionedAssertion = recordAttempt(
    value,
    actor,
    versionedSession,
    versionedChallenge.challengeID,
    "case-reference-versioned",
  );
  consumeAttempt(
    value,
    actor,
    versionedChallenge.challengeID,
    versionedAssertion,
  );
  const versionedAction = insertBoundAction(value, actor, versionedChallenge);
  const versionedIntent = createEvidenceIntent(value, versionedAction);
  assert.doesNotThrow(() => insertLedgerEvent(value, versionedIntent));
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_evidence_event_finalizations
     WHERE event_id = ?
  `).get(versionedIntent.event_id).count, 1);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_case_events
     WHERE report_id = ? AND event_type = 'review_started'
  `).get(versionedReport).count, 1);
  assert.equal(value.prepare(`
    SELECT COUNT(*) AS count FROM moderation_operator_case_event_links
     WHERE event_id = ?
  `).get(versionedIntent.event_id).count, 1);
});
