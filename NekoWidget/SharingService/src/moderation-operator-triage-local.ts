import { base64urlEncode } from "./encoding";
import {
  authenticateCloudflareAccessRequest,
  type AuthenticatedModerationOperatorAccess,
  type CloudflareAccessAuthenticationOptions,
} from "./moderation-operator-auth";
import { canonicalModerationEvidenceBytes, MODERATION_EVIDENCE_EVENT_SCHEMA } from "./moderation-evidence-export";
import { prepareModerationOperatorWebAuthnRequest } from "./moderation-operator-request";
import { verifyPreparedModerationOperatorWebAuthnAssertion } from "./moderation-operator-webauthn";
import { localModerationConsole } from "./moderation-operator-console";

/** Local integration candidate only. No Worker imports or exposes this handler. */
export interface LocalModerationTriageEnvironment {
  runtimeEnabled: string;
  environment: string;
  db: D1Database;
  origin: string;
  rpId: string;
  access: CloudflareAccessAuthenticationOptions;
}

interface Actor {
  operator_id: string;
  credential_id_sha256: string;
  public_key_cose: number[] | ArrayBuffer;
  sign_count: number;
  enrollment_admission_id: string;
}
interface Challenge {
  challenge_id: string;
  action_id: string;
  case_reference_hmac: string;
  challenge_value_sha256: string;
  method: string;
  pathname: string;
  body_sha256: string;
}
interface Intent {
  event_id: string;
  action_id: string;
  sequence: number;
  occurred_at: number;
  previous_event_sha256: string;
  artifact_sha256: string;
}
type Operation = "case_read" | "challenge_issue" | "assertion_verify" | "review_start";
type Outcome = "succeeded" | "rejected_invalid" | "rejected_forbidden" | "rejected_conflict" | "rejected_quota" | "failed_dependency";
interface Audit { id: string; operation: Operation; requestDigest: string; caseReference: string | null }

class TriageError extends Error {
  constructor(readonly status: number, readonly code: string, readonly outcome: Outcome) { super(code); }
}
const denied = () => new TriageError(403, "operator_forbidden", "rejected_forbidden");
const conflict = () => new TriageError(409, "operator_conflict", "rejected_conflict");
const invalid = () => new TriageError(400, "operator_request_invalid", "rejected_invalid");
const unavailable = () => new TriageError(503, "operator_dependency_unavailable", "failed_dependency");
const headers = { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8", "X-Content-Type-Options": "nosniff" };
const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const operationPattern = /^\/operator\/v1\/cases\/([0-9a-f]{64})\/review-start$/u;
const queuePattern = /^\/operator\/v1\/cases\/read(?:\/([1-9][0-9]{0,9})\/([0-9a-f]{64}))?$/u;
const assertionPattern = new RegExp(`^(/operator/v1/cases/([0-9a-f]{64})/review-start)/assertions/(${uuid})$`, "u");
const encoder = new TextEncoder();

function response(value: unknown, status = 200): Response { return new Response(JSON.stringify(value), { status, headers }); }
async function digest(bytes: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer))]
    .map((value) => value.toString(16).padStart(2, "0")).join("");
}
async function requestDigest(method: string, pathname: string): Promise<string> {
  return digest(encoder.encode(JSON.stringify(["NW.MODERATION-OPERATOR.TRIAGE-REQUEST.v1", method, pathname])));
}
function sqlFailure(error: unknown): TriageError {
  if (error instanceof TriageError) return error;
  const message = error instanceof Error ? error.message : "";
  if (/rate exceeded|too many (?:live access sessions|active challenges)/u.test(message)) {
    return new TriageError(429, "operator_quota_exceeded", "rejected_quota");
  }
  if (message.includes("malformed JSON")) return denied();
  if (/constraint failed|cannot be replayed|already (?:been |has |reserved|started)|active reservation|not active|not current|expired|mismatched|requires /u.test(message)) return conflict();
  return unavailable();
}

