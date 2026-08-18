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
  base64urlEncode,
  randomBase64url,
  sha256,
  sha256Base64url,
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
  encodeCanonicalFields,
  nextRotationAnchor,
  nextShareDayBoundary,
  PROTOCOL_VERSION,
  shareDayKey,
} from "./protocol";
import {
  asObject,
  binaryField,
  exactKeys,
  integerField,
  opaqueId,
  protocolVersion,
  uuidField,
} from "./validation";

const maximumMediaCiphertextBytes = 300 * 1024;
const maximumManifestCiphertextBytes = 64 * 1024;
const minimumChaChaCombinedBytes = 29;
const uploadCloseGraceSeconds = 600;
const sharingContentTTLSeconds = 30 * 86_400;

type GenerationState =
  | "reserved"
  | "uploading"
  | "prepared"
  | "committed"
  | "superseded"
  | "expired";

interface SourceRow {
  id: string;
  space_id: string;
  publisher_member_id: string;
  state: "active" | "revoked";
  current_revision: number;
  last_committed_share_day_key: number | null;
  cleanup_blocked: number;
  object_prefix: string;
  daily_boundary_minute_utc: number;
}

interface GenerationRow {
  id: string;
  source_id: string;
  space_id: string;
  publisher_member_id: string;
  share_day_key: number;
  state: GenerationState;
  item_count: number;
  reserve_request_hash: string;
  descriptor_request_hash: string | null;
  created_at: number;
  staging_expires_at: number;
  prepare_attempt_revision: number;
  prepare_attempt_id: string | null;
  reserved_revision: number | null;
  rotation_anchor_utc: number | null;
  prepare_expires_at: number | null;
  manifest_object_key: string | null;
  manifest_ciphertext_size: number | null;
  manifest_ciphertext_sha256: string | null;
  manifest_verified_at: number | null;
  committed_at: number | null;
  content_expires_at: number | null;
  revision: number | null;
  source_current_revision: number;
  source_state: "active" | "revoked";
  cleanup_blocked: number;
  daily_boundary_minute_utc: number;
}

interface MediaRow {
  generation_id: string;
  media_id: string;
  object_key: string;
  state: "reserved" | "expected" | "verified";
  ciphertext_size: number | null;
  ciphertext_sha256: string | null;
  verified_at: number | null;
}

interface CurrentRow extends GenerationRow {
  publisher_member_id: string;
  current_revision: number;
}

function requireMediaBucket(env: Env): R2Bucket {
  if (env.MEDIA === undefined) {
    throw new ApiError(503, "media_storage_unavailable", "The media store is temporarily unavailable.");
  }
  return env.MEDIA;
}

async function signedRequest(
  request: Request,
  env: Env,
  maximumBytes = 16 * 1024,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "member"));
  const body = await readBody(request, maximumBytes);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(403, "active_member_required", "Pairing must be complete before sharing photos.");
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}

async function replayResponse(
  env: Env,
  operation: string,
  member: AuthenticatedMember,
  clientRequestId: string,
  requestHash: string,
): Promise<Response | null> {
  const stored = await storedResponseForMember(
    env,
    operation,
    member,
    clientRequestId,
    requestHash,
  );
  if (stored !== null) await consumeNonceAndTouch(env, member);
  return stored;
}

