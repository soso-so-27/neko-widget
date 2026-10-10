import type { AuthenticatedModerationOperatorAccess } from "./moderation-operator-auth";
import {
  MODERATION_OPERATOR_REGISTRATION_POLICY,
  prepareModerationOperatorWebAuthnRegistration,
  verifyPreparedModerationOperatorWebAuthnRegistration,
  prepareModerationOperatorWebAuthnAssertion,
  verifyPreparedModerationOperatorWebAuthnAssertion,
  type UnadmittedModerationOperatorWebAuthnRegistration,
} from "./moderation-operator-webauthn";

/** Trusted local host only, before admission. This is neither authentication
 * middleware nor an enrollment/role writer. The caller must authenticate Access
 * and pin the installation and offline authority set before creating a ceremony.
 * SQL administrators and this host remain trusted. No route exposes these APIs.
 */
export interface LocalModerationEnrollmentBinding {
  readonly operatorID: string;
  readonly access: Readonly<AuthenticatedModerationOperatorAccess>;
  readonly installationScopeSHA256: string;
  readonly authoritySetSHA256: string;
  readonly expectedOrigin: string;
  readonly expectedRPID: string;
}

interface Unadmitted {
  readonly enrollmentAdmissionAuthorized: false;
  readonly hardwareProvenanceVerified: false;
  readonly realHumanVerified: false;
}
export interface LocalModerationEnrollmentChallenge extends Unadmitted {
  readonly kind: "unadmitted-local-enrollment-challenge";
  readonly ceremonyID: string;
  readonly phase: "registration" | "possession";
  readonly challengeID: string;
  /** Base64url bytes returned once. Only SHA-256 of decoded bytes is persisted. */
  readonly challenge: string;
  readonly challengeSHA256: string;
  readonly issuedAt: number;
  readonly expiresAt: number;
}
export interface UnadmittedLocalModerationEnrollment extends Unadmitted {
  readonly kind: "unadmitted-local-operator-enrollment";
  readonly ceremonyID: string;
  readonly binding: LocalModerationEnrollmentBinding;
  readonly issuedAt: number;
  readonly expiresAt: number;
  readonly registrationChallengeID: string;
  readonly registrationChallengeSHA256: string;
  readonly registration: UnadmittedModerationOperatorWebAuthnRegistration;
  readonly possession: Readonly<{
    challengeID: string;
    challengeSHA256: string;
    assertionSHA256: string;
    newCounter: number;
  }>;
}
export interface VerifyLocalModerationEnrollmentOptions {
  readonly ceremonyID: string;
  readonly binding: LocalModerationEnrollmentBinding;
  readonly response: unknown;
}

const unadmitted = Object.freeze({ enrollmentAdmissionAuthorized: false as const,
  hardwareProvenanceVerified: false as const, realHumanVerified: false as const });
const failure = (): Error => new Error("local_moderation_enrollment_unavailable");
const shaPattern = /^[0-9a-f]{64}$/u;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
function snapshotBinding(value: LocalModerationEnrollmentBinding): LocalModerationEnrollmentBinding {
  const access = Object.freeze({ operatorSubjectHmac: value.access.operatorSubjectHmac,
    subjectHmacKeyVersion: value.access.subjectHmacKeyVersion,
    accessSessionSHA256: value.access.accessSessionSHA256, keyId: value.access.keyId,
    issuedAt: value.access.issuedAt, expiresAt: value.access.expiresAt });
  const binding = Object.freeze({ operatorID: value.operatorID, access,
    installationScopeSHA256: value.installationScopeSHA256, authoritySetSHA256: value.authoritySetSHA256,
    expectedOrigin: value.expectedOrigin, expectedRPID: value.expectedRPID });
  if (!uuidPattern.test(binding.operatorID) || ![access.operatorSubjectHmac, access.accessSessionSHA256,
    binding.installationScopeSHA256, binding.authoritySetSHA256].every((v) => typeof v === "string" && shaPattern.test(v))
    || !Number.isInteger(access.subjectHmacKeyVersion) || access.subjectHmacKeyVersion < 1 || access.subjectHmacKeyVersion > 2147483647
    || !Number.isSafeInteger(access.issuedAt) || access.issuedAt < 0 || !Number.isSafeInteger(access.expiresAt)
    || access.expiresAt <= access.issuedAt || typeof access.keyId !== "string" || access.keyId.length < 1 || access.keyId.length > 256
    || typeof binding.expectedOrigin !== "string" || binding.expectedOrigin.length > 512
    || typeof binding.expectedRPID !== "string" || binding.expectedRPID.length > 253
    || !binding.expectedRPID.split(".").every((part) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(part))) throw failure();
  const origin = new URL(binding.expectedOrigin);
  if (origin.protocol !== "https:" || origin.origin !== binding.expectedOrigin || origin.username || origin.password
    || origin.pathname !== "/" || origin.search || origin.hash
    || new URL(`https://${binding.expectedRPID}`).hostname !== binding.expectedRPID
    || !(origin.hostname === binding.expectedRPID || origin.hostname.endsWith(`.${binding.expectedRPID}`))) throw failure();
  return binding;
}
function values(binding: LocalModerationEnrollmentBinding): (string | number)[] {
  const a = binding.access;
  return [binding.operatorID, a.operatorSubjectHmac, a.subjectHmacKeyVersion, a.accessSessionSHA256,
    a.keyId, a.issuedAt, a.expiresAt, binding.installationScopeSHA256, binding.authoritySetSHA256,
    binding.expectedOrigin, binding.expectedRPID];
}
const bindingWhere = `c.operator_id=? AND c.access_subject_hmac=? AND c.access_subject_hmac_key_version=?
 AND c.access_session_sha256=? AND c.access_key_id=? AND c.access_issued_at=? AND c.access_expires_at=?
 AND c.installation_scope_sha256=? AND c.authority_set_sha256=? AND c.expected_origin=? AND c.expected_rp_id=?`;
