import { activityStatement, authenticateSignedRequest, consumeNonceAndTouch,
  nonceStatements, requireLiveSpace, type AuthenticatedMember } from "./auth";
import { base64urlDecode, sha256, sha256Base64url } from "./encoding";
import type { Env } from "./env";
import { requireWindowDeliverySupport, windowDeliverySupportGuard } from "./window-delivery-membership";
import { ApiError, jsonResponse } from "./errors";
import { enforceRateLimit, parseJsonBody, readBody, requireEmptyBody, transientNetworkKey } from "./http";
import { encodeCanonicalFields } from "./protocol";
import { asObject, exactKeys, integerField, stringField, uuidField } from "./validation";

// Bounded internal pilot. Reaching capacity rejects additions, never evicts.
export const FAMILY_RECORD_MAXIMUM_PHOTOS = 100;
export const FAMILY_RECORD_MAXIMUM_WORDS = 1000;
export const FAMILY_RECORD_MAXIMUM_PHOTO_BYTES = 2 * 1024 * 1024;
const maximumWordsBytes = 32 * 1024;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

export interface MomentSharedRecord {
  photoID: string;
  photoCiphertext: string;
  photoBytes: Uint8Array;
  wordsID: string | null;
  wordsCiphertext: string | null;
  wordsSize: number;
}

