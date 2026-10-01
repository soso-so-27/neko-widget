var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/errors.ts
var ApiError = class extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
  status;
  code;
  details;
  static {
    __name(this, "ApiError");
  }
};
var sharedHeaders = {
  "Cache-Control": "no-store, max-age=0",
  "Content-Type": "application/json; charset=utf-8",
  Pragma: "no-cache",
  "X-Content-Type-Options": "nosniff"
};
function jsonResponse(value, status = 200, additionalHeaders) {
  const headers = new Headers(sharedHeaders);
  if (additionalHeaders !== void 0) {
    new Headers(additionalHeaders).forEach((headerValue, headerName) => {
      headers.set(headerName, headerValue);
    });
  }
  return new Response(JSON.stringify(value), { status, headers });
}
__name(jsonResponse, "jsonResponse");
function errorResponse(error) {
  if (error instanceof ApiError) {
    return jsonResponse(
      { error: { code: error.code, message: error.message, ...error.details } },
      error.status
    );
  }
  return jsonResponse(
    { error: { code: "internal_error", message: "The request could not be completed." } },
    500
  );
}
__name(errorResponse, "errorResponse");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/env.ts
function momentRuntimeEnabled(env) {
  return env.MOMENT_RUNTIME_ENABLED === "YES";
}
__name(momentRuntimeEnabled, "momentRuntimeEnabled");
function reportIngestionRuntimeEnabled(env) {
  return env.REPORT_INGESTION_RUNTIME_ENABLED === "YES";
}
__name(reportIngestionRuntimeEnabled, "reportIngestionRuntimeEnabled");
function reactionRuntimeEnabled(env) {
  return env.REACTION_RUNTIME_ENABLED === "YES";
}
__name(reactionRuntimeEnabled, "reactionRuntimeEnabled");
function windowNameRuntimeEnabled(env) {
  return env.WINDOW_NAME_RUNTIME_ENABLED === "YES";
}
__name(windowNameRuntimeEnabled, "windowNameRuntimeEnabled");
function apnsRuntimeEnabled(env) {
  return env.APNS_RUNTIME_ENABLED === "YES";
}
__name(apnsRuntimeEnabled, "apnsRuntimeEnabled");
function legacySharingRuntimeEnabled(env) {
  return env.LEGACY_SHARING_RUNTIME_ENABLED === "YES";
}
__name(legacySharingRuntimeEnabled, "legacySharingRuntimeEnabled");
function positiveIntegerSetting(value, fallback) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
__name(positiveIntegerSetting, "positiveIntegerSetting");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/runtime-gate.ts
function bit(value) {
  if (value === 0) return false;
  if (value === 1) return true;
  return null;
}
__name(bit, "bit");
async function loadRuntimeGate(env) {
  try {
    const row = await env.DB.prepare(
      `SELECT generation, media_enabled, apns_enabled,
              report_ingestion_enabled
         FROM personal_staging_runtime_gate
        WHERE singleton = 1`
    ).first();
    if (row === null || !Number.isSafeInteger(row.generation) || row.generation < 0) {
      return null;
    }
    const mediaEnabled = bit(row.media_enabled);
    const apnsEnabled = bit(row.apns_enabled);
    const reportIngestionEnabled = bit(row.report_ingestion_enabled);
    if (mediaEnabled === null || apnsEnabled === null || reportIngestionEnabled === null || apnsEnabled && !mediaEnabled) {
      return null;
    }
    return Object.freeze({
      generation: row.generation,
      mediaEnabled,
      apnsEnabled,
      reportIngestionEnabled
    });
  } catch {
    return null;
  }
}
__name(loadRuntimeGate, "loadRuntimeGate");
function mediaGateOpen(snapshot) {
  return snapshot?.mediaEnabled === true;
}
__name(mediaGateOpen, "mediaGateOpen");
function apnsGateOpen(snapshot) {
  return snapshot?.mediaEnabled === true && snapshot.apnsEnabled;
}
__name(apnsGateOpen, "apnsGateOpen");
function reportIngestionGateOpen(snapshot) {
  return snapshot?.reportIngestionEnabled === true;
}
__name(reportIngestionGateOpen, "reportIngestionGateOpen");
function effectiveRuntimeGateHeaders(env, snapshot) {
  const media = snapshot.mediaEnabled && momentRuntimeEnabled(env) && reactionRuntimeEnabled(env) && windowNameRuntimeEnabled(env);
  const apns = snapshot.mediaEnabled && snapshot.apnsEnabled && apnsRuntimeEnabled(env);
  const report = snapshot.reportIngestionEnabled && reportIngestionRuntimeEnabled(env);
  return new Headers({
    "Cache-Control": "no-store",
    "Neko-Runtime-Gate-Generation": String(snapshot.generation),
    "Neko-Runtime-Media": media ? "ON" : "OFF",
    "Neko-Runtime-Apns": apns ? "ON" : "OFF",
    "Neko-Runtime-Report-Ingestion": report ? "ON" : "OFF"
  });
}
__name(effectiveRuntimeGateHeaders, "effectiveRuntimeGateHeaders");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/encoding.ts
function base64urlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}
__name(base64urlEncode, "base64urlEncode");
function base64urlDecode(value, expectedBytes) {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) {
    throw new ApiError(400, "invalid_base64url", "A binary field is not canonical base64url.");
  }
  const padding = "=".repeat((4 - value.length % 4) % 4);
  let binary;
  try {
    binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
  } catch {
    throw new ApiError(400, "invalid_base64url", "A binary field is not canonical base64url.");
  }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (base64urlEncode(bytes) !== value) {
    throw new ApiError(400, "invalid_base64url", "A binary field is not canonical base64url.");
  }
  if (expectedBytes !== void 0 && bytes.length !== expectedBytes) {
    throw new ApiError(400, "invalid_binary_length", `A binary field must be ${expectedBytes} bytes.`);
  }
  return bytes;
}
__name(base64urlDecode, "base64urlDecode");
function randomBase64url(byteCount) {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return base64urlEncode(bytes);
}
__name(randomBase64url, "randomBase64url");
function arrayBufferCopy(bytes) {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}
__name(arrayBufferCopy, "arrayBufferCopy");
async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", arrayBufferCopy(bytes)));
}
__name(sha256, "sha256");
async function sha256Base64url(bytes) {
  return base64urlEncode(await sha256(bytes));
}
__name(sha256Base64url, "sha256Base64url");
async function verifyEd25519(publicKeyValue, signatureValue, message) {
  const publicKey = await crypto.subtle.importKey(
    "raw",
    arrayBufferCopy(base64urlDecode(publicKeyValue, 32)),
    { name: "Ed25519" },
    false,
    ["verify"]
  );
  return crypto.subtle.verify(
    { name: "Ed25519" },
    publicKey,
    arrayBufferCopy(base64urlDecode(signatureValue, 64)),
    arrayBufferCopy(message)
  );
}
__name(verifyEd25519, "verifyEd25519");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/protocol.ts
var PROTOCOL_VERSION = 1;
var ENVELOPE_ALGORITHM = "X25519-HKDF-SHA256-CHACHA20POLY1305";
var encoder = new TextEncoder();
function encodeCanonicalFields(fields) {
  const encoded = fields.map((field) => encoder.encode(field));
  const byteLength = encoded.reduce((total, field) => total + 2 + field.length, 0);
  const output = new Uint8Array(byteLength);
  const view = new DataView(output.buffer);
  let offset = 0;
  for (const field of encoded) {
    if (field.length > 65535) {
      throw new ApiError(400, "field_too_long", "A canonical field is too long.");
    }
    view.setUint16(offset, field.length, false);
    offset += 2;
    output.set(field, offset);
    offset += field.length;
  }
  return output;
}
__name(encodeCanonicalFields, "encodeCanonicalFields");
function creationTranscript(fields) {
  return encodeCanonicalFields([
    "NW1.CREATE",
    "1",
    fields.clientRequestId,
    fields.participantId,
    fields.agreementPublicKey,
    fields.signingPublicKey,
    fields.invitationProofPublicKey,
    String(fields.dailyBoundaryMinuteUTC)
  ]);
}
__name(creationTranscript, "creationTranscript");
function enrollmentTranscript(fields) {
  return encodeCanonicalFields([
    "NW1.ENROLL",
    "1",
    fields.spaceId,
    fields.invitationId,
    fields.challengeId,
    fields.challengeValue,
    String(fields.challengeExpiresAt),
    fields.clientRequestId,
    fields.participantId,
    fields.agreementPublicKey,
    fields.signingPublicKey
  ]);
}
__name(enrollmentTranscript, "enrollmentTranscript");
function pairingTranscript(fields) {
  return encodeCanonicalFields([
    "NW1.PAIRING",
    "1",
    fields.spaceId,
    fields.invitationId,
    fields.enrollmentId,
    String(fields.dailyBoundaryMinuteUTC),
    fields.inviterMemberId,
    fields.inviterParticipantId,
    fields.inviterAgreementPublicKey,
    fields.inviterSigningPublicKey,
    fields.inviteeMemberId,
    fields.inviteeParticipantId,
    fields.inviteeAgreementPublicKey,
    fields.inviteeSigningPublicKey
  ]);
}
__name(pairingTranscript, "pairingTranscript");
function approvalTranscript(transcriptHash, envelopeAlgorithm, keyEnvelope) {
  return encodeCanonicalFields([
    "NW1.APPROVE",
    "1",
    transcriptHash,
    envelopeAlgorithm,
    keyEnvelope
  ]);
}
__name(approvalTranscript, "approvalTranscript");
function deviceRecoveryClaimTranscript(fields) {
  return encodeCanonicalFields([
    "NW2.DEVICE-RECOVERY.CLAIM",
    "2",
    fields.recoveryId,
    fields.spaceId,
    String(fields.dailyBoundaryMinuteUTC),
    String(fields.expiresAt),
    String(fields.membershipRevision),
    String(fields.keyEpoch),
    fields.targetMemberId,
    fields.targetParticipantId,
    fields.targetRole,
    fields.targetAgreementPublicKey,
    fields.targetSigningPublicKey,
    fields.initiatorMemberId,
    fields.initiatorParticipantId,
    fields.initiatorRole,
    fields.initiatorAgreementPublicKey,
    fields.initiatorSigningPublicKey,
    fields.clientRequestId,
    fields.deviceId,
    fields.agreementPublicKey,
    fields.signingPublicKey
  ]);
}
__name(deviceRecoveryClaimTranscript, "deviceRecoveryClaimTranscript");
function deviceRecoveryApprovalTranscript(fields) {
  return encodeCanonicalFields([
    "NW2.DEVICE-RECOVERY.APPROVE",
    "2",
    fields.recoveryId,
    fields.spaceId,
    fields.targetMemberId,
    fields.deviceId,
    String(fields.membershipRevision),
    String(fields.keyEpoch),
    fields.transcriptHash,
    fields.envelopeAlgorithm,
    fields.keyEnvelope
  ]);
}
__name(deviceRecoveryApprovalTranscript, "deviceRecoveryApprovalTranscript");
function deviceRecoverySignedRequestTranscript(fields) {
  return encodeCanonicalFields([
    "NW2.DEVICE-RECOVERY.REQUEST",
    "2",
    fields.recoveryId,
    String(fields.timestamp),
    fields.nonce,
    fields.method.toUpperCase(),
    fields.pathname,
    fields.bodySHA256
  ]);
}
__name(deviceRecoverySignedRequestTranscript, "deviceRecoverySignedRequestTranscript");
function signedRequestTranscript(fields) {
  return encodeCanonicalFields([
    "NW1.REQUEST",
    "1",
    fields.memberId,
    String(fields.timestamp),
    fields.nonce,
    fields.method.toUpperCase(),
    fields.pathname,
    fields.bodySHA256
  ]);
}
__name(signedRequestTranscript, "signedRequestTranscript");
function shareDayKey(now, dailyBoundaryMinuteUTC) {
  return Math.floor((now - dailyBoundaryMinuteUTC * 60) / 86400);
}
__name(shareDayKey, "shareDayKey");
function nextShareDayBoundary(dayKey, dailyBoundaryMinuteUTC) {
  return (dayKey + 1) * 86400 + dailyBoundaryMinuteUTC * 60;
}
__name(nextShareDayBoundary, "nextShareDayBoundary");
function nextRotationAnchor(now) {
  return Math.ceil((now + 300) / 1200) * 1200;
}
__name(nextRotationAnchor, "nextRotationAnchor");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/validation.ts
var uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
var opaqueIdPattern = /^[A-Za-z0-9_-]{22}$/u;
function asObject(value) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new ApiError(400, "invalid_json", "The JSON body must be an object.");
  }
  return value;
}
__name(asObject, "asObject");
function exactKeys(object, expected) {
  const actual = Object.keys(object).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new ApiError(400, "invalid_fields", "The JSON body has missing or unknown fields.");
  }
}
__name(exactKeys, "exactKeys");
function stringField(object, key) {
  const value = object[key];
  if (typeof value !== "string") {
    throw new ApiError(400, "invalid_field", `${key} must be a string.`);
  }
  return value;
}
__name(stringField, "stringField");
function integerField(object, key, minimum, maximum) {
  const value = object[key];
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new ApiError(400, "invalid_field", `${key} is outside its allowed range.`);
  }
  return value;
}
__name(integerField, "integerField");
function protocolVersion(object) {
  if (object.protocolVersion !== 1) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 1.");
  }
  return 1;
}
__name(protocolVersion, "protocolVersion");
function uuidField(object, key) {
  const value = stringField(object, key);
  if (!uuidPattern.test(value)) {
    throw new ApiError(400, "invalid_field", `${key} must be a lowercase UUIDv4.`);
  }
  return value;
}
__name(uuidField, "uuidField");
function opaqueId(value, name) {
  if (!opaqueIdPattern.test(value)) {
    throw new ApiError(404, "not_found", `${name} was not found.`);
  }
  return value;
}
__name(opaqueId, "opaqueId");
function binaryField(object, key, bytes) {
  const value = stringField(object, key);
  base64urlDecode(value, bytes);
  return value;
}
__name(binaryField, "binaryField");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/auth.ts
async function authenticateSignedRequest(request, env, body) {
  if (request.headers.get("neko-protocol-version") !== "1") {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  let memberId;
  let requestedDeviceId = null;
  try {
    memberId = opaqueId(request.headers.get("neko-member-id") ?? "", "member");
    const rawDeviceId = request.headers.get("neko-device-id");
    if (rawDeviceId !== null) {
      requestedDeviceId = opaqueId(rawDeviceId, "device");
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
  const now = Math.floor(Date.now() / 1e3);
  if (Math.abs(now - timestamp) > 300) {
    throw new ApiError(401, "stale_request", "The signed request timestamp is outside the five-minute window.");
  }
  const devicePredicate = requestedDeviceId === null ? "AND device.legacy_member_id = m.id" : "AND device.id = ?";
  const memberStatement = env.DB.prepare(
    `SELECT m.id, m.space_id, m.role, m.participant_id,
            participant.id AS moment_participant_id, device.id AS device_id,
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
        AND device.state = m.state
        ${devicePredicate}
      WHERE m.id = ?`
  );
  const member = await (requestedDeviceId === null ? memberStatement.bind(memberId) : memberStatement.bind(requestedDeviceId, memberId)).first();
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
    bodySHA256: await sha256Base64url(body)
  });
  if (!await verifyEd25519(member.signing_public_key, signature, transcript)) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  return {
    id: member.id,
    spaceId: member.space_id,
    role: member.role,
    participantId: member.participant_id,
    momentParticipantId: member.moment_participant_id,
    deviceId: member.device_id,
    agreementPublicKey: member.agreement_public_key,
    signingPublicKey: member.signing_public_key,
    state: member.state,
    spaceState: member.space_state,
    nonce,
    now
  };
}
__name(authenticateSignedRequest, "authenticateSignedRequest");
function nonceStatements(env, member) {
  return [
    env.DB.prepare("DELETE FROM request_nonces WHERE member_id = ? AND expires_at < ?").bind(member.id, member.now),
    env.DB.prepare(
      "INSERT INTO request_nonces(member_id, nonce, created_at, expires_at) VALUES (?, ?, ?, ?)"
    ).bind(member.id, member.nonce, member.now, member.now + 601)
  ];
}
__name(nonceStatements, "nonceStatements");
function activityStatement(env, member) {
  const metadataExpiresAt = member.now + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2592e3);
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
        )`
  ).bind(member.now, metadataExpiresAt, member.spaceId, member.id);
}
__name(activityStatement, "activityStatement");
async function consumeNonce(env, member) {
  try {
    await env.DB.batch(nonceStatements(env, member));
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}
__name(consumeNonce, "consumeNonce");
async function consumeNonceAndTouch(env, member) {
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      activityStatement(env, member)
    ]);
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}
__name(consumeNonceAndTouch, "consumeNonceAndTouch");
function requireLiveSpace(member) {
  if (member.spaceState !== "active" || member.state === "revoked" || member.state === "expired") {
    throw new ApiError(410, "sharing_revoked", "This sharing space is no longer active.");
  }
}
__name(requireLiveSpace, "requireLiveSpace");
function requireOwner(member) {
  requireLiveSpace(member);
  if (member.role !== "owner" || member.state !== "active") {
    throw new ApiError(403, "owner_required", "Only the active inviter can perform this operation.");
  }
}
__name(requireOwner, "requireOwner");
function requirePendingInvitee(member) {
  requireLiveSpace(member);
  if (member.role !== "invitee" || member.state !== "pending") {
    throw new ApiError(409, "invalid_pairing_state", "The invited member is not awaiting completion.");
  }
}
__name(requirePendingInvitee, "requirePendingInvitee");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/http.ts
var defaultMaximumBodyBytes = 16 * 1024;
async function readBody(request, maximumBodyBytes = defaultMaximumBodyBytes) {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength)) {
      throw new ApiError(400, "invalid_content_length", "Content-Length is invalid.");
    }
    if (Number(contentLength) > maximumBodyBytes) {
      throw new ApiError(413, "body_too_large", "The request body is too large.");
    }
  }
  if (request.body === null) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maximumBodyBytes) {
      await reader.cancel();
      throw new ApiError(413, "body_too_large", "The request body is too large.");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}
__name(readBody, "readBody");
function parseJsonBody(request, body) {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/json.");
  }
  let decoded;
  try {
    decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new ApiError(400, "invalid_json", "The JSON body is invalid UTF-8 JSON.");
  }
  return asObject(decoded);
}
__name(parseJsonBody, "parseJsonBody");
function requireEmptyBody(body) {
  if (body.length !== 0) {
    throw new ApiError(400, "body_must_be_empty", "This request must have an empty body.");
  }
}
__name(requireEmptyBody, "requireEmptyBody");
function rejectQuery(url) {
  if (url.search !== "") {
    throw new ApiError(400, "query_not_allowed", "Query parameters are not accepted.");
  }
}
__name(rejectQuery, "rejectQuery");
async function enforceRateLimit(env, binding, key) {
  if (binding === void 0) {
    if (env.ENVIRONMENT !== "local") {
      throw new ApiError(503, "rate_limiter_unavailable", "The service is temporarily unavailable.");
    }
    return;
  }
  const result = await binding.limit({ key });
  if (!result.success) {
    throw new ApiError(429, "rate_limited", "Too many requests. Try again later.");
  }
}
__name(enforceRateLimit, "enforceRateLimit");
function transientNetworkKey(request, suffix) {
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  return `${suffix}:${address}`;
}
__name(transientNetworkKey, "transientNetworkKey");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/idempotency.ts
async function storedIdempotentResponse(env, operation, actorId, clientRequestId, requestHash) {
  const now = Math.floor(Date.now() / 1e3);
  await env.DB.prepare(
    `DELETE FROM idempotency_records
      WHERE operation = ? AND actor_id = ? AND client_request_id = ? AND expires_at <= ?`
  ).bind(operation, actorId, clientRequestId, now).run();
  const row = await env.DB.prepare(
    `SELECT request_hash, response_status, response_json
       FROM idempotency_records
      WHERE operation = ? AND actor_id = ? AND client_request_id = ?`
  ).bind(operation, actorId, clientRequestId).first();
  if (row === null) return null;
  if (row.request_hash !== requestHash) {
    throw new ApiError(409, "idempotency_conflict", "The idempotency key was already used with another request.");
  }
  return jsonResponse(JSON.parse(row.response_json), row.response_status);
}
__name(storedIdempotentResponse, "storedIdempotentResponse");
function idempotencyStatement(env, operation, actorId, clientRequestId, spaceId, requestHash, responseStatus, responseBody2, now) {
  const expiresAt = now + positiveIntegerSetting(env.IDEMPOTENCY_TTL_SECONDS, 172800);
  return env.DB.prepare(
    `INSERT INTO idempotency_records(
       operation, actor_id, client_request_id, space_id, request_hash,
       response_status, response_json, created_at, expires_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    operation,
    actorId,
    clientRequestId,
    spaceId,
    requestHash,
    responseStatus,
    JSON.stringify(responseBody2),
    now,
    expiresAt
  );
}
__name(idempotencyStatement, "idempotencyStatement");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/handlers.ts
function nowSeconds() {
  return Math.floor(Date.now() / 1e3);
}
__name(nowSeconds, "nowSeconds");
async function safelyVerify(publicKey, signature, message) {
  try {
    return await verifyEd25519(publicKey, signature, message);
  } catch {
    return false;
  }
}
__name(safelyVerify, "safelyVerify");
async function expireStalePairingState(env, now, scope) {
  const byInvitation = "invitationId" in scope;
  const scopeIds = byInvitation ? [scope.invitationId] : [...scope.spaceIds];
  if (scopeIds.length === 0) return;
  const placeholders2 = scopeIds.map(() => "?").join(", ");
  const enrollmentScope = byInvitation ? "invitation_id = ?" : `space_id IN (${placeholders2})`;
  const invitationScope = byInvitation ? "id = ?" : `space_id IN (${placeholders2})`;
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE approval_events
          SET key_envelope = NULL, approval_signature = NULL
        WHERE enrollment_id IN (
          SELECT id FROM enrollments
           WHERE state IN ('pending', 'approved') AND expires_at <= ?
             AND ${enrollmentScope}
        )`
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `UPDATE members
          SET state = 'expired'
        WHERE state = 'pending'
          AND id IN (
            SELECT member_id FROM enrollments
             WHERE state IN ('pending', 'approved') AND expires_at <= ?
               AND ${enrollmentScope}
          )`
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `UPDATE enrollments
        SET state = 'expired'
        WHERE state IN ('pending', 'approved') AND expires_at <= ?
          AND ${enrollmentScope}`
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `UPDATE invitations
          SET status = 'expired', invite_proof_public_key = NULL
        WHERE status = 'open' AND expires_at <= ? AND ${invitationScope}`
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
          )`
    ).bind(now, ...scopeIds),
    env.DB.prepare(
      `DELETE FROM invitation_challenges
        WHERE id IN (
          SELECT challenge_id FROM enrollments
           WHERE state = 'expired' AND challenge_id IS NOT NULL
             AND ${enrollmentScope}
        )`
    ).bind(...scopeIds)
  ]);
}
__name(expireStalePairingState, "expireStalePairingState");
function publicMember(id, role, state, participantId, agreementPublicKey, signingPublicKey) {
  return { id, role, state, participantId, agreementPublicKey, signingPublicKey };
}
__name(publicMember, "publicMember");
async function createSpace(request, env) {
  await enforceRateLimit(
    env,
    env.CREATE_RATE_LIMITER,
    transientNetworkKey(request, "create")
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
    "creationSignature"
  ]);
  protocolVersion(object);
  const fields = {
    clientRequestId: uuidField(object, "clientRequestId"),
    participantId: binaryField(object, "participantId", 16),
    agreementPublicKey: binaryField(object, "agreementPublicKey", 32),
    signingPublicKey: binaryField(object, "signingPublicKey", 32),
    invitationProofPublicKey: binaryField(object, "invitationProofPublicKey", 32),
    dailyBoundaryMinuteUTC: integerField(object, "dailyBoundaryMinuteUTC", 0, 1439)
  };
  const creationSignature = binaryField(object, "creationSignature", 64);
  if (!await safelyVerify(fields.signingPublicKey, creationSignature, creationTranscript(fields))) {
    throw new ApiError(401, "invalid_creation_signature", "The space creation signature is invalid.");
  }
  const requestHash = await sha256Base64url(body);
  const existing = await storedIdempotentResponse(
    env,
    "create-space",
    "public",
    fields.clientRequestId,
    requestHash
  );
  if (existing !== null) return existing;
  const now = nowSeconds();
  const invitationTTL = positiveIntegerSetting(env.INVITATION_TTL_SECONDS, 86400);
  const metadataExpiresAt = now + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2592e3);
  const spaceId = randomBase64url(16);
  const memberId = randomBase64url(16);
  const invitationId = randomBase64url(16);
  const expiresAt = now + invitationTTL;
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId,
    dailyBoundaryMinuteUTC: fields.dailyBoundaryMinuteUTC,
    member: publicMember(
      memberId,
      "owner",
      "active",
      fields.participantId,
      fields.agreementPublicKey,
      fields.signingPublicKey
    ),
    invitation: { id: invitationId, state: "open", expiresAt }
  };
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO spaces(
           id, creation_request_id, protocol_version, daily_boundary_minute_utc,
           state, created_at, last_activity_at, metadata_expires_at
         ) VALUES (?, ?, 1, ?, 'active', ?, ?, ?)`
      ).bind(
        spaceId,
        fields.clientRequestId,
        fields.dailyBoundaryMinuteUTC,
        now,
        now,
        metadataExpiresAt
      ),
      env.DB.prepare(
        `INSERT INTO members(
           id, space_id, role, participant_id, agreement_public_key,
           signing_public_key, state, created_at, activated_at
         ) VALUES (?, ?, 'owner', ?, ?, ?, 'active', ?, ?)`
      ).bind(
        memberId,
        spaceId,
        fields.participantId,
        fields.agreementPublicKey,
        fields.signingPublicKey,
        now,
        now
      ),
      env.DB.prepare(
        `INSERT INTO invitations(
           id, space_id, inviter_member_id, invite_proof_public_key,
           status, created_at, expires_at
         ) VALUES (?, ?, ?, ?, 'open', ?, ?)`
      ).bind(
        invitationId,
        spaceId,
        memberId,
        fields.invitationProofPublicKey,
        now,
        expiresAt
      ),
      idempotencyStatement(
        env,
        "create-space",
        "public",
        fields.clientRequestId,
        spaceId,
        requestHash,
        201,
        responseBody2,
        now
      )
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "create-space",
      "public",
      fields.clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "space_creation_conflict", "The space could not be created with these identities.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(createSpace, "createSpace");
async function createChallenge(request, env, invitationIdValue) {
  const invitationId = opaqueId(invitationIdValue, "invitation");
  await enforceRateLimit(
    env,
    env.INVITE_RATE_LIMITER,
    transientNetworkKey(request, `challenge:${invitationId}`)
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
      WHERE i.id = ?`
  ).bind(invitationId).first();
  if (invitation === null || invitation.invitation_status !== "open" || invitation.space_state !== "active" || invitation.invite_proof_public_key === null) {
    throw new ApiError(410, "invitation_unavailable", "This invitation is no longer available.");
  }
  const challengeCount = await env.DB.prepare(
    `SELECT COUNT(*) AS count
       FROM invitation_challenges
      WHERE invitation_id = ? AND consumed_at IS NULL AND expires_at > ?`
  ).bind(invitationId, now).first();
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
       VALUES (?, ?, ?, ?, ?)`
    ).bind(challengeId, invitationId, challengeValue, now, expiresAt).run();
  } catch {
    const live = await env.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM invitation_challenges
        WHERE invitation_id = ? AND consumed_at IS NULL AND expires_at > ?`
    ).bind(invitationId, now).first();
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
        signingPublicKey: invitation.inviter_signing_public_key
      }
    },
    201
  );
}
__name(createChallenge, "createChallenge");
async function redeemInvitation(request, env, invitationIdValue) {
  const invitationId = opaqueId(invitationIdValue, "invitation");
  await enforceRateLimit(
    env,
    env.INVITE_RATE_LIMITER,
    transientNetworkKey(request, `enroll:${invitationId}`)
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
    "participantSignature"
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
    requestHash
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
      WHERE i.id = ? AND c.id = ?`
  ).bind(invitationId, challengeId).first();
  if (challenge === null || challenge.invitation_status !== "open" || challenge.space_state !== "active" || challenge.invite_proof_public_key === null || challenge.challenge_consumed_at !== null || challenge.challenge_expires_at <= now) {
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
    signingPublicKey
  });
  const [validInviteProof, validParticipantProof] = await Promise.all([
    safelyVerify(challenge.invite_proof_public_key, inviteProofSignature, enrollmentBytes),
    safelyVerify(signingPublicKey, participantSignature, enrollmentBytes)
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
    inviteeSigningPublicKey: signingPublicKey
  });
  const transcript = base64urlEncode(transcriptBytes);
  const transcriptHash = await sha256Base64url(transcriptBytes);
  const pendingTTL = positiveIntegerSetting(env.PENDING_TTL_SECONDS, 86400);
  const expiresAt = now + pendingTTL;
  const metadataExpiresAt = now + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2592e3);
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: challenge.space_id,
    dailyBoundaryMinuteUTC: challenge.daily_boundary_minute_utc,
    member: publicMember(
      memberId,
      "invitee",
      "pending",
      participantId,
      agreementPublicKey,
      signingPublicKey
    ),
    enrollment: {
      id: enrollmentId,
      state: "pendingApproval",
      createdAt: now,
      expiresAt,
      transcript,
      transcriptHash
    }
  };
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO members(
           id, space_id, role, participant_id, agreement_public_key,
           signing_public_key, state, created_at
         ) VALUES (?, ?, 'invitee', ?, ?, ?, 'pending', ?)`
      ).bind(
        memberId,
        challenge.space_id,
        participantId,
        agreementPublicKey,
        signingPublicKey,
        now
      ),
      env.DB.prepare(
        `INSERT INTO enrollments(
           id, invitation_id, challenge_id, space_id, member_id, client_request_id,
           state, transcript, transcript_hash, invite_proof_signature,
           participant_signature, created_at, expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)`
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
        expiresAt
      ),
      env.DB.prepare(
        `UPDATE spaces
            SET last_activity_at = ?, metadata_expires_at = ?
          WHERE id = ? AND state = 'active'`
      ).bind(now, metadataExpiresAt, challenge.space_id),
      idempotencyStatement(
        env,
        "redeem-invitation",
        invitationId,
        clientRequestId,
        challenge.space_id,
        requestHash,
        201,
        responseBody2,
        now
      )
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "redeem-invitation",
      invitationId,
      clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invitation_already_used", "This invitation was already used or conflicts with this identity.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(redeemInvitation, "redeemInvitation");
async function signedMemberRequest(request, env) {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "member")
  );
  const body = await readBody(request);
  return { body, member: await authenticateSignedRequest(request, env, body) };
}
__name(signedMemberRequest, "signedMemberRequest");
async function loadEnrollment(env, spaceId) {
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
      LIMIT 1`
  ).bind(spaceId).first();
}
__name(loadEnrollment, "loadEnrollment");
async function getPending(request, env) {
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
      ORDER BY e.created_at ASC`
  ).bind(member.spaceId).all();
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
        row.invitee_signing_public_key
      )
    }))
  });
}
__name(getPending, "getPending");
async function getStatus(request, env) {
  const { body, member } = await signedMemberRequest(request, env);
  requireEmptyBody(body);
  await expireStalePairingState(env, member.now, { spaceIds: [member.spaceId] });
  const space = await env.DB.prepare(
    "SELECT id, daily_boundary_minute_utc, state FROM spaces WHERE id = ?"
  ).bind(member.spaceId).first();
  const currentMember = await env.DB.prepare(
    "SELECT state FROM members WHERE id = ? AND space_id = ?"
  ).bind(member.id, member.spaceId).first();
  if (space === null || space.state !== "active" || currentMember === null || currentMember.state === "revoked" || currentMember.state === "expired") {
    await consumeNonce(env, member);
    throw new ApiError(410, "sharing_revoked", "This sharing space is no longer active.");
  }
  await consumeNonceAndTouch(env, member);
  const enrollment = await loadEnrollment(env, member.spaceId);
  const completedRecovery = await env.DB.prepare(
    `SELECT consumed_at FROM device_recoveries
      WHERE space_id = ? AND state = 'consumed'
      ORDER BY consumed_at DESC LIMIT 1`
  ).bind(member.spaceId).first();
  const recovered = completedRecovery !== null;
  let state = recovered ? "active" : "awaitingInvitee";
  if (!recovered && enrollment !== null) {
    state = enrollment.enrollment_state === "pending" ? "pendingApproval" : enrollment.enrollment_state === "approved" ? "approvedAwaitingCompletion" : enrollment.enrollment_state === "consumed" ? "active" : enrollment.enrollment_state === "revoked" ? "cancelled" : "expired";
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
      ORDER BY peer.created_at ASC LIMIT 1`
  ).bind(member.spaceId, member.id).first();
  const peer = currentPeer === null ? null : publicMember(
    currentPeer.id,
    currentPeer.role,
    currentPeer.state,
    currentPeer.participant_id,
    currentPeer.agreement_public_key,
    currentPeer.signing_public_key
  );
  const keyEnvelope = !recovered && member.role === "invitee" && enrollment?.enrollment_state === "approved" && enrollment.key_envelope !== null && enrollment.envelope_algorithm !== null && enrollment.approval_signature !== null && enrollment.approved_at !== null ? {
    algorithm: enrollment.envelope_algorithm,
    ciphertext: enrollment.key_envelope,
    approvalSignature: enrollment.approval_signature,
    approvedAt: enrollment.approved_at
  } : null;
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
      member.signingPublicKey
    ),
    pairing: {
      state,
      enrollment: enrollment === null || recovered ? null : {
        id: enrollment.enrollment_id,
        createdAt: enrollment.enrollment_created_at,
        expiresAt: enrollment.enrollment_expires_at,
        transcript: enrollment.transcript,
        transcriptHash: enrollment.transcript_hash
      },
      peer,
      keyEnvelope
    }
  });
}
__name(getStatus, "getStatus");
async function replayAfterRace(env, operation, member, clientRequestId, requestHash, touchActivity = true) {
  const stored = await storedIdempotentResponse(
    env,
    operation,
    member.id,
    clientRequestId,
    requestHash
  );
  if (stored === null) return null;
  if (touchActivity) {
    await consumeNonceAndTouch(env, member);
  } else {
    await consumeNonce(env, member);
  }
  return stored;
}
__name(replayAfterRace, "replayAfterRace");
async function consumeNonceAndThrow(env, member, error) {
  await consumeNonce(env, member);
  throw error;
}
__name(consumeNonceAndThrow, "consumeNonceAndThrow");
async function approveEnrollment(request, env, enrollmentIdValue) {
  const enrollmentId = opaqueId(enrollmentIdValue, "enrollment");
  const { body, member } = await signedMemberRequest(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "transcriptHash",
    "envelopeAlgorithm",
    "keyEnvelope",
    "approvalSignature"
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
    requestHash
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
  if (enrollment === null || enrollment.enrollment_id !== enrollmentId || enrollment.enrollment_state !== "pending" || enrollment.transcript_hash !== transcriptHash) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(409, "invalid_pairing_state", "The enrollment cannot be approved.")
    );
  }
  if (!await safelyVerify(
    member.signingPublicKey,
    approvalSignature,
    approvalTranscript(transcriptHash, envelopeAlgorithm, keyEnvelope)
  )) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(401, "invalid_approval_signature", "The approval signature is invalid.")
    );
  }
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    enrollmentId,
    state: "approvedAwaitingCompletion",
    approvedAt: member.now
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO approval_events(
           enrollment_id, approver_member_id, client_request_id, transcript_hash,
           envelope_algorithm, key_envelope, approval_signature, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        enrollmentId,
        member.id,
        clientRequestId,
        transcriptHash,
        envelopeAlgorithm,
        keyEnvelope,
        approvalSignature,
        member.now
      ),
      idempotencyStatement(
        env,
        "approve-enrollment",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "approve-enrollment",
      member,
      clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The enrollment cannot be approved.");
  }
  return jsonResponse(responseBody2);
}
__name(approveEnrollment, "approveEnrollment");
async function completeEnrollment(request, env, enrollmentIdValue) {
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
    requestHash
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
  if (enrollment === null || enrollment.enrollment_id !== enrollmentId || enrollment.invitee_member_id !== member.id || enrollment.enrollment_state !== "approved" || enrollment.transcript_hash !== transcriptHash || enrollment.key_envelope === null) {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(409, "invalid_pairing_state", "The enrollment cannot be completed.")
    );
  }
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    enrollmentId,
    memberId: member.id,
    state: "active",
    activatedAt: member.now
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO completion_events(
           enrollment_id, member_id, client_request_id, transcript_hash, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(enrollmentId, member.id, clientRequestId, transcriptHash, member.now),
      idempotencyStatement(
        env,
        "complete-enrollment",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "complete-enrollment",
      member,
      clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The enrollment cannot be completed.");
  }
  return jsonResponse(responseBody2);
}
__name(completeEnrollment, "completeEnrollment");
async function cancelEnrollment(request, env, enrollmentIdValue) {
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
    requestHash
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
  if (enrollment === null || enrollment.enrollment_id !== enrollmentId || enrollment.invitee_member_id !== member.id || enrollment.enrollment_state !== "pending" && enrollment.enrollment_state !== "approved") {
    return consumeNonceAndThrow(
      env,
      member,
      new ApiError(410, "enrollment_unavailable", "This enrollment is no longer cancellable.")
    );
  }
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    enrollmentId,
    memberId: member.id,
    state: "cancelled"
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO cancellation_events(
           enrollment_id, member_id, client_request_id, created_at
         ) VALUES (?, ?, ?, ?)`
      ).bind(enrollmentId, member.id, clientRequestId, member.now),
      idempotencyStatement(
        env,
        "cancel-enrollment",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        202,
        responseBody2,
        member.now
      )
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "cancel-enrollment",
      member,
      clientRequestId,
      requestHash,
      false
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The enrollment could not be cancelled.");
  }
  return jsonResponse(responseBody2, 202);
}
__name(cancelEnrollment, "cancelEnrollment");
async function revokeSpace(request, env) {
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
    requestHash
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
        "Pairing must be completed before the whole space can be revoked."
      )
    );
  }
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    spaceId: member.spaceId,
    state: "revoked",
    deletionState: "pending"
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO revocation_events(space_id, actor_member_id, client_request_id, created_at)
         VALUES (?, ?, ?, ?)`
      ).bind(member.spaceId, member.id, clientRequestId, member.now),
      idempotencyStatement(
        env,
        "revoke-space",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        202,
        responseBody2,
        member.now
      )
    ]);
  } catch {
    const raced = await replayAfterRace(
      env,
      "revoke-space",
      member,
      clientRequestId,
      requestHash,
      false
    );
    if (raced !== null) return raced;
    throw new ApiError(409, "invalid_pairing_state", "The sharing space cannot be revoked again.");
  }
  return jsonResponse(responseBody2, 202);
}
__name(revokeSpace, "revokeSpace");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/device-recovery.ts
var DEVICE_RECOVERY_PROTOCOL_VERSION = 2;
var DEVICE_RECOVERY_TTL_SECONDS = 15 * 60;
var expiryCleanupLimit = 1e3;
function nowSeconds2() {
  return Math.floor(Date.now() / 1e3);
}
__name(nowSeconds2, "nowSeconds");
function protocolVersion2(object) {
  if (object.protocolVersion !== DEVICE_RECOVERY_PROTOCOL_VERSION) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
}
__name(protocolVersion2, "protocolVersion2");
async function safelyVerify2(publicKey, signature, message) {
  try {
    return await verifyEd25519(publicKey, signature, message);
  } catch {
    return false;
  }
}
__name(safelyVerify2, "safelyVerify");
function publicIdentity(fields) {
  return {
    memberId: fields.memberId,
    participantId: fields.participantId,
    role: fields.role,
    agreementPublicKey: fields.agreementPublicKey,
    signingPublicKey: fields.signingPublicKey,
    state: fields.state
  };
}
__name(publicIdentity, "publicIdentity");
function targetIdentity(row) {
  return publicIdentity({
    memberId: row.target_member_id,
    participantId: row.target_participant_id,
    role: row.target_role,
    agreementPublicKey: row.target_agreement_public_key,
    signingPublicKey: row.target_signing_public_key,
    state: row.target_member_state
  });
}
__name(targetIdentity, "targetIdentity");
function peerIdentity(row) {
  return publicIdentity({
    memberId: row.initiator_member_id,
    participantId: row.initiator_participant_id,
    role: row.initiator_role,
    agreementPublicKey: row.initiator_agreement_public_key,
    signingPublicKey: row.initiator_signing_public_key,
    state: row.initiator_member_state
  });
}
__name(peerIdentity, "peerIdentity");
function replacementIdentity(row) {
  if (row.proposed_agreement_public_key === null || row.proposed_signing_public_key === null) return null;
  return publicIdentity({
    memberId: row.target_member_id,
    participantId: row.target_participant_id,
    role: row.target_role,
    agreementPublicKey: row.proposed_agreement_public_key,
    signingPublicKey: row.proposed_signing_public_key,
    state: row.recovery_state === "consumed" ? "active" : "pending"
  });
}
__name(replacementIdentity, "replacementIdentity");
function publicRecoveryState(state) {
  switch (state) {
    case "open":
      return "awaitingClaim";
    case "claimed":
      return "pendingApproval";
    case "approved":
      return "approvedAwaitingCompletion";
    case "consumed":
      return "active";
    case "expired":
      return "expired";
  }
}
__name(publicRecoveryState, "publicRecoveryState");
async function loadRecovery(env, recoveryID) {
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
        AND initiator_device.agreement_public_key
              = recovery.initiator_agreement_public_key
        AND initiator_device.signing_public_key
              = recovery.initiator_signing_public_key
        AND initiator_device.state = 'active'
        AND (
          initiator.role <> 'owner'
          OR initiator_device.legacy_member_id = initiator.id
        )
       LEFT JOIN device_recovery_claim_events AS claim
         ON claim.recovery_id = recovery.id
       LEFT JOIN device_recovery_approval_events AS approval
         ON approval.recovery_id = recovery.id
       LEFT JOIN device_recovery_completion_events AS completion
         ON completion.recovery_id = recovery.id
      WHERE recovery.id = ?`
  ).bind(recoveryID).first();
}
__name(loadRecovery, "loadRecovery");
function recoveryMetadata(row) {
  return {
    id: row.recovery_id,
    state: publicRecoveryState(row.recovery_state),
    codePrefix: `NWR1.${row.recovery_id}`,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    membershipRevision: row.expected_membership_revision,
    keyEpoch: row.expected_key_epoch
  };
}
__name(recoveryMetadata, "recoveryMetadata");
function descriptorResponse(row) {
  return {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recovery: recoveryMetadata(row),
    space: {
      id: row.space_id,
      dailyBoundaryMinuteUTC: row.daily_boundary_minute_utc
    },
    target: targetIdentity(row),
    peer: peerIdentity(row)
  };
}
__name(descriptorResponse, "descriptorResponse");
function statusResponse(row) {
  const keyEnvelope = row.recovery_state === "approved" && row.envelope_algorithm !== null && row.key_envelope !== null && row.approval_signature !== null && row.approved_at !== null ? {
    algorithm: row.envelope_algorithm,
    ciphertext: row.key_envelope,
    approvalSignature: row.approval_signature,
    approvedAt: row.approved_at
  } : null;
  return {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recovery: {
      ...recoveryMetadata(row),
      transcript: row.claim_transcript,
      transcriptHash: row.claim_transcript_hash,
      clientRequestId: row.claim_client_request_id,
      deviceId: row.proposed_device_id,
      keyEnvelope,
      recoveredAt: row.consumed_at
    },
    space: {
      id: row.space_id,
      dailyBoundaryMinuteUTC: row.daily_boundary_minute_utc,
      currentMembershipRevision: row.current_membership_revision,
      currentKeyEpoch: row.current_key_epoch
    },
    credential: replacementIdentity(row),
    peer: peerIdentity(row),
    previousTargetSigningPublicKey: row.target_signing_public_key,
    recoveredAt: row.consumed_at
  };
}
__name(statusResponse, "statusResponse");
function claimResponse(row) {
  return statusResponse({ ...row, recovery_state: "claimed" });
}
__name(claimResponse, "claimResponse");
async function expireDeviceRecoveries(env, now, scope) {
  const scopePredicate = scope?.recoveryID !== void 0 ? "recovery.id = ?" : scope?.spaceID !== void 0 ? "recovery.space_id = ?" : "1 = 1";
  const values = scope?.recoveryID !== void 0 ? [scope.recoveryID, now] : scope?.spaceID !== void 0 ? [scope.spaceID, now] : [now];
  const limit = scope === void 0 ? `LIMIT ${expiryCleanupLimit}` : "";
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
        WHERE recovery_id IN (${subquery})`
    ).bind(...values),
    env.DB.prepare(
      `UPDATE device_recovery_claim_events
          SET recovery_proof_signature = NULL, device_signature = NULL
        WHERE recovery_id IN (${subquery})`
    ).bind(...values),
    env.DB.prepare(
      `UPDATE device_recoveries
          SET state = 'expired', recovery_proof_public_key = NULL
        WHERE id IN (${subquery})`
    ).bind(...values),
    env.DB.prepare(
      "DELETE FROM device_recovery_request_nonces WHERE expires_at < ?"
    ).bind(now)
  ]);
}
__name(expireDeviceRecoveries, "expireDeviceRecoveries");
async function signedMemberRequest2(request, env) {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-member")
  );
  const body = await readBody(request, 16 * 1024);
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
__name(signedMemberRequest2, "signedMemberRequest");
async function targetForRecovery(env, member, targetParticipantID) {
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
        AND moment_space.state = 'active'`
  ).bind(member.spaceId, targetParticipantID, member.id).first();
}
__name(targetForRecovery, "targetForRecovery");
async function requirePermittedRecoverySponsor(env, member) {
  if (member.role !== "owner") return;
  const primaryOwnerDevice = await env.DB.prepare(
    `SELECT 1 AS permitted
       FROM moment_devices
      WHERE id = ?
        AND participant_id = ?
        AND legacy_member_id = ?
        AND state = 'active'`
  ).bind(
    member.deviceId,
    member.momentParticipantId,
    member.id
  ).first();
  if (primaryOwnerDevice === null) {
    throw new ApiError(
      403,
      "primary_owner_device_required",
      "The original owner device is required to sponsor an invitee device enrollment."
    );
  }
}
__name(requirePermittedRecoverySponsor, "requirePermittedRecoverySponsor");
async function createDeviceRecovery(request, env) {
  const { body, member } = await signedMemberRequest2(request, env);
  let object;
  let clientRequestID;
  let targetParticipantID;
  let recoveryProofPublicKey;
  try {
    object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion",
      "clientRequestId",
      "targetParticipantId",
      "recoveryProofPublicKey"
    ]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    targetParticipantID = binaryField(object, "targetParticipantId", 16);
    recoveryProofPublicKey = binaryField(object, "recoveryProofPublicKey", 32);
    await requirePermittedRecoverySponsor(env, member);
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
    requestHash
  );
  if (replay !== null) {
    await consumeNonceAndTouch(env, member);
    return replay;
  }
  await expireDeviceRecoveries(env, member.now, { spaceID: member.spaceId });
  const target = await targetForRecovery(env, member, targetParticipantID);
  if (target === null || target.active_device_count >= 4) {
    await consumeNonce(env, member);
    throw new ApiError(
      409,
      "recovery_target_unavailable",
      "The peer cannot add another active device."
    );
  }
  const recoveryID = randomBase64url(16);
  const expiresAt = member.now + DEVICE_RECOVERY_TTL_SECONDS;
  const provisional = await env.DB.prepare(
    `SELECT daily_boundary_minute_utc
       FROM spaces
      WHERE id = ? AND state = 'active'`
  ).bind(member.spaceId).first();
  if (provisional === null) {
    await consumeNonce(env, member);
    throw new ApiError(409, "recovery_target_unavailable", "The recovery peer is unavailable.");
  }
  const responseBody2 = {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recovery: {
      id: recoveryID,
      state: "awaitingClaim",
      codePrefix: `NWR1.${recoveryID}`,
      createdAt: member.now,
      expiresAt,
      membershipRevision: target.membership_revision,
      keyEpoch: target.key_epoch
    },
    space: {
      id: member.spaceId,
      dailyBoundaryMinuteUTC: provisional.daily_boundary_minute_utc
    },
    target: publicIdentity({
      memberId: target.member_id,
      participantId: target.participant_id,
      role: target.role,
      agreementPublicKey: target.agreement_public_key,
      signingPublicKey: target.signing_public_key,
      state: "active"
    }),
    peer: publicIdentity({
      memberId: member.id,
      participantId: member.participantId,
      role: member.role,
      agreementPublicKey: member.agreementPublicKey,
      signingPublicKey: member.signingPublicKey,
      state: "active"
    })
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
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?)`
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
        member.agreementPublicKey,
        member.signingPublicKey,
        recoveryProofPublicKey,
        member.now,
        expiresAt
      ),
      idempotencyStatement(
        env,
        "create-device-recovery",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        201,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "create-device-recovery",
      member.id,
      clientRequestID,
      requestHash
    );
    if (raced !== null) {
      await consumeNonceAndTouch(env, member);
      return raced;
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "recovery_already_pending", "A recovery is already pending.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(createDeviceRecovery, "createDeviceRecovery");
async function getDeviceRecoveryDescriptor(request, env, recoveryIDValue) {
  await enforceRateLimit(
    env,
    env.CREATE_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-descriptor")
  );
  const body = await readBody(request);
  requireEmptyBody(body);
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  await expireDeviceRecoveries(env, nowSeconds2(), { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  if (row === null || row.recovery_state !== "open") {
    throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  }
  return jsonResponse(descriptorResponse(row));
}
__name(getDeviceRecoveryDescriptor, "getDeviceRecoveryDescriptor");
function claimFields(row, object) {
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
    signingPublicKey: binaryField(object, "signingPublicKey", 32)
  };
}
__name(claimFields, "claimFields");
async function claimDeviceRecovery(request, env, recoveryIDValue) {
  await enforceRateLimit(
    env,
    env.CREATE_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-claim")
  );
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const body = await readBody(request, 16 * 1024);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "deviceId",
    "agreementPublicKey",
    "signingPublicKey",
    "recoveryProofSignature",
    "deviceSignature"
  ]);
  protocolVersion2(object);
  const recoveryProofSignature = binaryField(object, "recoveryProofSignature", 64);
  const deviceSignature = binaryField(object, "deviceSignature", 64);
  const requestHash = await sha256Base64url(body);
  await expireDeviceRecoveries(env, nowSeconds2(), { recoveryID });
  let row = await loadRecovery(env, recoveryID);
  if (row === null) throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  const fields = claimFields(row, object);
  if (row.claim_client_request_id !== null) {
    if (row.claim_client_request_id !== fields.clientRequestId || row.claim_request_hash !== requestHash) {
      throw new ApiError(409, "recovery_already_claimed", "This recovery was already claimed.");
    }
    return jsonResponse(claimResponse(row), 201);
  }
  if (row.recovery_state !== "open" || row.recovery_proof_public_key === null || row.current_membership_revision !== row.expected_membership_revision || row.current_key_epoch !== row.expected_key_epoch) {
    throw new ApiError(410, "recovery_unavailable", "This device recovery is unavailable.");
  }
  const transcript = deviceRecoveryClaimTranscript(fields);
  if (!await safelyVerify2(row.recovery_proof_public_key, recoveryProofSignature, transcript) || !await safelyVerify2(fields.signingPublicKey, deviceSignature, transcript)) {
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
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
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
      nowSeconds2()
    ).run();
  } catch {
    row = await loadRecovery(env, recoveryID);
    if (row !== null && row.claim_client_request_id === fields.clientRequestId && row.claim_request_hash === requestHash) return jsonResponse(claimResponse(row), 201);
    throw new ApiError(409, "recovery_already_claimed", "This recovery cannot be claimed.");
  }
  row = await loadRecovery(env, recoveryID);
  if (row === null) throw new ApiError(409, "recovery_conflict", "The recovery claim was not retained.");
  return jsonResponse(claimResponse(row), 201);
}
__name(claimDeviceRecovery, "claimDeviceRecovery");
async function getPendingDeviceRecoveries(request, env) {
  const { body, member } = await signedMemberRequest2(request, env);
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
      ORDER BY created_at ASC`
  ).bind(member.id, member.spaceId).all();
  const rows = await Promise.all(ids.results.map((entry) => loadRecovery(env, entry.id)));
  await consumeNonceAndTouch(env, member);
  return jsonResponse({
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    spaceId: member.spaceId,
    pending: rows.filter((row) => row !== null).map(statusResponse)
  });
}
__name(getPendingDeviceRecoveries, "getPendingDeviceRecoveries");
async function approveDeviceRecovery(request, env, recoveryIDValue) {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const { body, member } = await signedMemberRequest2(request, env);
  let object;
  let clientRequestID;
  let transcriptHash;
  let envelopeAlgorithm;
  let keyEnvelope;
  let approvalSignature;
  try {
    object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion",
      "clientRequestId",
      "transcriptHash",
      "envelopeAlgorithm",
      "keyEnvelope",
      "approvalSignature"
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
    requestHash
  );
  if (replay !== null) {
    await consumeNonceAndTouch(env, member);
    return replay;
  }
  await expireDeviceRecoveries(env, member.now, { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  if (row === null || row.initiator_member_id !== member.id || row.recovery_state !== "claimed" || row.claim_transcript_hash !== transcriptHash || row.proposed_device_id === null || row.current_membership_revision !== row.expected_membership_revision || row.current_key_epoch !== row.expected_key_epoch) {
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
    keyEnvelope
  });
  if (!await safelyVerify2(member.signingPublicKey, approvalSignature, signatureTranscript)) {
    await consumeNonce(env, member);
    throw new ApiError(401, "invalid_approval_signature", "The recovery approval signature is invalid.");
  }
  const responseBody2 = {
    protocolVersion: DEVICE_RECOVERY_PROTOCOL_VERSION,
    recoveryId: recoveryID,
    targetMemberId: row.target_member_id,
    deviceId: row.proposed_device_id,
    membershipRevision: row.expected_membership_revision,
    keyEpoch: row.expected_key_epoch,
    state: "approvedAwaitingCompletion",
    approvedAt: member.now
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO device_recovery_approval_events(
           recovery_id, approver_member_id, client_request_id, request_hash,
           transcript_hash, envelope_algorithm, key_envelope,
           approval_signature, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        recoveryID,
        member.id,
        clientRequestID,
        requestHash,
        transcriptHash,
        envelopeAlgorithm,
        keyEnvelope,
        approvalSignature,
        member.now
      ),
      idempotencyStatement(
        env,
        "approve-device-recovery",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await storedIdempotentResponse(
      env,
      "approve-device-recovery",
      member.id,
      clientRequestID,
      requestHash
    );
    if (raced !== null) {
      await consumeNonceAndTouch(env, member);
      return raced;
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "invalid_recovery_state", "The recovery cannot be approved.");
  }
  return jsonResponse(responseBody2);
}
__name(approveDeviceRecovery, "approveDeviceRecovery");
function recoveryNonceStatements(env, recoveryID, nonce, now) {
  return [
    env.DB.prepare(
      "DELETE FROM device_recovery_request_nonces WHERE recovery_id = ? AND expires_at < ?"
    ).bind(recoveryID, now),
    env.DB.prepare(
      `INSERT INTO device_recovery_request_nonces(
         recovery_id, nonce, created_at, expires_at
       ) VALUES (?, ?, ?, ?)`
    ).bind(recoveryID, nonce, now, now + 601)
  ];
}
__name(recoveryNonceStatements, "recoveryNonceStatements");
async function consumeRecoveryNonce(env, authentication) {
  try {
    await env.DB.batch(recoveryNonceStatements(
      env,
      authentication.recovery.recovery_id,
      authentication.nonce,
      authentication.now
    ));
  } catch {
    throw new ApiError(409, "replayed_request", "This recovery request nonce was already used.");
  }
}
__name(consumeRecoveryNonce, "consumeRecoveryNonce");
async function authenticateRecoveryRequest(request, env, recoveryID) {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "device-recovery-client")
  );
  const body = await readBody(request, 16 * 1024);
  if (request.headers.get("neko-protocol-version") !== "2" || request.headers.get("neko-member-id") !== recoveryID) {
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
  const now = nowSeconds2();
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
    bodySHA256: await sha256Base64url(body)
  });
  if (!await safelyVerify2(recovery.proposed_signing_public_key, signature, transcript)) {
    throw new ApiError(401, "invalid_authentication", "Recovery request authentication failed.");
  }
  return { body, recovery, nonce, now };
}
__name(authenticateRecoveryRequest, "authenticateRecoveryRequest");
async function getDeviceRecoveryStatus(request, env, recoveryIDValue) {
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
__name(getDeviceRecoveryStatus, "getDeviceRecoveryStatus");
async function getSponsorDeviceRecoveryStatus(request, env, recoveryIDValue) {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const { body, member } = await signedMemberRequest2(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  await expireDeviceRecoveries(env, member.now, { recoveryID });
  const row = await loadRecovery(env, recoveryID);
  if (row === null || row.space_id !== member.spaceId || row.initiator_member_id !== member.id || row.proposed_device_id === null) {
    await consumeNonce(env, member);
    throw new ApiError(404, "not_found", "device recovery was not found.");
  }
  await consumeNonceAndTouch(env, member);
  return jsonResponse(statusResponse(row));
}
__name(getSponsorDeviceRecoveryStatus, "getSponsorDeviceRecoveryStatus");
async function completeDeviceRecovery(request, env, recoveryIDValue) {
  const recoveryID = opaqueId(recoveryIDValue, "device recovery");
  const authentication = await authenticateRecoveryRequest(request, env, recoveryID);
  let object;
  let clientRequestID;
  let transcriptHash;
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
    if (row.completion_client_request_id !== clientRequestID || row.completion_request_hash !== requestHash || row.completion_transcript_hash !== transcriptHash) {
      throw new ApiError(409, "idempotency_conflict", "The completion key was used with another request.");
    }
    return jsonResponse(statusResponse(row));
  }
  if (row.recovery_state !== "approved" || row.claim_transcript_hash !== transcriptHash || row.current_membership_revision !== row.expected_membership_revision || row.current_key_epoch !== row.expected_key_epoch) {
    await consumeRecoveryNonce(env, authentication);
    throw new ApiError(409, "invalid_recovery_state", "The recovery cannot be completed.");
  }
  try {
    await env.DB.batch([
      ...recoveryNonceStatements(env, recoveryID, authentication.nonce, authentication.now),
      env.DB.prepare(
        `INSERT INTO device_recovery_completion_events(
           recovery_id, client_request_id, request_hash, transcript_hash, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        recoveryID,
        clientRequestID,
        requestHash,
        transcriptHash,
        authentication.now
      ),
      env.DB.prepare(
        `UPDATE spaces SET last_activity_at = ?, metadata_expires_at = MAX(metadata_expires_at, ?)
          WHERE id = ? AND state = 'active'`
      ).bind(
        authentication.now,
        authentication.now + 2592e3,
        row.space_id
      )
    ]);
  } catch {
    row = await loadRecovery(env, recoveryID);
    if (row !== null && row.completion_client_request_id === clientRequestID && row.completion_request_hash === requestHash && row.completion_transcript_hash === transcriptHash) {
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
__name(completeDeviceRecovery, "completeDeviceRecovery");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/family-records.ts
var FAMILY_RECORD_MAXIMUM_PHOTOS = 100;
var FAMILY_RECORD_MAXIMUM_WORDS = 1e3;
var FAMILY_RECORD_MAXIMUM_PHOTO_BYTES = 2 * 1024 * 1024;
var maximumWordsBytes = 32 * 1024;
var uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
async function momentSharedPhotoID(spaceID, momentID) {
  const bytes = (await sha256(encodeCanonicalFields(["NW.FAMILY-RECORD.MOMENT.1", spaceID, momentID]))).slice(0, 16);
  bytes[6] = (bytes[6] ?? 0) & 15 | 64;
  bytes[8] = (bytes[8] ?? 0) & 63 | 128;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
__name(momentSharedPhotoID, "momentSharedPhotoID");
async function parseMomentSharedRecord(value, spaceID, momentID) {
  const object = asObject(value);
  const hasWords = Object.hasOwn(object, "wordsID") || Object.hasOwn(object, "wordsCiphertext");
  exactKeys(object, hasWords ? ["photoID", "photoCiphertext", "wordsID", "wordsCiphertext"] : ["photoID", "photoCiphertext"]);
  const photoID = uuidField(object, "photoID");
  if (photoID !== await momentSharedPhotoID(spaceID, momentID)) {
    throw new ApiError(400, "family_record_photo_id_mismatch", "Shared photo does not match this moment.");
  }
  const photoCiphertext = stringField(object, "photoCiphertext");
  const photoBytes = base64urlDecode(photoCiphertext);
  if (photoBytes.length < 29 || photoBytes.length > FAMILY_RECORD_MAXIMUM_PHOTO_BYTES) {
    throw new ApiError(413, "family_record_too_large", "Photo record exceeds the size limit.");
  }
  const wordsID = hasWords ? uuidField(object, "wordsID") : null;
  if (wordsID !== null && wordsID !== await momentSharedPhotoID(spaceID, `memo-${photoID}`)) {
    throw new ApiError(400, "family_record_words_id_mismatch", "Shared memo does not match this photo.");
  }
  const wordsCiphertext = hasWords ? stringField(object, "wordsCiphertext") : null;
  const wordsSize = wordsCiphertext === null ? 0 : base64urlDecode(wordsCiphertext).length;
  if (hasWords && (wordsSize < 29 || wordsSize > maximumWordsBytes)) {
    throw new ApiError(413, "family_record_too_large", "Memo record exceeds the size limit.");
  }
  return { photoID, photoCiphertext, photoBytes, wordsID, wordsCiphertext, wordsSize };
}
__name(parseMomentSharedRecord, "parseMomentSharedRecord");
var authorized = `EXISTS (
 SELECT 1 FROM members m JOIN spaces s ON s.id=m.space_id
 JOIN moment_participants p ON p.legacy_member_id=m.id AND p.space_id=s.id
 JOIN moment_devices d ON d.participant_id=p.id
 JOIN moment_spaces ms ON ms.space_id=s.id
 WHERE m.id=? AND s.id=? AND d.id=? AND m.state='active' AND s.state='active'
 AND p.state='active' AND d.state='active' AND ms.state='active' AND ms.current_key_epoch=1
 AND NOT EXISTS (SELECT 1 FROM moment_blocks b WHERE b.space_id=s.id AND b.state='active'))`;
function authBindings(m) {
  return [m.id, m.spaceId, m.deviceId];
}
__name(authBindings, "authBindings");
async function assertAuthorized(env, m) {
  requireLiveSpace(m);
  if (m.state !== "active" || await env.DB.prepare(`SELECT 1 AS ok WHERE ${authorized}`).bind(...authBindings(m)).first() === null) {
    throw new ApiError(410, "family_record_access_revoked", "This record is not accessible.");
  }
}
__name(assertAuthorized, "assertAuthorized");
function presentation(row) {
  return {
    id: row.id,
    entryID: row.entry_id,
    kind: row.kind,
    authorID: row.author_member_id,
    revision: row.revision,
    state: row.state,
    keyEpoch: row.key_epoch,
    ciphertext: row.ciphertext,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}
__name(presentation, "presentation");
var visibleEntry = /* @__PURE__ */ __name((space, entry) => `(
  NOT EXISTS (SELECT 1 FROM family_record_moments link
    WHERE link.space_id=${space} AND link.photo_id=${entry})
  OR EXISTS (SELECT 1 FROM family_record_moment_readers reader
    WHERE reader.space_id=${space} AND reader.photo_id=${entry}
      AND reader.participant_id=?)
)`, "visibleEntry");
async function current(env, m, id) {
  return env.DB.prepare(`SELECT record.* FROM family_records record
    WHERE record.space_id=? AND record.id=?
      AND ${visibleEntry("record.space_id", "record.entry_id")}`).bind(m.spaceId, id, m.momentParticipantId).first();
}
__name(current, "current");
async function momentSharedRecordCapacityReached(env, spaceID, withWords) {
  const photoCount = await env.DB.prepare("SELECT COUNT(*) AS count FROM family_records WHERE space_id=? AND kind='photo'").bind(spaceID).first();
  const wordsCount = withWords ? await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM family_records WHERE space_id=? AND kind='words'"
  ).bind(spaceID).first() : null;
  return photoCount !== null && photoCount.count >= FAMILY_RECORD_MAXIMUM_PHOTOS || withWords && wordsCount !== null && wordsCount.count >= FAMILY_RECORD_MAXIMUM_WORDS;
}
__name(momentSharedRecordCapacityReached, "momentSharedRecordCapacityReached");
async function prepareMomentSharedRecordCommit(env, m, record, clientRequestID, requestHash) {
  if (env.FAMILY_RECORD_RUNTIME_ENABLED !== "YES") {
    throw new ApiError(503, "family_record_runtime_disabled", "Shared records are unavailable.");
  }
  await assertAuthorized(env, m);
  if (await current(env, m, record.photoID) !== null) {
    throw new ApiError(409, "family_record_conflict", "This photo record already exists.");
  }
  if (await momentSharedRecordCapacityReached(env, m.spaceId, record.wordsID !== null)) {
    throw new ApiError(409, "family_record_capacity", "Shared record capacity reached; nothing was sent.");
  }
  if (!env.MEDIA) throw new ApiError(503, "family_record_storage_unavailable", "Record storage unavailable.");
  const objectKey2 = `family-records/v1/${m.spaceId}/${record.photoID}/${crypto.randomUUID()}`;
  await env.DB.prepare(`INSERT INTO family_record_staged_objects(object_key,space_id,photo_id,created_at)
    VALUES (?,?,?,?)`).bind(objectKey2, m.spaceId, record.photoID, m.now).run();
  await env.MEDIA.put(objectKey2, record.photoBytes);
  const guard = authorized;
  const guardBindings = authBindings(m);
  const photo = env.DB.prepare(`INSERT INTO family_records VALUES (
      ?,?,?,'photo',?,1,'active',1,NULL,?, ?,
      CASE WHEN (SELECT COUNT(*) FROM family_records WHERE space_id=? AND kind='photo') < ?
        AND ${guard} THEN ? ELSE NULL END,
      ?,?,?)`).bind(
    m.spaceId,
    record.photoID,
    record.photoID,
    m.id,
    objectKey2,
    record.photoBytes.length,
    m.spaceId,
    FAMILY_RECORD_MAXIMUM_PHOTOS,
    ...guardBindings,
    requestHash,
    clientRequestID,
    m.now,
    m.now
  );
  const statements = [photo];
  if (record.wordsID !== null && record.wordsCiphertext !== null) {
    statements.push(env.DB.prepare(`INSERT INTO family_records VALUES (
        ?,?,?,'words',?,1,'active',1,?,NULL,?,
        CASE WHEN (SELECT COUNT(*) FROM family_records WHERE space_id=? AND kind='words') < ?
          AND ${guard} THEN ? ELSE NULL END,
        ?,?,?)`).bind(
      m.spaceId,
      record.wordsID,
      record.photoID,
      m.id,
      record.wordsCiphertext,
      record.wordsSize,
      m.spaceId,
      FAMILY_RECORD_MAXIMUM_WORDS,
      ...guardBindings,
      requestHash,
      clientRequestID,
      m.now,
      m.now
    ));
  }
  statements.push(env.DB.prepare("DELETE FROM family_record_staged_objects WHERE object_key=?").bind(objectKey2));
  return { statements };
}
__name(prepareMomentSharedRecordCommit, "prepareMomentSharedRecordCommit");
async function familyRecords(request, env, id, photo = false) {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "family-record"));
  const body = await readBody(request, 3 * 1024 * 1024);
  const m = await authenticateSignedRequest(request, env, body);
  await assertAuthorized(env, m);
  if (id === "capabilities" && request.method === "GET" && !photo) {
    requireEmptyBody(body);
    await consumeNonceAndTouch(env, m);
    return jsonResponse({ schemaVersion: 1 });
  }
  if (id !== void 0 && !uuid.test(id)) throw new ApiError(404, "not_found", "Record not found.");
  if (request.method === "GET") {
    requireEmptyBody(body);
    if (id === void 0) {
      const rows = await env.DB.prepare(`SELECT record.* FROM family_records record
        WHERE record.space_id=? AND ${visibleEntry("record.space_id", "record.entry_id")}
        ORDER BY record.created_at DESC,record.id`).bind(m.spaceId, m.momentParticipantId).all();
      await assertAuthorized(env, m);
      await consumeNonceAndTouch(env, m);
      return jsonResponse({
        schemaVersion: 1,
        spaceID: m.spaceId,
        participantID: m.id,
        maximumPhotos: FAMILY_RECORD_MAXIMUM_PHOTOS,
        records: rows.results.map(presentation)
      });
    }
    const row2 = await current(env, m, id);
    if (!photo || row2?.kind !== "photo" || row2.state !== "active" || !row2.object_key || !env.MEDIA) {
      throw new ApiError(404, "not_found", "Photo not found.");
    }
    const object = await env.MEDIA.get(row2.object_key);
    if (object === null) throw new ApiError(404, "family_record_photo_missing", "Photo unavailable.");
    const latest = await current(env, m, id);
    await assertAuthorized(env, m);
    if (latest?.object_key !== row2.object_key || latest.state !== "active") {
      throw new ApiError(410, "family_record_withdrawn", "Photo withdrawn.");
    }
    await consumeNonceAndTouch(env, m);
    return new Response(object.body, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store" } });
  }
  if (request.method !== "PUT" || id === void 0 || photo) throw new ApiError(405, "method_not_allowed", "Unsupported operation.");
  const value = parseJsonBody(request, body);
  exactKeys(value, ["entryID", "kind", "expectedRevision", "operationID", "ciphertext"]);
  const entryID = uuidField(value, "entryID");
  const operationID = uuidField(value, "operationID");
  const kind = stringField(value, "kind");
  if (kind !== "photo" && kind !== "words") throw new ApiError(400, "invalid_kind", "Unsupported record.");
  const expected = integerField(value, "expectedRevision", 0, 1e6);
  const withdrawing = value.ciphertext === null;
  const encoded = withdrawing ? null : stringField(value, "ciphertext");
  const bytes = encoded === null ? null : base64urlDecode(encoded);
  if (bytes !== null && (bytes.length < 29 || bytes.length > (kind === "photo" ? FAMILY_RECORD_MAXIMUM_PHOTO_BYTES : maximumWordsBytes))) {
    throw new ApiError(413, "family_record_too_large", "Record exceeds the size limit.");
  }
  const payloadHash = await sha256Base64url(body);
  const prior = await current(env, m, id);
  if (prior?.last_operation_id === operationID) {
    if (prior.payload_hash !== payloadHash || prior.author_member_id !== m.id) throw new ApiError(409, "family_record_conflict", "Operation differs.");
    await consumeNonceAndTouch(env, m);
    return jsonResponse({ record: presentation(prior) });
  }
  if (prior ? prior.author_member_id !== m.id || prior.revision !== expected || prior.state !== "active" || prior.kind !== kind || prior.entry_id !== entryID || kind === "photo" && !withdrawing : expected !== 0 || withdrawing || kind === "photo" && entryID !== id) {
    throw new ApiError(409, "family_record_conflict", "Record changed or is not yours.");
  }
  if (kind === "words") {
    const entry = await current(env, m, entryID);
    if (entry?.kind !== "photo") throw new ApiError(404, "not_found", "Record not found.");
  }
  if (prior === null) {
    const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM family_records WHERE space_id=? AND kind=?").bind(m.spaceId, kind).first();
    if (!count || count.count >= (kind === "photo" ? FAMILY_RECORD_MAXIMUM_PHOTOS : FAMILY_RECORD_MAXIMUM_WORDS)) {
      throw new ApiError(409, "family_record_capacity", "Record capacity reached. Existing records are retained.");
    }
  }
  if (!env.MEDIA) throw new ApiError(503, "family_record_storage_unavailable", "Record storage unavailable.");
  const objectKey2 = kind === "photo" && bytes !== null ? `family-records/v1/${m.spaceId}/${id}/${crypto.randomUUID()}` : null;
  if (objectKey2 !== null && bytes !== null) await env.MEDIA.put(objectKey2, bytes);
  const row = {
    space_id: m.spaceId,
    id,
    entry_id: entryID,
    kind,
    author_member_id: m.id,
    revision: expected + 1,
    state: withdrawing ? "withdrawn" : "active",
    key_epoch: 1,
    ciphertext: kind === "words" ? encoded : null,
    object_key: objectKey2,
    ciphertext_size: bytes?.length ?? 0,
    payload_hash: payloadHash,
    last_operation_id: operationID,
    created_at: prior?.created_at ?? m.now,
    updated_at: m.now
  };
  let committed = false;
  try {
    const mutation = prior === null ? env.DB.prepare(`INSERT INTO family_records SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
          WHERE ${authorized} AND (SELECT COUNT(*) FROM family_records WHERE space_id=? AND kind=?) < ?
            AND ${visibleEntry("?", "?")}
          ON CONFLICT(space_id,id) DO NOTHING`).bind(
      ...Object.values(row),
      ...authBindings(m),
      m.spaceId,
      kind,
      kind === "photo" ? FAMILY_RECORD_MAXIMUM_PHOTOS : FAMILY_RECORD_MAXIMUM_WORDS,
      m.spaceId,
      entryID,
      m.spaceId,
      entryID,
      m.momentParticipantId
    ) : env.DB.prepare(`UPDATE family_records SET revision=?,state=?,ciphertext=?,object_key=?,ciphertext_size=?,
          payload_hash=?,last_operation_id=?,updated_at=? WHERE space_id=? AND id=? AND revision=?
          AND author_member_id=? AND state='active' AND ${authorized}
          AND ${visibleEntry("?", "?")}`).bind(
      row.revision,
      row.state,
      row.ciphertext,
      row.object_key,
      row.ciphertext_size,
      row.payload_hash,
      row.last_operation_id,
      row.updated_at,
      m.spaceId,
      id,
      expected,
      m.id,
      ...authBindings(m),
      m.spaceId,
      entryID,
      m.spaceId,
      entryID,
      m.momentParticipantId
    );
    const deletion = prior?.object_key ? [env.DB.prepare(
      `INSERT OR IGNORE INTO family_record_object_deletions SELECT ?,?
       WHERE EXISTS (SELECT 1 FROM family_records WHERE space_id=? AND id=?
         AND state='withdrawn' AND last_operation_id=?)`
    ).bind(prior.object_key, m.now, m.spaceId, id, operationID)] : [];
    const linkedRevocation = kind === "photo" && withdrawing ? [
      // The current photo mutation is the authority. Existing old/random-ID
      // records have no mapping and do not affect any delivery.
      env.DB.prepare(`INSERT INTO moment_changes(cursor,participant_id,change_type,moment_id,created_at)
        SELECT lower(hex(randomblob(16))),delivery.recipient_participant_id,
               'delivery_revoked',delivery.moment_id,?
          FROM family_record_moments AS link
          JOIN family_records AS record ON record.space_id=link.space_id AND record.id=link.photo_id
          JOIN moment_deliveries AS delivery ON delivery.moment_id=link.moment_id
         WHERE link.space_id=? AND link.photo_id=? AND record.state='withdrawn'
           AND record.last_operation_id=? AND delivery.state IN ('pending','acknowledged')`).bind(m.now, m.spaceId, id, operationID),
      env.DB.prepare(`UPDATE moment_deliveries SET state='revoked',revoked_at=?
        WHERE moment_id=(SELECT link.moment_id FROM family_record_moments AS link
          JOIN family_records AS record ON record.space_id=link.space_id AND record.id=link.photo_id
          WHERE link.space_id=? AND link.photo_id=? AND record.state='withdrawn'
            AND record.last_operation_id=?) AND state IN ('pending','acknowledged')`).bind(m.now, m.spaceId, id, operationID)
    ] : [];
    const result = await env.DB.batch([
      ...nonceStatements(env, m),
      mutation,
      ...linkedRevocation,
      ...deletion,
      activityStatement(env, m)
    ]);
    committed = result[2]?.meta.changes === 1;
    const saved = await current(env, m, id);
    await assertAuthorized(env, m);
    if (!committed && !(saved?.last_operation_id === operationID && saved.payload_hash === payloadHash)) {
      throw new ApiError(409, "family_record_conflict_or_capacity", "Record changed or storage capacity was reached.");
    }
    if (!saved) throw new ApiError(503, "family_record_unavailable", "Record temporarily unavailable.");
    return jsonResponse({ record: presentation(saved) });
  } finally {
    if (!committed && objectKey2 !== null) {
      try {
        const saved = await current(env, m, id);
        if (saved?.object_key !== objectKey2) await env.MEDIA.delete(objectKey2);
      } catch {
      }
    }
  }
}
__name(familyRecords, "familyRecords");
async function runFamilyRecordCleanup(env, now = Math.floor(Date.now() / 1e3)) {
  if (!env.MEDIA) return;
  const rows = await env.DB.prepare("SELECT object_key FROM family_record_object_deletions ORDER BY created_at LIMIT 20").all();
  for (const row of rows.results) {
    if (!row.object_key.startsWith("family-records/v1/")) throw new Error("Invalid family record deletion scope");
    await env.MEDIA.delete(row.object_key);
    await env.DB.prepare("DELETE FROM family_record_object_deletions WHERE object_key=?").bind(row.object_key).run();
  }
  const staged = await env.DB.prepare(`SELECT object_key,space_id,photo_id
    FROM family_record_staged_objects WHERE created_at <= ? ORDER BY created_at LIMIT 20`).bind(now - 3 * 24 * 60 * 60).all();
  for (const row of staged.results) {
    if (!row.object_key.startsWith(`family-records/v1/${row.space_id}/${row.photo_id}/`)) {
      throw new Error("Invalid staged family record deletion scope");
    }
    const current2 = await env.DB.prepare("SELECT object_key FROM family_records WHERE space_id=? AND id=?").bind(row.space_id, row.photo_id).first();
    if (current2?.object_key !== row.object_key) await env.MEDIA.delete(row.object_key);
    await env.DB.prepare("DELETE FROM family_record_staged_objects WHERE object_key=?").bind(row.object_key).run();
  }
}
__name(runFamilyRecordCleanup, "runFamilyRecordCleanup");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/push.ts
var APNS_PROTOCOL_VERSION = 2;
var APNS_ADDITIVE_PROTOCOL_VERSION = 3;
var APNS_DRAIN_CRON = "* * * * *";
var APNS_SUBSCRIPTION_TTL_SECONDS = 35 * 86400;
var APNS_EVENT_TTL_SECONDS = 24 * 60 * 60;
var APNS_DRAIN_LIMIT = 50;
var APNS_LEASE_SECONDS = 90;
var maximumAPNsResponseBytes = 1024;
var providerTokenCache = /* @__PURE__ */ new Map();
function buffer(bytes) {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}
__name(buffer, "buffer");
function strictObject(value, expected, label) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error(`${label} must be a JSON object.`);
  }
  const object = value;
  const actual = Object.keys(object).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} has missing or unknown fields.`);
  }
  return object;
}
__name(strictObject, "strictObject");
function secretString(object, key) {
  const value = object[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${key} must be a non-empty string.`);
  }
  return value;
}
__name(secretString, "secretString");
function parseProviderCredential(env) {
  if (env.APNS_PROVIDER_CREDENTIAL_JSON === void 0) {
    throw new Error("APNs provider credential is unavailable.");
  }
  let decoded;
  try {
    decoded = JSON.parse(env.APNS_PROVIDER_CREDENTIAL_JSON);
  } catch {
    throw new Error("APNs provider credential is not valid JSON.");
  }
  const object = strictObject(
    decoded,
    ["bundleId", "environment", "keyId", "privateKey", "teamId"],
    "APNs provider credential"
  );
  const keyId = secretString(object, "keyId");
  const teamId = secretString(object, "teamId");
  const bundleId = secretString(object, "bundleId");
  const privateKey = secretString(object, "privateKey");
  const environment = secretString(object, "environment");
  if (!/^[A-Z0-9]{10}$/u.test(keyId) || !/^[A-Z0-9]{10}$/u.test(teamId)) {
    throw new Error("APNs keyId and teamId must use Apple's ten-character format.");
  }
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(bundleId)) {
    throw new Error("APNs bundleId is invalid.");
  }
  if (environment !== "development" && environment !== "production") {
    throw new Error("APNs environment must be development or production.");
  }
  if (!privateKey.startsWith("-----BEGIN PRIVATE KEY-----") || !privateKey.trimEnd().endsWith("-----END PRIVATE KEY-----")) {
    throw new Error("APNs privateKey must be a PKCS#8 PEM private key.");
  }
  return { keyId, teamId, bundleId, environment, privateKey };
}
__name(parseProviderCredential, "parseProviderCredential");
function parseTokenKeyring(env) {
  if (env.APNS_TOKEN_KEYRING_JSON === void 0) {
    throw new Error("APNs token keyring is unavailable.");
  }
  let decoded;
  try {
    decoded = JSON.parse(env.APNS_TOKEN_KEYRING_JSON);
  } catch {
    throw new Error("APNs token keyring is not valid JSON.");
  }
  const object = strictObject(decoded, ["current", "keys"], "APNs token keyring");
  const current2 = secretString(object, "current");
  if (!/^[A-Za-z0-9_-]{1,32}$/u.test(current2)) {
    throw new Error("APNs current encryption key ID is invalid.");
  }
  const keyObject = object.keys;
  if (keyObject === null || Array.isArray(keyObject) || typeof keyObject !== "object") {
    throw new Error("APNs token keyring keys must be an object.");
  }
  const entries = Object.entries(keyObject);
  if (entries.length < 1 || entries.length > 4) {
    throw new Error("APNs token keyring must contain one through four keys.");
  }
  const keys = /* @__PURE__ */ new Map();
  for (const [id, value] of entries) {
    if (!/^[A-Za-z0-9_-]{1,32}$/u.test(id) || typeof value !== "string") {
      throw new Error("APNs token keyring contains an invalid entry.");
    }
    let bytes;
    try {
      bytes = base64urlDecode(value, 32);
    } catch {
      throw new Error("APNs token keyring keys must be canonical 32-byte base64url values.");
    }
    keys.set(id, bytes);
  }
  if (!keys.has(current2)) {
    throw new Error("APNs current encryption key is missing from the keyring.");
  }
  return { current: current2, keys };
}
__name(parseTokenKeyring, "parseTokenKeyring");
function tokenAAD(deviceID, environment, bundleID, keyID) {
  return new TextEncoder().encode(
    `NW2.APNS-TOKEN\0${deviceID}\0${environment}\0${bundleID}\0${keyID}`
  );
}
__name(tokenAAD, "tokenAAD");
async function importAESKey(bytes) {
  return crypto.subtle.importKey("raw", buffer(bytes), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}
__name(importAESKey, "importAESKey");
async function encryptDeviceToken(token, deviceID, credential, keyring) {
  const keyBytes = keyring.keys.get(keyring.current);
  if (keyBytes === void 0) throw new Error("APNs current encryption key is unavailable.");
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: buffer(nonce),
      additionalData: buffer(tokenAAD(
        deviceID,
        credential.environment,
        credential.bundleId,
        keyring.current
      ))
    },
    await importAESKey(keyBytes),
    buffer(token)
  );
  return {
    ciphertext: base64urlEncode(new Uint8Array(ciphertext)),
    nonce: base64urlEncode(nonce),
    digest: await sha256Base64url(token),
    keyID: keyring.current
  };
}
__name(encryptDeviceToken, "encryptDeviceToken");
async function decryptDeviceToken(row, credential, keyring) {
  const keyBytes = keyring.keys.get(row.encryption_key_id);
  if (keyBytes === void 0) throw new Error("APNs token encryption key version is unavailable.");
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: buffer(base64urlDecode(row.token_nonce, 12)),
      additionalData: buffer(tokenAAD(
        row.device_id,
        row.environment,
        credential.bundleId,
        row.encryption_key_id
      ))
    },
    await importAESKey(keyBytes),
    buffer(base64urlDecode(row.token_ciphertext))
  );
  const token = new Uint8Array(plaintext);
  if (token.length < 16 || token.length > 256 || await sha256Base64url(token) !== row.token_digest) {
    throw new Error("APNs encrypted token integrity check failed.");
  }
  return token;
}
__name(decryptDeviceToken, "decryptDeviceToken");
function parseRegistrationBody(object, protocolVersion4) {
  exactKeys(object, ["environment", "protocolVersion", "token"]);
  if (object.protocolVersion !== protocolVersion4) {
    throw new ApiError(
      400,
      "unsupported_protocol",
      `protocolVersion must be ${protocolVersion4}.`
    );
  }
  const environment = stringField(object, "environment");
  if (environment !== "development" && environment !== "production") {
    throw new ApiError(400, "invalid_field", "environment must be development or production.");
  }
  let token;
  try {
    token = base64urlDecode(stringField(object, "token"));
  } catch {
    throw new ApiError(400, "invalid_field", "token must be canonical base64url.");
  }
  if (token.length < 16 || token.length > 256) {
    throw new ApiError(400, "invalid_field", "token has an invalid decoded length.");
  }
  return { token, environment };
}
__name(parseRegistrationBody, "parseRegistrationBody");
function parseDeleteBody(object, protocolVersion4) {
  exactKeys(object, ["protocolVersion"]);
  if (object.protocolVersion !== protocolVersion4) {
    throw new ApiError(
      400,
      "unsupported_protocol",
      `protocolVersion must be ${protocolVersion4}.`
    );
  }
}
__name(parseDeleteBody, "parseDeleteBody");
async function signedActiveRequest(request, env) {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "push-subscription"));
  const body = await readBody(request, 4 * 1024);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(403, "active_member_required", "Pairing must be complete before notifications can be enabled.");
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}
__name(signedActiveRequest, "signedActiveRequest");
async function putPushSubscription(request, env, protocolVersion4, registrationMode) {
  const { body, member } = await signedActiveRequest(request, env);
  if (!apnsRuntimeEnabled(env) || !apnsGateOpen(await loadRuntimeGate(env))) {
    await consumeNonce(env, member);
    throw new ApiError(503, "apns_runtime_disabled", "Notifications are temporarily unavailable.");
  }
  let parsed;
  let encrypted;
  let credential;
  try {
    parsed = parseRegistrationBody(parseJsonBody(request, body), protocolVersion4);
    credential = parseProviderCredential(env);
    if (parsed.environment !== credential.environment) {
      throw new ApiError(409, "apns_environment_mismatch", "This build does not match the configured notification environment.");
    }
    encrypted = await encryptDeviceToken(
      parsed.token,
      member.deviceId,
      credential,
      parseTokenKeyring(env)
    );
  } catch (error) {
    await consumeNonce(env, member);
    if (error instanceof ApiError) throw error;
    throw new ApiError(503, "push_configuration_unavailable", "Notifications are temporarily unavailable.");
  }
  try {
    const statements = [...nonceStatements(env, member)];
    if (registrationMode === "exclusiveLegacy") {
      statements.push(
        // Possession of the plaintext APNs token proves this signed device is
        // the current destination for that physical app installation. Replace
        // every older window/device binding for the same one-way digest before
        // inserting the selected window. This keeps a failed client-side
        // DELETE from leaving generic pushes pointed at an inactive window.
        env.DB.prepare(
          `DELETE FROM notification_deliveries
            WHERE device_id <> ?
              AND device_id IN (
                SELECT device_id FROM apns_subscriptions
                 WHERE token_digest = ?
               )`
        ).bind(member.deviceId, encrypted.digest),
        // Replacing this physical token can remove the last delivery for an
        // old selected window. Do not retain an undeliverable event until its
        // TTL; scope cleanup before the subscription rows are deleted below.
        env.DB.prepare(
          `DELETE FROM notification_events
            WHERE participant_id IN (
                    SELECT participant_id
                      FROM apns_subscriptions
                     WHERE token_digest = ? AND device_id <> ?
                  )
              AND NOT EXISTS (
                SELECT 1
                  FROM notification_deliveries AS delivery
                 WHERE delivery.event_id = notification_events.id
              )`
        ).bind(encrypted.digest, member.deviceId),
        env.DB.prepare(
          `DELETE FROM apns_subscriptions
            WHERE token_digest = ? AND device_id <> ?`
        ).bind(encrypted.digest, member.deviceId)
      );
    } else {
      statements.push(
        // The first additive registration removes only legacy bindings for
        // this physical token. Their v1 route can wake an old client without
        // an exact window scope. Targeted v2-route bindings from later v3
        // calls coexist, one authenticated credential per private window.
        env.DB.prepare(
          `DELETE FROM notification_deliveries
            WHERE device_id <> ?
              AND device_id IN (
                SELECT device_id FROM apns_subscriptions
                 WHERE token_digest = ? AND route_schema_version = 1
              )`
        ).bind(member.deviceId, encrypted.digest),
        env.DB.prepare(
          `DELETE FROM notification_events
            WHERE participant_id IN (
                    SELECT participant_id
                      FROM apns_subscriptions
                     WHERE token_digest = ? AND device_id <> ?
                       AND route_schema_version = 1
                  )
              AND NOT EXISTS (
                SELECT 1
                  FROM notification_deliveries AS delivery
                 WHERE delivery.event_id = notification_events.id
              )`
        ).bind(encrypted.digest, member.deviceId),
        env.DB.prepare(
          `DELETE FROM apns_subscriptions
            WHERE token_digest = ? AND device_id <> ?
              AND route_schema_version = 1`
        ).bind(encrypted.digest, member.deviceId)
      );
    }
    const routeSchemaVersion = registrationMode === "exclusiveLegacy" ? 1 : 2;
    statements.push(
      env.DB.prepare(
        `INSERT INTO apns_subscriptions(
           device_id, participant_id, environment,
           token_ciphertext, token_nonce, token_digest, encryption_key_id,
           created_at, updated_at, expires_at, route_schema_version
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET
           participant_id = excluded.participant_id,
           environment = excluded.environment,
           token_ciphertext = excluded.token_ciphertext,
           token_nonce = excluded.token_nonce,
           token_digest = excluded.token_digest,
           encryption_key_id = excluded.encryption_key_id,
           updated_at = excluded.updated_at,
           expires_at = excluded.expires_at,
           route_schema_version = excluded.route_schema_version`
      ).bind(
        member.deviceId,
        member.momentParticipantId,
        credential.environment,
        encrypted.ciphertext,
        encrypted.nonce,
        encrypted.digest,
        encrypted.keyID,
        member.now,
        member.now,
        member.now + APNS_SUBSCRIPTION_TTL_SECONDS,
        routeSchemaVersion
      )
    );
    if (registrationMode === "additiveTargeted") {
      statements.push(
        env.DB.prepare(
          `UPDATE apns_subscriptions
              SET route_schema_version = 2
            WHERE device_id = ?`
        ).bind(member.deviceId)
      );
    }
    statements.push(activityStatement(env, member));
    await env.DB.batch(statements);
  } catch {
    await consumeNonce(env, member);
    throw new ApiError(409, "push_subscription_conflict", "The notification subscription could not be updated.");
  }
  return jsonResponse({
    protocolVersion: protocolVersion4,
    subscription: { state: "active" }
  });
}
__name(putPushSubscription, "putPushSubscription");
async function putCurrentPushSubscription(request, env) {
  return putPushSubscription(
    request,
    env,
    APNS_PROTOCOL_VERSION,
    "exclusiveLegacy"
  );
}
__name(putCurrentPushSubscription, "putCurrentPushSubscription");
async function putAdditivePushSubscription(request, env) {
  return putPushSubscription(
    request,
    env,
    APNS_ADDITIVE_PROTOCOL_VERSION,
    "additiveTargeted"
  );
}
__name(putAdditivePushSubscription, "putAdditivePushSubscription");
async function deletePushSubscription(request, env, protocolVersion4) {
  const { body, member } = await signedActiveRequest(request, env);
  try {
    parseDeleteBody(parseJsonBody(request, body), protocolVersion4);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      // Turning notifications off must discard every old attempt for this
      // physical signed device before its subscription disappears. Otherwise
      // re-registering the same token within the event TTL could resurrect a
      // pre-opt-out alert through the delivery/subscription join.
      env.DB.prepare(
        "DELETE FROM notification_deliveries WHERE device_id = ?"
      ).bind(member.deviceId),
      env.DB.prepare(
        `DELETE FROM notification_events
          WHERE participant_id = ?
            AND NOT EXISTS (
              SELECT 1
                FROM notification_deliveries AS delivery
               WHERE delivery.event_id = notification_events.id
            )`
      ).bind(member.momentParticipantId),
      env.DB.prepare("DELETE FROM apns_subscriptions WHERE device_id = ? AND participant_id = ?").bind(member.deviceId, member.momentParticipantId),
      activityStatement(env, member)
    ]);
  } catch {
    await consumeNonce(env, member);
    throw new ApiError(409, "push_subscription_conflict", "The notification subscription could not be removed.");
  }
  return jsonResponse({
    protocolVersion: protocolVersion4,
    subscription: { state: "deleted" }
  });
}
__name(deletePushSubscription, "deletePushSubscription");
async function deleteCurrentPushSubscription(request, env) {
  return deletePushSubscription(request, env, APNS_PROTOCOL_VERSION);
}
__name(deleteCurrentPushSubscription, "deleteCurrentPushSubscription");
async function deleteAdditivePushSubscription(request, env) {
  return deletePushSubscription(request, env, APNS_ADDITIVE_PROTOCOL_VERSION);
}
__name(deleteAdditivePushSubscription, "deleteAdditivePushSubscription");
function momentNotificationEventStatements(env, momentID, createdAt, gateEnabled) {
  if (!apnsRuntimeEnabled(env) || !gateEnabled) return [];
  return [env.DB.prepare(
    `INSERT INTO notification_events(
       id, kind, participant_id, moment_id, reaction_id, created_at, expires_at
     )
     SELECT lower(hex(randomblob(16))), 'new_moment',
            delivery.recipient_participant_id, delivery.moment_id,
            NULL, ?, ?
       FROM moment_deliveries AS delivery
      WHERE delivery.moment_id = ?
        AND delivery.state = 'pending'
     ON CONFLICT(kind, participant_id, moment_id) WHERE kind = 'new_moment'
     DO NOTHING`
  ).bind(createdAt, createdAt + APNS_EVENT_TTL_SECONDS, momentID)];
}
__name(momentNotificationEventStatements, "momentNotificationEventStatements");
function reactionNotificationEventStatements(env, reactionID, participantID, createdAt, gateEnabled) {
  if (!apnsRuntimeEnabled(env) || !gateEnabled) return [];
  return [env.DB.prepare(
    `INSERT INTO notification_events(
       id, kind, participant_id, moment_id, reaction_id, created_at, expires_at
     ) VALUES (?, 'heart', ?, NULL, ?, ?, ?)
     ON CONFLICT(kind, participant_id, reaction_id) WHERE kind = 'heart'
     DO NOTHING`
  ).bind(
    randomBase64url(16),
    participantID,
    reactionID,
    createdAt,
    createdAt + APNS_EVENT_TTL_SECONDS
  )];
}
__name(reactionNotificationEventStatements, "reactionNotificationEventStatements");
function pemPKCS8Bytes(value) {
  const base64 = value.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "").replace(/\s+/gu, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(base64)) {
    throw new Error("APNs private key PEM is malformed.");
  }
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}
__name(pemPKCS8Bytes, "pemPKCS8Bytes");
async function providerJWT(credential, now) {
  const cacheKey = `${credential.teamId}:${credential.keyId}`;
  const cached = providerTokenCache.get(cacheKey);
  if (cached !== void 0 && now - cached.issuedAt < 50 * 60) return cached.value;
  const header = base64urlEncode(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: credential.keyId })));
  const claims = base64urlEncode(new TextEncoder().encode(JSON.stringify({ iss: credential.teamId, iat: now })));
  const signingInput = `${header}.${claims}`;
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    buffer(pemPKCS8Bytes(credential.privateKey)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    buffer(new TextEncoder().encode(signingInput))
  ));
  if (signature.length !== 64) throw new Error("APNs provider signature has an invalid length.");
  const value = `${signingInput}.${base64urlEncode(signature)}`;
  providerTokenCache.set(cacheKey, { value, issuedAt: now });
  return value;
}
__name(providerJWT, "providerJWT");
function tokenHex(token) {
  return [...token].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
__name(tokenHex, "tokenHex");
function notificationPayload(row) {
  const body = row.kind === "new_moment" ? "\u65B0\u3057\u3044\u4E00\u679A\u304C\u5C4A\u304D\u307E\u3057\u305F\u3002" : "\u5C4A\u3051\u305F\u5199\u771F\u306B\u30CF\u30FC\u30C8\u304C\u5C4A\u304D\u307E\u3057\u305F\u3002";
  return JSON.stringify({
    aps: {
      alert: { title: "\u306D\u3053\u306E\u307E\u3069", body },
      "content-available": 1
    },
    neko: {
      // Additive bindings use a route schema that already-shipped clients
      // reject, so downgrading cannot interpret an inactive-window alert as
      // a generic wake for the selected window. v2 endpoint rows retain v1.
      v: row.route_schema_version,
      kind: row.kind
    },
    // Both route schemas keep the exact two-key `neko` shape. Only v2-aware
    // clients accept the targeted version; v1-only clients reject it before
    // reading the separately validated opaque IDs below.
    nekoTarget: {
      v: 1,
      spaceId: row.target_space_id,
      momentId: row.target_moment_id
    }
  });
}
__name(notificationPayload, "notificationPayload");
function collapseID(row) {
  return `${row.kind === "new_moment" ? "moment" : "heart"}-${row.event_id}`.slice(0, 64);
}
__name(collapseID, "collapseID");
async function boundedReason(response) {
  const text = (await response.text()).slice(0, maximumAPNsResponseBytes);
  try {
    const decoded = JSON.parse(text);
    return typeof decoded.reason === "string" && decoded.reason.length <= 64 ? decoded.reason : "Unknown";
  } catch {
    return "Unknown";
  }
}
__name(boundedReason, "boundedReason");
function retryDelaySeconds(attempts) {
  const base = Math.min(3600, 30 * 2 ** Math.min(attempts, 7));
  const random = crypto.getRandomValues(new Uint8Array(1))[0] ?? 0;
  return Math.floor(base * (0.75 + random / 512));
}
__name(retryDelaySeconds, "retryDelaySeconds");
function invalidDeviceResponse(status, reason) {
  return status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic" || reason === "Unregistered";
}
__name(invalidDeviceResponse, "invalidDeviceResponse");
function transientResponse(status, reason) {
  return status === 429 || status >= 500 || reason === "TooManyProviderTokenUpdates" || reason === "ExpiredProviderToken";
}
__name(transientResponse, "transientResponse");
async function markAccepted(env, row, leaseID, now) {
  const result = await env.DB.prepare(
    `UPDATE notification_deliveries
        SET state = 'accepted', attempts = attempts + 1,
            lease_id = NULL, lease_expires_at = NULL,
            last_status = 200, last_reason = NULL,
            accepted_at = ?, updated_at = ?
      WHERE event_id = ? AND device_id = ?
        AND token_digest = ?
        AND state = 'leased' AND lease_id = ?
        AND EXISTS (
          SELECT 1
            FROM apns_subscriptions AS subscription
           WHERE subscription.device_id = notification_deliveries.device_id
             AND subscription.token_digest = notification_deliveries.token_digest
             AND subscription.environment = ?
             AND subscription.route_schema_version = ?
        )`
  ).bind(
    now,
    now,
    row.event_id,
    row.device_id,
    row.token_digest,
    leaseID,
    row.environment,
    row.route_schema_version
  ).run();
  return result.meta.changes === 1;
}
__name(markAccepted, "markAccepted");
async function releaseAfterRouteChange(env, row, leaseID, now) {
  const result = await env.DB.prepare(
    `UPDATE notification_deliveries
        SET state = 'pending', attempts = attempts + 1,
            next_attempt_at = ?, lease_id = NULL, lease_expires_at = NULL,
            last_status = 200, last_reason = 'RouteChanged', updated_at = ?
      WHERE event_id = ? AND device_id = ?
        AND token_digest = ?
        AND state = 'leased' AND lease_id = ?
        AND EXISTS (
          SELECT 1
            FROM apns_subscriptions AS subscription
           WHERE subscription.device_id = notification_deliveries.device_id
             AND subscription.token_digest = notification_deliveries.token_digest
             AND subscription.environment = ?
             AND subscription.route_schema_version <> ?
        )`
  ).bind(
    now,
    now,
    row.event_id,
    row.device_id,
    row.token_digest,
    leaseID,
    row.environment,
    row.route_schema_version
  ).run();
  return result.meta.changes === 1;
}
__name(releaseAfterRouteChange, "releaseAfterRouteChange");
async function markRetry(env, row, leaseID, now, status, reason, configurationError) {
  const retryAt = Math.min(
    row.expires_at,
    now + (configurationError ? 3600 : retryDelaySeconds(row.attempts))
  );
  await env.DB.prepare(
    `UPDATE notification_deliveries
        SET state = 'pending', attempts = attempts + 1,
            next_attempt_at = ?, lease_id = NULL, lease_expires_at = NULL,
            last_status = ?, last_reason = ?, updated_at = ?
      WHERE event_id = ? AND device_id = ?
        AND state = 'leased' AND lease_id = ?`
  ).bind(
    retryAt,
    status,
    configurationError ? `configuration_error:${reason}` : reason,
    now,
    row.event_id,
    row.device_id,
    leaseID
  ).run();
}
__name(markRetry, "markRetry");
async function invalidateToken(env, row) {
  await env.DB.batch([
    env.DB.prepare(
      "DELETE FROM notification_deliveries WHERE token_digest = ?"
    ).bind(row.token_digest),
    env.DB.prepare(
      "DELETE FROM apns_subscriptions WHERE token_digest = ?"
    ).bind(row.token_digest)
  ]);
}
__name(invalidateToken, "invalidateToken");
async function drainNotificationOutbox(env, now = Math.floor(Date.now() / 1e3), fetchImpl = fetch, hooks = {}) {
  const summary = {
    leased: 0,
    accepted: 0,
    retried: 0,
    invalidated: 0,
    skipped: 0,
    configurationUnavailable: false
  };
  await env.DB.batch([
    env.DB.prepare("DELETE FROM apns_subscriptions WHERE expires_at <= ?").bind(now),
    env.DB.prepare("DELETE FROM notification_events WHERE expires_at <= ?").bind(now)
  ]);
  const runtimeGate = await loadRuntimeGate(env);
  if (!apnsRuntimeEnabled(env) || runtimeGate === null || !apnsGateOpen(runtimeGate)) {
    return summary;
  }
  let credential;
  let keyring;
  let authorization;
  try {
    credential = parseProviderCredential(env);
    keyring = parseTokenKeyring(env);
    authorization = await providerJWT(credential, now);
  } catch {
    summary.configurationUnavailable = true;
    return summary;
  }
  const candidates = await env.DB.prepare(
    `SELECT delivery.event_id, delivery.device_id, delivery.token_digest,
             delivery.state, delivery.attempts,
             event.kind, source_moment.space_id AS target_space_id,
             source_moment.id AS target_moment_id,
             event.created_at, event.expires_at,
             subscription.token_ciphertext, subscription.token_nonce,
             subscription.encryption_key_id, subscription.environment,
             subscription.route_schema_version
       FROM notification_deliveries AS delivery
       JOIN notification_events AS event ON event.id = delivery.event_id
       LEFT JOIN moment_reactions AS source_reaction
         ON source_reaction.id = event.reaction_id
       JOIN moments AS source_moment
         ON source_moment.id = COALESCE(event.moment_id, source_reaction.moment_id)
       JOIN apns_subscriptions AS subscription
         ON subscription.device_id = delivery.device_id
        AND subscription.token_digest = delivery.token_digest
      WHERE event.expires_at > ?
        AND subscription.expires_at > ?
        AND subscription.environment = ?
        AND (
          (delivery.state = 'pending' AND delivery.next_attempt_at <= ?)
          OR (delivery.state = 'leased' AND delivery.lease_expires_at <= ?)
        )
      ORDER BY delivery.next_attempt_at ASC, event.created_at ASC,
               delivery.event_id ASC, delivery.device_id ASC
      LIMIT ?`
  ).bind(
    now,
    now,
    credential.environment,
    now,
    now,
    APNS_DRAIN_LIMIT
  ).all();
  for (const row of candidates.results) {
    if (row.environment !== credential.environment) {
      summary.skipped += 1;
      continue;
    }
    const leaseID = randomBase64url(16);
    const leased = await env.DB.prepare(
      `UPDATE notification_deliveries
          SET state = 'leased', lease_id = ?, lease_expires_at = ?, updated_at = ?
        WHERE event_id = ? AND device_id = ?
          AND token_digest = ?
          AND (
            (state = 'pending' AND next_attempt_at <= ?)
            OR (state = 'leased' AND lease_expires_at <= ?)
          )`
    ).bind(
      leaseID,
      now + APNS_LEASE_SECONDS,
      now,
      row.event_id,
      row.device_id,
      row.token_digest,
      now,
      now
    ).run();
    if (leased.meta.changes !== 1) {
      summary.skipped += 1;
      continue;
    }
    summary.leased += 1;
    await hooks.afterLease?.({ eventID: row.event_id, deviceID: row.device_id });
    let token;
    try {
      token = await decryptDeviceToken(row, credential, keyring);
    } catch {
      await markRetry(env, row, leaseID, now, null, "TokenDecryptFailed", true);
      summary.retried += 1;
      continue;
    }
    const payload = notificationPayload(row);
    const stillCurrent = await env.DB.prepare(
      `SELECT 1 AS present
         FROM notification_deliveries AS delivery
         JOIN notification_events AS event ON event.id = delivery.event_id
         JOIN apns_subscriptions AS subscription
           ON subscription.device_id = delivery.device_id
          AND subscription.token_digest = delivery.token_digest
         JOIN personal_staging_runtime_gate AS runtime_gate
           ON runtime_gate.singleton = 1
        WHERE delivery.event_id = ? AND delivery.device_id = ?
          AND delivery.token_digest = ?
          AND delivery.state = 'leased' AND delivery.lease_id = ?
          AND event.expires_at > ?
          AND subscription.expires_at > ?
          AND subscription.environment = ?
          AND subscription.route_schema_version = ?
          AND runtime_gate.generation = ?
          AND runtime_gate.media_enabled = 1
          AND runtime_gate.apns_enabled = 1`
    ).bind(
      row.event_id,
      row.device_id,
      row.token_digest,
      leaseID,
      now,
      now,
      credential.environment,
      row.route_schema_version,
      runtimeGate.generation
    ).first();
    if (stillCurrent === null) {
      summary.skipped += 1;
      continue;
    }
    let response;
    try {
      response = await fetchImpl(
        `https://${credential.environment === "production" ? "api" : "api.sandbox"}.push.apple.com/3/device/${tokenHex(token)}`,
        {
          method: "POST",
          headers: {
            authorization: `bearer ${authorization}`,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-topic": credential.bundleId,
            "apns-expiration": String(row.expires_at),
            "apns-collapse-id": collapseID(row),
            "content-type": "application/json"
          },
          body: payload
        }
      );
    } catch {
      await markRetry(env, row, leaseID, now, null, "NetworkError", false);
      summary.retried += 1;
      continue;
    }
    if (response.status === 200) {
      if (await markAccepted(env, row, leaseID, now)) {
        summary.accepted += 1;
      } else if (await releaseAfterRouteChange(env, row, leaseID, now)) {
        summary.retried += 1;
      } else {
        summary.skipped += 1;
      }
      continue;
    }
    const reason = await boundedReason(response);
    if (invalidDeviceResponse(response.status, reason)) {
      await invalidateToken(env, row);
      summary.invalidated += 1;
      continue;
    }
    await markRetry(
      env,
      row,
      leaseID,
      now,
      response.status,
      reason,
      !transientResponse(response.status, reason)
    );
    summary.retried += 1;
  }
  return summary;
}
__name(drainNotificationOutbox, "drainNotificationOutbox");
function scheduleNotificationDrain(env, ctx) {
  if (apnsRuntimeEnabled(env)) ctx.waitUntil(drainNotificationOutbox(env));
}
__name(scheduleNotificationDrain, "scheduleNotificationDrain");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/reactions.ts
var REACTION_PROTOCOL_VERSION = 2;
var REACTION_DAILY_QUOTA = 30;
var REACTION_USAGE_RETENTION_DAYS = 2;
var reactionOperation = "post-paw-reaction";
function protocolVersion22(object) {
  if (object.protocolVersion !== REACTION_PROTOCOL_VERSION) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
  return REACTION_PROTOCOL_VERSION;
}
__name(protocolVersion22, "protocolVersion2");
function pawKind(object) {
  if (stringField(object, "kind") !== "paw") {
    throw new ApiError(400, "invalid_field", "kind must be paw.");
  }
  return "paw";
}
__name(pawKind, "pawKind");
function changeCursorValue(value) {
  if (!/^(?:[A-Za-z0-9_-]{22}|[0-9a-f]{32})$/u.test(value)) {
    throw new ApiError(404, "not_found", "cursor was not found.");
  }
  return value;
}
__name(changeCursorValue, "changeCursorValue");
async function signedReactionRequest(request, env) {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "moment-reaction")
  );
  const body = await readBody(request);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(
        403,
        "active_member_required",
        "Pairing must be complete before reacting to photos."
      );
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}
__name(signedReactionRequest, "signedReactionRequest");
async function reactionContext(env, member) {
  const row = await env.DB.prepare(
    `SELECT participant.id AS participant_id
       FROM moment_participants AS participant
       JOIN moment_devices AS device ON device.participant_id = participant.id
       JOIN moment_spaces AS space ON space.space_id = participant.space_id
      WHERE participant.id = ?
        AND device.id = ?
        AND participant.space_id = ?
        AND participant.state = 'active'
        AND device.state = 'active'
        AND space.state = 'active'`
  ).bind(
    member.momentParticipantId,
    member.deviceId,
    member.spaceId
  ).first();
  if (row === null) {
    throw new ApiError(
      503,
      "reaction_identity_unavailable",
      "The sharing identity is temporarily unavailable."
    );
  }
  return row;
}
__name(reactionContext, "reactionContext");
async function mutationRequestHash(request, body) {
  return sha256Base64url(encodeCanonicalFields([
    "NW2.IDEMPOTENCY",
    "2",
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    await sha256Base64url(body)
  ]));
}
__name(mutationRequestHash, "mutationRequestHash");
async function loadMoment(env, momentID) {
  return env.DB.prepare(
    `SELECT id, space_id, sender_participant_id, state
       FROM moments WHERE id = ?`
  ).bind(momentID).first();
}
__name(loadMoment, "loadMoment");
async function reactionAllowed(env, momentID, spaceID, reactorParticipantID, senderParticipantID, now) {
  const row = await env.DB.prepare(
    `SELECT 1 AS allowed
       FROM moments AS moment
       JOIN moment_spaces AS space ON space.space_id = moment.space_id
       JOIN moment_participants AS reactor ON reactor.id = ?
       JOIN moment_participants AS sender ON sender.id = ?
       JOIN moment_deliveries AS delivery
         ON delivery.moment_id = moment.id
        AND delivery.recipient_participant_id = reactor.id
      WHERE moment.id = ?
        AND moment.space_id = ?
        AND moment.state = 'committed'
        AND moment.sender_participant_id = sender.id
        AND reactor.id <> sender.id
        AND reactor.space_id = moment.space_id
        AND reactor.state = 'active'
        AND sender.space_id = moment.space_id
        AND sender.state = 'active'
        AND space.state = 'active'
        AND delivery.state IN ('pending', 'acknowledged')
        AND delivery.access_expires_at > ?
        AND EXISTS (
          SELECT 1 FROM moment_devices AS reactor_device
           WHERE reactor_device.participant_id = reactor.id
             AND reactor_device.state = 'active'
        )
        AND EXISTS (
          SELECT 1 FROM moment_devices AS sender_device
           WHERE sender_device.participant_id = sender.id
             AND sender_device.state = 'active'
        )
        AND NOT EXISTS (
          SELECT 1 FROM moment_blocks AS block
           WHERE block.space_id = moment.space_id
             AND block.state = 'active'
             AND (
               (block.blocker_participant_id = reactor.id
                AND block.blocked_participant_id = sender.id)
               OR
               (block.blocker_participant_id = sender.id
                AND block.blocked_participant_id = reactor.id)
             )
        )`
  ).bind(
    reactorParticipantID,
    senderParticipantID,
    momentID,
    spaceID,
    now
  ).first();
  return row !== null;
}
__name(reactionAllowed, "reactionAllowed");
async function loadReaction(env, momentID, reactorParticipantID) {
  return env.DB.prepare(
    `SELECT id, moment_id, space_id, reactor_participant_id,
            recipient_participant_id, kind, quota_day_key, created_at
       FROM moment_reactions
      WHERE moment_id = ? AND reactor_participant_id = ? AND kind = 'paw'`
  ).bind(momentID, reactorParticipantID).first();
}
__name(loadReaction, "loadReaction");
function reactionResponse(reaction, alreadyReacted) {
  return {
    protocolVersion: REACTION_PROTOCOL_VERSION,
    reaction: {
      id: reaction.id,
      momentId: reaction.moment_id,
      kind: reaction.kind
    },
    alreadyReacted
  };
}
__name(reactionResponse, "reactionResponse");
function reactionInsertStatement(env, reaction, ignoreExisting) {
  const conflict = ignoreExisting ? " ON CONFLICT(moment_id, reactor_participant_id, kind) DO NOTHING" : "";
  return env.DB.prepare(
    `INSERT INTO moment_reactions(
       id, moment_id, space_id, reactor_participant_id,
       recipient_participant_id, kind, quota_day_key, created_at
     ) VALUES (?, ?, ?, ?, ?, 'paw', ?, ?)${conflict}`
  ).bind(
    reaction.id,
    reaction.moment_id,
    reaction.space_id,
    reaction.reactor_participant_id,
    reaction.recipient_participant_id,
    reaction.quota_day_key,
    reaction.created_at
  );
}
__name(reactionInsertStatement, "reactionInsertStatement");
async function currentDailyUsage(env, participantID, dayKey) {
  const row = await env.DB.prepare(
    `SELECT reaction_count FROM moment_reaction_daily_usage
      WHERE participant_id = ? AND day_key = ?`
  ).bind(participantID, dayKey).first();
  return row?.reaction_count ?? 0;
}
__name(currentDailyUsage, "currentDailyUsage");
async function replayResponse(env, member, clientRequestID, requestHash) {
  let response;
  try {
    response = await storedIdempotentResponse(
      env,
      reactionOperation,
      member.id,
      clientRequestID,
      requestHash
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (response !== null) await consumeNonceAndTouch(env, member);
  return response;
}
__name(replayResponse, "replayResponse");
async function consumeAndThrow(env, member, error) {
  await consumeNonce(env, member);
  throw error;
}
__name(consumeAndThrow, "consumeAndThrow");
async function persistDuplicateResponse(env, member, reaction, clientRequestID, requestHash) {
  const responseBody2 = reactionResponse(reaction, true);
  const guard = {
    ...reaction,
    id: randomBase64url(16),
    created_at: member.now,
    quota_day_key: Math.floor(member.now / 86400)
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      reactionInsertStatement(env, guard, true),
      idempotencyStatement(
        env,
        reactionOperation,
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse(
      env,
      member,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "reaction_conflict", "The reaction could not be recorded.");
  }
  return jsonResponse(responseBody2);
}
__name(persistDuplicateResponse, "persistDuplicateResponse");
async function recordPawReaction(request, env, momentIDValue, notificationsEnabled) {
  const momentID = opaqueId(momentIDValue, "moment");
  const { body, member } = await signedReactionRequest(request, env);
  let clientRequestID;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId", "kind"]);
    protocolVersion22(object);
    clientRequestID = uuidField(object, "clientRequestId");
    pawKind(object);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const context2 = await reactionContext(env, member);
  const moment = await loadMoment(env, momentID);
  if (moment === null || moment.space_id !== member.spaceId) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(404, "moment_not_found", "The moment was not found.")
    );
  }
  if (moment.sender_participant_id === context2.participant_id) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(403, "self_reaction_not_allowed", "A sender cannot react to their own photo.")
    );
  }
  if (!await reactionAllowed(
    env,
    momentID,
    member.spaceId,
    context2.participant_id,
    moment.sender_participant_id,
    member.now
  )) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(410, "reaction_not_allowed", "This photo can no longer receive a reaction.")
    );
  }
  const requestHash = await mutationRequestHash(request, body);
  const replay = await replayResponse(
    env,
    member,
    clientRequestID,
    requestHash
  );
  if (replay !== null) return replay;
  const existing = await loadReaction(env, momentID, context2.participant_id);
  if (existing !== null) {
    return persistDuplicateResponse(
      env,
      member,
      existing,
      clientRequestID,
      requestHash
    );
  }
  const dayKey = Math.floor(member.now / 86400);
  if (await currentDailyUsage(env, context2.participant_id, dayKey) >= REACTION_DAILY_QUOTA) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(429, "reaction_daily_quota_reached", "The daily reaction limit was reached.")
    );
  }
  const reaction = {
    id: randomBase64url(16),
    moment_id: momentID,
    space_id: member.spaceId,
    reactor_participant_id: context2.participant_id,
    recipient_participant_id: moment.sender_participant_id,
    kind: "paw",
    quota_day_key: dayKey,
    created_at: member.now
  };
  const responseBody2 = reactionResponse(reaction, false);
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      reactionInsertStatement(env, reaction, false),
      env.DB.prepare(
        `INSERT INTO reaction_changes(
           cursor, participant_id, reaction_id, created_at
         ) VALUES (?, ?, ?, ?)`
      ).bind(
        randomBase64url(16),
        reaction.recipient_participant_id,
        reaction.id,
        reaction.created_at
      ),
      ...reactionNotificationEventStatements(
        env,
        reaction.id,
        reaction.recipient_participant_id,
        reaction.created_at,
        notificationsEnabled
      ),
      idempotencyStatement(
        env,
        reactionOperation,
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        201,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse(
      env,
      member,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    const racedReaction = await loadReaction(env, momentID, context2.participant_id);
    if (racedReaction !== null && await reactionAllowed(
      env,
      momentID,
      member.spaceId,
      context2.participant_id,
      moment.sender_participant_id,
      member.now
    )) {
      return persistDuplicateResponse(
        env,
        member,
        racedReaction,
        clientRequestID,
        requestHash
      );
    }
    const quotaReached = await currentDailyUsage(
      env,
      context2.participant_id,
      dayKey
    ) >= REACTION_DAILY_QUOTA;
    await consumeNonce(env, member);
    if (quotaReached) {
      throw new ApiError(
        429,
        "reaction_daily_quota_reached",
        "The daily reaction limit was reached."
      );
    }
    throw new ApiError(409, "reaction_conflict", "The reaction could not be recorded.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(recordPawReaction, "recordPawReaction");
async function getReactionChanges(request, env, cursorValue) {
  const cursor = cursorValue === void 0 ? void 0 : changeCursorValue(cursorValue);
  const { body, member } = await signedReactionRequest(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const context2 = await reactionContext(env, member);
  let afterSequence = 0;
  if (cursor !== void 0) {
    const cursorRow = await env.DB.prepare(
      `SELECT sequence FROM reaction_changes
        WHERE cursor = ? AND participant_id = ?`
    ).bind(cursor, context2.participant_id).first();
    if (cursorRow === null) {
      return consumeAndThrow(
        env,
        member,
        new ApiError(404, "cursor_not_found", "The reaction changes cursor was not found.")
      );
    }
    afterSequence = cursorRow.sequence;
  }
  const rows = await env.DB.prepare(
    `SELECT change.sequence, change.cursor,
            reaction.id AS reaction_id, reaction.moment_id, reaction.kind
       FROM reaction_changes AS change
       JOIN moment_reactions AS reaction ON reaction.id = change.reaction_id
      WHERE change.participant_id = ? AND change.sequence > ?
      ORDER BY change.sequence ASC
      LIMIT 100`
  ).bind(context2.participant_id, afterSequence).all();
  const returnedMaxSequence = rows.results.at(-1)?.sequence ?? afterSequence;
  const changes = rows.results.map((row) => ({
    cursor: row.cursor,
    type: "pawReceived",
    reaction: {
      id: row.reaction_id,
      momentId: row.moment_id,
      kind: row.kind
    }
  }));
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      // A successful signed cursor read proves that this physical device has
      // synchronized these hearts. Remove only deliveries addressed to the
      // APNs token currently registered by that device. Other enrolled
      // iPhones must retain their own pending delivery.
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
               WHERE event.kind = 'heart' AND event.participant_id = ?
                 AND event.reaction_id IN (
                   SELECT reaction_id
                     FROM reaction_changes
                    WHERE participant_id = ? AND sequence > ? AND sequence <= ?
                    ORDER BY sequence ASC
                    LIMIT 100
                 )
            )`
      ).bind(
        member.deviceId,
        context2.participant_id,
        context2.participant_id,
        context2.participant_id,
        afterSequence,
        returnedMaxSequence
      ),
      // Events without any remaining physical-device delivery carry no work.
      // Delete those tombs only after the requesting token was scoped above.
      env.DB.prepare(
        `DELETE FROM notification_events
          WHERE kind = 'heart' AND participant_id = ?
            AND reaction_id IN (
              SELECT reaction_id
                FROM reaction_changes
               WHERE participant_id = ? AND sequence > ? AND sequence <= ?
               ORDER BY sequence ASC
               LIMIT 100
            )
            AND NOT EXISTS (
              SELECT 1
                FROM notification_deliveries AS delivery
               WHERE delivery.event_id = notification_events.id
            )`
      ).bind(
        context2.participant_id,
        context2.participant_id,
        afterSequence,
        returnedMaxSequence
      ),
      activityStatement(env, member)
    ]);
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
  return jsonResponse({
    protocolVersion: REACTION_PROTOCOL_VERSION,
    changes,
    nextCursor: changes.at(-1)?.cursor ?? cursor ?? ""
  });
}
__name(getReactionChanges, "getReactionChanges");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/moments.ts
var MOMENT_PROTOCOL_VERSION = 2;
var MAXIMUM_MOMENT_CIPHERTEXT_BYTES = 1024 * 1024;
var MOMENT_DAILY_QUOTA = 5;
var MOMENT_RESERVATION_ATTEMPT_LIMIT = 3;
var MOMENT_UPLOAD_TTL_SECONDS = 60 * 60;
var MOMENT_REPORT_ONLY_TTL_SECONDS = 24 * 60 * 60;
var MOMENT_UNRECEIVED_TTL_SECONDS = 30 * 86400;
var MOMENT_ACKNOWLEDGED_TTL_SECONDS = 7 * 86400;
var REPORT_CONTENT_TTL_SECONDS = 7 * 86400;
var REPORT_DAILY_ATTEMPT_QUOTA = 10;
var minimumAEADCiphertextBytes = 29;
var objectDeletionGraceSeconds = 600;
var cleanupRowLimit = 1e3;
var MOMENT_CLEANUP_OBJECT_LIMIT = 1e3;
var MOMENT_REVOKED_SCOPE_LIMIT = 150;
var d1IdentifierChunkSize = 99;
var d1CASTupleChunkSize = 48;
var allowedClientModerationVersions = /* @__PURE__ */ new Set([1]);
var allowedSenderPolicyVersions = /* @__PURE__ */ new Set([1, 2]);
var allowedReporterConsentVersions = /* @__PURE__ */ new Set([1]);
var allowedModerationKeyIDs = /* @__PURE__ */ new Set(["moderation-v1", "moderation-v2"]);
function changeCursorValue2(value) {
  if (!/^(?:[A-Za-z0-9_-]{22}|[0-9a-f]{32})$/u.test(value)) {
    throw new ApiError(404, "not_found", "cursor was not found.");
  }
  return value;
}
__name(changeCursorValue2, "changeCursorValue");
function protocolVersion23(object) {
  if (object.protocolVersion !== MOMENT_PROTOCOL_VERSION) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
  return MOMENT_PROTOCOL_VERSION;
}
__name(protocolVersion23, "protocolVersion2");
function oneOf(object, key, values) {
  const value = stringField(object, key);
  if (!values.some((candidate) => candidate === value)) {
    throw new ApiError(400, "invalid_field", `${key} is not supported.`);
  }
  return value;
}
__name(oneOf, "oneOf");
function acceptedAtSeconds(object, key, now) {
  const value = stringField(object, key);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/u.test(value)) {
    throw new ApiError(400, "invalid_field", `${key} must be an ISO-8601 UTC date.`);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) {
    throw new ApiError(400, "invalid_field", `${key} must be an ISO-8601 UTC date.`);
  }
  const seconds = Math.floor(milliseconds / 1e3);
  if (seconds > now + 300) {
    throw new ApiError(400, "invalid_field", `${key} cannot be in the future.`);
  }
  return seconds;
}
__name(acceptedAtSeconds, "acceptedAtSeconds");
function requireOctetStream(request) {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/octet-stream") {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/octet-stream.");
  }
  if (request.headers.has("content-encoding")) {
    throw new ApiError(415, "content_encoding_not_allowed", "Content-Encoding is not accepted.");
  }
}
__name(requireOctetStream, "requireOctetStream");
function requireMediaBucket(env) {
  if (env.MEDIA === void 0) {
    throw new ApiError(503, "media_storage_unavailable", "The media store is temporarily unavailable.");
  }
  return env.MEDIA;
}
__name(requireMediaBucket, "requireMediaBucket");
function requireModerationBucket(env) {
  if (env.MODERATION_MEDIA === void 0) {
    throw new ApiError(
      503,
      "moderation_storage_unavailable",
      "The moderation evidence store is temporarily unavailable."
    );
  }
  return env.MODERATION_MEDIA;
}
__name(requireModerationBucket, "requireModerationBucket");
async function signedRequest(request, env, maximumBytes = 16 * 1024) {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "moment-member"));
  const body = await readBody(request, maximumBytes);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    if (member.spaceState !== "active" || member.state === "revoked" || member.state === "expired") {
      const window = await env.DB.prepare(
        `SELECT MIN(participant.report_only_until, device.report_only_until) AS report_only_until
           FROM moment_participants AS participant
           JOIN moment_devices AS device ON device.participant_id = participant.id
          WHERE participant.id = ? AND device.id = ?
            AND participant.space_id = ?`
      ).bind(
        member.momentParticipantId,
        member.deviceId,
        member.spaceId
      ).first();
      if (window?.report_only_until !== null && window?.report_only_until !== void 0 && window.report_only_until > member.now) {
        throw new ApiError(
          410,
          "report_only",
          "Normal sharing access ended; report-only access remains temporarily available.",
          { reportOnlyUntil: window.report_only_until }
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
__name(signedRequest, "signedRequest");
function reportNonceStatements(env, context2, nonce, now) {
  return [
    env.DB.prepare(
      "DELETE FROM moment_report_request_nonces WHERE device_id = ? AND expires_at < ?"
    ).bind(context2.device_id, now),
    env.DB.prepare(
      `INSERT INTO moment_report_request_nonces(
         device_id, nonce, created_at, expires_at
       ) VALUES (?, ?, ?, ?)`
    ).bind(context2.device_id, nonce, now, now + 601)
  ];
}
__name(reportNonceStatements, "reportNonceStatements");
function reportActivityStatement(env, member) {
  const metadataExpiresAt = member.now + positiveIntegerSetting(env.SPACE_INACTIVITY_TTL_SECONDS, 2592e3);
  return env.DB.prepare(
    `UPDATE spaces
        SET last_activity_at = ?, metadata_expires_at = ?
      WHERE id = ? AND state = 'active'
        AND EXISTS (
          SELECT 1 FROM members
           WHERE id = ? AND space_id = spaces.id AND state = 'active'
        )`
  ).bind(member.now, metadataExpiresAt, member.spaceId, member.id);
}
__name(reportActivityStatement, "reportActivityStatement");
async function consumeReportNonce(env, member, context2) {
  try {
    await env.DB.batch(reportNonceStatements(env, context2, member.nonce, member.now));
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}
__name(consumeReportNonce, "consumeReportNonce");
async function consumeReportNonceAndTouch(env, member, context2) {
  try {
    await env.DB.batch([
      ...reportNonceStatements(env, context2, member.nonce, member.now),
      reportActivityStatement(env, member)
    ]);
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
}
__name(consumeReportNonceAndTouch, "consumeReportNonceAndTouch");
async function consumeReportAndThrow(env, member, context2, error) {
  await consumeReportNonce(env, member, context2);
  throw error;
}
__name(consumeReportAndThrow, "consumeReportAndThrow");
async function requireReportIngestionRuntime(env, member, context2) {
  if (reportIngestionRuntimeEnabled(env) && reportIngestionGateOpen(await loadRuntimeGate(env))) return;
  await consumeReportNonce(env, member, context2);
  throw new ApiError(
    503,
    "report_ingestion_runtime_disabled",
    "New reports are temporarily unavailable."
  );
}
__name(requireReportIngestionRuntime, "requireReportIngestionRuntime");
async function signedReportRequest(request, env, maximumBytes = 16 * 1024) {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "moment-report"));
  const body = await readBody(request, maximumBytes);
  if (request.headers.get("neko-protocol-version") !== "1") {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  let credentialID;
  let requestedDeviceID = null;
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
  const now = Math.floor(Date.now() / 1e3);
  if (Math.abs(now - timestamp) > 300) {
    throw new ApiError(401, "stale_request", "The signed request timestamp is outside the five-minute window.");
  }
  const devicePredicate = requestedDeviceID === null ? "device.legacy_member_id = participant.legacy_member_id" : "device.id = ?";
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
       LIMIT 1`
  );
  const credential = await (requestedDeviceID === null ? credentialStatement.bind(credentialID) : credentialStatement.bind(credentialID, requestedDeviceID)).first();
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
    bodySHA256: await sha256Base64url(body)
  });
  if (!await verifyEd25519(credential.signing_public_key, signature, transcript)) {
    throw new ApiError(401, "invalid_authentication", "Signed request authentication failed.");
  }
  const active = credential.space_state === "active" && credential.participant_state === "active" && credential.device_state === "active";
  const reportOnly = !active && credential.participant_report_only_until !== null && credential.device_report_only_until !== null && credential.participant_report_only_until > now && credential.device_report_only_until > now;
  const member = {
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
    now
  };
  const context2 = {
    participant_id: credential.participant_id,
    device_id: credential.device_id,
    current_key_epoch: credential.current_key_epoch,
    membership_revision: credential.membership_revision,
    lineage_id: credential.lineage_id
  };
  if (!active && !reportOnly) {
    await consumeReportNonce(env, member, context2);
    throw new ApiError(410, "report_window_closed", "The report-only access window has closed.");
  }
  return { body, member, context: context2, reportOnly };
}
__name(signedReportRequest, "signedReportRequest");
async function consumeAndThrow2(env, member, error) {
  await consumeNonce(env, member);
  throw error;
}
__name(consumeAndThrow2, "consumeAndThrow");
async function mutationRequestHash2(request, body) {
  return sha256Base64url(encodeCanonicalFields([
    "NW2.IDEMPOTENCY",
    "2",
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    await sha256Base64url(body)
  ]));
}
__name(mutationRequestHash2, "mutationRequestHash");
async function replayResponse2(env, operation, member, clientRequestID, requestHash) {
  let stored;
  try {
    stored = await storedIdempotentResponse(
      env,
      operation,
      member.id,
      clientRequestID,
      requestHash
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (stored !== null) await consumeNonceAndTouch(env, member);
  return stored;
}
__name(replayResponse2, "replayResponse");
async function storedReportIdempotentResponse(env, operation, context2, clientRequestID, requestHash, now) {
  await env.DB.prepare(
    `DELETE FROM moment_report_idempotency_records
      WHERE operation = ? AND actor_device_id = ? AND client_request_id = ?
        AND expires_at <= ?`
  ).bind(operation, context2.device_id, clientRequestID, now).run();
  const row = await env.DB.prepare(
    `SELECT request_hash, response_status, response_json
       FROM moment_report_idempotency_records
      WHERE operation = ? AND actor_device_id = ? AND client_request_id = ?`
  ).bind(operation, context2.device_id, clientRequestID).first();
  if (row === null) return null;
  if (row.request_hash !== requestHash) {
    throw new ApiError(409, "idempotency_conflict", "The idempotency key was already used with another request.");
  }
  return jsonResponse(JSON.parse(row.response_json), row.response_status);
}
__name(storedReportIdempotentResponse, "storedReportIdempotentResponse");
function reportIdempotencyStatement(env, operation, context2, clientRequestID, requestHash, responseStatus, responseBody2, now) {
  const expiresAt = now + positiveIntegerSetting(env.IDEMPOTENCY_TTL_SECONDS, 172800);
  return env.DB.prepare(
    `INSERT INTO moment_report_idempotency_records(
       operation, actor_device_id, client_request_id, lineage_id, request_hash,
       response_status, response_json, created_at, expires_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    operation,
    context2.device_id,
    clientRequestID,
    context2.lineage_id,
    requestHash,
    responseStatus,
    JSON.stringify(responseBody2),
    now,
    expiresAt
  );
}
__name(reportIdempotencyStatement, "reportIdempotencyStatement");
async function replayReportResponse(env, operation, member, context2, clientRequestID, requestHash) {
  let stored;
  try {
    stored = await storedReportIdempotentResponse(
      env,
      operation,
      context2,
      clientRequestID,
      requestHash,
      member.now
    );
  } catch (error) {
    await consumeReportNonce(env, member, context2);
    throw error;
  }
  if (stored !== null) await consumeReportNonceAndTouch(env, member, context2);
  return stored;
}
__name(replayReportResponse, "replayReportResponse");
async function momentContext(env, member) {
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
        AND space.state = 'active'`
  ).bind(
    member.momentParticipantId,
    member.deviceId,
    member.spaceId
  ).first();
  if (row === null) {
    throw new ApiError(503, "moment_identity_unavailable", "The sharing identity is temporarily unavailable.");
  }
  return row;
}
__name(momentContext, "momentContext");
async function storagePrefix(env, spaceID, now) {
  const candidate = randomBase64url(24);
  await env.DB.prepare(
    `INSERT OR IGNORE INTO moment_storage_scopes(space_id, object_prefix, created_at)
     VALUES (?, ?, ?)`
  ).bind(spaceID, candidate, now).run();
  const row = await env.DB.prepare(
    "SELECT object_prefix FROM moment_storage_scopes WHERE space_id = ?"
  ).bind(spaceID).first();
  if (row === null) {
    throw new ApiError(503, "moment_storage_unavailable", "The media store is temporarily unavailable.");
  }
  return row.object_prefix;
}
__name(storagePrefix, "storagePrefix");
function r2Checksum(object) {
  const value = object.checksums.sha256;
  return value === void 0 ? null : base64urlEncode(new Uint8Array(value));
}
__name(r2Checksum, "r2Checksum");
async function ensureR2Object(bucket, key, body, digestBytes, digestValue) {
  const stored = await bucket.put(key, body, {
    onlyIf: { etagDoesNotMatch: "*" },
    sha256: digestBytes,
    httpMetadata: {
      contentType: "application/octet-stream",
      cacheControl: "no-store"
    }
  });
  const object = stored ?? await bucket.head(key);
  if (object === null || object.size !== body.length || r2Checksum(object) !== digestValue) {
    throw new ApiError(409, "object_integrity_conflict", "Stored ciphertext does not match its descriptor.");
  }
}
__name(ensureR2Object, "ensureR2Object");
async function loadMoment2(env, momentID) {
  return env.DB.prepare(
    `SELECT id, client_moment_id, space_id, sender_participant_id,
            sender_device_id, kind, key_epoch, state, object_key,
            ciphertext_size, ciphertext_sha256, sender_policy_version, quota_day_key, quota_counted,
            reservation_attempt, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at, committed_at,
            unreceived_expires_at, closed_at
       FROM moments WHERE id = ?`
  ).bind(momentID).first();
}
__name(loadMoment2, "loadMoment");
async function loadClientMoment(env, senderDeviceID, clientMomentID) {
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
      LIMIT 1`
  ).bind(senderDeviceID, clientMomentID).first();
}
__name(loadClientMoment, "loadClientMoment");
function isExpiredDraft(row, now) {
  return row.committed_at === null && (row.state === "expired" || row.state === "deleted" || row.upload_expires_at <= now);
}
__name(isExpiredDraft, "isExpiredDraft");
function requireSenderMoment(row, member, context2) {
  if (row === null || row.space_id !== member.spaceId || row.sender_participant_id !== context2.participant_id || row.sender_device_id !== context2.device_id) {
    throw new ApiError(404, "moment_not_found", "The moment was not found.");
  }
}
__name(requireSenderMoment, "requireSenderMoment");
async function eligibleRecipients(env, spaceID, senderParticipantID) {
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
      ORDER BY recipient.id ASC`
  ).bind(spaceID, senderParticipantID, senderParticipantID, senderParticipantID).all();
  return rows.results;
}
__name(eligibleRecipients, "eligibleRecipients");
function reservationResponse(row, used) {
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
      uploadExpiresAt: row.uploadExpiresAt
    },
    quota: {
      dayKey: row.quotaDayKey,
      used,
      limit: MOMENT_DAILY_QUOTA,
      remaining: Math.max(0, MOMENT_DAILY_QUOTA - used)
    }
  };
}
__name(reservationResponse, "reservationResponse");
async function reserveMoment(request, env) {
  const { body, member } = await signedRequest(request, env);
  let object;
  let clientRequestID;
  let clientMomentID;
  let kind;
  let keyEpoch;
  let ciphertextSize;
  let ciphertextSHA256;
  let clientModerationVersion;
  let senderPolicyVersion;
  let senderPolicyAcceptedAt;
  try {
    object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion",
      "clientRequestId",
      "clientMomentId",
      "kind",
      "keyEpoch",
      "ciphertextSize",
      "ciphertextSHA256",
      "clientModerationVersion",
      "senderPolicyAcceptance"
    ]);
    protocolVersion23(object);
    clientRequestID = uuidField(object, "clientRequestId");
    clientMomentID = uuidField(object, "clientMomentId");
    kind = oneOf(object, "kind", ["live", "memory"]);
    keyEpoch = integerField(object, "keyEpoch", 1, Number.MAX_SAFE_INTEGER);
    ciphertextSize = integerField(
      object,
      "ciphertextSize",
      minimumAEADCiphertextBytes,
      MAXIMUM_MOMENT_CIPHERTEXT_BYTES
    );
    ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
    clientModerationVersion = integerField(
      object,
      "clientModerationVersion",
      1,
      Number.MAX_SAFE_INTEGER
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
    return consumeAndThrow2(env, member, error);
  }
  const requestHash = await mutationRequestHash2(request, body);
  let context2;
  let prior;
  let retryingExpiredDraft;
  let recipients;
  let prefix;
  try {
    context2 = await momentContext(env, member);
    prior = await loadClientMoment(env, context2.device_id, clientMomentID);
    retryingExpiredDraft = prior !== null && isExpiredDraft(prior, member.now);
    if (retryingExpiredDraft && prior?.reserve_request_hash !== requestHash) {
      throw new ApiError(
        409,
        "idempotency_conflict",
        "The expired client moment can only be retried with its original request."
      );
    }
    if (retryingExpiredDraft && prior !== null && prior.reservation_attempt >= MOMENT_RESERVATION_ATTEMPT_LIMIT) {
      throw new ApiError(
        429,
        "reservation_retry_limit_exceeded",
        "This client moment has exhausted its safe reservation retries."
      );
    }
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  if (!retryingExpiredDraft) {
    const replayed = await replayResponse2(
      env,
      "reserve-moment",
      member,
      clientRequestID,
      requestHash
    );
    if (replayed !== null) return replayed;
  }
  try {
    if (keyEpoch !== context2.current_key_epoch) {
      throw new ApiError(409, "key_epoch_required", "The current sharing key epoch is required.");
    }
    recipients = await eligibleRecipients(env, member.spaceId, context2.participant_id);
    if (recipients.length === 0) {
      throw new ApiError(409, "no_eligible_recipients", "There is no eligible recipient for this moment.");
    }
    prefix = await storagePrefix(env, member.spaceId, member.now);
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  const quotaCounted = retryingExpiredDraft ? 0 : 1;
  const reservationAttempt = retryingExpiredDraft && prior !== null ? prior.reservation_attempt + 1 : 1;
  const dayKey = retryingExpiredDraft && prior !== null ? prior.quota_day_key : Math.floor(member.now / 86400);
  const usage = await env.DB.prepare(
    `SELECT reserved_count + committed_count AS used
       FROM moment_daily_usage WHERE participant_id = ? AND day_key = ?`
  ).bind(context2.participant_id, dayKey).first();
  const used = (usage?.used ?? 0) + quotaCounted;
  if (used > MOMENT_DAILY_QUOTA) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(429, "moment_daily_quota_exceeded", "The daily moment quota has been reached.")
    );
  }
  const momentID = randomBase64url(16);
  const objectKey2 = `v2/${prefix}/moments/${randomBase64url(24)}`;
  const uploadExpiresAt = member.now + MOMENT_UPLOAD_TTL_SECONDS;
  const responseBody2 = reservationResponse({
    id: momentID,
    clientMomentID,
    spaceID: member.spaceId,
    senderParticipantID: context2.participant_id,
    senderDeviceID: context2.device_id,
    kind,
    keyEpoch,
    ciphertextSize,
    ciphertextSHA256,
    quotaDayKey: dayKey,
    createdAt: member.now,
    uploadExpiresAt
  }, used);
  try {
    const statements = [
      ...nonceStatements(env, member)
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
             deleted_at = NULL`
        ).bind(
          prior.object_key,
          prior.id,
          member.now + objectDeletionGraceSeconds,
          member.now
        ));
      }
      statements.push(
        env.DB.prepare(
          `UPDATE moments
              SET state = 'expired', closed_at = COALESCE(closed_at, ?)
            WHERE id = ? AND committed_at IS NULL
              AND state IN ('reserved', 'uploaded') AND upload_expires_at <= ?`
        ).bind(member.now, prior.id, member.now),
        env.DB.prepare(
          `DELETE FROM idempotency_records
            WHERE operation = 'reserve-moment' AND actor_id = ?
              AND client_request_id = ? AND request_hash = ?`
        ).bind(member.id, clientRequestID, requestHash)
      );
    }
    statements.push(
      env.DB.prepare(
        `INSERT INTO moment_sender_policy_acceptances(
           participant_id, policy_version, accepted_at, recorded_at
         ) VALUES (?, ?, ?, ?)
         ON CONFLICT(participant_id, policy_version) DO UPDATE SET
           accepted_at = MAX(moment_sender_policy_acceptances.accepted_at, excluded.accepted_at),
           recorded_at = excluded.recorded_at`
      ).bind(context2.participant_id, senderPolicyVersion, senderPolicyAcceptedAt, member.now),
      env.DB.prepare(
        `INSERT INTO moments(
           id, client_moment_id, space_id, sender_participant_id,
           sender_device_id, kind, key_epoch, state, object_key,
           ciphertext_size, ciphertext_sha256, client_moderation_version,
           sender_policy_version, sender_policy_accepted_at, quota_day_key,
           quota_counted, reservation_attempt, reserve_request_hash,
           created_at, upload_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        momentID,
        clientMomentID,
        member.spaceId,
        context2.participant_id,
        context2.device_id,
        kind,
        keyEpoch,
        objectKey2,
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
        uploadExpiresAt
      ),
      idempotencyStatement(
        env,
        "reserve-moment",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        201,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    );
    await env.DB.batch(statements);
  } catch {
    const raced = await replayResponse2(
      env,
      "reserve-moment",
      member,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    const currentUsage = await env.DB.prepare(
      `SELECT reserved_count + committed_count AS used
         FROM moment_daily_usage WHERE participant_id = ? AND day_key = ?`
    ).bind(context2.participant_id, dayKey).first();
    await consumeNonce(env, member);
    if ((currentUsage?.used ?? 0) >= MOMENT_DAILY_QUOTA) {
      throw new ApiError(429, "moment_daily_quota_exceeded", "The daily moment quota has been reached.");
    }
    throw new ApiError(409, "moment_reservation_conflict", "The moment could not be reserved.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(reserveMoment, "reserveMoment");
async function queueObjectDeletion(env, objectKey2, objectType, ownerID, now) {
  await env.DB.prepare(
    `INSERT INTO moment_object_deletions(
       object_key, object_type, owner_id, state, not_before, attempts, created_at
     ) VALUES (?, ?, ?, 'pending', ?, 0, ?)
     ON CONFLICT(object_key) DO UPDATE SET
       state = 'pending',
       not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
       attempts = moment_object_deletions.attempts + 1,
       deleted_at = NULL`
  ).bind(objectKey2, objectType, ownerID, now + objectDeletionGraceSeconds, now).run();
}
__name(queueObjectDeletion, "queueObjectDeletion");
async function uploadMomentCiphertext(request, env, momentIDValue) {
  const momentID = opaqueId(momentIDValue, "moment");
  requireOctetStream(request);
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env, MAXIMUM_MOMENT_CIPHERTEXT_BYTES);
  if (body.length < minimumAEADCiphertextBytes) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(400, "ciphertext_too_small", "The ciphertext is too small.")
    );
  }
  const [context2, row, digestBytes, digestValue] = await Promise.all([
    momentContext(env, member),
    loadMoment2(env, momentID),
    sha256(body),
    sha256Base64url(body)
  ]);
  try {
    requireSenderMoment(row, member, context2);
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  if (isExpiredDraft(row, member.now)) {
    await consumeNonce(env, member);
    if (row.state !== "deleted") {
      await queueObjectDeletion(env, row.object_key, "moment", row.id, member.now);
    }
    throw new ApiError(
      410,
      "reservation_expired",
      "This reservation expired; reserve the same client moment again before uploading."
    );
  }
  if (row.ciphertext_size !== body.length || row.ciphertext_sha256 !== digestValue) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(409, "ciphertext_descriptor_mismatch", "Ciphertext does not match its reservation.")
    );
  }
  const responseBody2 = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    momentId: momentID,
    state: "uploaded",
    ciphertextSize: body.length,
    ciphertextSHA256: digestValue
  };
  if (row.state === "uploaded" || row.state === "committed") {
    await consumeNonce(env, member);
    const head = await bucket.head(row.object_key);
    if (head === null || head.size !== body.length || r2Checksum(head) !== digestValue) {
      throw new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable.");
    }
    await activityStatement(env, member).run();
    return jsonResponse(responseBody2);
  }
  if (row.state !== "reserved" || row.upload_expires_at <= member.now) {
    await consumeNonce(env, member);
    await queueObjectDeletion(env, row.object_key, "moment", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This moment no longer accepts ciphertext uploads.");
  }
  await consumeNonce(env, member);
  await ensureR2Object(bucket, row.object_key, body, digestBytes, digestValue);
  const updated = await env.DB.prepare(
    `UPDATE moments
        SET state = 'uploaded', uploaded_at = ?
      WHERE id = ? AND state = 'reserved' AND upload_expires_at > ?`
  ).bind(member.now, momentID, member.now).run();
  if (updated.meta.changes !== 1) {
    const raced = await loadMoment2(env, momentID);
    if (raced !== null && (raced.state === "uploaded" || raced.state === "committed") && raced.ciphertext_size === body.length && raced.ciphertext_sha256 === digestValue) {
      const head = await bucket.head(raced.object_key);
      if (head !== null && head.size === body.length && r2Checksum(head) === digestValue) {
        await activityStatement(env, member).run();
        return jsonResponse(responseBody2);
      }
    }
    await queueObjectDeletion(env, row.object_key, "moment", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This moment no longer accepts ciphertext uploads.");
  }
  await activityStatement(env, member).run();
  return jsonResponse(responseBody2);
}
__name(uploadMomentCiphertext, "uploadMomentCiphertext");
async function commitMoment(request, env, momentIDValue, notificationsEnabled) {
  const momentID = opaqueId(momentIDValue, "moment");
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env, 3 * 1024 * 1024);
  let clientRequestID;
  let sharedRecord = null;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, Object.hasOwn(object, "sharedRecord") ? ["protocolVersion", "clientRequestId", "sharedRecord"] : ["protocolVersion", "clientRequestId"]);
    protocolVersion23(object);
    clientRequestID = uuidField(object, "clientRequestId");
    if (Object.hasOwn(object, "sharedRecord")) {
      sharedRecord = await parseMomentSharedRecord(object.sharedRecord, member.spaceId, momentID);
    }
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  const requestHash = await mutationRequestHash2(request, body);
  const replayed = await replayResponse2(
    env,
    "commit-moment",
    member,
    clientRequestID,
    requestHash
  );
  if (replayed !== null) return replayed;
  const [context2, row] = await Promise.all([momentContext(env, member), loadMoment2(env, momentID)]);
  try {
    requireSenderMoment(row, member, context2);
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  if (row.sender_policy_version === 2 !== (sharedRecord !== null)) {
    return consumeAndThrow2(env, member, new ApiError(
      409,
      "family_record_required",
      "This delivery must commit its photo and memo together."
    ));
  }
  if (isExpiredDraft(row, member.now)) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(
        410,
        "reservation_expired",
        "This reservation expired; reserve the same client moment again before committing."
      )
    );
  }
  if (row.state !== "uploaded" || row.upload_expires_at <= member.now) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(409, "moment_not_ready", "The moment is not ready to commit.")
    );
  }
  if (row.key_epoch !== context2.current_key_epoch) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(409, "key_epoch_required", "The current sharing key epoch is required.")
    );
  }
  const [recipients, head] = await Promise.all([
    eligibleRecipients(env, member.spaceId, context2.participant_id),
    bucket.head(row.object_key)
  ]);
  if (recipients.length === 0) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(409, "no_eligible_recipients", "There is no eligible recipient for this moment.")
    );
  }
  if (head === null || head.size !== row.ciphertext_size || r2Checksum(head) !== row.ciphertext_sha256) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable.")
    );
  }
  const committedAt = member.now;
  const unreceivedExpiresAt = member.now + MOMENT_UNRECEIVED_TTL_SECONDS;
  const firstRecipientID = recipients[0]?.id;
  if (firstRecipientID === void 0) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(409, "no_eligible_recipients", "There is no eligible recipient for this moment.")
    );
  }
  const firstCursor = randomBase64url(16);
  const responseBody2 = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    moment: {
      id: momentID,
      state: "committed",
      committedAt,
      unreceivedExpiresAt
    },
    recipientCount: recipients.length,
    changeCursor: firstCursor,
    ...sharedRecord === null ? {} : { sharedRecordID: sharedRecord.photoID }
  };
  const commitEventID = randomBase64url(16);
  let sharedWrite = null;
  if (sharedRecord !== null) {
    try {
      sharedWrite = await prepareMomentSharedRecordCommit(env, member, sharedRecord, clientRequestID, requestHash);
    } catch (error) {
      const raced = await replayResponse2(env, "commit-moment", member, clientRequestID, requestHash);
      if (raced !== null) return raced;
      return consumeAndThrow2(env, member, error);
    }
  }
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_commit_events(
           id, moment_id, sender_participant_id, expected_key_epoch,
           expected_membership_revision, committed_at, unreceived_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        commitEventID,
        momentID,
        context2.participant_id,
        context2.current_key_epoch,
        context2.membership_revision,
        committedAt,
        unreceivedExpiresAt
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
            )`
      ).bind(
        momentID,
        committedAt,
        unreceivedExpiresAt,
        member.spaceId,
        context2.participant_id,
        context2.participant_id,
        context2.participant_id
      ),
      env.DB.prepare(
        `INSERT INTO moment_changes(
           cursor, participant_id, change_type, moment_id, created_at
         ) VALUES (?, ?, 'moment_committed', ?, ?)`
      ).bind(firstCursor, firstRecipientID, momentID, committedAt),
      env.DB.prepare(
        `INSERT INTO moment_changes(
           cursor, participant_id, change_type, moment_id, created_at
         )
         SELECT lower(hex(randomblob(16))), delivery.recipient_participant_id,
                'moment_committed', delivery.moment_id, ?
           FROM moment_deliveries AS delivery
          WHERE delivery.moment_id = ?
            AND delivery.recipient_participant_id <> ?`
      ).bind(committedAt, momentID, firstRecipientID),
      ...momentNotificationEventStatements(
        env,
        momentID,
        committedAt,
        notificationsEnabled
      ),
      env.DB.prepare("DELETE FROM moment_commit_events WHERE id = ?").bind(commitEventID),
      ...sharedWrite?.statements ?? [],
      ...sharedRecord === null ? [] : [
        env.DB.prepare("INSERT INTO family_record_moments(space_id,photo_id,moment_id) VALUES (?,?,?)").bind(member.spaceId, sharedRecord.photoID, momentID),
        env.DB.prepare("INSERT INTO family_record_moment_readers(space_id,photo_id,participant_id) VALUES (?,?,?)").bind(member.spaceId, sharedRecord.photoID, context2.participant_id),
        env.DB.prepare(`INSERT INTO family_record_moment_readers(space_id,photo_id,participant_id)
          SELECT ?,?,recipient_participant_id FROM moment_deliveries WHERE moment_id=?`).bind(member.spaceId, sharedRecord.photoID, momentID)
      ],
      idempotencyStatement(
        env,
        "commit-moment",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        201,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse2(
      env,
      "commit-moment",
      member,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    if (sharedRecord !== null && await momentSharedRecordCapacityReached(
      env,
      member.spaceId,
      sharedRecord.wordsID !== null
    )) {
      return consumeAndThrow2(env, member, new ApiError(
        409,
        "family_record_capacity",
        "Shared record capacity reached; nothing was sent."
      ));
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "moment_commit_conflict", "The moment could not be committed.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(commitMoment, "commitMoment");
async function getMomentChanges(request, env, cursorValue) {
  const cursor = cursorValue === void 0 ? void 0 : changeCursorValue2(cursorValue);
  const { body, member } = await signedRequest(request, env);
  if (body.length !== 0) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(400, "body_must_be_empty", "This request must have an empty body.")
    );
  }
  const context2 = await momentContext(env, member);
  let afterSequence = 0;
  if (cursor !== void 0) {
    const cursorRow = await env.DB.prepare(
      `SELECT sequence FROM moment_changes
        WHERE cursor = ? AND participant_id = ?`
    ).bind(cursor, context2.participant_id).first();
    if (cursorRow === null) {
      return consumeAndThrow2(
        env,
        member,
        new ApiError(404, "cursor_not_found", "The changes cursor was not found.")
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
      LIMIT 100`
  ).bind(context2.participant_id, afterSequence).all();
  const changes = rows.results.map((row) => {
    if (row.committed_at === null || row.access_expires_at === null || row.delivery_state === null) {
      throw new ApiError(503, "moment_state_unavailable", "The moment change is temporarily unavailable.");
    }
    return {
      cursor: row.cursor,
      sequence: row.sequence,
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
        deliveryState: row.delivery_state
      }
    };
  });
  await consumeNonceAndTouch(env, member);
  return jsonResponse({
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    changes,
    nextCursor: changes.at(-1)?.cursor ?? cursor ?? ""
  });
}
__name(getMomentChanges, "getMomentChanges");
async function downloadMomentCiphertext(request, env, momentIDValue) {
  const momentID = opaqueId(momentIDValue, "moment");
  const bucket = requireMediaBucket(env);
  const { body, member } = await signedRequest(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  const context2 = await momentContext(env, member);
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
      WHERE moment.id = ? AND moment.space_id = ?`
  ).bind(
    context2.participant_id,
    member.now,
    context2.participant_id,
    context2.participant_id,
    momentID,
    member.spaceId
  ).first();
  if (row === null || row.state !== "committed" || row.sender_participant_id !== context2.participant_id && row.recipient_authorized !== 1) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(404, "moment_not_found", "The moment was not found.")
    );
  }
  await consumeNonceAndTouch(env, member);
  const object = await bucket.get(row.object_key);
  if (object === null || object.size !== row.ciphertext_size || r2Checksum(object) !== row.ciphertext_sha256) {
    throw new ApiError(503, "stored_object_unavailable", "The ciphertext is temporarily unavailable.");
  }
  return new Response(object.body, {
    status: 200,
    headers: {
      "Cache-Control": "no-store, max-age=0",
      "Content-Type": "application/octet-stream",
      "Content-Length": String(row.ciphertext_size),
      "X-Content-Type-Options": "nosniff",
      "X-Neko-Ciphertext-SHA256": row.ciphertext_sha256
    }
  });
}
__name(downloadMomentCiphertext, "downloadMomentCiphertext");
async function acknowledgeMoment(request, env, momentIDValue) {
  const momentID = opaqueId(momentIDValue, "moment");
  const { body, member } = await signedRequest(request, env);
  let clientRequestID;
  let ciphertextSHA256;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId", "ciphertextSHA256"]);
    protocolVersion23(object);
    clientRequestID = uuidField(object, "clientRequestId");
    ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  const requestHash = await mutationRequestHash2(request, body);
  const replayed = await replayResponse2(
    env,
    "acknowledge-moment",
    member,
    clientRequestID,
    requestHash
  );
  if (replayed !== null) return replayed;
  const context2 = await momentContext(env, member);
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
        )`
  ).bind(
    momentID,
    context2.participant_id,
    member.spaceId,
    ciphertextSHA256,
    member.now,
    context2.participant_id,
    context2.participant_id
  ).first();
  if (delivery === null) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(404, "delivery_not_found", "The moment delivery was not found.")
    );
  }
  const acknowledgedAt = delivery.acknowledged_at ?? member.now;
  const shouldNotifySender = delivery.state === "pending";
  const accessExpiresAt = Math.min(
    delivery.access_expires_at,
    acknowledgedAt + MOMENT_ACKNOWLEDGED_TTL_SECONDS
  );
  const responseBody2 = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    delivery: {
      momentId: momentID,
      state: "acknowledged",
      acknowledgedAt,
      accessExpiresAt
    }
  };
  const eventID = randomBase64url(16);
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_ack_events(
           id, moment_id, recipient_participant_id, ciphertext_sha256,
           acknowledged_at, access_expires_at
         ) VALUES (?, ?, ?, ?, ?, ?)`
      ).bind(
        eventID,
        momentID,
        context2.participant_id,
        ciphertextSHA256,
        acknowledgedAt,
        accessExpiresAt
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
            )`
      ).bind(
        member.deviceId,
        context2.participant_id,
        context2.participant_id,
        momentID
      ),
      env.DB.prepare(
        `DELETE FROM notification_events
          WHERE kind = 'new_moment'
            AND participant_id = ? AND moment_id = ?
            AND NOT EXISTS (
              SELECT 1
                FROM notification_deliveries AS delivery
               WHERE delivery.event_id = notification_events.id
            )`
      ).bind(context2.participant_id, momentID),
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
            )`
      ).bind(
        momentID,
        context2.participant_id,
        shouldNotifySender ? 1 : 0
      ),
      idempotencyStatement(
        env,
        "acknowledge-moment",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse2(
      env,
      "acknowledge-moment",
      member,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "acknowledgement_conflict", "The delivery could not be acknowledged.");
  }
  return jsonResponse(responseBody2);
}
__name(acknowledgeMoment, "acknowledgeMoment");
async function blockParticipant(request, env, targetParticipantIDValue) {
  const targetParticipantID = opaqueId(targetParticipantIDValue, "participant");
  const { body, member } = await signedRequest(request, env);
  let clientRequestID;
  let withdrawal;
  try {
    const object = parseJsonBody(request, body);
    const hasWithdrawal = "withdrawalId" in object || "withdrawalTokenHash" in object;
    exactKeys(object, hasWithdrawal ? ["protocolVersion", "clientRequestId", "withdrawalId", "withdrawalTokenHash"] : ["protocolVersion", "clientRequestId"]);
    protocolVersion23(object);
    clientRequestID = uuidField(object, "clientRequestId");
    if (hasWithdrawal) {
      const id = uuidField(object, "withdrawalId");
      const tokenHash = stringField(object, "withdrawalTokenHash");
      if (!/^[0-9a-f]{64}$/u.test(tokenHash)) {
        throw new ApiError(400, "invalid_field", "The withdrawal token hash is invalid.");
      }
      withdrawal = { id, tokenHash };
    }
  } catch (error) {
    return consumeAndThrow2(env, member, error);
  }
  const requestHash = await mutationRequestHash2(request, body);
  const replayed = await replayResponse2(
    env,
    "block-participant",
    member,
    clientRequestID,
    requestHash
  );
  if (replayed !== null) return replayed;
  const context2 = await momentContext(env, member);
  if (targetParticipantID === context2.participant_id) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(400, "cannot_block_self", "A participant cannot block themselves.")
    );
  }
  const target = await env.DB.prepare(
    `SELECT id FROM moment_participants
      WHERE id = ? AND space_id = ? AND state = 'active'`
  ).bind(targetParticipantID, member.spaceId).first();
  if (target === null) {
    return consumeAndThrow2(
      env,
      member,
      new ApiError(404, "participant_not_found", "The participant was not found.")
    );
  }
  const existing = await env.DB.prepare(
    `SELECT created_at FROM moment_blocks
      WHERE blocker_participant_id = ? AND blocked_participant_id = ? AND state = 'active'`
  ).bind(context2.participant_id, targetParticipantID).first();
  if (existing !== null) {
    if (withdrawal !== void 0) {
      return consumeAndThrow2(
        env,
        member,
        new ApiError(409, "block_conflict", "The participant could not be blocked.")
      );
    }
    const responseBody3 = {
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      block: {
        blockerParticipantId: context2.participant_id,
        blockedParticipantId: targetParticipantID,
        state: "active",
        createdAt: existing.created_at
      },
      revokedDeliveryCount: 0,
      requiredKeyEpoch: context2.current_key_epoch
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
          responseBody3,
          member.now
        ),
        activityStatement(env, member)
      ]);
    } catch {
      const raced = await replayResponse2(
        env,
        "block-participant",
        member,
        clientRequestID,
        requestHash
      );
      if (raced !== null) return raced;
      await consumeNonce(env, member);
      throw new ApiError(409, "block_conflict", "The participant could not be blocked.");
    }
    return jsonResponse(responseBody3);
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
      `
  ).bind(
    member.spaceId,
    context2.participant_id,
    targetParticipantID,
    targetParticipantID,
    context2.participant_id
  ).first();
  const requiredKeyEpoch = context2.current_key_epoch + 1;
  const responseBody2 = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    block: {
      blockerParticipantId: context2.participant_id,
      blockedParticipantId: targetParticipantID,
      state: "active",
      createdAt: member.now,
      ...withdrawal === void 0 ? {} : { withdrawalId: withdrawal.id }
    },
    revokedDeliveryCount: affected?.count ?? 0,
    requiredKeyEpoch
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO moment_blocks(
           space_id, blocker_participant_id, blocked_participant_id, state,
           created_key_epoch, created_at
         ) VALUES (?, ?, ?, 'active', ?, ?)`
      ).bind(
        member.spaceId,
        context2.participant_id,
        targetParticipantID,
        requiredKeyEpoch,
        member.now
      ),
      ...withdrawal === void 0 ? [] : [env.DB.prepare(
        `INSERT INTO moment_block_withdrawals(
           id, token_hash, space_id, blocker_participant_id, blocked_participant_id,
           created_key_epoch, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        withdrawal.id,
        withdrawal.tokenHash,
        member.spaceId,
        context2.participant_id,
        targetParticipantID,
        requiredKeyEpoch,
        member.now
      )],
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
            )`
      ).bind(
        member.now,
        member.spaceId,
        context2.participant_id,
        targetParticipantID,
        targetParticipantID,
        context2.participant_id
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
            )`
      ).bind(
        member.now,
        member.spaceId,
        context2.participant_id,
        targetParticipantID,
        targetParticipantID,
        context2.participant_id
      ),
      env.DB.prepare(
        `UPDATE members
            SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?)
          WHERE id = ? AND space_id = ? AND state IN ('pending', 'active')`
      ).bind(member.now, targetParticipantID, member.spaceId),
      env.DB.prepare(
        `UPDATE moment_participants
            SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?),
                report_only_until = MAX(COALESCE(report_only_until, 0), ?)
          WHERE id = ? AND space_id = ? AND state IN ('pending', 'active')`
      ).bind(
        member.now,
        member.now + MOMENT_REPORT_ONLY_TTL_SECONDS,
        targetParticipantID,
        member.spaceId
      ),
      env.DB.prepare(
        `UPDATE moment_devices
            SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?),
                report_only_until = MAX(COALESCE(report_only_until, 0), ?)
          WHERE participant_id = ? AND state IN ('pending', 'active')`
      ).bind(
        member.now,
        member.now + MOMENT_REPORT_ONLY_TTL_SECONDS,
        targetParticipantID
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
           attempts = moment_object_deletions.attempts + 1, deleted_at = NULL`
      ).bind(
        member.now + objectDeletionGraceSeconds,
        member.now,
        member.spaceId,
        context2.participant_id,
        targetParticipantID
      ),
      env.DB.prepare(
        `UPDATE moments SET state = 'expired', closed_at = ?
          WHERE space_id = ? AND state = 'committed'
            AND sender_participant_id IN (?, ?)
            AND NOT EXISTS (
              SELECT 1 FROM moment_deliveries AS delivery
               WHERE delivery.moment_id = moments.id
                 AND delivery.state IN ('pending', 'acknowledged')
            )`
      ).bind(
        member.now,
        member.spaceId,
        context2.participant_id,
        targetParticipantID
      ),
      idempotencyStatement(
        env,
        "block-participant",
        member.id,
        clientRequestID,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse2(
      env,
      "block-participant",
      member,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "block_conflict", "The participant could not be blocked.");
  }
  return jsonResponse(responseBody2);
}
__name(blockParticipant, "blockParticipant");
async function withdrawParticipantBlock(request, env, withdrawalIDValue) {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "block-withdrawal")
  );
  const unauthorized = /* @__PURE__ */ __name(() => new ApiError(
    401,
    "invalid_authentication",
    "The withdrawal authorization is invalid."
  ), "unauthorized");
  let token;
  try {
    const authorization = request.headers.get("Authorization") ?? "";
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/u.exec(authorization);
    if (match?.[1] === void 0) throw unauthorized();
    token = base64urlDecode(match[1], 32);
  } catch {
    throw unauthorized();
  }
  const withdrawalID = uuidField({ withdrawalId: withdrawalIDValue }, "withdrawalId");
  const object = parseJsonBody(request, await readBody(request, 1024));
  exactKeys(object, ["protocolVersion", "clientRequestId"]);
  protocolVersion23(object);
  uuidField(object, "clientRequestId");
  const tokenHash = Array.from(
    await sha256(token),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
  const result = await env.DB.prepare(
    `UPDATE moment_block_withdrawals SET withdrawn_at = COALESCE(withdrawn_at, ?)
      WHERE id = ? AND token_hash = ?
        AND EXISTS (
          SELECT 1 FROM moment_spaces AS moment_space
          JOIN spaces AS space ON space.id = moment_space.space_id
          WHERE moment_space.space_id = moment_block_withdrawals.space_id
            AND moment_space.state = 'active' AND space.state = 'active'
        )
        AND (withdrawn_at IS NOT NULL OR EXISTS (
          SELECT 1 FROM moment_blocks AS block
          WHERE block.space_id = moment_block_withdrawals.space_id
            AND block.blocker_participant_id = moment_block_withdrawals.blocker_participant_id
            AND block.blocked_participant_id = moment_block_withdrawals.blocked_participant_id
            AND block.created_key_epoch = moment_block_withdrawals.created_key_epoch
            AND block.created_at = moment_block_withdrawals.created_at
            AND block.state = 'active'
        ))
      RETURNING id`
  ).bind(Math.floor(Date.now() / 1e3), withdrawalID, tokenHash).first();
  if (result === null) throw unauthorized();
  return jsonResponse({
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    block: { id: withdrawalID, state: "withdrawn" },
    sharingResumed: false
  });
}
__name(withdrawParticipantBlock, "withdrawParticipantBlock");
function reportReservationResponse(row, alreadyReported) {
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
      contentExpiresAt: row.content_expires_at
    },
    alreadyReported
  };
}
__name(reportReservationResponse, "reportReservationResponse");
function reportMatchesReservation(row, reasonCode, moderationKeyID, ciphertextSize, ciphertextSHA256) {
  return row.reason_code === reasonCode && row.moderation_key_id === moderationKeyID && row.ciphertext_size === ciphertextSize && row.ciphertext_sha256 === ciphertextSHA256;
}
__name(reportMatchesReservation, "reportMatchesReservation");
function isExpiredReportDraft(row, now) {
  return row.committed_at === null && (row.state === "expired" || row.state === "deleted" || row.upload_expires_at <= now);
}
__name(isExpiredReportDraft, "isExpiredReportDraft");
async function recordExistingReportReservation(env, member, context2, clientRequestID, requestHash, row) {
  const responseBody2 = reportReservationResponse(row, true);
  try {
    await env.DB.batch([
      ...reportNonceStatements(env, context2, member.nonce, member.now),
      reportIdempotencyStatement(
        env,
        "reserve-moment-report",
        context2,
        clientRequestID,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      reportActivityStatement(env, member)
    ]);
  } catch {
    const replayed = await replayReportResponse(
      env,
      "reserve-moment-report",
      member,
      context2,
      clientRequestID,
      requestHash
    );
    if (replayed !== null) return replayed;
    await consumeReportNonce(env, member, context2);
    throw new ApiError(409, "report_reservation_conflict", "The report could not be reserved.");
  }
  return jsonResponse(responseBody2);
}
__name(recordExistingReportReservation, "recordExistingReportReservation");
async function reserveMomentReport(request, env) {
  const { body, member, context: context2 } = await signedReportRequest(request, env);
  await requireReportIngestionRuntime(env, member, context2);
  let clientRequestID;
  let momentID;
  let reasonCode;
  let moderationKeyID;
  let ciphertextSize;
  let ciphertextSHA256;
  let reporterConsentVersion;
  let reporterConsentedAt;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, [
      "protocolVersion",
      "clientRequestId",
      "momentId",
      "reasonCode",
      "moderationKeyId",
      "ciphertextSize",
      "ciphertextSHA256",
      "reporterConsent"
    ]);
    protocolVersion23(object);
    clientRequestID = uuidField(object, "clientRequestId");
    momentID = opaqueId(stringField(object, "momentId"), "moment");
    reasonCode = oneOf(
      object,
      "reasonCode",
      ["objectionable", "harassment", "privacy", "other"]
    );
    moderationKeyID = stringField(object, "moderationKeyId");
    if (!allowedModerationKeyIDs.has(moderationKeyID)) {
      throw new ApiError(409, "moderation_key_required", "A reviewed moderation key is required.");
    }
    ciphertextSize = integerField(
      object,
      "ciphertextSize",
      minimumAEADCiphertextBytes,
      MAXIMUM_MOMENT_CIPHERTEXT_BYTES
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
    return consumeReportAndThrow(env, member, context2, error);
  }
  const requestHash = await mutationRequestHash2(request, body);
  const dedupeKey = await sha256Base64url(encodeCanonicalFields([
    "NW2.REPORT-DEDUPE",
    "2",
    context2.lineage_id,
    momentID,
    context2.participant_id
  ]));
  const latestAttempt = await loadLatestReportForReporter(
    env,
    momentID,
    context2.participant_id
  );
  const replacingExpiredDraft = latestAttempt !== null && isExpiredReportDraft(latestAttempt, member.now);
  const exactExpiredRetry = replacingExpiredDraft && latestAttempt?.reserve_request_hash === requestHash;
  if (!exactExpiredRetry) {
    const replayed = await replayReportResponse(
      env,
      "reserve-moment-report",
      member,
      context2,
      clientRequestID,
      requestHash
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
        AND moment.sender_participant_id <> ?`
  ).bind(
    momentID,
    member.spaceId,
    context2.participant_id,
    context2.participant_id
  ).first();
  if (reportable === null) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(404, "reportable_moment_not_found", "The reportable moment was not found.")
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
      LIMIT 1`
  ).bind(momentID, context2.participant_id, member.now).first();
  if (existing !== null) {
    if (!reportMatchesReservation(
      existing,
      reasonCode,
      moderationKeyID,
      ciphertextSize,
      ciphertextSHA256
    )) {
      return consumeReportAndThrow(
        env,
        member,
        context2,
        new ApiError(409, "already_reported", "This moment has already been reported.")
      );
    }
    return recordExistingReportReservation(
      env,
      member,
      context2,
      clientRequestID,
      requestHash,
      existing
    );
  }
  const tombstone = await env.DB.prepare(
    "SELECT report_id FROM moment_report_tombstones WHERE dedupe_key = ?"
  ).bind(dedupeKey).first();
  if (tombstone !== null) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(409, "already_reported", "This moment has already been reported.")
    );
  }
  let prefix;
  try {
    prefix = await storagePrefix(env, member.spaceId, member.now);
  } catch (error) {
    return consumeReportAndThrow(env, member, context2, error);
  }
  const quotaDayKey = Math.floor(member.now / 86400);
  const reportUsage = await env.DB.prepare(
    `SELECT attempt_count FROM moment_report_daily_usage
      WHERE participant_id = ? AND day_key = ?`
  ).bind(context2.participant_id, quotaDayKey).first();
  if ((reportUsage?.attempt_count ?? 0) >= REPORT_DAILY_ATTEMPT_QUOTA) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(429, "report_daily_quota_exceeded", "The daily reporting quota has been reached.")
    );
  }
  const reportID = randomBase64url(16);
  const objectKey2 = `v2/${prefix}/reports/${randomBase64url(24)}`;
  const uploadExpiresAt = member.now + MOMENT_UPLOAD_TTL_SECONDS;
  const responseBody2 = reportReservationResponse({
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
    content_expires_at: null
  }, false);
  try {
    const statements = [
      ...reportNonceStatements(env, context2, member.nonce, member.now)
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
             deleted_at = NULL`
        ).bind(
          latestAttempt.object_key,
          latestAttempt.id,
          member.now + objectDeletionGraceSeconds,
          member.now
        ));
      }
      statements.push(env.DB.prepare(
        `UPDATE moment_reports SET state = 'expired', closed_at = COALESCE(closed_at, ?)
          WHERE id = ? AND committed_at IS NULL
            AND state IN ('reserved', 'uploaded') AND upload_expires_at <= ?`
      ).bind(member.now, latestAttempt.id, member.now));
      if (exactExpiredRetry) {
        statements.push(env.DB.prepare(
          `DELETE FROM moment_report_idempotency_records
            WHERE operation = 'reserve-moment-report' AND actor_device_id = ?
              AND client_request_id = ? AND request_hash = ?`
        ).bind(context2.device_id, clientRequestID, requestHash));
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
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        reportID,
        momentID,
        member.spaceId,
        context2.lineage_id,
        context2.participant_id,
        context2.device_id,
        reportable.accused_participant_id,
        reasonCode,
        moderationKeyID,
        objectKey2,
        ciphertextSize,
        ciphertextSHA256,
        reporterConsentVersion,
        reporterConsentedAt,
        quotaDayKey,
        requestHash,
        dedupeKey,
        member.now,
        uploadExpiresAt
      ),
      reportIdempotencyStatement(
        env,
        "reserve-moment-report",
        context2,
        clientRequestID,
        requestHash,
        201,
        responseBody2,
        member.now
      ),
      reportActivityStatement(env, member)
    );
    await env.DB.batch(statements);
  } catch {
    const raced = await replayReportResponse(
      env,
      "reserve-moment-report",
      member,
      context2,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    const concurrent = await loadReportForReporter(
      env,
      momentID,
      context2.participant_id
    );
    if (concurrent !== null && reportMatchesReservation(
      concurrent,
      reasonCode,
      moderationKeyID,
      ciphertextSize,
      ciphertextSHA256
    )) {
      return recordExistingReportReservation(
        env,
        member,
        context2,
        clientRequestID,
        requestHash,
        concurrent
      );
    }
    const currentUsage = await env.DB.prepare(
      `SELECT attempt_count FROM moment_report_daily_usage
        WHERE participant_id = ? AND day_key = ?`
    ).bind(context2.participant_id, quotaDayKey).first();
    await consumeReportNonce(env, member, context2);
    if ((currentUsage?.attempt_count ?? 0) >= REPORT_DAILY_ATTEMPT_QUOTA) {
      throw new ApiError(429, "report_daily_quota_exceeded", "The daily reporting quota has been reached.");
    }
    throw new ApiError(409, "report_reservation_conflict", "The report could not be reserved.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(reserveMomentReport, "reserveMomentReport");
async function loadReport(env, reportID) {
  return env.DB.prepare(
    `SELECT id, moment_id, space_id, reporter_participant_id,
            reporter_device_id, accused_participant_id, reason_code,
            moderation_key_id, state, object_key,
            ciphertext_size, ciphertext_sha256, dedupe_key, reserve_request_hash, created_at,
            upload_expires_at, uploaded_at, committed_at,
            content_expires_at, closed_at
       FROM moment_reports WHERE id = ?`
  ).bind(reportID).first();
}
__name(loadReport, "loadReport");
async function loadReportForReporter(env, momentID, reporterParticipantID) {
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
      LIMIT 1`
  ).bind(momentID, reporterParticipantID).first();
}
__name(loadReportForReporter, "loadReportForReporter");
async function loadLatestReportForReporter(env, momentID, reporterParticipantID) {
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
      LIMIT 1`
  ).bind(momentID, reporterParticipantID).first();
}
__name(loadLatestReportForReporter, "loadLatestReportForReporter");
function requireReporterReport(row, member, context2) {
  if (row === null || row.space_id !== member.spaceId || row.reporter_participant_id !== context2.participant_id || row.reporter_device_id !== context2.device_id) {
    throw new ApiError(404, "report_not_found", "The report was not found.");
  }
}
__name(requireReporterReport, "requireReporterReport");
async function uploadMomentReportCiphertext(request, env, reportIDValue) {
  const reportID = opaqueId(reportIDValue, "report");
  requireOctetStream(request);
  const { body, member, context: context2 } = await signedReportRequest(
    request,
    env,
    MAXIMUM_MOMENT_CIPHERTEXT_BYTES
  );
  await requireReportIngestionRuntime(env, member, context2);
  const bucket = requireModerationBucket(env);
  if (body.length < minimumAEADCiphertextBytes) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(400, "ciphertext_too_small", "The ciphertext is too small.")
    );
  }
  const [row, digestBytes, digestValue] = await Promise.all([
    loadReport(env, reportID),
    sha256(body),
    sha256Base64url(body)
  ]);
  try {
    requireReporterReport(row, member, context2);
  } catch (error) {
    return consumeReportAndThrow(env, member, context2, error);
  }
  if (isExpiredReportDraft(row, member.now)) {
    await consumeReportNonce(env, member, context2);
    if (row.state !== "deleted") {
      await queueObjectDeletion(env, row.object_key, "report", row.id, member.now);
    }
    throw new ApiError(
      410,
      "reservation_expired",
      "This report reservation expired; reserve the report again before uploading."
    );
  }
  if (row.ciphertext_size !== body.length || row.ciphertext_sha256 !== digestValue) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(409, "ciphertext_descriptor_mismatch", "Ciphertext does not match its reservation.")
    );
  }
  const responseBody2 = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    reportId: reportID,
    state: "uploaded",
    ciphertextSize: body.length,
    ciphertextSHA256: digestValue
  };
  if (row.state === "uploaded" || row.state === "committed") {
    await consumeReportNonce(env, member, context2);
    const head = await bucket.head(row.object_key);
    if (head === null || head.size !== body.length || r2Checksum(head) !== digestValue) {
      throw new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable.");
    }
    await reportActivityStatement(env, member).run();
    return jsonResponse(responseBody2);
  }
  if (row.state !== "reserved" || row.upload_expires_at <= member.now) {
    await consumeReportNonce(env, member, context2);
    await queueObjectDeletion(env, row.object_key, "report", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This report no longer accepts ciphertext uploads.");
  }
  await consumeReportNonce(env, member, context2);
  await ensureR2Object(bucket, row.object_key, body, digestBytes, digestValue);
  const updated = await env.DB.prepare(
    `UPDATE moment_reports SET state = 'uploaded', uploaded_at = ?
      WHERE id = ? AND state = 'reserved' AND upload_expires_at > ?`
  ).bind(member.now, reportID, member.now).run();
  if (updated.meta.changes !== 1) {
    const raced = await loadReport(env, reportID);
    if (raced !== null && (raced.state === "uploaded" || raced.state === "committed") && raced.ciphertext_size === body.length && raced.ciphertext_sha256 === digestValue) {
      const head = await bucket.head(raced.object_key);
      if (head !== null && head.size === body.length && r2Checksum(head) === digestValue) {
        await reportActivityStatement(env, member).run();
        return jsonResponse(responseBody2);
      }
    }
    await queueObjectDeletion(env, row.object_key, "report", row.id, member.now);
    throw new ApiError(409, "upload_closed", "This report no longer accepts ciphertext uploads.");
  }
  await reportActivityStatement(env, member).run();
  return jsonResponse(responseBody2);
}
__name(uploadMomentReportCiphertext, "uploadMomentReportCiphertext");
async function commitMomentReport(request, env, reportIDValue) {
  const reportID = opaqueId(reportIDValue, "report");
  const { body, member, context: context2 } = await signedReportRequest(request, env);
  await requireReportIngestionRuntime(env, member, context2);
  const bucket = requireModerationBucket(env);
  let clientRequestID;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId"]);
    protocolVersion23(object);
    clientRequestID = uuidField(object, "clientRequestId");
  } catch (error) {
    return consumeReportAndThrow(env, member, context2, error);
  }
  const requestHash = await mutationRequestHash2(request, body);
  const replayed = await replayReportResponse(
    env,
    "commit-moment-report",
    member,
    context2,
    clientRequestID,
    requestHash
  );
  if (replayed !== null) return replayed;
  const row = await loadReport(env, reportID);
  try {
    requireReporterReport(row, member, context2);
  } catch (error) {
    return consumeReportAndThrow(env, member, context2, error);
  }
  if (isExpiredReportDraft(row, member.now)) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(
        410,
        "reservation_expired",
        "This report reservation expired; reserve the report again before committing."
      )
    );
  }
  if (row.state === "committed" && row.committed_at !== null && row.content_expires_at !== null) {
    const responseBody3 = {
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      report: {
        id: reportID,
        momentId: row.moment_id,
        state: "committed",
        committedAt: row.committed_at,
        contentExpiresAt: row.content_expires_at
      }
    };
    try {
      await env.DB.batch([
        ...reportNonceStatements(env, context2, member.nonce, member.now),
        reportIdempotencyStatement(
          env,
          "commit-moment-report",
          context2,
          clientRequestID,
          requestHash,
          201,
          responseBody3,
          member.now
        ),
        reportActivityStatement(env, member)
      ]);
    } catch {
      const raced = await replayReportResponse(
        env,
        "commit-moment-report",
        member,
        context2,
        clientRequestID,
        requestHash
      );
      if (raced !== null) return raced;
      await consumeReportNonce(env, member, context2);
      throw new ApiError(409, "report_commit_conflict", "The report could not be committed.");
    }
    return jsonResponse(responseBody3, 201);
  }
  if (row.state !== "uploaded" || row.upload_expires_at <= member.now) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(409, "report_not_ready", "The report is not ready to commit.")
    );
  }
  const head = await bucket.head(row.object_key);
  if (head === null || head.size !== row.ciphertext_size || r2Checksum(head) !== row.ciphertext_sha256) {
    return consumeReportAndThrow(
      env,
      member,
      context2,
      new ApiError(503, "stored_object_unavailable", "Uploaded ciphertext is temporarily unavailable.")
    );
  }
  const contentExpiresAt = member.now + REPORT_CONTENT_TTL_SECONDS;
  const responseBody2 = {
    protocolVersion: MOMENT_PROTOCOL_VERSION,
    report: {
      id: reportID,
      momentId: row.moment_id,
      state: "committed",
      committedAt: member.now,
      contentExpiresAt
    }
  };
  const commitEventID = randomBase64url(16);
  try {
    await env.DB.batch([
      ...reportNonceStatements(env, context2, member.nonce, member.now),
      env.DB.prepare(
        `INSERT INTO moment_report_commit_events(
           id, report_id, reporter_participant_id, committed_at, content_expires_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        commitEventID,
        reportID,
        context2.participant_id,
        member.now,
        contentExpiresAt
      ),
      env.DB.prepare("DELETE FROM moment_report_commit_events WHERE id = ?").bind(commitEventID),
      reportIdempotencyStatement(
        env,
        "commit-moment-report",
        context2,
        clientRequestID,
        requestHash,
        201,
        responseBody2,
        member.now
      ),
      reportActivityStatement(env, member)
    ]);
  } catch {
    const raced = await replayReportResponse(
      env,
      "commit-moment-report",
      member,
      context2,
      clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    await consumeReportNonce(env, member, context2);
    throw new ApiError(409, "report_commit_conflict", "The report could not be committed.");
  }
  return jsonResponse(responseBody2, 201);
}
__name(commitMomentReport, "commitMomentReport");
async function sweepRevokedV2Prefix(env, scope, objectType, now) {
  const bucket = objectType === "moment" ? env.MEDIA : env.MODERATION_MEDIA;
  if (bucket === void 0) return;
  const plural = objectType === "moment" ? "moments" : "reports";
  const objects = await bucket.list({
    prefix: `v2/${scope.object_prefix}/${plural}/`,
    limit: 1e3
  });
  const emptyColumn = objectType === "moment" ? "moment_empty_sweep_started_at" : "report_empty_sweep_started_at";
  const completedColumn = objectType === "moment" ? "moment_sweep_completed_at" : "report_sweep_completed_at";
  if (objects.objects.length > 0) {
    await bucket.delete(objects.objects.map((object) => object.key));
    await env.DB.prepare(
      `UPDATE moment_storage_scopes
          SET ${emptyColumn} = NULL, last_sweep_at = ?, sweep_count = sweep_count + 1
        WHERE space_id = ? AND ${completedColumn} IS NULL`
    ).bind(now, scope.space_id).run();
    return;
  }
  const emptyStartedAt = objectType === "moment" ? scope.moment_empty_sweep_started_at : scope.report_empty_sweep_started_at;
  if (emptyStartedAt === null) {
    await env.DB.prepare(
      `UPDATE moment_storage_scopes
          SET ${emptyColumn} = ?, last_sweep_at = ?, sweep_count = sweep_count + 1
        WHERE space_id = ? AND ${completedColumn} IS NULL`
    ).bind(now, now, scope.space_id).run();
  } else if (now - emptyStartedAt >= 60) {
    if (objectType === "report") {
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
              )`
        ).bind(now, now, scope.space_id, emptyStartedAt, now - 600),
        env.DB.prepare(
          `UPDATE moment_reports SET state = 'deleted', closed_at = ?
            WHERE space_id = ? AND state = 'expired'
              AND EXISTS (
                SELECT 1 FROM moment_storage_scopes AS storage
                 WHERE storage.space_id = moment_reports.space_id
                   AND storage.report_empty_sweep_started_at = ?
                   AND storage.report_sweep_completed_at = ?
              )`
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
            )`
        ).bind(now, scope.space_id, emptyStartedAt, now)
      ]);
    } else {
      await env.DB.prepare(
        `UPDATE moment_storage_scopes
            SET moment_sweep_completed_at = ?, last_sweep_at = ?,
                sweep_count = sweep_count + 1
          WHERE space_id = ? AND moment_sweep_completed_at IS NULL
            AND moment_empty_sweep_started_at = ?`
      ).bind(now, now, scope.space_id, emptyStartedAt).run();
    }
  }
}
__name(sweepRevokedV2Prefix, "sweepRevokedV2Prefix");
async function processRevokedV2Scopes(env, now) {
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
      LIMIT ?`
  ).bind(now, MOMENT_REVOKED_SCOPE_LIMIT).all();
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
      LIMIT ?`
  ).bind(now, now - 600, MOMENT_REVOKED_SCOPE_LIMIT).all();
  for (const scope of reportScopes.results) {
    await sweepRevokedV2Prefix(env, scope, "report", now);
  }
}
__name(processRevokedV2Scopes, "processRevokedV2Scopes");
async function purgeRevokedV2Spaces(env, now) {
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
      LIMIT 10`
  ).bind(now).all();
  if (rows.results.length === 0) return;
  const statements = [];
  for (const row of rows.results) {
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
          )`
    ).bind(row.space_id, now));
    if (row.object_prefix !== null) {
      const prefix = `v2/${row.object_prefix}/`;
      statements.push(env.DB.prepare(
        `DELETE FROM moment_object_deletions
          WHERE object_key >= ? AND object_key < ?
            AND NOT EXISTS (
              SELECT 1 FROM moment_spaces WHERE space_id = ?
            )`
      ).bind(prefix, `${prefix}\uFFFF`, row.space_id));
    }
  }
  await env.DB.batch(statements);
}
__name(purgeRevokedV2Spaces, "purgeRevokedV2Spaces");
async function runMomentCleanup(env, now = Math.floor(Date.now() / 1e3)) {
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM moment_report_request_nonces
        WHERE rowid IN (
          SELECT rowid FROM moment_report_request_nonces
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, device_id ASC, nonce ASC LIMIT ?
        )`
    ).bind(now, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_report_idempotency_records
        WHERE rowid IN (
          SELECT rowid FROM moment_report_idempotency_records
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, actor_device_id ASC, operation ASC,
                    client_request_id ASC LIMIT ?
        )`
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
        )`
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
         deleted_at = NULL`
    ).bind(now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moments SET state = 'expired', closed_at = ?
        WHERE id IN (
          SELECT id FROM moments
           WHERE state IN ('reserved', 'uploaded') AND upload_expires_at <= ?
           ORDER BY upload_expires_at ASC, id ASC LIMIT ?
        )`
    ).bind(now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moment_deliveries SET state = 'expired'
        WHERE (moment_id, recipient_participant_id) IN (
          SELECT moment_id, recipient_participant_id
            FROM moment_deliveries
           WHERE state IN ('pending', 'acknowledged') AND access_expires_at <= ?
           ORDER BY access_expires_at ASC, moment_id ASC, recipient_participant_id ASC
           LIMIT ?
        )`
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
         deleted_at = NULL`
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
        )`
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
         deleted_at = NULL`
    ).bind(now, now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `UPDATE moment_reports SET state = 'expired', closed_at = ?
        WHERE id IN (
          SELECT id FROM moment_reports
           WHERE (state IN ('reserved', 'uploaded') AND upload_expires_at <= ?)
              OR (state = 'committed' AND content_expires_at <= ?)
           ORDER BY created_at ASC, id ASC LIMIT ?
        )`
    ).bind(now, now, now, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_reports
        WHERE id IN (
          SELECT id FROM moment_reports
           WHERE state = 'deleted' AND committed_at IS NULL
             AND closed_at IS NOT NULL AND closed_at <= ?
           ORDER BY closed_at ASC, id ASC LIMIT ?
        )`
    ).bind(now - 172800, cleanupRowLimit),
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
        )`
    ).bind(now - 172800, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_report_daily_usage
        WHERE rowid IN (
          SELECT rowid FROM moment_report_daily_usage
           WHERE day_key < ?
           ORDER BY day_key ASC, participant_id ASC LIMIT ?
        )`
    ).bind(Math.floor(now / 86400) - 90, cleanupRowLimit),
    env.DB.prepare(
      `DELETE FROM moment_reaction_daily_usage
        WHERE rowid IN (
          SELECT rowid FROM moment_reaction_daily_usage
           WHERE day_key < ?
           ORDER BY day_key ASC, participant_id ASC LIMIT ?
        )`
    ).bind(
      Math.floor(now / 86400) - REACTION_USAGE_RETENTION_DAYS,
      cleanupRowLimit
    )
  ]);
  if (env.MEDIA === void 0 && env.MODERATION_MEDIA === void 0) return;
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
      LIMIT ?`
  ).bind(
    now,
    env.MEDIA === void 0 ? 0 : 1,
    env.MODERATION_MEDIA === void 0 ? 0 : 1,
    MOMENT_CLEANUP_OBJECT_LIMIT
  ).all();
  if (deletions.results.length > 0) {
    const momentObjects = deletions.results.filter((row) => row.object_type === "moment").map((row) => row.object_key);
    const reportObjects = deletions.results.filter((row) => row.object_type === "report").map((row) => row.object_key);
    if (momentObjects.length > 0) await env.MEDIA?.delete(momentObjects);
    if (reportObjects.length > 0) await env.MODERATION_MEDIA?.delete(reportObjects);
    const statements = [];
    const momentOwnerIDs = deletions.results.filter((row) => row.object_type === "moment").map((row) => row.owner_id);
    const reportOwnerIDs = deletions.results.filter((row) => row.object_type === "report").map((row) => row.owner_id);
    for (let offset = 0; offset < momentOwnerIDs.length; offset += d1IdentifierChunkSize) {
      const ids = momentOwnerIDs.slice(offset, offset + d1IdentifierChunkSize);
      const placeholders2 = ids.map(() => "?").join(", ");
      statements.push(env.DB.prepare(
        `UPDATE moments SET state = 'deleted', closed_at = COALESCE(closed_at, ?)
          WHERE id IN (${placeholders2}) AND state = 'expired'`
      ).bind(now, ...ids));
    }
    for (let offset = 0; offset < reportOwnerIDs.length; offset += d1IdentifierChunkSize) {
      const ids = reportOwnerIDs.slice(offset, offset + d1IdentifierChunkSize);
      const placeholders2 = ids.map(() => "?").join(", ");
      statements.push(env.DB.prepare(
        `UPDATE moment_reports SET state = 'deleted', closed_at = ?
          WHERE id IN (${placeholders2}) AND state = 'expired'`
      ).bind(now, ...ids));
    }
    for (let offset = 0; offset < deletions.results.length; offset += d1CASTupleChunkSize) {
      const rows = deletions.results.slice(offset, offset + d1CASTupleChunkSize);
      const tuples = rows.map(() => "(?, ?)").join(", ");
      statements.push(env.DB.prepare(
        `DELETE FROM moment_object_deletions
          WHERE state = 'pending' AND (object_key, attempts) IN (${tuples})`
      ).bind(...rows.flatMap((row) => [row.object_key, row.attempts])));
    }
    if (statements.length > 0) {
      await env.DB.batch(statements);
    }
  }
  await processRevokedV2Scopes(env, now);
  await purgeRevokedV2Spaces(env, now);
}
__name(runMomentCleanup, "runMomentCleanup");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/scheduled.ts
var CLEANUP_SPACE_LIMIT = 90;
var CLEANUP_NONCE_LIMIT = 1e4;
var CLEANUP_NONCE_CHUNK_SIZE = 2e3;
var CLEANUP_IDEMPOTENCY_LIMIT = 2500;
var CLEANUP_IDEMPOTENCY_CHUNK_SIZE = 500;
var CLEANUP_DAILY_FREEZE_LIMIT = 1e3;
var CLEANUP_DAILY_FREEZE_CHUNK_SIZE = 500;
var CLEANUP_GENERATION_CLOSE_LIMIT = 1e4;
var CLEANUP_GENERATION_CHUNK_SIZE = 100;
var CLEANUP_TERMINAL_GENERATION_LIMIT = 1e3;
var CLEANUP_SOURCE_UNBLOCK_LIMIT = 1e3;
var CLEANUP_FINALIZE_CHUNK_SIZE = 250;
var CLEANUP_OBJECT_LIMIT = 24e3;
var CLEANUP_REVOKED_SCOPE_LIMIT = 50;
var R2_PREFIX_LIST_LIMIT = 1e3;
var R2_DELETE_BATCH_SIZE = 1e3;
var LEGACY_CLEANUP_CRON = "*/5 * * * *";
var MOMENT_CLEANUP_CRON = "2,7,12,17,22,27,32,37,42,47,52,57 * * * *";
var OBJECT_DELETE_CAS_TUPLE_LIMIT = 48;
var UPLOAD_CLOSE_GRACE_SECONDS = 600;
var EMPTY_PREFIX_CONFIRM_SECONDS = 60;
var PAIRING_EXPIRY_CANDIDATES_SQL = `
  WITH
  expired_invitations AS MATERIALIZED (
    SELECT space_id, expires_at
      FROM invitations INDEXED BY open_invitations_expiry
     WHERE status = 'open' AND expires_at <= ?
     ORDER BY expires_at ASC, space_id ASC
     LIMIT ?
  ),
  expired_enrollments AS MATERIALIZED (
    SELECT space_id, expires_at
      FROM enrollments INDEXED BY live_enrollments_expiry
     WHERE state IN ('pending', 'approved') AND expires_at <= ?
     ORDER BY expires_at ASC, space_id ASC
     LIMIT ?
  ),
  expired_challenges AS MATERIALIZED (
    SELECT i.space_id, c.expires_at
      FROM invitation_challenges AS c INDEXED BY live_invitation_challenges_expiry
      JOIN invitations AS i ON i.id = c.invitation_id
     WHERE c.consumed_at IS NULL AND c.expires_at <= ?
     ORDER BY c.expires_at ASC, c.invitation_id ASC
     LIMIT ?
  ),
  bounded_candidates AS (
    SELECT space_id, expires_at FROM expired_invitations
    UNION ALL
    SELECT space_id, expires_at FROM expired_enrollments
    UNION ALL
    SELECT space_id, expires_at FROM expired_challenges
  )
  SELECT space_id AS id, MIN(expires_at) AS oldest_expiry
    FROM bounded_candidates
   GROUP BY space_id
   ORDER BY oldest_expiry ASC, space_id ASC
   LIMIT ?`;
