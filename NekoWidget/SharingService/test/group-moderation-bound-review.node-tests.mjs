import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createGroupModerationFixture, syntheticID, SYNTHETIC_CANONICAL_JPEG} from './fixtures/group-moderation.mjs';
import {groupModerationReviewSourceBinding, withBoundGroupModerationReview} from '../scripts/group-moderation-bound-review-lib.mjs';
import {createLocalGroupOwnerReviewHost, createGroupOwnerR2Transport} from '../scripts/group-moderation-r2-transport.mjs';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function fixture() {
  const f = createGroupModerationFixture(); f.events = []; f.sourcesRead = 0;
  f.adapters = {
    async readCurrentSource() {f.sourcesRead++; return f.source;},
    async readCiphertext(source) {assert.equal(source.objectKey, f.source.objectKey); return f.envelopeBytes;},
    async readReviewedKey(id) {assert.equal(id, 'moderation-v2'); return f.reviewed;},
    async audit(event) {f.events.push(event);},
  };
  return f;
}
const reject = (f, options = {}, sink = () => assert.fail('plaintext escaped')) =>
  assert.rejects(withBoundGroupModerationReview(f.ref, f.adapters, sink, options), {message: 'group_moderation_review_unavailable'});

test('exact v3 source, ordered audit and receipt; owned JPEG wiped, borrowed key untouched', async () => {
  const f = fixture(), key = Buffer.from(f.privateKeyBytes), envelope = Buffer.from(f.envelopeBytes); let delivered;
  const receipt = await withBoundGroupModerationReview(f.ref, f.adapters, ({jpeg, receipt}) => {
    delivered = jpeg;
    assert.deepEqual(jpeg, SYNTHETIC_CANONICAL_JPEG);
    assert.equal(receipt.schema, 'jp.nekowidget.group-moderation-local-review.v1');
    assert.equal(receipt.sourceSHA256, groupModerationReviewSourceBinding(f.source, f.ref).sourceSHA256);
    assert.equal(receipt.jpegSHA256, sha(SYNTHETIC_CANONICAL_JPEG));
    assert.equal(receipt.width, 1); assert.equal(receipt.height, 1);
    assert.deepEqual(f.events.map(e => e.phase), ['started', 'disclosure_ready']);
  });
  assert.equal(f.sourcesRead, 5);
  assert.deepEqual(f.events.map(e => e.phase), ['started', 'disclosure_ready', 'sink_completed']);
  assert.ok(delivered.every(b => b === 0)); assert.deepEqual(f.privateKeyBytes, key); assert.deepEqual(f.envelopeBytes, envelope);
  assert.ok(receipt.expiresAt <= Date.now() + 60000);
  const audit = JSON.stringify(f.events);
  for (const secret of [f.source.objectKey, ...['reportId', 'windowId', 'momentId', 'reporterParticipantId'].map(n => f.metadata[n]),
    f.privateKeyBytes.toString('hex'), SYNTHETIC_CANONICAL_JPEG.toString('base64')]) assert.ok(!audit.includes(secret));
});
test('source binding is ordered, immutable and includes window, report and full object identity', () => {
  const f = fixture(), initial = groupModerationReviewSourceBinding(f.source, f.ref);
  const reordered = Object.fromEntries(Object.entries(f.source).reverse());
  reordered.metadata = Object.fromEntries(Object.entries(f.metadata).reverse());
  assert.equal(groupModerationReviewSourceBinding(reordered, f.ref).sourceSHA256, initial.sourceSHA256);
  assert.ok(Object.isFrozen(initial.source)); assert.ok(Object.isFrozen(initial.source.metadata));
  const changed = structuredClone(f.source); changed.metadata.windowId = syntheticID(8);
  assert.notEqual(groupModerationReviewSourceBinding(changed, f.ref).sourceSHA256, initial.sourceSHA256);
  changed.metadata.reportId = syntheticID(9); changed.objectKey = `groups/reports/v3/${changed.metadata.reportId}/${'A'.repeat(32)}`;
  assert.notEqual(groupModerationReviewSourceBinding(changed, f.ref).sourceSHA256, initial.sourceSHA256);
});
for (const [name, mutate] of [
  ['v2 source', s => {s.schema = 'jp.nekowidget.moderation-review-source.v1';}],
  ['ordinary media key', s => {s.objectKey = 'groups/photos/v3/' + s.metadata.reportId;}],
  ['another report prefix', s => {s.objectKey = `groups/reports/v3/${syntheticID(9)}/${'A'.repeat(32)}`;}],
  ['object suffix traversal', s => {s.objectKey += '/../other';}],
  ['case mismatch', s => {s.caseReferenceHmac = 'b'.repeat(64);}],
  ['reference version mismatch', s => {s.caseReferenceHmacKeyVersion = 2;}],
  ['extra metadata', s => {s.metadata.groupKey = 'forbidden';}],
  ['expired source', s => {s.metadata.committedAt = 1; s.metadata.contentExpiresAt = 604801;}],
]) {
  test(`invalid ${name} prevents ciphertext and key access`, async () => {
    const f = fixture(); mutate(f.source);
    f.adapters.readCiphertext = () => assert.fail('object read'); f.adapters.readReviewedKey = () => assert.fail('key read');
    await reject(f); assert.equal(f.events.length, 0);
  });
}
for (const phase of ['ciphertext', 'key', 'disclosure_ready']) {
  test(`source replacement or revocation during ${phase} discloses nothing`, async () => {
    const f = fixture(); let revoked = false;
    f.adapters.readCurrentSource = async () => revoked ? null : f.source;
    if (phase === 'ciphertext') f.adapters.readCiphertext = async () => {revoked = true; return f.envelopeBytes;};
    if (phase === 'key') f.adapters.readReviewedKey = async () => {revoked = true; return f.reviewed;};
    if (phase === 'disclosure_ready') f.adapters.audit = async event => {if (event.phase === phase) revoked = true;};
    await reject(f);
  });
}
test('same-hash object substitution and ciphertext mismatch are rejected', async () => {
  const f = fixture(); f.adapters.readCiphertext = async () => {
    f.source.objectKey = `groups/reports/v3/${f.metadata.reportId}/${'Z'.repeat(32)}`; return f.envelopeBytes;
  }; await reject(f);
  const changed = fixture(); changed.envelopeBytes[90] ^= 1; await reject(changed);
  const short = fixture(); short.adapters.readCiphertext = async () => new Uint8Array(0);
  short.adapters.readReviewedKey = () => assert.fail('key read'); await reject(short);
});
for (const phase of ['started', 'disclosure_ready']) {
  test(`failed durable ${phase} audit blocks disclosure`, async () => {
    const f = fixture(); f.adapters.audit = async event => {if (event.phase === phase) throw Error('private synthetic error');};
    await reject(f);
  });
}
test('reviewed key identity, companion and fingerprint are each required', async () => {
  for (const change of [k => {k.reviewedKeyId = 'moderation-v1';}, k => {k.expectedPublicKeySHA256 = '0'.repeat(64);},
    k => {k.companionPublicKeyBytes = Buffer.alloc(43, 65);}]) {
    const f = fixture(); change(f.reviewed); await reject(f);
  }
});
test('parent abort before or during I/O cannot disclose or wait for the late adapter', async () => {
  const f = fixture(), parent = new AbortController(); parent.abort();
  f.adapters.readCurrentSource = () => assert.fail('cancelled source read'); await reject(f, {signal: parent.signal});
  const late = fixture(), controller = new AbortController(); let release, adapterSignal;
  late.adapters.readCiphertext = async (_, signal) => {
    adapterSignal = signal; controller.abort(); return new Promise(resolve => {release = resolve;});
  };
  await reject(late, {signal: controller.signal}); assert.equal(adapterSignal.aborted, true);
  release(late.envelopeBytes); await new Promise(setImmediate);
  assert.ok(!late.events.some(e => e.phase === 'disclosure_ready'));
});
for (const phase of ['source', 'ciphertext', 'key', 'disclosure_ready', 'sink', 'sink_completed']) {
  test(`bounded ${phase} wait cancels and late completion never starts another disclosure`, async () => {
    const f = fixture(); let release, delivered, calls = 0, adapterSignal;
    const paused = new Promise(resolve => {release = resolve;});
    const pause = signal => {adapterSignal = signal; return paused;};
    if (phase === 'source') f.adapters.readCurrentSource = async (_, signal) => pause(signal);
    if (phase === 'ciphertext') f.adapters.readCiphertext = async (_, signal) => pause(signal);
    if (phase === 'key') f.adapters.readReviewedKey = async (_, signal) => pause(signal);
    if (['disclosure_ready', 'sink_completed'].includes(phase)) f.adapters.audit = async (e, s) => {if (e.phase === phase) await pause(s);};
    const sink = async ({jpeg}, signal) => {delivered = jpeg; calls++; if (phase === 'sink') await pause(signal);};
    await reject(f, {maximumDurationMs: 150}, sink);
    assert.equal(adapterSignal.aborted, true); assert.equal(calls, ['sink', 'sink_completed'].includes(phase) ? 1 : 0);
    if (delivered) assert.ok(delivered.every(b => b === 0));
    release(phase === 'source' ? f.source : phase === 'ciphertext' ? f.envelopeBytes : f.reviewed);
    await new Promise(setImmediate); assert.equal(calls, ['sink', 'sink_completed'].includes(phase) ? 1 : 0);
  });
}
test('expiry at disclosure audit prevents release even without a timer turn', async context => {
  const f = fixture(); let clock = Date.now(); context.mock.method(Date, 'now', () => clock);
  f.adapters.audit = async e => {if (e.phase === 'disclosure_ready') clock = f.metadata.contentExpiresAt * 1000;};
  await reject(f);
});
test('sink failure is recorded as delivery unknown and clears its borrowed JPEG', async () => {
  const f = fixture(); let delivered;
  await reject(f, {}, ({jpeg}) => {delivered = jpeg; throw Error('synthetic sink failure');});
  assert.ok(delivered.every(b => b === 0)); assert.equal(f.events.at(-1).phase, 'failed_or_delivery_unknown');
  assert.ok(!f.events.some(e => e.phase === 'sink_completed'));
});
test('callback/reference mutation across await cannot replace the trusted reader', async () => {
  const f = fixture(); f.adapters.readCurrentSource = async ref => {
    assert.equal(ref.caseReferenceHmac, 'a'.repeat(64)); f.ref.caseReferenceHmac = 'b'.repeat(64);
    f.adapters.readCiphertext = () => assert.fail('switched callback'); return f.source;
  };
  await withBoundGroupModerationReview(f.ref, f.adapters, ({jpeg}) => assert.deepEqual(jpeg, SYNTHETIC_CANONICAL_JPEG));
});

