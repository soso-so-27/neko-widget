import { createHash } from "node:crypto";
import {
  decryptModerationReport,
  validateModerationMetadata,
  verifyReviewedModerationPrivateKey,
} from "./moderation-report-lib.mjs";

const schema = "jp.nekowidget.moderation-review-source.v1";
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const fail = () => { throw new Error("moderation_review_unavailable"); };
function keys(value, expected) {
  if (!value || Object.getPrototypeOf(value) !== Object.prototype
      || Object.keys(value).length !== expected.length
      || expected.some(key => !Object.hasOwn(value, key))) fail();
}
function reference(value) {
  keys(value, ["caseReferenceHmac", "caseReferenceHmacKeyVersion"]);
  if (typeof value.caseReferenceHmac !== "string" || !/^[0-9a-f]{64}$/.test(value.caseReferenceHmac)
      || !Number.isInteger(value.caseReferenceHmacKeyVersion)
      || value.caseReferenceHmacKeyVersion < 1 || value.caseReferenceHmacKeyVersion > 2147483647) fail();
  return Object.freeze({...value});
}

/** The snapshot MUST come from the authenticated, authorized source adapter,
 * never a browser upload. Its digest is a binding, not proof of permission.
 * Explicit field ordering also prevents JSON property order changing identity.
 */
export function moderationReviewSourceBinding(value, expectedReference) {
  const ref = reference(expectedReference);
  keys(value, ["schema", "caseReferenceHmac", "caseReferenceHmacKeyVersion", "objectKey", "metadata"]);
  if (value.schema !== schema || value.caseReferenceHmac !== ref.caseReferenceHmac
      || value.caseReferenceHmacKeyVersion !== ref.caseReferenceHmacKeyVersion
      || typeof value.objectKey !== "string" || value.objectKey.length < 1
      || Buffer.byteLength(value.objectKey) > 1024 || /[\u0000-\u0020\u007f]/u.test(value.objectKey)) fail();
  const m = validateModerationMetadata(value.metadata);
  const source = Object.freeze({...value, metadata: m});
  const sourceSHA256 = sha(JSON.stringify([schema, ref.caseReferenceHmacKeyVersion, ref.caseReferenceHmac,
    source.objectKey, m.schema, m.protocolVersion, m.envelopeDomain, m.algorithm,
    m.reportId, m.momentId, m.reporterParticipantId, m.reasonCode, m.moderationKeyId,
    m.ciphertextSize, m.ciphertextSHA256, m.committedAt, m.contentExpiresAt]));
  return Object.freeze({source, sourceSHA256});
}

/** INTERNAL isolated-Node boundary only. No Worker/HTTP route imports this.
 * All adapters are trusted host code, not client/model-selected callbacks.
 * readCurrentSource must recheck owner authorization, credential/session epoch,
 * one-case content-read scope and current DB source on EVERY call. A triage role
 * or review_start receipt alone is insufficient. audit must durably record
 * before reading and before disclosure. No live adapters/grants are provided.
 *
 * This function proves exact ciphertext->JPEG provenance; it does NOT issue a
 * disclosure grant, create an export, authorize AI transport, decide a case or
 * send a reply. It does not persist plaintext. consume is the fixed local UI
 * sink. Bytes already delivered to that sink cannot be recalled or securely
 * erased from all runtime/browser copies.
 */
