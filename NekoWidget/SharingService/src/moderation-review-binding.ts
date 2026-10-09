import type { LocalModerationReviewSource } from "./moderation-review-source";

/** DB-owned snapshot only. This is the same ordered source binding used by
 * moderation-bound-review-lib.mjs; it is not an authorization or image proof. */
export async function localModerationReviewSourceSHA256(source: LocalModerationReviewSource): Promise<string> {
  const m = source.metadata;
  const bytes = new TextEncoder().encode(JSON.stringify([
    source.schema, source.caseReferenceHmacKeyVersion, source.caseReferenceHmac,
    source.objectKey, m.schema, m.protocolVersion, m.envelopeDomain, m.algorithm,
    m.reportId, m.momentId, m.reporterParticipantId, m.reasonCode, m.moderationKeyId,
    m.ciphertextSize, m.ciphertextSHA256, m.committedAt, m.contentExpiresAt,
  ]));
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map(value => value.toString(16).padStart(2, "0")).join("");
}
