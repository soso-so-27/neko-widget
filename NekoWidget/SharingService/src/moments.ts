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
  sha256,
  sha256Base64url,
  verifyEd25519,
} from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import {
  positiveIntegerSetting,
  reportIngestionRuntimeEnabled,
  type Env,
} from "./env";
import {
  enforceRateLimit,
  parseJsonBody,
  readBody,
  requireEmptyBody,
  transientNetworkKey,
} from "./http";
import { idempotencyStatement, storedIdempotentResponse } from "./idempotency";
import { encodeCanonicalFields, signedRequestTranscript } from "./protocol";
import { momentNotificationEventStatements } from "./push";
import { REACTION_USAGE_RETENTION_DAYS } from "./reactions";
import {
  asObject,
  binaryField,
  exactKeys,
  integerField,
  opaqueId,
  stringField,
  uuidField,
  type JsonRecord,
} from "./validation";

export const MOMENT_PROTOCOL_VERSION = 2 as const;
export const MAXIMUM_MOMENT_CIPHERTEXT_BYTES = 1024 * 1024;
export const MOMENT_DAILY_QUOTA = 5;
export const MOMENT_RESERVATION_ATTEMPT_LIMIT = 3;
export const MOMENT_UPLOAD_TTL_SECONDS = 60 * 60;
export const MOMENT_REPORT_ONLY_TTL_SECONDS = 24 * 60 * 60;
export const MOMENT_UNRECEIVED_TTL_SECONDS = 30 * 86_400;
export const MOMENT_ACKNOWLEDGED_TTL_SECONDS = 7 * 86_400;
export const REPORT_CONTENT_TTL_SECONDS = 7 * 86_400;
export const REPORT_DAILY_ATTEMPT_QUOTA = 10;
const minimumAEADCiphertextBytes = 29;
const objectDeletionGraceSeconds = 600;
const cleanupRowLimit = 1_000;
// Keep ample headroom under D1's 1,000-query invocation limit because this
// runs in the same cron invocation as the bounded legacy cleanup.
// This phase has its own five-minute cron invocation. One thousand objects per
// run yields 288,000/day of physical deletion capacity, above the 10k-member
// worst-case ingress of 5 moments x 3 bounded reservations + 10 report attempts
// (250,000/day).
export const MOMENT_CLEANUP_OBJECT_LIMIT = 1_000;
// Each fallback prefix may need delete + two empty observations. At 150/type
// per five-minute v2-only cron, 10,000 synchronized revokes converge within
// 17 hours while keeping worst-case Worker subrequests below the configured
// 1,200 limit and D1 queries well below 1,000.
export const MOMENT_REVOKED_SCOPE_LIMIT = 150;
const d1IdentifierChunkSize = 99;
const d1CASTupleChunkSize = 48;

// These lists are deliberately code-reviewed and fail closed. Shipping a new
// client filter or policy text requires a Worker release that explicitly
// accepts its version.
const allowedClientModerationVersions = new Set([1]);
const allowedSenderPolicyVersions = new Set([1]);
const allowedReporterConsentVersions = new Set([1]);
const allowedModerationKeyIDs = new Set(["moderation-v1"]);

type MomentKind = "live" | "memory" | "bootstrap";
type MomentState = "reserved" | "uploaded" | "committed" | "expired" | "deleted";

interface MomentContextRow {
  participant_id: string;
  device_id: string;
  current_key_epoch: number;
  membership_revision: number;
  lineage_id: string;
}

interface ReportCredentialRow extends MomentContextRow {
  space_id: string;
  role: "owner" | "member";
  participant_state: "pending" | "active" | "revoked" | "expired";
  participant_report_only_until: number | null;
  device_state: "pending" | "active" | "revoked" | "expired";
  device_report_only_until: number | null;
  agreement_public_key: string;
  signing_public_key: string;
  space_state: "active" | "revoked";
}

interface ReportSignedRequest {
  body: Uint8Array;
  member: AuthenticatedMember;
  context: MomentContextRow;
  reportOnly: boolean;
}

interface MomentRow {
  id: string;
  client_moment_id: string;
  space_id: string;
  sender_participant_id: string;
  sender_device_id: string;
  kind: MomentKind;
  key_epoch: number;
  state: MomentState;
  object_key: string;
  ciphertext_size: number;
  ciphertext_sha256: string;
  quota_day_key: number;
  quota_counted: number;
  reservation_attempt: number;
  reserve_request_hash: string;
  created_at: number;
  upload_expires_at: number;
  uploaded_at: number | null;
  committed_at: number | null;
  unreceived_expires_at: number | null;
  closed_at: number | null;
}

interface DeliveryRow {
  moment_id: string;
  recipient_participant_id: string;
  state: "pending" | "acknowledged" | "expired" | "revoked";
  created_at: number;
  access_expires_at: number;
  acknowledged_at: number | null;
  revoked_at: number | null;
}

interface ReportRow {
  id: string;
  moment_id: string;
  space_id: string;
  reporter_participant_id: string;
  reporter_device_id: string;
  accused_participant_id: string;
  reason_code: "objectionable" | "harassment" | "privacy" | "other";
  moderation_key_id: string;
  state: MomentState;
  object_key: string;
  ciphertext_size: number;
  ciphertext_sha256: string;
  dedupe_key: string;
  reserve_request_hash: string;
  created_at: number;
  upload_expires_at: number;
  uploaded_at: number | null;
  committed_at: number | null;
  content_expires_at: number | null;
  closed_at: number | null;
}

interface ParticipantRow {
  id: string;
}

function changeCursorValue(value: string): string {
  if (!/^(?:[A-Za-z0-9_-]{22}|[0-9a-f]{32})$/u.test(value)) {
    throw new ApiError(404, "not_found", "cursor was not found.");
  }
  return value;
}

function protocolVersion2(object: JsonRecord): 2 {
  if (object.protocolVersion !== MOMENT_PROTOCOL_VERSION) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
  return MOMENT_PROTOCOL_VERSION;
}

function oneOf<T extends string>(
  object: JsonRecord,
  key: string,
  values: readonly T[],
): T {
  const value = stringField(object, key);
  if (!values.some((candidate) => candidate === value)) {
    throw new ApiError(400, "invalid_field", `${key} is not supported.`);
  }
  return value as T;
}

function acceptedAtSeconds(object: JsonRecord, key: string, now: number): number {
  const value = stringField(object, key);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/u.test(value)) {
    throw new ApiError(400, "invalid_field", `${key} must be an ISO-8601 UTC date.`);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) {
    throw new ApiError(400, "invalid_field", `${key} must be an ISO-8601 UTC date.`);
  }
  const seconds = Math.floor(milliseconds / 1000);
  if (seconds > now + 300) {
    throw new ApiError(400, "invalid_field", `${key} cannot be in the future.`);
  }
  return seconds;
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

function requireMediaBucket(env: Env): R2Bucket {
  if (env.MEDIA === undefined) {
    throw new ApiError(503, "media_storage_unavailable", "The media store is temporarily unavailable.");
  }
  return env.MEDIA;
}

function requireModerationBucket(env: Env): R2Bucket {
  if (env.MODERATION_MEDIA === undefined) {
    throw new ApiError(
      503,
      "moderation_storage_unavailable",
      "The moderation evidence store is temporarily unavailable.",
    );
  }
  return env.MODERATION_MEDIA;
}

async function signedRequest(
  request: Request,
  env: Env,
  maximumBytes = 16 * 1024,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "moment-member"));
  const body = await readBody(request, maximumBytes);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    if (
      member.spaceState !== "active"
      || member.state === "revoked"
      || member.state === "expired"
    ) {
      const window = await env.DB.prepare(
        `SELECT MIN(participant.report_only_until, device.report_only_until) AS report_only_until
           FROM moment_participants AS participant
           JOIN moment_devices AS device ON device.participant_id = participant.id
          WHERE participant.id = ? AND device.id = ?
            AND participant.space_id = ?`,
      ).bind(
        member.momentParticipantId,
        member.deviceId,
        member.spaceId,
      ).first<{ report_only_until: number | null }>();
      if (window?.report_only_until !== null && window?.report_only_until !== undefined
          && window.report_only_until > member.now) {
        throw new ApiError(
          410,
          "report_only",
          "Normal sharing access ended; report-only access remains temporarily available.",
          { reportOnlyUntil: window.report_only_until },
        );
      }
    }
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

function reportNonceStatements(
  env: Env,
  context: MomentContextRow,
  nonce: string,
  now: number,
): D1PreparedStatement[] {
  return [
    env.DB.prepare(
      "DELETE FROM moment_report_request_nonces WHERE device_id = ? AND expires_at < ?",
    ).bind(context.device_id, now),
    env.DB.prepare(
      `INSERT INTO moment_report_request_nonces(
         device_id, nonce, created_at, expires_at
       ) VALUES (?, ?, ?, ?)`,
    ).bind(context.device_id, nonce, now, now + 601),
  ];
}

function reportActivityStatement(
  env: Env,
  member: AuthenticatedMember,
): D1PreparedStatement {
  const metadataExpiresAt = member.now
    + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2_592_000);
  return env.DB.prepare(
    `UPDATE spaces
        SET last_activity_at = ?, metadata_expires_at = ?
      WHERE id = ? AND state = 'active'
        AND EXISTS (
          SELECT 1 FROM members
           WHERE id = ? AND space_id = spaces.id AND state = 'active'
        )`,
  ).bind(member.now, metadataExpiresAt, member.spaceId, member.id);
}

