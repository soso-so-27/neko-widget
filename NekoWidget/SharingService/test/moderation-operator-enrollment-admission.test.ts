import { env } from "cloudflare:workers";
import { applyD1Migrations, reset, type D1Migration } from "cloudflare:test";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { createLocalModerationEnrollmentCeremony as create, verifyLocalModerationEnrollmentRegistration as register,
  verifyLocalModerationEnrollmentPossession as possess, type LocalModerationEnrollmentBinding } from "../src/moderation-operator-enrollment-ceremony";
import { hashLocalEnrollmentAuthoritySet, hashLocalEnrollmentInstallationScope, type LocalEnrollmentOfflineApproval } from "../src/moderation-operator-enrollment-canonical";
import { createLocalInitialEnrollmentRequest, admitLocalInitialEnrollment, readLocalInitialEnrollmentStatus,
  type LocalInitialEnrollmentRequest } from "../src/moderation-operator-enrollment-admission";
import { base64urlDecode } from "../src/encoding";
import { actorSQL } from "../src/moderation-operator-identity";
const db = (env as unknown as {DB: D1Database}).DB;
const migrations = (env as unknown as {TEST_MIGRATIONS: D1Migration[]}).TEST_MIGRATIONS;
import { fixture, b64, hex, authenticator } from "./fixtures/moderation-enrollment";

const count = async (table: string) => (await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{n:number}>())!.n;
const denied = (p: Promise<unknown>) => expect(p).rejects.toThrow("local_initial_enrollment_unavailable");
async function prepared(ttl = 900) {
  const f = await fixture(); const ceremony = await f.completeCeremony(ttl);
  const request = await createLocalInitialEnrollmentRequest(db, {...f.policy, ceremonyID: ceremony.ceremonyID});
  async function sign(value = request): Promise<LocalEnrollmentOfflineApproval[]> {
    return Promise.all(value.approvalTranscripts.map(async (transcript, index) => ({keyID: transcript.keyID, revision: transcript.revision,
      algorithm: "Ed25519" as const, signatureBase64url: b64(new Uint8Array(await crypto.subtle.sign("Ed25519", f.pairs[index]!.privateKey,
        new Uint8Array(base64urlDecode(transcript.transcriptBase64url)).buffer)))})));
  }
  return {...f, ceremony, request, sign};
}
function proxy(before: (number: number) => Promise<void>, loseResponse = false): D1Database {
  let number = 0;
  return {prepare: db.prepare.bind(db), batch: async (statements: D1PreparedStatement[]) => {
    number++; await before(number); const result = await db.batch(statements);
    if (loseResponse && number === 2) throw new Error("synthetic response loss after commit");
    return result;
  }} as unknown as D1Database;
}
async function newAuthenticatorCeremony(f: Awaited<ReturnType<typeof prepared>>) {
  const key=await authenticator(); const first=await create(db,f.policy.binding);
  const next=await register(db,{ceremonyID:first.ceremonyID,binding:f.policy.binding,response:await key.response(first.challenge,true,7)});
  await possess(db,{ceremonyID:first.ceremonyID,binding:f.policy.binding,response:await key.response(next.challenge,false,8)});
  return {key,first};
}

