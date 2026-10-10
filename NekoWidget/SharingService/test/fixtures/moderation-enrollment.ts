import { env } from "cloudflare:workers";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import type { AuthenticatedModerationOperatorAccess } from "../../src/moderation-operator-auth";
import { createLocalModerationEnrollmentCeremony as create, verifyLocalModerationEnrollmentRegistration as register,
  verifyLocalModerationEnrollmentPossession as possess, type LocalModerationEnrollmentBinding } from "../../src/moderation-operator-enrollment-ceremony";
import { hashLocalEnrollmentAuthoritySet, hashLocalEnrollmentInstallationScope } from "../../src/moderation-operator-enrollment-canonical";
export const db = (env as unknown as {DB: D1Database}).DB;
export const origin = "https://moderation.operator.example.test";
export const rpID = "operator.example.test";
const encoder = new TextEncoder();
export const b64 = (value: Uint8Array) => btoa(String.fromCharCode(...value)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; } return result;
}
const hash = async (value: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(value).buffer));
export const hex = async (value: Uint8Array) => [...await hash(value)].map((n) => n.toString(16).padStart(2, "0")).join("");
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
export async function binding(expectedRPID = rpID): Promise<LocalModerationEnrollmentBinding> {
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{now: number}>())!.now;
  return { operatorID: crypto.randomUUID(), expectedOrigin: origin, expectedRPID,
    installationScopeSHA256: "1".repeat(64), authoritySetSHA256: "2".repeat(64),
    access: {operatorSubjectHmac: "3".repeat(64), subjectHmacKeyVersion: 1,
      accessSessionSHA256: "4".repeat(64), keyId: "synthetic-access-key", issuedAt: now - 10, expiresAt: now + 850} };
}
export async function authenticator(expectedRPID = rpID) {
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
    const auth = concat(await hash(encoder.encode(expectedRPID)), new Uint8Array([registration ? 0x45 : 0x05]), u32(counter),
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

/** Synthetic offline-admin preparation is deliberately outside the writer.
 * No live authority, identity or permission is provisioned by this fixture. */
export async function fixture(access?: AuthenticatedModerationOperatorAccess, expectedRPID = rpID) {
  const initial = await binding(expectedRPID);
  const b = {...initial, access: access ?? initial.access};
  const scope = {accountID: "1".repeat(32), databaseID: crypto.randomUUID(), serviceIdentity: "local-admission-test",
    accessIssuer: "https://synthetic-operator.cloudflareaccess.com", accessAudience: "2".repeat(64), expectedOrigin: origin, expectedRPID};
  const pairs = await Promise.all([0, 1].map(async () => await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]) as CryptoKeyPair));
  const keys = await Promise.all(pairs.map(async (pair, index) => {
    const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
    return {keyID: `offline-test-${index}`, revision: 1, publicKeyBase64url: b64(raw), publicKeyFingerprintSHA256: await hex(raw)};
  }));
  for (const k of keys) await db.prepare(`INSERT INTO moderation_operator_enrollment_offline_authorities(
    offline_authority_key_id,authority_policy_revision,authority_public_key_fingerprint_sha256) VALUES(?,?,?)`)
    .bind(k.keyID, k.revision, k.publicKeyFingerprintSHA256).run();
  const authorities = await Promise.all(keys.map(async (key) => ({...key, authorizedAt: (await db.prepare(`
    SELECT authorized_at FROM moderation_operator_enrollment_offline_authorities WHERE offline_authority_key_id=?`)
    .bind(key.keyID).first<{authorized_at:number}>())!.authorized_at})));
  b.installationScopeSHA256 = await hashLocalEnrollmentInstallationScope(scope);
  b.authoritySetSHA256 = await hashLocalEnrollmentAuthoritySet(authorities);
  const activeRoles = ["security_admin", "triage"];
  await db.batch([
    db.prepare("INSERT INTO moderation_operators(operator_id) VALUES(?)").bind(b.operatorID),
    db.prepare("INSERT INTO moderation_operator_subject_identities(operator_id,access_subject_hmac_key_version,access_subject_hmac) VALUES(?,?,?)")
      .bind(b.operatorID, b.access.subjectHmacKeyVersion, b.access.operatorSubjectHmac),
    db.prepare("INSERT INTO moderation_operator_state_events(operator_id,event_type) VALUES(?,'activated')").bind(b.operatorID),
    ...activeRoles.map((role) => db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES(?,?,'granted')").bind(b.operatorID,role)),
  ]);
  const policy = {binding: b, scope, activeRoles, authorities};
  const key = await authenticator(expectedRPID);
  async function completeCeremony(ttlSeconds = 900) {
    const first = await create(db, policy.binding, {ttlSeconds});
    const next = await register(db, {ceremonyID: first.ceremonyID, binding: policy.binding, response: await key.response(first.challenge, true, 7)});
    await possess(db, {ceremonyID: first.ceremonyID, binding: policy.binding, response: await key.response(next.challenge, false, 8)});
    return first;
  }
  return {db, policy, key, pairs, completeCeremony};
}