async function consumeReportNonce(
  env: Env,
  member: AuthenticatedMember,
  context: MomentContextRow,
): Promise<void> {
  try {
    await env.DB.batch(reportNonceStatements(env, context, member.nonce, member.now));
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}

async function consumeReportNonceAndTouch(
  env: Env,
  member: AuthenticatedMember,
  context: MomentContextRow,
): Promise<void> {
  try {
    await env.DB.batch([
      ...reportNonceStatements(env, context, member.nonce, member.now),
      reportActivityStatement(env, member),
    ]);
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}

async function consumeReportAndThrow(
  env: Env,
  member: AuthenticatedMember,
  context: MomentContextRow,
  error: unknown,
): Promise<never> {
  await consumeReportNonce(env, member, context);
  throw error;
}

async function requireReportIngestionRuntime(
  env: Env,
  member: AuthenticatedMember,
  context: MomentContextRow,
): Promise<void> {
  if (reportIngestionRuntimeEnabled(env)) return;
  // Authentication and signature verification happen before this gate. Burn
  // the signed nonce as well so a request rejected during an emergency stop
  // cannot be replayed after ingestion is enabled again.
  await consumeReportNonce(env, member, context);
  throw new ApiError(
    503,
    "report_ingestion_runtime_disabled",
    "New reports are temporarily unavailable.",
  );
}

async function signedReportRequest(
  request: Request,
  env: Env,
  maximumBytes = 16 * 1024,
): Promise<ReportSignedRequest> {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "moment-report"));
  const body = await readBody(request, maximumBytes);
  if (request.headers.get("neko-protocol-version") !== "1") {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  let credentialID: string;
  let requestedDeviceID: string | null = null;
  try {
    credentialID = opaqueId(request.headers.get("neko-member-id") ?? "", "member");
    const rawDeviceID = request.headers.get("neko-device-id");
    if (rawDeviceID !== null) {
      requestedDeviceID = opaqueId(rawDeviceID, "device");
    }
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
  const devicePredicate = requestedDeviceID === null
    ? "device.legacy_member_id = participant.legacy_member_id"
    : "device.id = ?";
  const credentialStatement = env.DB.prepare(
    `SELECT participant.id AS participant_id, device.id AS device_id,
            space.current_key_epoch, space.membership_revision, space.lineage_id,
            participant.space_id, participant.role,
            participant.state AS participant_state,
            participant.report_only_until AS participant_report_only_until,
            device.state AS device_state,
            device.report_only_until AS device_report_only_until,
            device.agreement_public_key, device.signing_public_key,
            space.state AS space_state
       FROM moment_devices AS device
       JOIN moment_participants AS participant ON participant.id = device.participant_id
       JOIN moment_spaces AS space ON space.space_id = participant.space_id
       WHERE participant.legacy_member_id = ?
         AND ${devicePredicate}
       LIMIT 1`,
  );
  const credential = await (requestedDeviceID === null
    ? credentialStatement.bind(credentialID)
    : credentialStatement.bind(credentialID, requestedDeviceID)
  ).first<ReportCredentialRow>();
  if (credential === null) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  const pathname = new URL(request.url).pathname;
  const transcript = signedRequestTranscript({
    memberId: credentialID,
    timestamp,
    nonce,
    method: request.method,
    pathname,
    bodySHA256: await sha256Base64url(body),
  });
  if (!(await verifyEd25519(credential.signing_public_key, signature, transcript))) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  const active = credential.space_state === "active"
    && credential.participant_state === "active"
    && credential.device_state === "active";
  const reportOnly = !active
    && credential.participant_report_only_until !== null
    && credential.device_report_only_until !== null
    && credential.participant_report_only_until > now
    && credential.device_report_only_until > now;
  const member: AuthenticatedMember = {
    id: credentialID,
    spaceId: credential.space_id,
    role: credential.role === "owner" ? "owner" : "invitee",
    participantId: credential.participant_id,
    momentParticipantId: credential.participant_id,
    deviceId: credential.device_id,
    agreementPublicKey: credential.agreement_public_key,
    signingPublicKey: credential.signing_public_key,
    state: credential.participant_state,
    spaceState: credential.space_state,
    nonce,
    now,
  };
  const context: MomentContextRow = {
    participant_id: credential.participant_id,
    device_id: credential.device_id,
    current_key_epoch: credential.current_key_epoch,
    membership_revision: credential.membership_revision,
    lineage_id: credential.lineage_id,
  };
  if (!active && !reportOnly) {
    await consumeReportNonce(env, member, context);
    throw new ApiError(410, "report_window_closed", "The report-only access window has closed.");
  }
  return { body, member, context, reportOnly };
}

async function consumeAndThrow(
  env: Env,
  member: AuthenticatedMember,
  error: unknown,
): Promise<never> {
  await consumeNonce(env, member);
  throw error;
}

async function bestEffortConsumeNonce(env: Env, member: AuthenticatedMember): Promise<void> {
  try {
    await consumeNonce(env, member);
  } catch {
    // Preserve the operation/integrity failure that caused cleanup or upload
    // reconciliation. A replay error must not hide the original condition.
  }
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
  operation: string,
  member: AuthenticatedMember,
  clientRequestID: string,
  requestHash: string,
): Promise<Response | null> {
  let stored: Response | null;
  try {
    stored = await storedIdempotentResponse(
      env,
      operation,
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

interface ReportIdempotencyRow {
  request_hash: string;
  response_status: number;
  response_json: string;
}

async function storedReportIdempotentResponse(
  env: Env,
  operation: string,
  context: MomentContextRow,
  clientRequestID: string,
  requestHash: string,
  now: number,
): Promise<Response | null> {
  await env.DB.prepare(
    `DELETE FROM moment_report_idempotency_records
      WHERE operation = ? AND actor_device_id = ? AND client_request_id = ?
        AND expires_at <= ?`,
  ).bind(operation, context.device_id, clientRequestID, now).run();
  const row = await env.DB.prepare(
    `SELECT request_hash, response_status, response_json
       FROM moment_report_idempotency_records
      WHERE operation = ? AND actor_device_id = ? AND client_request_id = ?`,
  ).bind(operation, context.device_id, clientRequestID).first<ReportIdempotencyRow>();
  if (row === null) return null;
  if (row.request_hash !== requestHash) {
    throw new ApiError(409, "idempotency_conflict", "The idempotency key was already used with another request.");
  }
  return jsonResponse(JSON.parse(row.response_json) as unknown, row.response_status);
}

function reportIdempotencyStatement(
  env: Env,
  operation: string,
  context: MomentContextRow,
  clientRequestID: string,
  requestHash: string,
  responseStatus: number,
  responseBody: unknown,
  now: number,
): D1PreparedStatement {
  const expiresAt = now + positiveIntegerSetting(env.IDEMPOTENCY_TTL_SECONDS, 172_800);
  return env.DB.prepare(
    `INSERT INTO moment_report_idempotency_records(
       operation, actor_device_id, client_request_id, lineage_id, request_hash,
       response_status, response_json, created_at, expires_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    operation,
    context.device_id,
    clientRequestID,
    context.lineage_id,
    requestHash,
    responseStatus,
    JSON.stringify(responseBody),
    now,
    expiresAt,
  );
}

async function replayReportResponse(
  env: Env,
  operation: string,
  member: AuthenticatedMember,
  context: MomentContextRow,
  clientRequestID: string,
  requestHash: string,
): Promise<Response | null> {
  let stored: Response | null;
  try {
    stored = await storedReportIdempotentResponse(
      env,
      operation,
      context,
      clientRequestID,
      requestHash,
      member.now,
    );
  } catch (error) {
    await consumeReportNonce(env, member, context);
    throw error;
  }
  if (stored !== null) await consumeReportNonceAndTouch(env, member, context);
  return stored;
}

async function momentContext(
  env: Env,
  member: AuthenticatedMember,
): Promise<MomentContextRow> {
  const row = await env.DB.prepare(
    `SELECT participant.id AS participant_id, device.id AS device_id,
            space.current_key_epoch, space.membership_revision, space.lineage_id
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
  ).first<MomentContextRow>();
  if (row === null) {
    throw new ApiError(503, "moment_identity_unavailable", "The sharing identity is temporarily unavailable.");
  }
  return row;
}

async function storagePrefix(env: Env, spaceID: string, now: number): Promise<string> {
  const candidate = randomBase64url(24);
  await env.DB.prepare(
    `INSERT OR IGNORE INTO moment_storage_scopes(space_id, object_prefix, created_at)
     VALUES (?, ?, ?)`,
  ).bind(spaceID, candidate, now).run();
  const row = await env.DB.prepare(
    "SELECT object_prefix FROM moment_storage_scopes WHERE space_id = ?",
  ).bind(spaceID).first<{ object_prefix: string }>();
  if (row === null) {
    throw new ApiError(503, "moment_storage_unavailable", "The media store is temporarily unavailable.");
  }
  return row.object_prefix;
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
  if (object === null || object.size !== body.length || r2Checksum(object) !== digestValue) {
    throw new ApiError(409, "object_integrity_conflict", "Stored ciphertext does not match its descriptor.");
  }
}

async function loadMoment(env: Env, momentID: string): Promise<MomentRow | null> {
  return env.DB.prepare(
    `SELECT id, client_moment_id, space_id, sender_participant_id,
            sender_device_id, kind, key_epoch, state, object_key,
            ciphertext_size, ciphertext_sha256, quota_day_key, quota_counted,
            reservation_attempt, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at, committed_at,
            unreceived_expires_at, closed_at
       FROM moments WHERE id = ?`,
  ).bind(momentID).first<MomentRow>();
}

async function loadClientMoment(
  env: Env,
  senderDeviceID: string,
  clientMomentID: string,
): Promise<MomentRow | null> {
  return env.DB.prepare(
    `SELECT id, client_moment_id, space_id, sender_participant_id,
            sender_device_id, kind, key_epoch, state, object_key,
            ciphertext_size, ciphertext_sha256, quota_day_key, quota_counted,
            reservation_attempt, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at, committed_at,
            unreceived_expires_at, closed_at
      FROM moments
      WHERE sender_device_id = ? AND client_moment_id = ?
      ORDER BY reservation_attempt DESC, created_at DESC, id DESC
      LIMIT 1`,
  ).bind(senderDeviceID, clientMomentID).first<MomentRow>();
}

function isExpiredDraft(row: MomentRow, now: number): boolean {
  return row.committed_at === null && (
    row.state === "expired" || row.state === "deleted" || row.upload_expires_at <= now
  );
}

function requireSenderMoment(
  row: MomentRow | null,
  member: AuthenticatedMember,
  context: MomentContextRow,
): asserts row is MomentRow {
  if (
    row === null || row.space_id !== member.spaceId
    || row.sender_participant_id !== context.participant_id
    || row.sender_device_id !== context.device_id
  ) {
    throw new ApiError(404, "moment_not_found", "The moment was not found.");
  }
}

async function eligibleRecipients(
  env: Env,
  spaceID: string,
  senderParticipantID: string,
): Promise<ParticipantRow[]> {
  const rows = await env.DB.prepare(
    `SELECT recipient.id
       FROM moment_participants AS recipient
      WHERE recipient.space_id = ?
        AND recipient.state = 'active'
        AND recipient.id <> ?
        AND EXISTS (
          SELECT 1 FROM moment_devices AS device
           WHERE device.participant_id = recipient.id AND device.state = 'active'
        )
        AND NOT EXISTS (
          SELECT 1 FROM moment_blocks AS block
           WHERE block.space_id = recipient.space_id AND block.state = 'active'
             AND (
               (block.blocker_participant_id = ?
                AND block.blocked_participant_id = recipient.id)
               OR
               (block.blocker_participant_id = recipient.id
                AND block.blocked_participant_id = ?)
             )
        )
      ORDER BY recipient.id ASC`,
  ).bind(spaceID, senderParticipantID, senderParticipantID, senderParticipantID)
    .all<ParticipantRow>();
  return rows.results;
}

function reservationResponse(row: {
  id: string;
  clientMomentID: string;
  spaceID: string;
  senderParticipantID: string;
  senderDeviceID: string;
  kind: "live" | "memory";
  keyEpoch: number;
  ciphertextSize: number;
  ciphertextSHA256: string;
  quotaDayKey: number;
  createdAt: number;
  uploadExpiresAt: number;
}, used: number): Record<string, unknown> {
  return {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    moment: {
      id: row.id,
      clientMomentId: row.clientMomentID,
      spaceId: row.spaceID,
      senderParticipantId: row.senderParticipantID,
      senderDeviceId: row.senderDeviceID,
      kind: row.kind,
      keyEpoch: row.keyEpoch,
      state: "reserved",
      ciphertextSize: row.ciphertextSize,
      ciphertextSHA256: row.ciphertextSHA256,
      createdAt: row.createdAt,
      uploadExpiresAt: row.uploadExpiresAt,
    },
    quota: {
      dayKey: row.quotaDayKey,
      used,
      limit: MOMENT_DAILY_QUOTA,
      remaining: Math.max(0, MOMENT_DAILY_QUOTA - used),
    },
  };
}

export async function reserveMoment(request: Request, env: Env): Promise<Response> {
  const { body, member } = await signedRequest(request, env);
  let object: JsonRecord;
  let clientRequestID: string;
  let clientMomentID: string;
  let kind: "live" | "memory";
  let keyEpoch: number;
  let ciphertextSize: number;
  let ciphertextSHA256: string;
  let clientModerationVersion: number;
  let senderPolicyVersion: number;
  let senderPolicyAcceptedAt: number;
  try {
    object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion", "clientRequestId", "clientMomentId", "kind", "keyEpoch",
      "ciphertextSize", "ciphertextSHA256", "clientModerationVersion",
      "senderPolicyAcceptance",
    ]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    clientMomentID = uuidField(object, "clientMomentId");
    kind = oneOf(object, "kind", ["live", "memory"] as const);
    keyEpoch = integerField(object, "keyEpoch", 1, Number.MAX_SAFE_INTEGER);
    ciphertextSize = integerField(
      object,
      "ciphertextSize",
      minimumAEADCiphertextBytes,
      MAXIMUM_MOMENT_CIPHERTEXT_BYTES,
    );
    ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
    clientModerationVersion = integerField(
      object,
      "clientModerationVersion",
      1,
      Number.MAX_SAFE_INTEGER,
    );
    if (!allowedClientModerationVersions.has(clientModerationVersion)) {
      throw new ApiError(409, "moderation_version_required", "This client moderation version is not accepted.");
    }
    const acceptance = asObject(object.senderPolicyAcceptance);
    exactKeys(acceptance, ["version", "acceptedAt"]);
    senderPolicyVersion = integerField(acceptance, "version", 1, Number.MAX_SAFE_INTEGER);
    if (!allowedSenderPolicyVersions.has(senderPolicyVersion)) {
      throw new ApiError(409, "sender_policy_required", "The current sender policy must be accepted.");
    }
    senderPolicyAcceptedAt = acceptedAtSeconds(acceptance, "acceptedAt", member.now);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }

  const requestHash = await mutationRequestHash(request, body);
  let context: MomentContextRow;
  let prior: MomentRow | null;
  let retryingExpiredDraft: boolean;
  let recipients: ParticipantRow[];
  let prefix: string;
  try {
    context = await momentContext(env, member);
    prior = await loadClientMoment(env, context.device_id, clientMomentID);
    retryingExpiredDraft = prior !== null && isExpiredDraft(prior, member.now);
    if (retryingExpiredDraft && prior?.reserve_request_hash !== requestHash) {
      throw new ApiError(
        409,
        "idempotency_conflict",
        "The expired client moment can only be retried with its original request.",
      );
    }
    if (
      retryingExpiredDraft && prior !== null
      && prior.reservation_attempt >= MOMENT_RESERVATION_ATTEMPT_LIMIT
    ) {
      throw new ApiError(
        429,
        "reservation_retry_limit_exceeded",
        "This client moment has exhausted its safe reservation retries.",
      );
    }
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  if (!retryingExpiredDraft) {
    const replayed = await replayResponse(
      env,
      "reserve-moment",
      member,
      clientRequestID,
      requestHash,
    );
    if (replayed !== null) return replayed;
  }
  try {
    if (keyEpoch !== context.current_key_epoch) {
      throw new ApiError(409, "key_epoch_required", "The current sharing key epoch is required.");
    }
    recipients = await eligibleRecipients(env, member.spaceId, context.participant_id);
    if (recipients.length === 0) {
      throw new ApiError(409, "no_eligible_recipients", "There is no eligible recipient for this moment.");
    }
    prefix = await storagePrefix(env, member.spaceId, member.now);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }

  const quotaCounted = retryingExpiredDraft ? 0 : 1;
  const reservationAttempt = retryingExpiredDraft && prior !== null
    ? prior.reservation_attempt + 1
    : 1;
  const dayKey = retryingExpiredDraft && prior !== null
    ? prior.quota_day_key
    : Math.floor(member.now / 86_400);
  const usage = await env.DB.prepare(
    `SELECT reserved_count + committed_count AS used
       FROM moment_daily_usage WHERE participant_id = ? AND day_key = ?`,
  ).bind(context.participant_id, dayKey).first<{ used: number }>();
  const used = (usage?.used ?? 0) + quotaCounted;
  if (used > MOMENT_DAILY_QUOTA) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(429, "moment_daily_quota_exceeded", "The daily moment quota has been reached."),
    );
  }

  const momentID = randomBase64url(16);
  const objectKey = `v2/${prefix}/moments/${randomBase64url(24)}`;
  const uploadExpiresAt = member.now + MOMENT_UPLOAD_TTL_SECONDS;
  const responseBody = reservationResponse({
    id: momentID,
    clientMomentID,
    spaceID: member.spaceId,
    senderParticipantID: context.participant_id,
    senderDeviceID: context.device_id,
    kind,
    keyEpoch,
    ciphertextSize,
    ciphertextSHA256,
    quotaDayKey: dayKey,
    createdAt: member.now,
    uploadExpiresAt,
  }, used);

  try {
    const statements: D1PreparedStatement[] = [
      ...nonceStatements(env, member),
    ];
    if (retryingExpiredDraft && prior !== null) {
      if (prior.state !== "deleted") {
        statements.push(env.DB.prepare(
          `INSERT INTO moment_object_deletions(
             object_key, object_type, owner_id, state, not_before, attempts, created_at
           ) VALUES (?, 'moment', ?, 'pending', ?, 0, ?)
           ON CONFLICT(object_key) DO UPDATE SET
             state = 'pending',
             not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
             attempts = moment_object_deletions.attempts + 1,
             deleted_at = NULL`,
        ).bind(
          prior.object_key,
          prior.id,
          member.now + objectDeletionGraceSeconds,
          member.now,
        ));
      }
      statements.push(
        env.DB.prepare(
          `UPDATE moments
              SET state = 'expired', closed_at = COALESCE(closed_at, ?)
            WHERE id = ? AND committed_at IS NULL
              AND state IN ('reserved', 'uploaded') AND upload_expires_at <= ?`,
        ).bind(member.now, prior.id, member.now),
        env.DB.prepare(
          `DELETE FROM idempotency_records
            WHERE operation = 'reserve-moment' AND actor_id = ?
              AND client_request_id = ? AND request_hash = ?`,
        ).bind(member.id, clientRequestID, requestHash),
      );
    }
    statements.push(
      env.DB.prepare(
        `INSERT INTO moment_sender_policy_acceptances(
           participant_id, policy_version, accepted_at, recorded_at
         ) VALUES (?, ?, ?, ?)
         ON CONFLICT(participant_id, policy_version) DO UPDATE SET
           accepted_at = MAX(moment_sender_policy_acceptances.accepted_at, excluded.accepted_at),
           recorded_at = excluded.recorded_at`,
      ).bind(context.participant_id, senderPolicyVersion, senderPolicyAcceptedAt, member.now),
      env.DB.prepare(
        `INSERT INTO moments(
           id, client_moment_id, space_id, sender_participant_id,
           sender_device_id, kind, key_epoch, state, object_key,
           ciphertext_size, ciphertext_sha256, client_moderation_version,
           sender_policy_version, sender_policy_accepted_at, quota_day_key,
           quota_counted, reservation_attempt, reserve_request_hash,
           created_at, upload_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        momentID,
        clientMomentID,
        member.spaceId,
        context.participant_id,
        context.device_id,
        kind,
        keyEpoch,
        objectKey,
        ciphertextSize,
        ciphertextSHA256,
        clientModerationVersion,
        senderPolicyVersion,
        senderPolicyAcceptedAt,
        dayKey,
        quotaCounted,
        reservationAttempt,
        requestHash,
        member.now,
        uploadExpiresAt,
      ),
      idempotencyStatement(
        env,
        "reserve-moment",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        201,
        responseBody,
        member.now,
      ),
      activityStatement(env, member),
    );
    await env.DB.batch(statements);
  } catch {
    const raced = await replayResponse(
      env,
      "reserve-moment",
      member,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    const currentUsage = await env.DB.prepare(
      `SELECT reserved_count + committed_count AS used
         FROM moment_daily_usage WHERE participant_id = ? AND day_key = ?`,
    ).bind(context.participant_id, dayKey).first<{ used: number }>();
    await consumeNonce(env, member);
    if ((currentUsage?.used ?? 0) >= MOMENT_DAILY_QUOTA) {
      throw new ApiError(429, "moment_daily_quota_exceeded", "The daily moment quota has been reached.");
    }
    throw new ApiError(409, "moment_reservation_conflict", "The moment could not be reserved.");
  }
  return jsonResponse(responseBody, 201);
}

async function queueObjectDeletion(
  env: Env,
  objectKey: string,
  objectType: "moment" | "report",
  ownerID: string,
  now: number,
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO moment_object_deletions(
       object_key, object_type, owner_id, state, not_before, attempts, created_at
     ) VALUES (?, ?, ?, 'pending', ?, 0, ?)
     ON CONFLICT(object_key) DO UPDATE SET
       state = 'pending',
       not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
       attempts = moment_object_deletions.attempts + 1,
       deleted_at = NULL`,
  ).bind(objectKey, objectType, ownerID, now + objectDeletionGraceSeconds, now).run();
}

export async function uploadMomentCiphertext(
  request: Request,
  env: Env,
  momentIDValue: string,
): Promise<Response> {
  const momentID = opaqueId(momentIDValue, "moment");
  requireOctetStream(request);
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env, MAXIMUM_MOMENT_CIPHERTEXT_BYTES);
  if (body.length < minimumAEADCiphertextBytes) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(400, "ciphertext_too_small", "The ciphertext is too small."),
    );
  }
  const [context, row, digestBytes, digestValue] = await Promise.all([
    momentContext(env, member),
    loadMoment(env, momentID),
    sha256(body),
    sha256Base64url(body),
  ]);
  try {
    requireSenderMoment(row, member, context);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  if (isExpiredDraft(row, member.now)) {
    await consumeNonce(env, member);
    if (row.state !== "deleted") {
      await queueObjectDeletion(env, row.object_key, "moment", row.id, member.now);
    }
    throw new ApiError(
      410,
      "reservation_expired",
      "This reservation expired; reserve the same client moment again before uploading.",
    );
  }
  if (row.ciphertext_size !== body.length || row.ciphertext_sha256 !== digestValue) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(409, "ciphertext_descriptor_mismatch", "Ciphertext does not match its reservation."),
    );
  }
  const responseBody = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    momentId: momentID,
    state: "uploaded",
    ciphertextSize: body.length,
    ciphertextSHA256: digestValue,
  };
  if (row.state === "uploaded" || row.state === "committed") {
    await consumeNonce(env, member);
    const head = await bucket.head(row.object_key);
    if (head === null || head.size !== body.length || r2Checksum(head) !== digestValue) {
      throw new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable.");
    }
    await activityStatement(env, member).run();
    return jsonResponse(responseBody);
  }
  if (row.state !== "reserved" || row.upload_expires_at <= member.now) {
    await consumeNonce(env, member);
    await queueObjectDeletion(env, row.object_key, "moment", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This moment no longer accepts ciphertext uploads.");
  }

  // R2 is not transactional with D1. Claim the nonce before the immutable put;
  // a retry with a fresh nonce reconciles the same server-reserved object key.
  await consumeNonce(env, member);
  await ensureR2Object(bucket, row.object_key, body, digestBytes, digestValue);
  const updated = await env.DB.prepare(
    `UPDATE moments
        SET state = 'uploaded', uploaded_at = ?
      WHERE id = ? AND state = 'reserved' AND upload_expires_at > ?`,
  ).bind(member.now, momentID, member.now).run();
  if (updated.meta.changes !== 1) {
    const raced = await loadMoment(env, momentID);
    if (
      raced !== null && (raced.state === "uploaded" || raced.state === "committed")
      && raced.ciphertext_size === body.length
      && raced.ciphertext_sha256 === digestValue
    ) {
      const head = await bucket.head(raced.object_key);
      if (head !== null && head.size === body.length && r2Checksum(head) === digestValue) {
        await activityStatement(env, member).run();
        return jsonResponse(responseBody);
      }
    }
    await queueObjectDeletion(env, row.object_key, "moment", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This moment no longer accepts ciphertext uploads.");
  }
  await activityStatement(env, member).run();
  return jsonResponse(responseBody);
}

export async function commitMoment(
  request: Request,
  env: Env,
  momentIDValue: string,
): Promise<Response> {
  const momentID = opaqueId(momentIDValue, "moment");
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env);
  let clientRequestID: string;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId"]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const requestHash = await mutationRequestHash(request, body);
  const replayed = await replayResponse(
    env,
    "commit-moment",
    member,
    clientRequestID,
    requestHash,
  );
  if (replayed !== null) return replayed;

  const [context, row] = await Promise.all([momentContext(env, member), loadMoment(env, momentID)]);
  try {
    requireSenderMoment(row, member, context);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  if (isExpiredDraft(row, member.now)) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(
        410,
        "reservation_expired",
        "This reservation expired; reserve the same client moment again before committing.",
      ),
    );
  }
  if (row.state !== "uploaded" || row.upload_expires_at <= member.now) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(409, "moment_not_ready", "The moment is not ready to commit."),
    );
  }
  if (row.key_epoch !== context.current_key_epoch) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(409, "key_epoch_required", "The current sharing key epoch is required."),
    );
  }
  const [recipients, head] = await Promise.all([
    eligibleRecipients(env, member.spaceId, context.participant_id),
    bucket.head(row.object_key),
  ]);
  if (recipients.length === 0) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(409, "no_eligible_recipients", "There is no eligible recipient for this moment."),
    );
  }
  if (
    head === null || head.size !== row.ciphertext_size
    || r2Checksum(head) !== row.ciphertext_sha256
  ) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable."),
    );
  }

  const committedAt = member.now;
  const unreceivedExpiresAt = member.now + MOMENT_UNRECEIVED_TTL_SECONDS;
  const firstRecipientID = recipients[0]?.id;
  if (firstRecipientID === undefined) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(409, "no_eligible_recipients", "There is no eligible recipient for this moment."),
    );
  }
  const firstCursor = randomBase64url(16);
  const responseBody = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    moment: {
      id: momentID,
      state: "committed",
      committedAt,
      unreceivedExpiresAt,
    },
    recipientCount: recipients.length,
    changeCursor: firstCursor,
  };
  const commitEventID = randomBase64url(16);
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_commit_events(
           id, moment_id, sender_participant_id, expected_key_epoch,
           expected_membership_revision, committed_at, unreceived_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        commitEventID,
        momentID,
        context.participant_id,
        context.current_key_epoch,
        context.membership_revision,
        committedAt,
        unreceivedExpiresAt,
      ),
      env.DB.prepare(
        `INSERT INTO moment_deliveries(
           moment_id, recipient_participant_id, state, created_at, access_expires_at
         )
         SELECT ?, recipient.id, 'pending', ?, ?
           FROM moment_participants AS recipient
          WHERE recipient.space_id = ? AND recipient.state = 'active'
            AND recipient.id <> ?
            AND EXISTS (
              SELECT 1 FROM moment_devices AS device
               WHERE device.participant_id = recipient.id AND device.state = 'active'
            )
            AND NOT EXISTS (
              SELECT 1 FROM moment_blocks AS block
               WHERE block.space_id = recipient.space_id AND block.state = 'active'
                 AND (
                   (block.blocker_participant_id = ?
                    AND block.blocked_participant_id = recipient.id)
                   OR
                   (block.blocker_participant_id = recipient.id
                    AND block.blocked_participant_id = ?)
                 )
            )`,
      ).bind(
        momentID,
        committedAt,
        unreceivedExpiresAt,
        member.spaceId,
        context.participant_id,
        context.participant_id,
        context.participant_id,
      ),
      env.DB.prepare(
        `INSERT INTO moment_changes(
           cursor, participant_id, change_type, moment_id, created_at
         ) VALUES (?, ?, 'moment_committed', ?, ?)`,
      ).bind(firstCursor, firstRecipientID, momentID, committedAt),
      env.DB.prepare(
        `INSERT INTO moment_changes(
           cursor, participant_id, change_type, moment_id, created_at
         )
         SELECT lower(hex(randomblob(16))), delivery.recipient_participant_id,
                'moment_committed', delivery.moment_id, ?
           FROM moment_deliveries AS delivery
          WHERE delivery.moment_id = ?
            AND delivery.recipient_participant_id <> ?`,
      ).bind(committedAt, momentID, firstRecipientID),
      ...momentNotificationEventStatements(env, momentID, committedAt),
      env.DB.prepare("DELETE FROM moment_commit_events WHERE id = ?").bind(commitEventID),
      idempotencyStatement(
        env,
        "commit-moment",
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
    const raced = await replayResponse(
      env,
      "commit-moment",
      member,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "moment_commit_conflict", "The moment could not be committed.");
  }
  return jsonResponse(responseBody, 201);
}

