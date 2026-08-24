import {
  activityStatement,
  authenticateSignedRequest,
  consumeNonce,
  consumeNonceAndTouch,
  nonceStatements,
  requireLiveSpace,
  type AuthenticatedMember,
} from "./auth";
import {
  base64urlDecode,
  base64urlEncode,
  randomBase64url,
  sha256Base64url,
  verifyEd25519,
} from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import {
  enforceRateLimit,
  parseJsonBody,
  readBody,
  requireEmptyBody,
  transientNetworkKey,
} from "./http";
import { idempotencyStatement, storedIdempotentResponse } from "./idempotency";
import {
  deviceRecoveryApprovalTranscript,
  deviceRecoveryClaimTranscript,
  deviceRecoverySignedRequestTranscript,
  ENVELOPE_ALGORITHM,
} from "./protocol";
import {
  binaryField,
  exactKeys,
  opaqueId,
  uuidField,
  type JsonRecord,
} from "./validation";

export const DEVICE_RECOVERY_PROTOCOL_VERSION = 2 as const;
export const DEVICE_RECOVERY_TTL_SECONDS = 15 * 60;
const expiryCleanupLimit = 1_000;

type RecoveryDatabaseState = "open" | "claimed" | "approved" | "consumed" | "expired";
type MemberRole = "owner" | "invitee";

interface RecoveryRow {
  recovery_id: string;
  space_id: string;
  recovery_state: RecoveryDatabaseState;
  recovery_proof_public_key: string | null;
  created_at: number;
  expires_at: number;
  claimed_at: number | null;
  approved_at: number | null;
  consumed_at: number | null;
  expected_membership_revision: number;
  expected_key_epoch: number;
  current_membership_revision: number;
  current_key_epoch: number;
  daily_boundary_minute_utc: number;
  space_state: "active" | "revoked";
  target_member_id: string;
  target_participant_id: string;
  target_role: MemberRole;
  target_member_state: "pending" | "active" | "revoked" | "expired";
  target_agreement_public_key: string;
  target_signing_public_key: string;
  target_moment_participant_id: string;
  target_device_id: string;
  initiator_member_id: string;
  initiator_participant_id: string;
  initiator_role: MemberRole;
  initiator_member_state: "pending" | "active" | "revoked" | "expired";
  initiator_agreement_public_key: string;
  initiator_signing_public_key: string;
  claim_client_request_id: string | null;
  claim_request_hash: string | null;
  proposed_device_id: string | null;
  proposed_agreement_public_key: string | null;
  proposed_signing_public_key: string | null;
  claim_transcript: string | null;
  claim_transcript_hash: string | null;
  envelope_algorithm: string | null;
  key_envelope: string | null;
  approval_signature: string | null;
  completion_client_request_id: string | null;
  completion_request_hash: string | null;
  completion_transcript_hash: string | null;
}

interface TargetRow {
  member_id: string;
  participant_id: string;
  role: MemberRole;
  member_state: "active";
  moment_participant_id: string;
  device_id: string;
  agreement_public_key: string;
  signing_public_key: string;
  membership_revision: number;
  key_epoch: number;
  active_device_count: number;
}

interface RecoveryAuthentication {
  body: Uint8Array;
  recovery: RecoveryRow;
  nonce: string;
  now: number;
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1_000);
}

function protocolVersion2(object: JsonRecord): void {
  if (object.protocolVersion !== DEVICE_RECOVERY_PROTOCOL_VERSION) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
}

async function safelyVerify(
  publicKey: string,
  signature: string,
  message: Uint8Array,
): Promise<boolean> {
  try {
    return await verifyEd25519(publicKey, signature, message);
  } catch {
    return false;
  }
}

function publicIdentity(fields: {
  memberId: string;
  participantId: string;
  role: MemberRole;
  agreementPublicKey: string;
  signingPublicKey: string;
  state: "pending" | "active" | "revoked" | "expired";
}): Record<string, unknown> {
  return {
    memberId: fields.memberId,
    participantId: fields.participantId,
    role: fields.role,
    agreementPublicKey: fields.agreementPublicKey,
    signingPublicKey: fields.signingPublicKey,
    state: fields.state,
  };
}