async function storedResponseForMember(
  env: Env,
  operation: string,
  member: AuthenticatedMember,
  clientRequestId: string,
  requestHash: string,
): Promise<Response | null> {
  let stored: Response | null;
  try {
    stored = await storedIdempotentResponse(
      env,
      operation,
      member.id,
      clientRequestId,
      requestHash,
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return stored;
}

async function mutationRequestHash(request: Request, body: Uint8Array): Promise<string> {
  return sha256Base64url(encodeCanonicalFields([
    "NW1.IDEMPOTENCY",
    "1",
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    await sha256Base64url(body),
  ]));
}

async function consumeAndThrow(
  env: Env,
  member: AuthenticatedMember,
  error: ApiError,
): Promise<never> {
  await consumeNonce(env, member);
  throw error;
}

async function bestEffortConsumeNonce(
  env: Env,
  member: AuthenticatedMember,
): Promise<void> {
  try {
    await consumeNonce(env, member);
  } catch {
    // Preserve the original operation error. Replay or transient D1 failure
    // must not replace a more specific R2/integrity response.
  }
}

function mediaItems(value: unknown, descriptors: boolean): Array<{
  mediaId: string;
  ciphertextSize?: number;
  ciphertextSHA256?: string;
}> {
  if (!Array.isArray(value) || value.length < 1 || value.length > 20) {
    throw new ApiError(400, "invalid_items", "items must contain between 1 and 20 unique media objects.");
  }
  const parsed = value.map((itemValue) => {
    const item = asObject(itemValue);
    exactKeys(item, descriptors
      ? ["mediaId", "ciphertextSize", "ciphertextSHA256"]
      : ["mediaId"]);
    const mediaId = binaryField(item, "mediaId", 16);
    if (!descriptors) return { mediaId };
    return {
      mediaId,
      ciphertextSize: integerField(
        item,
        "ciphertextSize",
        minimumChaChaCombinedBytes,
        maximumMediaCiphertextBytes,
      ),
      ciphertextSHA256: binaryField(item, "ciphertextSHA256", 32),
    };
  });
  const sorted = [...parsed].sort((left, right) =>
    left.mediaId < right.mediaId ? -1 : left.mediaId > right.mediaId ? 1 : 0
  );
  if (parsed.some((item, index) => item.mediaId !== sorted[index]?.mediaId)) {
    throw new ApiError(400, "items_not_sorted", "items must be sorted by mediaId.");
  }
  if (new Set(parsed.map((item) => item.mediaId)).size !== parsed.length) {
    throw new ApiError(400, "duplicate_media", "mediaId values must be unique.");
  }
  return parsed;
}

function objectKey(prefix: string): string {
  return `v1/${prefix}/${randomBase64url(24)}`;
}

async function sourceForPublisher(
  env: Env,
  member: AuthenticatedMember,
): Promise<SourceRow | null> {
  return env.DB.prepare(
    `SELECT src.id, src.space_id, src.publisher_member_id, src.state,
            src.current_revision, src.last_committed_share_day_key,
            src.cleanup_blocked, storage.object_prefix,
            s.daily_boundary_minute_utc
       FROM sharing_sources AS src
       JOIN sharing_storage_scopes AS storage ON storage.space_id = src.space_id
       JOIN spaces AS s ON s.id = src.space_id
      WHERE src.space_id = ? AND src.publisher_member_id = ?`,
  ).bind(member.spaceId, member.id).first<SourceRow>();
}

async function loadGeneration(
  env: Env,
  generationId: string,
): Promise<GenerationRow | null> {
  return env.DB.prepare(
    `SELECT g.*, src.current_revision AS source_current_revision,
            src.state AS source_state, src.cleanup_blocked,
            s.daily_boundary_minute_utc
       FROM sharing_generations AS g
       JOIN sharing_sources AS src ON src.id = g.source_id
       JOIN spaces AS s ON s.id = g.space_id
      WHERE g.id = ?`,
  ).bind(generationId).first<GenerationRow>();
}

async function loadMedia(env: Env, generationId: string): Promise<MediaRow[]> {
  const result = await env.DB.prepare(
    `SELECT generation_id, media_id, object_key, state, ciphertext_size,
            ciphertext_sha256, verified_at
       FROM sharing_generation_media
      WHERE generation_id = ? ORDER BY media_id ASC`,
  ).bind(generationId).all<MediaRow>();
  return result.results;
}

function requirePublisherGeneration(
  generation: GenerationRow | null,
  member: AuthenticatedMember,
): asserts generation is GenerationRow {
  if (
    generation === null ||
    generation.space_id !== member.spaceId ||
    generation.publisher_member_id !== member.id
  ) {
    throw new ApiError(404, "generation_not_found", "The generation was not found.");
  }
  if (generation.source_state !== "active") {
    throw new ApiError(410, "sharing_revoked", "This sharing source is no longer active.");
  }
}

function reservedItem(mediaId: string): Record<string, unknown> {
  return { mediaId, state: "reserved" };
}

function descriptorItem(row: MediaRow): Record<string, unknown> {
  return {
    mediaId: row.media_id,
    ciphertextSize: row.ciphertext_size,
    ciphertextSHA256: row.ciphertext_sha256,
    state: row.state,
  };
}

export async function reserveGeneration(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId", "items"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const items = mediaItems(object.items, false);
  const requestHash = await mutationRequestHash(request, body);
  const existing = await replayResponse(
    env,
    "reserve-generation",
    member,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) return existing;

  const space = await env.DB.prepare(
    `SELECT daily_boundary_minute_utc
       FROM spaces WHERE id = ? AND state = 'active'`,
  ).bind(member.spaceId).first<{ daily_boundary_minute_utc: number }>();
  if (space === null) {
    return consumeAndThrow(env, member, new ApiError(410, "sharing_revoked", "Sharing is no longer active."));
  }
  let source = await sourceForPublisher(env, member);
  if (source?.cleanup_blocked === 1) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(409, "previous_generation_cleanup_pending", "The prior generation is still being removed."),
    );
  }

  const dayKey = shareDayKey(member.now, space.daily_boundary_minute_utc);
  const nextDay = nextShareDayBoundary(dayKey, space.daily_boundary_minute_utc);
  const expiresAt = Math.min(member.now + 3600, nextDay);
  if (expiresAt <= member.now) {
    return consumeAndThrow(env, member, new ApiError(409, "generation_day_expired", "The share day has ended."));
  }

  const sourceId = source?.id ?? randomBase64url(16);
  const prefixCandidate = source?.object_prefix ?? randomBase64url(24);
  const generationId = randomBase64url(16);
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    source: { id: sourceId, publisherMemberId: member.id },
    generation: {
      id: generationId,
      state: "reserved",
      shareDayKey: dayKey,
      itemCount: items.length,
      createdAt: member.now,
      expiresAt,
    },
    items: items.map((item) => reservedItem(item.mediaId)),
  };

  const statements: D1PreparedStatement[] = [...nonceStatements(env, member)];
  if (source === null) {
    statements.push(
      env.DB.prepare(
        `INSERT INTO sharing_storage_scopes(space_id, object_prefix, created_at)
         VALUES (?, ?, ?) ON CONFLICT(space_id) DO NOTHING`,
      ).bind(member.spaceId, prefixCandidate, member.now),
      env.DB.prepare(
        `INSERT INTO space_deletion_jobs(
           space_id, state, requires_object_deletion, created_at
         ) VALUES (?, 'armed', 1, ?)
         ON CONFLICT(space_id) DO UPDATE SET requires_object_deletion = 1
           WHERE space_deletion_jobs.state = 'armed'`,
      ).bind(member.spaceId, member.now),
      env.DB.prepare(
        `INSERT INTO sharing_sources(
           id, space_id, publisher_member_id, state, created_at, updated_at
         ) VALUES (?, ?, ?, 'active', ?, ?)`,
      ).bind(sourceId, member.spaceId, member.id, member.now, member.now),
    );
  }
  statements.push(
    env.DB.prepare(
      `INSERT INTO sharing_daily_freezes(
         source_id, share_day_key, generation_id, created_at, expires_at
       ) VALUES (?, ?, ?, ?, ?)`,
    ).bind(sourceId, dayKey, generationId, member.now, nextDay),
    env.DB.prepare(
      `INSERT INTO sharing_generations(
         id, source_id, space_id, publisher_member_id, share_day_key, state,
         item_count, reserve_request_hash, created_at, staging_expires_at
       ) VALUES (?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?)`,
    ).bind(
      generationId,
      sourceId,
      member.spaceId,
      member.id,
      dayKey,
      items.length,
      requestHash,
      member.now,
      expiresAt,
    ),
    ...items.map((item) => env.DB.prepare(
      `INSERT INTO sharing_generation_media(
         generation_id, media_id, object_key, state
       ) VALUES (
         ?, ?,
         'v1/' || (SELECT object_prefix FROM sharing_storage_scopes WHERE space_id = ?) || '/' || ?,
         'reserved'
       )`,
    ).bind(generationId, item.mediaId, member.spaceId, randomBase64url(24))),
    idempotencyStatement(
      env,
      "reserve-generation",
      member.id,
      clientRequestId,
      member.spaceId,
      requestHash,
      201,
      responseBody,
      member.now,
    ),
    activityStatement(env, member),
  );

  try {
    await env.DB.batch(statements);
  } catch {
    const raced = await replayResponse(
      env,
      "reserve-generation",
      member,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    source = await sourceForPublisher(env, member);
    const daily = source === null
      ? null
      : await env.DB.prepare(
        "SELECT id FROM sharing_generations WHERE source_id = ? AND share_day_key = ?",
      ).bind(source.id, dayKey).first<{ id: string }>();
    await consumeNonce(env, member);
    throw new ApiError(
      409,
      daily === null ? "generation_reservation_conflict" : "daily_generation_exists",
      daily === null
        ? "The generation could not be reserved."
        : "This source already froze its generation for the share day.",
    );
  }
  return jsonResponse(responseBody, 201);
}