interface ChangeRow {
  sequence: number;
  cursor: string;
  change_type: "moment_committed" | "delivery_revoked";
  created_at: number;
  id: string;
  client_moment_id: string;
  sender_participant_id: string;
  kind: MomentKind;
  key_epoch: number;
  ciphertext_size: number;
  ciphertext_sha256: string;
  committed_at: number | null;
  access_expires_at: number | null;
  delivery_state: DeliveryRow["state"] | null;
}

export async function getMomentChanges(
  request: Request,
  env: Env,
  cursorValue?: string,
): Promise<Response> {
  const cursor = cursorValue === undefined ? undefined : changeCursorValue(cursorValue);
  const { body, member } = await signedRequest(request, env);
  if (body.length !== 0) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(400, "body_must_be_empty", "This request must have an empty body."),
    );
  }
  const context = await momentContext(env, member);
  let afterSequence = 0;
  if (cursor !== undefined) {
    const cursorRow = await env.DB.prepare(
      `SELECT sequence FROM moment_changes
        WHERE cursor = ? AND participant_id = ?`,
    ).bind(cursor, context.participant_id).first<{ sequence: number }>();
    if (cursorRow === null) {
      return consumeAndThrow(
        env,
        member,
        new ApiError(404, "cursor_not_found", "The changes cursor was not found."),
      );
    }
    afterSequence = cursorRow.sequence;
  }
  const rows = await env.DB.prepare(
    `SELECT change.sequence, change.cursor, change.change_type, change.created_at,
            moment.id, moment.client_moment_id, moment.sender_participant_id,
            moment.kind, moment.key_epoch, moment.ciphertext_size,
            moment.ciphertext_sha256, moment.committed_at,
            CASE
              WHEN moment.sender_participant_id = change.participant_id
                THEN moment.unreceived_expires_at
              ELSE delivery.access_expires_at
            END AS access_expires_at,
            CASE
              WHEN moment.sender_participant_id = change.participant_id THEN
                CASE WHEN EXISTS (
                  SELECT 1
                    FROM moment_deliveries AS sender_delivery
                   WHERE sender_delivery.moment_id = moment.id
                     AND sender_delivery.state = 'acknowledged'
                ) THEN 'acknowledged' ELSE 'pending' END
              ELSE delivery.state
            END AS delivery_state
       FROM moment_changes AS change
       JOIN moments AS moment ON moment.id = change.moment_id
       LEFT JOIN moment_deliveries AS delivery
         ON delivery.moment_id = moment.id
        AND delivery.recipient_participant_id = change.participant_id
      WHERE change.participant_id = ? AND change.sequence > ?
      ORDER BY change.sequence ASC
      LIMIT 100`,
  ).bind(context.participant_id, afterSequence).all<ChangeRow>();

  const changes = rows.results.map((row) => {
    if (
      row.committed_at === null || row.access_expires_at === null
      || row.delivery_state === null
    ) {
      throw new ApiError(503, "moment_state_unavailable", "The moment change is temporarily unavailable.");
    }
    return {
      cursor: row.cursor,
      type: row.change_type === "moment_committed" ? "momentCommitted" : "deliveryRevoked",
      createdAt: row.created_at,
      moment: {
        id: row.id,
        clientMomentId: row.client_moment_id,
        senderParticipantId: row.sender_participant_id,
        kind: row.kind,
        keyEpoch: row.key_epoch,
        ciphertextSize: row.ciphertext_size,
        ciphertextSHA256: row.ciphertext_sha256,
        committedAt: row.committed_at,
        accessExpiresAt: row.access_expires_at,
        deliveryState: row.delivery_state,
      },
    };
  });
  await consumeNonceAndTouch(env, member);
  return jsonResponse({
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    changes,
    nextCursor: changes.at(-1)?.cursor ?? cursor ?? "",
  });
}