function targetIdentity(row: RecoveryRow): Record<string, unknown> {
  return publicIdentity({
    memberId: row.target_member_id,
    participantId: row.target_participant_id,
    role: row.target_role,
    agreementPublicKey: row.target_agreement_public_key,
    signingPublicKey: row.target_signing_public_key,
    state: row.target_member_state,
  });
}

function peerIdentity(row: RecoveryRow): Record<string, unknown> {
  return publicIdentity({
    memberId: row.initiator_member_id,
    participantId: row.initiator_participant_id,
    role: row.initiator_role,
    agreementPublicKey: row.initiator_agreement_public_key,
    signingPublicKey: row.initiator_signing_public_key,
    state: row.initiator_member_state,
  });
}

function replacementIdentity(row: RecoveryRow): Record<string, unknown> | null {
  if (
    row.proposed_agreement_public_key === null
    || row.proposed_signing_public_key === null
  ) return null;
  return publicIdentity({
    memberId: row.target_member_id,
    participantId: row.target_participant_id,
    role: row.target_role,
    agreementPublicKey: row.proposed_agreement_public_key,
    signingPublicKey: row.proposed_signing_public_key,
    state: row.recovery_state === "consumed" ? "active" : "pending",
  });
}

function publicRecoveryState(state: RecoveryDatabaseState): string {
  switch (state) {
    case "open": return "awaitingClaim";
    case "claimed": return "pendingApproval";
    case "approved": return "approvedAwaitingCompletion";
    case "consumed": return "active";
    case "expired": return "expired";
  }
}

async function loadRecovery(env: Env, recoveryID: string): Promise<RecoveryRow | null> {
  return env.DB.prepare(
    `SELECT recovery.id AS recovery_id, recovery.space_id,
            recovery.state AS recovery_state,
            recovery.recovery_proof_public_key,
            recovery.created_at, recovery.expires_at, recovery.claimed_at,
            recovery.approved_at, recovery.consumed_at,
            recovery.expected_membership_revision, recovery.expected_key_epoch,
            moment_space.membership_revision AS current_membership_revision,
            moment_space.current_key_epoch,
            space.daily_boundary_minute_utc, space.state AS space_state,
            target.id AS target_member_id,
            target.participant_id AS target_participant_id,
            target.role AS target_role, target.state AS target_member_state,
            recovery.target_agreement_public_key,
            recovery.target_signing_public_key,
            recovery.target_moment_participant_id,
            recovery.target_device_id,
            initiator.id AS initiator_member_id,
            initiator.participant_id AS initiator_participant_id,
            initiator.role AS initiator_role,
            initiator.state AS initiator_member_state,
            recovery.initiator_agreement_public_key,
            recovery.initiator_signing_public_key,
            claim.client_request_id AS claim_client_request_id,
            claim.request_hash AS claim_request_hash,
            claim.proposed_device_id,
            claim.agreement_public_key AS proposed_agreement_public_key,
            claim.signing_public_key AS proposed_signing_public_key,
            claim.transcript AS claim_transcript,
            claim.transcript_hash AS claim_transcript_hash,
            approval.envelope_algorithm, approval.key_envelope,
            approval.approval_signature,
            completion.client_request_id AS completion_client_request_id,
            completion.request_hash AS completion_request_hash,
            completion.transcript_hash AS completion_transcript_hash
       FROM device_recoveries AS recovery
       JOIN spaces AS space ON space.id = recovery.space_id
       JOIN moment_spaces AS moment_space ON moment_space.space_id = recovery.space_id
       JOIN members AS target ON target.id = recovery.target_member_id
       JOIN members AS initiator ON initiator.id = recovery.initiator_member_id
       JOIN moment_participants AS initiator_participant
         ON initiator_participant.legacy_member_id = initiator.id
        AND initiator_participant.space_id = recovery.space_id
       JOIN moment_devices AS initiator_device
         ON initiator_device.participant_id = initiator_participant.id
        AND initiator_device.legacy_member_id = initiator.id
       LEFT JOIN device_recovery_claim_events AS claim
         ON claim.recovery_id = recovery.id
       LEFT JOIN device_recovery_approval_events AS approval
         ON approval.recovery_id = recovery.id
       LEFT JOIN device_recovery_completion_events AS completion
         ON completion.recovery_id = recovery.id
      WHERE recovery.id = ?`,
  ).bind(recoveryID).first<RecoveryRow>();
}

