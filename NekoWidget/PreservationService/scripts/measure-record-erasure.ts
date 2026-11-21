// Opt-in scale drill. All providers are local and every value is synthetic.
import assert from 'node:assert/strict';
import { setTimeout as wait } from 'node:timers/promises';
import { sha256 } from '../src/contracts';
import { identityIndexKey, indexedOwnerIdentity } from '../src/identity-index';
import { canonicalJSON, ImmutableRecordTree, type TreeRef } from '../src/immutable-record-tree';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerArchiveRecovery } from '../src/owner-archive-recovery';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from '../src/owner-recovery-copy';
import { RecordPhysicalDeletion } from '../src/record-physical-deletion';
import { RecordRecoveryCopy, type StoredRecordImage } from '../src/record-recovery-copy';
import type { RecoveryObject, RecoveryVersion, RecoveryVersionCursor, S3RecoveryCopy } from '../src/s3-recovery-copy';
import { syntheticKeyAuthority } from '../test/key-fixture';

const latency = Number(process.argv[2] ?? '15');
assert(Number.isInteger(latency) && latency >= 0 && latency <= 100);
const ownerId = '00000000-0000-4000-8000-000000000001';
const identitySecret = 'z'.repeat(64);
const makeKey = (folder: string) => `recovery/v1/${ownerId}/${folder}/${crypto.randomUUID()}`;
const makeID = (n: number) => `${(n % 16).toString(16)}0000000-0000-4000-8000-${n.toString(16).padStart(12,'0')}`;
const encoder = new TextEncoder();
const memory = new Map<string, { ref: RecoveryObject; data: Uint8Array }>();
let measuring = false;
const calls: Record<string, number> = {};
async function simulated(op: string) {
  if (!measuring) return;
  calls[op] = (calls[op] ?? 0) + 1;
  if (latency) await wait(latency);
}
const wrapper = (await syntheticKeyAuthority()).make();
const keys = envelopeKeyCustody({ enabled: true, wrapper: { ...wrapper, async unwrap(...args) {
  await simulated('key-unwrap');
  return wrapper.unwrap(...args);
} } });
const s3 = {
  async putVersioned(key: string, data: Uint8Array) {
    const ref = { key, bytes: data.length, sha256: await sha256(data), versionId: 'synthetic-v1' };
    memory.set(key, { ref, data: data.slice() });
    return ref;
  },
  async getVerified(reference: RecoveryObject) {
    await simulated('s3-get');
    const current = memory.get(reference.key);
    assert(current && reference.versionId === current.ref.versionId && reference.bytes === current.data.length);
    assert.equal(await sha256(current.data), reference.sha256);
    return current.data.slice();
  },
  async referenceForListedVersion(item: RecoveryVersion) {
    await simulated('s3-head');
    const found = memory.get(item.key)?.ref;
    assert(found && !item.deleteMarker && found.versionId === item.versionId && found.bytes === item.bytes);
    return found;
  },
  async listOwnerVersionsPage(owner: string, cursor?: RecoveryVersionCursor) {
    await simulated('s3-list'); assert.equal(owner, ownerId);
    const refs = [...memory.values()].map(item => item.ref);
    const offset = cursor ? refs.findIndex(ref => ref.key === cursor.keyMarker && ref.versionId === cursor.versionIdMarker) + 1 : 0;
    assert(!cursor || offset > 0);
    const versions = refs.slice(offset,offset+1000).map(ref => ({ ...ref, deleteMarker: false }));
    const last = versions.at(-1);
    return { versions, nextCursor: last && offset + versions.length < refs.length
      ? { keyMarker: last.key, versionIdMarker: last.versionId } : null };
  },
} as unknown as S3RecoveryCopy;
const records = new RecordRecoveryCopy(keys, s3);
const owners = new OwnerRecoveryCopy(keys, s3, identitySecret);
const r2 = new Map<string, { key: string; size: number; version: string }>();
const heads: OwnerRecoveryImage['records'] = [];
const photo = new Uint8Array(128 * 1024);
const targetId = makeID(1);
const evidenceToKeep = new Set<string>();
const toErase = new Set<string>();
for (let number = 1; number <= 252; number++) {
  const recordId = makeID(number);
  const hasPhoto = number <= 13 || (number >= 199 && number < 241);
  const primaryKey = hasPhoto ? `personal/${ownerId}/${recordId}/${crypto.randomUUID()}` : null;
  if (primaryKey) r2.set(primaryKey, { key: primaryKey, size: photo.length, version: 'synthetic-r2' });
  const metadata = new Uint8Array(1700 + number % 45);
  const baseline: StoredRecordImage = { ownerId, recordId, revision: 1, initialFingerprint: 'f'.repeat(64),
    initialOperation: crypto.randomUUID(), metadata, photoKey: primaryKey, photoBytes: hasPhoto ? photo.length : 0,
    quotaBytes: metadata.length + (hasPhoto ? photo.length : 0), deleted: false, photoCiphertext: hasPhoto ? photo : null };
  const first = await records.copy(baseline);
  let marker = await records.commit(ownerId, recordId, 1, first);
  let revision = 1;
  if (number <= 198) {
    const terminal = await records.copy({ ...baseline, revision: 2, metadata: null, photoKey: null,
      photoBytes: 0, quotaBytes: 0, deleted: true, photoCiphertext: null });
    await records.prepareDelete(ownerId, recordId, 1, terminal);
    marker = await records.commit(ownerId, recordId, 2, terminal);
    revision = 2;
    if (recordId === targetId) {
      toErase.add(first.record.key); toErase.add(first.photo!.key);
      evidenceToKeep.add(terminal.record.key);
    }
  } else if (number < 242) {
    const edit = await records.copy({ ...baseline, revision: 2 }, first.photo ?? undefined);
    marker = await records.commit(ownerId, recordId, 2, edit);
    revision = 2;
  }
  heads.push({ recordId, marker, revision, deleted: number <= 198 });
}
assert.equal(memory.size, 691 + 548);
assert.equal(r2.size, 55);
heads.sort((a,b) => a.recordId.localeCompare(b.recordId));
const tree = new ImmutableRecordTree(ownerId, 'owner-inventory-v1', keys, s3);
const root = await tree.create(heads.map(value => ({ key: value.recordId.replaceAll('-',''), value })));
const node = await tree.readAuthenticatedNode(root);
assert('children' in node && node.children.length === 16);
const seal = (bytes: Uint8Array) => keys.seal(bytes, { ownerId, purpose: 'recovery' });
const principal = { issuer: 'https://appleid.apple.com', subject: 'synthetic-only', refreshToken: 'synthetic-only' };
const credential = await keys.seal(encoder.encode(JSON.stringify(principal)), { ownerId, purpose: 'identity' });
const identityKey = await indexedOwnerIdentity(await identityIndexKey(identitySecret), principal.issuer, principal.subject);
for (let generation = 1; generation <= 356; generation++) {
  let treeRoot: TreeRef = root;
  if (generation > 1) {
    const children = [...node.children];
    for (let offset = 0; offset < (generation <= 29 ? 2 : 1); offset++) {
      const index = (generation + offset) % children.length;
      const child = children[index]!;
      children[index] = { ...child, object: await s3.putVersioned(makeKey('record'), await s3.getVerified(child.object)) };
    }
    const object = await s3.putVersioned(makeKey('record'), await seal(encoder.encode(canonicalJSON({ ...node, children }))));
    treeRoot = { ...root, object };
  }
  const body = { version: 3, ownerId, generation, identityKey, epoch: 0, disabled: false, purgeFenceId: null,
    createdAt: 100, inventoryGeneration: 252, billing: null, contact: null, retention: null, recordsTree: treeRoot,
    credential: { ownerEpoch: 0, sealedCredentialsBase64: Buffer.from(credential).toString('base64'), updatedAt: 100 } };
  await s3.putVersioned(makeKey('owner'), await seal(encoder.encode(JSON.stringify(body))));
}
assert.equal(memory.size, 2350);
let marked = false;
const db = { prepare(sql: string) { return { bind() { return {
  async first() { assert(sql.startsWith('SELECT')); return { generation: 356 }; },
  async run() { assert(sql.startsWith('DELETE FROM pa_record_physical_delete_queue')); marked = true; return { meta: { changes: 1 } }; },
}; } }; } } as unknown as D1Database;
const bucket = { async list() { await simulated('r2-list'); return {
  objects: [...r2.values()].sort((a,b)=>a.key.localeCompare(b.key)), truncated: false, delimitedPrefixes: [],
}; }, async head(key: string) { await simulated('r2-head'); return r2.get(key) ?? null; },
  async delete(key: string) { await simulated('r2-delete'); assert(key.startsWith(`personal/${ownerId}/${targetId}/`)); r2.delete(key); },
} as unknown as R2Bucket;
const executor = new RecordPhysicalDeletion({ db, bucket, records, inventory: s3, now: Date.now,
  archive: new OwnerArchiveRecovery(s3, owners, records),
  eraser: { async requestExactVersionDeletion(owner, version) {
    await simulated('s3-delete'); assert.equal(owner, ownerId); assert(toErase.has(version.key)); assert(memory.delete(version.key));
  } },
});
const job = { owner_id: ownerId, record_id: targetId, tombstone_revision: 2, requested_at: Date.now() };
for (const expected of ['processing','complete']) {
  measuring = true;
  const started = performance.now();
  const actual = await executor.step(job);
  const elapsedMs = Math.round(performance.now()-started);
  assert.equal(actual, expected);
  console.log(JSON.stringify({ simulatedProviderMs: latency, phase: expected, elapsedMs, calls }));
  for (const key of Object.keys(calls)) delete calls[key];
}
assert(marked && [...evidenceToKeep].every(key => memory.has(key)));
assert.equal(Number(memory.size), 2348);
assert.equal(Number(r2.size), 54);