export async function registerDescriptors(
  request: Request,
  env: Env,
  generationIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId", "items"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const items = mediaItems(object.items, true);
  const requestHash = await mutationRequestHash(request, body);
  const existing = await replayResponse(
    env,
    "register-generation-descriptors",
    member,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) return existing;

  const generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (
    generation.state === "superseded" ||
    generation.state === "expired" ||
    (generation.state === "committed" && (generation.content_expires_at ?? 0) <= member.now) ||
    ((generation.state === "reserved" || generation.state === "uploading" || generation.state === "prepared") &&
      generation.staging_expires_at <= member.now)
  ) {
    return consumeAndThrow(env, member, new ApiError(404, "generation_not_found", "The generation is no longer available."));
  }
  if (generation.state !== "reserved" || generation.staging_expires_at <= member.now) {
    return consumeAndThrow(env, member, new ApiError(409, "invalid_generation_state", "Descriptors can no longer be registered."));
  }
  const existingMedia = await loadMedia(env, generationId);
  if (
    existingMedia.length !== items.length ||
    existingMedia.some((row, index) => row.media_id !== items[index]?.mediaId)
  ) {
    return consumeAndThrow(env, member, new ApiError(409, "descriptor_set_mismatch", "Descriptors must exactly match the reservation."));
  }
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    generationId,
    state: "uploading",
    items: items.map((item) => ({ ...item, state: "expected" })),
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO sharing_descriptor_events(
           generation_id, actor_member_id, client_request_id, request_hash, created_at
         ) VALUES (?, ?, ?, ?, ?)`,
      ).bind(generationId, member.id, clientRequestId, requestHash, member.now),
      ...items.map((item) => env.DB.prepare(
        `UPDATE sharing_generation_media
            SET state = 'expected', ciphertext_size = ?, ciphertext_sha256 = ?
          WHERE generation_id = ? AND media_id = ? AND state = 'reserved'
            AND ciphertext_size IS NULL AND ciphertext_sha256 IS NULL`,
      ).bind(item.ciphertextSize, item.ciphertextSHA256, generationId, item.mediaId)),
      idempotencyStatement(
        env,
        "register-generation-descriptors",
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
    const raced = await replayResponse(
      env,
      "register-generation-descriptors",
      member,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "descriptor_registration_conflict", "Descriptors are immutable after registration.");
  }
  return jsonResponse(responseBody);
}

function requireOctetStream(request: Request): void {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/octet-stream") {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/octet-stream.");
  }
  if (request.headers.has("content-encoding")) {
    throw new ApiError(415, "content_encoding_not_allowed", "Content-Encoding is not accepted.");
  }
}

function r2Checksum(object: R2Object): string | null {
  const value = object.checksums.sha256;
  return value === undefined ? null : base64urlEncode(new Uint8Array(value));
}

async function ensureR2Object(
  bucket: R2Bucket,
  key: string,
  body: Uint8Array,
  digestBytes: Uint8Array,
  digestValue: string,
): Promise<void> {
  const stored = await bucket.put(key, body, {
    onlyIf: { etagDoesNotMatch: "*" },
    sha256: digestBytes,
    httpMetadata: {
      contentType: "application/octet-stream",
      cacheControl: "no-store",
    },
  });
  const object = stored ?? await bucket.head(key);
  if (
    object === null ||
    object.size !== body.length ||
    r2Checksum(object) !== digestValue
  ) {
    throw new ApiError(409, "object_integrity_conflict", "Stored ciphertext does not match its descriptor.");
  }
}

async function rearmObjectDeletion(
  env: Env,
  objectKeyValue: string,
  spaceId: string,
  sourceId: string,
  reason: "staging_expired" | "reprepare",
  now: number,
): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO sharing_object_deletions(
         object_key, space_id, source_id, reason, state, not_before,
         attempts, created_at, deleted_at
       ) VALUES (?, ?, ?, ?, 'pending', ?, 0, ?, NULL)
       ON CONFLICT(object_key) DO UPDATE SET
         state = 'pending',
         reason = excluded.reason,
         not_before = MAX(sharing_object_deletions.not_before, excluded.not_before),
         attempts = sharing_object_deletions.attempts + 1,
         deleted_at = NULL`,
    ).bind(
      objectKeyValue,
      spaceId,
      sourceId,
      reason,
      now + uploadCloseGraceSeconds,
      now,
    ),
    env.DB.prepare(
      `UPDATE sharing_sources
          SET cleanup_blocked = 1, updated_at = ?
        WHERE id = ? AND state = 'active'`,
    ).bind(now, sourceId),
  ]);
}