interface DownloadAuthorizationRow extends MomentRow {
  recipient_authorized: number;
}

export async function downloadMomentCiphertext(
  request: Request,
  env: Env,
  momentIDValue: string,
): Promise<Response> {
  const momentID = opaqueId(momentIDValue, "moment");
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const context = await momentContext(env, member);
  const row = await env.DB.prepare(
    `SELECT moment.id, moment.client_moment_id, moment.space_id,
            moment.sender_participant_id, moment.sender_device_id,
            moment.kind, moment.key_epoch, moment.state, moment.object_key,
            moment.ciphertext_size, moment.ciphertext_sha256,
            moment.created_at, moment.upload_expires_at, moment.uploaded_at,
            moment.committed_at, moment.unreceived_expires_at, moment.closed_at,
            CASE WHEN EXISTS (
              SELECT 1
                FROM moment_deliveries AS delivery
               WHERE delivery.moment_id = moment.id
                 AND delivery.recipient_participant_id = ?
                 AND delivery.state IN ('pending', 'acknowledged')
                 AND delivery.access_expires_at > ?
                 AND NOT EXISTS (
                   SELECT 1 FROM moment_blocks AS block
                    WHERE block.space_id = moment.space_id AND block.state = 'active'
                      AND (
                        (block.blocker_participant_id = moment.sender_participant_id
                         AND block.blocked_participant_id = ?)
                        OR
                        (block.blocker_participant_id = ?
                         AND block.blocked_participant_id = moment.sender_participant_id)
                      )
                 )
            ) THEN 1 ELSE 0 END AS recipient_authorized
       FROM moments AS moment
      WHERE moment.id = ? AND moment.space_id = ?`,
  ).bind(
    context.participant_id,
    member.now,
    context.participant_id,
    context.participant_id,
    momentID,
    member.spaceId,
  ).first<DownloadAuthorizationRow>();
  if (
    row === null || row.state !== "committed"
    || (row.sender_participant_id !== context.participant_id && row.recipient_authorized !== 1)
  ) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(404, "moment_not_found", "The moment was not found."),
    );
  }

  await consumeNonceAndTouch(env, member);
  const object = await bucket.get(row.object_key);
  if (
    object === null || object.size !== row.ciphertext_size
    || r2Checksum(object) !== row.ciphertext_sha256
  ) {
    throw new ApiError(503, "stored_object_unavailable", "The ciphertext is temporarily unavailable.");
  }
  return new Response(object.body, {
    status: 200,
    headers: {
      "Cache-Control": "no-store, max-age=0",
      "Content-Type": "application/octet-stream",
      "Content-Length": String(row.ciphertext_size),
      "X-Content-Type-Options": "nosniff",
      "X-Neko-Ciphertext-SHA256": row.ciphertext_sha256,
    },
  });
}

