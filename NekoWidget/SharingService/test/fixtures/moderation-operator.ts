import { env } from "cloudflare:workers";
import { base64urlEncode } from "../../src/encoding";
import { ModerationAccessJwksCache, verifyCloudflareAccessJWT, type CloudflareAccessAuthenticationOptions } from "../../src/moderation-operator-auth";
import { deriveModerationOperatorCaseReference } from "../../src/moderation-operator-case-reference";
import type { LocalModerationTriageEnvironment } from "../../src/moderation-operator-triage-local";
const db = (env as unknown as { DB: D1Database }).DB;
export const origin = "https://moderation.operator.example.test";
const rpId = "moderation.operator.example.test";
const issuer = "https://neko-operator.cloudflareaccess.com";
const audience = "b".repeat(64);
const kid = "a".repeat(64);
export const encoder = new TextEncoder();
async function hash(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer));
}
export async function hex(bytes: Uint8Array): Promise<string> {
  return [...await hash(bytes)].map((value) => value.toString(16).padStart(2, "0")).join("");
}
function concat(...chunks: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(chunks.reduce((sum, value) => sum + value.length, 0));
  let offset = 0;
  for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.length; }
  return output;
}
function der(raw: Uint8Array): Uint8Array {
  function integer(bytes: Uint8Array): Uint8Array {
    let offset = 0;
    while (offset < bytes.length - 1 && bytes[offset] === 0) offset += 1;
    const value = bytes.slice(offset);
    const positive = value[0]! < 128 ? value : concat(new Uint8Array([0]), value);
    return concat(new Uint8Array([2, positive.length]), positive);
  }
  const value = concat(integer(raw.slice(0, 32)), integer(raw.slice(32)));
  return concat(new Uint8Array([0x30, value.length]), value);
}

export interface Fixture {
  local: LocalModerationTriageEnvironment;
  token: string;
  operatorId: string;
  credentialDigest: string;
  caseReference: string;
  reportId: string;
  operationPath: string;
  sessionToken(lifetimeSeconds: number): Promise<string>;
  assertion(challenge: string, options?: { invalidSignature?: boolean; challengeOverride?: string; counter?: number }): Promise<string>;
  request(path: string, method?: string, body?: string, headers?: Record<string, string>): Request;
}

