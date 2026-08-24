import {
  authenticateSignedRequest,
  activityStatement,
  consumeNonce,
  consumeNonceAndTouch,
  nonceStatements,
  requireLiveSpace,
  requireOwner,
  requirePendingInvitee,
  type AuthenticatedMember,
} from "./auth";
import {
  base64urlEncode,
  randomBase64url,
  sha256Base64url,
  verifyEd25519,
} from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { positiveIntegerSetting } from "./env";
import {
  enforceRateLimit,
  parseJsonBody,
  readBody,
  requireEmptyBody,
  transientNetworkKey,
} from "./http";
import {
  idempotencyStatement,
  storedIdempotentResponse,
} from "./idempotency";
import {
  approvalTranscript,
  creationTranscript,
  enrollmentTranscript,
  ENVELOPE_ALGORITHM,
  pairingTranscript,
  PROTOCOL_VERSION,
} from "./protocol";
import {
  binaryField,
  exactKeys,
  integerField,
  opaqueId,
  protocolVersion,
  stringField,
  uuidField,
} from "./validation";

interface InvitationRow {
  invitation_id: string;
  space_id: string;
  invitation_status: "open" | "consumed" | "revoked" | "expired";
  invitation_expires_at: number;
  invite_proof_public_key: string | null;
  daily_boundary_minute_utc: number;
  space_state: "active" | "revoked";
  inviter_member_id: string;
  inviter_participant_id: string;
  inviter_agreement_public_key: string;
  inviter_signing_public_key: string;
}

interface ChallengeRow extends InvitationRow {
  challenge_id: string;
  challenge_value: string;
  challenge_expires_at: number;
  challenge_consumed_at: number | null;
}

interface EnrollmentRow {
  enrollment_id: string;
  invitation_id: string;
  space_id: string;
  enrollment_state: "pending" | "approved" | "consumed" | "revoked" | "expired";
  transcript: string;
  transcript_hash: string;
  enrollment_created_at: number;
  enrollment_expires_at: number;
  approved_at: number | null;
  consumed_at: number | null;
  invitee_member_id: string;
  invitee_participant_id: string;
  invitee_agreement_public_key: string;
  invitee_signing_public_key: string;
  invitee_state: "pending" | "active" | "revoked" | "expired";
  key_envelope: string | null;
  envelope_algorithm: string | null;
  approval_signature: string | null;
}

