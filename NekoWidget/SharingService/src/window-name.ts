import {
  activityStatement,
  authenticateSignedRequest,
  consumeNonce,
  consumeNonceAndTouch,
  nonceStatements,
  requireLiveSpace,
  requireOwner,
  type AuthenticatedMember,
} from "./auth";
import { base64urlDecode, sha256Base64url, verifyEd25519 } from "./encoding";
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
import { encodeCanonicalFields } from "./protocol";
import {
  binaryField,
  exactKeys,
  integerField,
  stringField,
  uuidField,
} from "./validation";

const protocolVersion = 2 as const;
const minimumCombinedAEADCiphertextBytes = 29;
export const MAXIMUM_WINDOW_NAME_CIPHERTEXT_BYTES = 512;
const putOperation = "put-window-name";

interface WindowNameContextRow {
  participant_role: "owner" | "member";
  current_key_epoch: number;
  is_blocked: number;
  is_primary_device: number;
}

interface WindowNameRow {
  owner_member_id: string;
  client_revision: number;
  key_epoch: number;
  ciphertext: string;
  ciphertext_size: number;
  ciphertext_sha256: string;
  owner_signature: string;
}

interface ParsedWindowName {
  clientRequestID: string;
  clientRevision: number;
  keyEpoch: number;
  ciphertext: string;
  ciphertextSize: number;
  ciphertextSHA256: string;
  ownerSignature: string;
}

function responseBody(row: WindowNameRow | null): Record<string, unknown> {
  return {
    protocolVersion,
    windowName: row === null ? null : {
      ownerMemberId: row.owner_member_id,
      clientRevision: row.client_revision,
      keyEpoch: row.key_epoch,
      ciphertext: row.ciphertext,
      ciphertextSHA256: row.ciphertext_sha256,
      ownerSignature: row.owner_signature,
    },
  };
}

async function signedRequest(
  request: Request,
  env: Env,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "window-name"),
  );
  const body = await readBody(request, 2 * 1024);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(
        403,
        "active_member_required",
        "Pairing must be complete before accessing the private window name.",
      );
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}

async function context(
  env: Env,
  member: AuthenticatedMember,
): Promise<WindowNameContextRow> {
  const row = await env.DB.prepare(
    `SELECT participant.role AS participant_role,
            space.current_key_epoch,
            CASE WHEN device.legacy_member_id IS NOT NULL
              THEN 1 ELSE 0 END AS is_primary_device,
            CASE WHEN EXISTS (
              SELECT 1
                FROM moment_blocks AS block
               WHERE block.space_id = space.space_id
                 AND block.state = 'active'
            ) THEN 1 ELSE 0 END AS is_blocked
       FROM moment_participants AS participant
       JOIN moment_devices AS device ON device.participant_id = participant.id
       JOIN moment_spaces AS space ON space.space_id = participant.space_id
      WHERE participant.id = ?
        AND device.id = ?
        AND participant.space_id = ?
        AND participant.state = 'active'
        AND device.state = 'active'
        AND space.state = 'active'`,
  ).bind(
    member.momentParticipantId,
    member.deviceId,
    member.spaceId,
  ).first<WindowNameContextRow>();
  if (row === null) {
    throw new ApiError(
      503,
      "window_name_identity_unavailable",
      "The private window identity is temporarily unavailable.",
    );
  }
  if (row.is_blocked === 1) {
    throw new ApiError(
      410,
      "window_name_blocked",
      "The private window name is unavailable after a participant block.",
    );
  }
  return row;
}

async function loadCurrent(env: Env, spaceID: string): Promise<WindowNameRow | null> {
  return env.DB.prepare(
    `SELECT owner_member_id, client_revision, key_epoch, ciphertext,
            ciphertext_size, ciphertext_sha256, owner_signature
       FROM moment_window_names
      WHERE space_id = ?`,
  ).bind(spaceID).first<WindowNameRow>();
}

async function mutationRequestHash(request: Request, body: Uint8Array): Promise<string> {
  return sha256Base64url(encodeCanonicalFields([
    "NW2.IDEMPOTENCY",
    "2",
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    await sha256Base64url(body),
  ]));
}

async function replayResponse(
  env: Env,
  member: AuthenticatedMember,
  clientRequestID: string,
  requestHash: string,
): Promise<Response | null> {
  let stored: Response | null;
  try {
    stored = await storedIdempotentResponse(
      env,
      putOperation,
      member.id,
      clientRequestID,
      requestHash,
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (stored !== null) await consumeNonceAndTouch(env, member);
  return stored;
}

async function consumeAndThrow(
  env: Env,
  member: AuthenticatedMember,
  error: unknown,
): Promise<never> {
  await consumeNonce(env, member);
  throw error;
}

async function parseWindowName(
  request: Request,
  body: Uint8Array,
): Promise<ParsedWindowName> {
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "clientRevision",
    "keyEpoch",
    "ciphertext",
    "ciphertextSHA256",
    "ownerSignature",
  ]);
  if (object.protocolVersion !== protocolVersion) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
  const clientRequestID = uuidField(object, "clientRequestId");
  const clientRevision = integerField(
    object,
    "clientRevision",
    0,
    Number.MAX_SAFE_INTEGER,
  );
  const keyEpoch = integerField(object, "keyEpoch", 1, Number.MAX_SAFE_INTEGER);
  const ciphertext = stringField(object, "ciphertext");
  const ciphertextBytes = base64urlDecode(ciphertext);
  if (
    ciphertextBytes.length < minimumCombinedAEADCiphertextBytes
    || ciphertextBytes.length > MAXIMUM_WINDOW_NAME_CIPHERTEXT_BYTES
  ) {
    throw new ApiError(
      400,
      "invalid_ciphertext_length",
      "The encrypted private window name is outside its allowed size.",
    );
  }
  const ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
  if (await sha256Base64url(ciphertextBytes) !== ciphertextSHA256) {
    throw new ApiError(
      400,
      "ciphertext_hash_mismatch",
      "The encrypted private window name does not match its digest.",
    );
  }
  const ownerSignature = binaryField(object, "ownerSignature", 64);
  return {
    clientRequestID,
    clientRevision,
    keyEpoch,
    ciphertext,
    ciphertextSize: ciphertextBytes.length,
    ciphertextSHA256,
    ownerSignature,
  };
}

