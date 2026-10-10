import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { fixture, origin, rpID, db, b64 } from "./fixtures/moderation-enrollment";
import { base64urlDecode } from "../src/encoding";
import { authenticateCloudflareAccessRequest, ModerationAccessJwksCache,
  type CloudflareAccessAuthenticationOptions } from "../src/moderation-operator-auth";
import { routeLocalModerationEnrollment } from "../src/moderation-operator-enrollment-local";
import { routeLocalModerationOperatorTriage } from "../src/moderation-operator-triage-local";
import type { LocalInitialEnrollmentRequest } from "../src/moderation-operator-enrollment-admission";
import { createLocalModerationOperatorHost, type LocalModerationOperatorHostEnvironment } from "../src/moderation-operator-host-local";

const encoder = new TextEncoder();
const root = "/operator/v1/enrollment";
const hostRPID = new URL(origin).hostname;
const count = async (table: string) => (await db.prepare(`SELECT count(*) AS n FROM ${table}`).first<{n:number}>())!.n;
beforeEach(async () => { await reset(); await applyD1Migrations(db, (env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS); });

async function authenticated(expectedRPID = hostRPID, extraEnrollment:Record<string,unknown> = {}) {
  const key = await crypto.subtle.generateKey({name:"RSASSA-PKCS1-v1_5",modulusLength:2048,
    publicExponent:new Uint8Array([1,0,1]),hash:"SHA-256"},true,["sign","verify"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk",key.publicKey);
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{now:number}>())!.now;
  const access: CloudflareAccessAuthenticationOptions = {issuer:"https://synthetic-operator.cloudflareaccess.com",audience:"2".repeat(64),
    subjectHmacKey:crypto.getRandomValues(new Uint8Array(32)),subjectHmacKeyVersion:1,cache:new ModerationAccessJwksCache(),
    fetchImpl:async () => new Response(JSON.stringify({keys:[{n:jwk.n,e:jwk.e,kty:"RSA",kid:"a".repeat(64),alg:"RS256",use:"sig"}]}),
      {headers:{"Content-Type":"application/json"}})};
  const input = `${b64(encoder.encode(JSON.stringify({alg:"RS256",kid:"a".repeat(64),typ:"JWT"})))}.${b64(encoder.encode(JSON.stringify({
    aud:[access.audience],iss:access.issuer,sub:crypto.randomUUID(),type:"app",iat:now,nbf:now,exp:now+600})))}`;
  const token = `${input}.${b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key.privateKey,encoder.encode(input))))}`;
  const req = (path:string,body?:string,headers:Record<string,string>={},method="POST") => new Request(origin+path,{method,
    headers:{Origin:origin,"Cf-Access-Jwt-Assertion":token,...(body===undefined?{}:{"Content-Type":"application/json"}),...headers},
    ...(body===undefined?{}:{body})});
  const identity = await authenticateCloudflareAccessRequest(req(root+"/start"),access);
  const f = await fixture(identity,expectedRPID);
  const local = {runtimeEnabled:"YES",environment:"local",db,origin,rpId:expectedRPID,access,
    enrollment:{operatorID:f.policy.binding.operatorID,scope:f.policy.scope,activeRoles:f.policy.activeRoles,authorities:f.policy.authorities}};
  Object.assign(local.enrollment,extraEnrollment);
  // The original direct probe remains separate: parent-domain enrollment works,
  // while the unchanged triage handler refuses it. The composed host rejects it at startup.
  const direct = (path:string,body?:string,headers?:Record<string,string>,method="POST") => path.startsWith(root)
    ? routeLocalModerationEnrollment(req(path,body,headers,method),{...local,...local.enrollment})
    : routeLocalModerationOperatorTriage(req(path,body,headers,method),local);
  const host = createLocalModerationOperatorHost(local);
  const route = (path:string,body?:string,headers?:Record<string,string>,method="POST") => host(req(path,body,headers,method));
  async function admit(useDirect = false) {
    const run = useDirect ? direct : route;
    expect((await run("/operator/v1/cases/read")).status).toBe(403);
    const first = await run(root+"/start"); expect(first.status).toBe(202);
    const challenge = await first.json() as {ceremonyID:string;challenge:string};
    const next = await run(`${root}/ceremonies/${challenge.ceremonyID}/registration`,JSON.stringify(await f.key.response(challenge.challenge,true,7)));
    expect(next.status).toBe(202);
    const possession = await next.json() as {challenge:string};
    const prepared = await run(`${root}/ceremonies/${challenge.ceremonyID}/possession`,JSON.stringify(await f.key.response(possession.challenge,false,8)));
    expect(prepared.status).toBe(202);
    const request = await prepared.json() as LocalInitialEnrollmentRequest;
    const approvals = await Promise.all(request.approvalTranscripts.map(async transcript => ({keyID:transcript.keyID,revision:transcript.revision,
      algorithm:"Ed25519",signatureBase64url:b64(new Uint8Array(await crypto.subtle.sign("Ed25519",
        f.pairs[Number(transcript.keyID.at(-1))]!.privateKey,new Uint8Array(base64urlDecode(transcript.transcriptBase64url)).buffer)))})));
    const result = await run(`${root}/requests/${request.requestID}/admit`,JSON.stringify({approvals})); expect(result.status).toBe(200);
    return request;
  }
  return {f,local,req,route,direct,host,admit,token};
}

describe("local operator host integration", () => {
  it("observes the existing parent-domain RP rejection after a real successful enrollment",async () => {
    const t = await authenticated(rpID); await t.admit(true);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    expect((await t.direct("/operator/v1/cases/read")).status).toBe(403);
    expect((await t.route(root+"/start")).status).toBe(503);
    expect(await count("moderation_operator_access_audit_starts")).toBe(0);
  });
  it("continues from actual enrollment to an audited queue using the same exact-host RP, DB and Access key",async () => {
    const t = await authenticated(); await t.admit();
    const queue = await t.route("/operator/v1/cases/read"); expect(queue.status).toBe(200);
    expect(await queue.json()).toMatchObject({cases:[],hasMore:false,unboundCases:0});
    expect(await count("moderation_operator_access_audit_finishes")).toBe(1);
  });
  it("uses the admitted credential for a real case review without synthesizing an admission row",async () => {
    const t = await authenticated(); await t.admit(); const reference = await seedReport();
    const queue = await t.route("/operator/v1/cases/read"); expect(queue.status).toBe(200);
    expect(await queue.json()).toMatchObject({cases:[{caseReferenceHmac:reference,reviewState:"unreviewed"}]});
    const begin = await t.route(`/operator/v1/cases/${reference}/review-start`); expect(begin.status).toBe(202);
    const challenge = await begin.json() as {assertionPath:string;challenge:string};
    const reviewed = await t.route(challenge.assertionPath,JSON.stringify(await t.f.key.response(challenge.challenge,false,9)));
    expect(reviewed.status).toBe(200);
    expect(await reviewed.json()).toEqual({caseReferenceHmac:reference,reviewState:"in_review"});
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    expect(await count("moderation_evidence_event_finalizations")).toBe(1);
  });
  it("rechecks current roles and Access even when the historical admission receipt is readable",async () => {
    const t = await authenticated(); const admitted = await t.admit();
    await db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES(?,'triage','revoked')")
      .bind(t.f.policy.binding.operatorID).run();
    expect((await t.route("/operator/v1/cases/read")).status).toBe(403);
    expect((await t.route("/operator/v1/cases/read",undefined,{"Cf-Access-Jwt-Assertion":""})).status).toBe(401);
    expect(await (await t.route(`${root}/ceremonies/${admitted.ceremonyID}/status`)).json()).toMatchObject({status:"admitted"});
    expect(await count("moderation_operator_access_audit_starts")).toBe(0);
  });
  it("keeps local startup policy fixed despite caller mutations",async () => {
    const t = await authenticated();
    t.local.origin = "https://foreign.invalid"; t.local.rpId = "foreign.invalid";
    t.local.enrollment.scope.expectedRPID = "foreign.invalid";
    t.local.enrollment.authorities[0]!.publicKeyBase64url = "invalid";
    (t.local.access.subjectHmacKey as Uint8Array).fill(0);
    t.local.enrollment.activeRoles.splice(0);
    await t.admit();
    expect((await t.route("/operator/v1/cases/read")).status).toBe(200);
  });
  it("does not allow runtime extra enrollment properties to override the shared DB, Access or local mode",async () => {
    const trapDB = new Proxy({},{get(){throw Error("unexpected secondary DB read");}});
    const t = await authenticated(hostRPID,{db:trapDB,access:{issuer:"https://foreign.invalid"},environment:"production"});
    await t.admit();
    expect((await t.route("/operator/v1/cases/read")).status).toBe(200);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
  });
  it("rejects inconsistent installation settings, foreign origins and alternate request paths before writes",async () => {
    const t = await authenticated();
    for (const scope of [{...t.local.enrollment.scope,accessAudience:"3".repeat(64)},
      {...t.local.enrollment.scope,accessIssuer:"https://other.cloudflareaccess.com"},
      {...t.local.enrollment.scope,expectedOrigin:"https://foreign.invalid"}, {...t.local.enrollment.scope,expectedRPID:rpID}]) {
      const host = createLocalModerationOperatorHost({...t.local,enrollment:{...t.local.enrollment,scope}});
      expect((await host(t.req(root+"/start"))).status).toBe(503);
    }
    for (const originOverride of [origin+"/", "http://moderation.operator.example.test",origin+"#fragment"]) {
      expect((await createLocalModerationOperatorHost({...t.local,origin:originOverride})(t.req(root+"/start"))).status).toBe(503);
    }
    for (const path of [root+"/start?operator=other",root+"/start#fragment"]) expect((await t.route(path)).status).toBe(403);
    expect((await t.host(new Request("https://foreign.invalid"+root+"/start",{method:"POST"}))).status).toBe(403);
    expect((await t.route(root+"/start",undefined,{Origin:"https://foreign.invalid"})).status).toBe(409);
    expect((await t.route("/operator/v1/enrollment-other/start")).status).toBe(404);
    expect(await count("moderation_operator_enrollment_ceremonies")).toBe(0);
  });
  it("keeps OFF/nonlocal hosts inert and renders the existing linked consoles without secret configuration",async () => {
    const t = await authenticated();
    for (const [runtimeEnabled,environment] of [["NO","local"],["YES","production"],["yes","local"]]) {
      const input = new Proxy({runtimeEnabled,environment},{get(target,key){
        if (key === "runtimeEnabled" || key === "environment") return target[key]; throw Error("protected input read");
      }}) as LocalModerationOperatorHostEnvironment;
      expect((await createLocalModerationOperatorHost(input)(new Proxy({} as Request,{get(){throw Error("request read");}}))).status).toBe(503);
    }
    for (const path of ["/operator/enrollment","/operator/console","/operator/owner/console/"+"a".repeat(64)+"/1"]) {
      const response = await t.route(path,undefined,undefined,"GET"); expect(response.status).toBe(200);
      const html = await response.text();
      for (const secret of [t.token,t.f.policy.binding.operatorID,t.f.policy.authorities[0]!.publicKeyBase64url]) expect(html).not.toContain(secret);
      expect(response.headers.get("Content-Security-Policy")).toContain("script-src 'nonce-");
      if (path === "/operator/enrollment") expect(html).toContain('href="/operator/console"');
    }
    expect((await t.route("/operator/owner/v1/cases/"+"a".repeat(64)+"/1/content-read")).status).toBe(503);
    expect((await t.route("/operator/resolution/v1/unknown")).status).toBe(404);
  });
});

/** Only synthetic report fixtures; all operator admissions above use real signatures. */
async function seedReport() {
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{now:number}>())!.now;
  const id = () => b64(crypto.getRandomValues(new Uint8Array(16)));
  const sha = () => b64(crypto.getRandomValues(new Uint8Array(32)));
  const lineage=crypto.randomUUID(),owner=id(),receiver=id(),ownerDevice=id(),receiverDevice=id(),moment=id(),report=id();
  const reference = "a".repeat(64);
  await db.batch([
    db.prepare("INSERT INTO moment_space_lineages(id,created_at) VALUES(?,unixepoch())").bind(lineage),
    db.prepare("INSERT INTO moment_spaces(space_id,lineage_id,state,created_at,updated_at) VALUES(?,?,'active',?,?)").bind(lineage,lineage,now,now),
    ...[owner,receiver].map((p,i) => db.prepare("INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES(?,?,?,'active',?,?)").bind(p,lineage,i===0?'owner':'member',now,now)),
    ...[[owner,ownerDevice],[receiver,receiverDevice]].map(([p,d]) => db.prepare("INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at) VALUES(?,?,?,?,'active',?,?)").bind(d!,p!,sha(),sha(),now,now)),
    db.prepare(`INSERT INTO moments(id,client_moment_id,space_id,sender_participant_id,sender_device_id,kind,key_epoch,state,object_key,ciphertext_size,ciphertext_sha256,client_moderation_version,sender_policy_version,sender_policy_accepted_at,quota_day_key,quota_counted,reservation_attempt,reserve_request_hash,created_at,upload_expires_at,uploaded_at,committed_at,unreceived_expires_at)
      VALUES(?,?,?,?,?,'live',1,'committed',?,32,?,1,1,?,1,0,1,?,?,?,?,?,?)`).bind(moment,crypto.randomUUID(),lineage,owner,ownerDevice,`moments/${moment}`,sha(),now,sha(),now,now+3600,now,now,now+604800),
    db.prepare("INSERT INTO moment_deliveries(moment_id,recipient_participant_id,state,created_at,access_expires_at) VALUES(?,?,'pending',?,?)").bind(moment,receiver,now,now+604800),
    db.prepare(`INSERT INTO moment_reports(id,moment_id,space_id,lineage_id,reporter_participant_id,reporter_device_id,accused_participant_id,reason_code,moderation_key_id,state,object_key,ciphertext_size,ciphertext_sha256,reporter_consent_version,reporter_consented_at,quota_day_key,reserve_request_hash,dedupe_key,created_at,upload_expires_at)
      VALUES(?,?,?,?,?,?,?,'privacy','moderation-v1','reserved',?,32,?,1,?,1,?,?,?,?)`).bind(report,moment,lineage,lineage,receiver,receiverDevice,owner,`reports/${report}`,sha(),now,sha(),sha(),now,now+3600),
    db.prepare("UPDATE moment_reports SET state='uploaded',uploaded_at=? WHERE id=?").bind(now,report),
    db.prepare("INSERT INTO moment_report_commit_events(id,report_id,reporter_participant_id,committed_at,content_expires_at) VALUES(?,?,?,?,?)").bind(crypto.randomUUID(),report,receiver,now,now+604800),
    db.prepare("INSERT INTO moderation_operator_versioned_case_references(report_id,case_reference_hmac,case_reference_hmac_key_version,derivation_protocol_version,derivation_domain) VALUES(?,?,1,1,'NW.MODERATION-OPERATOR.CASE-REFERENCE')").bind(report,reference),
  ]);
  return reference;
}