interface SpaceRow {
  id: string;
  daily_boundary_minute_utc: number;
  state: "active" | "revoked";
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
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

export async function expireStalePairingState(
  env: Env,
  now: number,
  scope: { invitationId: string } | { spaceIds: readonly string[] },
): Promise<void> {
  const byInvitation = "invitationId" in scope;
  const scopeIds = byInvitation ? [scope.invitationId] : [...scope.spaceIds];
  if (scopeIds.length === 0) return;
  const placeholders = scopeIds.map(() => "?").join(", ");
  const enrollmentScope = byInvitation
    ? "invitation_id = ?"
    : `space_id IN (${placeholders})`;
  const invitationScope = byInvitation ? "id = ?" : `space_id IN (${placeholders})`;

  await env.DB.batch([
    env.DB.prepare(
      `UPDATE approval_events
          SET key_envelope = NULL, approval_signature = NULL
        WHERE enrollment_id IN (
          SELECT id FROM enrollments
           WHERE state IN ('pending', 'approved') AND expires_at <= ?
             AND ${enrollmentScope}
        )`,
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `UPDATE members
          SET state = 'expired'
        WHERE state = 'pending'
          AND id IN (
            SELECT member_id FROM enrollments
             WHERE state IN ('pending', 'approved') AND expires_at <= ?
               AND ${enrollmentScope}
          )`,
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `UPDATE enrollments
        SET state = 'expired'
        WHERE state IN ('pending', 'approved') AND expires_at <= ?
          AND ${enrollmentScope}`,
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `UPDATE invitations
          SET status = 'expired', invite_proof_public_key = NULL
        WHERE status = 'open' AND expires_at <= ? AND ${invitationScope}`,
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `DELETE FROM invitation_challenges
        WHERE consumed_at IS NULL
          AND (
            expires_at <= ? OR invitation_id IN (
              SELECT id FROM invitations WHERE status <> 'open'
            )
          )
          AND invitation_id IN (
            SELECT id FROM invitations WHERE ${invitationScope}
          )`,
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `DELETE FROM invitation_challenges
        WHERE id IN (
          SELECT challenge_id FROM enrollments
           WHERE state = 'expired' AND challenge_id IS NOT NULL
             AND ${enrollmentScope}
        )`,
    ).bind(...scopeIds),
  ]);
}

function publicMember(
  id: string,
  role: "owner" | "invitee",
  state: "pending" | "active" | "revoked" | "expired",
  participantId: string,
  agreementPublicKey: string,
  signingPublicKey: string,
): Record<string, unknown> {
  return { id, role, state, participantId, agreementPublicKey, signingPublicKey };
}

export async function createSpace(request: Request, env: Env): Promise<Response> {
  await enforceRateLimit(
    env,
    env.CREATE_RATE_LIMITER,
    transientNetworkKey(request, "create"),
  );
  const body = await readBody(request);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "participantId",
    "agreementPublicKey",
    "signingPublicKey",
    "invitationProofPublicKey",
    "dailyBoundaryMinuteUTC",
    "creationSignature",
  ]);
  protocolVersion(object);
  const fields = {
    clientRequestId: uuidField(object, "clientRequestId"),
    participantId: binaryField(object, "participantId", 16),
    agreementPublicKey: binaryField(object, "agreementPublicKey", 32),
    signingPublicKey: binaryField(object, "signingPublicKey", 32),
    invitationProofPublicKey: binaryField(object, "invitationProofPublicKey", 32),
    dailyBoundaryMinuteUTC: integerField(object, "dailyBoundaryMinuteUTC", 0, 1439),
  };
  const creationSignature = binaryField(object, "creationSignature", 64);
  if (!(await safelyVerify(fields.signingPublicKey, creationSignature, creationTranscript(fields)))) {
    throw new ApiError(401, "invalid_creation_signature", "The space creation signature is invalid.");
  }

  const requestHash = await sha256Base64url(body);
  const existing = await storedIdempotentResponse(
    env,
    "create-space",
    "public",
    fields.clientRequestId,
    requestHash,
  );
  if (existing !== null) return existing;

  const now = nowSeconds();
  const invitationTTL = positiveIntegerSetting(env.INVITATION_TTL_SECONDS, 86_400);
  const metadataExpiresAt = now
    + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2_592_000);
  const spaceId = randomBase64url(16);
  const memberId = randomBase64url(16);
  const invitationId = randomBase64url(16);
  const expiresAt = now + invitationTTL;
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId,
    dailyBoundaryMinuteUTC: fields.dailyBoundaryMinuteUTC,
    member: publicMember(
      memberId,
      "owner",
      "active",
      fields.participantId,
      fields.agreementPublicKey,
      fields.signingPublicKey,
    ),
    invitation: { id: invitationId, state: "open", expiresAt },
  };

  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO spaces(
           id, creation_request_id, protocol_version, daily_boundary_minute_utc,
           state, created_at, last_activity_at, metadata_expires_at
         ) VALUES (?, ?, 1, ?, 'active', ?, ?, ?)`,
      ).bind(
        spaceId,
        fields.clientRequestId,
        fields.dailyBoundaryMinuteUTC,
        now,
        now,
        metadataExpiresAt,
      ),
      env.DB.prepare(
        `INSERT INTO members(
           id, space_id, role, participant_id, agreement_public_key,
           signing_public_key, state, created_at, activated_at
         ) VALUES (?, ?, 'owner', ?, ?, ?, 'active', ?, ?)`,
      ).bind(
        memberId,
        spaceId,
        fields.participantId,
        fields.agreementPublicKey,
        fields.signingPublicKey,
        now,
        now,
      ),
      env.DB.prepare(
        `INSERT INTO invitations(
           id, space_id, inviter_member_id, invite_proof_public_key,
           status, created_at, expires_at
         ) VALUES (?, ?, ?, ?, 'open', ?, ?)`,
      ).bind(
        invitationId,
        spaceId,
        memberId,
        fields.invitationProofPublicKey,
        now,
        expiresAt,
      ),
      idempotencyStatement(
        env,
        "create-space",
        "public",
        fields.clientRequestId,
        spaceId,
        requestHash,
        201,
        responseBody,
        now,
      ),
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "create-space",
      "public",
      fields.clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "space_creation_conflict", "The space could not be created with these identities.");
  }
  return jsonResponse(responseBody, 201);
}

export async function createChallenge(
  request: Request,
  env: Env,
  invitationIdValue: string,
): Promise<Response> {
  const invitationId = opaqueId(invitationIdValue, "invitation");
  await enforceRateLimit(
    env,
    env.INVITE_RATE_LIMITER,
    transientNetworkKey(request, `challenge:${invitationId}`),
  );
  const body = await readBody(request);
  requireEmptyBody(body);
  const now = nowSeconds();
  await expireStalePairingState(env, now, { invitationId });

  const invitation = await env.DB.prepare(
    `SELECT i.id AS invitation_id, i.space_id, i.status AS invitation_status,
            i.expires_at AS invitation_expires_at, i.invite_proof_public_key,
            s.daily_boundary_minute_utc, s.state AS space_state,
            owner.id AS inviter_member_id, owner.participant_id AS inviter_participant_id,
            owner.agreement_public_key AS inviter_agreement_public_key,
            owner.signing_public_key AS inviter_signing_public_key
       FROM invitations AS i
       JOIN spaces AS s ON s.id = i.space_id
       JOIN members AS owner ON owner.id = i.inviter_member_id
      WHERE i.id = ?`,
  ).bind(invitationId).first<InvitationRow>();

  if (
    invitation === null ||
    invitation.invitation_status !== "open" ||
    invitation.space_state !== "active" ||
    invitation.invite_proof_public_key === null
  ) {
    throw new ApiError(410, "invitation_unavailable", "This invitation is no longer available.");
  }

  const challengeCount = await env.DB.prepare(
    `SELECT COUNT(*) AS count
       FROM invitation_challenges
      WHERE invitation_id = ? AND consumed_at IS NULL AND expires_at > ?`,
  ).bind(invitationId, now).first<{ count: number }>();
  if ((challengeCount?.count ?? 0) >= 8) {
    throw new ApiError(429, "too_many_challenges", "Wait for an earlier challenge to expire.");
  }

  const challengeId = randomBase64url(16);
  const challengeValue = randomBase64url(32);
  const challengeTTL = positiveIntegerSetting(env.CHALLENGE_TTL_SECONDS, 300);
  const expiresAt = Math.min(now + challengeTTL, invitation.invitation_expires_at);
  try {
    await env.DB.prepare(
      `INSERT INTO invitation_challenges(id, invitation_id, value, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?)`,
    ).bind(challengeId, invitationId, challengeValue, now, expiresAt).run();
  } catch {
    const live = await env.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM invitation_challenges
        WHERE invitation_id = ? AND consumed_at IS NULL AND expires_at > ?`,
    ).bind(invitationId, now).first<{ count: number }>();
    if ((live?.count ?? 0) >= 8) {
      throw new ApiError(429, "too_many_challenges", "Wait for an earlier challenge to expire.");
    }
    throw new ApiError(409, "challenge_conflict", "The invitation challenge could not be created.");
  }

  return jsonResponse(
    {
      protocolVersion: PROTOCOL_VERSION,
      spaceId: invitation.space_id,
      dailyBoundaryMinuteUTC: invitation.daily_boundary_minute_utc,
      invitationId,
      challenge: { id: challengeId, value: challengeValue, expiresAt },
      inviter: {
        id: invitation.inviter_member_id,
        participantId: invitation.inviter_participant_id,
        agreementPublicKey: invitation.inviter_agreement_public_key,
        signingPublicKey: invitation.inviter_signing_public_key,
      },
    },
    201,
  );
}

