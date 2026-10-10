import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import {
  createLocalModerationEnrollmentCeremony as create,
  verifyLocalModerationEnrollmentRegistration as register,
  verifyLocalModerationEnrollmentPossession as possess,
  type LocalModerationEnrollmentBinding,
} from "../src/moderation-operator-enrollment-ceremony";
import { prepareModerationOperatorWebAuthnAssertion, verifyPreparedModerationOperatorWebAuthnAssertion } from "../src/moderation-operator-webauthn";
import { canonicalizeLocalInitialEnrollment, hashLocalEnrollmentAuthoritySet, hashLocalEnrollmentInstallationScope,
  localInitialEnrollmentApprovalTranscript, verifyLocalInitialEnrollmentOfflineApprovals,
  type LocalEnrollmentOfflineApproval } from "../src/moderation-operator-enrollment-canonical";

const db = (env as unknown as {DB: D1Database}).DB;
const migrations = (env as unknown as {TEST_MIGRATIONS: D1Migration[]}).TEST_MIGRATIONS;
const origin = "https://moderation.operator.example.test";
const rpID = "operator.example.test";
const encoder = new TextEncoder();
const C = "moderation_operator_enrollment_ceremonies";
const A = "moderation_operator_enrollment_ceremony_attempts";
const R = "moderation_operator_enrollment_ceremony_registrations";
const P = "moderation_operator_enrollment_ceremony_possessions";
const b64 = (value: Uint8Array) => btoa(String.fromCharCode(...value)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; } return result;
}
const hash = async (value: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(value).buffer));
const hex = async (value: Uint8Array) => [...await hash(value)].map((n) => n.toString(16).padStart(2, "0")).join("");
function u32(value: number) { const data = new Uint8Array(4); new DataView(data.buffer).setUint32(0, value); return data; }
function der(raw: Uint8Array) {
  function integer(input: Uint8Array) {
    let i = 0; while (i < input.length - 1 && input[i] === 0) i++;
    let bytes = input.slice(i); if (bytes[0]! & 128) bytes = concat(new Uint8Array([0]), bytes);
    return concat(new Uint8Array([2, bytes.length]), bytes);
  }
  const r = integer(raw.slice(0, 32)); const s = integer(raw.slice(32));
  return concat(new Uint8Array([0x30, r.length + s.length]), r, s);
}
async function binding(): Promise<LocalModerationEnrollmentBinding> {
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{now: number}>())!.now;
  return { operatorID: crypto.randomUUID(), expectedOrigin: origin, expectedRPID: rpID,
    installationScopeSHA256: "1".repeat(64), authoritySetSHA256: "2".repeat(64),
    access: {operatorSubjectHmac: "3".repeat(64), subjectHmacKeyVersion: 1,
      accessSessionSHA256: "4".repeat(64), keyId: "synthetic-access-key", issuedAt: now - 10, expiresAt: now + 1800} };
}
async function authenticator() {
  const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, true, ["sign", "verify"]) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const publicKeyCose = isoCBOR.encode(new Map<number, Parameters<typeof isoCBOR.encode>[0]>([
    [1, 2], [3, -7], [-1, 1], [-2, raw.slice(1, 33)], [-3, raw.slice(33)],
  ]));
  const id = crypto.getRandomValues(new Uint8Array(32));
  const sign = async (value: Uint8Array) => der(new Uint8Array(await crypto.subtle.sign(
    {name: "ECDSA", hash: "SHA-256"}, pair.privateKey, new Uint8Array(value).buffer)));
  async function response(challenge: string, registration: boolean, counter: number, bad = false, format = "packed") {
    const client = encoder.encode(JSON.stringify({type: registration ? "webauthn.create" : "webauthn.get", challenge, origin}));
    const auth = concat(await hash(encoder.encode(rpID)), new Uint8Array([registration ? 0x45 : 0x05]), u32(counter),
      ...(registration ? [new Uint8Array(16), new Uint8Array([0, id.length]), id, publicKeyCose] : []));
    const sig = await sign(concat(auth, await hash(client))); if (bad) sig[sig.length - 1]! ^= 1;
    const common = {id: b64(id), rawId: b64(id), type: "public-key", clientExtensionResults: {}};
    if (!registration) return {...common, response: {clientDataJSON: b64(client), authenticatorData: b64(auth), signature: b64(sig)}};
    const stmt = format === "none" ? new Map<string, Parameters<typeof isoCBOR.encode>[0]>()
      : new Map<string, Parameters<typeof isoCBOR.encode>[0]>([["alg", -7], ["sig", sig]]);
    return {...common, response: {clientDataJSON: b64(client), attestationObject: b64(isoCBOR.encode(
      new Map<string, Parameters<typeof isoCBOR.encode>[0]>([["fmt", format], ["authData", auth], ["attStmt", stmt]]))), transports: ["usb"]}};
  }
  return {id, publicKeyCose, response};
}
const rejected = async (promise: Promise<unknown>) => expect(promise).rejects.toThrow("local_moderation_enrollment_unavailable");
const count = async (table: string) => (await db.prepare(`SELECT count(*) AS n FROM ${table}`).first<{n:number}>())!.n;
async function registered(input?: LocalModerationEnrollmentBinding, auth?: Awaited<ReturnType<typeof authenticator>>, counter = 7) {
  const b = input ?? await binding(); const key = auth ?? await authenticator(); const first = await create(db, b);
  const next = await register(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(first.challenge, true, counter)});
  return {b, key, first, next};
}

