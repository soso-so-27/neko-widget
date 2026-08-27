import {
  activityStatement,
  authenticateSignedRequest,
  consumeNonce,
  nonceStatements,
  requireLiveSpace,
  type AuthenticatedMember,
} from "./auth";
import {
  base64urlDecode,
  base64urlEncode,
  randomBase64url,
  sha256Base64url,
} from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import { apnsRuntimeEnabled, type Env } from "./env";
import { apnsGateOpen, loadRuntimeGate } from "./runtime-gate";
import { enforceRateLimit, parseJsonBody, readBody, transientNetworkKey } from "./http";
import { exactKeys, stringField, type JsonRecord } from "./validation";

export const APNS_PROTOCOL_VERSION = 2 as const;
export const APNS_ADDITIVE_PROTOCOL_VERSION = 3 as const;
export const APNS_DRAIN_CRON = "* * * * *";
export const APNS_SUBSCRIPTION_TTL_SECONDS = 35 * 86_400;
export const APNS_EVENT_TTL_SECONDS = 24 * 60 * 60;
export const APNS_DRAIN_LIMIT = 50;
const APNS_LEASE_SECONDS = 90;
const maximumAPNsResponseBytes = 1_024;

type APNsEnvironment = "development" | "production";
type NotificationKind = "new_moment" | "heart";
type NotificationRouteSchemaVersion = 1 | 2;

interface ProviderCredential {
  keyId: string;
  teamId: string;
  bundleId: string;
  environment: APNsEnvironment;
  privateKey: string;
}

interface TokenKeyring {
  current: string;
  keys: ReadonlyMap<string, Uint8Array>;
}

interface DispatchRow {
  event_id: string;
  device_id: string;
  token_digest: string;
  state: "pending" | "leased";
  attempts: number;
  kind: NotificationKind;
  target_space_id: string;
  target_moment_id: string;
  created_at: number;
  expires_at: number;
  token_ciphertext: string;
  token_nonce: string;
  encryption_key_id: string;
  environment: APNsEnvironment;
  route_schema_version: NotificationRouteSchemaVersion;
}

interface APNsErrorBody {
  reason?: unknown;
}

export interface APNsDrainSummary {
  leased: number;
  accepted: number;
  retried: number;
  invalidated: number;
  skipped: number;
  configurationUnavailable: boolean;
}

interface CachedProviderToken {
  value: string;
  issuedAt: number;
}

const providerTokenCache = new Map<string, CachedProviderToken>();

function buffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

function strictObject(value: unknown, expected: readonly string[], label: string): JsonRecord {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error(`${label} must be a JSON object.`);
  }
  const object = value as JsonRecord;
  const actual = Object.keys(object).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} has missing or unknown fields.`);
  }
  return object;
}

function secretString(object: JsonRecord, key: string): string {
  const value = object[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${key} must be a non-empty string.`);
  }
  return value;
}