export async function redeemInvitation(
  request: Request,
  env: Env,
  invitationIdValue: string,
): Promise<Response> {
  const invitationId = opaqueId(invitationIdValue, "invitation");
  await enforceRateLimit(
    env,
    env.INVITE_RATE_LIMITER,
    transientNetworkKey(request, `enroll:${invitationId}`),
  );
  const body = await readBody(request);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "challengeId",
    "participantId",
    "agreementPublicKey",
    "signingPublicKey",
    "inviteProofSignature",
    "participantSignature",
  ]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const challengeId = binaryField(object, "challengeId", 16);
  const participantId = binaryField(object, "participantId", 16);
  const agreementPublicKey = binaryField(object, "agreementPublicKey", 32);
  const signingPublicKey = binaryField(object, "signingPublicKey", 32);
  const inviteProofSignature = binaryField(object, "inviteProofSignature", 64);
  const participantSignature = binaryField(object, "participantSignature", 64);
  const requestHash = await sha256Base64url(body);

  const existing = await storedIdempotentResponse(
    env,
    "redeem-invitation",
    invitationId,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) return existing;

  const now = nowSeconds();
  await expireStalePairingState(env, now, { invitationId });
  const challenge = await env.DB.prepare(
    `SELECT i.id AS invitation_id, i.space_id, i.status AS invitation_status,
            i.expires_at AS invitation_expires_at, i.invite_proof_public_key,
            s.daily_boundary_minute_utc, s.state AS space_state,
            owner.id AS inviter_member_id, owner.participant_id AS inviter_participant_id,
            owner.agreement_public_key AS inviter_agreement_public_key,
            owner.signing_public_key AS inviter_signing_public_key,
            c.id AS challenge_id, c.value AS challenge_value,
            c.expires_at AS challenge_expires_at, c.consumed_at AS challenge_consumed_at
       FROM invitations AS i
       JOIN spaces AS s ON s.id = i.space_id
       JOIN members AS owner ON owner.id = i.inviter_member_id
       JOIN invitation_challenges AS c ON c.invitation_id = i.id
      WHERE i.id = ? AND c.id = ?`,
  ).bind(invitationId, challengeId).first<ChallengeRow>();

  if (
    challenge === null ||
    challenge.invitation_status !== "open" ||
    challenge.space_state !== "active" ||
    challenge.invite_proof_public_key === null ||
    challenge.challenge_consumed_at !== null ||
    challenge.challenge_expires_at <= now
  ) {
    throw new ApiError(410, "challenge_unavailable", "This invitation challenge is no longer available.");
  }

  const enrollmentBytes = enrollmentTranscript({
    spaceId: challenge.space_id,
    invitationId,
    challengeId,
    challengeValue: challenge.challenge_value,
    challengeExpiresAt: challenge.challenge_expires_at,
    clientRequestId,
    participantId,
    agreementPublicKey,
    signingPublicKey,
  });
  const [validInviteProof, validParticipantProof] = await Promise.all([
    safelyVerify(challenge.invite_proof_public_key, inviteProofSignature, enrollmentBytes),
    safelyVerify(signingPublicKey, participantSignature, enrollmentBytes),
  ]);
  if (!validInviteProof || !validParticipantProof) {
    throw new ApiError(401, "invalid_enrollment_proof", "The invitation proof is invalid.");
  }

  const memberId = randomBase64url(16);
  const enrollmentId = randomBase64url(16);
  const transcriptBytes = pairingTranscript({
    spaceId: challenge.space_id,
    invitationId,
    enrollmentId,
    dailyBoundaryMinuteUTC: challenge.daily_boundary_minute_utc,
    inviterMemberId: challenge.inviter_member_id,
    inviterParticipantId: challenge.inviter_participant_id,
    inviterAgreementPublicKey: challenge.inviter_agreement_public_key,
    inviterSigningPublicKey: challenge.inviter_signing_public_key,
    inviteeMemberId: memberId,
    inviteeParticipantId: participantId,
    inviteeAgreementPublicKey: agreementPublicKey,
    inviteeSigningPublicKey: signingPublicKey,
  });
  const transcript = base64urlEncode(transcriptBytes);
  const transcriptHash = await sha256Base64url(transcriptBytes);
  const pendingTTL = positiveIntegerSetting(env.PENDING_TTL_SECONDS, 86_400);
  const expiresAt = now + pendingTTL;
  const metadataExpiresAt = now
    + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2_592_000);
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: challenge.space_id,
    dailyBoundaryMinuteUTC: challenge.daily_boundary_minute_utc,
    member: publicMember(
      memberId,
      "invitee",
      "pending",
      participantId,
      agreementPublicKey,
      signingPublicKey,
    ),
    enrollment: {
      id: enrollmentId,
      state: "pendingApproval",
      createdAt: now,
      expiresAt,
      transcript,
      transcriptHash,
    },
  };

  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO members(
           id, space_id, role, participant_id, agreement_public_key,
           signing_public_key, state, created_at
         ) VALUES (?, ?, 'invitee', ?, ?, ?, 'pending', ?)`,
      ).bind(
        memberId,
        challenge.space_id,
        participantId,
        agreementPublicKey,
        signingPublicKey,
        now,
      ),
      env.DB.prepare(
        `INSERT INTO enrollments(
           id, invitation_id, challenge_id, space_id, member_id, client_request_id,
           state, transcript, transcript_hash, invite_proof_signature,
           participant_signature, created_at, expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)`,
      ).bind(
        enrollmentId,
        invitationId,
        challengeId,
        challenge.space_id,
        memberId,
        clientRequestId,
        transcript,
        transcriptHash,
        inviteProofSignature,
        participantSignature,
        now,
        expiresAt,
      ),
      env.DB.prepare(
        `UPDATE spaces
            SET last_activity_at = ?, metadata_expires_at = ?
          WHERE id = ? AND state = 'active'`,
      ).bind(now, metadataExpiresAt, challenge.space_id),
      idempotencyStatement(
        env,
        "redeem-invitation",
        invitationId,
        clientRequestId,
        challenge.space_id,
        requestHash,
        201,
        responseBody,
        now,
      ),
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "redeem-invitation",
      invitationId,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invitation_already_used", "This invitation was already used or conflicts with this identity.");
  }
  return jsonResponse(responseBody, 201);
}

async function signedMemberRequest(
  request: Request,
  env: Env,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "member"),
  );
  const body = await readBody(request);
  return { body, member: await authenticateSignedRequest(request, env, body) };
}

async function loadEnrollment(env: Env, spaceId: string): Promise<EnrollmentRow | null> {
  return env.DB.prepare(
    `SELECT e.id AS enrollment_id, e.invitation_id, e.space_id,
            e.state AS enrollment_state, e.transcript, e.transcript_hash,
            e.created_at AS enrollment_created_at, e.expires_at AS enrollment_expires_at,
            e.approved_at, e.consumed_at,
            invitee.id AS invitee_member_id,
            invitee.participant_id AS invitee_participant_id,
            invitee.agreement_public_key AS invitee_agreement_public_key,
            invitee.signing_public_key AS invitee_signing_public_key,
            invitee.state AS invitee_state,
            a.key_envelope, a.envelope_algorithm, a.approval_signature
       FROM enrollments AS e
       JOIN members AS invitee ON invitee.id = e.member_id
       LEFT JOIN approval_events AS a ON a.enrollment_id = e.id
      WHERE e.space_id = ?
      ORDER BY e.created_at DESC
      LIMIT 1`,
  ).bind(spaceId).first<EnrollmentRow>();
}

export async function getPending(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedMemberRequest(request, env);
  requireEmptyBody(body);
  try {
    requireOwner(member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireStalePairingState(env, member.now, { spaceIds: [member.spaceId] });
  await consumeNonceAndTouch(env, member);
  const result = await env.DB.prepare(
    `SELECT e.id AS enrollment_id, e.transcript, e.transcript_hash,
            e.created_at AS enrollment_created_at, e.expires_at AS enrollment_expires_at,
            invitee.id AS invitee_member_id, invitee.participant_id AS invitee_participant_id,
            invitee.agreement_public_key AS invitee_agreement_public_key,
            invitee.signing_public_key AS invitee_signing_public_key
       FROM enrollments AS e
       JOIN members AS invitee ON invitee.id = e.member_id
      WHERE e.space_id = ? AND e.state = 'pending'
      ORDER BY e.created_at ASC`,
  ).bind(member.spaceId).all<EnrollmentRow>();

  return jsonResponse({
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    pending: result.results.map((row) => ({
      id: row.enrollment_id,
      state: "pendingApproval",
      createdAt: row.enrollment_created_at,
      expiresAt: row.enrollment_expires_at,
      transcript: row.transcript,
      transcriptHash: row.transcript_hash,
      member: publicMember(
        row.invitee_member_id,
        "invitee",
        "pending",
        row.invitee_participant_id,
        row.invitee_agreement_public_key,
        row.invitee_signing_public_key,
      ),
    })),
  });
}

export async function getStatus(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedMemberRequest(request, env);
  requireEmptyBody(body);
  await expireStalePairingState(env, member.now, { spaceIds: [member.spaceId] });
  const space = await env.DB.prepare(
    "SELECT id, daily_boundary_minute_utc, state FROM spaces WHERE id = ?",
  ).bind(member.spaceId).first<SpaceRow>();
  const currentMember = await env.DB.prepare(
    "SELECT state FROM members WHERE id = ? AND space_id = ?",
  ).bind(member.id, member.spaceId).first<{
    state: "pending" | "active" | "revoked" | "expired";
  }>();
  if (
    space === null ||
    space.state !== "active" ||
    currentMember === null ||
    currentMember.state === "revoked" ||
    currentMember.state === "expired"
  ) {
    await consumeNonce(env, member);
    throw new ApiError(410, "sharing_revoked", "This sharing space is no longer active.");
  }
  await consumeNonceAndTouch(env, member);
  const enrollment = await loadEnrollment(env, member.spaceId);
  const completedRecovery = await env.DB.prepare(
    `SELECT consumed_at FROM device_recoveries
      WHERE space_id = ? AND state = 'consumed'
      ORDER BY consumed_at DESC LIMIT 1`,
  ).bind(member.spaceId).first<{ consumed_at: number }>();
  const recovered = completedRecovery !== null;
  let state: "awaitingInvitee" | "pendingApproval" | "approvedAwaitingCompletion" | "active" | "cancelled" | "expired" =
    recovered ? "active" : "awaitingInvitee";
  if (!recovered && enrollment !== null) {
    state = enrollment.enrollment_state === "pending"
      ? "pendingApproval"
      : enrollment.enrollment_state === "approved"
        ? "approvedAwaitingCompletion"
        : enrollment.enrollment_state === "consumed"
          ? "active"
          : enrollment.enrollment_state === "revoked"
            ? "cancelled"
            : "expired";
  }

  const currentPeer = await env.DB.prepare(
    `SELECT peer.id, peer.participant_id, peer.role, peer.state,
            device.agreement_public_key, device.signing_public_key
       FROM members AS peer
       JOIN moment_participants AS participant
         ON participant.legacy_member_id = peer.id
        AND participant.space_id = peer.space_id
        AND participant.state = 'active'
       JOIN moment_devices AS device
         ON device.participant_id = participant.id
        AND device.legacy_member_id = peer.id
        AND device.state = 'active'
      WHERE peer.space_id = ? AND peer.id <> ? AND peer.state = 'active'
      ORDER BY peer.created_at ASC LIMIT 1`,
  ).bind(member.spaceId, member.id).first<{
    id: string;
    participant_id: string;
    role: "owner" | "invitee";
    agreement_public_key: string;
    signing_public_key: string;
    state: "pending" | "active" | "revoked" | "expired";
  }>();
  const peer = currentPeer === null
    ? null
    : publicMember(
      currentPeer.id,
      currentPeer.role,
      currentPeer.state,
      currentPeer.participant_id,
      currentPeer.agreement_public_key,
      currentPeer.signing_public_key,
    );

  const keyEnvelope =
    !recovered && member.role === "invitee" &&
    enrollment?.enrollment_state === "approved" &&
    enrollment.key_envelope !== null &&
    enrollment.envelope_algorithm !== null &&
    enrollment.approval_signature !== null &&
    enrollment.approved_at !== null
      ? {
        algorithm: enrollment.envelope_algorithm,
        ciphertext: enrollment.key_envelope,
        approvalSignature: enrollment.approval_signature,
        approvedAt: enrollment.approved_at,
      }
      : null;

  return jsonResponse({
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    dailyBoundaryMinuteUTC: space.daily_boundary_minute_utc,
    member: publicMember(
      member.id,
      member.role,
      currentMember.state,
      member.participantId,
      member.agreementPublicKey,
      member.signingPublicKey,
    ),
    pairing: {
      state,
      enrollment: enrollment === null || recovered
        ? null
        : {
          id: enrollment.enrollment_id,
          createdAt: enrollment.enrollment_created_at,
          expiresAt: enrollment.enrollment_expires_at,
          transcript: enrollment.transcript,
          transcriptHash: enrollment.transcript_hash,
        },
      peer,
      keyEnvelope,
    },
  });
}

async function replayAfterRace(
  env: Env,
  operation: string,
  member: AuthenticatedMember,
  clientRequestId: string,
  requestHash: string,
  touchActivity = true,
): Promise<Response | null> {
  const stored = await storedIdempotentResponse(
    env,
    operation,
    member.id,
    clientRequestId,
    requestHash,
  );
  if (stored === null) return null;
  if (touchActivity) {
    await consumeNonceAndTouch(env, member);
  } else {
    await consumeNonce(env, member);
  }
  return stored;
}

async function consumeNonceAndThrow(
  env: Env,
  member: AuthenticatedMember,
  error: ApiError,
): Promise<never> {
  await consumeNonce(env, member);
  throw error;
}

export async function approveEnrollment(
  request: Request,
  env: Env,
  enrollmentIdValue: string,
): Promise<Response> {
  const enrollmentId = opaqueId(enrollmentIdValue, "enrollment");
  const { body, member } = await signedMemberRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "transcriptHash",
    "envelopeAlgorithm",
    "keyEnvelope",
    "approvalSignature",
  ]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const transcriptHash = binaryField(object, "transcriptHash", 32);
  const envelopeAlgorithm = stringField(object, "envelopeAlgorithm");
  if (envelopeAlgorithm !== ENVELOPE_ALGORITHM) {
    throw new ApiError(400, "unsupported_envelope", "The key envelope algorithm is unsupported.");
  }
  const keyEnvelope = binaryField(object, "keyEnvelope", 60);
  const approvalSignature = binaryField(object, "approvalSignature", 64);
  const requestHash = await sha256Base64url(body);

  const existing = await storedIdempotentResponse(
    env,
    "approve-enrollment",
    member.id,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) {
    await consumeNonceAndTouch(env, member);
    return existing;
  }
  try {
    requireOwner(member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireStalePairingState(env, member.now, { spaceIds: [member.spaceId] });
  const enrollment = await loadEnrollment(env, member.spaceId);
  if (
    enrollment === null ||
    enrollment.enrollment_id !== enrollmentId ||
    enrollment.enrollment_state !== "pending" ||
    enrollment.transcript_hash !== transcriptHash
  ) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(409, "invalid_pairing_state", "The enrollment cannot be approved."),
    );
  }
  if (!(await safelyVerify(
    member.signingPublicKey,
    approvalSignature,
    approvalTranscript(transcriptHash, envelopeAlgorithm, keyEnvelope),
  ))) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(401, "invalid_approval_signature", "The approval signature is invalid."),
    );
  }

  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    enrollmentId,
    state: "approvedAwaitingCompletion",
    approvedAt: member.now,
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO approval_events(
           enrollment_id, approver_member_id, client_request_id, transcript_hash,
           envelope_algorithm, key_envelope, approval_signature, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        enrollmentId,
        member.id,
        clientRequestId,
        transcriptHash,
        envelopeAlgorithm,
        keyEnvelope,
        approvalSignature,
        member.now,
      ),
      idempotencyStatement(
        env,
        "approve-enrollment",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "approve-enrollment",
      member,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The enrollment cannot be approved.");
  }
  return jsonResponse(responseBody);
}

export async function completeEnrollment(
  request: Request,
  env: Env,
  enrollmentIdValue: string,
): Promise<Response> {
  const enrollmentId = opaqueId(enrollmentIdValue, "enrollment");
  const { body, member } = await signedMemberRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId", "transcriptHash"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const transcriptHash = binaryField(object, "transcriptHash", 32);
  const requestHash = await sha256Base64url(body);
  const existing = await storedIdempotentResponse(
    env,
    "complete-enrollment",
    member.id,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) {
    await consumeNonceAndTouch(env, member);
    return existing;
  }
  try {
    requirePendingInvitee(member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireStalePairingState(env, member.now, { spaceIds: [member.spaceId] });
  const enrollment = await loadEnrollment(env, member.spaceId);
  if (
    enrollment === null ||
    enrollment.enrollment_id !== enrollmentId ||
    enrollment.invitee_member_id !== member.id ||
    enrollment.enrollment_state !== "approved" ||
    enrollment.transcript_hash !== transcriptHash ||
    enrollment.key_envelope === null
  ) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(409, "invalid_pairing_state", "The enrollment cannot be completed."),
    );
  }
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    enrollmentId,
    memberId: member.id,
    state: "active",
    activatedAt: member.now,
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO completion_events(
           enrollment_id, member_id, client_request_id, transcript_hash, created_at
         ) VALUES (?, ?, ?, ?, ?)`,
      ).bind(enrollmentId, member.id, clientRequestId, transcriptHash, member.now),
      idempotencyStatement(
        env,
        "complete-enrollment",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "complete-enrollment",
      member,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The enrollment cannot be completed.");
  }
  return jsonResponse(responseBody);
}