function recoveryMetadata(row: RecoveryRow): Record<string, unknown> {
  return {
    id: row.recovery_id,
    state: publicRecoveryState(row.recovery_state),
    codePrefix: `NWR1.${row.recovery_id}`,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    membershipRevision: row.expected_membership_revision,
    keyEpoch: row.expected_key_epoch,
  };
}

function descriptorResponse(row: RecoveryRow): Record<string, unknown> {
  return {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recovery: recoveryMetadata(row),
    space: {
      id: row.space_id,
      dailyBoundaryMinuteUTC: row.daily_boundary_minute_utc,
    },
    target: targetIdentity(row),
    peer: peerIdentity(row),
  };
}

function statusResponse(row: RecoveryRow): Record<string, unknown> {
  const keyEnvelope = row.recovery_state === "approved"
    && row.envelope_algorithm !== null
    && row.key_envelope !== null
    && row.approval_signature !== null
    && row.approved_at !== null
    ? {
      algorithm: row.envelope_algorithm,
      ciphertext: row.key_envelope,
      approvalSignature: row.approval_signature,
      approvedAt: row.approved_at,
    }
    : null;
  return {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recovery: {
      ...recoveryMetadata(row),
      transcript: row.claim_transcript,
      transcriptHash: row.claim_transcript_hash,
      clientRequestId: row.claim_client_request_id,
      deviceId: row.proposed_device_id,
      keyEnvelope,
      recoveredAt: row.consumed_at,
    },
    space: {
      id: row.space_id,
      dailyBoundaryMinuteUTC: row.daily_boundary_minute_utc,
      currentMembershipRevision: row.current_membership_revision,
      currentKeyEpoch: row.current_key_epoch,
    },
    credential: replacementIdentity(row),
    peer: peerIdentity(row),
    previousTargetSigningPublicKey: row.target_signing_public_key,
    recoveredAt: row.consumed_at,
  };
}

function claimResponse(row: RecoveryRow): Record<string, unknown> {
  return statusResponse({ ...row, recovery_state: "claimed" });
}