function parseProviderCredential(env: Env): ProviderCredential {
  if (env.APNS_PROVIDER_CREDENTIAL_JSON === undefined) {
    throw new Error("APNs provider credential is unavailable.");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(env.APNS_PROVIDER_CREDENTIAL_JSON);
  } catch {
    throw new Error("APNs provider credential is not valid JSON.");
  }
  const object = strictObject(
    decoded,
    ["bundleId", "environment", "keyId", "privateKey", "teamId"],
    "APNs provider credential",
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
  if (
    !privateKey.startsWith("-----BEGIN PRIVATE KEY-----")
    || !privateKey.trimEnd().endsWith("-----END PRIVATE KEY-----")
  ) {
    throw new Error("APNs privateKey must be a PKCS#8 PEM private key.");
  }
  return { keyId, teamId, bundleId, environment, privateKey };
}

function parseTokenKeyring(env: Env): TokenKeyring {
  if (env.APNS_TOKEN_KEYRING_JSON === undefined) {
    throw new Error("APNs token keyring is unavailable.");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(env.APNS_TOKEN_KEYRING_JSON);
  } catch {
    throw new Error("APNs token keyring is not valid JSON.");
  }
  const object = strictObject(decoded, ["current", "keys"], "APNs token keyring");
  const current = secretString(object, "current");
  if (!/^[A-Za-z0-9_-]{1,32}$/u.test(current)) {
    throw new Error("APNs current encryption key ID is invalid.");
  }
  const keyObject = object.keys;
  if (keyObject === null || Array.isArray(keyObject) || typeof keyObject !== "object") {
    throw new Error("APNs token keyring keys must be an object.");
  }
  const entries = Object.entries(keyObject as Record<string, unknown>);
  if (entries.length < 1 || entries.length > 4) {
    throw new Error("APNs token keyring must contain one through four keys.");
  }
  const keys = new Map<string, Uint8Array>();
  for (const [id, value] of entries) {
    if (!/^[A-Za-z0-9_-]{1,32}$/u.test(id) || typeof value !== "string") {
      throw new Error("APNs token keyring contains an invalid entry.");
    }
    let bytes: Uint8Array;
    try {
      bytes = base64urlDecode(value, 32);
    } catch {
      throw new Error("APNs token keyring keys must be canonical 32-byte base64url values.");
    }
    keys.set(id, bytes);
  }
  if (!keys.has(current)) {
    throw new Error("APNs current encryption key is missing from the keyring.");
  }
  return { current, keys };
}

function tokenAAD(
  deviceID: string,
  environment: APNsEnvironment,
  bundleID: string,
  keyID: string,
): Uint8Array {
  return new TextEncoder().encode(
    `NW2.APNS-TOKEN\u0000${deviceID}\u0000${environment}\u0000${bundleID}\u0000${keyID}`,
  );
}

async function importAESKey(bytes: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", buffer(bytes), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function encryptDeviceToken(
  token: Uint8Array,
  deviceID: string,
  credential: ProviderCredential,
  keyring: TokenKeyring,
): Promise<{ ciphertext: string; nonce: string; digest: string; keyID: string }> {
  const keyBytes = keyring.keys.get(keyring.current);
  if (keyBytes === undefined) throw new Error("APNs current encryption key is unavailable.");
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: buffer(nonce),
      additionalData: buffer(tokenAAD(
        deviceID,
        credential.environment,
        credential.bundleId,
        keyring.current,
      )),
    },
    await importAESKey(keyBytes),
    buffer(token),
  );
  return {
    ciphertext: base64urlEncode(new Uint8Array(ciphertext)),
    nonce: base64urlEncode(nonce),
    digest: await sha256Base64url(token),
    keyID: keyring.current,
  };
}

async function decryptDeviceToken(
  row: DispatchRow,
  credential: ProviderCredential,
  keyring: TokenKeyring,
): Promise<Uint8Array> {
  const keyBytes = keyring.keys.get(row.encryption_key_id);
  if (keyBytes === undefined) throw new Error("APNs token encryption key version is unavailable.");
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: buffer(base64urlDecode(row.token_nonce, 12)),
      additionalData: buffer(tokenAAD(
        row.device_id,
        row.environment,
        credential.bundleId,
        row.encryption_key_id,
      )),
    },
    await importAESKey(keyBytes),
    buffer(base64urlDecode(row.token_ciphertext)),
  );
  const token = new Uint8Array(plaintext);
  if (token.length < 16 || token.length > 256 || await sha256Base64url(token) !== row.token_digest) {
    throw new Error("APNs encrypted token integrity check failed.");
  }
  return token;
}