function hostInput(f, signal = new AbortController().signal) {
  return {source: f.source, sourceSHA256: groupModerationReviewSourceBinding(f.source, f.ref).sourceSHA256,
    signal, readCurrentSource: f.adapters.readCurrentSource, audit: async phase => {f.events.push(phase);}};
}
test('v3 host returns an owned copy after both durable audit phases without issuing a receipt', async () => {
  const f = fixture(), review = createLocalGroupOwnerReviewHost(f.adapters);
  const output = await review(hostInput(f));
  assert.deepEqual(Buffer.from(output), SYNTHETIC_CANONICAL_JPEG);
  assert.deepEqual(f.events, ['started', 'disclosure_ready']);
  output.fill(0); assert.ok(f.envelopeBytes.some(b => b !== 0));
});
test('v3 host refuses a mismatched server source digest before object access', async () => {
  const f = fixture(); f.adapters.readCiphertext = () => assert.fail('object read');
  await assert.rejects(createLocalGroupOwnerReviewHost(f.adapters)({...hostInput(f), sourceSHA256: 'b'.repeat(64)}),
    {message: 'group_moderation_review_unavailable'});
  assert.deepEqual(f.events, []);
});
test('v3 host source revocation during key access prevents an owned output copy', async () => {
  const f = fixture(); let revoked = false;
  f.adapters.readCurrentSource = async () => revoked ? null : f.source;
  f.adapters.readReviewedKey = async () => {revoked = true; return f.reviewed;};
  await assert.rejects(createLocalGroupOwnerReviewHost(f.adapters)(hostInput(f)), {message: 'group_moderation_review_unavailable'});
  assert.deepEqual(f.events, ['started']);
});
test('v3 host cancelled before invocation makes no object request', async () => {
  const f = fixture(), controller = new AbortController(); controller.abort();
  f.adapters.readCiphertext = () => assert.fail('object read');
  await assert.rejects(createLocalGroupOwnerReviewHost(f.adapters)(hostInput(f, controller.signal)),
    {message: 'group_moderation_review_unavailable'});
});
test('v3 R2 bridge reuses the common transport and cancellation stops before any key read', async () => {
  const f = fixture(), controller = new AbortController(); let objectReads = 0, scopeChecks = 0, cancelled = false;
  const review = createGroupOwnerR2Transport({
    bucket: {async get(key) {
      objectReads++; assert.equal(key, f.source.objectKey); controller.abort();
      return {size: f.envelopeBytes.length, body: new ReadableStream({cancel() {cancelled = true;}})};
    }},
    keyDirectory: process.cwd(), publicKeySHA256: f.reviewed.expectedPublicKeySHA256,
    pipeName: 'unused-synthetic-pipe', brokerRecordFile: 'unused-synthetic-file',
    async assertScope() {scopeChecks++;},
  });
  await assert.rejects(review(hostInput(f, controller.signal)), {message: 'owner_review_unavailable'});
  await new Promise(setImmediate);
  assert.equal(objectReads, 1); assert.equal(scopeChecks, 1); assert.equal(cancelled, true);
});
