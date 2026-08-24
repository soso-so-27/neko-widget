import { base64urlDecode, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";
import { positiveIntegerSetting } from "./env";
import { signedRequestTranscript } from "./protocol";
import { opaqueId } from "./validation";

export interface AuthenticatedMember {
  id: string;
  spaceId: string;
  role: "owner" | "invitee";
  participantId: string;
  agreementPublicKey: string;
  signingPublicKey: string;
  state: "pending" | "active" | "revoked" | "expired";
  spaceState: "active" | "revoked";
  nonce: string;
  now: number;
}

interface MemberRow {
  id: string;
  space_id: string;
  role: "owner" | "invitee";
  participant_id: string;
  agreement_public_key: string;
  signing_public_key: string;
  state: "pending" | "active" | "revoked" | "expired";
  space_state: "active" | "revoked";
}

export async function authenticateSignedRequest(
  request: Request,
  env: Env,
  body: Uint8Array,
): Promise<AuthenticatedMember> {
  if (request.headers.get("neko-protocol-version") !== "1") {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  let memberId: string;
  try {
    memberId = opaqueId(request.headers.get("neko-member-id") ?? "", "member");
  } catch {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  const timestampValue = request.headers.get("neko-timestamp") ?? "";
  const timestamp = Number(timestampValue);
  const nonce = request.headers.get("neko-nonce") ?? "";
  const signature = request.headers.get("neko-signature") ?? "";

  if (!Number.isSafeInteger(timestamp) || String(timestamp) !== timestampValue) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  try {
    base64urlDecode(nonce, 16);
    base64urlDecode(signature, 64);
  } catch {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - timestamp) > 300) {
    throw new ApiError(401, "stale_request", "The signed request timestamp is outside the five-minute window.");
  }

  const member = await env.DB.prepare(
    `SELECT m.id, m.space_id, m.role, m.participant_id,
            device.agreement_public_key, device.signing_public_key,
            m.state, s.state AS space_state
       FROM members AS m
       JOIN spaces AS s ON s.id = m.space_id
       JOIN moment_participants AS participant
         ON participant.legacy_member_id = m.id
        AND participant.space_id = m.space_id
        AND participant.state = m.state
       JOIN moment_devices AS device
         ON device.participant_id = participant.id
        AND device.legacy_member_id = m.id
        AND device.state = m.state
      WHERE m.id = ?`,
  ).bind(memberId).first<MemberRow>();
  if (member === null) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }

  const pathname = new URL(request.url).pathname;
  const transcript = signedRequestTranscript({
    memberId,
    timestamp,
    nonce,
    method: request.method,
    pathname,
    bodySHA256: await sha256Base64url(body),
  });
  if (!(await verifyEd25519(member.signing_public_key, signature, transcript))) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }

  return {
    id: member.id,
    spaceId: member.space_id,
    role: member.role,
    participantId: member.participant_id,
    agreementPublicKey: member.agreement_public_key,
    signingPublicKey: member.signing_public_key,
    state: member.state,
    spaceState: member.space_state,
    nonce,
    now,
  };
}

export function nonceStatements(env: Env, member: AuthenticatedMember): D1PreparedStatement[] {
  return [
    env.DB.prepare("DELETE FROM request_nonces WHERE member_id = ? AND expires_at < ?")
      .bind(member.id, member.now),
    env.DB.prepare(
      "INSERT INTO request_nonces(member_id, nonce, created_at, expires_at) VALUES (?, ?, ?, ?)",
    ).bind(member.id, member.nonce, member.now, member.now + 601),
  ];
}

export function activityStatement(env: Env, member: AuthenticatedMember): D1PreparedStatement {
  const metadataExpiresAt = member.now
    + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2_592_000);
  return env.DB.prepare(
    `UPDATE spaces
        SET last_activity_at = ?, metadata_expires_at = ?
      WHERE id = ?
        AND state = 'active'
        AND EXISTS (
          SELECT 1
            FROM members
           WHERE id = ?
             AND space_id = spaces.id
             AND state IN ('pending', 'active')
        )`,
  ).bind(member.now, metadataExpiresAt, member.spaceId, member.id);
}

export async function consumeNonce(env: Env, member: AuthenticatedMember): Promise<void> {
  try {
    await env.DB.batch(nonceStatements(env, member));
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}

export async function consumeNonceAndTouch(env: Env, member: AuthenticatedMember): Promise<void> {
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      activityStatement(env, member),
    ]);
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}

export function requireLiveSpace(member: AuthenticatedMember): void {
  if (member.spaceState !== "active" || member.state === "revoked" || member.state === "expired") {
    throw new ApiError(410, "sharing_revoked", "This sharing space is no longer active.");
  }
}

export function requireOwner(member: AuthenticatedMember): void {
  requireLiveSpace(member);
  if (member.role !== "owner" || member.state !== "active") {
    throw new ApiError(403, "owner_required", "Only the active inviter can perform this operation.");
  }
}

export function requirePendingInvitee(member: AuthenticatedMember): void {
  requireLiveSpace(member);
  if (member.role !== "invitee" || member.state !== "pending") {
    throw new ApiError(409, "invalid_pairing_state", "The invited member is not awaiting completion.");
  }
}