function parseRegistrationBody(
  object: JsonRecord,
  protocolVersion: number,
): {
  token: Uint8Array;
  environment: APNsEnvironment;
} {
  exactKeys(object, ["environment", "protocolVersion", "token"]);
  if (object.protocolVersion !== protocolVersion) {
    throw new ApiError(
      400,
      "unsupported_protocol",
      `protocolVersion must be ${protocolVersion}.`,
    );
  }
  const environment = stringField(object, "environment");
  if (environment !== "development" && environment !== "production") {
    throw new ApiError(400, "invalid_field", "environment must be development or production.");
  }
  let token: Uint8Array;
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

function parseDeleteBody(object: JsonRecord, protocolVersion: number): void {
  exactKeys(object, ["protocolVersion"]);
  if (object.protocolVersion !== protocolVersion) {
    throw new ApiError(
      400,
      "unsupported_protocol",
      `protocolVersion must be ${protocolVersion}.`,
    );
  }
}

async function signedActiveRequest(
  request: Request,
  env: Env,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "push-subscription"));
  const body = await readBody(request, 4 * 1_024);
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

async function putPushSubscription(
  request: Request,
  env: Env,
  protocolVersion: number,
  registrationMode: "exclusiveLegacy" | "additiveTargeted",
): Promise<Response> {
  const { body, member } = await signedActiveRequest(request, env);
  if (!apnsRuntimeEnabled(env) || !apnsGateOpen(await loadRuntimeGate(env))) {
    await consumeNonce(env, member);
    throw new ApiError(503, "apns_runtime_disabled", "Notifications are temporarily unavailable.");
  }
  let parsed: ReturnType<typeof parseRegistrationBody>;
  let encrypted: Awaited<ReturnType<typeof encryptDeviceToken>>;
  let credential: ProviderCredential;
  try {
    parsed = parseRegistrationBody(parseJsonBody(request, body), protocolVersion);
    credential = parseProviderCredential(env);
    if (parsed.environment !== credential.environment) {
      throw new ApiError(409, "apns_environment_mismatch", "This build does not match the configured notification environment.");
    }
    encrypted = await encryptDeviceToken(
      parsed.token,
      member.deviceId,
      credential,
      parseTokenKeyring(env),
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
               )`,
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
              )`,
        ).bind(encrypted.digest, member.deviceId),
        env.DB.prepare(
          `DELETE FROM apns_subscriptions
            WHERE token_digest = ? AND device_id <> ?`,
        ).bind(encrypted.digest, member.deviceId),
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
              )`,
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
              )`,
        ).bind(encrypted.digest, member.deviceId),
        env.DB.prepare(
          `DELETE FROM apns_subscriptions
            WHERE token_digest = ? AND device_id <> ?
              AND route_schema_version = 1`,
        ).bind(encrypted.digest, member.deviceId),
      );
    }
    const routeSchemaVersion: NotificationRouteSchemaVersion =
      registrationMode === "exclusiveLegacy" ? 1 : 2;
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
           route_schema_version = excluded.route_schema_version`,
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
        routeSchemaVersion,
      ),
    );
    if (registrationMode === "additiveTargeted") {
      // Migration 0011 deliberately normalizes any token/timestamp UPSERT to
      // route 1 so an older rolled-back Worker cannot leave a stale route-2
      // marker. A v3 registration restores route 2 in a separate route-only
      // statement, which that compatibility trigger does not match.
      statements.push(
        env.DB.prepare(
          `UPDATE apns_subscriptions
              SET route_schema_version = 2
            WHERE device_id = ?`,
        ).bind(member.deviceId),
      );
    }
    statements.push(activityStatement(env, member));
    await env.DB.batch(statements);
  } catch {
    await consumeNonce(env, member);
    throw new ApiError(409, "push_subscription_conflict", "The notification subscription could not be updated.");
  }
  return jsonResponse({
    protocolVersion,
    subscription: { state: "active" },
  });
}

export async function putCurrentPushSubscription(
  request: Request,
  env: Env,
): Promise<Response> {
  return putPushSubscription(
    request,
    env,
    APNS_PROTOCOL_VERSION,
    "exclusiveLegacy",
  );
}

// Registers this authenticated window/device without removing another window
// credential that holds the same physical APNs token. The v2 endpoint above
// deliberately keeps its exclusive behavior for already-shipped clients.
export async function putAdditivePushSubscription(
  request: Request,
  env: Env,
): Promise<Response> {
  return putPushSubscription(
    request,
    env,
    APNS_ADDITIVE_PROTOCOL_VERSION,
    "additiveTargeted",
  );
}

async function deletePushSubscription(
  request: Request,
  env: Env,
  protocolVersion: number,
): Promise<Response> {
  const { body, member } = await signedActiveRequest(request, env);
  try {
    parseDeleteBody(parseJsonBody(request, body), protocolVersion);
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
        "DELETE FROM notification_deliveries WHERE device_id = ?",
      ).bind(member.deviceId),
      env.DB.prepare(
        `DELETE FROM notification_events
          WHERE participant_id = ?
            AND NOT EXISTS (
              SELECT 1
                FROM notification_deliveries AS delivery
               WHERE delivery.event_id = notification_events.id
            )`,
      ).bind(member.momentParticipantId),
      env.DB.prepare("DELETE FROM apns_subscriptions WHERE device_id = ? AND participant_id = ?")
        .bind(member.deviceId, member.momentParticipantId),
      activityStatement(env, member),
    ]);
  } catch {
    await consumeNonce(env, member);
    throw new ApiError(409, "push_subscription_conflict", "The notification subscription could not be removed.");
  }
  return jsonResponse({
    protocolVersion,
    subscription: { state: "deleted" },
  });
}

export async function deleteCurrentPushSubscription(
  request: Request,
  env: Env,
): Promise<Response> {
  return deletePushSubscription(request, env, APNS_PROTOCOL_VERSION);
}

export async function deleteAdditivePushSubscription(
  request: Request,
  env: Env,
): Promise<Response> {
  return deletePushSubscription(request, env, APNS_ADDITIVE_PROTOCOL_VERSION);
}

export function momentNotificationEventStatements(
  env: Env,
  momentID: string,
  createdAt: number,
  gateEnabled: boolean,
): D1PreparedStatement[] {
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
     DO NOTHING`,
  ).bind(createdAt, createdAt + APNS_EVENT_TTL_SECONDS, momentID)];
}

