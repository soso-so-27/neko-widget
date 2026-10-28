import {createHash} from 'node:crypto';
import {verifyReviewedModerationPrivateKey} from './moderation-report-lib.mjs';
import {decryptGroupModerationReport, validateGroupModerationMetadata} from './group-moderation-report-lib.mjs';

export const GROUP_MODERATION_REVIEW_SOURCE_SCHEMA = 'jp.nekowidget.group-moderation-review-source.v1';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = () => {throw new Error('group_moderation_review_unavailable');};
function exact(value, expected) {
  if (!value || Object.getPrototypeOf(value) !== Object.prototype
      || Reflect.ownKeys(value).length !== expected.length || expected.some(key => !Object.hasOwn(value, key))) fail();
  for (const key of expected) {
    const property = Object.getOwnPropertyDescriptor(value, key);
    if (!property?.enumerable || !Object.hasOwn(property, 'value')) fail();
  }
}
function reference(value) {
  exact(value, ['caseReferenceHmac', 'caseReferenceHmacKeyVersion']);
  if (typeof value.caseReferenceHmac !== 'string' || !/^[0-9a-f]{64}$/u.test(value.caseReferenceHmac)
      || !Number.isInteger(value.caseReferenceHmacKeyVersion) || value.caseReferenceHmacKeyVersion < 1
      || value.caseReferenceHmacKeyVersion > 2147483647) fail();
  return Object.freeze({...value});
}

/** Exact DB-owned snapshot. The digest binds identity; it does not grant access.
 * This ordered list is also the server-side sourceSHA256 contract. */
export function groupModerationReviewSourceBinding(value, expectedReference) {
  try {
    const ref = reference(expectedReference);
    exact(value, ['schema', 'caseReferenceHmac', 'caseReferenceHmacKeyVersion', 'objectKey', 'metadata']);
    if (value.schema !== GROUP_MODERATION_REVIEW_SOURCE_SCHEMA || value.caseReferenceHmac !== ref.caseReferenceHmac
        || value.caseReferenceHmacKeyVersion !== ref.caseReferenceHmacKeyVersion) fail();
    const m = validateGroupModerationMetadata(value.metadata);
    if (typeof value.objectKey !== 'string'
        || !new RegExp(`^groups/reports/v3/${m.reportId}/[A-Za-z0-9_-]{32}$`, 'u').test(value.objectKey)) fail();
    const source = Object.freeze({...value, metadata: m});
    const sourceSHA256 = hash(JSON.stringify([source.schema, ref.caseReferenceHmacKeyVersion, ref.caseReferenceHmac,
      source.objectKey, m.schema, m.protocolVersion, m.envelopeDomain, m.algorithm, m.reportId, m.windowId,
      m.momentId, m.reporterParticipantId, m.reasonCode, m.moderationKeyId,
      m.ciphertextSize, m.ciphertextSHA256, m.committedAt, m.contentExpiresAt]));
    return Object.freeze({source, sourceSHA256});
  } catch {fail();}
}

/** Isolated trusted Node host only, with no network/file transport of its own.
 * readCurrentSource must reauthorize owner/session/one-case read scope every
 * time. The sink is fixed local UI code, never a caller-selected destination.
 * The result proves submitted-evidence provenance, not human review or a grant.
 * Already delivered bytes cannot be recalled from every browser/runtime copy. */