async function freshChallenge() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return { challengeID: crypto.randomUUID(), challenge: btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, ""),
    challengeSHA256: [...digest].map((b) => b.toString(16).padStart(2, "0")).join("") };
}
interface CeremonyRow {
  ceremony_id: string; issued_at: number; expires_at: number;
  registration_challenge_id: string; registration_challenge_sha256: string;
}
interface RegistrationRow {
  registration_sha256: string; credential_id_sha256: string; public_key_cose: ArrayBuffer | number[];
  public_key_cose_sha256: string; registration_sign_count: number; authenticator_aaguid_sha256: string;
  attestation_format: "none" | "packed"; self_attestation_verified: number;
  possession_challenge_id: string; possession_challenge_sha256: string;
}

export async function createLocalModerationEnrollmentCeremony(db: D1Database,
  input: LocalModerationEnrollmentBinding, options: { ttlSeconds?: number } = {}): Promise<LocalModerationEnrollmentChallenge> {
  try {
    const binding = snapshotBinding(input);
    const ttl = options.ttlSeconds ?? 900;
    if (!Number.isInteger(ttl) || ttl < 1 || ttl > 900) throw failure();
    const ceremonyID = crypto.randomUUID(); const challenge = await freshChallenge();
    const row = await db.prepare(`INSERT INTO moderation_operator_enrollment_ceremonies(
      ceremony_id,operator_id,access_subject_hmac,access_subject_hmac_key_version,access_session_sha256,
      access_key_id,access_issued_at,access_expires_at,installation_scope_sha256,authority_set_sha256,expected_origin,expected_rp_id,
      registration_challenge_id,registration_challenge_sha256,expires_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,MIN(unixepoch()+?,?-1)) RETURNING issued_at,expires_at`)
      .bind(ceremonyID, ...values(binding), challenge.challengeID, challenge.challengeSHA256, ttl, binding.access.expiresAt)
      .first<{issued_at: number; expires_at: number}>();
    if (!row) throw failure();
    return Object.freeze({ kind: "unadmitted-local-enrollment-challenge", ...unadmitted, ceremonyID,
      phase: "registration", ...challenge, issuedAt: row.issued_at, expiresAt: row.expires_at });
  } catch { throw failure(); }
}

/** Consume in its own committed statement before prepare/verify, never inside a
 * result transaction. Malformed crypto input also burns an otherwise valid phase.
 * The caller cannot supply an already-prepared capability to bypass this CAS. */
async function consume(db: D1Database, ceremonyID: string, binding: LocalModerationEnrollmentBinding,
  phase: "registration" | "possession") {
  if (!uuidPattern.test(ceremonyID)) throw failure();
  const attemptID = crypto.randomUUID();
  const registration = phase === "registration";
  const prefix = registration ? "c.registration" : "r.possession";
  const result = await db.prepare(`INSERT INTO moderation_operator_enrollment_ceremony_attempts(
    ceremony_id,phase,attempt_id,challenge_id,challenge_sha256)
    SELECT c.ceremony_id,?,?,${prefix}_challenge_id,${prefix}_challenge_sha256
    FROM moderation_operator_enrollment_ceremonies c
    ${registration ? "" : "JOIN moderation_operator_enrollment_ceremony_registrations r ON r.ceremony_id=c.ceremony_id"}
    WHERE c.ceremony_id=? AND ${bindingWhere} AND c.issued_at<=unixepoch() AND c.expires_at>unixepoch()
    RETURNING challenge_id,challenge_sha256`)
    .bind(phase, attemptID, ceremonyID, ...values(binding)).first<{challenge_id:string;challenge_sha256:string}>();
  if (!result) throw failure();
  return { attemptID, challengeID: result.challenge_id, challengeSHA256: result.challenge_sha256 };
}
function snapshotResponse(response: unknown): unknown {
  // Copy synchronously, before the first await/CAS. Uncloneable input is still
  // sent to the consumed-phase verifier as invalid rather than left retryable.
  try { return structuredClone(response); } catch { return null; }
}