export function reactionNotificationEventStatements(
  env: Env,
  reactionID: string,
  participantID: string,
  createdAt: number,
  gateEnabled: boolean,
): D1PreparedStatement[] {
  if (!apnsRuntimeEnabled(env) || !gateEnabled) return [];
  return [env.DB.prepare(
    `INSERT INTO notification_events(
       id, kind, participant_id, moment_id, reaction_id, created_at, expires_at
     ) VALUES (?, 'heart', ?, NULL, ?, ?, ?)
     ON CONFLICT(kind, participant_id, reaction_id) WHERE kind = 'heart'
     DO NOTHING`,
  ).bind(
    randomBase64url(16),
    participantID,
    reactionID,
    createdAt,
    createdAt + APNS_EVENT_TTL_SECONDS,
  )];
}

function pemPKCS8Bytes(value: string): Uint8Array {
  const base64 = value
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/gu, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(base64)) {
    throw new Error("APNs private key PEM is malformed.");
  }
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

async function providerJWT(credential: ProviderCredential, now: number): Promise<string> {
  const cacheKey = `${credential.teamId}:${credential.keyId}`;
  const cached = providerTokenCache.get(cacheKey);
  if (cached !== undefined && now - cached.issuedAt < 50 * 60) return cached.value;

  const header = base64urlEncode(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: credential.keyId })));
  const claims = base64urlEncode(new TextEncoder().encode(JSON.stringify({ iss: credential.teamId, iat: now })));
  const signingInput = `${header}.${claims}`;
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    buffer(pemPKCS8Bytes(credential.privateKey)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    buffer(new TextEncoder().encode(signingInput)),
  ));
  if (signature.length !== 64) throw new Error("APNs provider signature has an invalid length.");
  const value = `${signingInput}.${base64urlEncode(signature)}`;
  providerTokenCache.set(cacheKey, { value, issuedAt: now });
  return value;
}

