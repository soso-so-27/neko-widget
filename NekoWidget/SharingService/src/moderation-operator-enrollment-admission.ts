import { base64urlEncode, sha256 } from "./encoding";
import { encodeCanonicalFields } from "./protocol";
import { MODERATION_OPERATOR_REGISTRATION_POLICY } from "./moderation-operator-webauthn";
import type { LocalModerationEnrollmentBinding, UnadmittedLocalModerationEnrollment } from "./moderation-operator-enrollment-ceremony";
import { canonicalizeLocalInitialEnrollment, localInitialEnrollmentApprovalTranscript,
  verifyLocalInitialEnrollmentOfflineApprovals, type LocalEnrollmentInstallationScope,
  type LocalEnrollmentOfflineAuthority, type LocalEnrollmentOfflineApproval,
  type LocalInitialEnrollmentContext } from "./moderation-operator-enrollment-canonical";

/** Trusted local host only. The host pins target, roles, scope and authorities,
 * authenticates Access anew, and supplies that exact session binding. Browser
 * receipts, browser-selected roles/keys and admission booleans are never inputs.
 * Offline administrators must already provision operator/identity/activation/
 * roles and the authority set. This writer never creates or changes those rows.
 */
export interface LocalInitialEnrollmentPolicy {
  binding: LocalModerationEnrollmentBinding;
  scope: LocalEnrollmentInstallationScope;
  activeRoles: readonly string[];
  authorities: readonly LocalEnrollmentOfflineAuthority[];
}
export interface LocalInitialEnrollmentRequest {
  kind: "unadmitted-local-initial-enrollment-request";
  requestID: string; ceremonyID: string; requestedAt: number; expiresAt: number;
  canonicalRequestSHA256: string;
  approvalTranscripts: readonly Readonly<{keyID: string; revision: number; transcriptBase64url: string}>[];
  enrollmentAdmissionAuthorized: false; hardwareProvenanceVerified: false; realHumanVerified: false;
}
export interface LocalInitialEnrollmentAdmission {
  kind: "locally-admitted-initial-operator";
  requestID: string; ceremonyID: string; canonicalRequestSHA256: string;
  admissionID: string; admittedAt: number; admissionProvenanceSHA256: string;
  operatorID: string; activeRoles: readonly string[]; accessSessionSHA256: string;
  hardwareProvenanceVerified: false; realHumanVerified: false;
}
export type LocalInitialEnrollmentIdentifier = {requestID: string; ceremonyID?: never} | {ceremonyID: string; requestID?: never};
export type LocalInitialEnrollmentStatus = {status: "not_found" | "expired" | "attempted" | "pending" | "admitted";
  request?: LocalInitialEnrollmentRequest; receipt?: LocalInitialEnrollmentAdmission};

function fail(): never { throw new Error("local_initial_enrollment_unavailable"); }
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const flags = {enrollmentAdmissionAuthorized: false as const, hardwareProvenanceVerified: false as const, realHumanVerified: false as const};
// Snapshot data properties only; reject getters, functions, symbols, nonplain
// objects and sparse arrays before an await. This is not a browser receipt parser.
function copy<T>(input: T): T {
  function visit(value: unknown, depth: number): unknown {
    if (depth > 6) fail();
    if (value === null || ["string", "number", "boolean"].includes(typeof value)) return value;
    if (typeof value !== "object" || value === null) fail();
    if (Array.isArray(value)) {
      if (value.length > 8 || Object.getPrototypeOf(value) !== Array.prototype || Reflect.ownKeys(value).length !== value.length + 1) fail();
      const descriptors = Object.getOwnPropertyDescriptors(value);
      return Array.from({length: value.length}, (_, i) => {
        const entry = descriptors[String(i)]; if (!entry || !("value" in entry)) fail(); return visit(entry.value, depth + 1);
      });
    }
    if (![Object.prototype, null].includes(Object.getPrototypeOf(value))) fail();
    const result: Record<string, unknown> = {};
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== "string") fail();
      const d = Object.getOwnPropertyDescriptor(value, key)!; if (!("value" in d)) fail();
      Object.defineProperty(result, key, {value: visit(d.value, depth + 1), enumerable: true});
    }
    return result;
  }
  return visit(input, 0) as T;
}
function stable(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable((value as Record<string, unknown>)[key])}`).join(",")}}`;
}
const digest = async (fields: readonly string[]) => [...await sha256(encodeCanonicalFields(fields))].map((b) => b.toString(16).padStart(2, "0")).join("");
async function now(db: D1Database): Promise<number> { return (await db.prepare("SELECT unixepoch() AS now").first<{now:number}>())!.now; }
const bindingWhere = `c.operator_id=? AND c.access_subject_hmac=? AND c.access_subject_hmac_key_version=?
 AND c.access_session_sha256=? AND c.access_key_id=? AND c.access_issued_at=? AND c.access_expires_at=?
 AND c.installation_scope_sha256=? AND c.authority_set_sha256=? AND c.expected_origin=? AND c.expected_rp_id=?`;