/** Match FamilyRecordSourceIdentity.recordID's canonical transcript and UUID spelling. */
export async function momentSharedPhotoID(spaceID: string, momentID: string): Promise<string> {
  const bytes = (await sha256(encodeCanonicalFields(["NW.FAMILY-RECORD.MOMENT.1", spaceID, momentID]))).slice(0, 16);
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export async function parseMomentSharedRecord(value: unknown, spaceID: string, momentID: string): Promise<MomentSharedRecord> {
  const object = asObject(value);
  const hasWords = Object.hasOwn(object, "wordsID") || Object.hasOwn(object, "wordsCiphertext");
  exactKeys(object, hasWords
    ? ["photoID", "photoCiphertext", "wordsID", "wordsCiphertext"]
    : ["photoID", "photoCiphertext"]);
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

interface RecordRow {
  space_id: string; id: string; entry_id: string; kind: "photo" | "words";
  author_member_id: string; revision: number; state: "active" | "withdrawn";
  key_epoch: number; ciphertext: string | null; object_key: string | null;
  ciphertext_size: number; payload_hash: string; last_operation_id: string;
  created_at: number; updated_at: number;
}

// Rechecked inside each mutation's atomic D1 batch, including block/device state.
const authorized = `EXISTS (
 SELECT 1 FROM members m JOIN spaces s ON s.id=m.space_id
 JOIN moment_participants p ON p.legacy_member_id=m.id AND p.space_id=s.id
 JOIN moment_devices d ON d.participant_id=p.id
 JOIN moment_spaces ms ON ms.space_id=s.id
 WHERE m.id=? AND s.id=? AND d.id=? AND m.state='active' AND s.state='active'
 AND p.state='active' AND d.state='active' AND ms.state='active' AND ms.current_key_epoch=1
 AND NOT EXISTS (SELECT 1 FROM moment_blocks b WHERE b.space_id=s.id AND b.state='active'))`;
function authBindings(m: AuthenticatedMember): string[] { return [m.id, m.spaceId, m.deviceId]; }
async function assertAuthorized(env: Env, m: AuthenticatedMember): Promise<void> {
  requireLiveSpace(m);
  if (m.state !== "active" || await env.DB.prepare(`SELECT 1 AS ok WHERE ${authorized}`)
    .bind(...authBindings(m)).first() === null) {
    throw new ApiError(410, "family_record_access_revoked", "This record is not accessible.");
  }
}
function presentation(row: RecordRow): Record<string, unknown> {
  return { id: row.id, entryID: row.entry_id, kind: row.kind, authorID: row.author_member_id,
    revision: row.revision, state: row.state, keyEpoch: row.key_epoch,
    ciphertext: row.ciphertext, createdAt: row.created_at, updatedAt: row.updated_at };
}
// Only the linked records created by a v2 moment have a fixed audience.
// The older independent catalog remains room-wide. Apply this to the entry ID
// so a linked photo's words cannot leak through the catalog or a direct URL.
const visibleEntry = (space: string, entry: string) => `(
  NOT EXISTS (SELECT 1 FROM family_record_moments link
    WHERE link.space_id=${space} AND link.photo_id=${entry})
  OR EXISTS (SELECT 1 FROM family_record_moment_readers reader
    WHERE reader.space_id=${space} AND reader.photo_id=${entry}
      AND reader.participant_id=?)
)`;

async function current(env: Env, m: AuthenticatedMember, id: string): Promise<RecordRow | null> {
  return env.DB.prepare(`SELECT record.* FROM family_records record
    WHERE record.space_id=? AND record.id=?
      AND ${visibleEntry("record.space_id", "record.entry_id")}`)
    .bind(m.spaceId, id, m.momentParticipantId).first<RecordRow>();
}

export async function momentSharedRecordCapacityReached(env: Env, spaceID: string, withWords: boolean): Promise<boolean> {
  const photoCount = await env.DB.prepare("SELECT COUNT(*) AS count FROM family_records WHERE space_id=? AND kind='photo'")
    .bind(spaceID).first<{ count: number }>();
  const wordsCount = withWords ? await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM family_records WHERE space_id=? AND kind='words'",
  ).bind(spaceID).first<{ count: number }>() : null;
  return photoCount !== null && photoCount.count >= FAMILY_RECORD_MAXIMUM_PHOTOS
    || withWords && wordsCount !== null && wordsCount.count >= FAMILY_RECORD_MAXIMUM_WORDS;
}

/** Stage ciphertext privately; the caller inserts these rows in the moment commit batch. */
export async function prepareMomentSharedRecordCommit(
  env: Env, m: AuthenticatedMember, record: MomentSharedRecord,
  clientRequestID: string, requestHash: string,
): Promise<{ statements: D1PreparedStatement[] }> {
  if (env.FAMILY_RECORD_RUNTIME_ENABLED !== "YES") {
    throw new ApiError(503, "family_record_runtime_disabled", "Shared records are unavailable.");
  }
  await assertAuthorized(env, m);
  await requireWindowDeliverySupport(env, m.spaceId);
  if (await current(env, m, record.photoID) !== null) {
    // A withdrawn record is a tombstone, never a slot for another upload.
    throw new ApiError(409, "family_record_conflict", "This photo record already exists.");
  }
  if (await momentSharedRecordCapacityReached(env, m.spaceId, record.wordsID !== null)) {
    throw new ApiError(409, "family_record_capacity", "Shared record capacity reached; nothing was sent.");
  }
  if (!env.MEDIA) throw new ApiError(503, "family_record_storage_unavailable", "Record storage unavailable.");
  const objectKey = `family-records/v1/${m.spaceId}/${record.photoID}/${crypto.randomUUID()}`;
  await env.DB.prepare(`INSERT INTO family_record_staged_objects(object_key,space_id,photo_id,created_at)
    VALUES (?,?,?,?)`).bind(objectKey, m.spaceId, record.photoID, m.now).run();
  await env.MEDIA.put(objectKey, record.photoBytes);
  const support = windowDeliverySupportGuard(env, m.spaceId);
  const guard = `${authorized} AND ${support.sql}`;
  const guardBindings = [...authBindings(m), ...support.bindings];
  const photo = env.DB.prepare(`INSERT INTO family_records VALUES (
      ?,?,?,'photo',?,1,'active',1,NULL,?, ?,
      CASE WHEN (SELECT COUNT(*) FROM family_records WHERE space_id=? AND kind='photo') < ?
        AND ${guard} THEN ? ELSE NULL END,
      ?,?,?)`).bind(
    m.spaceId, record.photoID, record.photoID, m.id, objectKey, record.photoBytes.length,
    m.spaceId, FAMILY_RECORD_MAXIMUM_PHOTOS, ...guardBindings, requestHash,
    clientRequestID, m.now, m.now,
  );
  const statements = [photo];
  if (record.wordsID !== null && record.wordsCiphertext !== null) {
    statements.push(env.DB.prepare(`INSERT INTO family_records VALUES (
        ?,?,?,'words',?,1,'active',1,?,NULL,?,
        CASE WHEN (SELECT COUNT(*) FROM family_records WHERE space_id=? AND kind='words') < ?
          AND ${guard} THEN ? ELSE NULL END,
        ?,?,?)`).bind(
      m.spaceId, record.wordsID, record.photoID, m.id, record.wordsCiphertext, record.wordsSize,
      m.spaceId, FAMILY_RECORD_MAXIMUM_WORDS, ...guardBindings, requestHash,
      clientRequestID, m.now, m.now,
    ));
  }
  statements.push(env.DB.prepare("DELETE FROM family_record_staged_objects WHERE object_key=?").bind(objectKey));
  return { statements };
}

export async function familyRecords(request: Request, env: Env, id?: string, photo = false): Promise<Response> {
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, "family-record"));
  const body = await readBody(request, 3 * 1024 * 1024);
  const m = await authenticateSignedRequest(request, env, body);
  await assertAuthorized(env, m);
  if (id === "capabilities" && request.method === "GET" && !photo) {
    requireEmptyBody(body);
    await consumeNonceAndTouch(env, m);
    return jsonResponse({ schemaVersion: 1 });
  }
  if (id !== undefined && !uuid.test(id)) throw new ApiError(404, "not_found", "Record not found.");
  if (request.method === "GET") {
    requireEmptyBody(body);
    if (id === undefined) {
      const rows = await env.DB.prepare(`SELECT record.* FROM family_records record
        WHERE record.space_id=? AND ${visibleEntry("record.space_id", "record.entry_id")}
        ORDER BY record.created_at DESC,record.id`)
        .bind(m.spaceId, m.momentParticipantId).all<RecordRow>();
      await assertAuthorized(env, m);
      await consumeNonceAndTouch(env, m);
      return jsonResponse({ schemaVersion: 1, spaceID: m.spaceId, participantID: m.id,
        maximumPhotos: FAMILY_RECORD_MAXIMUM_PHOTOS, records: rows.results.map(presentation) });
    }
    const row = await current(env, m, id);
    if (!photo || row?.kind !== "photo" || row.state !== "active" || !row.object_key || !env.MEDIA) {
      throw new ApiError(404, "not_found", "Photo not found.");
    }
    const object = await env.MEDIA.get(row.object_key);
    if (object === null) throw new ApiError(404, "family_record_photo_missing", "Photo unavailable.");
    // A concurrent withdrawal must not authorize a fetched older object.
    const latest = await current(env, m, id);
    await assertAuthorized(env, m);
    if (latest?.object_key !== row.object_key || latest.state !== "active") {
      throw new ApiError(410, "family_record_withdrawn", "Photo withdrawn.");
    }
    await consumeNonceAndTouch(env, m);
    return new Response(object.body, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store" } });
  }
  if (request.method !== "PUT" || id === undefined || photo) throw new ApiError(405, "method_not_allowed", "Unsupported operation.");
  const value = parseJsonBody(request, body);
  exactKeys(value, ["entryID", "kind", "expectedRevision", "operationID", "ciphertext"]);
  const entryID = uuidField(value, "entryID");
  const operationID = uuidField(value, "operationID");
  const kind = stringField(value, "kind");
  if (kind !== "photo" && kind !== "words") throw new ApiError(400, "invalid_kind", "Unsupported record.");
  const expected = integerField(value, "expectedRevision", 0, 1_000_000);
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
  if (prior ? (prior.author_member_id !== m.id || prior.revision !== expected || prior.state !== "active"
      || prior.kind !== kind || prior.entry_id !== entryID || (kind === "photo" && !withdrawing))
    : (expected !== 0 || withdrawing || (kind === "photo" && entryID !== id))) {
    throw new ApiError(409, "family_record_conflict", "Record changed or is not yours.");
  }
  if (kind === "words") {
    const entry = await current(env, m, entryID);
    if (entry?.kind !== "photo") throw new ApiError(404, "not_found", "Record not found.");
  }
  if (prior === null) {
    await requireWindowDeliverySupport(env, m.spaceId);
    const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM family_records WHERE space_id=? AND kind=?")
      .bind(m.spaceId, kind).first<{ count: number }>();
    if (!count || count.count >= (kind === "photo" ? FAMILY_RECORD_MAXIMUM_PHOTOS : FAMILY_RECORD_MAXIMUM_WORDS)) {
      throw new ApiError(409, "family_record_capacity", "Record capacity reached. Existing records are retained.");
    }
  }
  if (!env.MEDIA) throw new ApiError(503, "family_record_storage_unavailable", "Record storage unavailable.");
  // Unique per HTTP attempt: a losing concurrent replay must never delete the winner's object.
  const objectKey = kind === "photo" && bytes !== null
    ? `family-records/v1/${m.spaceId}/${id}/${crypto.randomUUID()}` : null;
  if (objectKey !== null && bytes !== null) await env.MEDIA.put(objectKey, bytes);
  const row: RecordRow = { space_id: m.spaceId, id, entry_id: entryID, kind,
    author_member_id: m.id, revision: expected + 1, state: withdrawing ? "withdrawn" : "active",
    key_epoch: 1, ciphertext: kind === "words" ? encoded : null, object_key: objectKey,
    ciphertext_size: bytes?.length ?? 0, payload_hash: payloadHash, last_operation_id: operationID,
    created_at: prior?.created_at ?? m.now, updated_at: m.now };
  let committed = false;
  try {
    const support = windowDeliverySupportGuard(env, m.spaceId);
    const mutation = prior === null
      ? env.DB.prepare(`INSERT INTO family_records SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
          WHERE ${authorized} AND (SELECT COUNT(*) FROM family_records WHERE space_id=? AND kind=?) < ?
          AND ${support.sql} AND ${visibleEntry("?", "?")}
          ON CONFLICT(space_id,id) DO NOTHING`).bind(...Object.values(row), ...authBindings(m), m.spaceId, kind,
          kind === "photo" ? FAMILY_RECORD_MAXIMUM_PHOTOS : FAMILY_RECORD_MAXIMUM_WORDS, ...support.bindings,
          m.spaceId, entryID, m.spaceId, entryID, m.momentParticipantId)
      : env.DB.prepare(`UPDATE family_records SET revision=?,state=?,ciphertext=?,object_key=?,ciphertext_size=?,
          payload_hash=?,last_operation_id=?,updated_at=? WHERE space_id=? AND id=? AND revision=?
          AND author_member_id=? AND state='active' AND ${authorized}
          AND ${visibleEntry("?", "?")}`)
        .bind(row.revision, row.state, row.ciphertext, row.object_key, row.ciphertext_size,
          row.payload_hash, row.last_operation_id, row.updated_at, m.spaceId, id, expected, m.id,
          ...authBindings(m), m.spaceId, entryID, m.spaceId, entryID, m.momentParticipantId);
    const deletion = prior?.object_key ? [env.DB.prepare(
      `INSERT OR IGNORE INTO family_record_object_deletions SELECT ?,?
       WHERE EXISTS (SELECT 1 FROM family_records WHERE space_id=? AND id=?
         AND state='withdrawn' AND last_operation_id=?)`)
      .bind(prior.object_key, m.now, m.spaceId, id, operationID)] : [];
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
           AND record.last_operation_id=? AND delivery.state IN ('pending','acknowledged')`)
        .bind(m.now, m.spaceId, id, operationID),
      env.DB.prepare(`UPDATE moment_deliveries SET state='revoked',revoked_at=?
        WHERE moment_id=(SELECT link.moment_id FROM family_record_moments AS link
          JOIN family_records AS record ON record.space_id=link.space_id AND record.id=link.photo_id
          WHERE link.space_id=? AND link.photo_id=? AND record.state='withdrawn'
            AND record.last_operation_id=?) AND state IN ('pending','acknowledged')`)
        .bind(m.now, m.spaceId, id, operationID),
    ] : [];
    const result = await env.DB.batch([
      ...nonceStatements(env, m), mutation, ...linkedRevocation, ...deletion, activityStatement(env, m),
    ]);
    committed = result[2]?.meta.changes === 1;
    const saved = await current(env, m, id);
    await assertAuthorized(env, m);
    if (!committed && !(saved?.last_operation_id === operationID && saved.payload_hash === payloadHash)) {
      if (prior === null) await requireWindowDeliverySupport(env, m.spaceId);
      throw new ApiError(409, "family_record_conflict_or_capacity", "Record changed or storage capacity was reached.");
    }
    if (!saved) throw new ApiError(503, "family_record_unavailable", "Record temporarily unavailable.");
    return jsonResponse({ record: presentation(saved) });
  } finally {
    if (!committed && objectKey !== null) {
      // A lost D1 response is not proof of rollback. Preserve ambiguous data.
      try {
        const saved = await current(env, m, id);
        if (saved?.object_key !== objectKey) await env.MEDIA.delete(objectKey);
      } catch { /* Leave ambiguous ciphertext intact; do not undo a possible commit. */ }
    }
  }
}

export async function runFamilyRecordCleanup(env: Env, now = Math.floor(Date.now() / 1000)): Promise<void> {
  if (!env.MEDIA) return;
  const rows = await env.DB.prepare("SELECT object_key FROM family_record_object_deletions ORDER BY created_at LIMIT 20")
    .all<{ object_key: string }>();
  for (const row of rows.results) {
    if (!row.object_key.startsWith("family-records/v1/")) throw new Error("Invalid family record deletion scope");
    await env.MEDIA.delete(row.object_key);
    await env.DB.prepare("DELETE FROM family_record_object_deletions WHERE object_key=?").bind(row.object_key).run();
  }
  // Beyond the two-day commit replay lease, an orphan cannot still be a live
  // pending commit. Keep any ciphertext that the catalog actually references.
  const staged = await env.DB.prepare(`SELECT object_key,space_id,photo_id
    FROM family_record_staged_objects WHERE created_at <= ? ORDER BY created_at LIMIT 20`)
    .bind(now - 3 * 24 * 60 * 60)
    .all<{ object_key: string; space_id: string; photo_id: string }>();
  for (const row of staged.results) {
    if (!row.object_key.startsWith(`family-records/v1/${row.space_id}/${row.photo_id}/`)) {
      throw new Error("Invalid staged family record deletion scope");
    }
    const current = await env.DB.prepare("SELECT object_key FROM family_records WHERE space_id=? AND id=?")
      .bind(row.space_id, row.photo_id).first<{ object_key: string | null }>();
    if (current?.object_key !== row.object_key) await env.MEDIA.delete(row.object_key);
    await env.DB.prepare("DELETE FROM family_record_staged_objects WHERE object_key=?").bind(row.object_key).run();
  }
}