function placeholders(count) {
  return Array.from({ length: count }, () => "?").join(", ");
}
__name(placeholders, "placeholders");
async function runOldestFirstChunks(capacity, chunkSize, runChunk) {
  let remaining = capacity;
  while (remaining > 0) {
    const limit = Math.min(chunkSize, remaining);
    const result = await runChunk(limit);
    if (result.meta.changes === 0) return;
    remaining -= limit;
  }
}
__name(runOldestFirstChunks, "runOldestFirstChunks");
async function pairingExpiryCandidates(env, now) {
  const result = await env.DB.prepare(PAIRING_EXPIRY_CANDIDATES_SQL).bind(
    now,
    CLEANUP_SPACE_LIMIT,
    now,
    CLEANUP_SPACE_LIMIT,
    now,
    CLEANUP_SPACE_LIMIT,
    CLEANUP_SPACE_LIMIT
  ).all();
  return result.results.map((row) => row.id);
}
__name(pairingExpiryCandidates, "pairingExpiryCandidates");
async function pendingDeletionCandidates(env) {
  const result = await env.DB.prepare(
    `SELECT space_id AS id
       FROM space_deletion_jobs
      WHERE state = 'pending'
      ORDER BY created_at ASC, space_id ASC
      LIMIT ?`
  ).bind(CLEANUP_SPACE_LIMIT).all();
  return result.results.map((row) => row.id);
}
__name(pendingDeletionCandidates, "pendingDeletionCandidates");
async function inactiveSpaceCandidates(env, now) {
  const result = await env.DB.prepare(
    `SELECT id
       FROM spaces
      WHERE state = 'active' AND metadata_expires_at <= ?
      ORDER BY metadata_expires_at ASC, id ASC
      LIMIT ?`
  ).bind(now, CLEANUP_SPACE_LIMIT).all();
  return result.results.map((row) => row.id);
}
__name(inactiveSpaceCandidates, "inactiveSpaceCandidates");
async function revokeAndPurgeSpaces(env, spaceIds, now, markInactive) {
  if (spaceIds.length === 0) return;
  const ids = [...spaceIds];
  const inList = placeholders(ids.length);
  const statements = [];
  if (markInactive) {
    statements.push(
      env.DB.prepare(
        `UPDATE spaces
            SET state = 'revoked', revoked_at = ?
          WHERE id IN (${inList})
            AND state = 'active'
            AND metadata_expires_at <= ?`
      ).bind(now, ...ids, now),
      env.DB.prepare(
        `INSERT INTO space_deletion_jobs(
           space_id, state, requires_object_deletion, created_at
         )
         SELECT id, 'pending',
                CASE WHEN EXISTS (
                  SELECT 1 FROM sharing_storage_scopes AS storage
                   WHERE storage.space_id = spaces.id
                ) THEN 1 ELSE 0 END,
                ?
           FROM spaces
          WHERE id IN (${inList})
            AND state = 'revoked'
            AND revoked_at = ?
         ON CONFLICT(space_id) DO UPDATE SET
           state = 'pending',
           requires_object_deletion = MAX(
             space_deletion_jobs.requires_object_deletion,
             excluded.requires_object_deletion
           ),
           created_at = excluded.created_at,
           completed_at = NULL,
           empty_sweep_started_at = NULL,
           last_sweep_at = NULL,
           sweep_count = 0`
      ).bind(now, ...ids, now)
    );
  }
  statements.push(
    env.DB.prepare(
      `UPDATE sharing_sources
          SET state = 'revoked', updated_at = ?
        WHERE space_id IN (${inList})
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = sharing_sources.space_id AND j.state = 'pending'
          )`
    ).bind(now, ...ids),
    env.DB.prepare(
      `UPDATE members
          SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?)
        WHERE space_id IN (${inList})
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = members.space_id AND j.state = 'pending'
          )`
    ).bind(now, ...ids),
    env.DB.prepare(
      `UPDATE invitations
          SET status = 'revoked', invite_proof_public_key = NULL
        WHERE space_id IN (${inList})
          AND status = 'open'
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = invitations.space_id AND j.state = 'pending'
          )`
    ).bind(...ids),
    env.DB.prepare(
      `UPDATE enrollments
          SET state = 'revoked'
        WHERE space_id IN (${inList})
          AND state IN ('pending', 'approved')
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = enrollments.space_id AND j.state = 'pending'
          )`
    ).bind(...ids),
    env.DB.prepare(
      `UPDATE approval_events
          SET key_envelope = NULL, approval_signature = NULL
        WHERE enrollment_id IN (
          SELECT e.id
            FROM enrollments AS e
            JOIN space_deletion_jobs AS j ON j.space_id = e.space_id
           WHERE e.space_id IN (${inList}) AND j.state = 'pending'
        )`
    ).bind(...ids),
    env.DB.prepare(
      `DELETE FROM invitation_challenges
        WHERE invitation_id IN (
          SELECT i.id
            FROM invitations AS i
            JOIN space_deletion_jobs AS j ON j.space_id = i.space_id
           WHERE i.space_id IN (${inList}) AND j.state = 'pending'
        )`
    ).bind(...ids),
    env.DB.prepare(
      `DELETE FROM spaces
        WHERE id IN (${inList})
          AND state = 'revoked'
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = spaces.id
               AND j.state = 'pending'
               AND j.requires_object_deletion = 0
          )`
    ).bind(...ids),
    env.DB.prepare(
      `DELETE FROM space_deletion_jobs
        WHERE space_id IN (${inList})
          AND state = 'pending'
          AND requires_object_deletion = 0
          AND NOT EXISTS (
            SELECT 1 FROM spaces WHERE spaces.id = space_deletion_jobs.space_id
          )`
    ).bind(...ids)
  );
  await env.DB.batch(statements);
}
__name(revokeAndPurgeSpaces, "revokeAndPurgeSpaces");
async function closeExpiredSharingGenerations(env, now) {
  await runOldestFirstChunks(
    CLEANUP_GENERATION_CLOSE_LIMIT,
    CLEANUP_GENERATION_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `INSERT INTO sharing_close_events(generation_id, reason, created_at)
       SELECT id, 'staging_expired', ?
         FROM sharing_generations INDEXED BY sharing_generations_staging_expiry
        WHERE state IN ('reserved', 'uploading', 'prepared')
          AND staging_expires_at <= ?
        ORDER BY staging_expires_at ASC, id ASC
        LIMIT ?`
    ).bind(now, now, limit).run()
  );
  await runOldestFirstChunks(
    CLEANUP_GENERATION_CLOSE_LIMIT,
    CLEANUP_GENERATION_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `INSERT INTO sharing_close_events(generation_id, reason, created_at)
       SELECT g.id, 'content_expired', ?
         FROM sharing_generations AS g INDEXED BY sharing_generations_content_expiry
         JOIN sharing_currents AS current ON current.generation_id = g.id
        WHERE g.state = 'committed' AND g.content_expires_at <= ?
        ORDER BY g.content_expires_at ASC, g.id ASC
        LIMIT ?`
    ).bind(now, now, limit).run()
  );
}
__name(closeExpiredSharingGenerations, "closeExpiredSharingGenerations");
async function processExplicitObjectDeletions(env, now) {
  if (env.MEDIA === void 0) return;
  let remaining = CLEANUP_OBJECT_LIMIT;
  while (remaining > 0) {
    const batchSize = Math.min(R2_DELETE_BATCH_SIZE, remaining);
    const rows = await env.DB.prepare(
      `SELECT object_key, attempts
         FROM sharing_object_deletions
        WHERE state = 'pending' AND not_before <= ?
        ORDER BY not_before ASC, created_at ASC, object_key ASC
        LIMIT ?`
    ).bind(now, batchSize).all();
    if (rows.results.length === 0) return;
    await env.MEDIA.delete(rows.results.map((row) => row.object_key));
    const statements = [];
    for (let offset = 0; offset < rows.results.length; offset += OBJECT_DELETE_CAS_TUPLE_LIMIT) {
      const chunk = rows.results.slice(offset, offset + OBJECT_DELETE_CAS_TUPLE_LIMIT);
      const tuples = chunk.map(() => "(?, ?)").join(", ");
      statements.push(env.DB.prepare(
        `DELETE FROM sharing_object_deletions
          WHERE state = 'pending'
            AND (object_key, attempts) IN (${tuples})`
      ).bind(...chunk.flatMap((row) => [row.object_key, row.attempts])));
    }
    await env.DB.batch(statements);
    remaining -= rows.results.length;
    if (rows.results.length < batchSize) return;
  }
}
__name(processExplicitObjectDeletions, "processExplicitObjectDeletions");
async function processRevokedStorageScopes(env, now) {
  if (env.MEDIA === void 0) return;
  const jobs = await env.DB.prepare(
    `SELECT job.space_id, storage.object_prefix, job.created_at,
            job.empty_sweep_started_at
       FROM space_deletion_jobs AS job
       JOIN sharing_storage_scopes AS storage ON storage.space_id = job.space_id
      WHERE job.state = 'pending' AND job.requires_object_deletion = 1
        AND job.created_at + ? <= ?
      ORDER BY job.created_at ASC, job.space_id ASC
      LIMIT ?`
  ).bind(UPLOAD_CLOSE_GRACE_SECONDS, now, CLEANUP_REVOKED_SCOPE_LIMIT).all();
  if (jobs.results.length === 0) return;
  const jobSpaceIds = jobs.results.map((job) => job.space_id);
  const inList = placeholders(jobSpaceIds.length);
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE sharing_generations
          SET state = 'expired', closed_at = COALESCE(closed_at, ?)
        WHERE space_id IN (${inList})
          AND state IN ('reserved', 'uploading', 'prepared', 'committed')
          AND EXISTS (
            SELECT 1 FROM space_deletion_jobs AS job
             WHERE job.space_id = sharing_generations.space_id
               AND job.state = 'pending' AND job.requires_object_deletion = 1
          )`
    ).bind(now, ...jobSpaceIds),
    env.DB.prepare(
      `DELETE FROM sharing_currents
        WHERE source_id IN (
          SELECT source.id
            FROM sharing_sources AS source
            JOIN space_deletion_jobs AS job ON job.space_id = source.space_id
           WHERE source.space_id IN (${inList})
             AND job.state = 'pending' AND job.requires_object_deletion = 1
        )`
    ).bind(...jobSpaceIds)
  ]);
  for (const job of jobs.results) {
    const prefix = `v1/${job.object_prefix}/`;
    const objects = await env.MEDIA.list({ prefix, limit: R2_PREFIX_LIST_LIMIT });
    if (objects.objects.length > 0) {
      await env.MEDIA.delete(objects.objects.map((object) => object.key));
      await env.DB.prepare(
        `UPDATE space_deletion_jobs
            SET empty_sweep_started_at = NULL, last_sweep_at = ?,
                sweep_count = sweep_count + 1
          WHERE space_id = ? AND state = 'pending'`
      ).bind(now, job.space_id).run();
      continue;
    }
    if (job.empty_sweep_started_at === null) {
      await env.DB.prepare(
        `UPDATE space_deletion_jobs
            SET empty_sweep_started_at = ?, last_sweep_at = ?,
                sweep_count = sweep_count + 1
          WHERE space_id = ? AND state = 'pending'`
      ).bind(now, now, job.space_id).run();
      continue;
    }
    if (now - job.empty_sweep_started_at >= EMPTY_PREFIX_CONFIRM_SECONDS) {
      await env.DB.batch([
        env.DB.prepare(
          "DELETE FROM sharing_object_deletions WHERE space_id = ?"
        ).bind(job.space_id),
        env.DB.prepare(
          `UPDATE space_deletion_jobs
              SET requires_object_deletion = 0, last_sweep_at = ?,
                  sweep_count = sweep_count + 1
            WHERE space_id = ? AND state = 'pending'`
        ).bind(now, job.space_id)
      ]);
    }
  }
}
__name(processRevokedStorageScopes, "processRevokedStorageScopes");
async function finalizeNormalSharingCleanup(env, now) {
  await runOldestFirstChunks(
    CLEANUP_TERMINAL_GENERATION_LIMIT,
    CLEANUP_FINALIZE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM sharing_generations
        WHERE id IN (
          WITH terminal_candidates AS MATERIALIZED (
            SELECT id, manifest_object_key
              FROM sharing_generations INDEXED BY sharing_generations_terminal_cleanup
             WHERE state IN ('superseded', 'expired') AND closed_at IS NOT NULL
             ORDER BY closed_at ASC, id ASC
             LIMIT ?
          )
          SELECT candidate.id
            FROM terminal_candidates AS candidate
           WHERE NOT EXISTS (
               SELECT 1
                 FROM sharing_object_deletions AS deletion
                WHERE deletion.object_key = candidate.manifest_object_key
                   OR deletion.object_key IN (
                     SELECT object_key FROM sharing_generation_media
                      WHERE generation_id = candidate.id
                   )
             )
        )`
    ).bind(limit).run()
  );
  await runOldestFirstChunks(
    CLEANUP_SOURCE_UNBLOCK_LIMIT,
    CLEANUP_FINALIZE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `UPDATE sharing_sources
          SET cleanup_blocked = 0, updated_at = ?
        WHERE id IN (
          WITH blocked_candidates AS MATERIALIZED (
            SELECT id
              FROM sharing_sources INDEXED BY sharing_sources_cleanup
             WHERE cleanup_blocked = 1 AND state = 'active'
             ORDER BY updated_at ASC, id ASC
             LIMIT ?
          )
          SELECT candidate.id
            FROM blocked_candidates AS candidate
           WHERE NOT EXISTS (
               SELECT 1 FROM sharing_object_deletions AS deletion
                WHERE deletion.source_id = candidate.id AND deletion.state = 'pending'
             )
        )`
    ).bind(now, limit).run()
  );
}
__name(finalizeNormalSharingCleanup, "finalizeNormalSharingCleanup");
async function cleanupEphemeralRows(env, now) {
  await runOldestFirstChunks(
    CLEANUP_NONCE_LIMIT,
    CLEANUP_NONCE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM request_nonces
        WHERE rowid IN (
          SELECT rowid
            FROM request_nonces
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, member_id ASC, nonce ASC
           LIMIT ?
        )`
    ).bind(now, limit).run()
  );
  await runOldestFirstChunks(
    CLEANUP_IDEMPOTENCY_LIMIT,
    CLEANUP_IDEMPOTENCY_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM idempotency_records
        WHERE rowid IN (
          SELECT rowid
            FROM idempotency_records
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, operation ASC, actor_id ASC, client_request_id ASC
           LIMIT ?
        )`
    ).bind(now, limit).run()
  );
  await runOldestFirstChunks(
    CLEANUP_DAILY_FREEZE_LIMIT,
    CLEANUP_DAILY_FREEZE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM sharing_daily_freezes
        WHERE rowid IN (
          SELECT rowid
            FROM sharing_daily_freezes
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, source_id ASC, share_day_key ASC
           LIMIT ?
        )`
    ).bind(now, limit).run()
  );
}
__name(cleanupEphemeralRows, "cleanupEphemeralRows");
async function runLegacyScheduledCleanup(env, now = Math.floor(Date.now() / 1e3)) {
  await cleanupEphemeralRows(env, now);
  await expireDeviceRecoveries(env, now);
  const pairingSpaceIds = await pairingExpiryCandidates(env, now);
  await expireStalePairingState(env, now, { spaceIds: pairingSpaceIds });
  const inactiveSpaceIds = await inactiveSpaceCandidates(env, now);
  await revokeAndPurgeSpaces(env, inactiveSpaceIds, now, true);
  await closeExpiredSharingGenerations(env, now);
  await processExplicitObjectDeletions(env, now);
  await processRevokedStorageScopes(env, now);
  await finalizeNormalSharingCleanup(env, now);
  const queuedSpaceIds = await pendingDeletionCandidates(env);
  await revokeAndPurgeSpaces(env, queuedSpaceIds, now, false);
}
__name(runLegacyScheduledCleanup, "runLegacyScheduledCleanup");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/sharing.ts
var maximumMediaCiphertextBytes = 300 * 1024;
var maximumManifestCiphertextBytes = 64 * 1024;
var minimumChaChaCombinedBytes = 29;
var uploadCloseGraceSeconds = 600;
var sharingContentTTLSeconds = 30 * 86400;
function requireMediaBucket2(env) {
  if (env.MEDIA === void 0) {
    throw new ApiError(503, "media_storage_unavailable", "The media store is temporarily unavailable.");
  }
  return env.MEDIA;
}
__name(requireMediaBucket2, "requireMediaBucket");
async function signedRequest2(request, env, maximumBytes = 16 * 1024) {
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
__name(signedRequest2, "signedRequest");
async function replayResponse3(env, operation, member, clientRequestId, requestHash) {
  const stored = await storedResponseForMember(
    env,
    operation,
    member,
    clientRequestId,
    requestHash
  );
  if (stored !== null) await consumeNonceAndTouch(env, member);
  return stored;
}
__name(replayResponse3, "replayResponse");
async function storedResponseForMember(env, operation, member, clientRequestId, requestHash) {
  let stored;
  try {
    stored = await storedIdempotentResponse(
      env,
      operation,
      member.id,
      clientRequestId,
      requestHash
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return stored;
}
__name(storedResponseForMember, "storedResponseForMember");
async function mutationRequestHash3(request, body) {
  return sha256Base64url(encodeCanonicalFields([
    "NW1.IDEMPOTENCY",
    "1",
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    await sha256Base64url(body)
  ]));
}
__name(mutationRequestHash3, "mutationRequestHash");
async function consumeAndThrow3(env, member, error) {
  await consumeNonce(env, member);
  throw error;
}
__name(consumeAndThrow3, "consumeAndThrow");
async function bestEffortConsumeNonce(env, member) {
  try {
    await consumeNonce(env, member);
  } catch {
  }
}
__name(bestEffortConsumeNonce, "bestEffortConsumeNonce");
function mediaItems(value, descriptors) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 20) {
    throw new ApiError(400, "invalid_items", "items must contain between 1 and 20 unique media objects.");
  }
  const parsed = value.map((itemValue) => {
    const item = asObject(itemValue);
    exactKeys(item, descriptors ? ["mediaId", "ciphertextSize", "ciphertextSHA256"] : ["mediaId"]);
    const mediaId = binaryField(item, "mediaId", 16);
    if (!descriptors) return { mediaId };
    return {
      mediaId,
      ciphertextSize: integerField(
        item,
        "ciphertextSize",
        minimumChaChaCombinedBytes,
        maximumMediaCiphertextBytes
      ),
      ciphertextSHA256: binaryField(item, "ciphertextSHA256", 32)
    };
  });
  const sorted = [...parsed].sort(
    (left, right) => left.mediaId < right.mediaId ? -1 : left.mediaId > right.mediaId ? 1 : 0
  );
  if (parsed.some((item, index) => item.mediaId !== sorted[index]?.mediaId)) {
    throw new ApiError(400, "items_not_sorted", "items must be sorted by mediaId.");
  }
  if (new Set(parsed.map((item) => item.mediaId)).size !== parsed.length) {
    throw new ApiError(400, "duplicate_media", "mediaId values must be unique.");
  }
  return parsed;
}
__name(mediaItems, "mediaItems");
function objectKey(prefix) {
  return `v1/${prefix}/${randomBase64url(24)}`;
}
__name(objectKey, "objectKey");
async function sourceForPublisher(env, member) {
  return env.DB.prepare(
    `SELECT src.id, src.space_id, src.publisher_member_id, src.state,
            src.current_revision, src.last_committed_share_day_key,
            src.cleanup_blocked, storage.object_prefix,
            s.daily_boundary_minute_utc
       FROM sharing_sources AS src
       JOIN sharing_storage_scopes AS storage ON storage.space_id = src.space_id
       JOIN spaces AS s ON s.id = src.space_id
      WHERE src.space_id = ? AND src.publisher_member_id = ?`
  ).bind(member.spaceId, member.id).first();
}
__name(sourceForPublisher, "sourceForPublisher");
async function loadGeneration(env, generationId) {
  return env.DB.prepare(
    `SELECT g.*, src.current_revision AS source_current_revision,
            src.state AS source_state, src.cleanup_blocked,
            s.daily_boundary_minute_utc
       FROM sharing_generations AS g
       JOIN sharing_sources AS src ON src.id = g.source_id
       JOIN spaces AS s ON s.id = g.space_id
      WHERE g.id = ?`
  ).bind(generationId).first();
}
__name(loadGeneration, "loadGeneration");
async function loadMedia(env, generationId) {
  const result = await env.DB.prepare(
    `SELECT generation_id, media_id, object_key, state, ciphertext_size,
            ciphertext_sha256, verified_at
       FROM sharing_generation_media
      WHERE generation_id = ? ORDER BY media_id ASC`
  ).bind(generationId).all();
  return result.results;
}
__name(loadMedia, "loadMedia");
function requirePublisherGeneration(generation, member) {
  if (generation === null || generation.space_id !== member.spaceId || generation.publisher_member_id !== member.id) {
    throw new ApiError(404, "generation_not_found", "The generation was not found.");
  }
  if (generation.source_state !== "active") {
    throw new ApiError(410, "sharing_revoked", "This sharing source is no longer active.");
  }
}
__name(requirePublisherGeneration, "requirePublisherGeneration");
function reservedItem(mediaId) {
  return { mediaId, state: "reserved" };
}
__name(reservedItem, "reservedItem");
function descriptorItem(row) {
  return {
    mediaId: row.media_id,
    ciphertextSize: row.ciphertext_size,
    ciphertextSHA256: row.ciphertext_sha256,
    state: row.state
  };
}
__name(descriptorItem, "descriptorItem");
async function reserveGeneration(request, env) {
  const { body, member } = await signedRequest2(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId", "items"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const items = mediaItems(object.items, false);
  const requestHash = await mutationRequestHash3(request, body);
  const existing = await replayResponse3(
    env,
    "reserve-generation",
    member,
    clientRequestId,
    requestHash
  );
  if (existing !== null) return existing;
  const space = await env.DB.prepare(
    `SELECT daily_boundary_minute_utc
       FROM spaces WHERE id = ? AND state = 'active'`
  ).bind(member.spaceId).first();
  if (space === null) {
    return consumeAndThrow3(env, member, new ApiError(410, "sharing_revoked", "Sharing is no longer active."));
  }
  let source = await sourceForPublisher(env, member);
  if (source?.cleanup_blocked === 1) {
    return consumeAndThrow3(
      env,
      member,
      new ApiError(409, "previous_generation_cleanup_pending", "The prior generation is still being removed.")
    );
  }
  const dayKey = shareDayKey(member.now, space.daily_boundary_minute_utc);
  const nextDay = nextShareDayBoundary(dayKey, space.daily_boundary_minute_utc);
  const expiresAt = Math.min(member.now + 3600, nextDay);
  if (expiresAt <= member.now) {
    return consumeAndThrow3(env, member, new ApiError(409, "generation_day_expired", "The share day has ended."));
  }
  const sourceId = source?.id ?? randomBase64url(16);
  const prefixCandidate = source?.object_prefix ?? randomBase64url(24);
  const generationId = randomBase64url(16);
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    source: { id: sourceId, publisherMemberId: member.id },
    generation: {
      id: generationId,
      state: "reserved",
      shareDayKey: dayKey,
      itemCount: items.length,
      createdAt: member.now,
      expiresAt
    },
    items: items.map((item) => reservedItem(item.mediaId))
  };
  const statements = [...nonceStatements(env, member)];
  if (source === null) {
    statements.push(
      env.DB.prepare(
        `INSERT INTO sharing_storage_scopes(space_id, object_prefix, created_at)
         VALUES (?, ?, ?) ON CONFLICT(space_id) DO NOTHING`
      ).bind(member.spaceId, prefixCandidate, member.now),
      env.DB.prepare(
        `INSERT INTO space_deletion_jobs(
           space_id, state, requires_object_deletion, created_at
         ) VALUES (?, 'armed', 1, ?)
         ON CONFLICT(space_id) DO UPDATE SET requires_object_deletion = 1
           WHERE space_deletion_jobs.state = 'armed'`
      ).bind(member.spaceId, member.now),
      env.DB.prepare(
        `INSERT INTO sharing_sources(
           id, space_id, publisher_member_id, state, created_at, updated_at
         ) VALUES (?, ?, ?, 'active', ?, ?)`
      ).bind(sourceId, member.spaceId, member.id, member.now, member.now)
    );
  }
  statements.push(
    env.DB.prepare(
      `INSERT INTO sharing_daily_freezes(
         source_id, share_day_key, generation_id, created_at, expires_at
       ) VALUES (?, ?, ?, ?, ?)`
    ).bind(sourceId, dayKey, generationId, member.now, nextDay),
    env.DB.prepare(
      `INSERT INTO sharing_generations(
         id, source_id, space_id, publisher_member_id, share_day_key, state,
         item_count, reserve_request_hash, created_at, staging_expires_at
       ) VALUES (?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?)`
    ).bind(
      generationId,
      sourceId,
      member.spaceId,
      member.id,
      dayKey,
      items.length,
      requestHash,
      member.now,
      expiresAt
    ),
    ...items.map((item) => env.DB.prepare(
      `INSERT INTO sharing_generation_media(
         generation_id, media_id, object_key, state
       ) VALUES (
         ?, ?,
         'v1/' || (SELECT object_prefix FROM sharing_storage_scopes WHERE space_id = ?) || '/' || ?,
         'reserved'
       )`
    ).bind(generationId, item.mediaId, member.spaceId, randomBase64url(24))),
    idempotencyStatement(
      env,
      "reserve-generation",
      member.id,
      clientRequestId,
      member.spaceId,
      requestHash,
      201,
      responseBody2,
      member.now
    ),
    activityStatement(env, member)
  );
  try {
    await env.DB.batch(statements);
  } catch {
    const raced = await replayResponse3(
      env,
      "reserve-generation",
      member,
      clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    source = await sourceForPublisher(env, member);
    const daily = source === null ? null : await env.DB.prepare(
      "SELECT id FROM sharing_generations WHERE source_id = ? AND share_day_key = ?"
    ).bind(source.id, dayKey).first();
    await consumeNonce(env, member);
    throw new ApiError(
      409,
      daily === null ? "generation_reservation_conflict" : "daily_generation_exists",
      daily === null ? "The generation could not be reserved." : "This source already froze its generation for the share day."
    );
  }
  return jsonResponse(responseBody2, 201);
}
__name(reserveGeneration, "reserveGeneration");
async function registerDescriptors(request, env, generationIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest2(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId", "items"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const items = mediaItems(object.items, true);
  const requestHash = await mutationRequestHash3(request, body);
  const existing = await replayResponse3(
    env,
    "register-generation-descriptors",
    member,
    clientRequestId,
    requestHash
  );
  if (existing !== null) return existing;
  const generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (generation.state === "superseded" || generation.state === "expired" || generation.state === "committed" && (generation.content_expires_at ?? 0) <= member.now || (generation.state === "reserved" || generation.state === "uploading" || generation.state === "prepared") && generation.staging_expires_at <= member.now) {
    return consumeAndThrow3(env, member, new ApiError(404, "generation_not_found", "The generation is no longer available."));
  }
  if (generation.state !== "reserved" || generation.staging_expires_at <= member.now) {
    return consumeAndThrow3(env, member, new ApiError(409, "invalid_generation_state", "Descriptors can no longer be registered."));
  }
  const existingMedia = await loadMedia(env, generationId);
  if (existingMedia.length !== items.length || existingMedia.some((row, index) => row.media_id !== items[index]?.mediaId)) {
    return consumeAndThrow3(env, member, new ApiError(409, "descriptor_set_mismatch", "Descriptors must exactly match the reservation."));
  }
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    generationId,
    state: "uploading",
    items: items.map((item) => ({ ...item, state: "expected" }))
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO sharing_descriptor_events(
           generation_id, actor_member_id, client_request_id, request_hash, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(generationId, member.id, clientRequestId, requestHash, member.now),
      ...items.map((item) => env.DB.prepare(
        `UPDATE sharing_generation_media
            SET state = 'expected', ciphertext_size = ?, ciphertext_sha256 = ?
          WHERE generation_id = ? AND media_id = ? AND state = 'reserved'
            AND ciphertext_size IS NULL AND ciphertext_sha256 IS NULL`
      ).bind(item.ciphertextSize, item.ciphertextSHA256, generationId, item.mediaId)),
      idempotencyStatement(
        env,
        "register-generation-descriptors",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse3(
      env,
      "register-generation-descriptors",
      member,
      clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "descriptor_registration_conflict", "Descriptors are immutable after registration.");
  }
  return jsonResponse(responseBody2);
}
__name(registerDescriptors, "registerDescriptors");
function requireOctetStream2(request) {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/octet-stream") {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/octet-stream.");
  }
  if (request.headers.has("content-encoding")) {
    throw new ApiError(415, "content_encoding_not_allowed", "Content-Encoding is not accepted.");
  }
}
__name(requireOctetStream2, "requireOctetStream");
function r2Checksum2(object) {
  const value = object.checksums.sha256;
  return value === void 0 ? null : base64urlEncode(new Uint8Array(value));
}
__name(r2Checksum2, "r2Checksum");
async function ensureR2Object2(bucket, key, body, digestBytes, digestValue) {
  const stored = await bucket.put(key, body, {
    onlyIf: { etagDoesNotMatch: "*" },
    sha256: digestBytes,
    httpMetadata: {
      contentType: "application/octet-stream",
      cacheControl: "no-store"
    }
  });
  const object = stored ?? await bucket.head(key);
  if (object === null || object.size !== body.length || r2Checksum2(object) !== digestValue) {
    throw new ApiError(409, "object_integrity_conflict", "Stored ciphertext does not match its descriptor.");
  }
}
__name(ensureR2Object2, "ensureR2Object");
async function rearmObjectDeletion(env, objectKeyValue, spaceId, sourceId, reason, now) {
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
         deleted_at = NULL`
    ).bind(
      objectKeyValue,
      spaceId,
      sourceId,
      reason,
      now + uploadCloseGraceSeconds,
      now
    ),
    env.DB.prepare(
      `UPDATE sharing_sources
          SET cleanup_blocked = 1, updated_at = ?
        WHERE id = ? AND state = 'active'`
    ).bind(now, sourceId)
  ]);
}
__name(rearmObjectDeletion, "rearmObjectDeletion");
async function uploadMedia(request, env, generationIdValue, mediaIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const mediaId = opaqueId(mediaIdValue, "media");
  requireOctetStream2(request);
  const bucket = requireMediaBucket2(env);
  const { body, member } = await signedRequest2(request, env, maximumMediaCiphertextBytes);
  try {
    if (body.length < minimumChaChaCombinedBytes) {
      return consumeAndThrow3(env, member, new ApiError(400, "ciphertext_too_small", "The ciphertext is too small."));
    }
    const [digestBytes, digestValue, generation, media] = await Promise.all([
      sha256(body),
      sha256Base64url(body),
      loadGeneration(env, generationId),
      env.DB.prepare(
        `SELECT generation_id, media_id, object_key, state, ciphertext_size,
              ciphertext_sha256, verified_at
         FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`
      ).bind(generationId, mediaId).first()
    ]);
    try {
      requirePublisherGeneration(generation, member);
    } catch (error) {
      await consumeNonce(env, member);
      throw error;
    }
    if (media === null || media.ciphertext_size !== body.length || media.ciphertext_sha256 !== digestValue) {
      return consumeAndThrow3(env, member, new ApiError(409, "ciphertext_descriptor_mismatch", "Ciphertext does not match its registered descriptor."));
    }
    const responseBody2 = {
      protocolVersion: PROTOCOL_VERSION,
      generationId,
      mediaId,
      ciphertextSize: body.length,
      ciphertextSHA256: digestValue,
      state: "verified"
    };
    if (media.state === "verified") {
      await consumeNonce(env, member);
      const head = await bucket.head(media.object_key);
      if (head === null || head.size !== body.length || r2Checksum2(head) !== digestValue) {
        throw new ApiError(503, "stored_object_unavailable", "Verified ciphertext is temporarily unavailable.");
      }
      await activityStatement(env, member).run();
      return jsonResponse(responseBody2);
    }
    if (generation.state !== "uploading" || generation.staging_expires_at <= member.now || media.state !== "expected") {
      await consumeNonce(env, member);
      if (await bucket.head(media.object_key) !== null) {
        await rearmObjectDeletion(
          env,
          media.object_key,
          member.spaceId,
          generation.source_id,
          "staging_expired",
          member.now
        );
      }
      throw new ApiError(409, "upload_closed", "This generation no longer accepts media uploads.");
    }
    await consumeNonce(env, member);
    await ensureR2Object2(bucket, media.object_key, body, digestBytes, digestValue);
    try {
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO sharing_media_verification_events(
           generation_id, media_id, actor_member_id, object_key,
           ciphertext_size, ciphertext_sha256, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`
        ).bind(
          generationId,
          mediaId,
          member.id,
          media.object_key,
          body.length,
          digestValue,
          member.now
        ),
        activityStatement(env, member)
      ]);
    } catch {
      const raced = await env.DB.prepare(
        `SELECT state, ciphertext_size, ciphertext_sha256
         FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`
      ).bind(generationId, mediaId).first();
      if (raced?.state === "verified" && raced.ciphertext_size === body.length && raced.ciphertext_sha256 === digestValue) {
        await activityStatement(env, member).run();
        return jsonResponse(responseBody2);
      }
      await rearmObjectDeletion(
        env,
        media.object_key,
        member.spaceId,
        generation.source_id,
        "staging_expired",
        member.now
      );
      throw new ApiError(409, "upload_closed", "This generation closed while the upload was finishing.");
    }
    return jsonResponse(responseBody2);
  } catch (error) {
    await bestEffortConsumeNonce(env, member);
    throw error;
  }
}
__name(uploadMedia, "uploadMedia");
async function prepareGeneration(request, env, generationIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest2(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, ["protocolVersion", "clientRequestId"]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const requestHash = await mutationRequestHash3(request, body);
  const existing = await storedResponseForMember(
    env,
    "prepare-generation",
    member,
    clientRequestId,
    requestHash
  );
  if (existing !== null) {
    const payload = await existing.clone().json();
    if (typeof payload.prepareExpiresAt !== "number" || payload.prepareExpiresAt <= member.now) {
      return consumeAndThrow3(env, member, new ApiError(409, "prepare_expired", "This prepare attempt expired; use a new clientRequestId."));
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
  if (generation.staging_expires_at <= member.now || generation.state !== "uploading" && generation.state !== "prepared" || generation.state === "prepared" && (generation.rotation_anchor_utc ?? 0) > member.now) {
    return consumeAndThrow3(env, member, new ApiError(409, "invalid_generation_state", "The generation cannot be prepared now."));
  }
  const verified = await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM sharing_generation_media
      WHERE generation_id = ? AND state = 'verified'`
  ).bind(generationId).first();
  if ((verified?.count ?? 0) !== generation.item_count) {
    return consumeAndThrow3(env, member, new ApiError(409, "media_incomplete", "Every canonical ciphertext must be verified first."));
  }
  const currentDay = shareDayKey(member.now, generation.daily_boundary_minute_utc);
  if (currentDay !== generation.share_day_key) {
    return consumeAndThrow3(env, member, new ApiError(409, "generation_day_expired", "Missed share days are not backfilled."));
  }
  const anchor = nextRotationAnchor(member.now);
  if (anchor >= generation.staging_expires_at) {
    return consumeAndThrow3(env, member, new ApiError(409, "generation_day_expired", "There is not enough time to commit this share day."));
  }
  const attemptId = randomBase64url(16);
  const attemptRevision = generation.prepare_attempt_revision + 1;
  const reservedRevision = generation.source_current_revision + 1;
  const responseBody2 = {
    protocolVersion: PROTOCOL_VERSION,
    generationId,
    state: "prepared",
    prepareAttemptRevision: attemptRevision,
    prepareAttemptId: attemptId,
    reservedRevision,
    rotationAnchorUTC: anchor,
    prepareExpiresAt: anchor
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO sharing_prepare_events(
           generation_id, actor_member_id, client_request_id, request_hash,
           attempt_id, attempt_revision, reserved_revision,
           rotation_anchor_utc, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        generationId,
        member.id,
        clientRequestId,
        requestHash,
        attemptId,
        attemptRevision,
        reservedRevision,
        anchor,
        member.now
      ),
      idempotencyStatement(
        env,
        "prepare-generation",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await storedResponseForMember(
      env,
      "prepare-generation",
      member,
      clientRequestId,
      requestHash
    );
    if (raced !== null) {
      const payload = await raced.clone().json();
      if (typeof payload.prepareExpiresAt === "number" && payload.prepareExpiresAt > member.now) {
        await consumeNonceAndTouch(env, member);
        return raced;
      }
    }
    await consumeNonce(env, member);
    throw new ApiError(409, "prepare_conflict", "The generation prepare state changed.");
  }
  return jsonResponse(responseBody2);
}
__name(prepareGeneration, "prepareGeneration");
async function uploadManifest(request, env, generationIdValue, attemptIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const attemptId = opaqueId(attemptIdValue, "prepare attempt");
  requireOctetStream2(request);
  const bucket = requireMediaBucket2(env);
  const { body, member } = await signedRequest2(request, env, maximumManifestCiphertextBytes);
  try {
    if (body.length < minimumChaChaCombinedBytes) {
      return consumeAndThrow3(env, member, new ApiError(400, "ciphertext_too_small", "The ciphertext is too small."));
    }
    const [digestBytes, digestValue] = await Promise.all([sha256(body), sha256Base64url(body)]);
    let generation = await loadGeneration(env, generationId);
    try {
      requirePublisherGeneration(generation, member);
    } catch (error) {
      await consumeNonce(env, member);
      throw error;
    }
    if (generation.state !== "prepared" || generation.prepare_attempt_id !== attemptId || (generation.prepare_expires_at ?? 0) <= member.now) {
      await consumeNonce(env, member);
      if (generation.manifest_object_key !== null && await bucket.head(generation.manifest_object_key) !== null) {
        await rearmObjectDeletion(
          env,
          generation.manifest_object_key,
          member.spaceId,
          generation.source_id,
          "reprepare",
          member.now
        );
      }
      throw new ApiError(409, "prepare_expired", "This prepare attempt is no longer current.");
    }
    const responseBody2 = {
      protocolVersion: PROTOCOL_VERSION,
      generationId,
      prepareAttemptRevision: generation.prepare_attempt_revision,
      prepareAttemptId: attemptId,
      ciphertextSize: body.length,
      ciphertextSHA256: digestValue,
      state: "verified"
    };
    if (generation.manifest_verified_at !== null) {
      if (generation.manifest_object_key === null || generation.manifest_ciphertext_size !== body.length || generation.manifest_ciphertext_sha256 !== digestValue) {
        return consumeAndThrow3(env, member, new ApiError(409, "manifest_immutable", "The prepared manifest is immutable."));
      }
      await consumeNonce(env, member);
      const head = await bucket.head(generation.manifest_object_key);
      if (head === null || head.size !== body.length || r2Checksum2(head) !== digestValue) {
        throw new ApiError(503, "stored_object_unavailable", "Verified manifest is temporarily unavailable.");
      }
      await activityStatement(env, member).run();
      return jsonResponse(responseBody2);
    }
    await consumeNonce(env, member);
    if (generation.manifest_object_key === null) {
      const scope = await env.DB.prepare(
        "SELECT object_prefix FROM sharing_storage_scopes WHERE space_id = ?"
      ).bind(member.spaceId).first();
      if (scope === null) {
        throw new ApiError(409, "storage_scope_missing", "The private storage scope is not armed.");
      }
      const candidate = objectKey(scope.object_prefix);
      await env.DB.prepare(
        `UPDATE sharing_generations
          SET manifest_object_key = ?
        WHERE id = ? AND state = 'prepared' AND prepare_attempt_id = ?
          AND prepare_expires_at > ? AND manifest_object_key IS NULL`
      ).bind(candidate, generationId, attemptId, member.now).run();
      generation = await loadGeneration(env, generationId);
      try {
        requirePublisherGeneration(generation, member);
      } catch (error) {
        throw error;
      }
    }
    if (generation.manifest_object_key === null || generation.state !== "prepared" || generation.prepare_attempt_id !== attemptId || (generation.prepare_expires_at ?? 0) <= member.now) {
      throw new ApiError(409, "prepare_expired", "This prepare attempt closed while reserving the manifest.");
    }
    await ensureR2Object2(
      bucket,
      generation.manifest_object_key,
      body,
      digestBytes,
      digestValue
    );
    try {
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO sharing_manifest_verification_events(
           generation_id, attempt_id, actor_member_id, object_key,
           ciphertext_size, ciphertext_sha256, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`
        ).bind(
          generationId,
          attemptId,
          member.id,
          generation.manifest_object_key,
          body.length,
          digestValue,
          member.now
        ),
        activityStatement(env, member)
      ]);
    } catch {
      const raced = await loadGeneration(env, generationId);
      if (raced?.prepare_attempt_id === attemptId && raced.manifest_verified_at !== null && raced.manifest_ciphertext_size === body.length && raced.manifest_ciphertext_sha256 === digestValue) {
        await activityStatement(env, member).run();
        return jsonResponse(responseBody2);
      }
      await rearmObjectDeletion(
        env,
        generation.manifest_object_key,
        member.spaceId,
        generation.source_id,
        "reprepare",
        member.now
      );
      throw new ApiError(409, "prepare_expired", "This prepare attempt closed while the upload was finishing.");
    }
    return jsonResponse(responseBody2);
  } catch (error) {
    await bestEffortConsumeNonce(env, member);
    throw error;
  }
}
__name(uploadManifest, "uploadManifest");
async function commitGeneration(request, env, generationIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest2(request, env);
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "prepareAttemptId",
    "prepareAttemptRevision",
    "reservedRevision",
    "manifestCiphertextSHA256"
  ]);
  protocolVersion(object);
  const clientRequestId = uuidField(object, "clientRequestId");
  const attemptId = binaryField(object, "prepareAttemptId", 16);
  const attemptRevision = integerField(object, "prepareAttemptRevision", 1, 2147483647);
  const reservedRevision = integerField(object, "reservedRevision", 1, 2147483647);
  const manifestHash = binaryField(object, "manifestCiphertextSHA256", 32);
  const requestHash = await mutationRequestHash3(request, body);
  const existing = await replayResponse3(
    env,
    "commit-generation",
    member,
    clientRequestId,
    requestHash
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
  const responseBody2 = {
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
    state: "current"
  };
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      env.DB.prepare(
        `INSERT INTO sharing_commit_events(
           generation_id, actor_member_id, client_request_id, request_hash,
           attempt_id, attempt_revision, reserved_revision,
           manifest_ciphertext_sha256, server_share_day_key, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
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
        member.now
      ),
      idempotencyStatement(
        env,
        "commit-generation",
        member.id,
        clientRequestId,
        member.spaceId,
        requestHash,
        200,
        responseBody2,
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse3(
      env,
      "commit-generation",
      member,
      clientRequestId,
      requestHash
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "commit_conflict", "The latest prepared generation could not be committed.");
  }
  return jsonResponse(responseBody2);
}
__name(commitGeneration, "commitGeneration");
function generationManifest(generation) {
  if (generation.manifest_verified_at === null || generation.manifest_ciphertext_size === null || generation.manifest_ciphertext_sha256 === null) return null;
  return {
    ciphertextSize: generation.manifest_ciphertext_size,
    ciphertextSHA256: generation.manifest_ciphertext_sha256
  };
}
__name(generationManifest, "generationManifest");
async function getGeneration(request, env, generationIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const { body, member } = await signedRequest2(request, env);
  requireEmptyBody(body);
  const generation = await loadGeneration(env, generationId);
  try {
    requirePublisherGeneration(generation, member);
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (generation.state === "superseded" || generation.state === "expired" || generation.state === "committed" && (generation.content_expires_at ?? 0) <= member.now || (generation.state === "reserved" || generation.state === "uploading" || generation.state === "prepared") && generation.staging_expires_at <= member.now) {
    return consumeAndThrow3(env, member, new ApiError(404, "generation_not_found", "The generation is no longer available."));
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
      manifest: generationManifest(generation)
    },
    items: media.map(descriptorItem)
  });
}
__name(getGeneration, "getGeneration");
async function loadCurrent(env, sourceId, spaceId, now) {
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
        AND g.state = 'committed' AND g.content_expires_at > ?`
  ).bind(sourceId, spaceId, now).first();
}
__name(loadCurrent, "loadCurrent");
function currentSummary(current2) {
  return {
    generationId: current2.id,
    shareDayKey: current2.share_day_key,
    revision: current2.current_revision,
    rotationAnchorUTC: current2.rotation_anchor_utc,
    itemCount: current2.item_count,
    committedAt: current2.committed_at,
    contentExpiresAt: current2.content_expires_at
  };
}
__name(currentSummary, "currentSummary");
async function getSources(request, env) {
  const { body, member } = await signedRequest2(request, env);
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
      ORDER BY src.id ASC`
  ).bind(member.now, member.spaceId).all();
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
        contentExpiresAt: row.content_expires_at
      }
    }))
  });
}
__name(getSources, "getSources");
function currentETag(sourceId, revision) {
  return `"nw1-${sourceId}-${revision}"`;
}
__name(currentETag, "currentETag");
async function getCurrent(request, env, sourceIdValue) {
  const sourceId = opaqueId(sourceIdValue, "source");
  const { body, member } = await signedRequest2(request, env);
  requireEmptyBody(body);
  const current2 = await loadCurrent(env, sourceId, member.spaceId, member.now);
  if (current2 === null) {
    return consumeAndThrow3(env, member, new ApiError(404, "current_unavailable", "This source has no current generation."));
  }
  const etag = currentETag(sourceId, current2.current_revision);
  if (request.headers.get("if-none-match") === etag) {
    await consumeNonceAndTouch(env, member);
    return new Response(null, {
      status: 304,
      headers: {
        "Cache-Control": "no-store, max-age=0",
        ETag: etag,
        Pragma: "no-cache"
      }
    });
  }
  const media = await loadMedia(env, current2.id);
  await consumeNonceAndTouch(env, member);
  const response = jsonResponse({
    protocolVersion: PROTOCOL_VERSION,
    sourceId,
    publisherMemberId: current2.publisher_member_id,
    current: {
      ...currentSummary(current2),
      prepareAttemptId: current2.prepare_attempt_id,
      prepareAttemptRevision: current2.prepare_attempt_revision,
      reservedRevision: current2.reserved_revision,
      manifest: generationManifest(current2),
      items: media.map((row) => ({
        mediaId: row.media_id,
        ciphertextSize: row.ciphertext_size,
        ciphertextSHA256: row.ciphertext_sha256
      }))
    }
  });
  response.headers.set("ETag", etag);
  return response;
}
__name(getCurrent, "getCurrent");
function ciphertextResponse(object, ciphertextSHA256) {
  return new Response(object.body, {
    headers: {
      "Cache-Control": "no-store, max-age=0",
      "Content-Length": String(object.size),
      "Content-Type": "application/octet-stream",
      ETag: `"sha256-${ciphertextSHA256}"`,
      "Neko-Ciphertext-SHA256": ciphertextSHA256,
      Pragma: "no-cache",
      "X-Content-Type-Options": "nosniff"
    }
  });
}
__name(ciphertextResponse, "ciphertextResponse");
async function downloadManifest(request, env, generationIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const bucket = requireMediaBucket2(env);
  const { body, member } = await signedRequest2(request, env);
  requireEmptyBody(body);
  const row = await env.DB.prepare(
    `SELECT g.manifest_object_key, g.manifest_ciphertext_size,
            g.manifest_ciphertext_sha256
       FROM sharing_currents AS current
       JOIN sharing_sources AS src ON src.id = current.source_id
       JOIN sharing_generations AS g ON g.id = current.generation_id
      WHERE current.generation_id = ? AND src.space_id = ?
        AND src.state = 'active' AND g.state = 'committed'
        AND g.content_expires_at > ?`
  ).bind(generationId, member.spaceId, member.now).first();
  if (row?.manifest_object_key === null || row?.manifest_object_key === void 0 || row.manifest_ciphertext_size === null || row.manifest_ciphertext_sha256 === null) {
    return consumeAndThrow3(env, member, new ApiError(404, "manifest_not_found", "The current manifest was not found."));
  }
  await consumeNonce(env, member);
  const object = await bucket.get(row.manifest_object_key);
  if (object === null || object.size !== row.manifest_ciphertext_size || r2Checksum2(object) !== row.manifest_ciphertext_sha256) {
    throw new ApiError(503, "stored_object_unavailable", "The current manifest is temporarily unavailable.");
  }
  await activityStatement(env, member).run();
  return ciphertextResponse(object, row.manifest_ciphertext_sha256);
}
__name(downloadManifest, "downloadManifest");
async function downloadMedia(request, env, generationIdValue, mediaIdValue) {
  const generationId = opaqueId(generationIdValue, "generation");
  const mediaId = opaqueId(mediaIdValue, "media");
  const bucket = requireMediaBucket2(env);
  const { body, member } = await signedRequest2(request, env);
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
        AND gm.state = 'verified'`
  ).bind(generationId, mediaId, member.spaceId, member.now).first();
  if (row === null) {
    return consumeAndThrow3(env, member, new ApiError(404, "media_not_found", "The current media object was not found."));
  }
  await consumeNonce(env, member);
  const object = await bucket.get(row.object_key);
  if (object === null || object.size !== row.ciphertext_size || r2Checksum2(object) !== row.ciphertext_sha256) {
    throw new ApiError(503, "stored_object_unavailable", "The current media is temporarily unavailable.");
  }
  await activityStatement(env, member).run();
  return ciphertextResponse(object, row.ciphertext_sha256);
}
__name(downloadMedia, "downloadMedia");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/window-name.ts
var protocolVersion3 = 2;
var minimumCombinedAEADCiphertextBytes = 29;
var MAXIMUM_WINDOW_NAME_CIPHERTEXT_BYTES = 512;
var putOperation = "put-window-name";
function responseBody(row) {
  return {
    protocolVersion: protocolVersion3,
    windowName: row === null ? null : {
      ownerMemberId: row.owner_member_id,
      clientRevision: row.client_revision,
      keyEpoch: row.key_epoch,
      ciphertext: row.ciphertext,
      ciphertextSHA256: row.ciphertext_sha256,
      ownerSignature: row.owner_signature
    }
  };
}
__name(responseBody, "responseBody");
async function signedRequest3(request, env) {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "window-name")
  );
  const body = await readBody(request, 2 * 1024);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(
        403,
        "active_member_required",
        "Pairing must be complete before accessing the private window name."
      );
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}
__name(signedRequest3, "signedRequest");
async function context(env, member) {
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
        AND space.state = 'active'`
  ).bind(
    member.momentParticipantId,
    member.deviceId,
    member.spaceId
  ).first();
  if (row === null) {
    throw new ApiError(
      503,
      "window_name_identity_unavailable",
      "The private window identity is temporarily unavailable."
    );
  }
  if (row.is_blocked === 1) {
    throw new ApiError(
      410,
      "window_name_blocked",
      "The private window name is unavailable after a participant block."
    );
  }
  return row;
}
__name(context, "context");
async function loadCurrent2(env, spaceID) {
  return env.DB.prepare(
    `SELECT owner_member_id, client_revision, key_epoch, ciphertext,
            ciphertext_size, ciphertext_sha256, owner_signature
       FROM moment_window_names
      WHERE space_id = ?`
  ).bind(spaceID).first();
}
__name(loadCurrent2, "loadCurrent");
async function mutationRequestHash4(request, body) {
  return sha256Base64url(encodeCanonicalFields([
    "NW2.IDEMPOTENCY",
    "2",
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    await sha256Base64url(body)
  ]));
}
__name(mutationRequestHash4, "mutationRequestHash");
async function replayResponse4(env, member, clientRequestID, requestHash) {
  let stored;
  try {
    stored = await storedIdempotentResponse(
      env,
      putOperation,
      member.id,
      clientRequestID,
      requestHash
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (stored !== null) await consumeNonceAndTouch(env, member);
  return stored;
}
__name(replayResponse4, "replayResponse");
async function consumeAndThrow4(env, member, error) {
  await consumeNonce(env, member);
  throw error;
}
__name(consumeAndThrow4, "consumeAndThrow");
async function parseWindowName(request, body) {
  const object = parseJsonBody(request, body);
  exactKeys(object, [
    "protocolVersion",
    "clientRequestId",
    "clientRevision",
    "keyEpoch",
    "ciphertext",
    "ciphertextSHA256",
    "ownerSignature"
  ]);
  if (object.protocolVersion !== protocolVersion3) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
  const clientRequestID = uuidField(object, "clientRequestId");
  const clientRevision = integerField(
    object,
    "clientRevision",
    0,
    Number.MAX_SAFE_INTEGER
  );
  const keyEpoch = integerField(object, "keyEpoch", 1, Number.MAX_SAFE_INTEGER);
  const ciphertext = stringField(object, "ciphertext");
  const ciphertextBytes = base64urlDecode(ciphertext);
  if (ciphertextBytes.length < minimumCombinedAEADCiphertextBytes || ciphertextBytes.length > MAXIMUM_WINDOW_NAME_CIPHERTEXT_BYTES) {
    throw new ApiError(
      400,
      "invalid_ciphertext_length",
      "The encrypted private window name is outside its allowed size."
    );
  }
  const ciphertextSHA256 = binaryField(object, "ciphertextSHA256", 32);
  if (await sha256Base64url(ciphertextBytes) !== ciphertextSHA256) {
    throw new ApiError(
      400,
      "ciphertext_hash_mismatch",
      "The encrypted private window name does not match its digest."
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
    ownerSignature
  };
}
__name(parseWindowName, "parseWindowName");
function samePayload(current2, requested) {
  return current2.client_revision === requested.clientRevision && current2.key_epoch === requested.keyEpoch && current2.ciphertext === requested.ciphertext && current2.ciphertext_size === requested.ciphertextSize && current2.ciphertext_sha256 === requested.ciphertextSHA256 && current2.owner_signature === requested.ownerSignature;
}
__name(samePayload, "samePayload");
async function getWindowName(request, env) {
  const { body, member } = await signedRequest3(request, env);
  try {
    requireEmptyBody(body);
    await context(env, member);
  } catch (error) {
    return consumeAndThrow4(env, member, error);
  }
  const row = await loadCurrent2(env, member.spaceId);
  await consumeNonceAndTouch(env, member);
  return jsonResponse(responseBody(row));
}
__name(getWindowName, "getWindowName");
async function putWindowName(request, env) {
  const { body, member } = await signedRequest3(request, env);
  let requested;
  let actor;
  try {
    requested = await parseWindowName(request, body);
    requireOwner(member);
    actor = await context(env, member);
    if (actor.participant_role !== "owner") {
      throw new ApiError(
        403,
        "owner_required",
        "Only the active inviter can update the private window name."
      );
    }
    if (actor.is_primary_device !== 1) {
      throw new ApiError(
        403,
        "primary_owner_device_required",
        "The original owner device is required to update the private window name."
      );
    }
    const ownerTranscript = encodeCanonicalFields([
      "NW2.WINDOW-NAME-RECORD",
      "1",
      member.spaceId,
      member.id,
      String(requested.clientRevision),
      String(requested.keyEpoch),
      requested.ciphertextSHA256
    ]);
    if (!await verifyEd25519(
      member.signingPublicKey,
      requested.ownerSignature,
      ownerTranscript
    )) {
      throw new ApiError(
        401,
        "invalid_owner_signature",
        "The private window name owner signature is invalid."
      );
    }
  } catch (error) {
    return consumeAndThrow4(env, member, error);
  }
  const requestHash = await mutationRequestHash4(request, body);
  const replayed = await replayResponse4(
    env,
    member,
    requested.clientRequestID,
    requestHash
  );
  if (replayed !== null) return replayed;
  if (requested.keyEpoch !== actor.current_key_epoch) {
    return consumeAndThrow4(
      env,
      member,
      new ApiError(
        409,
        "key_epoch_required",
        "The current sharing key epoch is required."
      )
    );
  }
  const row = {
    owner_member_id: member.id,
    client_revision: requested.clientRevision,
    key_epoch: requested.keyEpoch,
    ciphertext: requested.ciphertext,
    ciphertext_size: requested.ciphertextSize,
    ciphertext_sha256: requested.ciphertextSHA256,
    owner_signature: requested.ownerSignature
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
             THEN excluded.updated_at ELSE moment_window_names.updated_at END)`
      ).bind(
        member.spaceId,
        member.id,
        requested.clientRevision,
        requested.keyEpoch,
        requested.ciphertext,
        requested.ciphertextSize,
        requested.ciphertextSHA256,
        requested.ownerSignature,
        member.now
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
        member.now
      ),
      activityStatement(env, member)
    ]);
  } catch {
    const raced = await replayResponse4(
      env,
      member,
      requested.clientRequestID,
      requestHash
    );
    if (raced !== null) return raced;
    const current2 = await loadCurrent2(env, member.spaceId);
    let failure = new ApiError(
      409,
      "window_name_update_conflict",
      "The private window name could not be updated."
    );
    if (current2 !== null && current2.client_revision > requested.clientRevision) {
      failure = new ApiError(
        409,
        "stale_window_name_revision",
        "A newer private window name revision already exists."
      );
    } else if (current2 !== null && current2.client_revision === requested.clientRevision && !samePayload(current2, requested)) {
      failure = new ApiError(
        409,
        "window_name_revision_conflict",
        "This private window name revision already has different ciphertext."
      );
    }
    return consumeAndThrow4(env, member, failure);
  }
  return jsonResponse(response);
}
__name(putWindowName, "putWindowName");

// ../../neko-family-worker-policy2-20260927/NekoWidget/SharingService/src/index.ts
async function route(request, env, ctx) {
  const url = new URL(request.url);
  rejectQuery(url);
  const { pathname } = url;
  let runtimeGatePromise;
  const runtimeGate = /* @__PURE__ */ __name(() => {
    runtimeGatePromise ??= loadRuntimeGate(env);
    return runtimeGatePromise;
  }, "runtimeGate");
  if (pathname === "/v2/family-records" || pathname.startsWith("/v2/family-records/")) {
    if (env.FAMILY_RECORD_RUNTIME_ENABLED !== "YES" || !momentRuntimeEnabled(env) || !mediaGateOpen(await runtimeGate())) {
      throw new ApiError(503, "family_record_runtime_disabled", "Family records are unavailable.");
    }
    const match = pathname.match(/^\/v2\/family-records(?:\/([^/]+)(\/photo)?)?$/u);
    if (!match) throw new ApiError(404, "not_found", "Record not found.");
    return familyRecords(request, env, match[1], match[2] !== void 0);
  }
  if (request.method === "GET" && pathname === "/health") {
    const snapshot = await runtimeGate();
    if (snapshot === null) {
      throw new ApiError(503, "runtime_gate_unavailable", "Runtime control is unavailable.");
    }
    return jsonResponse(
      { status: "ok", protocolVersion: 1 },
      200,
      effectiveRuntimeGateHeaders(env, snapshot)
    );
  }
  if (pathname === "/v1/sharing" || pathname.startsWith("/v1/sharing/")) {
    if (!legacySharingRuntimeEnabled(env)) {
      throw new ApiError(
        503,
        "legacy_sharing_runtime_disabled",
        "Legacy daily sharing is unavailable."
      );
    }
  }
  if (request.method === "POST" && pathname === "/v1/spaces") {
    return createSpace(request, env);
  }
  const challengeMatch = pathname.match(/^\/v1\/invitations\/([^/]+)\/challenges$/u);
  if (request.method === "POST" && challengeMatch?.[1] !== void 0) {
    return createChallenge(request, env, challengeMatch[1]);
  }
  const enrollmentMatch = pathname.match(/^\/v1\/invitations\/([^/]+)\/enrollments$/u);
  if (request.method === "POST" && enrollmentMatch?.[1] !== void 0) {
    return redeemInvitation(request, env, enrollmentMatch[1]);
  }
  if (request.method === "GET" && pathname === "/v1/pairing/pending") {
    return getPending(request, env);
  }
  if (request.method === "GET" && pathname === "/v1/pairing/status") {
    return getStatus(request, env);
  }
  const approveMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/approve$/u);
  if (request.method === "POST" && approveMatch?.[1] !== void 0) {
    return approveEnrollment(request, env, approveMatch[1]);
  }
  const completeMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/complete$/u);
  if (request.method === "POST" && completeMatch?.[1] !== void 0) {
    return completeEnrollment(request, env, completeMatch[1]);
  }
  const cancelMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/cancel$/u);
  if (request.method === "POST" && cancelMatch?.[1] !== void 0) {
    return cancelEnrollment(request, env, cancelMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v1/pairing/revoke") {
    return revokeSpace(request, env);
  }
  if (request.method === "POST" && pathname === "/v2/device-recoveries") {
    return createDeviceRecovery(request, env);
  }
  if (request.method === "GET" && pathname === "/v2/device-recoveries/pending") {
    return getPendingDeviceRecoveries(request, env);
  }
  const recoveryDescriptorMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/descriptor$/u
  );
  if (request.method === "GET" && recoveryDescriptorMatch?.[1] !== void 0) {
    return getDeviceRecoveryDescriptor(request, env, recoveryDescriptorMatch[1]);
  }
  const recoveryClaimMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/claim$/u
  );
  if (request.method === "POST" && recoveryClaimMatch?.[1] !== void 0) {
    return claimDeviceRecovery(request, env, recoveryClaimMatch[1]);
  }
  const recoveryApproveMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/approve$/u
  );
  if (request.method === "POST" && recoveryApproveMatch?.[1] !== void 0) {
    return approveDeviceRecovery(request, env, recoveryApproveMatch[1]);
  }
  const recoveryStatusMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/status$/u
  );
  if (request.method === "GET" && recoveryStatusMatch?.[1] !== void 0) {
    return getDeviceRecoveryStatus(request, env, recoveryStatusMatch[1]);
  }
  const recoverySponsorStatusMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/sponsor-status$/u
  );
  if (request.method === "GET" && recoverySponsorStatusMatch?.[1] !== void 0) {
    return getSponsorDeviceRecoveryStatus(request, env, recoverySponsorStatusMatch[1]);
  }
  const recoveryCompleteMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/complete$/u
  );
  if (request.method === "POST" && recoveryCompleteMatch?.[1] !== void 0) {
    return completeDeviceRecovery(request, env, recoveryCompleteMatch[1]);
  }
  const pawReactionMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/reactions$/u);
  if ((pawReactionMatch?.[1] !== void 0 || pathname === "/v2/reactions/changes" || pathname.startsWith("/v2/reactions/changes/")) && (!reactionRuntimeEnabled(env) || !mediaGateOpen(await runtimeGate()))) {
    throw new ApiError(
      503,
      "reaction_runtime_disabled",
      "Photo reactions are temporarily unavailable."
    );
  }
  if ((pathname === "/v2/moments" || pathname.startsWith("/v2/moments/")) && pawReactionMatch?.[1] === void 0) {
    if (!momentRuntimeEnabled(env) || !mediaGateOpen(await runtimeGate())) {
      throw new ApiError(
        503,
        "moment_runtime_disabled",
        "Moment sharing is temporarily unavailable."
      );
    }
  }
  if (request.method === "POST" && pathname === "/v2/moments/reservations") {
    return reserveMoment(request, env);
  }
  if (pathname === "/v2/push-subscriptions/current") {
    if (request.method === "PUT") {
      const response = await putCurrentPushSubscription(request, env);
      if (response.ok && ctx !== void 0) scheduleNotificationDrain(env, ctx);
      return response;
    }
    if (request.method === "DELETE") {
      return deleteCurrentPushSubscription(request, env);
    }
  }
  if (pathname === "/v3/push-subscriptions/current") {
    if (request.method === "PUT") {
      const response = await putAdditivePushSubscription(request, env);
      if (response.ok && ctx !== void 0) scheduleNotificationDrain(env, ctx);
      return response;
    }
    if (request.method === "DELETE") {
      return deleteAdditivePushSubscription(request, env);
    }
  }
  if (pathname === "/v2/window-name" && (!windowNameRuntimeEnabled(env) || !mediaGateOpen(await runtimeGate()))) {
    throw new ApiError(
      503,
      "window_name_runtime_disabled",
      "Private window name sync is temporarily unavailable."
    );
  }
  if (request.method === "GET" && pathname === "/v2/window-name") {
    return getWindowName(request, env);
  }
  if (request.method === "PUT" && pathname === "/v2/window-name") {
    return putWindowName(request, env);
  }
  if (request.method === "GET" && pathname === "/v2/moments/changes") {
    return getMomentChanges(request, env);
  }
  if (request.method === "GET" && pathname === "/v2/reactions/changes") {
    return getReactionChanges(request, env);
  }
  const reactionChangesMatch = pathname.match(/^\/v2\/reactions\/changes\/([^/]+)$/u);
  if (request.method === "GET" && reactionChangesMatch?.[1] !== void 0) {
    return getReactionChanges(request, env, reactionChangesMatch[1]);
  }
  const momentChangesMatch = pathname.match(/^\/v2\/moments\/changes\/([^/]+)$/u);
  if (request.method === "GET" && momentChangesMatch?.[1] !== void 0) {
    return getMomentChanges(request, env, momentChangesMatch[1]);
  }
  const momentCiphertextMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/ciphertext$/u);
  if (request.method === "PUT" && momentCiphertextMatch?.[1] !== void 0) {
    return uploadMomentCiphertext(request, env, momentCiphertextMatch[1]);
  }
  if (request.method === "GET" && momentCiphertextMatch?.[1] !== void 0) {
    return downloadMomentCiphertext(request, env, momentCiphertextMatch[1]);
  }
  const momentCommitMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/commit$/u);
  if (request.method === "POST" && momentCommitMatch?.[1] !== void 0) {
    const response = await commitMoment(
      request,
      env,
      momentCommitMatch[1],
      apnsRuntimeEnabled(env) && apnsGateOpen(await runtimeGate())
    );
    if (response.ok && ctx !== void 0) scheduleNotificationDrain(env, ctx);
    return response;
  }
  const momentAckMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/ack$/u);
  if (request.method === "POST" && momentAckMatch?.[1] !== void 0) {
    return acknowledgeMoment(request, env, momentAckMatch[1]);
  }
  if (request.method === "POST" && pawReactionMatch?.[1] !== void 0) {
    const response = await recordPawReaction(
      request,
      env,
      pawReactionMatch[1],
      apnsRuntimeEnabled(env) && apnsGateOpen(await runtimeGate())
    );
    if (response.ok && ctx !== void 0) scheduleNotificationDrain(env, ctx);
    return response;
  }
  const participantBlockMatch = pathname.match(/^\/v2\/participants\/([^/]+)\/block$/u);
  if (request.method === "POST" && participantBlockMatch?.[1] !== void 0) {
    return blockParticipant(request, env, participantBlockMatch[1]);
  }
  const blockWithdrawalMatch = pathname.match(/^\/v2\/blocks\/([^/]+)\/withdraw$/u);
  if (request.method === "POST" && blockWithdrawalMatch?.[1] !== void 0) {
    return withdrawParticipantBlock(request, env, blockWithdrawalMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v2/reports/reservations") {
    return reserveMomentReport(request, env);
  }
  const reportCiphertextMatch = pathname.match(/^\/v2\/reports\/([^/]+)\/ciphertext$/u);
  if (request.method === "PUT" && reportCiphertextMatch?.[1] !== void 0) {
    return uploadMomentReportCiphertext(request, env, reportCiphertextMatch[1]);
  }
  const reportCommitMatch = pathname.match(/^\/v2\/reports\/([^/]+)\/commit$/u);
  if (request.method === "POST" && reportCommitMatch?.[1] !== void 0) {
    return commitMomentReport(request, env, reportCommitMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v1/sharing/generations/reserve") {
    return reserveGeneration(request, env);
  }
  const descriptorMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/descriptors$/u);
  if (request.method === "POST" && descriptorMatch?.[1] !== void 0) {
    return registerDescriptors(request, env, descriptorMatch[1]);
  }
  const mediaMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/media\/([^/]+)$/u);
  if (request.method === "PUT" && mediaMatch?.[1] !== void 0 && mediaMatch[2] !== void 0) {
    return uploadMedia(request, env, mediaMatch[1], mediaMatch[2]);
  }
  const prepareMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/prepare$/u);
  if (request.method === "POST" && prepareMatch?.[1] !== void 0) {
    return prepareGeneration(request, env, prepareMatch[1]);
  }
  const manifestUploadMatch = pathname.match(
    /^\/v1\/sharing\/generations\/([^/]+)\/prepares\/([^/]+)\/manifest$/u
  );
  if (request.method === "PUT" && manifestUploadMatch?.[1] !== void 0 && manifestUploadMatch[2] !== void 0) {
    return uploadManifest(request, env, manifestUploadMatch[1], manifestUploadMatch[2]);
  }
  const commitMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/commit$/u);
  if (request.method === "POST" && commitMatch?.[1] !== void 0) {
    return commitGeneration(request, env, commitMatch[1]);
  }
  if (request.method === "GET" && pathname === "/v1/sharing/sources") {
    return getSources(request, env);
  }
  const currentMatch = pathname.match(/^\/v1\/sharing\/sources\/([^/]+)\/current$/u);
  if (request.method === "GET" && currentMatch?.[1] !== void 0) {
    return getCurrent(request, env, currentMatch[1]);
  }
  const manifestDownloadMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/manifest$/u);
  if (request.method === "GET" && manifestDownloadMatch?.[1] !== void 0) {
    return downloadManifest(request, env, manifestDownloadMatch[1]);
  }
  if (request.method === "GET" && mediaMatch?.[1] !== void 0 && mediaMatch[2] !== void 0) {
    return downloadMedia(request, env, mediaMatch[1], mediaMatch[2]);
  }
  const generationMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)$/u);
  if (request.method === "GET" && generationMatch?.[1] !== void 0) {
    return getGeneration(request, env, generationMatch[1]);
  }
  throw new ApiError(404, "not_found", "The endpoint was not found.");
}
__name(route, "route");
var index_default = {
  async fetch(request, env, ctx) {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      return errorResponse(error);
    }
  },
  async scheduled(controller, env, ctx) {
    if (controller.cron === MOMENT_CLEANUP_CRON) {
      ctx.waitUntil(runMomentCleanup(env));
      ctx.waitUntil(runFamilyRecordCleanup(env));
    } else if (controller.cron === APNS_DRAIN_CRON) {
      ctx.waitUntil(drainNotificationOutbox(env));
    } else if (controller.cron === LEGACY_CLEANUP_CRON) {
      ctx.waitUntil(runLegacyScheduledCleanup(env));
    }
  }
};
export {
  index_default as default,
  route
};
//# sourceMappingURL=index.js.map
