import { base64urlEncode } from "./encoding";
import { authenticateCloudflareAccessRequest, type AuthenticatedModerationOperatorAccess } from "./moderation-operator-auth";
import { actorSQL, guard, admitSession, type Actor } from "./moderation-operator-identity";
import { prepareModerationOperatorWebAuthnRequest } from "./moderation-operator-request";
import { verifyPreparedModerationOperatorWebAuthnAssertion } from "./moderation-operator-webauthn";
import type { LocalModerationTriageEnvironment } from "./moderation-operator-triage-local";
import { readLocalModerationReviewSource, type LocalModerationReviewSource } from "./moderation-review-source";
import { localModerationReviewSourceSHA256 } from "./moderation-review-binding";
import { localModerationOwnerConsole } from "./moderation-owner-console";

type Phase = "started" | "disclosure_ready";
/** Trusted isolated host implementation, never selected by a request/browser.
 * It must use the reviewed Node decryptor, call readCurrentSource on every
 * existing boundary, persist audit before disclosure, and return an owned JPEG
 * copy. This local handler does not transport keys or enable a production host. */
export interface LocalOwnerReviewHost {
  (input: Readonly<{
    source: LocalModerationReviewSource;
    sourceSHA256: string;
    signal: AbortSignal;
    readCurrentSource(): Promise<LocalModerationReviewSource>;
    audit(phase: Phase): Promise<void>;
  }>): Promise<Uint8Array>;
}
export interface LocalModerationOwnerEnvironment extends LocalModerationTriageEnvironment {
  reviewEvidence?: LocalOwnerReviewHost;
}
interface Challenge {
  challenge_id: string;
  policy_revision: number;
  purpose: "content_read" | "decision";
  challenge_value_sha256: string;
  case_reference_hmac: string;
  case_reference_hmac_key_version: number;
  source_snapshot_sha256: string;
  read_receipt_id: string | null;
  expires_at: number;
}
const jsonHeaders = { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8", "X-Content-Type-Options": "nosniff" };
const hex = "[0-9a-f]{64}";
const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const pattern = new RegExp(`^/operator/owner/v1/cases/(${hex})/([1-9][0-9]{0,9})/(content-read|decisions/no-action/(${uuid}))(?:/assertions/(${uuid}))?$`, "u");
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: jsonHeaders });
class OwnerError extends Error { constructor(readonly status: number) { super("owner_review_unavailable"); } }
const fail = (status = 409): never => { throw new OwnerError(status); };
async function sha(bytes: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer))]
    .map(value => value.toString(16).padStart(2, "0")).join("");
}
function policyGuard(db: D1Database, actor: Actor, revision: number): D1PreparedStatement {
  return db.prepare(`SELECT json(CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_current_policies
    WHERE policy_revision=? AND owner_operator_id=? AND enrollment_admission_id=?) THEN 'true' ELSE 'denied' END)`)
    .bind(revision, actor.operator_id, actor.enrollment_admission_id);
}
function currentGuard(db: D1Database, actor: Actor, access: AuthenticatedModerationOperatorAccess,
  challenge: Challenge): D1PreparedStatement {
  return db.prepare(`SELECT json(CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_current_challenges
    WHERE challenge_id=? AND operator_id=? AND credential_id_sha256=? AND enrollment_admission_id=?
      AND access_session_sha256=? AND source_snapshot_sha256=?) THEN 'true' ELSE 'denied' END)`)
    .bind(challenge.challenge_id, actor.operator_id, actor.credential_id_sha256,
      actor.enrollment_admission_id, access.accessSessionSHA256, challenge.source_snapshot_sha256);
}
async function source(env: LocalModerationOwnerEnvironment, reference: string, version: number) {
  const value = await readLocalModerationReviewSource(env.db, { caseReferenceHmac: reference, caseReferenceHmacKeyVersion: version });
  if (!value) return fail();
  return value;
}
async function issue(env: LocalModerationOwnerEnvironment, access: AuthenticatedModerationOperatorAccess,
  actor: Actor, reference: string, version: number, receiptId: string | undefined, pathname: string): Promise<Response> {
  const policy = await env.db.prepare(`SELECT policy_revision FROM moderation_owner_current_policies
    WHERE owner_operator_id=? AND enrollment_admission_id=?`).bind(actor.operator_id, actor.enrollment_admission_id)
    .first<{ policy_revision: number }>();
  if (!policy) return fail(403);
  const snapshot = await source(env, reference, version);
  const snapshotSHA = await localModerationReviewSourceSHA256(snapshot);
  const challengeId = crypto.randomUUID();
  const random = crypto.getRandomValues(new Uint8Array(32));
  const purpose = receiptId === undefined ? "content_read" : "decision";
  const result = await env.db.batch([guard(env.db, access, actor), policyGuard(env.db, actor, policy.policy_revision),
    admitSession(env.db, access, actor),
    env.db.prepare(`INSERT INTO moderation_owner_challenges(challenge_id,domain,policy_revision,operator_id,
      credential_id_sha256,enrollment_admission_id,access_session_sha256,challenge_value_sha256,purpose,
      case_reference_hmac,case_reference_hmac_key_version,source_sha256,source_committed_at,source_expires_at,
      source_snapshot_sha256,decision,reply_template,read_receipt_id,expires_at)
      VALUES (?,'NW.MODERATION-OWNER.ACTION.v1',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, ?,MIN(unixepoch()+300,?,?))
      RETURNING expires_at`).bind(challengeId, policy.policy_revision, actor.operator_id, actor.credential_id_sha256,
        actor.enrollment_admission_id, access.accessSessionSHA256, await sha(random), purpose, reference, version,
        snapshot.metadata.ciphertextSHA256, snapshot.metadata.committedAt, snapshot.metadata.contentExpiresAt,
        snapshotSHA, receiptId === undefined ? null : "no_action", receiptId === undefined ? null : "review_no_action_v1",
        receiptId ?? null, access.expiresAt, snapshot.metadata.contentExpiresAt),
  ]);
  return json({ challengeId, challenge: base64urlEncode(random), assertionPath: `${pathname}/assertions/${challengeId}`,
    caseReferenceHmac: reference, sourceSHA256: snapshotSHA,
    expiresAt: (result[3]!.results[0] as { expires_at: number }).expires_at,
    rpId: env.rpId, userVerification: "required", purpose }, 202);
}
async function disclose(env: LocalModerationOwnerEnvironment, access: AuthenticatedModerationOperatorAccess,
  actor: Actor, challenge: Challenge, receiptId: string, host: LocalOwnerReviewHost): Promise<Response> {
  const controller = new AbortController();
  const deadline = Date.now() + 60_000;
  const alive = () => { if (controller.signal.aborted || Date.now() >= deadline) fail(); };
  async function step<T>(operation: () => Promise<T>): Promise<T> {
    alive();
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      return await new Promise<T>((resolve, reject) => {
        timeout = setTimeout(() => { controller.abort(); reject(new OwnerError(503)); }, Math.max(1, deadline - Date.now()));
        Promise.resolve().then(() => { alive(); return operation(); })
          .then(value => { try { alive(); resolve(value); } catch (error) { reject(error); } }, reject);
      });
    } finally { clearTimeout(timeout); }
  }
  const assertions = () => [guard(env.db, access, actor), currentGuard(env.db, actor, access, challenge),
    env.db.prepare(`SELECT json(CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_read_claims
      WHERE challenge_id=? AND read_receipt_id=? AND expires_at>unixepoch()) THEN 'true' ELSE 'denied' END)`)
      .bind(challenge.challenge_id, receiptId)];
  const current = async () => {
    alive();
    await step(() => env.db.batch(assertions()));
    const value = await step(() => source(env, challenge.case_reference_hmac, challenge.case_reference_hmac_key_version));
    if (await step(() => localModerationReviewSourceSHA256(value)) !== challenge.source_snapshot_sha256) fail();
    await step(() => env.db.batch(assertions())); alive();
    return value;
  };
  let jpeg: Uint8Array | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const snapshot = await current();
    const operation = host(Object.freeze({ source: snapshot, sourceSHA256: challenge.source_snapshot_sha256,
      signal: controller.signal, readCurrentSource: current,
      audit: async (phase: Phase) => {
        alive();
        if (phase !== "started" && phase !== "disclosure_ready") fail();
        await step(() => env.db.batch([...assertions(), env.db.prepare(`INSERT INTO moderation_owner_read_events(read_receipt_id,phase) VALUES (?,?)`)
          .bind(receiptId, phase)])); alive();
      },
    }));
    // A late host result is never disclosed; its owned buffer is erased.
    const owned = Promise.resolve(operation).then(value => {
      if (controller.signal.aborted || Date.now() >= deadline) { if (value instanceof Uint8Array) value.fill(0); fail(); }
      return value;
    });
    jpeg = await Promise.race([owned, new Promise<never>((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new OwnerError(503)); }, Math.max(1, deadline - Date.now()));
    })]);
    if (!(jpeg instanceof Uint8Array) || jpeg.byteLength < 4 || jpeg.byteLength > 1_048_576 - 98_304 - 28
        || jpeg[0] !== 0xff || jpeg[1] !== 0xd8 || jpeg.at(-2) !== 0xff || jpeg.at(-1) !== 0xd9) fail(503);
    await current();
    // Trusted decryptor delivery receipt, not a claim that the human saw or
    // understood the picture. A new signature confirms the actual decision.
    await step(() => env.db.batch([...assertions(), env.db.prepare(`INSERT INTO moderation_owner_read_receipts(read_receipt_id) VALUES (?)`).bind(receiptId)]));
    alive();
    return new Response(jpeg.slice().buffer, { headers: { "Cache-Control": "no-store", "Content-Type": "image/jpeg",
      "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
      "X-Moderation-Read-Receipt": receiptId, "X-Moderation-Source-SHA256": challenge.source_snapshot_sha256,
      "X-Moderation-Expires-At": String(Math.min(challenge.expires_at, Math.floor(deadline / 1000))) } });
  } catch (error) {
    try { await step(() => env.db.prepare(`INSERT INTO moderation_owner_read_events(read_receipt_id,phase) VALUES (?,'delivery_unknown')`).bind(receiptId).run()); }
    catch { /* Claim remains consumed; absence of a final receipt is unresolved. */ }
    throw error;
  } finally { controller.abort(); clearTimeout(timer); jpeg?.fill(0); }
}
async function prove(request: Request, env: LocalModerationOwnerEnvironment, access: AuthenticatedModerationOperatorAccess,
  actor: Actor, reference: string, version: number, receipt: string | undefined, id: string, host: LocalOwnerReviewHost): Promise<Response> {
  const challenge = await env.db.prepare(`SELECT * FROM moderation_owner_current_challenges
    WHERE challenge_id=? AND operator_id=? AND credential_id_sha256=? AND enrollment_admission_id=?
      AND access_session_sha256=? AND case_reference_hmac=? AND case_reference_hmac_key_version=?
      AND purpose=? AND read_receipt_id IS ?`)
    .bind(id, actor.operator_id, actor.credential_id_sha256, actor.enrollment_admission_id,
      access.accessSessionSHA256, reference, version, receipt === undefined ? "content_read" : "decision", receipt ?? null).first<Challenge>();
  if (!challenge) return fail();
  const prepared = await prepareModerationOperatorWebAuthnRequest(request, { expectedOrigin: env.origin,
    expectedRPID: env.rpId, expectedChallengeSHA256: challenge.challenge_value_sha256,
    credential: { credentialIdSHA256: actor.credential_id_sha256, publicKeyCose: new Uint8Array(actor.public_key_cose), counter: actor.sign_count } });
  await env.db.batch([guard(env.db, access, actor), currentGuard(env.db, actor, access, challenge),
    env.db.prepare(`INSERT INTO moderation_owner_assertion_attempts(challenge_id,assertion_sha256) VALUES (?,?)`).bind(id, prepared.assertionSHA256)]);
  const verified = await verifyPreparedModerationOperatorWebAuthnAssertion(prepared);
  const consume = env.db.prepare(`INSERT INTO moderation_owner_challenge_consumptions(challenge_id,verified_assertion_sha256,authenticator_sign_count) VALUES (?,?,?)`)
    .bind(id, verified.assertionSHA256, verified.newCounter);
  if (receipt === undefined) {
    const readReceiptId = crypto.randomUUID();
    // Claim commits before any key/object/host operation. Failed or unknown
    // disclosure cannot rewind the signature or retry this claim.
    await env.db.batch([guard(env.db, access, actor), currentGuard(env.db, actor, access, challenge), consume,
      env.db.prepare(`INSERT INTO moderation_owner_read_claims(challenge_id,read_receipt_id,expires_at)
        VALUES (?,?,MIN(unixepoch()+60,?))`).bind(id, readReceiptId, challenge.expires_at)]);
    return disclose(env, access, actor, challenge, readReceiptId, host);
  }
  const decisionId = crypto.randomUUID();
  await env.db.batch([guard(env.db, access, actor), currentGuard(env.db, actor, access, challenge), consume,
    env.db.prepare(`INSERT INTO moderation_owner_decisions(decision_id,challenge_id,case_reference_hmac) VALUES (?,?,?)`)
      .bind(decisionId, id, reference)]);
  return json({ caseReferenceHmac: reference, sourceSHA256: challenge.source_snapshot_sha256,
    decisionId, outcome: "no_action", reply: "draft_saved", sent: false });
}
/** Local composition entry only. Production Worker never imports this module.
 * Policy registration and real data transport are deliberately not HTTP APIs. */