export async function expireDeviceRecoveries(
  env: Env,
  now: number,
  scope?: { recoveryID?: string; spaceID?: string },
): Promise<void> {
  const scopePredicate = scope?.recoveryID !== undefined
    ? "recovery.id = ?"
    : scope?.spaceID !== undefined
      ? "recovery.space_id = ?"
      : "1 = 1";
  const values = scope?.recoveryID !== undefined
    ? [scope.recoveryID, now]
    : scope?.spaceID !== undefined
      ? [scope.spaceID, now]
      : [now];
  const limit = scope === undefined ? `LIMIT ${expiryCleanupLimit}` : "";
  const subquery = `SELECT recovery.id
                      FROM device_recoveries AS recovery
                      JOIN moment_spaces AS moment_space
                        ON moment_space.space_id = recovery.space_id
                     WHERE ${scopePredicate}
                       AND recovery.state IN ('open', 'claimed', 'approved')
                       AND (
                         recovery.expires_at <= ?
                         OR moment_space.membership_revision
                              <> recovery.expected_membership_revision
                         OR moment_space.current_key_epoch <> recovery.expected_key_epoch
                       )
                     ORDER BY recovery.expires_at ASC, recovery.id ASC ${limit}`;
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE device_recovery_approval_events
          SET key_envelope = NULL, approval_signature = NULL
        WHERE recovery_id IN (${subquery})`,
    ).bind(...values),
    env.DB.prepare(
      `UPDATE device_recovery_claim_events
          SET recovery_proof_signature = NULL, device_signature = NULL
        WHERE recovery_id IN (${subquery})`,
    ).bind(...values),
    env.DB.prepare(
      `UPDATE device_recoveries
          SET state = 'expired', recovery_proof_public_key = NULL
        WHERE id IN (${subquery})`,
    ).bind(...values),
    env.DB.prepare(
      "DELETE FROM device_recovery_request_nonces WHERE expires_at < ?",
    ).bind(now),
  ]);
}

async function signedMemberRequest(
  request: Request,
  env: Env,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-member"),
  );
  const body = await readBody(request, 16 * 1_024);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(403, "active_member_required", "An active peer is required.");
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}

async function targetForRecovery(
  env: Env,
  member: AuthenticatedMember,
  targetParticipantID: string,
): Promise<TargetRow | null> {
  return env.DB.prepare(
    `SELECT target.id AS member_id, target.participant_id, target.role,
            target.state AS member_state,
            participant.id AS moment_participant_id,
            device.id AS device_id,
            device.agreement_public_key, device.signing_public_key,
            moment_space.membership_revision,
            moment_space.current_key_epoch AS key_epoch,
            (SELECT COUNT(*) FROM moment_devices AS active_device
              WHERE active_device.participant_id = participant.id
                AND active_device.state = 'active') AS active_device_count
       FROM members AS target
       JOIN moment_participants AS participant
         ON participant.legacy_member_id = target.id
        AND participant.space_id = target.space_id
       JOIN moment_devices AS device
         ON device.participant_id = participant.id
        AND device.legacy_member_id = target.id
       JOIN moment_spaces AS moment_space ON moment_space.space_id = target.space_id
      WHERE target.space_id = ? AND target.participant_id = ?
        AND target.id <> ? AND target.state = 'active'
        AND participant.state = 'active' AND device.state = 'active'
        AND moment_space.state = 'active'`,
  ).bind(member.spaceId, targetParticipantID, member.id).first<TargetRow>();
}

export async function createDeviceRecovery(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedMemberRequest(request, env);
  let object: JsonRecord;
  let clientRequestID: string;
  let targetParticipantID: string;
  let recoveryProofPublicKey: string;
  try {
    object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion",
      "clientRequestId",
      "targetParticipantId",
      "recoveryProofPublicKey",
    ]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    targetParticipantID = binaryField(object, "targetParticipantId", 16);
    recoveryProofPublicKey = binaryField(object, "recoveryProofPublicKey", 32);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  const requestHash = await sha256Base64url(body);
  const replay = await storedIdempotentResponse(
    env,
    "create-device-recovery",
    member.id,
    clientRequestID,
    requestHash,
  );
  if (replay !== null) {
    await consumeNonceAndTouch(env, member);
    return replay;
  }
  await expireDeviceRecoveries(env, member.now, { spaceID: member.spaceId });
  const target = await targetForRecovery(env, member, targetParticipantID);
  if (target === null || target.active_device_count !== 1) {
    await consumeNonce(env, member);
    throw new ApiError(
      409,
      "recovery_target_unavailable",
      "The peer does not have exactly one replaceable active device.",
    );
  }
  const recoveryID = randomBase64url(16);
  const expiresAt = member.now + DEVICE_RECOVERY_TTL_SECONDS;
  const provisional = await env.DB.prepare(
    `SELECT space.daily_boundary_minute_utc,
            device.agreement_public_key AS initiator_agreement_public_key,
            device.signing_public_key AS initiator_signing_public_key
       FROM spaces AS space
       JOIN moment_participants AS participant
         ON participant.legacy_member_id = ? AND participant.space_id = space.id
       JOIN moment_devices AS device
         ON device.participant_id = participant.id AND device.legacy_member_id = ?
      WHERE space.id = ? AND space.state = 'active'
        AND participant.state = 'active' AND device.state = 'active'`,
  ).bind(member.id, member.id, member.spaceId).first<{
    daily_boundary_minute_utc: number;
    initiator_agreement_public_key: string;
    initiator_signing_public_key: string;
  }>();
  if (provisional === null) {
    await consumeNonce(env, member);
    throw new ApiError(409, "recovery_target_unavailable", "The recovery peer is unavailable.");
  }
  const responseBody = {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recovery: {
      id: recoveryID,
      state: "awaitingClaim",
      codePrefix: `NWR1.${recoveryID}`,
      createdAt: member.now,
      expiresAt,
      membershipRevision: target.membership_revision,
      keyEpoch: target.key_epoch,
    },
    space: {
      id: member.spaceId,
      dailyBoundaryMinuteUTC: provisional.daily_boundary_minute_utc,
    },
    target: publicIdentity({
      memberId: target.member_id,
      participantId: target.participant_id,
      role: target.role,
      agreementPublicKey: target.agreement_public_key,
      signingPublicKey: target.signing_public_key,
      state: "active",
    }),
    peer: publicIdentity({
      memberId: member.id,
      participantId: member.participantId,
      role: member.role,
      agreementPublicKey: provisional.initiator_agreement_public_key,
      signingPublicKey: provisional.initiator_signing_public_key,
      state: "active",
    }),
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO device_recoveries(
           id, space_id, initiator_member_id, target_member_id,
           target_moment_participant_id, target_device_id,
           expected_membership_revision, expected_key_epoch,
           target_agreement_public_key, target_signing_public_key,
           initiator_agreement_public_key, initiator_signing_public_key,
           recovery_proof_public_key, state, created_at, expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?)`,
      ).bind(
        recoveryID,
        member.spaceId,
        member.id,
        target.member_id,
        target.moment_participant_id,
        target.device_id,
        target.membership_revision,
        target.key_epoch,
        target.agreement_public_key,
        target.signing_public_key,
        provisional.initiator_agreement_public_key,
        provisional.initiator_signing_public_key,
        recoveryProofPublicKey,
        member.now,
        expiresAt,
      ),
      idempotencyStatement(
        env,
        "create-device-recovery",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        201,
        responseBody,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "create-device-recovery",
      member.id,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) {
      await consumeNonceAndTouch(env, member);
      return raced;
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "recovery_already_pending", "A recovery is already pending.");
  }
  return jsonResponse(responseBody, 201);
}