export async function withBoundGroupModerationReview(expectedReference, adapters, consume,
  {maximumDurationMs = 60000, signal: parentSignal} = {}) {
  const ref = reference(expectedReference);
  for (const name of ['readCurrentSource', 'readCiphertext', 'readReviewedKey', 'audit']) {
    if (typeof adapters?.[name] !== 'function') fail();
  }
  if (typeof consume !== 'function' || !Number.isInteger(maximumDurationMs)
      || maximumDurationMs < 1 || maximumDurationMs > 60000
      || (parentSignal !== undefined && !(parentSignal instanceof AbortSignal))) fail();
  const {readCurrentSource, readCiphertext, readReviewedKey, audit} = adapters;
  let expiresAt = Date.now() + maximumDurationMs;
  const monotonicStart = performance.now(), controller = new AbortController();
  const cancel = () => controller.abort();
  parentSignal?.addEventListener('abort', cancel, {once: true});
  if (parentSignal?.aborted) cancel();
  const remaining = () => Math.min(expiresAt - Date.now(), maximumDurationMs - (performance.now() - monotonicStart));
  function active() {if (controller.signal.aborted || remaining() <= 0) {controller.abort(); fail();}}
  async function step(operation) {
    active();
    let timer, onAbort;
    try {
      return await new Promise((resolve, reject) => {
        onAbort = () => reject(new Error('cancelled'));
        controller.signal.addEventListener('abort', onAbort, {once: true});
        timer = setTimeout(() => controller.abort(), Math.ceil(remaining()));
        Promise.resolve().then(() => {active(); return operation(controller.signal);}).then(value => {
          try {active(); resolve(value);} catch {reject(new Error('expired'));}
        }, reject);
      });
    } finally {clearTimeout(timer); controller.signal.removeEventListener('abort', onAbort);}
  }
  let ciphertext, privateKey, publicKey, jpeg, event;
  try {
    const bound = groupModerationReviewSourceBinding(await step(s => readCurrentSource(ref, s)), ref);
    expiresAt = Math.min(expiresAt, bound.source.metadata.contentExpiresAt * 1000);
    event = Object.freeze({schema: 'jp.nekowidget.group-moderation-local-review.v1', ...ref, sourceSHA256: bound.sourceSHA256});
    async function recheck() {
      active();
      const current = await step(s => readCurrentSource(ref, s));
      if (groupModerationReviewSourceBinding(current, ref).sourceSHA256 !== bound.sourceSHA256) fail();
      active();
    }
    await step(s => audit(Object.freeze({...event, phase: 'started'}), s));
    await recheck();
    const fetched = await step(s => readCiphertext(bound.source, s));
    if (!(fetched instanceof Uint8Array) || fetched.byteLength !== bound.source.metadata.ciphertextSize) fail();
    ciphertext = Buffer.from(fetched);
    await recheck();
    const reviewed = await step(s => readReviewedKey(bound.source.metadata.moderationKeyId, s));
    if (!(reviewed?.privateKeyBytes instanceof Uint8Array) || reviewed.privateKeyBytes.byteLength !== 32
        || !(reviewed.companionPublicKeyBytes instanceof Uint8Array) || reviewed.companionPublicKeyBytes.byteLength !== 43) fail();
    privateKey = Buffer.from(reviewed.privateKeyBytes);
    publicKey = Buffer.from(reviewed.companionPublicKeyBytes);
    verifyReviewedModerationPrivateKey({reviewedKeyId: reviewed.reviewedKeyId, metadataKeyId: 'moderation-v2',
      privateKeyBytes: privateKey, companionPublicKeyBytes: publicKey, expectedPublicKeySHA256: reviewed.expectedPublicKeySHA256});
    await recheck();
    const decoded = decryptGroupModerationReport(bound.source.metadata, ciphertext, privateKey);
    jpeg = decoded.canonicalJPEG;
    const receipt = Object.freeze({...event, jpegSHA256: hash(jpeg),
      width: decoded.dimensions.width, height: decoded.dimensions.height, expiresAt});
    await step(s => audit(Object.freeze({...event, phase: 'disclosure_ready'}), s));
    await recheck();
    await step(s => consume(Object.freeze({jpeg, receipt}), s));
    await step(s => audit(Object.freeze({...event, phase: 'sink_completed'}), s));
    return receipt;
  } catch {
    if (event) {
      try {await step(s => audit(Object.freeze({...event, phase: 'failed_or_delivery_unknown'}), s));} catch { /* unresolved audit remains unresolved */ }
    }
    fail();
  } finally {
    controller.abort(); parentSignal?.removeEventListener('abort', cancel);
    for (const bytes of [ciphertext, privateKey, publicKey, jpeg]) bytes?.fill(0);
  }
}
