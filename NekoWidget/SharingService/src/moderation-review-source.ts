export interface LocalModerationReviewReference {
  caseReferenceHmac: string;
  caseReferenceHmacKeyVersion: number;
}

export interface LocalModerationReviewSource extends LocalModerationReviewReference {
  schema: "jp.nekowidget.moderation-review-source.v1";
  objectKey: string;
  metadata: {
    schema: "jp.nekowidget.moderation-export.v1";
    protocolVersion: 2;
    envelopeDomain: "NW2.MODERATION-REPORT";
    algorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305";
    reportId: string;
    momentId: string;
    reporterParticipantId: string;
    reasonCode: "objectionable" | "harassment" | "privacy" | "other";
    moderationKeyId: string;
    ciphertextSize: number;
    ciphertextSHA256: string;
    committedAt: number;
    contentExpiresAt: number;
  };
}

interface SourceRow {
  case_reference_hmac: string;
  case_reference_hmac_key_version: number;
  object_key: string;
  id: string;
  moment_id: string;
  reporter_participant_id: string;
  reason_code: LocalModerationReviewSource["metadata"]["reasonCode"];
  moderation_key_id: string;
  ciphertext_size: number;
  ciphertext_sha256: string;
  committed_at: number;
  content_expires_at: number;
}

/** LOCAL internal metadata adapter, NOT a public route, authentication or grant.
 * The caller must complete owner authentication, current permission checks and
 * successful auditing before entry. IDs/object keys returned here are private:
 * do not log them or return this snapshot through the public/queue endpoints.
 * One DB statement preserves the live view's commit/tombstone/TTL and legacy
 * terminal-decision exclusions, and excludes pending/already-deleted objects.
 * This is a point-in-time snapshot, not a lease. Re-read and compare it before
 * consuming decrypted evidence; the Node consumer must validate exact metadata
 * and bind the ciphertext digest/envelope to this report. No image, key, object
 * fetch, grant, write, TTL extension or authorization is performed here.
 * Invalid, absent, stale and unavailable sources all return null (fail closed).
 */
export async function readLocalModerationReviewSource(
  db: D1Database, reference: LocalModerationReviewReference,
): Promise<LocalModerationReviewSource | null> {
  try {
    if (reference === null || typeof reference !== "object"
        || Object.getPrototypeOf(reference) !== Object.prototype
        || Reflect.ownKeys(reference).length !== 2) return null;
    const fields = Object.getOwnPropertyDescriptors(reference);
    const hmac = fields.caseReferenceHmac;
    const version = fields.caseReferenceHmacKeyVersion;
    if (!hmac || !version || !("value" in hmac) || !("value" in version)
        || !hmac.enumerable || !version.enumerable || typeof hmac.value !== "string"
        || !/^[0-9a-f]{64}$/u.test(hmac.value) || !Number.isSafeInteger(version.value)
        || version.value < 1 || version.value > 0x7fff_ffff) return null;
    // Bind only owned primitive values before the first await; never re-read a
    // mutable caller reference when returning the database's current binding.
    const row = await db.prepare(`SELECT s.case_reference_hmac, s.case_reference_hmac_key_version,
      r.object_key, r.id, r.moment_id, r.reporter_participant_id, r.reason_code,
      r.moderation_key_id, r.ciphertext_size, r.ciphertext_sha256, r.committed_at, r.content_expires_at
      FROM moderation_advisory_live_sources AS s
      JOIN moment_reports AS r ON r.id = s.report_id
      WHERE s.case_reference_hmac = ? AND s.case_reference_hmac_key_version = ?
        AND NOT EXISTS (SELECT 1 FROM moment_object_deletions AS d
          WHERE d.object_key = r.object_key OR (d.object_type = 'report' AND d.owner_id = r.id))`)
      .bind(hmac.value, version.value).first<SourceRow>();
    if (!row) return null;
    return {
      schema: "jp.nekowidget.moderation-review-source.v1",
      caseReferenceHmac: row.case_reference_hmac,
      caseReferenceHmacKeyVersion: row.case_reference_hmac_key_version,
      objectKey: row.object_key,
      metadata: {
        schema: "jp.nekowidget.moderation-export.v1", protocolVersion: 2,
        envelopeDomain: "NW2.MODERATION-REPORT", algorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
        reportId: row.id, momentId: row.moment_id, reporterParticipantId: row.reporter_participant_id,
        reasonCode: row.reason_code, moderationKeyId: row.moderation_key_id,
        ciphertextSize: row.ciphertext_size, ciphertextSHA256: row.ciphertext_sha256,
        committedAt: row.committed_at, contentExpiresAt: row.content_expires_at,
      },
    };
  } catch {
    // Do not expose SQL errors or report identifiers through the consumer.
    return null;
  }
}