export async function verifyLocalModerationEnrollmentRegistration(db: D1Database,
  options: VerifyLocalModerationEnrollmentOptions): Promise<LocalModerationEnrollmentChallenge> {
  try {
    const ceremonyID = options.ceremonyID; const binding = snapshotBinding(options.binding);
    const response = snapshotResponse(options.response);
    const attempt = await consume(db, ceremonyID, binding, "registration");
    const verified = await verifyPreparedModerationOperatorWebAuthnRegistration(
      await prepareModerationOperatorWebAuthnRegistration({response, expectedOrigin: binding.expectedOrigin,
        expectedRPID: binding.expectedRPID, expectedChallengeSHA256: attempt.challengeSHA256}));
    const challenge = await freshChallenge();
    await db.prepare(`INSERT INTO moderation_operator_enrollment_ceremony_registrations(
      ceremony_id,attempt_id,registration_sha256,credential_id_sha256,public_key_cose,public_key_cose_sha256,
      registration_sign_count,authenticator_aaguid_sha256,attestation_policy,attestation_format,self_attestation_verified,
      possession_challenge_id,possession_challenge_sha256) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`)
      .bind(ceremonyID, attempt.attemptID, verified.registrationSHA256, verified.credential.credentialIdSHA256,
        verified.credential.publicKeyCose, verified.publicKeyCoseSHA256, verified.credential.counter,
        verified.authenticatorAAGUIDSHA256, verified.attestationPolicy, verified.attestationFormat,
        Number(verified.selfAttestationSignatureVerified), challenge.challengeID, challenge.challengeSHA256).run();
    const row = await db.prepare(`SELECT issued_at,expires_at FROM moderation_operator_enrollment_ceremonies WHERE ceremony_id=?`)
      .bind(ceremonyID).first<CeremonyRow>();
    if (!row) throw failure();
    return Object.freeze({kind: "unadmitted-local-enrollment-challenge", ...unadmitted, ceremonyID,
      phase: "possession", ...challenge, issuedAt: row.issued_at, expiresAt: row.expires_at});
  } catch { throw failure(); }
}

export async function verifyLocalModerationEnrollmentPossession(db: D1Database,
  options: VerifyLocalModerationEnrollmentOptions): Promise<UnadmittedLocalModerationEnrollment> {
  try {
    const ceremonyID = options.ceremonyID; const binding = snapshotBinding(options.binding);
    const response = snapshotResponse(options.response);
    const attempt = await consume(db, ceremonyID, binding, "possession");
    const row = await db.prepare(`SELECT c.*,r.*,
      MAX(r.registration_sign_count,COALESCE((SELECT sign_count FROM moderation_operator_credential_counters
        WHERE credential_id_sha256=r.credential_id_sha256),0)) AS counter_floor
      FROM moderation_operator_enrollment_ceremonies c JOIN moderation_operator_enrollment_ceremony_registrations r
      ON r.ceremony_id=c.ceremony_id WHERE c.ceremony_id=?`).bind(ceremonyID)
      .first<CeremonyRow & RegistrationRow & {counter_floor: number}>();
    if (!row) throw failure();
    const publicKeyCose = new Uint8Array(row.public_key_cose);
    const verified = await verifyPreparedModerationOperatorWebAuthnAssertion(
      await prepareModerationOperatorWebAuthnAssertion({response, expectedOrigin: binding.expectedOrigin,
        expectedRPID: binding.expectedRPID, expectedChallengeSHA256: attempt.challengeSHA256,
        credential: {credentialIdSHA256: row.credential_id_sha256, publicKeyCose, counter: row.counter_floor}}));
    // The insert trigger rechecks the latest global floor, including a concurrent
    // ceremony or legacy/owner/resolution assertion completed during verification.
    await db.prepare(`INSERT INTO moderation_operator_enrollment_ceremony_possessions(
      ceremony_id,attempt_id,credential_id_sha256,verified_assertion_sha256,authenticator_sign_count) VALUES(?,?,?,?,?)`)
      .bind(ceremonyID, attempt.attemptID, row.credential_id_sha256, verified.assertionSHA256, verified.newCounter).run();
    const registration: UnadmittedModerationOperatorWebAuthnRegistration = Object.freeze({
      kind: "unadmitted-operator-registration", ...unadmitted,
      registrationSHA256: row.registration_sha256,
      credential: Object.freeze({credentialIdSHA256: row.credential_id_sha256, publicKeyCose,
        counter: row.registration_sign_count}), publicKeyCoseSHA256: row.public_key_cose_sha256,
      authenticatorAAGUIDSHA256: row.authenticator_aaguid_sha256,
      attestationPolicy: MODERATION_OPERATOR_REGISTRATION_POLICY, attestationFormat: row.attestation_format,
      selfAttestationSignatureVerified: row.self_attestation_verified === 1,
    });
    return Object.freeze({kind: "unadmitted-local-operator-enrollment", ...unadmitted, ceremonyID, binding,
      issuedAt: row.issued_at, expiresAt: row.expires_at,
      registrationChallengeID: row.registration_challenge_id,
      registrationChallengeSHA256: row.registration_challenge_sha256, registration,
      possession: Object.freeze({challengeID: attempt.challengeID, challengeSHA256: attempt.challengeSHA256,
        assertionSHA256: verified.assertionSHA256, newCounter: verified.newCounter})});
  } catch { throw failure(); }
}