function bindingValues(b: LocalModerationEnrollmentBinding) {
  return [b.operatorID, b.access.operatorSubjectHmac, b.access.subjectHmacKeyVersion, b.access.accessSessionSHA256,
    b.access.keyId, b.access.issuedAt, b.access.expiresAt, b.installationScopeSHA256, b.authoritySetSHA256, b.expectedOrigin, b.expectedRPID];
}
type Row = Record<string, string | number | ArrayBuffer | number[]>;
async function readDurable(db: D1Database, ceremonyID: string, binding: LocalModerationEnrollmentBinding): Promise<UnadmittedLocalModerationEnrollment> {
  if (!uuid.test(ceremonyID)) fail();
  const row = await db.prepare(`SELECT c.*,r.*,p.verified_assertion_sha256,p.authenticator_sign_count
    FROM moderation_operator_enrollment_ceremonies c JOIN moderation_operator_enrollment_ceremony_registrations r USING(ceremony_id)
    JOIN moderation_operator_enrollment_ceremony_possessions p USING(ceremony_id)
    JOIN moderation_operator_enrollment_ceremony_attempts a ON a.attempt_id=r.attempt_id AND a.ceremony_id=c.ceremony_id AND a.phase='registration'
    JOIN moderation_operator_enrollment_ceremony_attempts z ON z.attempt_id=p.attempt_id AND z.ceremony_id=c.ceremony_id AND z.phase='possession'
    WHERE c.ceremony_id=? AND ${bindingWhere}`).bind(ceremonyID, ...bindingValues(binding)).first<Row>();
  if (!row) fail();
  const storedBinding: LocalModerationEnrollmentBinding = {operatorID: row.operator_id as string,
    access: {operatorSubjectHmac: row.access_subject_hmac as string, subjectHmacKeyVersion: row.access_subject_hmac_key_version as number,
      accessSessionSHA256: row.access_session_sha256 as string, keyId: row.access_key_id as string, issuedAt: row.access_issued_at as number, expiresAt: row.access_expires_at as number},
    installationScopeSHA256: row.installation_scope_sha256 as string, authoritySetSHA256: row.authority_set_sha256 as string,
    expectedOrigin: row.expected_origin as string, expectedRPID: row.expected_rp_id as string};
  if (stable(binding) !== stable(storedBinding)) fail();
  return {kind: "unadmitted-local-operator-enrollment", ...flags, ceremonyID, binding: storedBinding,
    issuedAt: row.issued_at as number, expiresAt: row.expires_at as number,
    registrationChallengeID: row.registration_challenge_id as string, registrationChallengeSHA256: row.registration_challenge_sha256 as string,
    registration: {kind: "unadmitted-operator-registration", ...flags,
      registrationSHA256: row.registration_sha256 as string, credential: {credentialIdSHA256: row.credential_id_sha256 as string,
        publicKeyCose: new Uint8Array(row.public_key_cose as ArrayBuffer), counter: row.registration_sign_count as number},
      publicKeyCoseSHA256: row.public_key_cose_sha256 as string, authenticatorAAGUIDSHA256: row.authenticator_aaguid_sha256 as string,
      attestationPolicy: MODERATION_OPERATOR_REGISTRATION_POLICY, attestationFormat: row.attestation_format as "none" | "packed",
      selfAttestationSignatureVerified: row.self_attestation_verified === 1},
    possession: {challengeID: row.possession_challenge_id as string, challengeSHA256: row.possession_challenge_sha256 as string,
      assertionSHA256: row.verified_assertion_sha256 as string, newCounter: row.authenticator_sign_count as number}};
}
function authoritiesJSON(policy: LocalInitialEnrollmentPolicy): string {
  return JSON.stringify([...policy.authorities].sort((a, b) => a.keyID < b.keyID ? -1 : 1).map((a) => ({
    keyID: a.keyID, revision: a.revision, publicKeyFingerprintSHA256: a.publicKeyFingerprintSHA256, authorizedAt: a.authorizedAt})));
}
function rolesJSON(policy: LocalInitialEnrollmentPolicy): string { return JSON.stringify([...policy.activeRoles].sort()); }
function currentGuard(db: D1Database, requestID: string): D1PreparedStatement {
  return db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_current
    WHERE enrollment_request_id=?) THEN 'true' ELSE 'denied' END) AS valid`).bind(requestID);
}
async function contextFor(db: D1Database, policy: LocalInitialEnrollmentPolicy, identifier: LocalInitialEnrollmentIdentifier) {
  const byRequest = "requestID" in identifier;
  const id = byRequest ? identifier.requestID : identifier.ceremonyID;
  if (typeof id !== "string" || !uuid.test(id)) fail();
  const row = await db.prepare(`SELECT q.*,b.ceremony_id,b.roles_json,b.authorities_json,b.role_snapshot_sha256
    FROM moderation_operator_enrollment_requests q JOIN moderation_operator_initial_enrollment_bindings b USING(enrollment_request_id)
    WHERE ${byRequest ? "q.enrollment_request_id" : "b.ceremony_id"}=?`).bind(id).first<Row>();
  if (!row) return null;
  const enrollment = await readDurable(db, row.ceremony_id as string, policy.binding);
  const context: LocalInitialEnrollmentContext = {scope: policy.scope, activeRoles: policy.activeRoles, authorities: policy.authorities,
    enrollment, requestID: row.enrollment_request_id as string, requestedAt: row.requested_at as number};
  const canonical = await canonicalizeLocalInitialEnrollment(context);
  if (canonical.canonicalRequestSHA256 !== row.canonical_request_sha256 || canonical.roleSnapshotSHA256 !== row.role_snapshot_sha256
    || row.roles_json !== rolesJSON(policy) || row.authorities_json !== authoritiesJSON(policy)
    || canonical.expiresAt !== row.expires_at) fail();
  return {context, canonical};
}
async function displayRequest(context: LocalInitialEnrollmentContext): Promise<LocalInitialEnrollmentRequest> {
  const request = await canonicalizeLocalInitialEnrollment(context);
  const approvalTranscripts = await Promise.all([...context.authorities].sort((a,b) => a.keyID < b.keyID ? -1 : 1).map(async (a) => Object.freeze({
    keyID: a.keyID, revision: a.revision, transcriptBase64url: base64urlEncode(await localInitialEnrollmentApprovalTranscript(context, a.keyID))})));
  return Object.freeze({kind: "unadmitted-local-initial-enrollment-request", ...flags, requestID: request.requestID,
    ceremonyID: context.enrollment.ceremonyID, requestedAt: request.requestedAt, expiresAt: request.expiresAt,
    canonicalRequestSHA256: request.canonicalRequestSHA256, approvalTranscripts: Object.freeze(approvalTranscripts)});
}

export async function createLocalInitialEnrollmentRequest(db: D1Database,
  input: LocalInitialEnrollmentPolicy & {ceremonyID: string}): Promise<LocalInitialEnrollmentRequest> {
  try {
    const options = copy(input);
    const enrollment = await readDurable(db, options.ceremonyID, options.binding);
    const requestID = crypto.randomUUID();
    const context = {scope: options.scope, activeRoles: options.activeRoles, authorities: options.authorities,
      enrollment, requestID, requestedAt: await now(db)};
    const canonical = await canonicalizeLocalInitialEnrollment(context);
    const r = enrollment.registration; const b = enrollment.binding;
    // No role/identity/activation is inserted. This must be a fresh credential;
    // an existing legacy row cannot acquire staging provenance by attaching a
    // new ceremony. The old request guards and bridge trigger roll back the
    // fresh credential and event if any prerequisite or concurrent request fails.
    await db.batch([
      db.prepare(`INSERT INTO moderation_operator_credentials(credential_id_sha256,operator_id,public_key_cose,registration_sign_count) VALUES(?,?,?,?)`)
        .bind(r.credential.credentialIdSHA256, b.operatorID, r.credential.publicKeyCose, r.credential.counter),
      db.prepare(`INSERT INTO moderation_operator_credential_events(credential_id_sha256,event_type) VALUES(?,'registered')`)
        .bind(r.credential.credentialIdSHA256),
      db.prepare(`INSERT INTO moderation_operator_enrollment_requests(enrollment_request_id,enrollment_kind,request_schema_version,
        canonical_request_sha256,target_operator_id,target_access_subject_hmac_key_version,target_access_subject_hmac,
        target_credential_id_sha256,target_public_key_cose_sha256,target_public_key_cose_snapshot,target_registration_sign_count,
        attestation_evidence_sha256,attestation_policy_revision,authenticator_aaguid_sha256,expires_at)
        VALUES(?,'initial_bootstrap',1,?,?,?,?,?,?,?,?,?,1,?,?)`)
        .bind(requestID, canonical.canonicalRequestSHA256, b.operatorID, b.access.subjectHmacKeyVersion, b.access.operatorSubjectHmac,
          r.credential.credentialIdSHA256, r.publicKeyCoseSHA256, r.credential.publicKeyCose, r.credential.counter,
          r.registrationSHA256, r.authenticatorAAGUIDSHA256, enrollment.expiresAt),
      db.prepare(`INSERT INTO moderation_operator_initial_enrollment_bindings(enrollment_request_id,ceremony_id,
        installation_scope_sha256,authority_set_sha256,role_snapshot_sha256,roles_json,authorities_json) VALUES(?,?,?,?,?,?,?)`)
        .bind(requestID, options.ceremonyID, canonical.installationScopeSHA256, canonical.authoritySetSHA256,
          canonical.roleSnapshotSHA256, rolesJSON(options), authoritiesJSON(options)),
    ]);
    // requestedAt is the committed DB value, not the earlier hash-preparation time.
    const stored = await contextFor(db, options, {requestID}); if (!stored) fail();
    return displayRequest(stored.context);
  } catch { return fail(); }
}

interface ApprovalRow {offline_authority_key_id: string; authority_policy_revision: number;
  authority_public_key_fingerprint_sha256: string; authority_signature_sha256: string; approved_at: number}
async function readReceipt(db: D1Database, context: LocalInitialEnrollmentContext): Promise<LocalInitialEnrollmentAdmission | null> {
  const row = await db.prepare(`SELECT a.*,q.canonical_request_sha256 FROM moderation_operator_enrollment_admissions a
    JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id) WHERE enrollment_request_id=?`)
    .bind(context.requestID).first<{enrollment_admission_id:string;admitted_at:number;admission_provenance_sha256:string;canonical_request_sha256:string}>();
  if (!row) return null;
  return Object.freeze({kind: "locally-admitted-initial-operator", requestID: context.requestID,
    ceremonyID: context.enrollment.ceremonyID, canonicalRequestSHA256: row.canonical_request_sha256,
    admissionID: row.enrollment_admission_id, admittedAt: row.admitted_at, admissionProvenanceSHA256: row.admission_provenance_sha256,
    operatorID: context.enrollment.binding.operatorID, activeRoles: Object.freeze([...context.activeRoles].sort()),
    accessSessionSHA256: context.enrollment.binding.access.accessSessionSHA256, hardwareProvenanceVerified: false, realHumanVerified: false});
}

export async function admitLocalInitialEnrollment(db: D1Database,
  input: LocalInitialEnrollmentPolicy & {requestID: string; approvals: readonly LocalEnrollmentOfflineApproval[]}): Promise<LocalInitialEnrollmentAdmission> {
  let ownedAttempt: {requestID: string; attemptID: string} | undefined;
  try {
    const options = copy(input);
    const stored = await contextFor(db, options, {requestID: options.requestID}); if (!stored) fail();
    const {context, canonical} = stored;
    // Durable one-shot CAS commits before cryptographic verification. Failure or
    // an unknown outcome is recovered by read-only status, never another attempt.
    ownedAttempt = {requestID: options.requestID, attemptID: crypto.randomUUID()};
    await db.prepare(`INSERT INTO moderation_operator_initial_enrollment_attempts(enrollment_request_id,attempt_id) VALUES(?,?)`)
      .bind(ownedAttempt.requestID, ownedAttempt.attemptID).run();
    const verified = await verifyLocalInitialEnrollmentOfflineApprovals(context, options.approvals, await now(db));
    await db.batch([currentGuard(db, options.requestID), ...verified.verifiedApprovals.map((a) => db.prepare(`
      INSERT INTO moderation_operator_enrollment_offline_approvals(enrollment_request_id,offline_authority_key_id,
       authority_policy_revision,authority_public_key_fingerprint_sha256,authority_signature_sha256) VALUES(?,?,?,?,?)`)
      .bind(options.requestID, a.keyID, a.revision, a.publicKeyFingerprintSHA256, a.signatureSHA256))]);
    const approvals = (await db.prepare(`SELECT * FROM moderation_operator_enrollment_offline_approvals
      WHERE enrollment_request_id=? ORDER BY offline_authority_key_id`).bind(options.requestID).all<ApprovalRow>()).results;
    if (approvals.length !== 2 || approvals.some((a, i) => a.offline_authority_key_id !== verified.verifiedApprovals[i]!.keyID
      || a.authority_signature_sha256 !== verified.verifiedApprovals[i]!.signatureSHA256)) fail();
    // Exact C encoding, actual committed approval times, sorted authorities. No
    // timestamp equality across separate statements is assumed or manufactured.
    const provenance = await digest(["NW.MODERATION-ENROLLMENT.ADMISSION.v1", "1", canonical.installationScopeSHA256,
      canonical.requestID, canonical.canonicalRequestSHA256, String(canonical.requestedAt), String(canonical.expiresAt),
      context.enrollment.ceremonyID, canonical.roleSnapshotSHA256, canonical.authoritySetSHA256, "2",
      ...approvals.flatMap((a) => [a.offline_authority_key_id, String(a.authority_policy_revision),
        a.authority_public_key_fingerprint_sha256, a.authority_signature_sha256, String(a.approved_at)])]);
    const admissionID = crypto.randomUUID(); const b = context.enrollment.binding;
    await db.batch([currentGuard(db, options.requestID),
      // Recheck the exact rows hashed above inside the same final transaction.
      ...approvals.map((a) => db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moderation_operator_enrollment_offline_approvals
        WHERE enrollment_request_id=? AND offline_authority_key_id=? AND authority_policy_revision=?
        AND authority_public_key_fingerprint_sha256=? AND authority_signature_sha256=? AND approved_at=?) THEN 'true' ELSE 'denied' END)`)
        .bind(options.requestID, a.offline_authority_key_id, a.authority_policy_revision, a.authority_public_key_fingerprint_sha256, a.authority_signature_sha256, a.approved_at)),
      db.prepare(`INSERT INTO moderation_operator_enrollment_admissions(enrollment_admission_id,enrollment_request_id,admission_provenance_sha256) VALUES(?,?,?)`)
        .bind(admissionID, options.requestID, provenance),
      db.prepare(`INSERT INTO moderation_operator_access_sessions(access_session_sha256,operator_id,access_subject_hmac_key_version,
        access_subject_hmac,token_issued_at,token_expires_at) VALUES(?,?,?,?,?,?)`)
        .bind(b.access.accessSessionSHA256, b.operatorID, b.access.subjectHmacKeyVersion, b.access.operatorSubjectHmac, b.access.issuedAt, b.access.expiresAt),
    ]);
    const receipt = await readReceipt(db, context); if (!receipt) fail(); return receipt;
  } catch {
    if (ownedAttempt) {
      // Fence only this call's durable attempt, including an unknown CAS result.
      // A duplicate/parallel caller has a different attempt ID and cannot abort
      // the owner. A committed admission wins over a lost response. If this
      // audit write also fails, keep the attempt unresolved until expiry.
      try {
        await db.prepare(`INSERT INTO moderation_operator_initial_enrollment_failures(enrollment_request_id,attempt_id)
          SELECT enrollment_request_id,attempt_id FROM moderation_operator_initial_enrollment_attempts a
          WHERE a.enrollment_request_id=? AND a.attempt_id=?
           AND NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_admissions WHERE enrollment_request_id=a.enrollment_request_id)
           AND NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_failures WHERE enrollment_request_id=a.enrollment_request_id)`)
          .bind(ownedAttempt.requestID, ownedAttempt.attemptID).run();
      } catch { /* No retry or success inference after an unavailable audit write. */ }
    }
    return fail();
  }
}

/** Read-only recovery after response loss. An admitted receipt is historical
 * evidence of this transaction, not a fresh role/session authorization check. */
export async function readLocalInitialEnrollmentStatus(db: D1Database,
  input: LocalInitialEnrollmentPolicy & LocalInitialEnrollmentIdentifier): Promise<LocalInitialEnrollmentStatus> {
  try {
    const options = copy(input);
    if (("requestID" in options) === ("ceremonyID" in options)) fail();
    const stored = await contextFor(db, options, "requestID" in options ? {requestID: options.requestID!} : {ceremonyID: options.ceremonyID!});
    if (!stored) return {status: "not_found"};
    const request = await displayRequest(stored.context);
    const receipt = await readReceipt(db, stored.context); if (receipt) return {status: "admitted", request, receipt};
    if (await now(db) >= stored.context.enrollment.expiresAt) return {status: "expired"};
    const attempt = await db.prepare("SELECT 1 FROM moderation_operator_initial_enrollment_attempts WHERE enrollment_request_id=?")
      .bind(stored.context.requestID).first();
    return {status: attempt ? "attempted" : "pending", request};
  } catch { return fail(); }
}