function samePayload(current: WindowNameRow, requested: ParsedWindowName): boolean {
  return current.client_revision === requested.clientRevision
    && current.key_epoch === requested.keyEpoch
    && current.ciphertext === requested.ciphertext
    && current.ciphertext_size === requested.ciphertextSize
    && current.ciphertext_sha256 === requested.ciphertextSHA256
    && current.owner_signature === requested.ownerSignature;
}

export async function getWindowName(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedRequest(request, env);
  try {
    requireEmptyBody(body);
    await context(env, member);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const row = await loadCurrent(env, member.spaceId);
  await consumeNonceAndTouch(env, member);
  return jsonResponse(responseBody(row));
}

export async function putWindowName(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedRequest(request, env);
  let requested: ParsedWindowName;
  let actor: WindowNameContextRow;
  try {
    requested = await parseWindowName(request, body);
    requireOwner(member);
    actor = await context(env, member);
    if (actor.participant_role !== "owner") {
      throw new ApiError(
        403,
        "owner_required",
        "Only the active inviter can update the private window name.",
      );
    }
    if (actor.is_primary_device !== 1) {
      throw new ApiError(
        403,
        "primary_owner_device_required",
        "The original owner device is required to update the private window name.",
      );
    }
    const ownerTranscript = encodeCanonicalFields([
      "NW2.WINDOW-NAME-RECORD",
      "1",
      member.spaceId,
      member.id,
      String(requested.clientRevision),
      String(requested.keyEpoch),
      requested.ciphertextSHA256,
    ]);
    if (!(await verifyEd25519(
      member.signingPublicKey,
      requested.ownerSignature,
      ownerTranscript,
    ))) {
      throw new ApiError(
        401,
        "invalid_owner_signature",
        "The private window name owner signature is invalid.",
      );
    }
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }

  const requestHash = await mutationRequestHash(request, body);
  const replayed = await replayResponse(
    env,
    member,
    requested.clientRequestID,
    requestHash,
  );
  if (replayed !== null) return replayed;
  if (requested.keyEpoch !== actor.current_key_epoch) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(
        409,
        "key_epoch_required",
        "The current sharing key epoch is required.",
      ),
    );
  }

  const row: WindowNameRow = {
    owner_member_id: member.id,
    client_revision: requested.clientRevision,
    key_epoch: requested.keyEpoch,
    ciphertext: requested.ciphertext,
    ciphertext_size: requested.ciphertextSize,
    ciphertext_sha256: requested.ciphertextSHA256,
    owner_signature: requested.ownerSignature,
  };
  const response = responseBody(row);
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_window_names(
           space_id, owner_member_id, client_revision, key_epoch,
           ciphertext, ciphertext_size, ciphertext_sha256, owner_signature,
           updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(space_id) DO UPDATE SET
           owner_member_id = excluded.owner_member_id,
           client_revision = excluded.client_revision,
           key_epoch = excluded.key_epoch,
           ciphertext = excluded.ciphertext,
           ciphertext_size = excluded.ciphertext_size,
           ciphertext_sha256 = excluded.ciphertext_sha256,
           owner_signature = excluded.owner_signature,
           updated_at = (CASE
             WHEN excluded.client_revision > moment_window_names.client_revision
             THEN excluded.updated_at ELSE moment_window_names.updated_at END)`,
      ).bind(
        member.spaceId,
        member.id,
        requested.clientRevision,
        requested.keyEpoch,
        requested.ciphertext,
        requested.ciphertextSize,
        requested.ciphertextSHA256,
        requested.ownerSignature,
        member.now,
      ),
      idempotencyStatement(
        env,
        putOperation,
        member.id,
        requested.clientRequestID,
        member.spaceId,
        requestHash,
        200,
        response,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await replayResponse(
      env,
      member,
      requested.clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    const current = await loadCurrent(env, member.spaceId);
    let failure = new ApiError(
      409,
      "window_name_update_conflict",
      "The private window name could not be updated.",
    );
    if (current !== null && current.client_revision > requested.clientRevision) {
      failure = new ApiError(
        409,
        "stale_window_name_revision",
        "A newer private window name revision already exists.",
      );
    } else if (
      current !== null
      && current.client_revision === requested.clientRevision
      && !samePayload(current, requested)
    ) {
      failure = new ApiError(
        409,
        "window_name_revision_conflict",
        "This private window name revision already has different ciphertext.",
      );
    }
    return consumeAndThrow(env, member, failure);
  }
  return jsonResponse(response);
}