export async function routeLocalModerationOwner(request: Request, env: LocalModerationOwnerEnvironment): Promise<Response> {
  if (env.runtimeEnabled !== "YES" || env.environment !== "local") return json({ error: "owner_runtime_disabled" }, 503);
  try {
    const url = new URL(request.url), match = pattern.exec(url.pathname);
    if (request.method === "GET" && url.origin === env.origin && url.search === ""
        && /^\/operator\/owner\/console\/[0-9a-f]{64}\/[1-9][0-9]{0,9}$/u.test(url.pathname)) return localModerationOwnerConsole();
    if (request.method !== "POST" || !match || Number(match[2]) > 2_147_483_647) return json({ error: "not_found" }, 404);
    const host = env.reviewEvidence;
    if (typeof host !== "function") return fail(503);
    let access: AuthenticatedModerationOperatorAccess;
    try { access = await authenticateCloudflareAccessRequest(request, env.access); } catch { return fail(401); }
    const origin = new URL(env.origin);
    if (origin.protocol !== "https:" || origin.origin !== env.origin || origin.hostname !== env.rpId
        || url.origin !== env.origin || url.search !== "" || request.headers.get("origin") !== env.origin) fail(403);
    if (!match[5] && request.body !== null) fail(400);
    const actor = await env.db.prepare(actorSQL).bind(access.operatorSubjectHmac, access.subjectHmacKeyVersion).first<Actor>();
    if (!actor) return fail(403);
    await env.db.batch([guard(env.db, access, actor),
      env.db.prepare("DELETE FROM moderation_owner_source_snapshots WHERE expires_at<=unixepoch()"),
      env.db.prepare("DELETE FROM moderation_owner_reply_outbox WHERE expires_at<=unixepoch()")]);
    if (!match[5]) return await issue(env, access, actor, match[1]!, Number(match[2]), match[4], url.pathname);
    return await prove(request, env, access, actor, match[1]!, Number(match[2]), match[4], match[5], host);
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    const status = error instanceof OwnerError ? error.status : /quota|rate exceeded|too many/u.test(message) ? 429
      : /constraint|denied|malformed JSON|not current|replay|expired|requires|counter/u.test(message) ? 409 : 503;
    return json({ error: "owner_review_unavailable" }, status);
  }
}
