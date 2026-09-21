import { authenticateSignedRequest, consumeNonce, requireLiveSpace, requireOwner, type AuthenticatedMember } from "./auth";
import { authenticateBillingSignedRequest, consumeBillingNonce, type AuthenticatedBillingAccount } from "./billing-auth";
import { effectiveBillingEntitlement } from "./billing-entitlement";
import { billingEffectiveEntitlementRuntimeEnabled, billingWindowSponsorshipRuntimeEnabled, type Env } from "./env";
import { ApiError, jsonResponse } from "./errors";
import { sha256Base64url } from "./encoding";
import { enforceRateLimit, parseJsonBody, readBody, requireEmptyBody, transientNetworkKey } from "./http";
import { signedRequestTranscript } from "./protocol";
import { exactKeys, integerField, protocolVersion, uuidField } from "./validation";

interface Context {
  lineage_id: string; membership_revision: number; generation: number; billing_account_id: string | null;
}
interface SupportRequest {
  id: string; request_hash: string; space_id: string; window_lineage_id: string;
  requester_member_id: string; requester_participant_id: string; requester_device_id: string;
  billing_account_id: string; billing_key_id: string; membership_revision: number;
  expected_generation: number; expected_current_billing_account_id: string | null;
  created_at: number; expires_at: number;
  approval_id: string | null; approval_hash: string | null; owner_participant_id: string | null; owner_device_id: string | null;
  commit_id: string | null; commit_hash: string | null;
}
const unavailable = () => new ApiError(503, "window_support_unavailable", "Window support could not be verified.");
const conflict = () => new ApiError(409, "window_support_request_conflict", "This support request or its window changed.");
const expired = () => new ApiError(410, "window_support_request_expired", "This support request expired.");
function writeFailure(error: unknown): ApiError {
  // Constraint failures are determinate CAS/approval rejections. A transport or
  // database failure is not proof that this person's membership ended.
  return error instanceof Error && /SQLITE_CONSTRAINT/u.test(error.message) ? conflict() : unavailable();
}
const selectRequest = `SELECT r.*,a.client_request_id AS approval_id,a.request_hash AS approval_hash,
 a.owner_participant_id,a.owner_device_id,c.client_request_id AS commit_id,c.request_hash AS commit_hash
 FROM billing_window_support_requests r LEFT JOIN billing_window_support_approvals a ON a.request_id=r.id
 LEFT JOIN billing_window_support_commits c ON c.request_id=r.id`;

