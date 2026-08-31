import {
  authenticateSignedRequest,
  consumeNonce,
  requireLiveSpace,
  requireOwner,
} from "./auth";
import {
  authenticateBillingSignedRequest,
  consumeBillingNonce,
} from "./billing-auth";
import { effectiveBillingEntitlement } from "./billing-entitlement";
import { windowSponsorshipConsentTranscript } from "./billing-protocol";
import { sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import {
  enforceRateLimit,
  parseJsonBody,
  readBody,
  requireEmptyBody,
  transientNetworkKey,
} from "./http";
import {
  binaryField,
  exactKeys,
  integerField,
  opaqueId,
  protocolVersion,
  stringField,
  uuidField,
} from "./validation";

interface Gate {
  window_sponsorship_enabled: 0 | 1;
  effective_entitlement_enabled: 0 | 1;
}
interface Owner {
  signing_public_key: string;
}
interface EntRef {
  decision_id: string;
  request_generation: number;
  evaluated_at_ms: number;
}
interface Existing {
  request_hash: string;
  billing_account_id: string;
  window_lineage_id: string;
  operation: "sponsor" | "unsponsor";
  resulting_generation: number;
  recorded_at: number;
}
interface OwnerDetachExisting {
  request_hash: string;
  window_lineage_id: string;
  space_id: string;
  owner_participant_id: string;
  owner_device_id: string;
  resulting_generation: number;
  recorded_at: number;
}
interface OwnerDetachContext {
  window_lineage_id: string;
  membership_revision: number;
  billing_account_id: string;
  state: "active" | "unsponsored";
  generation: number;
}
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

async function existing(env: Env, id: string) {
  return env.DB.prepare(
    `SELECT request_hash,billing_account_id,window_lineage_id,operation,resulting_generation,recorded_at FROM billing_window_sponsorship_requests WHERE client_request_id=?`,
  )
    .bind(id)
    .first<Existing>();
}
function response(id: string, row: Existing) {
  return jsonResponse({
    protocolVersion: 1,
    clientRequestId: id,
    billingAccountId: row.billing_account_id,
    windowLineageId: row.window_lineage_id,
    state: row.operation === "sponsor" ? "active" : "unsponsored",
    generation: row.resulting_generation,
    recordedAt: row.recorded_at,
  });
}

async function existingOwnerDetach(env: Env, id: string) {
  return env.DB.prepare(
    `SELECT request_hash,window_lineage_id,space_id,owner_participant_id,
            owner_device_id,resulting_generation,recorded_at
       FROM billing_window_sponsorship_owner_detach_requests
      WHERE client_request_id=?`,
  )
    .bind(id)
    .first<OwnerDetachExisting>();
}

function ownerDetachResponse(id: string, row: OwnerDetachExisting) {
  return jsonResponse({
    protocolVersion: 1,
    clientRequestId: id,
    windowLineageSponsored: false,
    generation: row.resulting_generation,
    recordedAt: row.recorded_at,
  });
}

export async function changeWindowSponsorship(
  request: Request,
  env: Env,
  lineageValue: string,
): Promise<Response> {
  const gate = await env.DB.prepare(
    "SELECT window_sponsorship_enabled,effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton=1",
  )
    .first<Gate>()
    .catch(() => null);
  if (gate?.window_sponsorship_enabled !== 1)
    throw new ApiError(
      503,
      "billing_runtime_disabled",
      "Billing is temporarily unavailable.",
    );
  await enforceRateLimit(
    env,
    env.BILLING_RATE_LIMITER,
    transientNetworkKey(request, "billing-window-sponsorship"),
  );
  const windowLineageId = opaqueId(lineageValue, "window lineage");
  const operation =
    request.method === "PUT" ? ("sponsor" as const) : ("unsponsor" as const);
  const body = await readBody(request, 4096);
  const value = parseJsonBody(request, body);
  exactKeys(
    value,
    operation === "sponsor"
      ? [
          "protocolVersion",
          "clientRequestId",
          "expectedGeneration",
          "expectedCurrentBillingAccountId",
          "consentSpaceId",
          "ownerParticipantId",
          "ownerDeviceId",
          "consentMembershipRevision",
          "consentIssuedAt",
          "ownerConsentNonce",
          "ownerConsentSignature",
        ]
      : [
          "protocolVersion",
          "clientRequestId",
          "expectedGeneration",
          "expectedCurrentBillingAccountId",
        ],
  );
  protocolVersion(value);
  const clientRequestId = uuidField(value, "clientRequestId");
  const expectedGeneration = integerField(
    value,
    "expectedGeneration",
    0,
    1_000_000_000,
  );
  const expectedRaw = value.expectedCurrentBillingAccountId;
  if (
    expectedRaw !== null &&
    (typeof expectedRaw !== "string" || !uuid.test(expectedRaw))
  )
    throw new ApiError(
      400,
      "invalid_field",
      "expectedCurrentBillingAccountId is invalid.",
    );
  const expectedCurrentBillingAccountId = expectedRaw as string | null;
  const account = await authenticateBillingSignedRequest(request, env, body);
  await consumeBillingNonce(env, account);
  let consentSpaceId: string | undefined,
    ownerParticipantId: string | undefined,
    ownerDeviceId: string | undefined,
    ownerConsentSignature: string | undefined,
    ownerConsentNonce: string | undefined,
    consentIssuedAt: number | undefined,
    consentMembershipRevision: number | undefined;
  if (operation === "sponsor") {
    consentSpaceId = opaqueId(stringField(value, "consentSpaceId"), "space");
    ownerParticipantId = opaqueId(
      stringField(value, "ownerParticipantId"),
      "owner participant",
    );
    ownerDeviceId = opaqueId(
      stringField(value, "ownerDeviceId"),
      "owner device",
    );
    consentMembershipRevision = integerField(
      value,
      "consentMembershipRevision",
      1,
      1_000_000_000,
    );
    consentIssuedAt = integerField(
      value,
      "consentIssuedAt",
      1,
      Number.MAX_SAFE_INTEGER,
    );
    ownerConsentNonce = binaryField(value, "ownerConsentNonce", 16);
    ownerConsentSignature = binaryField(value, "ownerConsentSignature", 64);
  }
  const transcript = windowSponsorshipConsentTranscript({
    operation,
    clientRequestId,
    billingAccountId: account.billingAccountId,
    windowLineageId,
    expectedGeneration,
    expectedCurrentBillingAccountId:
      expectedCurrentBillingAccountId ?? undefined,
    consentSpaceId,
    ownerParticipantId,
    ownerDeviceId,
    consentIssuedAt,
    consentMembershipRevision,
    ownerConsentNonce,
  });
  const requestHash = await sha256Base64url(body);
  const replay = await existing(env, clientRequestId);
  if (replay !== null) {
    if (
      replay.request_hash !== requestHash ||
      replay.billing_account_id !== account.billingAccountId ||
      replay.window_lineage_id !== windowLineageId ||
      replay.operation !== operation
    )
      throw new ApiError(
        409,
        "sponsorship_request_conflict",
        "The sponsorship request ID was already used.",
      );
    return response(clientRequestId, replay);
  }
  let entitlement: EntRef | null = null;
  if (operation === "sponsor") {
    if (gate.effective_entitlement_enabled !== 1)
      throw new ApiError(
        503,
        "billing_runtime_disabled",
        "Billing is temporarily unavailable.",
      );
    if (
      !(await effectiveBillingEntitlement(env, account.billingAccountId))
        .grantsPlus
    )
      throw new ApiError(
        403,
        "plus_entitlement_required",
        "An active Plus subscription is required.",
      );
    entitlement = await env.DB.prepare(
      `SELECT decision_id,request_generation,evaluated_at_ms FROM billing_effective_entitlement_current WHERE billing_account_id=? AND materialized_grants_plus=1 AND ownership_type='PURCHASED' AND materialized_status IN('active','gracePeriod') AND revocation_date_ms IS NULL AND revocation_reason IS NULL AND is_upgraded=0 AND access_until_ms>? AND authority_stale_at_ms>? ORDER BY MIN(access_until_ms,authority_stale_at_ms) DESC,original_transaction_id ASC LIMIT 1`,
    )
      .bind(account.billingAccountId, Date.now(), Date.now())
      .first<EntRef>();
    if (entitlement === null)
      throw new ApiError(
        403,
        "plus_entitlement_required",
        "An active Plus subscription is required.",
      );
    if (Math.abs(account.now - consentIssuedAt!) > 300)
      throw new ApiError(
        400,
        "stale_owner_consent",
        "The owner approval has expired.",
      );
    const owner = await env.DB.prepare(
      `SELECT d.signing_public_key FROM moment_spaces s JOIN moment_participants p ON p.space_id=s.space_id JOIN moment_devices d ON d.participant_id=p.id WHERE s.space_id=? AND s.lineage_id=? AND s.state='active' AND s.membership_revision=? AND p.id=? AND p.role='owner' AND p.state='active' AND d.id=? AND d.state='active' AND NOT EXISTS(SELECT 1 FROM moment_blocks b WHERE b.space_id=s.space_id AND b.state='active')`,
    )
      .bind(
        consentSpaceId!,
        windowLineageId,
        consentMembershipRevision!,
        ownerParticipantId!,
        ownerDeviceId!,
      )
      .first<Owner>();
    let valid = false;
    try {
      valid =
        owner !== null &&
        (await verifyEd25519(
          owner.signing_public_key,
          ownerConsentSignature!,
          transcript,
        ));
    } catch {
      valid = false;
    }
    if (!valid)
      throw new ApiError(
        403,
        "owner_consent_required",
        "The current window owner must approve sponsorship.",
      );
  }
  const resultingGeneration = expectedGeneration + 1;
  try {
    await env.DB.prepare(
      `INSERT INTO billing_window_sponsorship_requests(client_request_id,request_hash,operation,billing_account_id,submitted_by_billing_key_id,window_lineage_id,expected_generation,expected_current_billing_account_id,consent_space_id,owner_participant_id,owner_device_id,consent_membership_revision,consent_issued_at,owner_consent_nonce_hash,owner_consent_hash,entitlement_decision_id,entitlement_request_generation,entitlement_evaluated_at_ms,resulting_generation) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
    )
      .bind(
        clientRequestId,
        requestHash,
        operation,
        account.billingAccountId,
        account.billingKeyId,
        windowLineageId,
        expectedGeneration,
        expectedCurrentBillingAccountId,
        consentSpaceId ?? null,
        ownerParticipantId ?? null,
        ownerDeviceId ?? null,
        consentMembershipRevision ?? null,
        consentIssuedAt ?? null,
        ownerConsentNonce === undefined
          ? null
          : await sha256Base64url(new TextEncoder().encode(ownerConsentNonce)),
        operation === "sponsor" ? await sha256Base64url(transcript) : null,
        entitlement?.decision_id ?? null,
        entitlement?.request_generation ?? null,
        entitlement?.evaluated_at_ms ?? null,
        resultingGeneration,
      )
      .run();
  } catch {
    const raced = await existing(env, clientRequestId);
    if (
      raced !== null &&
      raced.request_hash === requestHash &&
      raced.billing_account_id === account.billingAccountId &&
      raced.window_lineage_id === windowLineageId &&
      raced.operation === operation
    )
      return response(clientRequestId, raced);
    throw new ApiError(
      409,
      "sponsorship_conflict",
      "Window sponsorship changed concurrently.",
    );
  }
  const applied = await existing(env, clientRequestId);
  if (applied === null)
    throw new ApiError(
      503,
      "sponsorship_unavailable",
      "Sponsorship is temporarily unavailable.",
    );
  return response(clientRequestId, applied);
}

export async function detachWindowSponsorshipAsOwner(
  request: Request,
  env: Env,
): Promise<Response> {
  const gate = await env.DB.prepare(
    "SELECT window_sponsorship_enabled,effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton=1",
  )
    .first<Gate>()
    .catch(() => null);
  if (gate?.window_sponsorship_enabled !== 1)
    throw new ApiError(
      503,
      "billing_runtime_disabled",
      "Billing is temporarily unavailable.",
    );
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "window-sponsorship-owner-detach"),
  );
  const body = await readBody(request, 512);
  const value = parseJsonBody(request, body);
  exactKeys(value, [
    "protocolVersion",
    "clientRequestId",
    "expectedGeneration",
  ]);
  protocolVersion(value);
  const clientRequestId = uuidField(value, "clientRequestId");
  const expectedGeneration = integerField(
    value,
    "expectedGeneration",
    1,
    1_000_000_000,
  );
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireOwner(member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await consumeNonce(env, member);
  const requestHash = await sha256Base64url(body);
  const replay = await existingOwnerDetach(env, clientRequestId);
  if (replay !== null) {
    if (
      replay.request_hash !== requestHash ||
      replay.space_id !== member.spaceId ||
      replay.owner_participant_id !== member.momentParticipantId ||
      replay.owner_device_id !== member.deviceId
    )
      throw new ApiError(
        409,
        "sponsorship_request_conflict",
        "The sponsorship request ID was already used.",
      );
    return ownerDetachResponse(clientRequestId, replay);
  }
  const current = await env.DB.prepare(
    `SELECT space.lineage_id AS window_lineage_id,
            space.membership_revision,
            sponsorship.billing_account_id,
            sponsorship.state,
            sponsorship.generation
       FROM moment_spaces space
       JOIN billing_window_sponsorships sponsorship
         ON sponsorship.window_lineage_id=space.lineage_id
      WHERE space.space_id=?
        AND space.state='active'
        AND sponsorship.state='active'
        AND NOT EXISTS(
          SELECT 1 FROM moment_blocks block
           WHERE block.space_id=space.space_id AND block.state='active'
        )`,
  )
    .bind(member.spaceId)
    .first<OwnerDetachContext>();
  if (current === null || current.generation !== expectedGeneration)
    throw new ApiError(
      409,
      "sponsorship_conflict",
      "Window sponsorship changed concurrently.",
    );
  try {
    await env.DB.prepare(
      `INSERT INTO billing_window_sponsorship_owner_detach_requests(
         client_request_id,request_hash,window_lineage_id,space_id,
         owner_participant_id,owner_device_id,membership_revision,
         expected_generation,expected_billing_account_id,resulting_generation
       ) VALUES(?,?,?,?,?,?,?,?,?,?)`,
    )
      .bind(
        clientRequestId,
        requestHash,
        current.window_lineage_id,
        member.spaceId,
        member.momentParticipantId,
        member.deviceId,
        current.membership_revision,
        expectedGeneration,
        current.billing_account_id,
        expectedGeneration + 1,
      )
      .run();
  } catch {
    const raced = await existingOwnerDetach(env, clientRequestId);
    if (
      raced !== null &&
      raced.request_hash === requestHash &&
      raced.space_id === member.spaceId &&
      raced.owner_participant_id === member.momentParticipantId &&
      raced.owner_device_id === member.deviceId
    )
      return ownerDetachResponse(clientRequestId, raced);
    throw new ApiError(
      409,
      "sponsorship_conflict",
      "Window sponsorship changed concurrently.",
    );
  }
  const applied = await existingOwnerDetach(env, clientRequestId);
  if (applied === null)
    throw new ApiError(
      503,
      "sponsorship_unavailable",
      "Sponsorship is temporarily unavailable.",
    );
  return ownerDetachResponse(clientRequestId, applied);
}

export async function getWindowSponsorshipGrant(
  request: Request,
  env: Env,
): Promise<Response> {
  const gate = await env.DB.prepare(
    "SELECT window_sponsorship_enabled,effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton=1",
  )
    .first<Gate>()
    .catch(() => null);
  if (
    gate?.window_sponsorship_enabled !== 1 ||
    gate.effective_entitlement_enabled !== 1
  )
    throw new ApiError(
      503,
      "billing_runtime_disabled",
      "Billing is temporarily unavailable.",
    );
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "window-sponsorship-grant"),
  );
  const body = await readBody(request, 0);
  requireEmptyBody(body);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(
        403,
        "active_member_required",
        "Pairing must be complete before accessing the window sponsorship.",
      );
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await consumeNonce(env, member);
  const now = Date.now();
  const row = await env.DB.prepare(
    `SELECT space.lineage_id AS window_lineage_id,
    space.membership_revision,
    sponsorship.state,sponsorship.generation,
   MAX(CASE WHEN current.materialized_grants_plus=1 AND current.ownership_type='PURCHASED'
     AND current.materialized_status IN('active','gracePeriod') AND current.revocation_date_ms IS NULL
     AND current.revocation_reason IS NULL AND current.is_upgraded=0 AND current.access_until_ms>?
     AND current.authority_stale_at_ms>? THEN MIN(current.access_until_ms,current.authority_stale_at_ms) END) AS access_until_ms
  FROM moment_spaces space
  LEFT JOIN billing_window_sponsorships sponsorship ON sponsorship.window_lineage_id=space.lineage_id
  LEFT JOIN billing_effective_entitlement_current current ON current.billing_account_id=sponsorship.billing_account_id
 WHERE space.space_id=? AND space.state='active'
   AND NOT EXISTS(SELECT 1 FROM moment_blocks block WHERE block.space_id=space.space_id AND block.state='active')
 GROUP BY space.lineage_id,space.membership_revision,sponsorship.state,sponsorship.generation`,
  )
    .bind(now, now, member.spaceId)
    .first<{
      window_lineage_id: string;
      membership_revision: number;
      state: "active" | "unsponsored" | null;
      generation: number | null;
      access_until_ms: number | null;
    }>();
  const sponsored = row?.state === "active",
    grantsPlus =
      sponsored &&
      row?.access_until_ms !== null &&
      row?.access_until_ms !== undefined;
  const ownerConsentContext =
    member.role === "owner" && row !== null
      ? {
          windowLineageId: row.window_lineage_id,
          membershipRevision: row.membership_revision,
        }
      : undefined;
  return jsonResponse({
    protocolVersion: 1,
    windowLineageSponsored: sponsored,
    grantsPlus,
    generation: row?.generation ?? 0,
    accessUntilMs: grantsPlus ? row!.access_until_ms : null,
    evaluatedAtMs: now,
    ...(ownerConsentContext === undefined ? {} : { ownerConsentContext }),
  });
}