describe("local durable unadmitted operator ceremony", () => {
  beforeEach(async () => { await reset(); await applyD1Migrations(db, migrations);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network forbidden")); });
  afterEach(() => { expect(fetch).not.toHaveBeenCalled(); vi.restoreAllMocks(); });

  it("completes real registration and same-key possession without an operator, grant or admission", async () => {
    const {b, key, first, next} = await registered();
    const result = await possess(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(next.challenge, false, 8)});
    expect(result).toMatchObject({kind: "unadmitted-local-operator-enrollment", ceremonyID: first.ceremonyID,
      binding: b, registrationChallengeID: first.challengeID, registrationChallengeSHA256: first.challengeSHA256,
      enrollmentAdmissionAuthorized: false, realHumanVerified: false, hardwareProvenanceVerified: false,
      registration: {credential: {counter: 7}}, possession: {newCounter: 8, challengeID: next.challengeID, challengeSHA256: next.challengeSHA256}});
    expect(result.possession.assertionSHA256).toMatch(/^[a-f0-9]{64}$/u);
    expect(Object.isFrozen(result)).toBe(true); expect(Object.isFrozen(result.binding.access)).toBe(true);
    for (const table of ["moderation_operators", "moderation_operator_credentials", "moderation_operator_enrollment_admissions", "moderation_operator_role_events"])
      expect(await count(table)).toBe(0);
    expect(await count(A)).toBe(2); expect(await count(P)).toBe(1);
    const columns = (await db.prepare(`PRAGMA table_info(${C})`).all<{name:string}>()).results.map((r) => r.name);
    expect(columns).not.toContain("challenge"); expect(columns).not.toContain("subject");
    const dump = JSON.stringify((await db.prepare(`SELECT * FROM ${C}`).all()).results);
    expect(dump).not.toContain(first.challenge); expect(dump).not.toContain(b64(key.id));
    const stored = await db.prepare(`SELECT registration_sign_count FROM ${R}`).first();
    expect(stored).toEqual({registration_sign_count: 7});
    // This is the actual shared floor query used by the existing actor reader.
    const floor = await db.prepare("SELECT sign_count FROM moderation_operator_credential_counters WHERE credential_id_sha256=?")
      .bind(result.registration.credential.credentialIdSHA256).first<{sign_count:number}>();
    expect(floor!.sign_count).toBe(8);
    for (const counter of [7, 8, 9]) {
      const challenge = crypto.getRandomValues(new Uint8Array(32));
      const prepared = await prepareModerationOperatorWebAuthnAssertion({expectedOrigin: origin, expectedRPID: rpID,
        expectedChallengeSHA256: await hex(challenge), credential: {...result.registration.credential, counter: floor!.sign_count},
        response: await key.response(b64(challenge), false, counter)});
      if (counter <= 8) await expect(verifyPreparedModerationOperatorWebAuthnAssertion(prepared)).rejects.toThrow();
      else expect((await verifyPreparedModerationOperatorWebAuthnAssertion(prepared)).newCounter).toBe(9);
    }
  });

  it("connects actual WebAuthn/D1 receipts to two real offline signatures and still grants no admission", async () => {
    const initial = await binding();
    const scope = {accountID: "1".repeat(32), databaseID: crypto.randomUUID(), serviceIdentity: "local-ceremony-test",
      accessIssuer: "https://synthetic-operator.cloudflareaccess.com", accessAudience: "2".repeat(64), expectedOrigin: origin, expectedRPID: rpID};
    const pairs = await Promise.all([0, 1].map(async () => await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]) as CryptoKeyPair));
    const authorities = await Promise.all(pairs.map(async (pair, index) => {
      const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
      return {keyID: `offline-test-${index}`, revision: 1, publicKeyBase64url: b64(raw),
        publicKeyFingerprintSHA256: await hex(raw), authorizedAt: initial.access.issuedAt};
    }));
    const b = {...initial, installationScopeSHA256: await hashLocalEnrollmentInstallationScope(scope),
      authoritySetSHA256: await hashLocalEnrollmentAuthoritySet(authorities)};
    const {key, first, next} = await registered(b);
    const enrollment = await possess(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(next.challenge, false, 8)});
    const now = (await db.prepare("SELECT unixepoch() AS now").first<{now: number}>())!.now;
    // This is preparation only: no request/admission/role writer is connected.
    const context = {scope, activeRoles: ["triage", "security_admin"], enrollment, requestID: crypto.randomUUID(), requestedAt: now, authorities};
    const canonical = await canonicalizeLocalInitialEnrollment(context);
    expect(canonical.authoritySetSHA256).toBe(b.authoritySetSHA256);
    const approvals: LocalEnrollmentOfflineApproval[] = await Promise.all(authorities.map(async (authority, index) => ({
      keyID: authority.keyID, revision: authority.revision, algorithm: "Ed25519" as const,
      signatureBase64url: b64(new Uint8Array(await crypto.subtle.sign("Ed25519", pairs[index]!.privateKey,
        new Uint8Array(await localInitialEnrollmentApprovalTranscript(context, authority.keyID)).buffer))),
    })));
    const verified = await verifyLocalInitialEnrollmentOfflineApprovals(context, approvals, now);
    expect(verified).toMatchObject({enrollmentAdmissionAuthorized: false, needsFinalDBRecheck: true,
      hardwareProvenanceVerified: false, realHumanVerified: false});
    expect(verified.verifiedApprovals).toHaveLength(2);
    expect(verified.request.canonicalRequestSHA256).toBe(canonical.canonicalRequestSHA256);
    for (const table of ["moderation_operator_enrollment_requests", "moderation_operator_enrollment_admissions", "moderation_operator_role_events"])
      expect(await count(table)).toBe(0);
  });

  it.each(["registration", "possession"] as const)("commits %s consumption before an invalid signature and denies reprepare/retry", async (phase) => {
    const b = await binding(); const key = await authenticator(); const first = await create(db, b);
    const next = phase === "registration" ? first : await register(db, {ceremonyID: first.ceremonyID, binding: b,
      response: await key.response(first.challenge, true, 7)});
    const verify = phase === "registration" ? register : possess;
    await rejected(verify(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(next.challenge, phase === "registration", 8, true)}));
    await rejected(verify(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(next.challenge, phase === "registration", 8)}));
    expect(await count(A)).toBe(phase === "registration" ? 1 : 2); expect(await count(P)).toBe(0);
    expect(await count("moderation_operator_credential_counters")).toBe(0);
  });

  it.each(["registration", "possession"] as const)("permits only one concurrent %s attempt", async (phase) => {
    const b = await binding(); const key = await authenticator(); const first = await create(db, b);
    const next = phase === "registration" ? first : await register(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(first.challenge, true, 7)});
    const response = await key.response(next.challenge, phase === "registration", 8);
    const verify = phase === "registration" ? register : possess;
    const outcomes = await Promise.allSettled([verify(db, {ceremonyID: first.ceremonyID, binding: b, response}), verify(db, {ceremonyID: first.ceremonyID, binding: b, response})]);
    expect(outcomes.map((r) => r.status).sort()).toEqual(["fulfilled", "rejected"]);
    await rejected(verify(db, {ceremonyID: first.ceremonyID, binding: b, response}));
  });

  it.each(["registration", "possession"] as const)("binds every identity/session/scope/authority/origin/RP field before %s", async (phase) => {
    const b = await binding(); const key = await authenticator(); const first = await create(db, b);
    const next = phase === "registration" ? first : await register(db, {ceremonyID: first.ceremonyID, binding: b,
      response: await key.response(first.challenge, true, 7)});
    const verify = phase === "registration" ? register : possess;
    const alterations: LocalModerationEnrollmentBinding[] = [
      {...b, operatorID: crypto.randomUUID()}, {...b, installationScopeSHA256: "5".repeat(64)}, {...b, authoritySetSHA256: "6".repeat(64)},
      {...b, expectedOrigin: "https://another.operator.example.test"}, {...b, expectedRPID: "example.test"},
      ...[{operatorSubjectHmac: "7".repeat(64)}, {subjectHmacKeyVersion: 2}, {accessSessionSHA256: "8".repeat(64)},
        {keyId: "other-key"}, {issuedAt: b.access.issuedAt - 1}, {expiresAt: b.access.expiresAt + 1}].map((change) => ({...b, access: {...b.access, ...change}})),
    ];
    for (const wrong of alterations) await rejected(verify(db, {ceremonyID: first.ceremonyID, binding: wrong, response: await key.response(next.challenge, phase === "registration", 8)}));
    expect(await count(A)).toBe(phase === "registration" ? 0 : 1);
    await verify(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(next.challenge, phase === "registration", 8)});
  });

  it("uses database time, caps at 900 seconds, strictly precedes Access expiry and refuses equal expiry", async () => {
    const b = await binding(); const first = await create(db, b);
    expect(first.expiresAt - first.issuedAt).toBe(900);
    const short = {...b, access: {...b.access, expiresAt: first.issuedAt + 20}};
    expect((await create(db, short)).expiresAt).toBe(short.access.expiresAt - 1);
    await rejected(create(db, b, {ttlSeconds: 901}));
    await rejected(create(db, {...b, access: {...b.access, expiresAt: first.issuedAt}}));
    const expiring = await create(db, b, {ttlSeconds: 1}); const key = await authenticator();
    await new Promise((resolve) => setTimeout(resolve, Math.max(0, expiring.expiresAt * 1000 - Date.now()) + 20));
    const now = (await db.prepare("SELECT unixepoch() AS now").first<{now:number}>())!.now;
    expect(now).toBeGreaterThanOrEqual(expiring.expiresAt);
    await rejected(register(db, {ceremonyID: expiring.ceremonyID, binding: b, response: await key.response(expiring.challenge, true, 7)}));
    expect(await count(A)).toBe(0);
  });

  it("a rolled-back result cannot roll back the prior durable CAS or permit a restarted caller", async () => {
    const b = await binding(); const key = await authenticator(); const first = await create(db, b);
    await db.exec(`CREATE TRIGGER test_fail_result BEFORE INSERT ON ${R} BEGIN SELECT RAISE(ABORT,'synthetic result rollback'); END`);
    const response = await key.response(first.challenge, true, 7);
    await rejected(register(db, {ceremonyID: first.ceremonyID, binding: b, response}));
    expect(await count(A)).toBe(1); expect(await count(R)).toBe(0);
    await db.exec("DROP TRIGGER test_fail_result");
    // New API call has no in-memory prepared token from the first attempt.
    await rejected(register(db, {ceremonyID: first.ceremonyID, binding: structuredClone(b), response: structuredClone(response)}));
  });

  it("keeps failed possession consumed after result rollback and contributes no counter floor", async () => {
    const {b, key, first, next} = await registered();
    await db.exec(`CREATE TRIGGER test_fail_possession BEFORE INSERT ON ${P} BEGIN SELECT RAISE(ABORT,'synthetic result rollback'); END`);
    const response = await key.response(next.challenge, false, 8);
    await rejected(possess(db, {ceremonyID: first.ceremonyID, binding: b, response}));
    expect(await count(A)).toBe(2); expect(await count(P)).toBe(0);
    expect(await count("moderation_operator_credential_counters")).toBe(0);
    await db.exec("DROP TRIGGER test_fail_possession");
    await rejected(possess(db, {ceremonyID: first.ceremonyID, binding: b, response}));
  });

  it("requires registration before possession, and checks the current floor again inside the result transaction", async () => {
    const b = await binding(); const key = await authenticator(); const first = await create(db, b);
    await rejected(possess(db, {ceremonyID: first.ceremonyID, binding: b, response: {}}));
    expect(await count(A)).toBe(0);
    const one = await registered(b, key); const two = await registered(b, key);
    await possess(db, {ceremonyID: one.first.ceremonyID, binding: b, response: await key.response(one.next.challenge, false, 10)});
    // Simulate a verifier that read a lower floor before a concurrent success.
    // This direct SQL attempt is synthetic; it tests the final DB guard, not a signature.
    const attemptID = crypto.randomUUID();
    await db.prepare(`INSERT INTO ${A}(ceremony_id,phase,attempt_id,challenge_id,challenge_sha256) VALUES(?,'possession',?,?,?)`)
      .bind(two.first.ceremonyID, attemptID, two.next.challengeID, two.next.challengeSHA256).run();
    for (const counter of [0, 8, 10]) {
      await expect(db.prepare(`INSERT INTO ${P}(ceremony_id,attempt_id,credential_id_sha256,verified_assertion_sha256,authenticator_sign_count) VALUES(?,?,?,?,?)`)
        .bind(two.first.ceremonyID, attemptID, await hex(key.id), "a".repeat(64), counter).run()).rejects.toThrow();
    }
    expect(await count(P)).toBe(1);
  });

  it("snapshots caller inputs before CAS awaits and cannot use a different possession key", async () => {
    const b = await binding(); const key = await authenticator(); const first = await create(db, b);
    const response = await key.response(first.challenge, true, 7);
    const mutable = structuredClone(b);
    const pending = register(db, {ceremonyID: first.ceremonyID, binding: mutable, response});
    response.rawId = "changed"; (mutable as {authoritySetSHA256:string}).authoritySetSHA256 = "9".repeat(64);
    const next = await pending; const otherKey = await authenticator();
    await rejected(possess(db, {ceremonyID: first.ceremonyID, binding: b, response: await otherKey.response(next.challenge, false, 8)}));
    expect(await count(P)).toBe(0);
  });

  it("keeps evidence immutable including INSERT OR REPLACE and rechecks the latest counter floor", async () => {
    const b = await binding(); const key = await authenticator();
    const one = await registered(b, key); const two = await registered(b, key);
    await possess(db, {ceremonyID: one.first.ceremonyID, binding: b, response: await key.response(one.next.challenge, false, 8)});
    await rejected(possess(db, {ceremonyID: two.first.ceremonyID, binding: b, response: await key.response(two.next.challenge, false, 8)}));
    for (const table of [C, A, R, P]) {
      await expect(db.prepare(`UPDATE ${table} SET ceremony_id=ceremony_id`).run()).rejects.toThrow();
      await expect(db.prepare(`DELETE FROM ${table}`).run()).rejects.toThrow();
      await expect(db.prepare(`INSERT OR REPLACE INTO ${table} SELECT * FROM ${table} LIMIT 1`).run()).rejects.toThrow();
    }
    expect(await count(P)).toBe(1);
  });

  it("preserves explicit zero-counter compatibility without granting authority", async () => {
    const {b, key, first, next} = await registered(undefined, undefined, 0);
    const result = await possess(db, {ceremonyID: first.ceremonyID, binding: b, response: await key.response(next.challenge, false, 0)});
    expect(result.possession.newCounter).toBe(0); expect(result.enrollmentAdmissionAuthorized).toBe(false);
  });
});