async function gate(env: Env): Promise<void> {
  if (!billingWindowSponsorshipRuntimeEnabled(env) || !billingEffectiveEntitlementRuntimeEnabled(env)) {
    throw new ApiError(503, "billing_runtime_disabled", "Billing is temporarily unavailable.");
  }
  const row = await env.DB.prepare("SELECT window_sponsorship_enabled,effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton=1")
    .first<{ window_sponsorship_enabled: number; effective_entitlement_enabled: number }>().catch(() => null);
  if (row?.window_sponsorship_enabled !== 1 || row.effective_entitlement_enabled !== 1) throw unavailable();
}
async function context(env: Env, member: AuthenticatedMember): Promise<Context> {
  requireLiveSpace(member);
  if (member.state !== "active") throw new ApiError(403, "active_member_required", "Active participation is required.");
  const row = await env.DB.prepare(`SELECT s.lineage_id,s.membership_revision,COALESCE(b.generation,0) AS generation,
    CASE WHEN b.state='active' THEN b.billing_account_id END AS billing_account_id
    FROM moment_spaces s JOIN spaces legacy ON legacy.id=s.space_id
    JOIN members m ON m.space_id=s.space_id JOIN moment_participants p ON p.legacy_member_id=m.id AND p.space_id=s.space_id
    JOIN moment_devices d ON d.participant_id=p.id
    LEFT JOIN billing_window_sponsorships b ON b.window_lineage_id=s.lineage_id
    WHERE s.space_id=? AND m.id=? AND p.id=? AND d.id=? AND s.state='active' AND legacy.state='active'
      AND m.state='active' AND p.state='active' AND d.state='active' AND m.role=? AND p.role=?
      AND NOT EXISTS(SELECT 1 FROM moment_blocks block WHERE block.space_id=s.space_id AND block.state='active')`)
    .bind(member.spaceId, member.id, member.momentParticipantId, member.deviceId, member.role, member.role === "owner" ? "owner" : "member")
    .first<Context>().catch(() => { throw unavailable(); });
  if (!row) throw new ApiError(410, "sharing_revoked", "This window is no longer available.");
  return row;
}
async function load(env: Env, id: string): Promise<SupportRequest | null> {
  return env.DB.prepare(`${selectRequest} WHERE r.id=?`).bind(id).first<SupportRequest>().catch(() => { throw unavailable(); });
}
function presentation(row: SupportRequest) {
  return { id: row.id, requesterMemberId: row.requester_member_id,
    state: row.commit_id ? "completed" : row.expires_at <= Math.floor(Date.now() / 1000) ? "expired" : row.approval_id ? "approved" : "pending",
    expectedGeneration: row.expected_generation, membershipRevision: row.membership_revision,
    createdAt: row.created_at, expiresAt: row.expires_at,
    resultingGeneration: row.commit_id ? row.expected_generation + 1 : null };
}
async function response(env: Env, member: AuthenticatedMember, row: SupportRequest, status = 200) {
  await context(env, member);
  return jsonResponse({ protocolVersion: 1, request: presentation(row) }, status);
}
function assertRequester(row: SupportRequest, member: AuthenticatedMember, payer: AuthenticatedBillingAccount) {
  if (row.space_id !== member.spaceId || row.requester_member_id !== member.id
    || row.requester_participant_id !== member.momentParticipantId || row.requester_device_id !== member.deviceId
    || row.billing_account_id !== payer.billingAccountId || row.billing_key_id !== payer.billingKeyId) throw conflict();
}
function assertCurrent(row: SupportRequest, current: Context) {
  if (row.expires_at <= Math.floor(Date.now() / 1000)) throw expired();
  if (row.window_lineage_id !== current.lineage_id || row.membership_revision !== current.membership_revision
    || row.expected_generation !== current.generation || row.expected_current_billing_account_id !== current.billing_account_id) throw conflict();
}
async function requireEligiblePayer(env: Env, accountID: string) {
  const entitlement = await effectiveBillingEntitlement(env, accountID).catch(() => { throw unavailable(); });
  if (entitlement.grantsPlus) return;
  if (entitlement.status === "unconfirmed") throw unavailable();
  throw new ApiError(403, "plus_entitlement_required", "An active membership is required.");
}
async function requireResumeNeeded(env: Env, current: Context) {
  if (!current.billing_account_id) return;
  const entitlement = await effectiveBillingEntitlement(env, current.billing_account_id).catch(() => { throw unavailable(); });
  if (entitlement.grantsPlus) throw new ApiError(409, "window_support_already_active", "This window already has active support.");
  if (entitlement.status === "unconfirmed") throw unavailable();
}
async function recheck(env: Env, row: SupportRequest, member: AuthenticatedMember) {
  await gate(env);
  const current = await context(env, member);
  assertCurrent(row, current);
  await requireEligiblePayer(env, row.billing_account_id);
  await requireResumeNeeded(env, current);
}

