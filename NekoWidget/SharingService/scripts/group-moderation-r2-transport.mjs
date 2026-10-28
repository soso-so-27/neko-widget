import {createOwnerR2TransportForReviewHost} from './moderation-owner-r2-transport.mjs';
import {groupModerationReviewSourceBinding, withBoundGroupModerationReview} from './group-moderation-bound-review-lib.mjs';
const fail = () => {throw new Error('group_moderation_review_unavailable');};

/** Fixed v3 factory for trusted startup code. The common transport alone owns
 * R2 scope, Windows custody checks, restricted key reads and owned-buffer wipes.
 * Neither a browser nor a JSON setting can choose this factory or its sink. */
export function createLocalGroupOwnerReviewHost(adapters) {
  const readCiphertext = adapters?.readCiphertext, readReviewedKey = adapters?.readReviewedKey;
  if (typeof readCiphertext !== 'function' || typeof readReviewedKey !== 'function') fail();
  return async function review(input) {
    const signal = input?.signal, readCurrentSource = input?.readCurrentSource, audit = input?.audit;
    let output;
    const active = () => {if (!(signal instanceof AbortSignal) || signal.aborted) fail();};
    try {
      active();
      if (typeof readCurrentSource !== 'function' || typeof audit !== 'function') fail();
      const ref = Object.freeze({caseReferenceHmac: input.source.caseReferenceHmac,
        caseReferenceHmacKeyVersion: input.source.caseReferenceHmacKeyVersion});
      const expected = groupModerationReviewSourceBinding(input.source, ref).sourceSHA256;
      if (expected !== input.sourceSHA256) fail();
      await withBoundGroupModerationReview(ref, {
        async readCurrentSource() {
          active(); const current = await readCurrentSource(); active();
          if (groupModerationReviewSourceBinding(current, ref).sourceSHA256 !== expected) fail();
          return current;
        },
        readCiphertext,
        readReviewedKey,
        async audit(event) {
          active();
          if (event.phase === 'started' || event.phase === 'disclosure_ready') await audit(event.phase);
          // The authenticated server handler records its own receipt only after
          // this host returns; a local sink copy is not delivery to the browser.
          active();
        },
      }, ({jpeg}) => {active(); output = Uint8Array.from(jpeg);}, {signal});
      active();
      if (!output) fail();
      return output;
    } catch {output?.fill(0); fail();}
  };
}

export function createGroupOwnerR2Transport(config) {
  return createOwnerR2TransportForReviewHost(config, createLocalGroupOwnerReviewHost);
}