// The newest admitted, unrevoked credential is the local candidate's credential
// epoch. A second query inside every transaction prevents role/alias/credential
// changes between the initial read and a write or protected metadata read.
const actorSQL = `SELECT identity.operator_id, credential.credential_id_sha256,
    credential.public_key_cose, admission.enrollment_admission_id,
    MAX(credential.registration_sign_count, COALESCE((
      SELECT MAX(authenticator_sign_count) FROM moderation_operator_challenge_consumptions
      WHERE credential_id_sha256 = credential.credential_id_sha256), 0)) AS sign_count
  FROM moderation_operator_subject_identities AS identity
  JOIN moderation_operator_enrollment_requests AS enrollment
    ON enrollment.target_operator_id = identity.operator_id
   AND enrollment.target_access_subject_hmac_key_version = identity.access_subject_hmac_key_version
   AND enrollment.target_access_subject_hmac = identity.access_subject_hmac
  JOIN moderation_operator_enrollment_admissions AS admission
    ON admission.enrollment_request_id = enrollment.enrollment_request_id
  JOIN moderation_operator_credentials AS credential
    ON credential.credential_id_sha256 = enrollment.target_credential_id_sha256
   AND credential.operator_id = identity.operator_id
   AND credential.public_key_cose = enrollment.target_public_key_cose_snapshot
   AND credential.registration_sign_count = enrollment.target_registration_sign_count
  WHERE identity.access_subject_hmac = ? AND identity.access_subject_hmac_key_version = ?
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_subject_identities AS newer
      WHERE newer.operator_id = identity.operator_id
        AND newer.access_subject_hmac_key_version > identity.access_subject_hmac_key_version)
    AND EXISTS (SELECT 1 FROM moderation_operator_state_events
      WHERE operator_id = identity.operator_id AND event_type = 'activated')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_state_events
      WHERE operator_id = identity.operator_id AND event_type = 'revoked')
    AND EXISTS (SELECT 1 FROM moderation_operator_role_events
      WHERE operator_id = identity.operator_id AND role_code = 'triage' AND event_type = 'granted')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_role_events
      WHERE operator_id = identity.operator_id AND role_code = 'triage' AND event_type = 'revoked')
    AND EXISTS (SELECT 1 FROM moderation_operator_credential_events
      WHERE credential_id_sha256 = credential.credential_id_sha256 AND event_type = 'registered')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_credential_events
      WHERE credential_id_sha256 = credential.credential_id_sha256 AND event_type = 'revoked')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_enrollment_admissions AS newer_admission
      JOIN moderation_operator_enrollment_requests AS newer_enrollment
        ON newer_enrollment.enrollment_request_id = newer_admission.enrollment_request_id
      WHERE newer_enrollment.target_operator_id = identity.operator_id
        AND newer_admission.rowid > admission.rowid)
  ORDER BY admission.rowid DESC LIMIT 1`;