/** Explicit exchange only. No key, billing identity or receipt is disclosed to a peer. */
export async function windowSupportRequests(request: Request, env: Env, requestID?: string, action?: string): Promise<Response> {
  await gate(env);
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "window-support-request"));
  if (request.method !== "GET") await enforceRateLimit(env, env.BILLING_RATE_LIMITER, transientNetworkKey(request, "window-support-request-write"));
  const body = await readBody(request, 2048);
  const member = await authenticateSignedRequest(request, env, body);
  await consumeNonce(env, member);
  const current = await context(env, member);
  if (request.method === "GET" && action === undefined) {
    requireEmptyBody(body);
    if (requestID === undefined) {
      const rows = await env.DB.prepare(`${selectRequest} WHERE r.space_id=? AND (?='owner' OR r.requester_member_id=?)
        AND ((c.request_id IS NOT NULL AND r.expected_generation+1=?)
          OR (c.request_id IS NULL AND r.expires_at>unixepoch() AND r.membership_revision=? AND r.expected_generation=?))
        ORDER BY (c.request_id IS NOT NULL),r.created_at DESC,r.id LIMIT 32`)
        .bind(member.spaceId, member.role, member.id, current.generation, current.membership_revision, current.generation).all<SupportRequest>()
        .catch(() => { throw unavailable(); });
      await context(env, member);
      return jsonResponse({ protocolVersion: 1, requests: rows.results.map(presentation) });
    }
    const row = await load(env, requestID);
    if (!row || row.space_id !== member.spaceId || (member.role !== "owner" && row.requester_member_id !== member.id)) {
      throw new ApiError(404, "not_found", "Support request not found.");
    }
    return response(env, member, row);
  }
  if (request.method !== "POST" || (action !== undefined && action !== "approve" && action !== "commit")) {
    throw new ApiError(404, "not_found", "Support request route not found.");
  }
  const object = parseJsonBody(request, body);
  exactKeys(object, requestID === undefined
    ? ["protocolVersion", "clientRequestId", "billingAccountId", "requesterMemberId", "expectedGeneration"] : ["protocolVersion", "clientRequestId"]);
  protocolVersion(object);
  const operationID = uuidField(object, "clientRequestId");
  const hash = await sha256Base64url(body);
  let payer: AuthenticatedBillingAccount | undefined;
  if (requestID === undefined || action === "commit") {
    payer = await authenticateBillingSignedRequest(request, env, body);
    await consumeBillingNonce(env, payer);
  }
  if (requestID === undefined) {
    if (uuidField(object, "billingAccountId") !== payer!.billingAccountId || object.requesterMemberId !== member.id) throw conflict();
    const expectedGeneration = integerField(object, "expectedGeneration", 0, 1_000_000_000);
    const prior = await load(env, operationID);
    if (prior) {
      assertRequester(prior, member, payer!);
      if (prior.request_hash !== hash) throw conflict();
      return response(env, member, prior, 201);
    }
    if (expectedGeneration !== current.generation) throw conflict();
    await requireEligiblePayer(env, payer!.billingAccountId);
    await requireResumeNeeded(env, current);
    try {
      await env.DB.prepare(`INSERT INTO billing_window_support_requests(id,request_hash,space_id,window_lineage_id,
        requester_member_id,requester_participant_id,requester_device_id,billing_account_id,billing_key_id,
        membership_revision,expected_generation,expected_current_billing_account_id,expires_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,unixepoch()+300)`)
        .bind(operationID, hash, member.spaceId, current.lineage_id, member.id, member.momentParticipantId, member.deviceId,
          payer!.billingAccountId, payer!.billingKeyId, current.membership_revision, expectedGeneration, current.billing_account_id).run();
    } catch (error) {
      const raced = await load(env, operationID).catch(() => { throw unavailable(); });
      if (raced) { assertRequester(raced, member, payer!); if (raced.request_hash === hash) return response(env, member, raced, 201); }
      await gate(env);
      await requireEligiblePayer(env, payer!.billingAccountId);
      await requireResumeNeeded(env, await context(env, member));
      throw writeFailure(error);
    }
    const created = await load(env, operationID);
    if (!created) throw unavailable();
    return response(env, member, created, 201);
  }
  const row = await load(env, requestID);
  if (!row || row.space_id !== member.spaceId) throw new ApiError(404, "not_found", "Support request not found.");
  if (action === "approve") {
    requireOwner(member);
    if (row.approval_id) {
      if (row.approval_id !== operationID || row.approval_hash !== hash || row.owner_participant_id !== member.momentParticipantId
        || row.owner_device_id !== member.deviceId) throw conflict();
      return response(env, member, row);
    }
  } else if (action === "commit") {
    assertRequester(row, member, payer!);
    if (row.commit_id) {
      if (row.commit_id !== operationID || row.commit_hash !== hash) throw conflict();
      return response(env, member, row);
    }
    if (!row.approval_id) throw conflict();
  } else throw new ApiError(404, "not_found", "Support request route not found.");
  await recheck(env, row, member);
  try {
    if (action === "approve") {
      const transcript = signedRequestTranscript({ memberId: member.id, timestamp: Number(request.headers.get("neko-timestamp")),
        nonce: member.nonce, method: request.method, pathname: new URL(request.url).pathname, bodySHA256: hash });
      await env.DB.prepare(`INSERT INTO billing_window_support_approvals(request_id,client_request_id,request_hash,
        owner_participant_id,owner_device_id,consent_nonce_hash,consent_hash) VALUES(?,?,?,?,?,?,?)`)
        .bind(row.id, operationID, hash, member.momentParticipantId, member.deviceId,
          await sha256Base64url(new TextEncoder().encode(member.nonce)), await sha256Base64url(transcript)).run();
    } else {
      // The trigger applies the existing sponsorship audit/CAS in this same
      // statement. There is never an unsponsored interval during replacement.
      await env.DB.prepare("INSERT INTO billing_window_support_commits(request_id,client_request_id,request_hash) VALUES(?,?,?)")
        .bind(row.id, operationID, hash).run();
    }
  } catch (error) {
    const raced = await load(env, row.id).catch(() => { throw unavailable(); });
    const identical = action === "approve" ? raced?.approval_id === operationID && raced.approval_hash === hash
      && raced.owner_participant_id === member.momentParticipantId && raced.owner_device_id === member.deviceId
      : raced?.commit_id === operationID && raced.commit_hash === hash;
    if (raced && identical) return response(env, member, raced);
    await recheck(env, row, member);
    if (action === "commit" && error instanceof Error && /sponsorship limit reached/u.test(error.message)) {
      const limit = await env.DB.prepare(`SELECT COUNT(*) AS n FROM billing_window_sponsorships
        WHERE billing_account_id=? AND state='active' AND window_lineage_id<>?`)
        .bind(row.billing_account_id, row.window_lineage_id).first<{ n: number }>().catch(() => { throw unavailable(); });
      if (limit && limit.n >= 3) throw new ApiError(409, "window_sponsorship_limit_reached", "This membership already supports three windows.");
    }
    throw writeFailure(error);
  }
  const result = await load(env, row.id);
  if (!result) throw unavailable();
  return response(env, member, result);
}