export async function acknowledgeMoment(
  request: Request,
  env: Env,
  momentIDValue: string,
): Promise<Response> {
  const momentID = opaqueId(momentIDValue, "moment");
  const { body, member } = await signedRequest(request, env);
  let clientRequestID: string;
  let ciphertextSHA256: string;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId", "ciphertextSHA256"]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const requestHash = await mutationRequestHash(request, body);
  const replayed = await replayResponse(
    env,
    "acknowledge-moment",
    member,
    clientRequestID,
    requestHash,
  );
  if (replayed !== null) return replayed;
  const context = await momentContext(env, member);
  const delivery = await env.DB.prepare(
    `SELECT delivery.moment_id, delivery.recipient_participant_id,
            delivery.state, delivery.created_at, delivery.access_expires_at,
            delivery.acknowledged_at, delivery.revoked_at
       FROM moment_deliveries AS delivery
       JOIN moments AS moment ON moment.id = delivery.moment_id
      WHERE delivery.moment_id = ?
        AND delivery.recipient_participant_id = ?
        AND moment.space_id = ?
        AND moment.ciphertext_sha256 = ?
        AND moment.state = 'committed'
        AND delivery.state IN ('pending', 'acknowledged')
        AND delivery.access_expires_at > ?
        AND NOT EXISTS (
          SELECT 1 FROM moment_blocks AS block
           WHERE block.space_id = moment.space_id AND block.state = 'active'
             AND (
               (block.blocker_participant_id = moment.sender_participant_id
                AND block.blocked_participant_id = ?)
               OR
               (block.blocker_participant_id = ?
                AND block.blocked_participant_id = moment.sender_participant_id)
             )
        )`,
  ).bind(
    momentID,
    context.participant_id,
    member.spaceId,
    ciphertextSHA256,
    member.now,
    context.participant_id,
    context.participant_id,
  ).first<DeliveryRow>();
  if (delivery === null) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(404, "delivery_not_found", "The moment delivery was not found."),
    );
  }
  const acknowledgedAt = delivery.acknowledged_at ?? member.now;
  const shouldNotifySender = delivery.state === "pending";
  const accessExpiresAt = Math.min(
    delivery.access_expires_at,
    acknowledgedAt + MOMENT_ACKNOWLEDGED_TTL_SECONDS,
  );
  const responseBody = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    delivery: {
      momentId: momentID,
      state: "acknowledged",
      acknowledgedAt,
      accessExpiresAt,
    },
  };
  const eventID = randomBase64url(16);
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_ack_events(
           id, moment_id, recipient_participant_id, ciphertext_sha256,
           acknowledged_at, access_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?)`,
      ).bind(
        eventID,
        momentID,
        context.participant_id,
        ciphertextSHA256,
        acknowledgedAt,
        accessExpiresAt,
      ),
      env.DB.prepare("DELETE FROM moment_ack_events WHERE id = ?").bind(eventID),
      // A moment delivery is participant-scoped, but APNs work is physical
      // device-scoped. A successful signed ACK proves only this device has the
      // photo, so retain alerts for the participant's other enrolled iPhones.
      env.DB.prepare(
        `DELETE FROM notification_deliveries
          WHERE token_digest = (
                  SELECT token_digest
                    FROM apns_subscriptions
                   WHERE device_id = ? AND participant_id = ?
                )
            AND event_id IN (
              SELECT event.id
                FROM notification_events AS event
               WHERE event.kind = 'new_moment'
                 AND event.participant_id = ?
                 AND event.moment_id = ?
            )`,
      ).bind(
        member.deviceId,
        context.participant_id,
        context.participant_id,
        momentID,
      ),
      env.DB.prepare(
        `DELETE FROM notification_events
          WHERE kind = 'new_moment'
            AND participant_id = ? AND moment_id = ?
            AND NOT EXISTS (
              SELECT 1
                FROM notification_deliveries AS delivery
               WHERE delivery.event_id = notification_events.id
            )`,
      ).bind(context.participant_id, momentID),
      // The sender receives an opaque, image-free change only after a recipient
      // device has durably acknowledged the delivery. The existing changes
      // authorization keeps it scoped to the sender participant, and the
      // client still treats this as device arrival rather than opened/read.
      // The event timestamp is the already-visible commit time, not the
      // recipient's exact activity time. Only one sender event is retained
      // even when a moment has more than one recipient.
      env.DB.prepare(
        `INSERT INTO moment_changes(
           cursor, participant_id, change_type, moment_id, created_at
         )
         SELECT lower(hex(randomblob(16))), moment.sender_participant_id,
                'moment_committed', moment.id,
                COALESCE(moment.committed_at, moment.created_at)
           FROM moments AS moment
          WHERE moment.id = ?
            AND moment.sender_participant_id <> ?
            AND ? = 1
            AND NOT EXISTS (
              SELECT 1
                FROM moment_changes AS existing
               WHERE existing.participant_id = moment.sender_participant_id
                 AND existing.change_type = 'moment_committed'
                 AND existing.moment_id = moment.id
            )`,
      ).bind(
        momentID,
        context.participant_id,
        shouldNotifySender ? 1 : 0,
      ),
      idempotencyStatement(
        env,
        "acknowledge-moment",
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
    const raced = await replayResponse(
      env,
      "acknowledge-moment",
      member,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "acknowledgement_conflict", "The delivery could not be acknowledged.");
  }
  return jsonResponse(responseBody);
}

export async function blockParticipant(
  request: Request,
  env: Env,
  targetParticipantIDValue: string,
): Promise<Response> {
  const targetParticipantID = opaqueId(targetParticipantIDValue, "participant");
  const { body, member } = await signedRequest(request, env);
  let clientRequestID: string;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId"]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const requestHash = await mutationRequestHash(request, body);
  const replayed = await replayResponse(
    env,
    "block-participant",
    member,
    clientRequestID,
    requestHash,
  );
  if (replayed !== null) return replayed;
  const context = await momentContext(env, member);
  if (targetParticipantID === context.participant_id) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(400, "cannot_block_self", "A participant cannot block themselves."),
    );
  }
  const target = await env.DB.prepare(
    `SELECT id FROM moment_participants
      WHERE id = ? AND space_id = ? AND state = 'active'`,
  ).bind(targetParticipantID, member.spaceId).first<ParticipantRow>();
  if (target === null) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(404, "participant_not_found", "The participant was not found."),
    );
  }
  const existing = await env.DB.prepare(
    `SELECT created_at FROM moment_blocks
      WHERE blocker_participant_id = ? AND blocked_participant_id = ? AND state = 'active'`,
  ).bind(context.participant_id, targetParticipantID).first<{ created_at: number }>();
  if (existing !== null) {
    const responseBody = {
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      block: {
        blockerParticipantId: context.participant_id,
        blockedParticipantId: targetParticipantID,
        state: "active",
        createdAt: existing.created_at,
      },
      revokedDeliveryCount: 0,
      requiredKeyEpoch: context.current_key_epoch,
    };
    try {
      await env.DB.batch([
        ...nonceStatements(env, member),
        idempotencyStatement(
          env,
          "block-participant",
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
      const raced = await replayResponse(
        env,
        "block-participant",
        member,
        clientRequestID,
        requestHash,
      );
      if (raced !== null) return raced;
      await consumeNonce(env, member);
      throw new ApiError(409, "block_conflict", "The participant could not be blocked.");
    }
    return jsonResponse(responseBody);
  }

  const affected = await env.DB.prepare(
    `SELECT COUNT(*) AS count
       FROM moment_deliveries AS delivery
       JOIN moments AS moment ON moment.id = delivery.moment_id
      WHERE moment.space_id = ?
        AND delivery.state IN ('pending', 'acknowledged')
        AND (
          (moment.sender_participant_id = ?
           AND delivery.recipient_participant_id = ?)
          OR
          (moment.sender_participant_id = ?
           AND delivery.recipient_participant_id = ?)
        )
      `,
  ).bind(
    member.spaceId,
    context.participant_id,
    targetParticipantID,
    targetParticipantID,
    context.participant_id,
  ).first<{ count: number }>();
  const requiredKeyEpoch = context.current_key_epoch + 1;
  const responseBody = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    block: {
      blockerParticipantId: context.participant_id,
      blockedParticipantId: targetParticipantID,
      state: "active",
      createdAt: member.now,
    },
    revokedDeliveryCount: affected?.count ?? 0,
    requiredKeyEpoch,
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_blocks(
           space_id, blocker_participant_id, blocked_participant_id, state,
           created_key_epoch, created_at
         ) VALUES (?, ?, ?, 'active', ?, ?)`,
      ).bind(
        member.spaceId,
        context.participant_id,
        targetParticipantID,
        requiredKeyEpoch,
        member.now,
      ),
      env.DB.prepare(
        `INSERT INTO moment_changes(
           cursor, participant_id, change_type, moment_id, created_at
         )
         SELECT lower(hex(randomblob(16))), delivery.recipient_participant_id,
                'delivery_revoked', delivery.moment_id, ?
           FROM moment_deliveries AS delivery
           JOIN moments AS moment ON moment.id = delivery.moment_id
          WHERE moment.space_id = ?
            AND delivery.state IN ('pending', 'acknowledged')
            AND (
              (moment.sender_participant_id = ?
               AND delivery.recipient_participant_id = ?)
              OR
              (moment.sender_participant_id = ?
               AND delivery.recipient_participant_id = ?)
            )`,
      ).bind(
        member.now,
        member.spaceId,
        context.participant_id,
        targetParticipantID,
        targetParticipantID,
        context.participant_id,
      ),
      env.DB.prepare(
        `UPDATE moment_deliveries
            SET state = 'revoked', revoked_at = ?
          WHERE state IN ('pending', 'acknowledged')
            AND moment_id IN (
              SELECT moment.id FROM moments AS moment
               WHERE moment.space_id = ?
                 AND (
                   (moment.sender_participant_id = ?
                    AND moment_deliveries.recipient_participant_id = ?)
                   OR
                   (moment.sender_participant_id = ?
                    AND moment_deliveries.recipient_participant_id = ?)
                 )
            )`,
      ).bind(
        member.now,
        member.spaceId,
        context.participant_id,
        targetParticipantID,
        targetParticipantID,
        context.participant_id,
      ),
      env.DB.prepare(
        `UPDATE members
            SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?)
          WHERE id = ? AND space_id = ? AND state IN ('pending', 'active')`,
      ).bind(member.now, targetParticipantID, member.spaceId),
      env.DB.prepare(
        `UPDATE moment_participants
            SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?),
                report_only_until = MAX(COALESCE(report_only_until, 0), ?)
          WHERE id = ? AND space_id = ? AND state IN ('pending', 'active')`,
      ).bind(
        member.now,
        member.now + MOMENT_REPORT_ONLY_TTL_SECONDS,
        targetParticipantID,
        member.spaceId,
      ),
      env.DB.prepare(
        `UPDATE moment_devices
            SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?),
                report_only_until = MAX(COALESCE(report_only_until, 0), ?)
          WHERE participant_id = ? AND state IN ('pending', 'active')`,
      ).bind(
        member.now,
        member.now + MOMENT_REPORT_ONLY_TTL_SECONDS,
        targetParticipantID,
      ),
      env.DB.prepare(
        `INSERT INTO moment_object_deletions(
           object_key, object_type, owner_id, state, not_before, attempts, created_at
         )
         SELECT object_key, 'moment', id, 'pending', ?, 0, ?
           FROM moments AS moment
          WHERE moment.space_id = ? AND state = 'committed'
            AND moment.sender_participant_id IN (?, ?)
            AND NOT EXISTS (
              SELECT 1 FROM moment_deliveries AS delivery
               WHERE delivery.moment_id = moment.id
                 AND delivery.state IN ('pending', 'acknowledged')
            )
         ON CONFLICT(object_key) DO UPDATE SET
           state = 'pending', not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
           attempts = moment_object_deletions.attempts + 1, deleted_at = NULL`,
      ).bind(
        member.now + objectDeletionGraceSeconds,
        member.now,
        member.spaceId,
        context.participant_id,
        targetParticipantID,
      ),
      env.DB.prepare(
        `UPDATE moments SET state = 'expired', closed_at = ?
          WHERE space_id = ? AND state = 'committed'
            AND sender_participant_id IN (?, ?)
            AND NOT EXISTS (
              SELECT 1 FROM moment_deliveries AS delivery
               WHERE delivery.moment_id = moments.id
                 AND delivery.state IN ('pending', 'acknowledged')
            )`,
      ).bind(
        member.now,
        member.spaceId,
        context.participant_id,
        targetParticipantID,
      ),
      idempotencyStatement(
        env,
        "block-participant",
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
    const raced = await replayResponse(
      env,
      "block-participant",
      member,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "block_conflict", "The participant could not be blocked.");
  }
  return jsonResponse(responseBody);
}

interface ReportableMomentRow {
  moment_id: string;
  accused_participant_id: string;
}

function reportReservationResponse(
  row: Pick<
    ReportRow,
    | "id" | "moment_id" | "state" | "moderation_key_id"
    | "ciphertext_size" | "ciphertext_sha256" | "created_at"
    | "upload_expires_at" | "uploaded_at" | "committed_at" | "content_expires_at"
  >,
  alreadyReported: boolean,
): Record<string, unknown> {
  return {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    report: {
      id: row.id,
      momentId: row.moment_id,
      state: row.state,
      moderationKeyId: row.moderation_key_id,
      ciphertextSize: row.ciphertext_size,
      ciphertextSHA256: row.ciphertext_sha256,
      createdAt: row.created_at,
      uploadExpiresAt: row.upload_expires_at,
      uploadedAt: row.uploaded_at,
      committedAt: row.committed_at,
      contentExpiresAt: row.content_expires_at,
    },
    alreadyReported,
  };
}

function reportMatchesReservation(
  row: ReportRow,
  reasonCode: ReportRow["reason_code"],
  moderationKeyID: string,
  ciphertextSize: number,
  ciphertextSHA256: string,
): boolean {
  return row.reason_code === reasonCode
    && row.moderation_key_id === moderationKeyID
    && row.ciphertext_size === ciphertextSize
    && row.ciphertext_sha256 === ciphertextSHA256;
}

function isExpiredReportDraft(row: ReportRow, now: number): boolean {
  return row.committed_at === null && (
    row.state === "expired" || row.state === "deleted" || row.upload_expires_at <= now
  );
}

async function recordExistingReportReservation(
  env: Env,
  member: AuthenticatedMember,
  context: MomentContextRow,
  clientRequestID: string,
  requestHash: string,
  row: ReportRow,
): Promise<Response> {
  const responseBody = reportReservationResponse(row, true);
  try {
    await env.DB.batch([
      ...reportNonceStatements(env, context, member.nonce, member.now),
      reportIdempotencyStatement(
        env,
        "reserve-moment-report",
        context,
        clientRequestID,
        requestHash,
        200,
        responseBody,
        member.now,
      ),
      reportActivityStatement(env, member),
    ]);
  } catch {
    const replayed = await replayReportResponse(
      env,
      "reserve-moment-report",
      member,
      context,
      clientRequestID,
      requestHash,
    );
    if (replayed !== null) return replayed;
    await consumeReportNonce(env, member, context);
    throw new ApiError(409, "report_reservation_conflict", "The report could not be reserved.");
  }
  return jsonResponse(responseBody);
}