function guard(db: D1Database, access: AuthenticatedModerationOperatorAccess, actor: Actor): D1PreparedStatement {
  // SQLite json() deliberately raises on denial so D1 rolls back the entire
  // batch. A SELECT returning zero rows would silently permit later statements.
  return db.prepare(`WITH current_actor AS (${actorSQL})
    SELECT json(CASE WHEN EXISTS (SELECT 1 FROM current_actor
      WHERE operator_id = ? AND credential_id_sha256 = ? AND enrollment_admission_id = ?)
      AND ? <= unixepoch() AND ? > unixepoch() THEN 'true' ELSE 'denied' END) AS admitted`)
    .bind(access.operatorSubjectHmac, access.subjectHmacKeyVersion,
      actor.operator_id, actor.credential_id_sha256, actor.enrollment_admission_id,
      access.issuedAt, access.expiresAt);
}
function admitSession(db: D1Database, access: AuthenticatedModerationOperatorAccess, actor: Actor): D1PreparedStatement {
  return db.prepare(`INSERT INTO moderation_operator_access_sessions(
    access_session_sha256, operator_id, access_subject_hmac_key_version, access_subject_hmac,
    token_issued_at, token_expires_at)
    SELECT ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM moderation_operator_access_sessions WHERE access_session_sha256 = ?)`)
    .bind(access.accessSessionSHA256, actor.operator_id, access.subjectHmacKeyVersion,
      access.operatorSubjectHmac, access.issuedAt, access.expiresAt, access.accessSessionSHA256);
}
function startAudit(db: D1Database, access: AuthenticatedModerationOperatorAccess, actor: Actor, audit: Audit): D1PreparedStatement {
  return db.prepare(`INSERT INTO moderation_operator_access_audit_starts(
    audit_request_id, operator_id, access_session_sha256, operation_code, request_sha256, case_reference_hmac)
    VALUES (?, ?, ?, ?, ?, ?)`).bind(audit.id, actor.operator_id, access.accessSessionSHA256,
      audit.operation, audit.requestDigest, audit.caseReference);
}
function finishAudit(db: D1Database, access: AuthenticatedModerationOperatorAccess, actor: Actor, audit: Audit,
  outcome: Outcome = "succeeded", status = 200): D1PreparedStatement {
  return db.prepare(`INSERT INTO moderation_operator_access_audit_finishes(
    audit_request_id, operator_id, access_session_sha256, operation_code, request_sha256,
    case_reference_hmac, outcome_code, status_code) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
    .bind(audit.id, actor.operator_id, access.accessSessionSHA256, audit.operation,
      audit.requestDigest, audit.caseReference, outcome, status);
}
async function batch(db: D1Database, statements: D1PreparedStatement[]): Promise<D1Result[]> {
  try { return await db.batch(statements); } catch (error) { throw sqlFailure(error); }
}

async function queue(env: LocalModerationTriageEnvironment, access: AuthenticatedModerationOperatorAccess, actor: Actor,
  method: string, pathname: string, afterDue = 0, afterReference = ""): Promise<Response> {
  const audit: Audit = { id: crypto.randomUUID(), operation: "case_read", caseReference: null,
    requestDigest: await requestDigest(method, pathname) };
  const result = await batch(env.db, [guard(env.db, access, actor), admitSession(env.db, access, actor),
    startAudit(env.db, access, actor, audit),
    env.db.prepare(`SELECT reference.case_reference_hmac AS caseReferenceHmac,
      cases.review_due_at AS reviewDueAt,
      EXISTS (SELECT 1 FROM moderation_advisory_live_sources AS source
        WHERE source.case_reference_hmac=reference.case_reference_hmac) AS evidenceAvailable,
      CASE WHEN advisory.job_id IS NULL THEN 'not_requested'
        WHEN result.job_id IS NULL THEN 'pending'
        ELSE json_extract(result.result_json, '$.reason') END AS advisoryReason,
      CASE WHEN json_extract(result.result_json, '$.priorityHint')='raise' THEN 'raise'
        ELSE 'preserve' END AS advisoryPriority,
      CASE WHEN EXISTS (SELECT 1 FROM moderation_case_events AS event
        WHERE event.report_id = cases.report_id AND event.event_type = 'review_started')
        THEN 'in_review' ELSE 'unreviewed' END AS reviewState,
      CASE WHEN NOT EXISTS (SELECT 1 FROM moderation_case_events AS event
        WHERE event.report_id = cases.report_id AND event.event_type = 'review_started'
          AND event.recorded_at <= cases.review_due_at) AND cases.review_due_at < unixepoch()
        THEN 1 ELSE 0 END AS slaExceeded,
      EXISTS (SELECT 1 FROM moderation_evidence_event_intents AS intent
        WHERE intent.case_reference_hmac = reference.case_reference_hmac AND intent.finalize_by >= unixepoch()
          AND NOT EXISTS (SELECT 1 FROM moderation_evidence_event_finalizations WHERE event_id = intent.event_id)) AS pendingFinalization
      FROM moderation_cases AS cases JOIN moderation_operator_versioned_case_references AS reference
        ON reference.report_id = cases.report_id
      LEFT JOIN moderation_advisory_current_jobs AS advisory ON advisory.report_id=cases.report_id
      LEFT JOIN moderation_advisory_results AS result ON result.job_id=advisory.job_id
      WHERE NOT EXISTS (SELECT 1 FROM moderation_case_events AS event
        WHERE event.report_id = cases.report_id AND event.event_type = 'review_decided')
        AND (cases.review_due_at > ? OR (cases.review_due_at = ? AND reference.case_reference_hmac > ?))
      ORDER BY cases.review_due_at, reference.case_reference_hmac LIMIT 21`).bind(afterDue, afterDue, afterReference),
    env.db.prepare(`SELECT COUNT(*) AS unboundCases FROM moderation_cases AS cases
      WHERE NOT EXISTS (SELECT 1 FROM moderation_operator_versioned_case_references WHERE report_id = cases.report_id)
        AND NOT EXISTS (SELECT 1 FROM moderation_case_events WHERE report_id = cases.report_id AND event_type = 'review_decided')`),
    finishAudit(env.db, access, actor, audit),
  ]);
  const cases = result[3]!.results;
  return response({ cases: cases.slice(0, 20), hasMore: cases.length > 20,
    unboundCases: (result[4]!.results[0] as { unboundCases: number }).unboundCases });
}

async function beginReview(env: LocalModerationTriageEnvironment, access: AuthenticatedModerationOperatorAccess,
  actor: Actor, pathname: string, caseReference: string): Promise<Response> {
  const challengeId = crypto.randomUUID();
  const actionId = crypto.randomUUID();
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const audit: Audit = { id: crypto.randomUUID(), operation: "challenge_issue", caseReference,
    requestDigest: await requestDigest("POST", pathname) };
  const result = await batch(env.db, [guard(env.db, access, actor), admitSession(env.db, access, actor),
    startAudit(env.db, access, actor, audit),
    env.db.prepare(`INSERT INTO moderation_case_reservations(
      reservation_id, case_reference_hmac, operator_id, access_subject_hmac_key_version, access_session_sha256, expires_at)
      VALUES (?, ?, ?, ?, ?, MIN(unixepoch() + 300, ?))`).bind(crypto.randomUUID(), caseReference,
      actor.operator_id, access.subjectHmacKeyVersion, access.accessSessionSHA256, access.expiresAt),
    env.db.prepare(`INSERT INTO moderation_operator_challenges(challenge_id, operator_id,
      access_subject_hmac_key_version, credential_id_sha256, access_session_sha256, challenge_value_sha256,
      purpose, action_type, action_id, case_reference_hmac, method, pathname, body_sha256, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, 'request', 'review_start', ?, ?, 'POST', ?, ?, MIN(unixepoch() + 300, ?))
      RETURNING expires_at`).bind(challengeId, actor.operator_id, access.subjectHmacKeyVersion,
      actor.credential_id_sha256, access.accessSessionSHA256, await digest(challenge), actionId, caseReference,
      pathname, await digest(new Uint8Array()), access.expiresAt),
    finishAudit(env.db, access, actor, audit, "succeeded", 202),
  ]);
  // This is a deferred, empty-body operation. The later HTTP body carries only
  // its authentication proof; it cannot replace the frozen operation's body.
  return response({ actionId, challengeId, challenge: base64urlEncode(challenge),
    assertionPath: `${pathname}/assertions/${challengeId}`, expiresAt: (result[4]!.results[0] as { expires_at: number }).expires_at,
    rpId: env.rpId, userVerification: "required" }, 202);
}

async function proveReview(request: Request, env: LocalModerationTriageEnvironment,
  access: AuthenticatedModerationOperatorAccess, actor: Actor, operationPath: string,
  caseReference: string, challengeId: string): Promise<Response> {
  const selection = await batch(env.db, [guard(env.db, access, actor),
    env.db.prepare(`SELECT challenge.* FROM moderation_operator_challenges AS challenge
    JOIN moderation_operator_enrollment_trusted_challenges AS trusted USING(challenge_id)
    WHERE challenge.challenge_id = ? AND challenge.operator_id = ? AND challenge.access_session_sha256 = ?
      AND challenge.credential_id_sha256 = ? AND trusted.enrollment_admission_id = ?
      AND challenge.purpose = 'request' AND challenge.action_type = 'review_start'
      AND challenge.case_reference_hmac = ? AND challenge.method = 'POST' AND challenge.pathname = ?
      AND challenge.issued_at <= unixepoch() AND challenge.expires_at > unixepoch()`)
    .bind(challengeId, actor.operator_id, access.accessSessionSHA256, actor.credential_id_sha256,
      actor.enrollment_admission_id, caseReference, operationPath)]);
  const challenge = (selection[1]!.results[0] ?? null) as Challenge | null;
  if (challenge === null || challenge.body_sha256 !== await digest(new Uint8Array())) throw conflict();
  const proofAudit: Audit = { id: crypto.randomUUID(), operation: "assertion_verify", caseReference,
    requestDigest: await requestDigest("POST", new URL(request.url).pathname) };
  await batch(env.db, [guard(env.db, access, actor), startAudit(env.db, access, actor, proofAudit)]);
  let reviewAudit: Audit | undefined;
  try {
    let prepared;
    try {
      prepared = await prepareModerationOperatorWebAuthnRequest(request, {
        expectedOrigin: env.origin, expectedRPID: env.rpId,
        expectedChallengeSHA256: challenge.challenge_value_sha256,
        credential: { credentialIdSHA256: actor.credential_id_sha256,
          publicKeyCose: new Uint8Array(actor.public_key_cose), counter: actor.sign_count },
      });
    } catch { throw invalid(); }
    // A separate committed batch is mandatory BEFORE signature verification.
    // A bad signature or rollback below never returns this challenge to service.
    await batch(env.db, [guard(env.db, access, actor), env.db.prepare(`INSERT INTO moderation_operator_assertion_attempts(
      challenge_id, operator_id, access_session_sha256, credential_id_sha256, assertion_sha256)
      VALUES (?, ?, ?, ?, ?)`).bind(challengeId, actor.operator_id, access.accessSessionSHA256,
      actor.credential_id_sha256, prepared.assertionSHA256)]);
    let verified;
    try { verified = await verifyPreparedModerationOperatorWebAuthnAssertion(prepared); } catch { throw invalid(); }
    const pendingAudit: Audit = { id: crypto.randomUUID(), operation: "review_start", caseReference,
      requestDigest: await requestDigest("POST", operationPath) };
    const eventId = crypto.randomUUID();
    const transaction = await batch(env.db, [guard(env.db, access, actor),
      env.db.prepare(`INSERT INTO moderation_operator_challenge_consumptions(challenge_id, operator_id,
        credential_id_sha256, verified_assertion_sha256, authenticator_sign_count) VALUES (?, ?, ?, ?, ?)`)
        .bind(challengeId, actor.operator_id, actor.credential_id_sha256, verified.assertionSHA256, verified.newCounter),
      env.db.prepare(`INSERT INTO moderation_operator_actions(action_id, case_reference_hmac, action_type,
        requester_operator_id, request_challenge_id, request_sha256, request_method, request_pathname,
        required_approvals, required_approver_role, expires_at)
        VALUES (?, ?, 'review_start', ?, ?, ?, 'POST', ?, 0, NULL, MIN(unixepoch() + 900, ?))`)
        .bind(challenge.action_id, caseReference, actor.operator_id, challengeId,
          challenge.body_sha256, operationPath, access.expiresAt),
      startAudit(env.db, access, actor, pendingAudit),
      env.db.prepare(`INSERT INTO moderation_evidence_event_intents(event_id, case_reference_hmac, sequence,
        action_id, action_type, actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
        previous_event_sha256, artifact_sha256, case_outcome_code, legacy_backfill)
        VALUES (?, ?, COALESCE((SELECT MAX(sequence) + 1 FROM moderation_evidence_ledger_events WHERE case_reference_hmac = ?), 1),
          ?, 'review_start', ?, ?, unixepoch(), COALESCE((SELECT event_sha256 FROM moderation_evidence_ledger_events
            WHERE case_reference_hmac = ? ORDER BY sequence DESC LIMIT 1), ?), ?, NULL, 0)
        RETURNING event_id, action_id, sequence, occurred_at, previous_event_sha256, artifact_sha256`)
        .bind(eventId, caseReference, caseReference, challenge.action_id, access.subjectHmacKeyVersion,
          access.operatorSubjectHmac, caseReference, "0".repeat(64), verified.assertionSHA256),
    ]);
    reviewAudit = pendingAudit;
    const intent = transaction[4]!.results[0] as unknown as Intent;
    const event = { schema: MODERATION_EVIDENCE_EVENT_SCHEMA, sequence: intent.sequence,
      eventID: intent.event_id, actionID: intent.action_id, actionType: "review_start",
      caseReferenceHmac: caseReference, actorSubjectHmacKeyVersion: access.subjectHmacKeyVersion,
      actorSubjectHmac: access.operatorSubjectHmac, occurredAt: intent.occurred_at,
      previousEventSHA256: intent.previous_event_sha256, artifactSHA256: intent.artifact_sha256 };
    const eventDigest = await digest(canonicalModerationEvidenceBytes(event));
    await batch(env.db, [guard(env.db, access, actor),
      env.db.prepare(`INSERT INTO moderation_evidence_ledger_events(case_reference_hmac, sequence, event_id, action_id,
        action_type, actor_subject_hmac_key_version, actor_subject_hmac, occurred_at,
        previous_event_sha256, artifact_sha256, event_sha256)
        VALUES (?, ?, ?, ?, 'review_start', ?, ?, ?, ?, ?, ?)`)
        .bind(caseReference, intent.sequence, intent.event_id, intent.action_id,
          access.subjectHmacKeyVersion, access.operatorSubjectHmac, intent.occurred_at,
          intent.previous_event_sha256, intent.artifact_sha256, eventDigest),
      finishAudit(env.db, access, actor, pendingAudit), finishAudit(env.db, access, actor, proofAudit),
    ]);
    return response({ caseReferenceHmac: caseReference, reviewState: "in_review" });
  } catch (error) {
    const failure = sqlFailure(error);
    try {
      await batch(env.db, [finishAudit(env.db, access, actor, proofAudit, failure.outcome, failure.status),
        ...(reviewAudit === undefined ? [] : [finishAudit(env.db, access, actor, reviewAudit, failure.outcome, failure.status)])]);
    } catch { throw unavailable(); }
    throw failure;
  }
}

export async function routeLocalModerationOperatorTriage(request: Request, env: LocalModerationTriageEnvironment): Promise<Response> {
  if (env.runtimeEnabled !== "YES" || env.environment !== "local") {
    return response({ error: { code: "operator_runtime_disabled" } }, 503);
  }
  try {
    const url = new URL(request.url);
    // Public, data-free LOCAL shell. Protected case data is fetched separately
    // through the same Access/actor/audit gate below. Never deployed by Worker.
    if (request.method === "GET" && url.pathname === "/operator/console"
        && url.origin === env.origin && url.search === "") return localModerationConsole();
    const operation = operationPattern.exec(url.pathname);
    const assertion = assertionPattern.exec(url.pathname);
    const page = queuePattern.exec(url.pathname);
    const readQueue = (request.method === "GET" && url.pathname === "/operator/v1/cases")
      || (request.method === "POST" && page !== null && Number(page[1] ?? 0) <= 2_147_483_647);
    if (!(readQueue
        || (request.method === "POST" && (operation !== null || assertion !== null)))) {
      return response({ error: { code: "not_found" } }, 404);
    }
    let access: AuthenticatedModerationOperatorAccess;
    try { access = await authenticateCloudflareAccessRequest(request, env.access); }
    catch { return response({ error: { code: "operator_authentication_failed" } }, 401); }
    const origin = new URL(env.origin);
    if (origin.protocol !== "https:" || origin.origin !== env.origin || origin.hostname !== env.rpId
        || url.origin !== env.origin || request.headers.get("origin") !== env.origin || url.search !== "") throw denied();
    if (assertion === null && request.body !== null) throw invalid();
    const actor = await env.db.prepare(actorSQL)
      .bind(access.operatorSubjectHmac, access.subjectHmacKeyVersion).first<Actor>();
    if (actor === null) throw denied();
    // Same-origin browser GET omits Origin. POST read preserves the strict
    // existing Origin gate without trusting a JS-supplied substitute header.
    if (readQueue) return await queue(env, access, actor, request.method, url.pathname,
      Number(page?.[1] ?? 0), page?.[2] ?? "");
    if (operation !== null) return await beginReview(env, access, actor, url.pathname, operation[1]!);
    return await proveReview(request, env, access, actor, assertion![1]!, assertion![2]!, assertion![3]!);
  } catch (error) {
    const failure = sqlFailure(error);
    return response({ error: { code: failure.code } }, failure.status);
  }
}
