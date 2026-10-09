import { base64urlDecode, base64urlEncode, sha256, verifyEd25519 } from "./encoding";
import { encodeCanonicalFields } from "./protocol";
import { MODERATION_OPERATOR_REGISTRATION_POLICY } from "./moderation-operator-webauthn";
import type { UnadmittedLocalModerationEnrollment } from "./moderation-operator-enrollment-ceremony";

/** Local preparation only. No caller of this module obtains an admission or role. */
export const LOCAL_ENROLLMENT_CANONICAL_POLICY_REVISION = 1;
const hashPattern = /^[0-9a-f]{64}$/u;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const roles = new Set(["triage", "evidence_reviewer", "privacy_approver", "auditor", "security_admin"]);
const maxInteger = 2_147_483_647;
const failure = "invalid_local_enrollment_canonical_input";

export interface LocalEnrollmentInstallationScope {
  accountID: string;
  databaseID: string;
  serviceIdentity: string;
  accessIssuer: string;
  accessAudience: string;
  expectedOrigin: string;
  expectedRPID: string;
}

/** Reviewed host policy, never a public key selected by an approval package. */
export interface LocalEnrollmentOfflineAuthority {
  keyID: string;
  revision: number;
  publicKeyBase64url: string;
  publicKeyFingerprintSHA256: string;
  authorizedAt: number;
}

export interface LocalEnrollmentOfflineApproval {
  keyID: string;
  revision: number;
  algorithm: "Ed25519";
  signatureBase64url: string;
}

export interface LocalInitialEnrollmentContext {
  scope: LocalEnrollmentInstallationScope;
  activeRoles: readonly string[];
  /** A successful durable adapter readback, not a serialized browser receipt. */
  enrollment: UnadmittedLocalModerationEnrollment;
  requestID: string;
  /** Actual committed request time; the digest itself deliberately excludes it. */
  requestedAt: number;
  authorities: readonly LocalEnrollmentOfflineAuthority[];
}

export interface CanonicalLocalInitialEnrollmentRequest {
  requestID: string;
  requestedAt: number;
  expiresAt: number;
  installationScopeSHA256: string;
  authoritySetSHA256: string;
  roleSnapshotSHA256: string;
  canonicalRequestSHA256: string;
  /** Immutable exact transcript projection, with no private key or Access JWT. */
  fields: readonly string[];
  enrollmentAdmissionAuthorized: false;
}

function fail(): never { throw new Error(failure); }

// Inspect data properties without evaluating accessors. Copy every nested record and
// byte array synchronously before hashing or signature verification can yield.
function record(value: unknown, keys: readonly string[]): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) fail();
  const descriptors = Object.getOwnPropertyDescriptors(value);
  if (Reflect.ownKeys(value).length !== keys.length || Object.keys(descriptors).some((key) => !keys.includes(key))) fail();
  const output: Record<string, unknown> = {};
  for (const key of keys) {
    const descriptor = descriptors[key];
    if (!descriptor || !("value" in descriptor)) fail();
    output[key] = descriptor.value;
  }
  return output;
}