export async function withBoundModerationReview(expectedReference, adapters, consume, {maximumDurationMs = 60000} = {}) {
  const ref = reference(expectedReference);
  for (const name of ["readCurrentSource", "readCiphertext", "readReviewedKey", "audit"]) {
    if (typeof adapters?.[name] !== "function") fail();
  }
  if (typeof consume !== "function") fail();
  if (!Number.isInteger(maximumDurationMs) || maximumDurationMs < 1 || maximumDurationMs > 60000) fail();
  // Capture trusted operations before yielding; mutable caller configuration
  // cannot switch the source/key/audit/sink halfway through one review.
  const {readCurrentSource, readCiphertext, readReviewedKey, audit} = adapters;
  const startedAt = Date.now();
  const startedMonotonic = performance.now();
  let expiresAt = startedAt + maximumDurationMs;
  const controller = new AbortController();
  const remaining = () => Math.min(expiresAt - Date.now(), maximumDurationMs - (performance.now() - startedMonotonic));
  // Each awaited operation is bounded, including audit and the sink. Racing an
  // entire async workflow would allow a late continuation to disclose bytes.
  // Racing each step means rejection exits the only continuation immediately.
  async function step(operation) {
    if (controller.signal.aborted || remaining() <= 0) {controller.abort(); fail();}
    let timer;
    try {
      return await new Promise((resolve, reject) => {
        timer = setTimeout(() => {controller.abort(); reject(new Error("deadline"));}, Math.ceil(remaining()));
        Promise.resolve().then(() => {
          if (controller.signal.aborted || remaining() <= 0) {controller.abort(); fail();}
          return operation(controller.signal);
        }).then(value => {
          if (controller.signal.aborted || remaining() <= 0) {controller.abort(); reject(new Error("deadline"));}
          else resolve(value);
        }, reject);
      });
    } finally {clearTimeout(timer);}
  }
  let ciphertext, privateKey, publicKey, jpeg;
  let event;
  try {
    const current = await step(signal => readCurrentSource(ref, signal));
    const bound = moderationReviewSourceBinding(current, ref);
    expiresAt = Math.min(expiresAt, bound.source.metadata.contentExpiresAt * 1000);
    event = Object.freeze({schema: "jp.nekowidget.moderation-local-review.v1",
      caseReferenceHmac: ref.caseReferenceHmac,
      caseReferenceHmacKeyVersion: ref.caseReferenceHmacKeyVersion,
      sourceSHA256: bound.sourceSHA256});
    async function recheck() {
      if (remaining() <= 0) fail();
      const next = await step(signal => readCurrentSource(ref, signal));
      if (moderationReviewSourceBinding(next, ref).sourceSHA256 !== bound.sourceSHA256
          || remaining() <= 0) fail();
    }
    await step(signal => audit(Object.freeze({...event, phase: "started"}), signal));
    await recheck();
    const fetched = await step(signal => readCiphertext(bound.source, signal));
    if (!(fetched instanceof Uint8Array) || fetched.byteLength !== bound.source.metadata.ciphertextSize) fail();
    ciphertext = Buffer.from(fetched);
    await recheck();
    const key = await step(signal => readReviewedKey(bound.source.metadata.moderationKeyId, signal));
    if (!(key?.privateKeyBytes instanceof Uint8Array) || key.privateKeyBytes.byteLength !== 32
        || !(key.companionPublicKeyBytes instanceof Uint8Array) || key.companionPublicKeyBytes.byteLength !== 43) fail();
    privateKey = Buffer.from(key.privateKeyBytes);
    publicKey = Buffer.from(key.companionPublicKeyBytes);
    verifyReviewedModerationPrivateKey({reviewedKeyId: key.reviewedKeyId,
      metadataKeyId: bound.source.metadata.moderationKeyId, privateKeyBytes: privateKey,
      companionPublicKeyBytes: publicKey, expectedPublicKeySHA256: key.expectedPublicKeySHA256});
    const decoded = decryptModerationReport(bound.source.metadata, ciphertext, privateKey);
    jpeg = decoded.canonicalJPEG;
    const receipt = Object.freeze({...event, jpegSHA256: sha(jpeg), width: decoded.dimensions.width,
      height: decoded.dimensions.height, expiresAt});
    // Persist the disclosure attempt first, then check current authority/source
    // again. A failed audit or changed source releases zero bytes to the sink.
    await step(signal => audit(Object.freeze({...event, phase: "disclosure_ready"}), signal));
    await recheck();
    await step(signal => consume(Object.freeze({jpeg, receipt}), signal));
    await step(signal => audit(Object.freeze({...event, phase: "sink_completed"}), signal));
    return receipt;
  } catch {
    if (event) {
      try { await step(signal => audit(Object.freeze({...event, phase: "failed_or_delivery_unknown"}), signal)); } catch { /* incomplete audit remains unresolved */ }
    }
    // No identities, object keys, crypto internals or adapter errors escape.
    fail();
  } finally {
    controller.abort();
    ciphertext?.fill(0); privateKey?.fill(0); publicKey?.fill(0); jpeg?.fill(0);
  }
}
