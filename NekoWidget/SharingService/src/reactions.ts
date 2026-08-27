import {
  activityStatement,
  authenticateSignedRequest,
  consumeNonce,
  consumeNonceAndTouch,
  nonceStatements,
  requireLiveSpace,
  type AuthenticatedMember,
} from "./auth";
import { randomBase64url, sha256Base64url } from "./encoding";
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
import { reactionNotificationEventStatements } from "./push";
import {
  exactKeys,
  opaqueId,
  stringField,
  uuidField,
  type JsonRecord,
} from "./validation";

export const REACTION_PROTOCOL_VERSION = 2 as const;
export const REACTION_DAILY_QUOTA = 30;
export const REACTION_USAGE_RETENTION_DAYS = 2;
const reactionOperation = "post-paw-reaction";

interface ReactionContextRow {
  participant_id: string;
}

interface ReactionMomentRow {
  id: string;
  space_id: string;
  sender_participant_id: string;
  state: "reserved" | "uploaded" | "committed" | "expired" | "deleted";
}

interface ReactionRow {
  id: string;
  moment_id: string;
  space_id: string;
  reactor_participant_id: string;
  recipient_participant_id: string;
  kind: "paw";
  quota_day_key: number;
  created_at: number;
}

interface ReactionChangeRow {
  sequence: number;
  cursor: string;
  reaction_id: string;
  moment_id: string;
  kind: "paw";
}

function protocolVersion2(object: JsonRecord): 2 {
  if (object.protocolVersion !== REACTION_PROTOCOL_VERSION) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 2.");
  }
  return REACTION_PROTOCOL_VERSION;
}

function pawKind(object: JsonRecord): "paw" {
  if (stringField(object, "kind") !== "paw") {
    throw new ApiError(400, "invalid_field", "kind must be paw.");
  }
  return "paw";
}

function changeCursorValue(value: string): string {
  if (!/^(?:[A-Za-z0-9_-]{22}|[0-9a-f]{32})$/u.test(value)) {
    throw new ApiError(404, "not_found", "cursor was not found.");
  }
  return value;
}

async function signedReactionRequest(
  request: Request,
  env: Env,
): Promise<{ body: Uint8Array; member: AuthenticatedMember }> {
  await enforceRateLimit(
    env,
    env.MEMBER_RATE_LIMITER,
    transientNetworkKey(request, "moment-reaction"),
  );
  const body = await readBody(request);
  const member = await authenticateSignedRequest(request, env, body);
  try {
    requireLiveSpace(member);
    if (member.state !== "active") {
      throw new ApiError(
        403,
        "active_member_required",
        "Pairing must be complete before reacting to photos.",
      );
    }
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  return { body, member };
}

async function reactionContext(
  env: Env,
  member: AuthenticatedMember,
): Promise<ReactionContextRow> {
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
        AND space.state = 'active'`,
  ).bind(
    member.momentParticipantId,
    member.deviceId,
    member.spaceId,
  ).first<ReactionContextRow>();
  if (row === null) {
    throw new ApiError(
      503,
      "reaction_identity_unavailable",
      "The sharing identity is temporarily unavailable.",
    );
  }
  return row;
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

async function loadMoment(env: Env, momentID: string): Promise<ReactionMomentRow | null> {
  return env.DB.prepare(
    `SELECT id, space_id, sender_participant_id, state
       FROM moments WHERE id = ?`,
  ).bind(momentID).first<ReactionMomentRow>();
}

async function reactionAllowed(
  env: Env,
  momentID: string,
  spaceID: string,
  reactorParticipantID: string,
  senderParticipantID: string,
  now: number,
): Promise<boolean> {
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
        )`,
  ).bind(
    reactorParticipantID,
    senderParticipantID,
    momentID,
    spaceID,
    now,
  ).first<{ allowed: number }>();
  return row !== null;
}

async function loadReaction(
  env: Env,
  momentID: string,
  reactorParticipantID: string,
): Promise<ReactionRow | null> {
  return env.DB.prepare(
    `SELECT id, moment_id, space_id, reactor_participant_id,
            recipient_participant_id, kind, quota_day_key, created_at
       FROM moment_reactions
      WHERE moment_id = ? AND reactor_participant_id = ? AND kind = 'paw'`,
  ).bind(momentID, reactorParticipantID).first<ReactionRow>();
}