export async function uploadMedia(
  request: Request,
  env: Env,
  generationIdValue: string,
  mediaIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const mediaId = opaqueId(mediaIdValue, "media");
  requireOctetStream(request);
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env, maximumMediaCiphertextBytes);
  try {
  if (body.length < minimumChaChaCombinedBytes) {
    return consumeAndThrow(env, member, new ApiError(400, "ciphertext_too_small", "The ciphertext is too small."));
  }
  const [digestBytes, digestValue, generation, media] = await Promise.all([
    sha256(body),
    sha256Base64url(body),
    loadGeneration(env, generationId),
    env.DB.prepare(
      `SELECT generation_id, media_id, object_key, state, ciphertext_size,
              ciphertext_sha256, verified_at
         FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`,
    ).bind(generationId, mediaId).first<MediaRow>(),
  ]);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (
    media === null ||
    media.ciphertext_size !== body.length ||
    media.ciphertext_sha256 !== digestValue
  ) {
    return consumeAndThrow(env, member, new ApiError(409, "ciphertext_descriptor_mismatch", "Ciphertext does not match its registered descriptor."));
  }
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    generationId,
    mediaId,
    ciphertextSize: body.length,
    ciphertextSHA256: digestValue,
    state: "verified",
  };
  if (media.state === "verified") {
    await consumeNonce(env, member);
    const head = await bucket.head(media.object_key);
    if (head === null || head.size !== body.length || r2Checksum(head) !== digestValue) {
      throw new ApiError(503, "stored_object_unavailable", "Verified ciphertext is temporarily unavailable.");
    }
    await activityStatement(env, member).run();
    return jsonResponse(responseBody);
  }
  if (
    generation.state !== "uploading" ||
    generation.staging_expires_at <= member.now ||
    media.state !== "expected"
  ) {
    await consumeNonce(env, member);
    if (await bucket.head(media.object_key) !== null) {
      await rearmObjectDeletion(
        env,
        media.object_key,
        member.spaceId,
        generation.source_id,
        "staging_expired",
        member.now,
      );
    }
    throw new ApiError(409, "upload_closed", "This generation no longer accepts media uploads.");
  }

  // R2 is outside D1 transactions. Claim the signed nonce before the first
  // object-store side effect; retries use a fresh nonce and reconcile the same
  // server-reserved object key.
  await consumeNonce(env, member);
  await ensureR2Object(bucket, media.object_key, body, digestBytes, digestValue);
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO sharing_media_verification_events(
           generation_id, media_id, actor_member_id, object_key,
           ciphertext_size, ciphertext_sha256, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        generationId,
        mediaId,
        member.id,
        media.object_key,
        body.length,
        digestValue,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await env.DB.prepare(
      `SELECT state, ciphertext_size, ciphertext_sha256
         FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`,
    ).bind(generationId, mediaId).first<MediaRow>();
    if (
      raced?.state === "verified" &&
      raced.ciphertext_size === body.length &&
      raced.ciphertext_sha256 === digestValue
    ) {
      await activityStatement(env, member).run();
      return jsonResponse(responseBody);
    }
    // A close/revoke may win after R2 put. The armed prefix sweep and this
    // explicit delayed deletion both cover the late object.
    await rearmObjectDeletion(
      env,
      media.object_key,
      member.spaceId,
      generation.source_id,
      "staging_expired",
      member.now,
    );
    throw new ApiError(409, "upload_closed", "This generation closed while the upload was finishing.");
  }
  return jsonResponse(responseBody);
  } catch (error) {
    await bestEffortConsumeNonce(env, member);
    throw error;
  }
}

