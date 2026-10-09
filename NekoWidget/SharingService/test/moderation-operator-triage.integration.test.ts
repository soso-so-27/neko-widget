import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { base64urlEncode } from "../src/encoding";
import { ModerationAccessJwksCache, verifyCloudflareAccessJWT, type CloudflareAccessAuthenticationOptions } from "../src/moderation-operator-auth";
import { deriveModerationOperatorCaseReference } from "../src/moderation-operator-case-reference";
import { routeLocalModerationOperatorTriage, type LocalModerationTriageEnvironment } from "../src/moderation-operator-triage-local";
import { runDurableModerationAdvisory } from "../src/moderation-ai-durable";
import { routeModerationOperatorRequest } from "../src/moderation-operator-worker";

const db = (env as unknown as { DB: D1Database }).DB;
beforeEach(async () => {
  await reset();
  await applyD1Migrations(db, (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS);
});
const origin = "https://moderation.operator.example.test";
const rpId = "moderation.operator.example.test";
const issuer = "https://neko-operator.cloudflareaccess.com";
const audience = "b".repeat(64);
const kid = "a".repeat(64);
const encoder = new TextEncoder();
async function hash(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer));
}
async function hex(bytes: Uint8Array): Promise<string> {
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

interface Fixture {
  local: LocalModerationTriageEnvironment;
  token: string;
  operatorId: string;
  credentialDigest: string;
  caseReference: string;
  reportId: string;
  operationPath: string;
  sessionToken(lifetimeSeconds: number): Promise<string>;
  assertion(challenge: string, options?: { invalidSignature?: boolean; challengeOverride?: string }): Promise<string>;
  request(path: string, method?: string, body?: string, headers?: Record<string, string>): Request;
}

async function fixture(): Promise<Fixture> {
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
      const counter = new Uint8Array([0, 0, 0, 1]);
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

async function begin(test: Fixture): Promise<{ challenge: string; challengeId: string; assertionPath: string }> {
  const result = await routeLocalModerationOperatorTriage(test.request(test.operationPath, "POST"), test.local);
  expect(result.status).toBe(202);
  return result.json();
}
async function count(table: string): Promise<number> {
  return (await db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).first<{ count: number }>())!.count;
}
function withBatchHook(test: Fixture, hook: (ordinal: number, statements: D1PreparedStatement[]) => Promise<D1PreparedStatement[]>): LocalModerationTriageEnvironment {
  let ordinal = 0;
  const guardedDb = new Proxy(db, {
    get(target, property) {
      if (property === "batch") return async (statements: D1PreparedStatement[]) => {
        ordinal += 1;
        return target.batch(await hook(ordinal, statements));
      };
      const value = Reflect.get(target, property, target) as unknown;
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return { ...test.local, db: guardedDb };
}

describe("local authenticated moderation triage", () => {
  it("provides a data-free CSP console only locally; production never exposes it", async () => {
    const test = await fixture();
    const response = await routeLocalModerationOperatorTriage(new Request(origin+'/operator/console'), test.local);
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain('通報の確認');
    for (const secret of [test.token,test.reportId,test.caseReference,test.credentialDigest]) expect(html).not.toContain(secret);
    const nonce = /script nonce="([a-f0-9]{32})"/.exec(html)![1];
    expect(response.headers.get('Content-Security-Policy')).toContain(`script-src 'nonce-${nonce}'`);
    expect(response.headers.get('Content-Security-Policy')).toContain("connect-src 'self'");
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(await count('moderation_operator_access_audit_starts')).toBe(0);
    expect((await routeLocalModerationOperatorTriage(new Request(origin+'/operator/console'), {...test.local,environment:'production'})).status).toBe(503);
    expect(routeModerationOperatorRequest(new Request(origin+'/operator/console'), {OPERATOR_RUNTIME_ENABLED:'YES'}).status).toBe(404);
  });

  it("uses authenticated audited POST read without weakening the GET Origin boundary", async () => {
    const test = await fixture();
    const response = await routeLocalModerationOperatorTriage(test.request('/operator/v1/cases/read','POST'),test.local);
    expect(response.status).toBe(200);
    const value = await response.json();
    expect(value).toMatchObject({cases:[{caseReferenceHmac:test.caseReference,evidenceAvailable:1,advisoryReason:'not_requested',advisoryPriority:'preserve'}]});
    expect(JSON.stringify(value)).not.toContain(test.reportId);
    const readAudit=await db.prepare("SELECT request_sha256 FROM moderation_operator_access_audit_starts").first<{request_sha256:string}>();
    expect(readAudit!.request_sha256).toBe(await hex(encoder.encode(JSON.stringify(['NW.MODERATION-OPERATOR.TRIAGE-REQUEST.v1','POST','/operator/v1/cases/read']))));
    for(const [path,method,body,headers] of [
      ['/operator/v1/cases/read','POST',undefined,{Origin:'https://foreign.invalid'}],
      ['/operator/v1/cases/read','POST','{}',{}],
      ['/operator/v1/cases/read?x=1','POST',undefined,{}],
      ['/operator/v1/cases','GET',undefined,{Origin:''}],
      ['/operator/v1/cases/read','POST',undefined,{'Cf-Access-Jwt-Assertion':''}],
    ] as const)expect((await routeLocalModerationOperatorTriage(test.request(path,method,body,headers),test.local)).status).toBeGreaterThanOrEqual(400);
    expect(await count('moderation_operator_access_audit_starts')).toBe(1);
    await db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES (?,'triage','revoked')").bind(test.operatorId).run();
    expect((await routeLocalModerationOperatorTriage(test.request('/operator/v1/cases/read','POST'),test.local)).status).toBe(403);
  });

  it("shows only current AI metadata and retains expired cases without stale hints", async () => {
    const test=await fixture();
    const ref={caseReferenceHmac:test.caseReference,caseReferenceHmacKeyVersion:1};
    await runDurableModerationAdvisory(db,ref,{safetyRoute:'child_safety_hold'},{apiKey:'unused-local'});
    const read=async()=> (await routeLocalModerationOperatorTriage(test.request('/operator/v1/cases/read','POST'),test.local)).json();
    expect(await read()).toMatchObject({cases:[{evidenceAvailable:1,advisoryReason:'child_safety_hold',advisoryPriority:'raise'}]});
    await runDurableModerationAdvisory(db,ref,{safetyRoute:'unreviewed'},{apiKey:'unused-local'});
    expect(await read()).toMatchObject({cases:[{advisoryReason:'safety_route_unreviewed',advisoryPriority:'preserve'}]});
    await db.prepare("UPDATE moment_reports SET state='expired',closed_at=unixepoch() WHERE id=?").bind(test.reportId).run();
    expect(await read()).toMatchObject({cases:[{evidenceAvailable:0,advisoryReason:'not_requested',reviewState:'unreviewed'}]});
    expect(await count('moderation_operator_challenges')).toBe(0);
    expect(await count('moderation_case_events')).toBe(0);
  });

  it("pages beyond twenty cases without skipping equal deadlines or admitting a foreign origin", async () => {
    const test=await fixture();
    for(let index=0;index<21;index++) {
      const report=base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
      const reference=(await deriveModerationOperatorCaseReference({reportId:report,caseReferenceHmacKeyVersion:1},new Uint8Array(32).fill(9))).caseReferenceHmac;
      await db.batch([
        db.prepare(`INSERT INTO moment_report_tombstones(report_id,lineage_id,dedupe_key,moderation_key_id,reason_code,committed_at,content_expires_at)
          SELECT ?,lineage_id,?,'moderation-v1','privacy',committed_at,content_expires_at FROM moment_report_tombstones WHERE report_id=?`)
          .bind(report,crypto.randomUUID(),test.reportId),
        db.prepare(`INSERT INTO moderation_operator_versioned_case_references(report_id,case_reference_hmac,case_reference_hmac_key_version,derivation_protocol_version,derivation_domain)
          VALUES (?,?,1,1,'NW.MODERATION-OPERATOR.CASE-REFERENCE')`).bind(report,reference),
      ]);
    }
    const first=await (await routeLocalModerationOperatorTriage(test.request('/operator/v1/cases/read','POST'),test.local))
      .json<{cases:{reviewDueAt:number;caseReferenceHmac:string}[];hasMore:boolean}>();
    expect(first.cases).toHaveLength(20);expect(first.hasMore).toBe(true);
    const cursor=first.cases.at(-1)!;const path=`/operator/v1/cases/read/${cursor.reviewDueAt}/${cursor.caseReferenceHmac}`;
    const second=await (await routeLocalModerationOperatorTriage(test.request(path,'POST'),test.local))
      .json<{cases:{caseReferenceHmac:string}[];hasMore:boolean}>();
    expect(second.cases).toHaveLength(2);expect(second.hasMore).toBe(false);
    const expected=await db.prepare('SELECT case_reference_hmac FROM moderation_operator_versioned_case_references ORDER BY case_reference_hmac').all<{case_reference_hmac:string}>();
    expect([...first.cases,...second.cases].map(x=>x.caseReferenceHmac)).toEqual(expected.results.map(x=>x.case_reference_hmac));
    expect((await routeLocalModerationOperatorTriage(test.request(path,'POST',undefined,{Origin:'https://foreign.invalid'}),test.local)).status).toBe(403);
    expect((await routeLocalModerationOperatorTriage(test.request('/operator/v1/cases/read/9999999999/'+test.caseReference,'POST'),test.local)).status).toBe(404);
  });

  it("runs a real Access/WebAuthn/D1 review start without granting export or decision", async () => {
    const test = await fixture();
    const queue = await routeLocalModerationOperatorTriage(test.request("/operator/v1/cases"), test.local);
    expect(queue.status).toBe(200);
    expect(await queue.json()).toMatchObject({ cases: [{ caseReferenceHmac: test.caseReference, reviewState: "unreviewed" }] });
    const challenge = await begin(test);
    expect(await count("moderation_case_events")).toBe(0);
    const result = await routeLocalModerationOperatorTriage(
      test.request(challenge.assertionPath, "POST", await test.assertion(challenge.challenge)), test.local);
    expect(await result.clone().text()).not.toContain(test.reportId);
    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ caseReferenceHmac: test.caseReference, reviewState: "in_review" });
    expect(await count("moderation_operator_assertion_attempts")).toBe(1);
    expect(await count("moderation_operator_challenge_consumptions")).toBe(1);
    expect(await count("moderation_operator_actions")).toBe(1);
    expect(await count("moderation_evidence_ledger_events")).toBe(1);
    expect(await count("moderation_evidence_event_finalizations")).toBe(1);
    expect(await count("moderation_case_events")).toBe(1);
    expect(await count("moderation_operator_access_audit_starts")).toBe(4);
    expect(await count("moderation_operator_access_audit_finishes")).toBe(4);
    for (const path of ["/operator/v1/evidence/export", "/operator/v1/review-decision", "/operator/v1/content-delete"]) {
      expect((await routeLocalModerationOperatorTriage(test.request(path, "POST"), test.local)).status).toBe(404);
    }
  });

  it("records a bad signature attempt permanently and refuses reuse", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const failed = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST",
      await test.assertion(challenge.challenge, { invalidSignature: true })), test.local);
    expect(failed.status).toBe(400);
    expect(await count("moderation_operator_assertion_attempts")).toBe(1);
    const replay = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST",
      await test.assertion(challenge.challenge)), test.local);
    expect(replay.status).toBe(409);
    expect(await count("moderation_operator_challenge_consumptions")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
  });

  it("keeps OFF and nonlocal configurations inert before reading protected inputs", async () => {
    for (const [runtimeEnabled, environment] of [["NO", "local"], ["YES", "production"], ["yes", "local"]]) {
      const local = new Proxy({ runtimeEnabled, environment }, {
        get(target, property) {
          if (property === "runtimeEnabled" || property === "environment") return target[property];
          throw new Error("protected binding must not be read");
        },
      }) as LocalModerationTriageEnvironment;
      const request = new Proxy({} as Request, { get() { throw new Error("request must not be read"); } });
      expect((await routeLocalModerationOperatorTriage(request, local)).status).toBe(503);
    }
    expect(await count("moderation_operator_access_sessions")).toBe(0);
  });

  it("exposes bounded HMAC metadata and explicitly counts unbound cases", async () => {
    const test = await fixture();
    const unboundReport = base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
    await db.prepare(`INSERT INTO moment_report_tombstones(report_id, lineage_id, dedupe_key, moderation_key_id,
      reason_code, committed_at, content_expires_at) SELECT ?, lineage_id, ?, 'moderation-v1', 'privacy',
      unixepoch(), unixepoch() + 604800 FROM moment_report_tombstones WHERE report_id = ?`)
      .bind(unboundReport, crypto.randomUUID(), test.reportId).run();
    const result = await routeLocalModerationOperatorTriage(test.request("/operator/v1/cases"), test.local);
    const text = await result.clone().text();
    for (const secret of [test.reportId, unboundReport, test.token, test.operatorId, test.credentialDigest]) expect(text).not.toContain(secret);
    const due = await db.prepare('SELECT review_due_at FROM moderation_cases WHERE report_id=?')
      .bind(test.reportId).first<{review_due_at:number}>();
    expect(await result.json()).toEqual({ cases: [{ caseReferenceHmac: test.caseReference,
      reviewDueAt: due!.review_due_at, evidenceAvailable: 1, advisoryReason: 'not_requested', advisoryPriority: 'preserve',
      reviewState: "unreviewed", slaExceeded: 0, pendingFinalization: 0 }], hasMore: false, unboundCases: 1 });
    expect(await count("moderation_case_events")).toBe(0);
  });

  it("rejects wrong auth, origin, query and operation body before admitting a session", async () => {
    const test = await fixture();
    const requests = [
      [test.request("/operator/v1/cases", "GET", undefined, { "Cf-Access-Jwt-Assertion": "spoofed" }), 401],
      [test.request("/operator/v1/cases", "GET", undefined, { Origin: "https://other.example.test" }), 403],
      [test.request("/operator/v1/cases?scope=all"), 403],
      [test.request(test.operationPath, "POST", "{}"), 400],
    ] as const;
    for (const [request, status] of requests) expect((await routeLocalModerationOperatorTriage(request, test.local)).status).toBe(status);
    expect(await count("moderation_operator_access_sessions")).toBe(0);
    expect(await count("moderation_operator_challenges")).toBe(0);
    expect(await count("moderation_operator_access_audit_starts")).toBe(0);
  });

  it("binds the assertion to its exact case, frozen operation and server challenge", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const assertion = await test.assertion(challenge.challenge);
    const wrongCase = challenge.assertionPath.replace(test.caseReference, "d".repeat(64));
    expect((await routeLocalModerationOperatorTriage(test.request(wrongCase, "POST", assertion), test.local)).status).toBe(409);
    expect((await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST",
      await test.assertion(challenge.challenge, { challengeOverride: base64urlEncode(new Uint8Array(32)) })), test.local)).status).toBe(400);
    expect(await count("moderation_operator_assertion_attempts")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
    const accepted = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST", assertion), test.local);
    expect(accepted.status).toBe(200);
  });

  it("rechecks role inside the same metadata transaction and rolls back on a concurrent revocation", async () => {
    const test = await fixture();
    const local = withBatchHook(test, async (ordinal, statements) => {
      if (ordinal === 1) await db.prepare(`INSERT INTO moderation_operator_role_events(operator_id, role_code, event_type)
        VALUES (?, 'triage', 'revoked')`).bind(test.operatorId).run();
      return statements;
    });
    const result = await routeLocalModerationOperatorTriage(test.request("/operator/v1/cases"), local);
    expect(result.status).toBe(403);
    expect(await count("moderation_operator_access_sessions")).toBe(0);
    expect(await count("moderation_operator_access_audit_starts")).toBe(0);
  });

  it("retains the attempt but refuses consumption when the credential is revoked after verification", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const local = withBatchHook(test, async (ordinal, statements) => {
      if (ordinal === 4) await db.prepare(`INSERT INTO moderation_operator_credential_events(credential_id_sha256, event_type)
        VALUES (?, 'revoked')`).bind(test.credentialDigest).run();
      return statements;
    });
    const result = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST",
      await test.assertion(challenge.challenge)), local);
    expect(result.status).toBe(403);
    expect(await count("moderation_operator_assertion_attempts")).toBe(1);
    expect(await count("moderation_operator_challenge_consumptions")).toBe(0);
    expect(await count("moderation_operator_actions")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
  });

  it("refuses an old Access identity epoch without consuming its challenge", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    await db.prepare(`INSERT INTO moderation_operator_subject_identities(operator_id, access_subject_hmac_key_version, access_subject_hmac)
      VALUES (?, 2, ?)`).bind(test.operatorId, "f".repeat(64)).run();
    const result = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST",
      await test.assertion(challenge.challenge)), test.local);
    expect(result.status).toBe(403);
    expect(await count("moderation_operator_assertion_attempts")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
  });

  it("allows only one of two concurrent submissions to consume and start review", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const body = await test.assertion(challenge.challenge);
    const results = await Promise.all([1, 2].map(() => routeLocalModerationOperatorTriage(
      test.request(challenge.assertionPath, "POST", body), test.local)));
    expect(results.map((result) => result.status).sort()).toEqual([200, 409]);
    expect(await count("moderation_operator_assertion_attempts")).toBe(1);
    expect(await count("moderation_operator_challenge_consumptions")).toBe(1);
    expect(await count("moderation_case_events")).toBe(1);
  });

  it("rolls back consumption, action, intent and review audit together while preserving the prior attempt", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const local = withBatchHook(test, async (ordinal, statements) => ordinal === 4
      ? [...statements, db.prepare("SELECT json('synthetic late transaction failure')")] : statements);
    const result = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST",
      await test.assertion(challenge.challenge)), local);
    expect(result.status).toBe(403);
    expect(await count("moderation_operator_assertion_attempts")).toBe(1);
    for (const table of ["moderation_operator_challenge_consumptions", "moderation_operator_actions",
      "moderation_evidence_event_intents", "moderation_case_events"]) expect(await count(table)).toBe(0);
    expect(await count("moderation_operator_access_audit_starts")).toBe(2);
    expect(await count("moderation_operator_access_audit_finishes")).toBe(2);
  });

  it("keeps failed finalization unreviewed, visible as pending, and non-replayable", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const body = await test.assertion(challenge.challenge);
    const local = withBatchHook(test, async (ordinal, statements) => {
      if (ordinal === 5) throw new Error("synthetic dependency failure");
      return statements;
    });
    const result = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST", body), local);
    expect(result.status).toBe(503);
    expect(await count("moderation_operator_assertion_attempts")).toBe(1);
    expect(await count("moderation_operator_challenge_consumptions")).toBe(1);
    expect(await count("moderation_evidence_event_intents")).toBe(1);
    expect(await count("moderation_evidence_ledger_events")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
    const queue = await routeLocalModerationOperatorTriage(test.request("/operator/v1/cases"), test.local);
    expect(await queue.json()).toMatchObject({ cases: [{ reviewState: "unreviewed", pendingFinalization: 1 }] });
    expect((await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST", body), test.local)).status).toBe(409);
  });

  it("enforces the existing exact per-session quota in the metadata/audit transaction", async () => {
    const test = await fixture();
    for (let index = 0; index < 30; index += 1) {
      expect((await routeLocalModerationOperatorTriage(test.request("/operator/v1/cases"), test.local)).status).toBe(200);
    }
    expect((await routeLocalModerationOperatorTriage(test.request("/operator/v1/cases"), test.local)).status).toBe(429);
    expect(await count("moderation_operator_access_audit_starts")).toBe(30);
    expect(await count("moderation_operator_access_audit_finishes")).toBe(30);
  });

  it("refuses a different Access session for the same operator without consuming the original challenge", async () => {
    const test = await fixture();
    const challenge = await begin(test);
    const body = await test.assertion(challenge.challenge);
    const otherSession = await test.sessionToken(600);
    const failed = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST", body,
      { "Cf-Access-Jwt-Assertion": otherSession }), test.local);
    expect(failed.status).toBe(409);
    expect(await count("moderation_operator_assertion_attempts")).toBe(0);
    expect(await count("moderation_operator_access_sessions")).toBe(1);
    expect((await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST", body), test.local)).status).toBe(200);
  });

  it("refuses an expired challenge using database time even during the Access clock-skew allowance", async () => {
    const test = await fixture();
    const token = await test.sessionToken(3);
    const started = await routeLocalModerationOperatorTriage(test.request(test.operationPath, "POST", undefined,
      { "Cf-Access-Jwt-Assertion": token }), test.local);
    expect(started.status).toBe(202);
    const challenge = await started.json<{ challenge: string; assertionPath: string; expiresAt: number }>();
    const body = await test.assertion(challenge.challenge);
    await new Promise((resolve) => setTimeout(resolve, Math.max(1, challenge.expiresAt * 1_000 - Date.now() + 100)));
    const result = await routeLocalModerationOperatorTriage(test.request(challenge.assertionPath, "POST", body,
      { "Cf-Access-Jwt-Assertion": token }), test.local);
    // The atomic authority guard rejects the expired session before looking
    // up its challenge, including while the Access verifier allows clock skew.
    expect(result.status).toBe(403);
    expect(await count("moderation_operator_assertion_attempts")).toBe(0);
    expect(await count("moderation_operator_challenge_consumptions")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
  });

  it.each(["known", "unknown"])("conceals %s case existence when triage access is revoked after actor lookup", async (kind) => {
    const test = await fixture();
    const local = withBatchHook(test, async (ordinal, statements) => {
      if (ordinal === 1) await db.prepare(`INSERT INTO moderation_operator_role_events(operator_id, role_code, event_type)
        VALUES (?, 'triage', 'revoked')`).bind(test.operatorId).run();
      return statements;
    });
    const path = kind === "known" ? test.operationPath : test.operationPath.replace(test.caseReference, "d".repeat(64));
    const result = await routeLocalModerationOperatorTriage(test.request(path, "POST"), local);
    expect(result.status).toBe(403);
    expect(await result.json()).toEqual({ error: { code: "operator_forbidden" } });
    expect(await count("moderation_operator_access_sessions")).toBe(0);
    expect(await count("moderation_operator_access_audit_starts")).toBe(0);
    expect(await count("moderation_operator_challenges")).toBe(0);
  });

  it.each(["known", "unknown"])("conceals %s challenge existence when triage access is revoked before its read", async (kind) => {
    const test = await fixture();
    const challenge = await begin(test);
    const local = withBatchHook(test, async (ordinal, statements) => {
      if (ordinal === 1) await db.prepare(`INSERT INTO moderation_operator_role_events(operator_id, role_code, event_type)
        VALUES (?, 'triage', 'revoked')`).bind(test.operatorId).run();
      return statements;
    });
    const path = kind === "known" ? challenge.assertionPath : challenge.assertionPath.replace(challenge.challengeId, crypto.randomUUID());
    const result = await routeLocalModerationOperatorTriage(test.request(path, "POST",
      await test.assertion(challenge.challenge)), local);
    expect(result.status).toBe(403);
    expect(await result.json()).toEqual({ error: { code: "operator_forbidden" } });
    expect(await count("moderation_operator_access_audit_starts")).toBe(1);
    expect(await count("moderation_operator_assertion_attempts")).toBe(0);
    expect(await count("moderation_case_events")).toBe(0);
  });
});