function tokenHex(token: Uint8Array): string {
  return [...token].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function notificationPayload(row: DispatchRow): string {
  const body = row.kind === "new_moment"
    ? "新しい一枚が届きました。"
    : "届けた写真にハートが届きました。";
  return JSON.stringify({
    aps: {
      alert: { title: "ねこのまど", body },
      "content-available": 1,
    },
    neko: {
      // Additive bindings use a route schema that already-shipped clients
      // reject, so downgrading cannot interpret an inactive-window alert as
      // a generic wake for the selected window. v2 endpoint rows retain v1.
      v: row.route_schema_version,
      kind: row.kind,
    },
    // Both route schemas keep the exact two-key `neko` shape. Only v2-aware
    // clients accept the targeted version; v1-only clients reject it before
    // reading the separately validated opaque IDs below.
    nekoTarget: {
      v: 1,
      spaceId: row.target_space_id,
      momentId: row.target_moment_id,
    },
  });
}

function collapseID(row: DispatchRow): string {
  return `${row.kind === "new_moment" ? "moment" : "heart"}-${row.event_id}`.slice(0, 64);
}

async function boundedReason(response: Response): Promise<string> {
  const text = (await response.text()).slice(0, maximumAPNsResponseBytes);
  try {
    const decoded = JSON.parse(text) as APNsErrorBody;
    return typeof decoded.reason === "string" && decoded.reason.length <= 64
      ? decoded.reason
      : "Unknown";
  } catch {
    return "Unknown";
  }
}

function retryDelaySeconds(attempts: number): number {
  const base = Math.min(3_600, 30 * (2 ** Math.min(attempts, 7)));
  const random = crypto.getRandomValues(new Uint8Array(1))[0] ?? 0;
  return Math.floor(base * (0.75 + random / 512));
}

function invalidDeviceResponse(status: number, reason: string): boolean {
  return status === 410
    || reason === "BadDeviceToken"
    || reason === "DeviceTokenNotForTopic"
    || reason === "Unregistered";
}

function transientResponse(status: number, reason: string): boolean {
  return status === 429 || status >= 500
    || reason === "TooManyProviderTokenUpdates"
    || reason === "ExpiredProviderToken";
}

async function markAccepted(
  env: Env,
  row: DispatchRow,
  leaseID: string,
  now: number,
): Promise<boolean> {
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
        )`,
  ).bind(
    now,
    now,
    row.event_id,
    row.device_id,
    row.token_digest,
    leaseID,
    row.environment,
    row.route_schema_version,
  ).run();
  return result.meta.changes === 1;
}

async function releaseAfterRouteChange(
  env: Env,
  row: DispatchRow,
  leaseID: string,
  now: number,
): Promise<boolean> {
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
        )`,
  ).bind(
    now,
    now,
    row.event_id,
    row.device_id,
    row.token_digest,
    leaseID,
    row.environment,
    row.route_schema_version,
  ).run();
  return result.meta.changes === 1;
}

async function markRetry(
  env: Env,
  row: DispatchRow,
  leaseID: string,
  now: number,
  status: number | null,
  reason: string,
  configurationError: boolean,
): Promise<void> {
  const retryAt = Math.min(
    row.expires_at,
    now + (configurationError ? 3_600 : retryDelaySeconds(row.attempts)),
  );
  await env.DB.prepare(
    `UPDATE notification_deliveries
        SET state = 'pending', attempts = attempts + 1,
            next_attempt_at = ?, lease_id = NULL, lease_expires_at = NULL,
            last_status = ?, last_reason = ?, updated_at = ?
      WHERE event_id = ? AND device_id = ?
        AND state = 'leased' AND lease_id = ?`,
  ).bind(
    retryAt,
    status,
    configurationError ? `configuration_error:${reason}` : reason,
    now,
    row.event_id,
    row.device_id,
    leaseID,
  ).run();
}