export async function cancelEnrollment(
  request: Request,
  env: Env,
  enrollmentIdValue: string,
): Promise<Response> {
  const enrollmentId = opaqueId(enrollmentIdValue, "enrollment");
  const { body, member } = await signedMemberRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const requestHash = await sha256Base64url(body);
  const existing = await storedIdempotentResponse(
    env,
    "cancel-enrollment",
    member.id,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) {
    await consumeNonce(env, member);
    return existing;
  }
  try {
    requirePendingInvitee(member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireStalePairingState(env, member.now, { spaceIds: [member.spaceId] });
  const enrollment = await loadEnrollment(env, member.spaceId);
  if (
    enrollment === null ||
    enrollment.enrollment_id !== enrollmentId ||
    enrollment.invitee_member_id !== member.id ||
    (enrollment.enrollment_state !== "pending" && enrollment.enrollment_state !== "approved")
  ) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(410, "enrollment_unavailable", "This enrollment is no longer cancellable."),
    );
  }
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    enrollmentId,
    memberId: member.id,
    state: "cancelled",
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO cancellation_events(
           enrollment_id, member_id, client_request_id, created_at
         ) VALUES (?, ?, ?, ?)`,
      ).bind(enrollmentId, member.id, clientRequestId, member.now),
      idempotencyStatement(
        env,
        "cancel-enrollment",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        202,
        responseBody,
        member.now,
      ),
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "cancel-enrollment",
      member,
      clientRequestId,
      requestHash,
      false,
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The enrollment could not be cancelled.");
  }
  return jsonResponse(responseBody, 202);
}

export async function revokeSpace(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedMemberRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const requestHash = await sha256Base64url(body);
  const existing = await storedIdempotentResponse(
    env,
    "revoke-space",
    member.id,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) {
    await consumeNonce(env, member);
    return existing;
  }
  try {
    requireLiveSpace(member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (member.state !== "active") {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(
        403,
        "active_member_required",
        "Pairing must be completed before the whole space can be revoked.",
      ),
    );
  }
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    state: "revoked",
    deletionState: "pending",
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO revocation_events(space_id, actor_member_id, client_request_id, created_at)
         VALUES (?, ?, ?, ?)`,
      ).bind(member.spaceId, member.id, clientRequestId, member.now),
      idempotencyStatement(
        env,
        "revoke-space",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        202,
        responseBody,
        member.now,
      ),
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "revoke-space",
      member,
      clientRequestId,
      requestHash,
      false,
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The sharing space cannot be revoked again.");
  }
  return jsonResponse(responseBody, 202);
}
