import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { withBoundModerationReview, moderationReviewSourceBinding } from "../scripts/moderation-bound-review-lib.mjs";
import { deriveRawModerationPublicKey } from "../scripts/moderation-report-lib.mjs";
import { createSyntheticModerationBundle, SYNTHETIC_CANONICAL_JPEG } from "../scripts/moderation-staging-drill-lib.mjs";

const digest = bytes => createHash("sha256").update(bytes).digest("hex");
function fixture() {
  const privateKeyBytes = randomBytes(32);
  const raw = deriveRawModerationPublicKey(privateKeyBytes);
  const bundle = createSyntheticModerationBundle(raw);
  const ref = {caseReferenceHmac: "a".repeat(64), caseReferenceHmacKeyVersion: 1};
  const source = {schema: "jp.nekowidget.moderation-review-source.v1", ...ref,
    objectKey: "reports/synthetic-case", metadata: {...bundle.metadata}};
  const events = [];
  const key = {privateKeyBytes, companionPublicKeyBytes: Buffer.from(raw.toString("base64url")),
    reviewedKeyId: "moderation-v1", expectedPublicKeySHA256: digest(raw)};
  return {source, ref, events, bundle, key, reads: 0, adapter: {
    // Synthetic authorization only. This fixture is NOT a live owner grant.
    async readCurrentSource() { return source; },
    async readCiphertext(snapshot) { assert.equal(snapshot.metadata.reportId, bundle.metadata.reportId); return bundle.envelopeBytes; },
    async readReviewedKey(id) { assert.equal(id, "moderation-v1"); return key; },
    async audit(event) { events.push(event); },
  }};
}
async function rejected(f, sink = () => assert.fail("plaintext escaped")) {
  await assert.rejects(withBoundModerationReview(f.ref, f.adapter, sink), {message: "moderation_review_unavailable"});
}

test("real X25519/ChaCha report is tied to exact case/source and sink bytes are cleared", async () => {
  const f = fixture(); let delivered;
  const originalKey = Buffer.from(f.key.privateKeyBytes);
  const receipt = await withBoundModerationReview(f.ref, f.adapter, ({jpeg, receipt}) => {
    delivered = jpeg;
    assert.deepEqual(jpeg, SYNTHETIC_CANONICAL_JPEG);
    assert.equal(receipt.caseReferenceHmac, f.ref.caseReferenceHmac);
    assert.equal(receipt.jpegSHA256, digest(SYNTHETIC_CANONICAL_JPEG));
    assert.equal(receipt.width, 1); assert.equal(receipt.height, 1);
    assert.ok(receipt.expiresAt <= Date.now() + 60000);
  });
  assert.ok(delivered.every(byte => byte === 0));
  assert.deepEqual(f.key.privateKeyBytes, originalKey, "caller-owned key is not mutated");
  assert.deepEqual(f.events.map(e => e.phase), ["started", "disclosure_ready", "sink_completed"]);
  assert.equal(receipt.sourceSHA256, moderationReviewSourceBinding(f.source, f.ref).sourceSHA256);
  const audit = JSON.stringify(f.events);
  for (const secret of [f.source.objectKey, f.source.metadata.reportId,
    f.source.metadata.reporterParticipantId, f.key.privateKeyBytes.toString("hex"), SYNTHETIC_CANONICAL_JPEG.toString("base64")]) {
    assert.ok(!audit.includes(secret));
  }
});

test("source digest is property-order independent and binds reportId absent from crypto AAD", () => {
  const f = fixture();
  const first = moderationReviewSourceBinding(f.source, f.ref).sourceSHA256;
  const reordered = Object.fromEntries(Object.entries(f.source).reverse());
  reordered.metadata = Object.fromEntries(Object.entries(f.source.metadata).reverse());
  assert.equal(moderationReviewSourceBinding(reordered, f.ref).sourceSHA256, first);
  for (const field of ["reportId", "momentId", "reporterParticipantId"]) {
    const changed = {...f.source, metadata: {...f.source.metadata, [field]: "another_report"}};
    assert.notEqual(moderationReviewSourceBinding(changed, f.ref).sourceSHA256, first);
  }
  assert.notEqual(moderationReviewSourceBinding({...f.source, objectKey: "different/object"}, f.ref).sourceSHA256, first);
});

for (const mutate of [
  s => {s.caseReferenceHmac = "b".repeat(64);},
  s => {s.caseReferenceHmacKeyVersion = 2;},
  s => {s.metadata.reasonCode = "unsupported";},
  s => {s.objectKey = "reports/with space";},
  s => {s.unexpected = true;},
  s => {s.metadata.contentExpiresAt = Math.floor(Date.now()/1000)-1; s.metadata.committedAt = s.metadata.contentExpiresAt-604800;},
]) {
  test(`invalid or expired source releases no ciphertext/key/plaintext (${mutate.toString()})`, async () => {
    const f = fixture(); mutate(f.source);
    f.adapter.readCiphertext = () => assert.fail("object read");
    f.adapter.readReviewedKey = () => assert.fail("key read");
    await rejected(f);
    assert.equal(f.events.length, 0);
  });
}

