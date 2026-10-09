import { describe, expect, it } from "vitest";
import { base64urlEncode } from "../src/encoding";
import { MODERATION_OPERATOR_REGISTRATION_POLICY } from "../src/moderation-operator-webauthn";
import { canonicalizeLocalInitialEnrollment, hashLocalEnrollmentAuthoritySet, hashLocalEnrollmentInstallationScope,
  localInitialEnrollmentApprovalTranscript, verifyLocalInitialEnrollmentOfflineApprovals,
  type LocalInitialEnrollmentContext, type LocalEnrollmentOfflineApproval,
  type LocalEnrollmentOfflineAuthority } from "../src/moderation-operator-enrollment-canonical";

// Contract fixtures stand in for a trusted durable readback. Registration and
// actual possession cryptography are covered by the separate D1 ceremony tests.
const encoder = new TextEncoder();
type Mutable<T> = T extends Uint8Array ? T : T extends readonly (infer U)[] ? Mutable<U>[]
  : T extends object ? { -readonly [K in keyof T]: Mutable<T[K]> } : T;
function bytes(hex: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(hex.match(/../gu)!, (value) => parseInt(value, 16));
}
async function h(value: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(value).buffer))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
// Independent signer serialization: does not call production protocol helpers.
function c(fields: readonly string[]): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(fields.flatMap((field) => {
    const value = [...encoder.encode(field)]; return [value.length >>> 8, value.length & 255, ...value];
  }));
}
const fixedKeys = [
  ["9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"],
  ["4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"],
] as const;
const cose = bytes("a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5");

async function fixture() {
  const privateKeys = await Promise.all(fixedKeys.map(([seed]) => crypto.subtle.importKey("pkcs8",
    bytes(`302e020100300506032b657004220420${seed}`).buffer, { name: "Ed25519" }, false, ["sign"])));
  const authorities: LocalEnrollmentOfflineAuthority[] = await Promise.all(fixedKeys.map(async ([, pub], index) => ({
    keyID: `offline-${index + 1}`, revision: 1, publicKeyBase64url: base64urlEncode(bytes(pub)),
    publicKeyFingerprintSHA256: await h(bytes(pub)), authorizedAt: 900,
  })));
  const scope = { accountID: "1".repeat(32), databaseID: "11111111-2222-4333-8444-555555555555",
    serviceIdentity: "local-operator-test", accessIssuer: "https://operator-test.cloudflareaccess.com",
    accessAudience: "2".repeat(64), expectedOrigin: "https://moderation.operator.example.test", expectedRPID: "operator.example.test" };
  const context: LocalInitialEnrollmentContext = { scope, activeRoles: ["triage", "security_admin"],
    requestID: "11111111-1111-4111-8111-111111111111", requestedAt: 1100, authorities,
    enrollment: { kind: "unadmitted-local-operator-enrollment", ceremonyID: "22222222-2222-4222-8222-222222222222",
      issuedAt: 1000, expiresAt: 1700, registrationChallengeID: "33333333-3333-4333-8333-333333333333",
      registrationChallengeSHA256: "3".repeat(64), enrollmentAdmissionAuthorized: false,
      hardwareProvenanceVerified: false, realHumanVerified: false,
      binding: { operatorID: "44444444-4444-4444-8444-444444444444",
        installationScopeSHA256: await hashLocalEnrollmentInstallationScope(scope), authoritySetSHA256: await hashLocalEnrollmentAuthoritySet(authorities),
        expectedOrigin: scope.expectedOrigin, expectedRPID: scope.expectedRPID,
        access: { operatorSubjectHmac: "4".repeat(64), subjectHmacKeyVersion: 1, accessSessionSHA256: "5".repeat(64),
          keyId: "synthetic-jwt-key", issuedAt: 950, expiresAt: 1800 } },
      registration: { kind: "unadmitted-operator-registration", credential: { credentialIdSHA256: "6".repeat(64), publicKeyCose: new Uint8Array(cose), counter: 7 },
        registrationSHA256: "7".repeat(64), publicKeyCoseSHA256: await h(cose), authenticatorAAGUIDSHA256: "8".repeat(64),
        attestationPolicy: MODERATION_OPERATOR_REGISTRATION_POLICY, attestationFormat: "none", selfAttestationSignatureVerified: false,
        hardwareProvenanceVerified: false, realHumanVerified: false, enrollmentAdmissionAuthorized: false },
      possession: { challengeID: "55555555-5555-4555-8555-555555555555", challengeSHA256: "9".repeat(64), assertionSHA256: "a".repeat(64), newCounter: 8 } },
  };
  async function sign(contextValue = context, independent = false): Promise<LocalEnrollmentOfflineApproval[]> {
    const request = await canonicalizeLocalInitialEnrollment(contextValue);
    return Promise.all(contextValue.authorities.map(async (authority, index) => {
      const message = independent ? c(["NW.MODERATION-ENROLLMENT.OFFLINE-APPROVAL.v1", "1", "Ed25519", request.installationScopeSHA256,
        authority.keyID, String(authority.revision), authority.publicKeyFingerprintSHA256, request.requestID,
        request.canonicalRequestSHA256, String(request.requestedAt), String(request.expiresAt), "approve-initial-bootstrap"])
        : await localInitialEnrollmentApprovalTranscript(contextValue, authority.keyID);
      return { keyID: authority.keyID, revision: authority.revision, algorithm: "Ed25519" as const,
        signatureBase64url: base64urlEncode(new Uint8Array(await crypto.subtle.sign("Ed25519", privateKeys[index]!, new Uint8Array(message).buffer))) };
    }));
  }
  return { context, sign, privateKeys };
}