export async function fixture(): Promise<Fixture> {
  const accessKey = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", accessKey.publicKey);
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{ now: number }>())!.now;
  const header = base64urlEncode(encoder.encode(JSON.stringify({ alg: "RS256", kid, typ: "JWT" })));
  const subject = crypto.randomUUID();
  const claims = base64urlEncode(encoder.encode(JSON.stringify({ aud: [audience], iss: issuer,
    sub: subject, type: "app", iat: now, nbf: now, exp: now + 600 })));
  const jwtInput = `${header}.${claims}`;
  const token = `${jwtInput}.${base64urlEncode(new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", accessKey.privateKey, encoder.encode(jwtInput))))}`;
  const accessOptions: CloudflareAccessAuthenticationOptions = { issuer, audience,
    subjectHmacKey: crypto.getRandomValues(new Uint8Array(32)), subjectHmacKeyVersion: 1,
    cache: new ModerationAccessJwksCache(),
    fetchImpl: async () => new Response(JSON.stringify({ keys: [{ kid, kty: "RSA", alg: "RS256", use: "sig", n: jwk.n, e: jwk.e }] }),
      { headers: { "Content-Type": "application/json" } }),
  };
  const access = await verifyCloudflareAccessJWT(token, accessOptions);
  const webAuthnKey = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const rawPublic = new Uint8Array(await crypto.subtle.exportKey("raw", webAuthnKey.publicKey));
  const publicCose = concat(new Uint8Array([0xa5, 1, 2, 3, 0x26, 0x20, 1, 0x21, 0x58, 0x20]),
    rawPublic.slice(1, 33), new Uint8Array([0x22, 0x58, 0x20]), rawPublic.slice(33));
  const credentialId = crypto.getRandomValues(new Uint8Array(32));
  const credentialDigest = await hex(credentialId);
  const operatorId = crypto.randomUUID();
  const enrollmentId = crypto.randomUUID();
  const admissionId = crypto.randomUUID();
  const fixedDigest = "c".repeat(64);
  await db.batch([
    db.prepare("INSERT INTO moderation_operators(operator_id) VALUES (?)").bind(operatorId),
    db.prepare(`INSERT INTO moderation_operator_subject_identities(operator_id, access_subject_hmac_key_version, access_subject_hmac)
      VALUES (?, 1, ?)`).bind(operatorId, access.operatorSubjectHmac),
    db.prepare("INSERT INTO moderation_operator_state_events(operator_id, event_type) VALUES (?, 'activated')").bind(operatorId),
    ...["triage", "security_admin"].map((role) => db.prepare(`INSERT INTO moderation_operator_role_events(operator_id, role_code, event_type)
      VALUES (?, ?, 'granted')`).bind(operatorId, role)),
    db.prepare(`INSERT INTO moderation_operator_credentials(credential_id_sha256, operator_id, public_key_cose, registration_sign_count)
      VALUES (?, ?, ?, 0)`).bind(credentialDigest, operatorId, publicCose),
    db.prepare("INSERT INTO moderation_operator_credential_events(credential_id_sha256, event_type) VALUES (?, 'registered')").bind(credentialDigest),
    db.prepare(`INSERT INTO moderation_operator_enrollment_requests(enrollment_request_id, enrollment_kind, request_schema_version,
      canonical_request_sha256, target_operator_id, target_access_subject_hmac_key_version, target_access_subject_hmac,
      target_credential_id_sha256, target_public_key_cose_sha256, target_public_key_cose_snapshot,
      target_registration_sign_count, attestation_evidence_sha256, attestation_policy_revision,
      authenticator_aaguid_sha256, expires_at)
      VALUES (?, 'initial_bootstrap', 1, ?, ?, 1, ?, ?, ?, ?, 0, ?, 1, ?, unixepoch() + 900)`)
      .bind(enrollmentId, fixedDigest, operatorId, access.operatorSubjectHmac, credentialDigest, await hex(publicCose), publicCose, fixedDigest, fixedDigest),
    ...["LOCAL_OFFLINE_A", "LOCAL_OFFLINE_B"].flatMap((key, index) => [
      db.prepare(`INSERT INTO moderation_operator_enrollment_offline_authorities(offline_authority_key_id,
        authority_policy_revision, authority_public_key_fingerprint_sha256) VALUES (?, 1, ?)`)
        .bind(key, String(index + 1).repeat(64)),
      db.prepare(`INSERT INTO moderation_operator_enrollment_offline_approvals(enrollment_request_id, offline_authority_key_id,
        authority_policy_revision, authority_public_key_fingerprint_sha256, authority_signature_sha256) VALUES (?, ?, 1, ?, ?)`)
        .bind(enrollmentId, key, String(index + 1).repeat(64), String(index + 3).repeat(64)),
    ]),
    db.prepare(`INSERT INTO moderation_operator_enrollment_admissions(enrollment_admission_id, enrollment_request_id, admission_provenance_sha256)
      VALUES (?, ?, ?)`).bind(admissionId, enrollmentId, fixedDigest),
  ]);
  // These fixture admissions model previously reviewed enrollment. The route
  // does not enroll operators or assert that the synthetic admission signatures
  // prove a real attestation/bootstrap ceremony.
  const reportId = base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
  const caseReference = (await deriveModerationOperatorCaseReference(
    { reportId, caseReferenceHmacKeyVersion: 1 }, crypto.getRandomValues(new Uint8Array(32)),
  )).caseReferenceHmac;
  const lineage = crypto.randomUUID();
  const id = () => base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
  const sha = () => base64urlEncode(crypto.getRandomValues(new Uint8Array(32)));
  const owner=id(),receiver=id(),ownerDevice=id(),receiverDevice=id(),moment=id();
  await db.batch([
    db.prepare("INSERT INTO moment_space_lineages(id, created_at) VALUES (?, unixepoch())").bind(lineage),
    db.prepare("INSERT INTO moment_spaces(space_id,lineage_id,state,created_at,updated_at) VALUES (?,?,'active',?,?)").bind(lineage,lineage,now,now),
    ...[owner,receiver].map((p,i)=>db.prepare("INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES (?, ?, ?, 'active',?,?)").bind(p,lineage,i===0?'owner':'member',now,now)),
    ...[[owner,ownerDevice],[receiver,receiverDevice]].map(([p,d])=>db.prepare("INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at) VALUES (?,?,?,?,'active',?,?)").bind(d!,p!,sha(),sha(),now,now)),
    db.prepare(`INSERT INTO moments(id,client_moment_id,space_id,sender_participant_id,sender_device_id,kind,key_epoch,state,
      object_key,ciphertext_size,ciphertext_sha256,client_moderation_version,sender_policy_version,sender_policy_accepted_at,
      quota_day_key,quota_counted,reservation_attempt,reserve_request_hash,created_at,upload_expires_at,uploaded_at,committed_at,unreceived_expires_at)
      VALUES (?,?,?,?,?,'live',1,'committed',?,32,?,1,1,?,1,0,1,?,?,?, ?,?,?)`)
      .bind(moment,crypto.randomUUID(),lineage,owner,ownerDevice,`moments/${moment}`,sha(),now,sha(),now,now+3600,now,now,now+604800),
    db.prepare("INSERT INTO moment_deliveries(moment_id,recipient_participant_id,state,created_at,access_expires_at) VALUES (?,?,'pending',?,?)").bind(moment,receiver,now,now+604800),
    db.prepare(`INSERT INTO moment_reports(id,moment_id,space_id,lineage_id,reporter_participant_id,reporter_device_id,
      accused_participant_id,reason_code,moderation_key_id,state,object_key,ciphertext_size,ciphertext_sha256,
      reporter_consent_version,reporter_consented_at,quota_day_key,reserve_request_hash,dedupe_key,created_at,upload_expires_at)
      VALUES (?,?,?,?,?,?,?,'privacy','moderation-v1','reserved',?,32,?,1,?,1,?,?,?,?)`)
      .bind(reportId,moment,lineage,lineage,receiver,receiverDevice,owner,`reports/${reportId}`,sha(),now,sha(),sha(),now,now+3600),
    db.prepare("UPDATE moment_reports SET state='uploaded',uploaded_at=? WHERE id=?").bind(now,reportId),
    db.prepare("INSERT INTO moment_report_commit_events(id,report_id,reporter_participant_id,committed_at,content_expires_at) VALUES (?,?,?,?,?)")
      .bind(crypto.randomUUID(),reportId,receiver,now,now+604800),
    db.prepare(`INSERT INTO moderation_operator_versioned_case_references(report_id, case_reference_hmac,
      case_reference_hmac_key_version, derivation_protocol_version, derivation_domain)
      VALUES (?, ?, 1, 1, 'NW.MODERATION-OPERATOR.CASE-REFERENCE')`).bind(reportId, caseReference),
  ]);
  const local: LocalModerationTriageEnvironment = { runtimeEnabled: "YES", environment: "local", db,
    origin, rpId, access: accessOptions };
  return {
    local, token, operatorId, credentialDigest, reportId, caseReference,
    operationPath: `/operator/v1/cases/${caseReference}/review-start`,
    async sessionToken(lifetimeSeconds) {
      const current = (await db.prepare("SELECT unixepoch() AS now").first<{ now: number }>())!.now;
      const payload = base64urlEncode(encoder.encode(JSON.stringify({ aud: [audience], iss: issuer,
        sub: subject, type: "app", iat: current, nbf: current, exp: current + lifetimeSeconds,
        identity_nonce: crypto.randomUUID() })));
      const input = `${header}.${payload}`;
      return `${input}.${base64urlEncode(new Uint8Array(await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5", accessKey.privateKey, encoder.encode(input))))}`;
    },
    request(path, method = "GET", body, extraHeaders = {}) {
      return new Request(`${origin}${path}`, { method,
        headers: { Origin: origin, "Cf-Access-Jwt-Assertion": token,
          ...(body === undefined ? {} : { "Content-Type": "application/json" }), ...extraHeaders },
        ...(body === undefined ? {} : { body }) });
    },
    async assertion(challenge, options = {}) {
      const client = encoder.encode(JSON.stringify({ type: "webauthn.get", origin,
        challenge: options.challengeOverride ?? challenge, crossOrigin: false }));
      const counter = new Uint8Array(4);
      new DataView(counter.buffer).setUint32(0, options.counter ?? 1, false);
      const authenticator = concat(await hash(encoder.encode(rpId)), new Uint8Array([5]), counter);
      const signingBytes = concat(authenticator, await hash(client));
      const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" },
        webAuthnKey.privateKey, new Uint8Array(signingBytes).buffer));
      if (options.invalidSignature) signature[0] = signature[0]! ^ 1;
      return JSON.stringify({ id: base64urlEncode(credentialId), rawId: base64urlEncode(credentialId),
        type: "public-key", clientExtensionResults: {}, authenticatorAttachment: "cross-platform",
        response: { clientDataJSON: base64urlEncode(client), authenticatorData: base64urlEncode(authenticator), signature: base64urlEncode(der(signature)) } });
    },
  };
}