export async function getDeviceRecoveryDescriptor(
  request: Request,
  env: Env,
  recoveryIDValue: string,
): Promise<Response> {
  await enforceRateLimit(
    env,
    env.CREATE_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-descriptor"),
  );
  const body = await readBody(request);
  requireEmptyBody(body);
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  await expireDeviceRecoveries(env, nowSeconds(), { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  if (row === null || row.recovery_state !== "open") {
    throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  }
  return jsonResponse(descriptorResponse(row));
}

function claimFields(row: RecoveryRow, object: JsonRecord) {
  return {
    recoveryId: row.recovery_id,
    spaceId: row.space_id,
    dailyBoundaryMinuteUTC: row.daily_boundary_minute_utc,
    expiresAt: row.expires_at,
    membershipRevision: row.expected_membership_revision,
    keyEpoch: row.expected_key_epoch,
    targetMemberId: row.target_member_id,
    targetParticipantId: row.target_participant_id,
    targetRole: row.target_role,
    targetAgreementPublicKey: row.target_agreement_public_key,
    targetSigningPublicKey: row.target_signing_public_key,
    initiatorMemberId: row.initiator_member_id,
    initiatorParticipantId: row.initiator_participant_id,
    initiatorRole: row.initiator_role,
    initiatorAgreementPublicKey: row.initiator_agreement_public_key,
    initiatorSigningPublicKey: row.initiator_signing_public_key,
    clientRequestId: uuidField(object, "clientRequestId"),
    deviceId: binaryField(object, "deviceId", 16),
    agreementPublicKey: binaryField(object, "agreementPublicKey", 32),
    signingPublicKey: binaryField(object, "signingPublicKey", 32),
  };
}

export async function claimDeviceRecovery(
  request: Request,
  env: Env,
  recoveryIDValue: string,
): Promise<Response> {
  await enforceRateLimit(
    env,
    env.CREATE_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-claim"),
  );
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const body = await readBody(request, 16 * 1_024);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "deviceId",
    "agreementPublicKey",
    "signingPublicKey",
    "recoveryProofSignature",
    "deviceSignature",
  ]);
  protocolVersion2(object);
  const recoveryProofSignature = binaryField(object, "recoveryProofSignature", 64);
  const deviceSignature = binaryField(object, "deviceSignature", 64);
  const requestHash = await sha256Base64url(body);
  await expireDeviceRecoveries(env, nowSeconds(), { recoveryID });
  let row = await loadRecovery(env, recoveryID);
  if (row === null) throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  const fields = claimFields(row, object);
  if (row.claim_client_request_id !== null) {
    if (
      row.claim_client_request_id !== fields.clientRequestId
      || row.claim_request_hash !== requestHash
    ) {
      throw new ApiError(409, "recovery_already_claimed", "This recovery was already claimed.");
    }
    return jsonResponse(claimResponse(row), 201);
  }
  if (
    row.recovery_state !== "open"
    || row.recovery_proof_public_key === null
    || row.current_membership_revision !== row.expected_membership_revision
    || row.current_key_epoch !== row.expected_key_epoch
  ) {
    throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  }
  const transcript = deviceRecoveryClaimTranscript(fields);
  if (
    !(await safelyVerify(row.recovery_proof_public_key, recoveryProofSignature, transcript))
    || !(await safelyVerify(fields.signingPublicKey, deviceSignature, transcript))
  ) {
    throw new ApiError(401, "invalid_recovery_signature", "The recovery claim signature is invalid.");
  }
  const transcriptValue = base64urlEncode(transcript);
  const transcriptHash = await sha256Base64url(transcript);
  try {
    await env.DB.prepare(
      `INSERT INTO device_recovery_claim_events(
         recovery_id, client_request_id, request_hash, proposed_device_id,
         agreement_public_key, signing_public_key, transcript, transcript_hash,
         recovery_proof_signature, device_signature, created_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      recoveryID,
      fields.clientRequestId,
      requestHash,
      fields.deviceId,
      fields.agreementPublicKey,
      fields.signingPublicKey,
      transcriptValue,
      transcriptHash,
      recoveryProofSignature,
      deviceSignature,
      nowSeconds(),
    ).run();
  } catch {
    row = await loadRecovery(env, recoveryID);
    if (
      row !== null
      && row.claim_client_request_id === fields.clientRequestId
      && row.claim_request_hash === requestHash
    ) return jsonResponse(claimResponse(row), 201);
    throw new ApiError(409, "recovery_already_claimed", "This recovery cannot be claimed.");
  }
  row = await loadRecovery(env, recoveryID);
  if (row === null) throw new ApiError(409, "recovery_conflict", "The recovery claim was not retained.");
  return jsonResponse(claimResponse(row), 201);
}

export async function getPendingDeviceRecoveries(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedMemberRequest(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireDeviceRecoveries(env, member.now, { spaceID: member.spaceId });
  const ids = await env.DB.prepare(
    `SELECT id FROM device_recoveries
      WHERE initiator_member_id = ? AND space_id = ?
        AND state = 'claimed'
      ORDER BY created_at ASC`,
  ).bind(member.id, member.spaceId).all<{ id: string }>();
  const rows = await Promise.all(ids.results.map((entry) => loadRecovery(env, entry.id)));
  await consumeNonceAndTouch(env, member);
  return jsonResponse({
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    spaceId: member.spaceId,
    pending: rows.filter((row): row is RecoveryRow => row !== null).map(statusResponse),
  });
}

export async function approveDeviceRecovery(
  request: Request,
  env: Env,
  recoveryIDValue: string,
): Promise<Response> {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const { body, member } = await signedMemberRequest(request, env);
  let object: JsonRecord;
  let clientRequestID: string;
  let transcriptHash: string;
  let envelopeAlgorithm: string;
  let keyEnvelope: string;
  let approvalSignature: string;
  try {
    object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion",
      "clientRequestId",
      "transcriptHash",
      "envelopeAlgorithm",
      "keyEnvelope",
      "approvalSignature",
    ]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    transcriptHash = binaryField(object, "transcriptHash", 32);
    if (object.envelopeAlgorithm !== ENVELOPE_ALGORITHM) {
      throw new ApiError(400, "unsupported_envelope", "The key envelope algorithm is unsupported.");
    }
    envelopeAlgorithm = ENVELOPE_ALGORITHM;
    keyEnvelope = binaryField(object, "keyEnvelope", 60);
    approvalSignature = binaryField(object, "approvalSignature", 64);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  const requestHash = await sha256Base64url(body);
  const replay = await storedIdempotentResponse(
    env,
    "approve-device-recovery",
    member.id,
    clientRequestID,
    requestHash,
  );
  if (replay !== null) {
    await consumeNonceAndTouch(env, member);
    return replay;
  }
  await expireDeviceRecoveries(env, member.now, { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  if (
    row === null
    || row.initiator_member_id !== member.id
    || row.recovery_state !== "claimed"
    || row.claim_transcript_hash !== transcriptHash
    || row.proposed_device_id === null
    || row.current_membership_revision !== row.expected_membership_revision
    || row.current_key_epoch !== row.expected_key_epoch
  ) {
    await consumeNonce(env, member);
    throw new ApiError(409, "invalid_recovery_state", "The recovery cannot be approved.");
  }
  const signatureTranscript = deviceRecoveryApprovalTranscript({
    recoveryId: recoveryID,
    spaceId: row.space_id,
    targetMemberId: row.target_member_id,
    deviceId: row.proposed_device_id,
    membershipRevision: row.expected_membership_revision,
    keyEpoch: row.expected_key_epoch,
    transcriptHash,
    envelopeAlgorithm,
    keyEnvelope,
  });
  if (!(await safelyVerify(member.signingPublicKey, approvalSignature, signatureTranscript))) {
    await consumeNonce(env, member);
    throw new ApiError(401, "invalid_approval_signature", "The recovery approval signature is invalid.");
  }
  const responseBody = {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recoveryId: recoveryID,
    targetMemberId: row.target_member_id,
    deviceId: row.proposed_device_id,
    membershipRevision: row.expected_membership_revision,
    keyEpoch: row.expected_key_epoch,
    state: "approvedAwaitingCompletion",
    approvedAt: member.now,
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO device_recovery_approval_events(
           recovery_id, approver_member_id, client_request_id, request_hash,
           transcript_hash, envelope_algorithm, key_envelope,
           approval_signature, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        recoveryID,
        member.id,
        clientRequestID,
        requestHash,
        transcriptHash,
        envelopeAlgorithm,
        keyEnvelope,
        approvalSignature,
        member.now,
      ),
      idempotencyStatement(
        env,
        "approve-device-recovery",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        200,
        responseBody,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "approve-device-recovery",
      member.id,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) {
      await consumeNonceAndTouch(env, member);
      return raced;
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "invalid_recovery_state", "The recovery cannot be approved.");
  }
  return jsonResponse(responseBody);
}

function recoveryNonceStatements(
  env: Env,
  recoveryID: string,
  nonce: string,
  now: number,
): D1PreparedStatement[] {
  return [
    env.DB.prepare(
      "DELETE FROM device_recovery_request_nonces WHERE recovery_id = ? AND expires_at < ?",
    ).bind(recoveryID, now),
    env.DB.prepare(
      `INSERT INTO device_recovery_request_nonces(
         recovery_id, nonce, created_at, expires_at
       ) VALUES (?, ?, ?, ?)`,
    ).bind(recoveryID, nonce, now, now + 601),
  ];
}

async function consumeRecoveryNonce(
  env: Env,
  authentication: RecoveryAuthentication,
): Promise<void> {
  try {
    await env.DB.batch(recoveryNonceStatements(
      env,
      authentication.recovery.recovery_id,
      authentication.nonce,
      authentication.now,
    ));
  } catch {
    throw new ApiError(409, "replayed_request", "This recovery request nonce was already used.");
  }
}

async function authenticateRecoveryRequest(
  request: Request,
  env: Env,
  recoveryID: string,
): Promise<RecoveryAuthentication> {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-client"),
  );
  const body = await readBody(request, 16 * 1_024);
  if (
    request.headers.get("neko-protocol-version") !== "2"
    || request.headers.get("neko-member-id") !== recoveryID
  ) {
    throw new ApiError(401, "invalid_authentication", "Recovery request authentication failed.");
  }
  const timestampValue = request.headers.get("neko-timestamp") ?? "";
  const timestamp = Number(timestampValue);
  const nonce = request.headers.get("neko-nonce") ?? "";
  const signature = request.headers.get("neko-signature") ?? "";
  if (!Number.isSafeInteger(timestamp) || String(timestamp) !== timestampValue) {
    throw new ApiError(401, "invalid_authentication", "Recovery request authentication failed.");
  }
  try {
    base64urlDecode(nonce, 16);
    base64urlDecode(signature, 64);
  } catch {
    throw new ApiError(401, "invalid_authentication", "Recovery request authentication failed.");
  }
  const now = nowSeconds();
  if (Math.abs(now - timestamp) > 300) {
    throw new ApiError(401, "stale_request", "The recovery request timestamp is outside the five-minute window.");
  }
  const recovery = await loadRecovery(env, recoveryID);
  if (recovery === null || recovery.proposed_signing_public_key === null) {
    throw new ApiError(401, "invalid_authentication", "Recovery request authentication failed.");
  }
  const transcript = deviceRecoverySignedRequestTranscript({
    recoveryId: recoveryID,
    timestamp,
    nonce,
    method: request.method,
    pathname: new URL(request.url).pathname,
    bodySHA256: await sha256Base64url(body),
  });
  if (!(await safelyVerify(recovery.proposed_signing_public_key, signature, transcript))) {
    throw new ApiError(401, "invalid_authentication", "Recovery request authentication failed.");
  }
  return { body, recovery, nonce, now };
}

export async function getDeviceRecoveryStatus(
  request: Request,
  env: Env,
  recoveryIDValue: string,
): Promise<Response> {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const authentication = await authenticateRecoveryRequest(request, env, recoveryID);
  try {
    requireEmptyBody(authentication.body);
  } catch (error) {
    await consumeRecoveryNonce(env, authentication);
    throw error;
  }
  await expireDeviceRecoveries(env, authentication.now, { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  await consumeRecoveryNonce(env, authentication);
  if (row === null) throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  return jsonResponse(statusResponse(row));
}

export async function getSponsorDeviceRecoveryStatus(
  request: Request,
  env: Env,
  recoveryIDValue: string,
): Promise<Response> {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const { body, member } = await signedMemberRequest(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireDeviceRecoveries(env, member.now, { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  if (
    row === null
    || row.space_id !== member.spaceId
    || row.initiator_member_id !== member.id
    || row.proposed_device_id === null
  ) {
    await consumeNonce(env, member);
    throw new ApiError(404, "not_found", "device recovery was not found.");
  }
  await consumeNonceAndTouch(env, member);
  return jsonResponse(statusResponse(row));
}

export async function completeDeviceRecovery(
  request: Request,
  env: Env,
  recoveryIDValue: string,
): Promise<Response> {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const authentication = await authenticateRecoveryRequest(request, env, recoveryID);
  let object: JsonRecord;
  let clientRequestID: string;
  let transcriptHash: string;
  try {
    object = parseJsonBody(request, authentication.body);
    exactKeys(object, ["protocolVersion", "clientRequestId", "transcriptHash"]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    transcriptHash = binaryField(object, "transcriptHash", 32);
  } catch (error) {
    await consumeRecoveryNonce(env, authentication);
    throw error;
  }
  const requestHash = await sha256Base64url(authentication.body);
  await expireDeviceRecoveries(env, authentication.now, { recoveryID });
  let row = await loadRecovery(env, recoveryID);
  if (row === null) {
    await consumeRecoveryNonce(env, authentication);
    throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  }
  if (row.completion_client_request_id !== null) {
    await consumeRecoveryNonce(env, authentication);
    if (
      row.completion_client_request_id !== clientRequestID
      || row.completion_request_hash !== requestHash
      || row.completion_transcript_hash !== transcriptHash
    ) {
      throw new ApiError(409, "idempotency_conflict", "The completion key was used with another request.");
    }
    return jsonResponse(statusResponse(row));
  }
  if (
    row.recovery_state !== "approved"
    || row.claim_transcript_hash !== transcriptHash
    || row.current_membership_revision !== row.expected_membership_revision
    || row.current_key_epoch !== row.expected_key_epoch
  ) {
    await consumeRecoveryNonce(env, authentication);
    throw new ApiError(409, "invalid_recovery_state", "The recovery cannot be completed.");
  }
  try {
    await env.DB.batch([
      ...recoveryNonceStatements(env, recoveryID, authentication.nonce, authentication.now),
      env.DB.prepare(
        `INSERT INTO device_recovery_completion_events(
           recovery_id, client_request_id, request_hash, transcript_hash, created_at
         ) VALUES (?, ?, ?, ?, ?)`,
      ).bind(
        recoveryID,
        clientRequestID,
        requestHash,
        transcriptHash,
        authentication.now,
      ),
      env.DB.prepare(
        `UPDATE spaces SET last_activity_at = ?, metadata_expires_at = MAX(metadata_expires_at, ?)
          WHERE id = ? AND state = 'active'`,
      ).bind(
        authentication.now,
        authentication.now + 2_592_000,
        row.space_id,
      ),
    ]);
  } catch {
    row = await loadRecovery(env, recoveryID);
    if (
      row !== null
      && row.completion_client_request_id === clientRequestID
      && row.completion_request_hash === requestHash
      && row.completion_transcript_hash === transcriptHash
    ) {
      await consumeRecoveryNonce(env, authentication);
      return jsonResponse(statusResponse(row));
    }
    await consumeRecoveryNonce(env, authentication);
    throw new ApiError(409, "invalid_recovery_state", "The recovery cannot be completed.");
  }
  row = await loadRecovery(env, recoveryID);
  if (row === null || row.recovery_state !== "consumed") {
    throw new ApiError(409, "recovery_conflict", "The recovery completion was not retained.");
  }
  return jsonResponse(statusResponse(row));
}