export async function prepareGeneration(
  request: Request,
  env: Env,
  generationIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const requestHash = await mutationRequestHash(request, body);
  const existing = await storedResponseForMember(
    env,
    "prepare-generation",
    member,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) {
    const payload = await existing.clone().json() as { prepareExpiresAt?: unknown };
    if (typeof payload.prepareExpiresAt !== "number" || payload.prepareExpiresAt <= member.now) {
      return consumeAndThrow(env, member, new ApiError(409, "prepare_expired", "This prepare attempt expired; use a new clientRequestId."));
    }
    await consumeNonceAndTouch(env, member);
    return existing;
  }

  const generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (
    generation.staging_expires_at <= member.now ||
    (generation.state !== "uploading" && generation.state !== "prepared") ||
    (generation.state === "prepared" && (generation.rotation_anchor_utc ?? 0) > member.now)
  ) {
    return consumeAndThrow(env, member, new ApiError(409, "invalid_generation_state", "The generation cannot be prepared now."));
  }
  const verified = await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM sharing_generation_media
      WHERE generation_id = ? AND state = 'verified'`,
  ).bind(generationId).first<{ count: number }>();
  if ((verified?.count ?? 0) !== generation.item_count) {
    return consumeAndThrow(env, member, new ApiError(409, "media_incomplete", "Every canonical ciphertext must be verified first."));
  }
  const currentDay = shareDayKey(member.now, generation.daily_boundary_minute_utc);
  if (currentDay !== generation.share_day_key) {
    return consumeAndThrow(env, member, new ApiError(409, "generation_day_expired", "Missed share days are not backfilled."));
  }
  const anchor = nextRotationAnchor(member.now);
  if (anchor >= generation.staging_expires_at) {
    return consumeAndThrow(env, member, new ApiError(409, "generation_day_expired", "There is not enough time to commit this share day."));
  }
  const attemptId = randomBase64url(16);
  const attemptRevision = generation.prepare_attempt_revision + 1;
  const reservedRevision = generation.source_current_revision + 1;
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    generationId,
    state: "prepared",
    prepareAttemptRevision: attemptRevision,
    prepareAttemptId: attemptId,
    reservedRevision,
    rotationAnchorUTC: anchor,
    prepareExpiresAt: anchor,
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO sharing_prepare_events(
           generation_id, actor_member_id, client_request_id, request_hash,
           attempt_id, attempt_revision, reserved_revision,
           rotation_anchor_utc, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        generationId,
        member.id,
        clientRequestId,
        requestHash,
        attemptId,
        attemptRevision,
        reservedRevision,
        anchor,
        member.now,
      ),
      idempotencyStatement(
        env,
        "prepare-generation",
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
    const raced = await storedResponseForMember(
      env,
      "prepare-generation",
      member,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) {
      const payload = await raced.clone().json() as { prepareExpiresAt?: unknown };
      if (typeof payload.prepareExpiresAt === "number" && payload.prepareExpiresAt > member.now) {
        await consumeNonceAndTouch(env, member);
        return raced;
      }
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "prepare_conflict", "The generation prepare state changed.");
  }
  return jsonResponse(responseBody);
}

export async function uploadManifest(
  request: Request,
  env: Env,
  generationIdValue: string,
  attemptIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const attemptId = opaqueId(attemptIdValue, "prepare attempt");
  requireOctetStream(request);
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env, maximumManifestCiphertextBytes);
  try {
  if (body.length < minimumChaChaCombinedBytes) {
    return consumeAndThrow(env, member, new ApiError(400, "ciphertext_too_small", "The ciphertext is too small."));
  }
  const [digestBytes, digestValue] = await Promise.all([sha256(body), sha256Base64url(body)]);
  let generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (
    generation.state !== "prepared" ||
    generation.prepare_attempt_id !== attemptId ||
    (generation.prepare_expires_at ?? 0) <= member.now
  ) {
    await consumeNonce(env, member);
    if (
      generation.manifest_object_key !== null &&
      await bucket.head(generation.manifest_object_key) !== null
    ) {
      await rearmObjectDeletion(
        env,
        generation.manifest_object_key,
        member.spaceId,
        generation.source_id,
        "reprepare",
        member.now,
      );
    }
    throw new ApiError(409, "prepare_expired", "This prepare attempt is no longer current.");
  }
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    generationId,
    prepareAttemptRevision: generation.prepare_attempt_revision,
    prepareAttemptId: attemptId,
    ciphertextSize: body.length,
    ciphertextSHA256: digestValue,
    state: "verified",
  };
  if (generation.manifest_verified_at !== null) {
    if (
      generation.manifest_object_key === null ||
      generation.manifest_ciphertext_size !== body.length ||
      generation.manifest_ciphertext_sha256 !== digestValue
    ) {
      return consumeAndThrow(env, member, new ApiError(409, "manifest_immutable", "The prepared manifest is immutable."));
    }
    await consumeNonce(env, member);
    const head = await bucket.head(generation.manifest_object_key);
    if (head === null || head.size !== body.length || r2Checksum(head) !== digestValue) {
      throw new ApiError(503, "stored_object_unavailable", "Verified manifest is temporarily unavailable.");
    }
    await activityStatement(env, member).run();
    return jsonResponse(responseBody);
  }

  // Reserve the nonce before the manifest key reservation and before R2.
  await consumeNonce(env, member);
  if (generation.manifest_object_key === null) {
    const scope = await env.DB.prepare(
      "SELECT object_prefix FROM sharing_storage_scopes WHERE space_id = ?",
    ).bind(member.spaceId).first<{ object_prefix: string }>();
    if (scope === null) {
      throw new ApiError(409, "storage_scope_missing", "The private storage scope is not armed.");
    }
    const candidate = objectKey(scope.object_prefix);
    await env.DB.prepare(
      `UPDATE sharing_generations
          SET manifest_object_key = ?
        WHERE id = ? AND state = 'prepared' AND prepare_attempt_id = ?
          AND prepare_expires_at > ? AND manifest_object_key IS NULL`,
    ).bind(candidate, generationId, attemptId, member.now).run();
    generation = await loadGeneration(env, generationId);
    try {
      requirePublisherGeneration(generation, member);
    } catch (error) {
      throw error;
    }
  }
  if (
    generation.manifest_object_key === null ||
    generation.state !== "prepared" ||
    generation.prepare_attempt_id !== attemptId ||
    (generation.prepare_expires_at ?? 0) <= member.now
  ) {
    throw new ApiError(409, "prepare_expired", "This prepare attempt closed while reserving the manifest.");
  }

  await ensureR2Object(
    bucket,
    generation.manifest_object_key,
    body,
    digestBytes,
    digestValue,
  );
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO sharing_manifest_verification_events(
           generation_id, attempt_id, actor_member_id, object_key,
           ciphertext_size, ciphertext_sha256, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        generationId,
        attemptId,
        member.id,
        generation.manifest_object_key,
        body.length,
        digestValue,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await loadGeneration(env, generationId);
    if (
      raced?.prepare_attempt_id === attemptId &&
      raced.manifest_verified_at !== null &&
      raced.manifest_ciphertext_size === body.length &&
      raced.manifest_ciphertext_sha256 === digestValue
    ) {
      await activityStatement(env, member).run();
      return jsonResponse(responseBody);
    }
    await rearmObjectDeletion(
      env,
      generation.manifest_object_key,
      member.spaceId,
      generation.source_id,
      "reprepare",
      member.now,
    );
    throw new ApiError(409, "prepare_expired", "This prepare attempt closed while the upload was finishing.");
  }
  return jsonResponse(responseBody);
  } catch (error) {
    await bestEffortConsumeNonce(env, member);
    throw error;
  }
}

export async function commitGeneration(
  request: Request,
  env: Env,
  generationIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "prepareAttemptId",
    "prepareAttemptRevision",
    "reservedRevision",
    "manifestCiphertextSHA256",
  ]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const attemptId = binaryField(object, "prepareAttemptId", 16);
  const attemptRevision = integerField(object, "prepareAttemptRevision", 1, 2_147_483_647);
  const reservedRevision = integerField(object, "reservedRevision", 1, 2_147_483_647);
  const manifestHash = binaryField(object, "manifestCiphertextSHA256", 32);
  const requestHash = await mutationRequestHash(request, body);
  const existing = await replayResponse(
    env,
    "commit-generation",
    member,
    clientRequestId,
    requestHash,
  );
  if (existing !== null) return existing;

  const generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  const currentDay = shareDayKey(member.now, generation.daily_boundary_minute_utc);
  const responseBody = {
    protocolVersion: PROTOCOL_VERSION,
    sourceId: generation.source_id,
    generationId,
    shareDayKey: generation.share_day_key,
    revision: reservedRevision,
    prepareAttemptId: attemptId,
    prepareAttemptRevision: attemptRevision,
    reservedRevision,
    rotationAnchorUTC: generation.rotation_anchor_utc,
    committedAt: member.now,
    contentExpiresAt: member.now + sharingContentTTLSeconds,
    state: "current",
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO sharing_commit_events(
           generation_id, actor_member_id, client_request_id, request_hash,
           attempt_id, attempt_revision, reserved_revision,
           manifest_ciphertext_sha256, server_share_day_key, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        generationId,
        member.id,
        clientRequestId,
        requestHash,
        attemptId,
        attemptRevision,
        reservedRevision,
        manifestHash,
        currentDay,
        member.now,
      ),
      idempotencyStatement(
        env,
        "commit-generation",
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
    const raced = await replayResponse(
      env,
      "commit-generation",
      member,
      clientRequestId,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "commit_conflict", "The latest prepared generation could not be committed.");
  }
  return jsonResponse(responseBody);
}

function generationManifest(generation: GenerationRow): Record<string, unknown> | null {
  if (
    generation.manifest_verified_at === null ||
    generation.manifest_ciphertext_size === null ||
    generation.manifest_ciphertext_sha256 === null
  ) return null;
  return {
    ciphertextSize: generation.manifest_ciphertext_size,
    ciphertextSHA256: generation.manifest_ciphertext_sha256,
  };
}

export async function getGeneration(
  request: Request,
  env: Env,
  generationIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest(request, env);
  requireEmptyBody(body);
  const generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (
    generation.state === "superseded" ||
    generation.state === "expired" ||
    (generation.state === "committed" && (generation.content_expires_at ?? 0) <= member.now) ||
    ((generation.state === "reserved" || generation.state === "uploading" || generation.state === "prepared") &&
      generation.staging_expires_at <= member.now)
  ) {
    return consumeAndThrow(env, member, new ApiError(404, "generation_not_found", "The generation is no longer available."));
  }
  const media = await loadMedia(env, generationId);
  await consumeNonceAndTouch(env, member);
  return jsonResponse({
    protocolVersion: PROTOCOL_VERSION,
    sourceId: generation.source_id,
    publisherMemberId: generation.publisher_member_id,
    generation: {
      id: generation.id,
      state: generation.state,
      shareDayKey: generation.share_day_key,
      itemCount: generation.item_count,
      createdAt: generation.created_at,
      expiresAt: generation.staging_expires_at,
      prepareAttemptRevision: generation.prepare_attempt_revision,
      prepareAttemptId: generation.prepare_attempt_id,
      reservedRevision: generation.reserved_revision,
      rotationAnchorUTC: generation.rotation_anchor_utc,
      prepareExpiresAt: generation.prepare_expires_at,
      manifest: generationManifest(generation),
    },
    items: media.map(descriptorItem),
  });
}

async function loadCurrent(
  env: Env,
  sourceId: string,
  spaceId: string,
  now: number,
): Promise<CurrentRow | null> {
  return env.DB.prepare(
    `SELECT g.*, src.current_revision AS source_current_revision,
            src.current_revision, src.state AS source_state,
            src.cleanup_blocked, src.publisher_member_id,
            s.daily_boundary_minute_utc
       FROM sharing_currents AS current
       JOIN sharing_sources AS src ON src.id = current.source_id
       JOIN sharing_generations AS g ON g.id = current.generation_id
       JOIN spaces AS s ON s.id = src.space_id
      WHERE src.id = ? AND src.space_id = ? AND src.state = 'active'
        AND g.state = 'committed' AND g.content_expires_at > ?`,
  ).bind(sourceId, spaceId, now).first<CurrentRow>();
}

function currentSummary(current: CurrentRow): Record<string, unknown> {
  return {
    generationId: current.id,
    shareDayKey: current.share_day_key,
    revision: current.current_revision,
    rotationAnchorUTC: current.rotation_anchor_utc,
    itemCount: current.item_count,
    committedAt: current.committed_at,
    contentExpiresAt: current.content_expires_at,
  };
}

export async function getSources(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedRequest(request, env);
  requireEmptyBody(body);
  const result = await env.DB.prepare(
    `SELECT src.id, src.publisher_member_id,
            g.id AS generation_id, g.share_day_key, current.revision,
            g.rotation_anchor_utc, g.item_count, g.committed_at, g.content_expires_at
       FROM sharing_sources AS src
       LEFT JOIN sharing_currents AS current ON current.source_id = src.id
       LEFT JOIN sharing_generations AS g
         ON g.id = current.generation_id AND g.content_expires_at > ?
      WHERE src.space_id = ? AND src.state = 'active'
      ORDER BY src.id ASC`,
  ).bind(member.now, member.spaceId).all<{
    id: string;
    publisher_member_id: string;
    generation_id: string | null;
    share_day_key: number | null;
    revision: number | null;
    rotation_anchor_utc: number | null;
    item_count: number | null;
    committed_at: number | null;
    content_expires_at: number | null;
  }>();
  await consumeNonceAndTouch(env, member);
  return jsonResponse({
    protocolVersion: PROTOCOL_VERSION,
    sources: result.results.map((row) => ({
      id: row.id,
      publisherMemberId: row.publisher_member_id,
      current: row.generation_id === null ? null : {
        generationId: row.generation_id,
        shareDayKey: row.share_day_key,
        revision: row.revision,
        rotationAnchorUTC: row.rotation_anchor_utc,
        itemCount: row.item_count,
        committedAt: row.committed_at,
        contentExpiresAt: row.content_expires_at,
      },
    })),
  });
}

function currentETag(sourceId: string, revision: number): string {
  return `"nw1-${sourceId}-${revision}"`;
}

export async function getCurrent(
  request: Request,
  env: Env,
  sourceIdValue: string,
): Promise<Response> {
  const sourceId = opaqueId(sourceIdValue, "source");
  const { body, member } = await signedRequest(request, env);
  requireEmptyBody(body);
  const current = await loadCurrent(env, sourceId, member.spaceId, member.now);
  if (current === null) {
    return consumeAndThrow(env, member, new ApiError(404, "current_unavailable", "This source has no current generation."));
  }
  const etag = currentETag(sourceId, current.current_revision);
  if (request.headers.get("if-none-match") === etag) {
    await consumeNonceAndTouch(env, member);
    return new Response(null, {
      status: 304,
      headers: {
        "Cache-Control": "no-store, max-age=0",
        ETag: etag,
        Pragma: "no-cache",
      },
    });
  }
  const media = await loadMedia(env, current.id);
  await consumeNonceAndTouch(env, member);
  const response = jsonResponse({
    protocolVersion: PROTOCOL_VERSION,
    sourceId,
    publisherMemberId: current.publisher_member_id,
    current: {
      ...currentSummary(current),
      prepareAttemptId: current.prepare_attempt_id,
      prepareAttemptRevision: current.prepare_attempt_revision,
      reservedRevision: current.reserved_revision,
      manifest: generationManifest(current),
      items: media.map((row) => ({
        mediaId: row.media_id,
        ciphertextSize: row.ciphertext_size,
        ciphertextSHA256: row.ciphertext_sha256,
      })),
    },
  });
  response.headers.set("ETag", etag);
  return response;
}

function ciphertextResponse(
  object: R2ObjectBody,
  ciphertextSHA256: string,
): Response {
  return new Response(object.body, {
    headers: {
      "Cache-Control": "no-store, max-age=0",
      "Content-Length": String(object.size),
      "Content-Type": "application/octet-stream",
      ETag: `"sha256-${ciphertextSHA256}"`,
      "Neko-Ciphertext-SHA256": ciphertextSHA256,
      Pragma: "no-cache",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export async function downloadManifest(
  request: Request,
  env: Env,
  generationIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env);
  requireEmptyBody(body);
  const row = await env.DB.prepare(
    `SELECT g.manifest_object_key, g.manifest_ciphertext_size,
            g.manifest_ciphertext_sha256
       FROM sharing_currents AS current
       JOIN sharing_sources AS src ON src.id = current.source_id
       JOIN sharing_generations AS g ON g.id = current.generation_id
      WHERE current.generation_id = ? AND src.space_id = ?
        AND src.state = 'active' AND g.state = 'committed'
        AND g.content_expires_at > ?`,
  ).bind(generationId, member.spaceId, member.now).first<{
    manifest_object_key: string | null;
    manifest_ciphertext_size: number | null;
    manifest_ciphertext_sha256: string | null;
  }>();
  if (
    row?.manifest_object_key === null ||
    row?.manifest_object_key === undefined ||
    row.manifest_ciphertext_size === null ||
    row.manifest_ciphertext_sha256 === null
  ) {
    return consumeAndThrow(env, member, new ApiError(404, "manifest_not_found", "The current manifest was not found."));
  }
  await consumeNonce(env, member);
  const object = await bucket.get(row.manifest_object_key);
  if (
    object === null ||
    object.size !== row.manifest_ciphertext_size ||
    r2Checksum(object) !== row.manifest_ciphertext_sha256
  ) {
    throw new ApiError(503, "stored_object_unavailable", "The current manifest is temporarily unavailable.");
  }
  await activityStatement(env, member).run();
  return ciphertextResponse(object, row.manifest_ciphertext_sha256);
}

export async function downloadMedia(
  request: Request,
  env: Env,
  generationIdValue: string,
  mediaIdValue: string,
): Promise<Response> {
  const generationId = opaqueId(generationIdValue, "generation");
  const mediaId = opaqueId(mediaIdValue, "media");
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env);
  requireEmptyBody(body);
  const row = await env.DB.prepare(
    `SELECT gm.object_key, gm.ciphertext_size, gm.ciphertext_sha256
       FROM sharing_currents AS current
       JOIN sharing_sources AS src ON src.id = current.source_id
       JOIN sharing_generations AS g ON g.id = current.generation_id
       JOIN sharing_generation_media AS gm ON gm.generation_id = g.id
      WHERE current.generation_id = ? AND gm.media_id = ?
        AND src.space_id = ? AND src.state = 'active'
        AND g.state = 'committed' AND g.content_expires_at > ?
        AND gm.state = 'verified'`,
  ).bind(generationId, mediaId, member.spaceId, member.now).first<{
    object_key: string;
    ciphertext_size: number;
    ciphertext_sha256: string;
  }>();
  if (row === null) {
    return consumeAndThrow(env, member, new ApiError(404, "media_not_found", "The current media object was not found."));
  }
  await consumeNonce(env, member);
  const object = await bucket.get(row.object_key);
  if (
    object === null ||
    object.size !== row.ciphertext_size ||
    r2Checksum(object) !== row.ciphertext_sha256
  ) {
    throw new ApiError(503, "stored_object_unavailable", "The current media is temporarily unavailable.");
  }
  await activityStatement(env, member).run();
  return ciphertextResponse(object, row.ciphertext_sha256);
}