async function invalidateToken(
  env: Env,
  row: DispatchRow,
): Promise<void> {
  // APNs invalidates the physical token, not one room membership. The same
  // installation can register that token under a distinct device credential
  // for each private window, so remove every matching digest. Digest CAS still
  // preserves any device that already refreshed to a newer token.
  await env.DB.batch([
    env.DB.prepare(
      "DELETE FROM notification_deliveries WHERE token_digest = ?",
    ).bind(row.token_digest),
    env.DB.prepare(
      "DELETE FROM apns_subscriptions WHERE token_digest = ?",
    ).bind(row.token_digest),
  ]);
}

export async function drainNotificationOutbox(
  env: Env,
  now = Math.floor(Date.now() / 1_000),
  fetchImpl: typeof fetch = fetch,
  hooks: {
    afterLease?: (delivery: { eventID: string; deviceID: string }) => Promise<void>;
  } = {},
): Promise<APNsDrainSummary> {
  const summary: APNsDrainSummary = {
    leased: 0,
    accepted: 0,
    retried: 0,
    invalidated: 0,
    skipped: 0,
    configurationUnavailable: false,
  };
  await env.DB.batch([
    env.DB.prepare("DELETE FROM apns_subscriptions WHERE expires_at <= ?").bind(now),
    env.DB.prepare("DELETE FROM notification_events WHERE expires_at <= ?").bind(now),
  ]);
  const runtimeGate = await loadRuntimeGate(env);
  if (!apnsRuntimeEnabled(env) || runtimeGate === null || !apnsGateOpen(runtimeGate)) {
    return summary;
  }

  let credential: ProviderCredential;
  let keyring: TokenKeyring;
  let authorization: string;
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
      LIMIT ?`,
  ).bind(
    now,
    now,
    credential.environment,
    now,
    now,
    APNS_DRAIN_LIMIT,
  ).all<DispatchRow>();

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
          )`,
    ).bind(
      leaseID,
      now + APNS_LEASE_SECONDS,
      now,
      row.event_id,
      row.device_id,
      row.token_digest,
      now,
      now,
    ).run();
    if (leased.meta.changes !== 1) {
      summary.skipped += 1;
      continue;
    }
    summary.leased += 1;

    // Tests use this boundary to deterministically reproduce a foreground
    // cursor acknowledgement racing a scheduled drain. Production passes no
    // hook; the durable-row validation below is always authoritative.
    await hooks.afterLease?.({ eventID: row.event_id, deviceID: row.device_id });

    let token: Uint8Array;
    try {
      token = await decryptDeviceToken(row, credential, keyring);
    } catch {
      await markRetry(env, row, leaseID, now, null, "TokenDecryptFailed", true);
      summary.retried += 1;
      continue;
    }

    const payload = notificationPayload(row);
    // A foreground/background sync can delete this physical token's delivery
    // after candidate selection (or even after the lease is acquired). Check
    // the event, lease, token CAS, and live subscription immediately before
    // making an irreversible APNs request.
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
          AND runtime_gate.apns_enabled = 1`,
    ).bind(
      row.event_id,
      row.device_id,
      row.token_digest,
      leaseID,
      now,
      now,
      credential.environment,
      row.route_schema_version,
      runtimeGate.generation,
    ).first<{ present: number }>();
    if (stillCurrent === null) {
      summary.skipped += 1;
      continue;
    }
    let response: Response;
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
            "content-type": "application/json",
          },
          body: payload,
        },
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
        // APNs accepted a payload whose route was superseded while the
        // network request was in flight. Keep the durable delivery pending so
        // the next drain sends the current route instead of losing it forever.
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
      !transientResponse(response.status, reason),
    );
    summary.retried += 1;
  }
  return summary;
}

export function scheduleNotificationDrain(env: Env, ctx: ExecutionContext): void {
  if (apnsRuntimeEnabled(env)) ctx.waitUntil(drainNotificationOutbox(env));
}
