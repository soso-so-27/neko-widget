import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fixture, origin, db, b64 } from "./fixtures/moderation-enrollment";
import { base64urlDecode } from "../src/encoding";
import { authenticateCloudflareAccessRequest, ModerationAccessJwksCache,
  type CloudflareAccessAuthenticationOptions } from "../src/moderation-operator-auth";
import { routeLocalModerationEnrollment, type LocalModerationEnrollmentEnvironment } from "../src/moderation-operator-enrollment-local";
import { routeModerationOperatorRequest } from "../src/moderation-operator-worker";
import type { LocalInitialEnrollmentRequest } from "../src/moderation-operator-enrollment-admission";
const encoder = new TextEncoder();
const root = "/operator/v1/enrollment";
const count = async (table: string) => (await db.prepare(`SELECT count(*) AS n FROM ${table}`).first<{n:number}>())!.n;
beforeEach(async () => { await reset(); await applyD1Migrations(db, (env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS); });

async function authenticated() {
  const key = await crypto.subtle.generateKey({name:"RSASSA-PKCS1-v1_5",modulusLength:2048,
    publicExponent:new Uint8Array([1,0,1]),hash:"SHA-256"},true,["sign","verify"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk",key.publicKey);
  const now = (await db.prepare("SELECT unixepoch() AS now").first<{now:number}>())!.now;
  const accessOptions: CloudflareAccessAuthenticationOptions = {issuer:"https://synthetic-operator.cloudflareaccess.com", audience:"2".repeat(64),
    subjectHmacKey:crypto.getRandomValues(new Uint8Array(32)),subjectHmacKeyVersion:1,cache:new ModerationAccessJwksCache(),
    fetchImpl:async () => new Response(JSON.stringify({keys:[{n:jwk.n,e:jwk.e,kty:"RSA",kid:"a".repeat(64),alg:"RS256",use:"sig"}]}),{headers:{"Content-Type":"application/json"}})};
  const jwtInput = `${b64(encoder.encode(JSON.stringify({alg:"RS256",kid:"a".repeat(64),typ:"JWT"})))}.${b64(encoder.encode(JSON.stringify({
    aud:[accessOptions.audience],iss:accessOptions.issuer,sub:crypto.randomUUID(),type:"app",iat:now,nbf:now,exp:now+600})))}`;
  const token = `${jwtInput}.${b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key.privateKey,encoder.encode(jwtInput))))}`;
  const req = (path: string, body?: string, headers: Record<string,string> = {}) => new Request(origin + path, {method:"POST",
    headers:{Origin:origin,"Cf-Access-Jwt-Assertion":token,...(body===undefined?{}:{"Content-Type":"application/json"}),...headers},...(body===undefined?{}:{body})});
  const access = await authenticateCloudflareAccessRequest(req(root+"/start"),accessOptions);
  const f = await fixture(access);
  const local: LocalModerationEnrollmentEnvironment = {environment:"local",db,operatorID:f.policy.binding.operatorID,
    scope:f.policy.scope,activeRoles:f.policy.activeRoles,authorities:f.policy.authorities,access:accessOptions};
  const route = (path: string, body?: string, headers?: Record<string,string>) => routeLocalModerationEnrollment(req(root+path,body,headers),local);
  async function prepare() {
    const first = await route("/start"); expect(first.status).toBe(202);
    const challenge = await first.json() as {ceremonyID:string;challenge:string;userID:string};
    expect(base64urlDecode(challenge.userID).length).toBe(32);
    const next = await route(`/ceremonies/${challenge.ceremonyID}/registration`,JSON.stringify(await f.key.response(challenge.challenge,true,7)));
    expect(next.status).toBe(202);
    const possession = await next.json() as {challenge:string};
    const response = await route(`/ceremonies/${challenge.ceremonyID}/possession`,JSON.stringify(await f.key.response(possession.challenge,false,8)));
    expect(response.status).toBe(202);
    return await response.json() as LocalInitialEnrollmentRequest;
  }
  async function approvalPackage(prepared: LocalInitialEnrollmentRequest) {
    return {approvals: await Promise.all(prepared.approvalTranscripts.map(async (transcript) => ({keyID:transcript.keyID,
      revision:transcript.revision,algorithm:"Ed25519",signatureBase64url:b64(new Uint8Array(await crypto.subtle.sign("Ed25519",
        f.pairs[Number(transcript.keyID.at(-1))]!.privateKey,new Uint8Array(base64urlDecode(transcript.transcriptBase64url)).buffer)))})))};
  }
  return {f,local,route,req,prepare,approvalPackage,token};
}

describe("local authenticated initial enrollment route", () => {
  it("renders a data-free CSP page only locally and leaves production routing closed", async () => {
    const t = await authenticated();
    const response = await routeLocalModerationEnrollment(new Request(origin+"/operator/enrollment"),t.local);
    expect(response.status).toBe(200); const html = await response.text();
    expect(html).toContain("運営者の登録");
    for (const secret of [t.token,t.f.policy.binding.operatorID,t.f.policy.binding.access.operatorSubjectHmac,t.f.policy.authorities[0]!.publicKeyBase64url]) expect(html).not.toContain(secret);
    const nonce = /script nonce="([0-9a-f]{32})"/u.exec(html)![1];
    expect(response.headers.get("Content-Security-Policy")).toContain(`script-src 'nonce-${nonce}'`);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect((await routeLocalModerationEnrollment(new Request(origin+"/operator/enrollment"),{...t.local,environment:"production"})).status).toBe(503);
    expect(routeModerationOperatorRequest(t.req(root+"/start"),{OPERATOR_RUNTIME_ENABLED:"YES"}).status).toBe(503);
    expect(await count("moderation_operator_enrollment_ceremonies")).toBe(0);
  });

  it("connects actual RS256 Access, ES256 registration/possession and two Ed25519 approvals to local admission", async () => {
    const t = await authenticated(); const request = await t.prepare();
    expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
    const result = await t.route(`/requests/${request.requestID}/admit`,JSON.stringify(await t.approvalPackage(request)));
    expect(result.status).toBe(200);
    const receipt = await result.json() as {kind:string;requestID:string;ceremonyID:string;canonicalRequestSHA256:string};
    expect(receipt).toMatchObject({kind:"locally-admitted-initial-operator",requestID:request.requestID,ceremonyID:request.ceremonyID,canonicalRequestSHA256:request.canonicalRequestSHA256});
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    const status = await t.route(`/ceremonies/${request.ceremonyID}/status`);
    expect(await status.json()).toMatchObject({status:"admitted",receipt});
  });

  it("recovers the same committed request and admission without repeating either write", async () => {
    const t = await authenticated(); const ignoredResponse = await t.prepare();
    const status = await t.route(`/ceremonies/${ignoredResponse.ceremonyID}/status`);
    const recovered = await status.json() as {status:string;request:LocalInitialEnrollmentRequest};
    expect(recovered.status).toBe("pending"); expect(recovered.request).toEqual(ignoredResponse);
    await t.route(`/requests/${recovered.request.requestID}/admit`,JSON.stringify(await t.approvalPackage(recovered.request)));
    const before = await count("moderation_operator_initial_enrollment_attempts");
    expect((await (await t.route(`/ceremonies/${ignoredResponse.ceremonyID}/status`)).json()) as object).toMatchObject({status:"admitted"});
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(before);
    expect(await count("moderation_operator_enrollment_requests")).toBe(1);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
  });

  it("rejects foreign, missing, invalid authentication, policy mismatch and body-bearing preparation before writes", async () => {
    const t = await authenticated();
    for (const headers of [{Origin:"https://foreign.invalid"},{Origin:""},{"Cf-Access-Jwt-Assertion":""},{"Cf-Access-Jwt-Assertion":"invalid"}])
      expect((await t.route("/start",undefined,headers)).status).toBeGreaterThanOrEqual(400);
    expect((await t.route("/start","{}")).status).toBe(409);
    expect((await routeLocalModerationEnrollment(t.req(root+"/start"),{...t.local,operatorID:crypto.randomUUID()})).status).toBe(403);
    expect((await routeLocalModerationEnrollment(t.req(root+"/start"),{...t.local,scope:{...t.local.scope,accessAudience:"1".repeat(64)}})).status).toBe(409);
    expect(await count("moderation_operator_enrollment_ceremonies")).toBe(0);
  });

  it("rejects duplicate and escaped duplicate approval fields, oversized and non-UTF8 bodies before final consumption", async () => {
    const t = await authenticated(); const prepared = await t.prepare(); const good = JSON.stringify(await t.approvalPackage(prepared));
    for (const raw of ['{"approvals":[],"approvals":[]}','{"approvals":[{"keyID":"one","key\\u0049D":"two"}]}',good.slice(0,-1)+',"roles":["security_admin"]}'," ".repeat(32769)]) {
      expect((await t.route(`/requests/${prepared.requestID}/admit`,raw)).status).toBe(409);
    }
    const invalid = new Request(origin+root+`/requests/${prepared.requestID}/admit`,{method:"POST",headers:{Origin:origin,"Content-Type":"application/json","Cf-Access-Jwt-Assertion":t.token},body:new Uint8Array([0xff])});
    expect((await routeLocalModerationEnrollment(invalid,t.local)).status).toBe(409);
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(0);
    expect((await t.route(`/requests/${prepared.requestID}/admit`,good)).status).toBe(200);
  });

  it("rejects a complete approval JSON that stalls before EOF without consuming final admission", async () => {
    const t = await authenticated(); const prepared = await t.prepare();
    const good = JSON.stringify(await t.approvalPackage(prepared));
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(encoder.encode(good)); },
      cancel() { cancelled = true; },
    });
    const realSetTimeout = globalThis.setTimeout;
    const timer = vi.spyOn(globalThis, "setTimeout").mockImplementation((...args: Parameters<typeof setTimeout>) => {
      args[1] = args[1] === 15000 ? 1 : args[1];
      return realSetTimeout(...args);
    });
    try {
      const stalled = new Request(origin+root+`/requests/${prepared.requestID}/admit`, {method:"POST",
        headers:{Origin:origin,"Content-Type":"application/json","Cf-Access-Jwt-Assertion":t.token},body:stream});
      expect((await routeLocalModerationEnrollment(stalled,t.local)).status).toBe(409);
      expect(cancelled).toBe(true);
      expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(0);
      expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
    } finally { timer.mockRestore(); }
    expect((await t.route(`/requests/${prepared.requestID}/admit`,good)).status).toBe(200);
  });
});