function reactionResponse(reaction: ReactionRow, alreadyReacted: boolean): unknown {
  return {
    protocolVersion: REACTION_PROTOCOL_VERSION,
    reaction: {
      id: reaction.id,
      momentId: reaction.moment_id,
      kind: reaction.kind,
    },
    alreadyReacted,
  };
}

function reactionInsertStatement(
  env: Env,
  reaction: ReactionRow,
  ignoreExisting: boolean,
): D1PreparedStatement {
  const conflict = ignoreExisting
    ? " ON CONFLICT(moment_id, reactor_participant_id, kind) DO NOTHING"
    : "";
  return env.DB.prepare(
    `INSERT INTO moment_reactions(
       id, moment_id, space_id, reactor_participant_id,
       recipient_participant_id, kind, quota_day_key, created_at
     ) VALUES (?, ?, ?, ?, ?, 'paw', ?, ?)${conflict}`,
  ).bind(
    reaction.id,
    reaction.moment_id,
    reaction.space_id,
    reaction.reactor_participant_id,
    reaction.recipient_participant_id,
    reaction.quota_day_key,
    reaction.created_at,
  );
}

async function currentDailyUsage(
  env: Env,
  participantID: string,
  dayKey: number,
): Promise<number> {
  const row = await env.DB.prepare(
    `SELECT reaction_count FROM moment_reaction_daily_usage
      WHERE participant_id = ? AND day_key = ?`,
  ).bind(participantID, dayKey).first<{ reaction_count: number }>();
  return row?.reaction_count ?? 0;
}

async function replayResponse(
  env: Env,
  member: AuthenticatedMember,
  clientRequestID: string,
  requestHash: string,
): Promise<Response | null> {
  let response: Response | null;
  try {
    response = await storedIdempotentResponse(
      env,
      reactionOperation,
      member.id,
      clientRequestID,
      requestHash,
    );
  } catch (error) {
    await consumeNonce(env, member);
    throw error;
  }
  if (response !== null) await consumeNonceAndTouch(env, member);
  return response;
}

async function consumeAndThrow(
  env: Env,
  member: AuthenticatedMember,
  error: unknown,
): Promise<never> {
  await consumeNonce(env, member);
  throw error;
}

