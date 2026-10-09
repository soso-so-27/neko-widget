import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { createLocalOwnerReviewHost } from "../scripts/moderation-owner-review-host.mjs";
import { moderationReviewSourceBinding } from "../scripts/moderation-bound-review-lib.mjs";
import { deriveRawModerationPublicKey } from "../scripts/moderation-report-lib.mjs";
import { createSyntheticModerationBundle, SYNTHETIC_CANONICAL_JPEG } from "../scripts/moderation-staging-drill-lib.mjs";
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
function fixture() {
  const privateKeyBytes = randomBytes(32), raw = deriveRawModerationPublicKey(privateKeyBytes);
  const bundle = createSyntheticModerationBundle(raw);
  const ref = { caseReferenceHmac: "a".repeat(64), caseReferenceHmacKeyVersion: 1 };
  const source = { schema: "jp.nekowidget.moderation-review-source.v1", ...ref,
    objectKey: "reports/owner-synthetic", metadata: { ...bundle.metadata } };
  const abort = new AbortController(), phases = []; let reads = 0, fetches = 0;
  const adapters = { async readCiphertext() { fetches++; return bundle.envelopeBytes; },
    async readReviewedKey() { return { privateKeyBytes, companionPublicKeyBytes: Buffer.from(raw.toString("base64url")),
      reviewedKeyId: "moderation-v1", expectedPublicKeySHA256: hash(raw) }; } };
  const input = { source, sourceSHA256: moderationReviewSourceBinding(source, ref).sourceSHA256,
    signal: abort.signal, async readCurrentSource() { reads++; return source; }, async audit(phase) { phases.push(phase); } };
  return { adapters, input, abort, phases, get reads() { return reads; }, get fetches() { return fetches; } };
}
test("owner host composes real encryption and returns an owned JPEG only after both audits", async () => {
  const f=fixture(), host=createLocalOwnerReviewHost(f.adapters);
  const jpeg=await host(f.input);
  assert.deepEqual(Buffer.from(jpeg),SYNTHETIC_CANONICAL_JPEG);
  assert.deepEqual(f.phases,["started","disclosure_ready"]);assert.ok(f.reads>=4);assert.equal(f.fetches,1);
  jpeg.fill(0);assert.notEqual(SYNTHETIC_CANONICAL_JPEG[0],0);
});
test("another exact source digest is rejected before fetching ciphertext", async()=>{
  const f=fixture();f.input.sourceSHA256="0".repeat(64);
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input),{message:"owner_review_unavailable"});
  assert.equal(f.fetches,0);
});
test("parent cancellation before invocation releases no image or object request",async()=>{
  const f=fixture();f.abort.abort();
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input));assert.equal(f.fetches,0);
});
test("revocation during a slow key read prevents the JPEG sink",async()=>{
  const f=fixture(), original=f.adapters.readReviewedKey;
  f.adapters.readReviewedKey=async()=>{const key=await original();f.abort.abort();return key};
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input));assert.deepEqual(f.phases,["started"]);
});
test("failed disclosure audit prevents output",async()=>{
  const f=fixture();f.input.audit=async phase=>{f.phases.push(phase);if(phase==='disclosure_ready')throw Error('db unavailable')};
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input));assert.deepEqual(f.phases,["started","disclosure_ready"]);
});
