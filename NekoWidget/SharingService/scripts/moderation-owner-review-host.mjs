import { moderationReviewSourceBinding, withBoundModerationReview } from "./moderation-bound-review-lib.mjs";

/** Isolated Node composition for LocalOwnerReviewHost. Only trusted deployment
 * code supplies object/key readers. No HTTP route, key transport or permission
 * registration is created. The local owner handler owns current authorization,
 * the durable one-use claim, audit and receipt/decision persistence. */
export function createLocalOwnerReviewHost(adapters) {
  const readCiphertext = adapters?.readCiphertext;
  const readReviewedKey = adapters?.readReviewedKey;
  if (typeof readCiphertext !== "function" || typeof readReviewedKey !== "function") {
    throw new Error("owner_review_unavailable");
  }
  return async function review(input) {
    const parentSignal = input?.signal;
    const readCurrentSource = input?.readCurrentSource;
    const audit = input?.audit;
    let output;
    function active() {
      if (!(parentSignal instanceof AbortSignal) || parentSignal.aborted) throw new Error("owner_review_unavailable");
    }
    try {
      active();
      if (typeof readCurrentSource !== "function" || typeof audit !== "function") throw new Error("owner_review_unavailable");
      const ref = Object.freeze({ caseReferenceHmac: input.source.caseReferenceHmac,
        caseReferenceHmacKeyVersion: input.source.caseReferenceHmacKeyVersion });
      const expected = moderationReviewSourceBinding(input.source, ref).sourceSHA256;
      if (expected !== input.sourceSHA256) throw new Error("owner_review_unavailable");
      await withBoundModerationReview(ref, {
        async readCurrentSource() {
          active();
          const current = await readCurrentSource();
          active();
          if (moderationReviewSourceBinding(current, ref).sourceSHA256 !== expected) throw new Error("owner_review_unavailable");
          return current;
        },
        async readCiphertext(source, signal) {
          active();
          const value = await readCiphertext(source, AbortSignal.any([parentSignal, signal]));
          active(); return value;
        },
        async readReviewedKey(id, signal) {
          active();
          const value = await readReviewedKey(id, AbortSignal.any([parentSignal, signal]));
          active(); return value;
        },
        async audit(event) {
          active();
          if (event.phase === "started" || event.phase === "disclosure_ready") await audit(event.phase);
          // The caller records its own receipt only after this host resolves.
          // A local sink copy is not proof that an HTTP/browser delivery ended.
          active();
        },
      }, ({ jpeg }) => { active(); output = Uint8Array.from(jpeg); });
      active();
      if (!output) throw new Error("owner_review_unavailable");
      return output;
    } catch {
      output?.fill(0);
      throw new Error("owner_review_unavailable");
    }
  };
}