test("different report with same plaintext identity cannot replace the selected DB source during read", async () => {
  const f = fixture();
  f.adapter.readCiphertext = async () => {
    f.source.metadata.reportId = "other-report-same-moment";
    return f.bundle.envelopeBytes;
  };
  f.adapter.readReviewedKey = () => assert.fail("key read after source mutation");
  await rejected(f);
});

for (const phase of ["ciphertext", "key", "disclosure_ready"]) {
  test(`revocation/source deletion during ${phase} releases zero plaintext`, async () => {
    const f = fixture(); let revoked = false;
    f.adapter.readCurrentSource = async () => revoked ? null : f.source;
    if (phase === "ciphertext") f.adapter.readCiphertext = async () => {revoked = true; return f.bundle.envelopeBytes;};
    if (phase === "key") f.adapter.readReviewedKey = async () => {revoked = true; return f.key;};
    if (phase === "disclosure_ready") f.adapter.audit = async e => {if(e.phase === phase) revoked = true;};
    await rejected(f);
  });
}

for (const phase of ["started", "disclosure_ready"]) {
  test(`failed ${phase} audit prevents disclosure`, async () => {
    const f = fixture();
    f.adapter.audit = async e => {if(e.phase === phase) throw new Error("sensitive adapter exception");};
    await rejected(f);
  });
}

test("wrong reviewed fingerprint rejects even a cryptographically valid private key", async () => {
  const f = fixture(); f.key.expectedPublicKeySHA256 = "0".repeat(64); await rejected(f);
});
test("wrong key identity and altered ciphertext are rejected", async () => {
  const f = fixture(); f.key.reviewedKeyId = "moderation-v2"; await rejected(f);
  const g = fixture(); g.bundle.envelopeBytes[50] ^= 1; await rejected(g);
});
test("wrong size is rejected before key read", async () => {
  const f = fixture(); f.adapter.readCiphertext = async () => new Uint8Array(0);
  f.adapter.readReviewedKey = () => assert.fail("key read"); await rejected(f);
});
test("caller mutation across await cannot switch callback, reference or frozen snapshot", async () => {
  const f = fixture(); let reads = 0;
  f.adapter.readCurrentSource = async ref => {
    assert.equal(ref.caseReferenceHmac, "a".repeat(64));
    reads++;
    f.ref.caseReferenceHmac = "f".repeat(64);
    f.adapter.readCiphertext = () => assert.fail("switched adapter");
    return f.source;
  };
  await withBoundModerationReview(f.ref, f.adapter, ({jpeg}) => assert.deepEqual(jpeg, SYNTHETIC_CANONICAL_JPEG));
  assert.equal(reads, 4);
});
test("sink failure is delivery unknown, never a retry or completed result, and clears bytes", async () => {
  const f = fixture(); let delivered; let calls = 0;
  await rejected(f, ({jpeg}) => {delivered = jpeg; calls++; throw new Error("sink failed");});
  assert.equal(calls, 1); assert.ok(delivered.every(x => x === 0));
  assert.equal(f.events.at(-1).phase, "failed_or_delivery_unknown");
  assert.ok(!f.events.some(e => e.phase === "sink_completed"));
});
test("missing trusted adapters cannot start a review", async () => {
  const f = fixture(); delete f.adapter.audit; await rejected(f);
});
for (const phase of ["source", "ciphertext", "key", "disclosure_ready", "sink", "sink_completed"]) {
  test(`deadline aborts a stalled ${phase}; late completion never starts another disclosure`, async () => {
    const f = fixture(); let release; let delivered; let calls = 0; let receivedSignal;
    const stalled = new Promise(resolve => {release = resolve;});
    const sink = async ({jpeg}, signal) => {delivered = jpeg; calls++; receivedSignal = signal; if(phase === "sink") await stalled;};
    if(phase === "source") f.adapter.readCurrentSource = async (_, signal) => {receivedSignal = signal; return stalled;};
    if(phase === "ciphertext") f.adapter.readCiphertext = async (_, signal) => {receivedSignal = signal; return stalled;};
    if(phase === "key") f.adapter.readReviewedKey = async (_, signal) => {receivedSignal = signal; return stalled;};
    if(["disclosure_ready", "sink_completed"].includes(phase)) f.adapter.audit = async (e, signal) => {
      if(e.phase === phase) {receivedSignal = signal; await stalled;}
    };
    await assert.rejects(withBoundModerationReview(f.ref, f.adapter, sink, {maximumDurationMs: 300}),
      {message: "moderation_review_unavailable"});
    assert.equal(receivedSignal.aborted, true);
    assert.equal(calls, ["sink", "sink_completed"].includes(phase) ? 1 : 0);
    if(delivered) assert.ok(delivered.every(x => x === 0));
    release(phase === "source" ? f.source : phase === "ciphertext" ? f.bundle.envelopeBytes : f.key);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls, ["sink", "sink_completed"].includes(phase) ? 1 : 0);
  });
}
test("an immediate sink result after expiry is delivery unknown even before timers execute", async context => {
  const f = fixture(); let clock = Date.now(); let delivered;
  context.mock.method(Date, "now", () => clock);
  await assert.rejects(withBoundModerationReview(f.ref, f.adapter, ({jpeg}) => {
    delivered = jpeg; clock += 60001;
  }), {message: "moderation_review_unavailable"});
  assert.ok(delivered.every(byte => byte === 0));
  assert.ok(!f.events.some(event => event.phase === "sink_completed"));
});