function string(value: unknown, pattern: RegExp): string {
  if (typeof value !== "string" || !pattern.test(value)) fail();
  return value;
}
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || Object.is(value, -0)
      || value < 0 || value > maximum) fail();
  return value;
}
function positive(value: unknown, maximum = maxInteger): number {
  const result = integer(value, maximum); if (!result) fail(); return result;
}
function list(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) fail();
  // Dense ordinary arrays only, with no accessor/extra/symbol entries.
  if (Object.getPrototypeOf(value) !== Array.prototype
      || Reflect.ownKeys(value).length !== value.length + 1) fail();
  const descriptors = Object.getOwnPropertyDescriptors(value);
  return Array.from({ length: value.length }, (_, index) => {
    const descriptor = descriptors[String(index)];
    if (!descriptor || !("value" in descriptor)) fail(); return descriptor.value;
  });
}
function hash(value: unknown): string { return string(value, hashPattern); }
function uuid(value: unknown): string { return string(value, uuidPattern); }
function binary(value: unknown, length?: number): string {
  if (typeof value !== "string" || value.length > 2048) fail();
  try { base64urlDecode(value, length); } catch { fail(); } return value;
}
async function digest(bytes: Uint8Array): Promise<string> {
  return [...await sha256(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
async function fieldsDigest(fields: readonly string[]): Promise<string> {
  return digest(encodeCanonicalFields(fields));
}

function snapshotScope(value: unknown): LocalEnrollmentInstallationScope {
  const r = record(value, ["accountID", "databaseID", "serviceIdentity", "accessIssuer", "accessAudience", "expectedOrigin", "expectedRPID"]);
  const accountID = string(r.accountID, /^[0-9a-f]{32}$/u);
  const databaseID = string(r.databaseID, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u);
  const serviceIdentity = string(r.serviceIdentity, /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/u);
  const accessIssuer = string(r.accessIssuer, /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/u);
  const accessAudience = hash(r.accessAudience);
  const expectedOrigin = string(r.expectedOrigin, /^https:\/\/[^\s]+$/u);
  const expectedRPID = string(r.expectedRPID, /^[a-z0-9.-]{1,253}$/u);
  let url: URL; try { url = new URL(expectedOrigin); } catch { fail(); }
  if (url.origin !== expectedOrigin || url.hostname !== expectedRPID && !url.hostname.endsWith(`.${expectedRPID}`)
      || expectedRPID.includes("..") || expectedRPID.startsWith(".") || expectedRPID.endsWith(".")) fail();
  return { accountID, databaseID, serviceIdentity, accessIssuer, accessAudience, expectedOrigin, expectedRPID };
}
function scopeFields(scope: LocalEnrollmentInstallationScope): string[] {
  return ["NW.MODERATION-ENROLLMENT.SCOPE.v1", "1", scope.accountID, scope.databaseID,
    scope.serviceIdentity, scope.accessIssuer, scope.accessAudience, scope.expectedOrigin, scope.expectedRPID];
}
export async function hashLocalEnrollmentInstallationScope(value: LocalEnrollmentInstallationScope): Promise<string> {
  return fieldsDigest(scopeFields(snapshotScope(value)));
}

function snapshotAuthorities(value: unknown): LocalEnrollmentOfflineAuthority[] {
  const result = list(value, 2).map((authority) => {
    const r = record(authority, ["keyID", "revision", "publicKeyBase64url", "publicKeyFingerprintSHA256", "authorizedAt"]);
    return {
      keyID: string(r.keyID, /^[A-Za-z0-9._-]{8,64}$/u), revision: positive(r.revision),
      publicKeyBase64url: binary(r.publicKeyBase64url, 32), publicKeyFingerprintSHA256: hash(r.publicKeyFingerprintSHA256),
      authorizedAt: integer(r.authorizedAt),
    };
  }).sort((a, b) => a.keyID < b.keyID ? -1 : a.keyID > b.keyID ? 1 : 0);
  if (result.length !== 2 || new Set(result.map((a) => a.keyID)).size !== 2
      || new Set(result.map((a) => a.publicKeyBase64url)).size !== 2
      || new Set(result.map((a) => a.publicKeyFingerprintSHA256)).size !== 2) fail();
  return result;
}
async function authoritySetDigest(authorities: readonly LocalEnrollmentOfflineAuthority[]): Promise<string> {
  for (const a of authorities) {
    if (await digest(base64urlDecode(a.publicKeyBase64url, 32)) !== a.publicKeyFingerprintSHA256) fail();
  }
  return fieldsDigest(["NW.MODERATION-ENROLLMENT.AUTHORITY-SET.v1", "1", "2",
    ...authorities.flatMap((a) => [a.keyID, String(a.revision), a.publicKeyFingerprintSHA256, String(a.authorizedAt)])]);
}
/** Persist this exact digest in the ceremony BEFORE exposing its challenge. */
export async function hashLocalEnrollmentAuthoritySet(authorities: readonly LocalEnrollmentOfflineAuthority[]): Promise<string> {
  return authoritySetDigest(snapshotAuthorities(authorities));
}

function snapshotContext(value: unknown) {
  const r = record(value, ["scope", "activeRoles", "enrollment", "requestID", "requestedAt", "authorities"]);
  const scope = snapshotScope(r.scope);
  const authorities = snapshotAuthorities(r.authorities);
  const activeRoles = list(r.activeRoles, 5).map((role) => {
    if (typeof role !== "string" || !roles.has(role)) fail(); return role;
  }).sort();
  if (new Set(activeRoles).size !== activeRoles.length || !activeRoles.includes("security_admin")) fail();
  const e = record(r.enrollment, ["kind", "ceremonyID", "binding", "issuedAt", "expiresAt", "registrationChallengeID",
    "registrationChallengeSHA256", "registration", "possession", "enrollmentAdmissionAuthorized", "hardwareProvenanceVerified", "realHumanVerified"]);
  if (e.kind !== "unadmitted-local-operator-enrollment" || e.enrollmentAdmissionAuthorized !== false
      || e.hardwareProvenanceVerified !== false || e.realHumanVerified !== false) fail();
  const b = record(e.binding, ["operatorID", "access", "installationScopeSHA256", "authoritySetSHA256", "expectedOrigin", "expectedRPID"]);
  const a = record(b.access, ["operatorSubjectHmac", "subjectHmacKeyVersion", "accessSessionSHA256", "keyId", "issuedAt", "expiresAt"]);
  const registration = record(e.registration, ["kind", "registrationSHA256", "credential", "publicKeyCoseSHA256",
    "authenticatorAAGUIDSHA256", "attestationPolicy", "attestationFormat", "selfAttestationSignatureVerified",
    "hardwareProvenanceVerified", "realHumanVerified", "enrollmentAdmissionAuthorized"]);
  if (registration.kind !== "unadmitted-operator-registration" || registration.attestationPolicy !== MODERATION_OPERATOR_REGISTRATION_POLICY
      || registration.hardwareProvenanceVerified !== false || registration.realHumanVerified !== false
      || registration.enrollmentAdmissionAuthorized !== false
      || !["none", "packed"].includes(registration.attestationFormat as string)
      || registration.selfAttestationSignatureVerified !== (registration.attestationFormat === "packed")) fail();
  const c = record(registration.credential, ["credentialIdSHA256", "publicKeyCose", "counter"]);
  if (!(c.publicKeyCose instanceof Uint8Array) || c.publicKeyCose.length < 1 || c.publicKeyCose.length > 1024) fail();
  const publicKeyCose = new Uint8Array(c.publicKeyCose);
  const p = record(e.possession, ["newCounter", "assertionSHA256", "challengeID", "challengeSHA256"]);
  const originalCounter = integer(c.counter, 0xffffffff); const newCounter = integer(p.newCounter, 0xffffffff);
  if (originalCounter !== 0 || newCounter !== 0) { if (newCounter <= originalCounter) fail(); }
  const issuedAt = integer(e.issuedAt); const expiresAt = integer(e.expiresAt);
  const accessIssuedAt = integer(a.issuedAt); const accessExpiresAt = integer(a.expiresAt);
  const requestedAt = integer(r.requestedAt);
  if (issuedAt < accessIssuedAt || expiresAt <= issuedAt || expiresAt > issuedAt + 900
      || expiresAt >= accessExpiresAt || requestedAt < issuedAt || requestedAt >= expiresAt
      || b.expectedOrigin !== scope.expectedOrigin || b.expectedRPID !== scope.expectedRPID) fail();
  string(a.keyId, /^[A-Za-z0-9._-]{1,128}$/u);
  return { scope, authorities, activeRoles, requestID: uuid(r.requestID), requestedAt, issuedAt, expiresAt,
    ceremonyID: uuid(e.ceremonyID), scopeSHA256: hash(b.installationScopeSHA256), authoritySHA256: hash(b.authoritySetSHA256),
    operatorID: uuid(b.operatorID), subjectVersion: positive(a.subjectHmacKeyVersion), subjectHmac: hash(a.operatorSubjectHmac),
    accessSessionSHA256: hash(a.accessSessionSHA256), accessIssuedAt, accessExpiresAt,
    credentialSHA256: hash(c.credentialIdSHA256), publicKeyCose, publicKeyCoseSHA256: hash(registration.publicKeyCoseSHA256),
    originalCounter, registrationSHA256: hash(registration.registrationSHA256), aaguidSHA256: hash(registration.authenticatorAAGUIDSHA256),
    registrationChallengeID: uuid(e.registrationChallengeID), registrationChallengeSHA256: hash(e.registrationChallengeSHA256),
    newCounter, assertionSHA256: hash(p.assertionSHA256), possessionChallengeID: uuid(p.challengeID), possessionChallengeSHA256: hash(p.challengeSHA256) };
}
type Snapshot = ReturnType<typeof snapshotContext>;

async function canonicalize(snapshot: Snapshot): Promise<CanonicalLocalInitialEnrollmentRequest> {
  const scopeSHA256 = await fieldsDigest(scopeFields(snapshot.scope));
  const authoritySetSHA256 = await authoritySetDigest(snapshot.authorities);
  if (scopeSHA256 !== snapshot.scopeSHA256 || authoritySetSHA256 !== snapshot.authoritySHA256
      || await digest(snapshot.publicKeyCose) !== snapshot.publicKeyCoseSHA256
      || snapshot.authorities.some((a) => a.authorizedAt > snapshot.requestedAt)) fail();
  const roleSnapshotSHA256 = await fieldsDigest(["NW.MODERATION-ENROLLMENT.ROLES.v1", "1",
    String(snapshot.activeRoles.length), ...snapshot.activeRoles]);
  const fields = Object.freeze(["NW.MODERATION-ENROLLMENT.REQUEST.v1", "1", scopeSHA256, snapshot.requestID,
    "initial_bootstrap", snapshot.operatorID, String(snapshot.subjectVersion), snapshot.subjectHmac, roleSnapshotSHA256,
    snapshot.credentialSHA256, snapshot.publicKeyCoseSHA256, base64urlEncode(snapshot.publicKeyCose), String(snapshot.originalCounter),
    snapshot.registrationSHA256, String(LOCAL_ENROLLMENT_CANONICAL_POLICY_REVISION), MODERATION_OPERATOR_REGISTRATION_POLICY,
    snapshot.aaguidSHA256, snapshot.registrationChallengeID, snapshot.registrationChallengeSHA256,
    snapshot.accessSessionSHA256, String(snapshot.accessIssuedAt), String(snapshot.accessExpiresAt), String(snapshot.expiresAt), "", "",
    snapshot.ceremonyID, snapshot.possessionChallengeID, snapshot.possessionChallengeSHA256, snapshot.assertionSHA256,
    String(snapshot.newCounter), authoritySetSHA256]);
  return Object.freeze({ requestID: snapshot.requestID, requestedAt: snapshot.requestedAt, expiresAt: snapshot.expiresAt,
    installationScopeSHA256: scopeSHA256, authoritySetSHA256, roleSnapshotSHA256, canonicalRequestSHA256: await fieldsDigest(fields),
    fields, enrollmentAdmissionAuthorized: false });
}

export async function canonicalizeLocalInitialEnrollment(context: LocalInitialEnrollmentContext): Promise<CanonicalLocalInitialEnrollmentRequest> {
  return canonicalize(snapshotContext(context));
}

function approvalFields(request: CanonicalLocalInitialEnrollmentRequest, authority: LocalEnrollmentOfflineAuthority): string[] {
  return ["NW.MODERATION-ENROLLMENT.OFFLINE-APPROVAL.v1", "1", "Ed25519", request.installationScopeSHA256,
    authority.keyID, String(authority.revision), authority.publicKeyFingerprintSHA256, request.requestID,
    request.canonicalRequestSHA256, String(request.requestedAt), String(request.expiresAt), "approve-initial-bootstrap"];
}
/** Exportable signer transcript; does not establish request admission. */
export async function localInitialEnrollmentApprovalTranscript(context: LocalInitialEnrollmentContext, authorityKeyID: string): Promise<Uint8Array> {
  const snapshot = snapshotContext(context);
  const authority = snapshot.authorities.find((a) => a.keyID === authorityKeyID); if (!authority) fail();
  return encodeCanonicalFields(approvalFields(await canonicalize(snapshot), authority));
}

export async function verifyLocalInitialEnrollmentOfflineApprovals(context: LocalInitialEnrollmentContext,
  approvalsValue: readonly LocalEnrollmentOfflineApproval[], nowValue: number) {
  const snapshot = snapshotContext(context);
  const now = integer(nowValue);
  const approvals = list(approvalsValue, 2).map((value) => {
    const r = record(value, ["keyID", "revision", "algorithm", "signatureBase64url"]);
    if (r.algorithm !== "Ed25519") fail();
    return { keyID: string(r.keyID, /^[A-Za-z0-9._-]{8,64}$/u), revision: positive(r.revision), signatureBase64url: binary(r.signatureBase64url, 64) };
  });
  if (approvals.length !== 2 || new Set(approvals.map((a) => a.keyID)).size !== 2
      || now < snapshot.requestedAt || now >= snapshot.expiresAt) fail();
  const request = await canonicalize(snapshot);
  const verified = [];
  for (const authority of snapshot.authorities) {
    const approval = approvals.find((a) => a.keyID === authority.keyID);
    if (!approval || approval.revision !== authority.revision) fail();
    let valid = false;
    try { valid = await verifyEd25519(authority.publicKeyBase64url, approval.signatureBase64url, encodeCanonicalFields(approvalFields(request, authority))); }
    catch { fail(); }
    if (!valid) fail();
    verified.push(Object.freeze({ keyID: authority.keyID, revision: authority.revision,
      publicKeyFingerprintSHA256: authority.publicKeyFingerprintSHA256,
      signatureSHA256: await digest(base64urlDecode(approval.signatureBase64url, 64)) }));
  }
  return Object.freeze({ kind: "unadmitted-local-offline-approval-verification" as const,
    request, verifiedApprovals: Object.freeze(verified), enrollmentAdmissionAuthorized: false as const,
    needsFinalDBRecheck: true as const, hardwareProvenanceVerified: false as const, realHumanVerified: false as const });
}