describe("trusted local initial admission writer", () => {
  beforeEach(async () => {await reset(); await applyD1Migrations(db, migrations);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network forbidden"));});
  afterEach(() => {expect(fetch).not.toHaveBeenCalled(); vi.restoreAllMocks();});

  it("admits an actual durable WebAuthn registration with two actual Ed25519 approvals and an enrolled session", async () => {
    const f = await prepared();
    const access = f.policy.binding.access;
    expect(await db.prepare(actorSQL).bind(access.operatorSubjectHmac,access.subjectHmacKeyVersion).first()).toBeNull();
    await expect(db.prepare(`INSERT INTO moderation_operator_access_sessions(access_session_sha256,operator_id,
      access_subject_hmac_key_version,access_subject_hmac,token_issued_at,token_expires_at) VALUES(?,?,?,?,?,?)`)
      .bind(access.accessSessionSHA256,f.policy.binding.operatorID,access.subjectHmacKeyVersion,access.operatorSubjectHmac,access.issuedAt,access.expiresAt).run()).rejects.toThrow();
    const result = await admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()});
    expect(result).toMatchObject({kind:"locally-admitted-initial-operator",requestID:f.request.requestID,
      canonicalRequestSHA256:f.request.canonicalRequestSHA256,ceremonyID:f.ceremony.ceremonyID,
      operatorID:f.policy.binding.operatorID,activeRoles:["security_admin","triage"],hardwareProvenanceVerified:false,realHumanVerified:false});
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    expect(await count("moderation_operator_access_sessions")).toBe(1);
    expect(await count("moderation_operator_role_events")).toBe(2);
    const actor = await db.prepare(actorSQL).bind(access.operatorSubjectHmac,access.subjectHmacKeyVersion).first<{sign_count:number}>();
    expect(actor!.sign_count).toBe(8);
    expect(await db.prepare("SELECT registration_sign_count FROM moderation_operator_credentials").first()).toEqual({registration_sign_count:7});
    const stored = await db.prepare("SELECT requested_at FROM moderation_operator_enrollment_requests").first<{requested_at:number}>();
    expect(stored!.requested_at).toBe(f.request.requestedAt);
    const bridge=await db.prepare("SELECT role_snapshot_sha256 FROM moderation_operator_initial_enrollment_bindings").first<{role_snapshot_sha256:string}>();
    const approvals=(await db.prepare("SELECT * FROM moderation_operator_enrollment_offline_approvals ORDER BY offline_authority_key_id")
      .all<{offline_authority_key_id:string;authority_policy_revision:number;authority_public_key_fingerprint_sha256:string;authority_signature_sha256:string;approved_at:number}>()).results;
    const fields=["NW.MODERATION-ENROLLMENT.ADMISSION.v1","1",f.policy.binding.installationScopeSHA256,f.request.requestID,
      f.request.canonicalRequestSHA256,String(stored!.requested_at),String(f.request.expiresAt),f.ceremony.ceremonyID,
      bridge!.role_snapshot_sha256,f.policy.binding.authoritySetSHA256,"2",...approvals.flatMap(a=>[a.offline_authority_key_id,
        String(a.authority_policy_revision),a.authority_public_key_fingerprint_sha256,a.authority_signature_sha256,String(a.approved_at)])];
    // Independent length-prefix encoder, using actual committed approval times.
    const bytes=new Uint8Array(fields.flatMap(field=>{const data=new TextEncoder().encode(field);return [data.length>>>8,data.length&255,...data];}));
    expect(result.admissionProvenanceSHA256).toBe(await hex(bytes));
    expect((await readLocalInitialEnrollmentStatus(db,{...f.policy,requestID:f.request.requestID})).receipt).toEqual(result);
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
  });

  it.each(["operator","identity","activation","roles"])("does not invent missing %s and rolls back credential staging", async (missing) => {
    const f = await fixture(); const b={...f.policy.binding,operatorID:crypto.randomUUID(),access:{...f.policy.binding.access,operatorSubjectHmac:"b".repeat(64)}};
    if(missing!=="operator") {
      await db.prepare("INSERT INTO moderation_operators(operator_id) VALUES(?)").bind(b.operatorID).run();
      if(missing!=="identity") await db.prepare("INSERT INTO moderation_operator_subject_identities(operator_id,access_subject_hmac_key_version,access_subject_hmac) VALUES(?,?,?)")
        .bind(b.operatorID,b.access.subjectHmacKeyVersion,b.access.operatorSubjectHmac).run();
      if(missing!=="identity"&&missing!=="activation") {
        await db.prepare("INSERT INTO moderation_operator_state_events(operator_id,event_type) VALUES(?,'activated')").bind(b.operatorID).run();
        for(const role of missing==="roles"?["security_admin"]:f.policy.activeRoles) await db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES(?,?,'granted')").bind(b.operatorID,role).run();
      }
    }
    const before=await count("moderation_operator_role_events");
    const first=await create(db,b); const next=await register(db,{ceremonyID:first.ceremonyID,binding:b,response:await f.key.response(first.challenge,true,7)});
    await possess(db,{ceremonyID:first.ceremonyID,binding:b,response:await f.key.response(next.challenge,false,8)});
    await denied(createLocalInitialEnrollmentRequest(db,{...f.policy,binding:b,ceremonyID:first.ceremonyID}));
    expect(await count("moderation_operator_credentials")).toBe(0);
    expect(await count("moderation_operator_enrollment_requests")).toBe(0);
    expect(await count("moderation_operator_role_events")).toBe(before);
  });

  it("uses only durable possession rows and never accepts a browser receipt", async () => {
    const f = await fixture();
    const first = await create(db,f.policy.binding);
    await denied(createLocalInitialEnrollmentRequest(db,{...f.policy,ceremonyID:first.ceremonyID}));
    expect(await count("moderation_operator_credentials")).toBe(0);
    expect(await count("moderation_operator_enrollment_requests")).toBe(0);
  });

  it("recovers pending approval bytes through request or ceremony ID without writes or reissue", async () => {
    const f = await prepared();
    for (const identifier of [{requestID:f.request.requestID},{ceremonyID:f.ceremony.ceremonyID}]) {
      expect(await readLocalInitialEnrollmentStatus(db,{...f.policy,...identifier})).toEqual({status:"pending",request:f.request});
    }
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(0);
    expect(await count("moderation_operator_enrollment_requests")).toBe(1);
    await denied(createLocalInitialEnrollmentRequest(db,{...f.policy,ceremonyID:f.ceremony.ceremonyID}));
    expect(await count("moderation_operator_enrollment_requests")).toBe(1);
    expect(await readLocalInitialEnrollmentStatus(db,{...f.policy,requestID:crypto.randomUUID()})).toEqual({status:"not_found"});
  });

  it("burns a failed signature attempt before crypto; a corrected package cannot retry", async () => {
    const f = await prepared(); const approvals = await f.sign(); approvals[0]!.signatureBase64url=b64(new Uint8Array(64));
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals}));
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(1);
    expect(await count("moderation_operator_enrollment_offline_approvals")).toBe(0);
    expect((await readLocalInitialEnrollmentStatus(db,{...f.policy,ceremonyID:f.ceremony.ceremonyID})).status).toBe("attempted");
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
  });

  it("allows only one concurrent finalization", async () => {
    const f = await prepared(); const options={...f.policy,requestID:f.request.requestID,approvals:await f.sign()};
    const results=await Promise.allSettled([admitLocalInitialEnrollment(db,options),admitLocalInitialEnrollment(db,options)]);
    expect(results.map(r=>r.status).sort()).toEqual(["fulfilled","rejected"]);
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(1);
    expect(await count("moderation_operator_enrollment_offline_approvals")).toBe(2);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
  });

  it.each(["session","scope","roles","authority","identity"])("rejects changed caller %s before consuming", async (change) => {
    const f=await prepared(); const policy=structuredClone(f.policy);
    if(change==="session") policy.binding.access={...policy.binding.access,accessSessionSHA256:"e".repeat(64)};
    if(change==="scope") policy.scope.serviceIdentity="other-service";
    if(change==="roles") policy.activeRoles.push("auditor");
    if(change==="authority") policy.authorities[0]!.revision++;
    if(change==="identity") policy.binding.operatorID=crypto.randomUUID();
    await denied(admitLocalInitialEnrollment(db,{...policy,requestID:f.request.requestID,approvals:await f.sign()}));
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(0);
    await denied(readLocalInitialEnrollmentStatus(db,{...policy,requestID:f.request.requestID}));
  });

  it.each(["role-added","role-revoked","alias","credential-revoked","authority-revision","authority-added"])("rechecks DB %s in the final transaction after signatures and approvals", async (change) => {
    const f=await prepared();
    const connection=proxy(async (batch) => {
      if(batch!==2)return;
      if(change==="role-added"||change==="role-revoked") await db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES(?,?,?)")
        .bind(f.policy.binding.operatorID,change==="role-added"?"auditor":"triage",change==="role-added"?"granted":"revoked").run();
      if(change==="alias") await db.prepare("INSERT INTO moderation_operator_subject_identities(operator_id,access_subject_hmac_key_version,access_subject_hmac) VALUES(?,2,?)")
        .bind(f.policy.binding.operatorID,"c".repeat(64)).run();
      if(change==="credential-revoked") await db.prepare("INSERT INTO moderation_operator_credential_events(credential_id_sha256,event_type) VALUES(?,'revoked')").bind(await hex(f.key.id)).run();
      if(change.startsWith("authority")) await db.prepare("INSERT INTO moderation_operator_enrollment_offline_authorities(offline_authority_key_id,authority_policy_revision,authority_public_key_fingerprint_sha256) VALUES(?,?,?)")
        .bind(change==="authority-added"?"offline-extra":f.policy.authorities[0]!.keyID,change==="authority-added"?1:2,"f".repeat(64)).run();
    });
    await denied(admitLocalInitialEnrollment(connection,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
    expect(await count("moderation_operator_enrollment_offline_approvals")).toBe(2);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
    expect(await count("moderation_operator_access_sessions")).toBe(0);
  });

  it("rolls back admission if the enrolled session fails, retains consumed attempt and both approvals", async () => {
    const f=await prepared();
    await db.exec("CREATE TRIGGER test_session_failure BEFORE INSERT ON moderation_operator_access_sessions BEGIN SELECT RAISE(ABORT,'synthetic session failure'); END");
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
    expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
    expect(await count("moderation_operator_access_sessions")).toBe(0);
    expect(await count("moderation_operator_enrollment_offline_approvals")).toBe(2);
    expect((await readLocalInitialEnrollmentStatus(db,{...f.policy,requestID:f.request.requestID})).status).toBe("attempted");
  });

  it("recovers a committed admission after the response is lost without any second write", async () => {
    const f=await prepared();
    await denied(admitLocalInitialEnrollment(proxy(async()=>{},true),{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    const state=await readLocalInitialEnrollmentStatus(db,{...f.policy,ceremonyID:f.ceremony.ceremonyID});
    expect(state.status).toBe("admitted"); expect(state.receipt!.canonicalRequestSHA256).toBe(f.request.canonicalRequestSHA256);
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(1);
    expect(await count("moderation_operator_access_sessions")).toBe(1);
  });

  it("copies inputs before awaiting and rejects accessor-selected approval keys", async () => {
    const f=await prepared(); const options={...structuredClone(f.policy),requestID:f.request.requestID,approvals:await f.sign()};
    const pending=admitLocalInitialEnrollment(db,options);
    options.activeRoles.push("auditor"); options.authorities[0]!.revision=99; options.approvals[0]!.signatureBase64url="changed";
    expect((await pending).activeRoles).toEqual(["security_admin","triage"]);
    const input={...f.policy,requestID:f.request.requestID,get approvals():LocalEnrollmentOfflineApproval[]{throw new Error("must not invoke");}};
    await denied(admitLocalInitialEnrollment(db,input));
  });

  it("rejects expired requests without extending the ceremony or treating a timeout as success", async () => {
    const f=await prepared(2); const approvals=await f.sign();
    await new Promise(resolve=>setTimeout(resolve,Math.max(0,f.request.expiresAt*1000-Date.now())+30));
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals}));
    expect(await readLocalInitialEnrollmentStatus(db,{...f.policy,requestID:f.request.requestID})).toEqual({status:"expired"});
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(0);
  });

  it("rechecks expiry after successful signatures and committed approvals at final transaction time", async () => {
    const f=await prepared(2);
    const connection=proxy(async batch=>{
      if(batch===2) await new Promise(resolve=>setTimeout(resolve,Math.max(0,f.request.expiresAt*1000-Date.now())+30));
    });
    await denied(admitLocalInitialEnrollment(connection,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
    expect(await count("moderation_operator_enrollment_offline_approvals")).toBe(2);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
    expect(await count("moderation_operator_access_sessions")).toBe(0);
  });

  it.each(["failed","expired"])("explicitly restarts an ended %s application with a new ceremony and different credential", async (reason) => {
    const f=await prepared(reason==="expired"?2:900);
    if(reason==="failed") {
      const bad=await f.sign(); bad[0]!.signatureBase64url=b64(new Uint8Array(64));
      await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:bad}));
      expect(await count("moderation_operator_initial_enrollment_failures")).toBe(1);
    } else await new Promise(resolve=>setTimeout(resolve,Math.max(0,f.request.expiresAt*1000-Date.now())+30));
    const replacement=await newAuthenticatorCeremony(f);
    const request=await createLocalInitialEnrollmentRequest(db,{...f.policy,ceremonyID:replacement.first.ceremonyID});
    expect(request.requestID).not.toBe(f.request.requestID);
    expect(await count("moderation_operator_credentials")).toBe(2);
    expect(await count("moderation_operator_enrollment_requests")).toBe(2);
    expect(await db.prepare("SELECT 1 FROM moderation_operator_initial_enrollment_current WHERE enrollment_request_id=?").bind(f.request.requestID).first()).toBeNull();
    // Even a delayed old write cannot complete after its terminal failure/expiry.
    await expect(db.prepare(`INSERT INTO moderation_operator_enrollment_offline_approvals(enrollment_request_id,offline_authority_key_id,
      authority_policy_revision,authority_public_key_fingerprint_sha256,authority_signature_sha256) VALUES(?,?,?,?,?)`)
      .bind(f.request.requestID,f.policy.authorities[0]!.keyID,1,f.policy.authorities[0]!.publicKeyFingerprintSHA256,"d".repeat(64)).run()).rejects.toThrow();
    const receipt=await admitLocalInitialEnrollment(db,{...f.policy,requestID:request.requestID,approvals:await f.sign(request)});
    expect(receipt.requestID).toBe(request.requestID);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    expect(await count("moderation_operator_access_sessions")).toBe(1);
    expect(await count("moderation_operator_enrollment_ceremony_possessions")).toBe(2);
    expect(await count("moderation_operator_initial_enrollment_bindings")).toBe(2);
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
  });

  it.each([false,true])("rejects a competing new credential while the prior request remains pending (attempt=%s)", async (attempt) => {
    const f=await prepared();
    if(attempt) {
      await db.prepare("INSERT INTO moderation_operator_initial_enrollment_attempts(enrollment_request_id,attempt_id) VALUES(?,?)")
        .bind(f.request.requestID,crypto.randomUUID()).run();
      // Duplicate caller must not terminalize the other caller's active attempt.
      await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
      expect(await count("moderation_operator_initial_enrollment_failures")).toBe(0);
    }
    const replacement=await newAuthenticatorCeremony(f);
    await denied(createLocalInitialEnrollmentRequest(db,{...f.policy,ceremonyID:replacement.first.ceremonyID}));
    expect(await count("moderation_operator_credentials")).toBe(1);
    expect(await count("moderation_operator_enrollment_requests")).toBe(1);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
  });

  it.each([true,false])("rejects an unknown legacy credential, including one with the same durable ID (%s)", async (sameID) => {
    const f=await fixture(); const first=await f.completeCeremony();
    const legacy=sameID?f.key:await authenticator();
    await db.prepare("INSERT INTO moderation_operator_credentials(credential_id_sha256,operator_id,public_key_cose,registration_sign_count) VALUES(?,?,?,7)")
      .bind(await hex(legacy.id),f.policy.binding.operatorID,legacy.publicKeyCose).run();
    await db.prepare("INSERT INTO moderation_operator_credential_events(credential_id_sha256,event_type) VALUES(?,'registered')").bind(await hex(legacy.id)).run();
    await denied(createLocalInitialEnrollmentRequest(db,{...f.policy,ceremonyID:first.ceremonyID}));
    expect(await count("moderation_operator_initial_enrollment_bindings")).toBe(0);
    expect(await count("moderation_operator_credentials")).toBe(1);
  });

  it("keeps an unavailable failure audit unresolved and refuses a competing restart", async () => {
    const f=await prepared();
    await db.exec("CREATE TRIGGER test_failure_audit_unavailable BEFORE INSERT ON moderation_operator_initial_enrollment_failures BEGIN SELECT RAISE(ABORT,'synthetic audit unavailable'); END");
    const bad=await f.sign(); bad[0]!.signatureBase64url=b64(new Uint8Array(64));
    await denied(admitLocalInitialEnrollment(db,{...f.policy,requestID:f.request.requestID,approvals:bad}));
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(1);
    expect(await count("moderation_operator_initial_enrollment_failures")).toBe(0);
    const next=await newAuthenticatorCeremony(f);
    await denied(createLocalInitialEnrollmentRequest(db,{...f.policy,ceremonyID:next.first.ceremonyID}));
    expect(await count("moderation_operator_credentials")).toBe(1);
    expect(await count("moderation_operator_enrollment_admissions")).toBe(0);
  });

  it("returns a committed historical receipt after response loss and ceremony expiry without asserting fresh rights", async () => {
    const f=await prepared(2);
    await denied(admitLocalInitialEnrollment(proxy(async()=>{},true),{...f.policy,requestID:f.request.requestID,approvals:await f.sign()}));
    const saved=(await readLocalInitialEnrollmentStatus(db,{...f.policy,requestID:f.request.requestID})).receipt!;
    expect(await count("moderation_operator_initial_enrollment_failures")).toBe(0);
    await new Promise(resolve=>setTimeout(resolve,Math.max(0,f.request.expiresAt*1000-Date.now())+30));
    const status=await readLocalInitialEnrollmentStatus(db,{...f.policy,ceremonyID:f.ceremony.ceremonyID});
    expect(status).toEqual({status:"admitted",request:f.request,receipt:saved});
    expect(status.receipt!.admittedAt).toBeLessThan(f.request.expiresAt);
    expect(status.receipt).not.toHaveProperty("currentlyAuthorized");
    expect(await count("moderation_operator_enrollment_admissions")).toBe(1);
    expect(await count("moderation_operator_access_sessions")).toBe(1);
    expect(await count("moderation_operator_initial_enrollment_attempts")).toBe(1);
  });
});