export async function reserveMomentReport(request: Request, env: Env): Promise<Response> {
  const { body, member, context } = await signedReportRequest(request, env);
  await requireReportIngestionRuntime(env, member, context);
  let clientRequestID: string;
  let momentID: string;
  let reasonCode: "objectionable" | "harassment" | "privacy" | "other";
  let moderationKeyID: string;
  let ciphertextSize: number;
  let ciphertextSHA256: string;
  let reporterConsentVersion: number;
  let reporterConsentedAt: number;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion", "clientRequestId", "momentId", "reasonCode",
      "moderationKeyId", "ciphertextSize", "ciphertextSHA256", "reporterConsent",
    ]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    momentID = opaqueId(stringField(object, "momentId"), "moment");
    reasonCode = oneOf(
      object,
      "reasonCode",
      ["objectionable", "harassment", "privacy", "other"] as const,
    );
    moderationKeyID = stringField(object, "moderationKeyId");
    if (!allowedModerationKeyIDs.has(moderationKeyID)) {
      throw new ApiError(409, "moderation_key_required", "The current moderation key is required.");
    }
    ciphertextSize = integerField(
      object,
      "ciphertextSize",
      minimumAEADCiphertextBytes,
      MAXIMUM_MOMENT_CIPHERTEXT_BYTES,
    );
    ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
    const consent = asObject(object.reporterConsent);
    exactKeys(consent, ["version", "acceptedAt"]);
    reporterConsentVersion = integerField(consent, "version", 1, Number.MAX_SAFE_INTEGER);
    if (!allowedReporterConsentVersions.has(reporterConsentVersion)) {
      throw new ApiError(409, "reporter_consent_required", "The current reporting consent is required.");
    }
    reporterConsentedAt = acceptedAtSeconds(consent, "acceptedAt", member.now);
  } catch (error) {
    return consumeReportAndThrow(env, member, context, error);
  }
  const requestHash = await mutationRequestHash(request, body);
  const dedupeKey = await sha256Base64url(encodeCanonicalFields([
    "NW2.REPORT-DEDUPE",
    "2",
    context.lineage_id,
    momentID,
    context.participant_id,
  ]));
  const latestAttempt = await loadLatestReportForReporter(
    env,
    momentID,
    context.participant_id,
  );
  const replacingExpiredDraft = latestAttempt !== null
    && isExpiredReportDraft(latestAttempt, member.now);
  const exactExpiredRetry = replacingExpiredDraft
    && latestAttempt?.reserve_request_hash === requestHash;
  if (!exactExpiredRetry) {
    const replayed = await replayReportResponse(
      env,
      "reserve-moment-report",
      member,
      context,
      clientRequestID,
      requestHash,
    );
    if (replayed !== null) return replayed;
  }
  const reportable = await env.DB.prepare(
    `SELECT moment.id AS moment_id,
            moment.sender_participant_id AS accused_participant_id
       FROM moments AS moment
       JOIN moment_deliveries AS delivery ON delivery.moment_id = moment.id
      WHERE moment.id = ? AND moment.space_id = ?
        AND delivery.recipient_participant_id = ?
        AND moment.sender_participant_id <> ?`,
  ).bind(
    momentID,
    member.spaceId,
    context.participant_id,
    context.participant_id,
  ).first<ReportableMomentRow>();
  if (reportable === null) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(404, "reportable_moment_not_found", "The reportable moment was not found."),
    );
  }
  const existing = await env.DB.prepare(
    `SELECT id, moment_id, space_id, reporter_participant_id,
            reporter_device_id, accused_participant_id, reason_code,
            moderation_key_id, state, object_key, ciphertext_size,
            ciphertext_sha256, dedupe_key, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at,
            committed_at, content_expires_at, closed_at
      FROM moment_reports
      WHERE moment_id = ? AND reporter_participant_id = ?
        AND (
          (state IN ('reserved', 'uploaded') AND upload_expires_at > ?)
          OR state = 'committed'
          OR committed_at IS NOT NULL
        )
      ORDER BY CASE WHEN committed_at IS NOT NULL THEN 0 ELSE 1 END, created_at DESC
      LIMIT 1`,
  ).bind(momentID, context.participant_id, member.now).first<ReportRow>();
  if (existing !== null) {
    if (!reportMatchesReservation(
      existing,
      reasonCode,
      moderationKeyID,
      ciphertextSize,
      ciphertextSHA256,
    )) {
      return consumeReportAndThrow(
        env,
        member,
        context,
        new ApiError(409, "already_reported", "This moment has already been reported."),
      );
    }
    return recordExistingReportReservation(
      env,
      member,
      context,
      clientRequestID,
      requestHash,
      existing,
    );
  }
  const tombstone = await env.DB.prepare(
    "SELECT report_id FROM moment_report_tombstones WHERE dedupe_key = ?",
  ).bind(dedupeKey).first<{ report_id: string }>();
  if (tombstone !== null) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(409, "already_reported", "This moment has already been reported."),
    );
  }
  let prefix: string;
  try {
    prefix = await storagePrefix(env, member.spaceId, member.now);
  } catch (error) {
    return consumeReportAndThrow(env, member, context, error);
  }
  const quotaDayKey = Math.floor(member.now / 86_400);
  const reportUsage = await env.DB.prepare(
    `SELECT attempt_count FROM moment_report_daily_usage
      WHERE participant_id = ? AND day_key = ?`,
  ).bind(context.participant_id, quotaDayKey).first<{ attempt_count: number }>();
  if ((reportUsage?.attempt_count ?? 0) >= REPORT_DAILY_ATTEMPT_QUOTA) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(429, "report_daily_quota_exceeded", "The daily reporting quota has been reached."),
    );
  }
  const reportID = randomBase64url(16);
  const objectKey = `v2/${prefix}/reports/${randomBase64url(24)}`;
  const uploadExpiresAt = member.now + MOMENT_UPLOAD_TTL_SECONDS;
  const responseBody = reportReservationResponse({
    id: reportID,
    moment_id: momentID,
    state: "reserved",
    moderation_key_id: moderationKeyID,
    ciphertext_size: ciphertextSize,
    ciphertext_sha256: ciphertextSHA256,
    created_at: member.now,
    upload_expires_at: uploadExpiresAt,
    uploaded_at: null,
    committed_at: null,
    content_expires_at: null,
  }, false);
  try {
    const statements: D1PreparedStatement[] = [
      ...reportNonceStatements(env, context, member.nonce, member.now),
    ];
    if (replacingExpiredDraft && latestAttempt !== null) {
      if (latestAttempt.state !== "deleted") {
        statements.push(env.DB.prepare(
          `INSERT INTO moment_object_deletions(
             object_key, object_type, owner_id, state, not_before, attempts, created_at
           ) VALUES (?, 'report', ?, 'pending', ?, 0, ?)
           ON CONFLICT(object_key) DO UPDATE SET
             state = 'pending',
             not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
             attempts = moment_object_deletions.attempts + 1,
             deleted_at = NULL`,
        ).bind(
          latestAttempt.object_key,
          latestAttempt.id,
          member.now + objectDeletionGraceSeconds,
          member.now,
        ));
      }
      statements.push(env.DB.prepare(
        `UPDATE moment_reports SET state = 'expired', closed_at = COALESCE(closed_at, ?)
          WHERE id = ? AND committed_at IS NULL
            AND state IN ('reserved', 'uploaded') AND upload_expires_at <= ?`,
      ).bind(member.now, latestAttempt.id, member.now));
      if (exactExpiredRetry) {
        statements.push(env.DB.prepare(
          `DELETE FROM moment_report_idempotency_records
            WHERE operation = 'reserve-moment-report' AND actor_device_id = ?
              AND client_request_id = ? AND request_hash = ?`,
        ).bind(context.device_id, clientRequestID, requestHash));
      }
    }
    statements.push(
      env.DB.prepare(
        `INSERT INTO moment_reports(
           id, moment_id, space_id, lineage_id, reporter_participant_id, reporter_device_id,
           accused_participant_id, reason_code, moderation_key_id, state,
           object_key, ciphertext_size, ciphertext_sha256,
           reporter_consent_version, reporter_consented_at,
           quota_day_key, reserve_request_hash, dedupe_key, created_at, upload_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        reportID,
        momentID,
        member.spaceId,
        context.lineage_id,
        context.participant_id,
        context.device_id,
        reportable.accused_participant_id,
        reasonCode,
        moderationKeyID,
        objectKey,
        ciphertextSize,
        ciphertextSHA256,
        reporterConsentVersion,
        reporterConsentedAt,
        quotaDayKey,
        requestHash,
        dedupeKey,
        member.now,
        uploadExpiresAt,
      ),
      reportIdempotencyStatement(
        env,
        "reserve-moment-report",
        context,
        clientRequestID,
        requestHash,
        201,
        responseBody,
        member.now,
      ),
      reportActivityStatement(env, member),
    );
    await env.DB.batch(statements);
  } catch {
    const raced = await replayReportResponse(
      env,
      "reserve-moment-report",
      member,
      context,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    const concurrent = await loadReportForReporter(
      env,
      momentID,
      context.participant_id,
    );
    if (
      concurrent !== null
      && reportMatchesReservation(
        concurrent,
        reasonCode,
        moderationKeyID,
        ciphertextSize,
        ciphertextSHA256,
      )
    ) {
      return recordExistingReportReservation(
        env,
        member,
        context,
        clientRequestID,
        requestHash,
        concurrent,
      );
    }
    const currentUsage = await env.DB.prepare(
      `SELECT attempt_count FROM moment_report_daily_usage
        WHERE participant_id = ? AND day_key = ?`,
    ).bind(context.participant_id, quotaDayKey).first<{ attempt_count: number }>();
    await consumeReportNonce(env, member, context);
    if ((currentUsage?.attempt_count ?? 0) >= REPORT_DAILY_ATTEMPT_QUOTA) {
      throw new ApiError(429, "report_daily_quota_exceeded", "The daily reporting quota has been reached.");
    }
    throw new ApiError(409, "report_reservation_conflict", "The report could not be reserved.");
  }
  return jsonResponse(responseBody, 201);
}

async function loadReport(env: Env, reportID: string): Promise<ReportRow | null> {
  return env.DB.prepare(
    `SELECT id, moment_id, space_id, reporter_participant_id,
            reporter_device_id, accused_participant_id, reason_code,
            moderation_key_id, state, object_key,
            ciphertext_size, ciphertext_sha256, dedupe_key, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at, committed_at,
            content_expires_at, closed_at
       FROM moment_reports WHERE id = ?`,
  ).bind(reportID).first<ReportRow>();
}

async function loadReportForReporter(
  env: Env,
  momentID: string,
  reporterParticipantID: string,
): Promise<ReportRow | null> {
  return env.DB.prepare(
    `SELECT id, moment_id, space_id, reporter_participant_id,
            reporter_device_id, accused_participant_id, reason_code,
            moderation_key_id, state, object_key, ciphertext_size,
            ciphertext_sha256, dedupe_key, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at,
            committed_at, content_expires_at, closed_at
      FROM moment_reports
      WHERE moment_id = ? AND reporter_participant_id = ?
        AND (state IN ('reserved', 'uploaded', 'committed') OR committed_at IS NOT NULL)
      ORDER BY CASE WHEN committed_at IS NOT NULL THEN 0 ELSE 1 END, created_at DESC
      LIMIT 1`,
  ).bind(momentID, reporterParticipantID).first<ReportRow>();
}

async function loadLatestReportForReporter(
  env: Env,
  momentID: string,
  reporterParticipantID: string,
): Promise<ReportRow | null> {
  return env.DB.prepare(
    `SELECT id, moment_id, space_id, reporter_participant_id,
            reporter_device_id, accused_participant_id, reason_code,
            moderation_key_id, state, object_key, ciphertext_size,
            ciphertext_sha256, dedupe_key, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at, committed_at,
            content_expires_at, closed_at
       FROM moment_reports
      WHERE moment_id = ? AND reporter_participant_id = ?
      ORDER BY rowid DESC
      LIMIT 1`,
  ).bind(momentID, reporterParticipantID).first<ReportRow>();
}

function requireReporterReport(
  row: ReportRow | null,
  member: AuthenticatedMember,
  context: MomentContextRow,
): asserts row is ReportRow {
  if (
    row === null || row.space_id !== member.spaceId
    || row.reporter_participant_id !== context.participant_id
    || row.reporter_device_id !== context.device_id
  ) {
    throw new ApiError(404, "report_not_found", "The report was not found.");
  }
}

export async function uploadMomentReportCiphertext(
  request: Request,
  env: Env,
  reportIDValue: string,
): Promise<Response> {
  const reportID = opaqueId(reportIDValue, "report");
  requireOctetStream(request);
  const { body, member, context } = await signedReportRequest(
    request,
    env,
    MAXIMUM_MOMENT_CIPHERTEXT_BYTES,
  );
  await requireReportIngestionRuntime(env, member, context);
  const bucket = requireModerationBucket(env);
  if (body.length < minimumAEADCiphertextBytes) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(400, "ciphertext_too_small", "The ciphertext is too small."),
    );
  }
  const [row, digestBytes, digestValue] = await Promise.all([
    loadReport(env, reportID),
    sha256(body),
    sha256Base64url(body),
  ]);
  try {
    requireReporterReport(row, member, context);
  } catch (error) {
    return consumeReportAndThrow(env, member, context, error);
  }
  if (isExpiredReportDraft(row, member.now)) {
    await consumeReportNonce(env, member, context);
    if (row.state !== "deleted") {
      await queueObjectDeletion(env, row.object_key, "report", row.id, member.now);
    }
    throw new ApiError(
      410,
      "reservation_expired",
      "This report reservation expired; reserve the report again before uploading.",
    );
  }
  if (row.ciphertext_size !== body.length || row.ciphertext_sha256 !== digestValue) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(409, "ciphertext_descriptor_mismatch", "Ciphertext does not match its reservation."),
    );
  }
  const responseBody = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    reportId: reportID,
    state: "uploaded",
    ciphertextSize: body.length,
    ciphertextSHA256: digestValue,
  };
  if (row.state === "uploaded" || row.state === "committed") {
    await consumeReportNonce(env, member, context);
    const head = await bucket.head(row.object_key);
    if (head === null || head.size !== body.length || r2Checksum(head) !== digestValue) {
      throw new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable.");
    }
    await reportActivityStatement(env, member).run();
    return jsonResponse(responseBody);
  }
  if (row.state !== "reserved" || row.upload_expires_at <= member.now) {
    await consumeReportNonce(env, member, context);
    await queueObjectDeletion(env, row.object_key, "report", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This report no longer accepts ciphertext uploads.");
  }
  await consumeReportNonce(env, member, context);
  await ensureR2Object(bucket, row.object_key, body, digestBytes, digestValue);
  const updated = await env.DB.prepare(
    `UPDATE moment_reports SET state = 'uploaded', uploaded_at = ?
      WHERE id = ? AND state = 'reserved' AND upload_expires_at > ?`,
  ).bind(member.now, reportID, member.now).run();
  if (updated.meta.changes !== 1) {
    const raced = await loadReport(env, reportID);
    if (
      raced !== null && (raced.state === "uploaded" || raced.state === "committed")
      && raced.ciphertext_size === body.length
      && raced.ciphertext_sha256 === digestValue
    ) {
      const head = await bucket.head(raced.object_key);
      if (head !== null && head.size === body.length && r2Checksum(head) === digestValue) {
        await reportActivityStatement(env, member).run();
        return jsonResponse(responseBody);
      }
    }
    await queueObjectDeletion(env, row.object_key, "report", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This report no longer accepts ciphertext uploads.");
  }
  await reportActivityStatement(env, member).run();
  return jsonResponse(responseBody);
}

export async function commitMomentReport(
  request: Request,
  env: Env,
  reportIDValue: string,
): Promise<Response> {
  const reportID = opaqueId(reportIDValue, "report");
  const { body, member, context } = await signedReportRequest(request, env);
  await requireReportIngestionRuntime(env, member, context);
  const bucket = requireModerationBucket(env);
  let clientRequestID: string;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId"]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
  } catch (error) {
    return consumeReportAndThrow(env, member, context, error);
  }
  const requestHash = await mutationRequestHash(request, body);
  const replayed = await replayReportResponse(
    env,
    "commit-moment-report",
    member,
    context,
    clientRequestID,
    requestHash,
  );
  if (replayed !== null) return replayed;
  const row = await loadReport(env, reportID);
  try {
    requireReporterReport(row, member, context);
  } catch (error) {
    return consumeReportAndThrow(env, member, context, error);
  }
  if (isExpiredReportDraft(row, member.now)) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(
        410,
        "reservation_expired",
        "This report reservation expired; reserve the report again before committing.",
      ),
    );
  }
  if (
    row.state === "committed" && row.committed_at !== null
    && row.content_expires_at !== null
  ) {
    const responseBody = {
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      report: {
        id: reportID,
        momentId: row.moment_id,
        state: "committed",
        committedAt: row.committed_at,
        contentExpiresAt: row.content_expires_at,
      },
    };
    try {
      await env.DB.batch([
        ...reportNonceStatements(env, context, member.nonce, member.now),
        reportIdempotencyStatement(
          env,
          "commit-moment-report",
          context,
          clientRequestID,
          requestHash,
          201,
          responseBody,
          member.now,
        ),
        reportActivityStatement(env, member),
      ]);
    } catch {
      const raced = await replayReportResponse(
        env,
        "commit-moment-report",
        member,
        context,
        clientRequestID,
        requestHash,
      );
      if (raced !== null) return raced;
      await consumeReportNonce(env, member, context);
      throw new ApiError(409, "report_commit_conflict", "The report could not be committed.");
    }
    return jsonResponse(responseBody, 201);
  }
  if (row.state !== "uploaded" || row.upload_expires_at <= member.now) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(409, "report_not_ready", "The report is not ready to commit."),
    );
  }
  const head = await bucket.head(row.object_key);
  if (
    head === null || head.size !== row.ciphertext_size
    || r2Checksum(head) !== row.ciphertext_sha256
  ) {
    return consumeReportAndThrow(
      env,
      member,
      context,
      new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable."),
    );
  }
  const contentExpiresAt = member.now + REPORT_CONTENT_TTL_SECONDS;
  const responseBody = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    report: {
      id: reportID,
      momentId: row.moment_id,
      state: "committed",
      committedAt: member.now,
      contentExpiresAt,
    },
  };
  const commitEventID = randomBase64url(16);
  try {
    await env.DB.batch([
      ...reportNonceStatements(env, context, member.nonce, member.now),
      env.DB.prepare(
        `INSERT INTO moment_report_commit_events(
           id, report_id, reporter_participant_id, committed_at, content_expires_at
         ) VALUES (?, ?, ?, ?, ?)`,
      ).bind(
        commitEventID,
        reportID,
        context.participant_id,
        member.now,
        contentExpiresAt,
      ),
      env.DB.prepare("DELETE FROM moment_report_commit_events WHERE id = ?").bind(commitEventID),
      reportIdempotencyStatement(
        env,
        "commit-moment-report",
        context,
        clientRequestID,
        requestHash,
        201,
        responseBody,
        member.now,
      ),
      reportActivityStatement(env, member),
    ]);
  } catch {
    const raced = await replayReportResponse(
      env,
      "commit-moment-report",
      member,
      context,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeReportNonce(env, member, context);
    throw new ApiError(409, "report_commit_conflict", "The report could not be committed.");
  }
  return jsonResponse(responseBody, 201);
}

interface ObjectDeletionRow {
  object_key: string;
  object_type: "moment" | "report";
  owner_id: string;
  attempts: number;
}

interface RevokedScopeRow {
  space_id: string;
  object_prefix: string;
  moment_empty_sweep_started_at: number | null;
  report_empty_sweep_started_at: number | null;
}

async function sweepRevokedV2Prefix(
  env: Env,
  scope: RevokedScopeRow,
  objectType: "moment" | "report",
  now: number,
): Promise<void> {
  const bucket = objectType === "moment" ? env.MEDIA : env.MODERATION_MEDIA;
  if (bucket === undefined) return;
  const plural = objectType === "moment" ? "moments" : "reports";
  const objects = await bucket.list({
    prefix: `v2/${scope.object_prefix}/${plural}/`,
    limit: 1_000,
  });
  const emptyColumn = objectType === "moment"
    ? "moment_empty_sweep_started_at"
    : "report_empty_sweep_started_at";
  const completedColumn = objectType === "moment"
    ? "moment_sweep_completed_at"
    : "report_sweep_completed_at";
  if (objects.objects.length > 0) {
    await bucket.delete(objects.objects.map((object) => object.key));
    await env.DB.prepare(
      `UPDATE moment_storage_scopes
          SET ${emptyColumn} = NULL, last_sweep_at = ?, sweep_count = sweep_count + 1
        WHERE space_id = ? AND ${completedColumn} IS NULL`,
    ).bind(now, scope.space_id).run();
    return;
  }
  const emptyStartedAt = objectType === "moment"
    ? scope.moment_empty_sweep_started_at
    : scope.report_empty_sweep_started_at;
  if (emptyStartedAt === null) {
    await env.DB.prepare(
      `UPDATE moment_storage_scopes
          SET ${emptyColumn} = ?, last_sweep_at = ?, sweep_count = sweep_count + 1
        WHERE space_id = ? AND ${completedColumn} IS NULL`,
    ).bind(now, now, scope.space_id).run();
  } else if (now - emptyStartedAt >= 60) {
    if (objectType === "report") {
      // The second empty moderation-bucket proof is conservative physical
      // deletion evidence for every terminal report under this prefix. Repeat
      // report/window eligibility and CAS the first-empty timestamp so a late
      // authenticated reserve invalidates this observation atomically.
      await env.DB.batch([
        env.DB.prepare(
          `UPDATE moment_storage_scopes
              SET report_sweep_completed_at = ?, last_sweep_at = ?,
                  sweep_count = sweep_count + 1
            WHERE space_id = ? AND report_sweep_completed_at IS NULL
              AND report_empty_sweep_started_at = ?
              AND NOT EXISTS (
                SELECT 1 FROM moment_participants AS participant
                 WHERE participant.space_id = moment_storage_scopes.space_id
                   AND participant.report_only_until > ?
              )
              AND NOT EXISTS (
                SELECT 1 FROM moment_reports AS report
                 WHERE report.space_id = moment_storage_scopes.space_id
                   AND report.state IN ('reserved', 'uploaded', 'committed')
              )`,
        ).bind(now, now, scope.space_id, emptyStartedAt, now - 600),
        env.DB.prepare(
          `UPDATE moment_reports SET state = 'deleted', closed_at = ?
            WHERE space_id = ? AND state = 'expired'
              AND EXISTS (
                SELECT 1 FROM moment_storage_scopes AS storage
                 WHERE storage.space_id = moment_reports.space_id
                   AND storage.report_empty_sweep_started_at = ?
                   AND storage.report_sweep_completed_at = ?
              )`,
        ).bind(now, scope.space_id, emptyStartedAt, now),
        env.DB.prepare(
          `UPDATE moment_report_tombstones
              SET content_deleted_at = MAX(COALESCE(content_deleted_at, 0), ?)
            WHERE report_id IN (
              SELECT report.id FROM moment_reports AS report
              JOIN moment_storage_scopes AS storage ON storage.space_id = report.space_id
               WHERE report.space_id = ? AND report.committed_at IS NOT NULL
                 AND storage.report_empty_sweep_started_at = ?
                 AND storage.report_sweep_completed_at = ?
            )`,
        ).bind(now, scope.space_id, emptyStartedAt, now),
      ]);
    } else {
      await env.DB.prepare(
        `UPDATE moment_storage_scopes
            SET moment_sweep_completed_at = ?, last_sweep_at = ?,
                sweep_count = sweep_count + 1
          WHERE space_id = ? AND moment_sweep_completed_at IS NULL
            AND moment_empty_sweep_started_at = ?`,
      ).bind(now, now, scope.space_id, emptyStartedAt).run();
    }
  }
}

async function processRevokedV2Scopes(env: Env, now: number): Promise<void> {
  const momentScopes = await env.DB.prepare(
    `SELECT storage.space_id, storage.object_prefix,
            storage.moment_empty_sweep_started_at,
            storage.report_empty_sweep_started_at
       FROM moment_storage_scopes AS storage
       JOIN moment_spaces AS space ON space.space_id = storage.space_id
      WHERE space.state = 'revoked' AND space.revoked_at IS NOT NULL
        AND space.revoked_at + 600 <= ?
        AND storage.moment_sweep_completed_at IS NULL
      ORDER BY COALESCE(space.revoked_at, space.updated_at) ASC, storage.space_id ASC
      LIMIT ?`,
  ).bind(now, MOMENT_REVOKED_SCOPE_LIMIT).all<RevokedScopeRow>();
  for (const scope of momentScopes.results) {
    await sweepRevokedV2Prefix(env, scope, "moment", now);
  }

  const reportScopes = await env.DB.prepare(
    `SELECT storage.space_id, storage.object_prefix,
            storage.moment_empty_sweep_started_at,
            storage.report_empty_sweep_started_at
       FROM moment_storage_scopes AS storage
       JOIN moment_spaces AS space ON space.space_id = storage.space_id
      WHERE space.state = 'revoked' AND space.revoked_at IS NOT NULL
        AND space.revoked_at + 600 <= ?
        AND storage.report_sweep_completed_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM moment_participants AS participant
           WHERE participant.space_id = space.space_id
             AND participant.report_only_until > ?
        )
        AND NOT EXISTS (
          SELECT 1 FROM moment_reports AS report
           WHERE report.space_id = space.space_id
             AND report.state IN ('reserved', 'uploaded', 'committed')
        )
      ORDER BY COALESCE(space.revoked_at, space.updated_at) ASC, storage.space_id ASC
      LIMIT ?`,
  ).bind(now, now - 600, MOMENT_REVOKED_SCOPE_LIMIT).all<RevokedScopeRow>();
  for (const scope of reportScopes.results) {
    await sweepRevokedV2Prefix(env, scope, "report", now);
  }
}

interface PurgeableV2SpaceRow {
  space_id: string;
  object_prefix: string | null;
}

async function purgeRevokedV2Spaces(env: Env, now: number): Promise<void> {
  const rows = await env.DB.prepare(
    `SELECT space.space_id, storage.object_prefix
       FROM moment_spaces AS space
       LEFT JOIN moment_storage_scopes AS storage ON storage.space_id = space.space_id
      WHERE space.state = 'revoked' AND space.revoked_at IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM moment_participants AS participant
           WHERE participant.space_id = space.space_id
             AND participant.report_only_until > ?
        )
        AND NOT EXISTS (
          SELECT 1 FROM moment_reports AS report
           WHERE report.space_id = space.space_id
             AND report.state IN ('reserved', 'uploaded', 'committed')
        )
        AND (
          storage.space_id IS NULL
          OR (storage.moment_sweep_completed_at IS NOT NULL
              AND storage.report_sweep_completed_at IS NOT NULL)
        )
      ORDER BY space.revoked_at ASC, space.space_id ASC
      LIMIT 10`,
  ).bind(now).all<PurgeableV2SpaceRow>();
  if (rows.results.length === 0) return;
  const statements: D1PreparedStatement[] = [];
  for (const row of rows.results) {
    // Repeat every eligibility predicate in the terminal delete. A report-only
    // request may have authenticated immediately before its window closed and
    // inserted after the candidate SELECT; the parent delete must lose that
    // race rather than cascading the accepted report.
    statements.push(env.DB.prepare(
      `DELETE FROM moment_spaces
        WHERE space_id = ? AND state = 'revoked' AND revoked_at IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM moment_participants AS participant
             WHERE participant.space_id = moment_spaces.space_id
               AND participant.report_only_until > ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM moment_reports AS report
             WHERE report.space_id = moment_spaces.space_id
               AND report.state IN ('reserved', 'uploaded', 'committed')
          )
          AND (
            NOT EXISTS (
              SELECT 1 FROM moment_storage_scopes AS storage
               WHERE storage.space_id = moment_spaces.space_id
            )
            OR EXISTS (
              SELECT 1 FROM moment_storage_scopes AS storage
               WHERE storage.space_id = moment_spaces.space_id
                 AND storage.moment_sweep_completed_at IS NOT NULL
                 AND storage.report_sweep_completed_at IS NOT NULL
            )
          )`,
    ).bind(row.space_id, now));
    if (row.object_prefix !== null) {
      const prefix = `v2/${row.object_prefix}/`;
      statements.push(env.DB.prepare(
        `DELETE FROM moment_object_deletions
          WHERE object_key >= ? AND object_key < ?
            AND NOT EXISTS (
              SELECT 1 FROM moment_spaces WHERE space_id = ?
            )`,
      ).bind(prefix, `${prefix}\uffff`, row.space_id));
    }
  }
  await env.DB.batch(statements);
}

/**
 * Bounded v2 retention work. Ciphertext is removed independently from the
 * append-only delivery/change metadata so an offline client's opaque cursor
 * never silently becomes invalid merely because a media TTL elapsed.
 */
export async function runMomentCleanup(
  env: Env,
  now = Math.floor(Date.now() / 1000),
): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM moment_report_request_nonces
        WHERE rowid IN (
          SELECT rowid FROM moment_report_request_nonces
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, device_id ASC, nonce ASC LIMIT ?
        )`,
    ).bind(now, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_report_idempotency_records
        WHERE rowid IN (
          SELECT rowid FROM moment_report_idempotency_records
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, actor_device_id ASC, operation ASC,
                    client_request_id ASC LIMIT ?
        )`,
    ).bind(now, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_object_deletions
        WHERE rowid IN (
          SELECT deletion.rowid FROM moment_object_deletions AS deletion
           WHERE (deletion.object_type = 'moment' AND EXISTS (
             SELECT 1 FROM moments
              WHERE moments.id = deletion.owner_id
                AND moments.state IN ('reserved', 'uploaded', 'committed')
           )) OR (deletion.object_type = 'report' AND EXISTS (
             SELECT 1 FROM moment_reports
              WHERE moment_reports.id = deletion.owner_id
                AND moment_reports.state IN ('reserved', 'uploaded', 'committed')
           ))
           ORDER BY deletion.created_at ASC, deletion.object_key ASC LIMIT ?
        )`,
    ).bind(cleanupRowLimit),
    env.DB.prepare(
      `INSERT INTO moment_object_deletions(
         object_key, object_type, owner_id, state, not_before, attempts, created_at
       )
       SELECT object_key, 'moment', id, 'pending', ?, 0, ?
         FROM moments
        WHERE state IN ('reserved', 'uploaded') AND upload_expires_at <= ?
        ORDER BY upload_expires_at ASC, id ASC LIMIT ?
       ON CONFLICT(object_key) DO UPDATE SET
         state = 'pending', not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
         deleted_at = NULL`,
    ).bind(now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moments SET state = 'expired', closed_at = ?
        WHERE id IN (
          SELECT id FROM moments
           WHERE state IN ('reserved', 'uploaded') AND upload_expires_at <= ?
           ORDER BY upload_expires_at ASC, id ASC LIMIT ?
        )`,
    ).bind(now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moment_deliveries SET state = 'expired'
        WHERE (moment_id, recipient_participant_id) IN (
          SELECT moment_id, recipient_participant_id
            FROM moment_deliveries
           WHERE state IN ('pending', 'acknowledged') AND access_expires_at <= ?
           ORDER BY access_expires_at ASC, moment_id ASC, recipient_participant_id ASC
           LIMIT ?
        )`,
    ).bind(now, cleanupRowLimit),
    env.DB.prepare(
      `INSERT INTO moment_object_deletions(
         object_key, object_type, owner_id, state, not_before, attempts, created_at
       )
       SELECT object_key, 'moment', id, 'pending', ?, 0, ?
         FROM moments AS moment
        WHERE state = 'committed'
          AND (
            unreceived_expires_at <= ?
            OR NOT EXISTS (
              SELECT 1 FROM moment_deliveries AS delivery
               WHERE delivery.moment_id = moment.id
                 AND delivery.state IN ('pending', 'acknowledged')
                 AND delivery.access_expires_at > ?
            )
          )
        ORDER BY committed_at ASC, id ASC LIMIT ?
       ON CONFLICT(object_key) DO UPDATE SET
         state = 'pending', not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
         deleted_at = NULL`,
    ).bind(now, now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moments SET state = 'expired', closed_at = ?
        WHERE id IN (
          SELECT id FROM moments AS moment
           WHERE state = 'committed'
             AND (
               unreceived_expires_at <= ?
               OR NOT EXISTS (
                 SELECT 1 FROM moment_deliveries AS delivery
                  WHERE delivery.moment_id = moment.id
                    AND delivery.state IN ('pending', 'acknowledged')
                    AND delivery.access_expires_at > ?
               )
             )
           ORDER BY committed_at ASC, id ASC LIMIT ?
        )`,
    ).bind(now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `INSERT INTO moment_object_deletions(
         object_key, object_type, owner_id, state, not_before, attempts, created_at
       )
       SELECT object_key, 'report', id, 'pending', ?, 0, ?
         FROM moment_reports
        WHERE (state IN ('reserved', 'uploaded') AND upload_expires_at <= ?)
           OR (state = 'committed' AND content_expires_at <= ?)
        ORDER BY created_at ASC, id ASC LIMIT ?
       ON CONFLICT(object_key) DO UPDATE SET
         state = 'pending', not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
         deleted_at = NULL`,
    ).bind(now, now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moment_reports SET state = 'expired', closed_at = ?
        WHERE id IN (
          SELECT id FROM moment_reports
           WHERE (state IN ('reserved', 'uploaded') AND upload_expires_at <= ?)
              OR (state = 'committed' AND content_expires_at <= ?)
           ORDER BY created_at ASC, id ASC LIMIT ?
        )`,
    ).bind(now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_reports
        WHERE id IN (
          SELECT id FROM moment_reports
           WHERE state = 'deleted' AND committed_at IS NULL
             AND closed_at IS NOT NULL AND closed_at <= ?
           ORDER BY closed_at ASC, id ASC LIMIT ?
        )`,
    ).bind(now - 172_800, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_reports
        WHERE id IN (
          SELECT report.id
            FROM moment_reports AS report
            JOIN moment_report_tombstones AS tombstone
              ON tombstone.report_id = report.id
           WHERE report.state = 'deleted' AND report.committed_at IS NOT NULL
             AND tombstone.content_deleted_at IS NOT NULL
             AND tombstone.content_deleted_at <= ?
           ORDER BY tombstone.content_deleted_at ASC, report.id ASC LIMIT ?
        )`,
    ).bind(now - 172_800, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_report_daily_usage
        WHERE rowid IN (
          SELECT rowid FROM moment_report_daily_usage
           WHERE day_key < ?
           ORDER BY day_key ASC, participant_id ASC LIMIT ?
        )`,
    ).bind(Math.floor(now / 86_400) - 90, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_reaction_daily_usage
        WHERE rowid IN (
          SELECT rowid FROM moment_reaction_daily_usage
           WHERE day_key < ?
           ORDER BY day_key ASC, participant_id ASC LIMIT ?
        )`,
    ).bind(
      Math.floor(now / 86_400) - REACTION_USAGE_RETENTION_DAYS,
      cleanupRowLimit,
    ),
  ]);

  if (env.MEDIA === undefined && env.MODERATION_MEDIA === undefined) return;
  const deletions = await env.DB.prepare(
    `SELECT object_key, object_type, owner_id, attempts
       FROM moment_object_deletions
      WHERE state = 'pending' AND not_before <= ?
        AND ((object_type = 'moment' AND ? = 1)
             OR (object_type = 'report' AND ? = 1))
        AND (
          (object_type = 'moment' AND NOT EXISTS (
            SELECT 1 FROM moments
             WHERE moments.id = moment_object_deletions.owner_id
               AND moments.state IN ('reserved', 'uploaded', 'committed')
          ))
          OR
          (object_type = 'report' AND NOT EXISTS (
            SELECT 1 FROM moment_reports
             WHERE moment_reports.id = moment_object_deletions.owner_id
               AND moment_reports.state IN ('reserved', 'uploaded', 'committed')
          ))
        )
      ORDER BY not_before ASC, created_at ASC, object_key ASC
      LIMIT ?`,
  ).bind(
    now,
    env.MEDIA === undefined ? 0 : 1,
    env.MODERATION_MEDIA === undefined ? 0 : 1,
    MOMENT_CLEANUP_OBJECT_LIMIT,
  ).all<ObjectDeletionRow>();
  if (deletions.results.length > 0) {
    const momentObjects = deletions.results
      .filter((row) => row.object_type === "moment")
      .map((row) => row.object_key);
    const reportObjects = deletions.results
      .filter((row) => row.object_type === "report")
      .map((row) => row.object_key);
    if (momentObjects.length > 0) await env.MEDIA?.delete(momentObjects);
    if (reportObjects.length > 0) await env.MODERATION_MEDIA?.delete(reportObjects);
    const statements: D1PreparedStatement[] = [];
    const momentOwnerIDs = deletions.results
      .filter((row) => row.object_type === "moment")
      .map((row) => row.owner_id);
    const reportOwnerIDs = deletions.results
      .filter((row) => row.object_type === "report")
      .map((row) => row.owner_id);
    for (let offset = 0; offset < momentOwnerIDs.length; offset += d1IdentifierChunkSize) {
      const ids = momentOwnerIDs.slice(offset, offset + d1IdentifierChunkSize);
      const placeholders = ids.map(() => "?").join(", ");
      statements.push(env.DB.prepare(
        `UPDATE moments SET state = 'deleted', closed_at = COALESCE(closed_at, ?)
          WHERE id IN (${placeholders}) AND state = 'expired'`,
      ).bind(now, ...ids));
    }
    for (let offset = 0; offset < reportOwnerIDs.length; offset += d1IdentifierChunkSize) {
      const ids = reportOwnerIDs.slice(offset, offset + d1IdentifierChunkSize);
      const placeholders = ids.map(() => "?").join(", ");
      statements.push(env.DB.prepare(
        `UPDATE moment_reports SET state = 'deleted', closed_at = ?
          WHERE id IN (${placeholders}) AND state = 'expired'`,
      ).bind(now, ...ids));
    }
    for (let offset = 0; offset < deletions.results.length; offset += d1CASTupleChunkSize) {
      const rows = deletions.results.slice(offset, offset + d1CASTupleChunkSize);
      const tuples = rows.map(() => "(?, ?)").join(", ");
      statements.push(env.DB.prepare(
        `DELETE FROM moment_object_deletions
          WHERE state = 'pending' AND (object_key, attempts) IN (${tuples})`,
      ).bind(...rows.flatMap((row) => [row.object_key, row.attempts])));
    }
    if (statements.length > 0) {
      await env.DB.batch(statements);
    }
  }
  await processRevokedV2Scopes(env, now);
  await purgeRevokedV2Spaces(env, now);
}