async function persistDuplicateResponse(
  env: Env,
  member: AuthenticatedMember,
  reaction: ReactionRow,
  clientRequestID: string,
  requestHash: string,
): Promise<Response> {
  const responseBody = reactionResponse(reaction, true);
  const guard: ReactionRow = {
    ...reaction,
    id: randomBase64url(16),
    created_at: member.now,
    quota_day_key: Math.floor(member.now / 86_400),
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
        responseBody,
        member.now,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    const raced = await replayResponse(
      env,
      member,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    await consumeNonce(env, member);
    throw new ApiError(409, "reaction_conflict", "The reaction could not be recorded.");
  }
  return jsonResponse(responseBody);
}

export async function recordPawReaction(
  request: Request,
  env: Env,
  momentIDValue: string,
  notificationsEnabled: boolean,
): Promise<Response> {
  const momentID = opaqueId(momentIDValue, "moment");
  const { body, member } = await signedReactionRequest(request, env);
  let clientRequestID: string;
  try {
    const object = parseJsonBody(request, body);
    exactKeys(object, ["protocolVersion", "clientRequestId", "kind"]);
    protocolVersion2(object);
    clientRequestID = uuidField(object, "clientRequestId");
    pawKind(object);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const context = await reactionContext(env, member);
  const moment = await loadMoment(env, momentID);
  if (moment === null || moment.space_id !== member.spaceId) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(404, "moment_not_found", "The moment was not found."),
    );
  }
  if (moment.sender_participant_id === context.participant_id) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(403, "self_reaction_not_allowed", "A sender cannot react to their own photo."),
    );
  }
  if (!(await reactionAllowed(
    env,
    momentID,
    member.spaceId,
    context.participant_id,
    moment.sender_participant_id,
    member.now,
  ))) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(410, "reaction_not_allowed", "This photo can no longer receive a reaction."),
    );
  }

  const requestHash = await mutationRequestHash(request, body);
  const replay = await replayResponse(
    env,
    member,
    clientRequestID,
    requestHash,
  );
  if (replay !== null) return replay;

  const existing = await loadReaction(env, momentID, context.participant_id);
  if (existing !== null) {
    return persistDuplicateResponse(
      env,
      member,
      existing,
      clientRequestID,
      requestHash,
    );
  }

  const dayKey = Math.floor(member.now / 86_400);
  if ((await currentDailyUsage(env, context.participant_id, dayKey)) >= REACTION_DAILY_QUOTA) {
    return consumeAndThrow(
      env,
      member,
      new ApiError(429, "reaction_daily_quota_reached", "The daily reaction limit was reached."),
    );
  }

  const reaction: ReactionRow = {
    id: randomBase64url(16),
    moment_id: momentID,
    space_id: member.spaceId,
    reactor_participant_id: context.participant_id,
    recipient_participant_id: moment.sender_participant_id,
    kind: "paw",
    quota_day_key: dayKey,
    created_at: member.now,
  };
  const responseBody = reactionResponse(reaction, false);
  try {
    await env.DB.batch([
      ...nonceStatements(env, member),
      reactionInsertStatement(env, reaction, false),
      env.DB.prepare(
        `INSERT INTO reaction_changes(
           cursor, participant_id, reaction_id, created_at
         ) VALUES (?, ?, ?, ?)`,
      ).bind(
        randomBase64url(16),
        reaction.recipient_participant_id,
        reaction.id,
        reaction.created_at,
      ),
      ...reactionNotificationEventStatements(
        env,
        reaction.id,
        reaction.recipient_participant_id,
        reaction.created_at,
        notificationsEnabled,
      ),
      idempotencyStatement(
        env,
        reactionOperation,
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
      member,
      clientRequestID,
      requestHash,
    );
    if (raced !== null) return raced;
    const racedReaction = await loadReaction(env, momentID, context.participant_id);
    if (racedReaction !== null && await reactionAllowed(
      env,
      momentID,
      member.spaceId,
      context.participant_id,
      moment.sender_participant_id,
      member.now,
    )) {
      return persistDuplicateResponse(
        env,
        member,
        racedReaction,
        clientRequestID,
        requestHash,
      );
    }
    const quotaReached = (await currentDailyUsage(
      env,
      context.participant_id,
      dayKey,
    )) >= REACTION_DAILY_QUOTA;
    await consumeNonce(env, member);
    if (quotaReached) {
      throw new ApiError(
        429,
        "reaction_daily_quota_reached",
        "The daily reaction limit was reached.",
      );
    }
    throw new ApiError(409, "reaction_conflict", "The reaction could not be recorded.");
  }
  return jsonResponse(responseBody, 201);
}

export async function getReactionChanges(
  request: Request,
  env: Env,
  cursorValue?: string,
): Promise<Response> {
  const cursor = cursorValue === undefined ? undefined : changeCursorValue(cursorValue);
  const { body, member } = await signedReactionRequest(request, env);
  try {
    requireEmptyBody(body);
  } catch (error) {
    return consumeAndThrow(env, member, error);
  }
  const context = await reactionContext(env, member);
  let afterSequence = 0;
  if (cursor !== undefined) {
    const cursorRow = await env.DB.prepare(
      `SELECT sequence FROM reaction_changes
        WHERE cursor = ? AND participant_id = ?`,
    ).bind(cursor, context.participant_id).first<{ sequence: number }>();
    if (cursorRow === null) {
      return consumeAndThrow(
        env,
        member,
        new ApiError(404, "cursor_not_found", "The reaction changes cursor was not found."),
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
      LIMIT 100`,
  ).bind(context.participant_id, afterSequence).all<ReactionChangeRow>();
  // The cleanup must acknowledge exactly the immutable page returned above.
  // A new heart can be committed between this read and the following batch;
  // bounding by the returned maximum prevents that unseen heart's APNs
  // delivery from being consumed by a second LIMIT query.
  const returnedMaxSequence = rows.results.at(-1)?.sequence ?? afterSequence;
  const changes = rows.results.map((row) => ({
    cursor: row.cursor,
    type: "pawReceived",
    reaction: {
      id: row.reaction_id,
      momentId: row.moment_id,
      kind: row.kind,
    },
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
            )`,
      ).bind(
        member.deviceId,
        context.participant_id,
        context.participant_id,
        context.participant_id,
        afterSequence,
        returnedMaxSequence,
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
            )`,
      ).bind(
        context.participant_id,
        context.participant_id,
        afterSequence,
        returnedMaxSequence,
      ),
      activityStatement(env, member),
    ]);
  } catch {
    throw new ApiError(409, "replayed_request", "This signed request nonce has already been used.");
  }
  return jsonResponse({
    protocolVersion: REACTION_PROTOCOL_VERSION,
    changes,
    nextCursor: changes.at(-1)?.cursor ?? cursor ?? "",
  });
}