describe("local initial enrollment canonical contract", () => {
  it("verifies two actual Ed25519 signatures from an independent signer without authorizing admission", async () => {
    const { context, sign } = await fixture(); const approvals = await sign(context, true);
    const result = await verifyLocalInitialEnrollmentOfflineApprovals(context, approvals.reverse(), 1200);
    expect(result.verifiedApprovals.map((a) => a.keyID)).toEqual(["offline-1", "offline-2"]);
    expect(result).toMatchObject({ enrollmentAdmissionAuthorized: false, needsFinalDBRecheck: true,
      hardwareProvenanceVerified: false, realHumanVerified: false });
    expect(Object.isFrozen(result.verifiedApprovals)).toBe(true);
  });
  it("pins exact field order, byte encoding, domain and fixed request digest", async () => {
    const { context } = await fixture(); const request = await canonicalizeLocalInitialEnrollment(context);
    const e = context.enrollment; const a = e.binding.access; const r = e.registration;
    const scopeHash = await h(c(["NW.MODERATION-ENROLLMENT.SCOPE.v1", "1", context.scope.accountID, context.scope.databaseID,
      context.scope.serviceIdentity, context.scope.accessIssuer, context.scope.accessAudience, context.scope.expectedOrigin, context.scope.expectedRPID]));
    const roleHash = await h(c(["NW.MODERATION-ENROLLMENT.ROLES.v1", "1", "2", "security_admin", "triage"]));
    const authorityHash = await h(c(["NW.MODERATION-ENROLLMENT.AUTHORITY-SET.v1", "1", "2",
      ...context.authorities.flatMap((authority) => [authority.keyID, "1", authority.publicKeyFingerprintSHA256, "900"])]));
    const expected = ["NW.MODERATION-ENROLLMENT.REQUEST.v1", "1", scopeHash, context.requestID, "initial_bootstrap", e.binding.operatorID,
      "1", a.operatorSubjectHmac, roleHash, r.credential.credentialIdSHA256, r.publicKeyCoseSHA256, base64urlEncode(cose), "7",
      r.registrationSHA256, "1", MODERATION_OPERATOR_REGISTRATION_POLICY, r.authenticatorAAGUIDSHA256,
      e.registrationChallengeID, e.registrationChallengeSHA256, a.accessSessionSHA256, "950", "1800", "1700", "", "",
      e.ceremonyID, e.possession.challengeID, e.possession.challengeSHA256, e.possession.assertionSHA256, "8", authorityHash];
    expect(request.fields).toEqual(expected);
    expect(request.canonicalRequestSHA256).toBe(await h(c(expected)));
    expect([...c(["猫", "", "1"])]).toEqual([0, 3, 0xe7, 0x8c, 0xab, 0, 0, 0, 1, 49]);
    expect(request.canonicalRequestSHA256).toMatch(/^[a-f0-9]{64}$/u);
  });
  it("excludes DB requestedAt from request hash but binds the actual committed time in both signatures", async () => {
    const { context, sign } = await fixture(); const approvals = await sign();
    const changed = { ...context, requestedAt: 1101 };
    expect((await canonicalizeLocalInitialEnrollment(changed)).canonicalRequestSHA256)
      .toBe((await canonicalizeLocalInitialEnrollment(context)).canonicalRequestSHA256);
    await expect(verifyLocalInitialEnrollmentOfflineApprovals(changed, approvals, 1200)).rejects.toThrow();
  });
  it.each(["one", "duplicate", "bad-signature", "algorithm", "padding", "extra", "revision"])("rejects invalid approval: %s", async (kind) => {
    const { context, sign } = await fixture(); let approvals: unknown[] = await sign();
    if (kind === "one") approvals.pop();
    if (kind === "duplicate") approvals[1] = approvals[0];
    if (kind === "bad-signature") approvals[0] = { ...(approvals[0] as object), signatureBase64url: base64urlEncode(new Uint8Array(64)) };
    if (kind === "algorithm") approvals[0] = { ...(approvals[0] as object), algorithm: "ES256" };
    if (kind === "padding") approvals[0] = { ...(approvals[0] as LocalEnrollmentOfflineApproval), signatureBase64url: (approvals[0] as LocalEnrollmentOfflineApproval).signatureBase64url + "=" };
    if (kind === "extra") approvals[0] = { ...(approvals[0] as object), publicKeyBase64url: context.authorities[0]!.publicKeyBase64url };
    if (kind === "revision") approvals[0] = { ...(approvals[0] as object), revision: 2 };
    await expect(verifyLocalInitialEnrollmentOfflineApprovals(context, approvals as LocalEnrollmentOfflineApproval[], 1200)).rejects.toThrow();
  });
  it.each(["scope", "roles", "credential", "possession", "session", "request-id"])("rejects altered signed context: %s", async (kind) => {
    const { context, sign } = await fixture(); const approvals = await sign();
    const changed = structuredClone(context) as Mutable<LocalInitialEnrollmentContext>;
    if (kind === "scope") { changed.scope.serviceIdentity = "another-service"; changed.enrollment.binding.installationScopeSHA256 = await hashLocalEnrollmentInstallationScope(changed.scope); }
    if (kind === "roles") changed.activeRoles = ["security_admin"];
    if (kind === "credential") changed.enrollment.registration.credential.credentialIdSHA256 = "b".repeat(64);
    if (kind === "possession") changed.enrollment.possession.assertionSHA256 = "b".repeat(64);
    if (kind === "session") changed.enrollment.binding.access.accessSessionSHA256 = "b".repeat(64);
    if (kind === "request-id") changed.requestID = "66666666-6666-4666-8666-666666666666";
    await expect(verifyLocalInitialEnrollmentOfflineApprovals(changed, approvals, 1200)).rejects.toThrow();
  });
  it("rejects authority changes in the same DB second and duplicate raw keys", async () => {
    const { context, sign } = await fixture(); const approvals = await sign();
    context.authorities = context.authorities.map((a) => ({ ...a, revision: 2, authorizedAt: context.requestedAt }));
    await expect(verifyLocalInitialEnrollmentOfflineApprovals(context, approvals, 1200)).rejects.toThrow();
    await expect(hashLocalEnrollmentAuthoritySet([{ ...context.authorities[0]! }, { ...context.authorities[0]!, keyID: "offline-3" }])).rejects.toThrow();
  });
  it.each([1099, 1700, 1701])("rejects a request outside its verified time window: %s", async (now) => {
    const { context, sign } = await fixture(); await expect(verifyLocalInitialEnrollmentOfflineApprovals(context, await sign(), now)).rejects.toThrow();
  });
  it("rejects a COSE digest mismatch, unknown policy, duplicate roles and extra receipt properties", async () => {
    const { context } = await fixture(); const changed = structuredClone(context);
    changed.enrollment.registration.credential.publicKeyCose[0] = changed.enrollment.registration.credential.publicKeyCose[0]! ^ 1;
    await expect(canonicalizeLocalInitialEnrollment(changed)).rejects.toThrow();
    await expect(canonicalizeLocalInitialEnrollment({ ...context, activeRoles: ["security_admin", "security_admin"] })).rejects.toThrow();
    const extra = { ...context, enrollment: { ...context.enrollment, approved: true } };
    await expect(canonicalizeLocalInitialEnrollment(extra)).rejects.toThrow();
    const unknownPolicy = structuredClone(context) as unknown as { enrollment: { registration: { attestationPolicy: string } } };
    unknownPolicy.enrollment.registration.attestationPolicy = "unknown";
    await expect(canonicalizeLocalInitialEnrollment(unknownPolicy as LocalInitialEnrollmentContext)).rejects.toThrow();
  });
  it("copies mutable COSE, roles, authority and signature inputs before the first await", async () => {
    const { context, sign } = await fixture(); const approvals = await sign();
    const pending = verifyLocalInitialEnrollmentOfflineApprovals(context, approvals, 1200);
    context.enrollment.registration.credential.publicKeyCose.fill(0);
    context.activeRoles = [];
    context.scope.serviceIdentity = "mutated-after-yield";
    context.authorities[0]!.revision = 3;
    approvals[0]!.signatureBase64url = base64urlEncode(new Uint8Array(64));
    await expect(pending).resolves.toMatchObject({ enrollmentAdmissionAuthorized: false, needsFinalDBRecheck: true });
    await expect(verifyLocalInitialEnrollmentOfflineApprovals(context, approvals, 1200)).rejects.toThrow();
  });
  it("rejects accessor and symbolic fields without invoking a getter", async () => {
    const { context } = await fixture(); let invoked = false;
    const accessor = { ...context }; Object.defineProperty(accessor, "requestedAt", { enumerable: true, get() { invoked = true; return 1100; } });
    await expect(canonicalizeLocalInitialEnrollment(accessor)).rejects.toThrow(); expect(invoked).toBe(false);
    await expect(canonicalizeLocalInitialEnrollment({ ...context, [Symbol("extra")]: 1 })).rejects.toThrow();
  });
});
