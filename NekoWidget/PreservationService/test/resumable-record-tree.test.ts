import { expect, it } from 'vitest';
import { canonicalJSON, ImmutableRecordTree, type TreeEntry, type TreeRef } from '../src/immutable-record-tree';
import { ResumableRecordTree, type ResumableTreePlan, type ResumableTreeIO } from '../src/resumable-record-tree';
import { envelopeKeyCustody } from '../src/key-custody';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { syntheticKeyAuthority } from './key-fixture';

const owner = '00000000-0000-4000-8000-000000000001';
const tree = 'owner-inventory-v1';
const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
async function fixture(keyLength: 32 | 64 = 32) {
  const authority = await syntheticKeyAuthority(), wrapper = authority.make();
  let opens = 0, seals = 0, gets = 0, puts = 0, active = 0, peak = 0;
  const keys = envelopeKeyCustody({ enabled: true, wrapper: {
    wrap: (...args) => { seals++; return wrapper.wrap(...args); },
    unwrap: (...args) => { opens++; return wrapper.unwrap(...args); },
  } });
  const objects = new Map<string, { body: Uint8Array; version: string; checksum: string }>();
  // Real signing/checksum/version adapter and AES custody, with only the HTTP
  // transport replaced. No public AWS endpoint is contacted.
  const s3 = new S3RecoveryCopy({ enabled: 'YES', region: 'ap-northeast-1', bucket: 'synthetic-tree',
    expectedAccountId: '123456789012', accessKeyId: 'synthetic', secretAccessKey: 'synthetic' }, async (url, init) => {
    active++; peak = Math.max(peak, active);
    try {
      const address = new URL(String(url)), key = decodeURIComponent(address.pathname.slice(1));
      const headers = new Headers(init?.headers);
      if (address.hostname !== 'synthetic-tree.s3.ap-northeast-1.amazonaws.com'
        || headers.get('x-amz-expected-bucket-owner') !== '123456789012') throw Error('wrong target');
      let stored = objects.get(key);
      if (init?.method === 'PUT') {
        puts++;
        if (headers.get('if-none-match') !== '*') throw Error('missing conditional creation');
        if (stored) return new Response(null, { status: 412 });
        const body = new Uint8Array(await new Response(init.body).arrayBuffer());
        const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', body));
        const checksum = btoa(String.fromCharCode(...digest));
        if (checksum !== headers.get('x-amz-checksum-sha256')) throw Error('bad upload checksum');
        stored = { body, version: crypto.randomUUID(), checksum }; objects.set(key, stored);
      }
      if (!stored || (address.searchParams.has('versionId') && address.searchParams.get('versionId') !== stored.version)) {
        return new Response(null, { status: 404 });
      }
      if (init?.method === 'GET') gets++;
      return new Response(init?.method === 'GET' ? stored.body.slice() : null, { headers: {
        'x-amz-version-id': stored.version, 'x-amz-checksum-sha256': stored.checksum,
        'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(stored.body.length),
      } });
    } finally { active--; }
  });
  const receipts = new Map<string, { node: string; ref: TreeRef }>();
  const writes: string[] = [];
  const io: ResumableTreeIO = { async durablePreparedNode(node, hash, count, id) {
    const text = canonicalJSON(node), prior = receipts.get(id);
    if (prior) { expect(prior.node).toBe(text); return copy(prior.ref); }
    const body = await keys.seal(new TextEncoder().encode(text), { ownerId: owner, purpose: 'recovery' });
    const object = await s3.putVersioned(`recovery/v1/${owner}/record/${crypto.randomUUID()}`, body);
    const ref = { object, prefix: node.prefix, count, hash };
    receipts.set(id, { node: text, ref }); writes.push(node.prefix); return copy(ref);
  } };
  return { authority, keys, s3, objects, io, writes, receipts,
    original: new ImmutableRecordTree(owner, tree, keys, s3, keyLength),
    next: () => new ResumableRecordTree(owner, tree, keys, s3, keyLength),
    counts: () => ({ opens, seals, gets, puts, active, peak }),
    reset: () => { opens = seals = gets = puts = active = peak = 0; } };
}
async function finish(f: Awaited<ReturnType<typeof fixture>>, input: ResumableTreePlan,
  budget: number | { maxReads: number; maxWrites: number } = 1) {
  const limits = typeof budget === 'number' ? { maxReads: budget, maxWrites: budget } : budget;
  let plan = copy(input); const calls: { reads: number; writes: number; authority: number }[] = [];
  for (let step = 0; step < 600; step++) {
    const before = f.counts(), saved = JSON.stringify(plan);
    const result = await f.next().step(plan, limits, f.io);
    expect(JSON.stringify(plan)).toBe(saved);
    const after = f.counts();
    expect(result.reads).toBeLessThanOrEqual(limits.maxReads); expect(result.writes).toBeLessThanOrEqual(limits.maxWrites);
    expect(after.opens - before.opens).toBe(result.reads);
    expect(after.gets - before.gets).toBe(result.reads);
    calls.push({ reads: result.reads, writes: result.writes, authority: after.opens + after.seals - before.opens - before.seals });
    plan = copy(result.plan);
    if (result.root) return { root: result.root, plan, calls };
  }
  throw Error('bounded continuation did not finish');
}
it('direct probe: splits a full leaf across fresh instances with one read/write per step and retains all old versions', async () => {
  const f = await fixture(), entries = Array.from({ length: 64 }, (_, i) => ({ key: 'a' + i.toString(16).padStart(31, '0'), value: i }));
  const root = await f.original.create(entries), old = new Map(f.objects);
  f.reset(); const extra = { key: 'b'.repeat(32), value: 64 };
  const plan = await f.next().begin(root, [extra]); expect(f.counts()).toMatchObject({ gets: 0, puts: 0, opens: 0, seals: 0 });
  const result = await finish(f, plan);
  expect(result.calls.length).toBeGreaterThan(1);
  expect(Math.max(...result.calls.map(call => call.authority))).toBeLessThanOrEqual(2);
  expect(f.writes).toEqual(['a', 'b', '']);
  expect(result.root.hash).toBe(await f.original.logicalHash([...entries, extra]));
  expect(await f.original.entries(result.root)).toEqual([...entries, extra]);
  for (const [key, value] of old) expect(f.objects.get(key)).toBe(value);
  expect(await f.original.entries(root)).toEqual(entries);
  expect(f.authority.rawKeys.every(key => key.every(byte => byte === 0))).toBe(true);
  console.log('RESUMABLE_TREE_DIRECT_PROBE=' + JSON.stringify({ steps: result.calls.length, calls: result.calls, writtenPrefixes: f.writes }));
});

it('updates sixteen records in shared branches once, preserving unchanged references with read3/write2 budgets', async () => {
  const f = await fixture();
  const entries: TreeEntry[] = ['a', 'b', 'c'].flatMap(prefix => Array.from({ length: 40 }, (_, i) => ({
    key: prefix + i.toString(16).padStart(31, '0'), value: i,
  })));
  const root = await f.original.create(entries), oldNode = await f.original.readAuthenticatedNode(root);
  if (!('children' in oldNode)) throw Error('expected branch');
  const changes = [...entries.slice(0, 8), ...entries.slice(40, 48)].map(entry => ({ ...entry, value: 'new' }));
  const observed: string[] = [];
  f.io.validate = (previous, next) => { expect(previous?.key).toBe(next.key); observed.push(next.key); };
  f.reset(); const result = await finish(f, await f.next().begin(root, changes), { maxReads: 3, maxWrites: 2 });
  expect(f.writes).toEqual(['a', 'b', '']);
  expect(observed.sort()).toEqual(changes.map(entry => entry.key).sort());
  const newNode = await f.original.readAuthenticatedNode(result.root);
  if (!('children' in newNode)) throw Error('expected branch');
  expect(newNode.children.find(child => child.prefix === 'c')).toEqual(oldNode.children.find(child => child.prefix === 'c'));
  const merged = entries.map(entry => changes.find(change => change.key === entry.key) ?? entry);
  expect(await f.original.entries(result.root)).toEqual(merged);
  expect(result.root.hash).toBe(await f.original.logicalHash(merged));
  expect(result.calls.every(call => call.authority <= 5)).toBe(true);
  expect(f.counts().active).toBe(0);
});

it('continues a deep split and a later absent branch without caching old decrypted leaves', async () => {
  const f = await fixture(), entries = Array.from({ length: 64 }, (_, i) => ({ key: i.toString(16).padStart(32, '0'), value: i }));
  const root = await f.original.create(entries), extra = { key: (64).toString(16).padStart(32, '0'), value: 64 };
  const result = await finish(f, await f.next().begin(root, [extra]));
  expect(result.calls.length).toBeGreaterThan(32);
  expect(new Set(f.writes).size).toBe(f.writes.length);
  expect(result.root.hash).toBe(await f.original.logicalHash([...entries, extra]));
  const added = { key: 'f'.repeat(32), value: 65 };
  const later = await finish(f, await f.next().begin(result.root, [added]));
  expect(later.root.hash).toBe(await f.original.logicalHash([...entries, extra, added]));
  expect(await f.original.entries(root)).toEqual(entries);
});

it('replays a durable writer receipt after a lost result without duplicating the immutable object', async () => {
  const f = await fixture(), first = { key: 'a'.repeat(32), value: 1 };
  const root = await f.original.create([first]), plan = await f.next().begin(root, [{ ...first, value: 2 }]);
  const original = copy(plan), savedWriter = f.io.durablePreparedNode;
  const lost: ResumableTreeIO = { async durablePreparedNode(...args) {
    await savedWriter(...args); throw Error('response lost after durable write');
  } };
  f.reset();
  await expect(f.next().step(plan, { maxReads: 3, maxWrites: 2 }, lost)).rejects.toThrow('response lost');
  expect(plan).toEqual(original); expect(f.writes).toEqual(['']); expect(f.counts().active).toBe(0);
  const puts = f.counts().puts;
  const result = await finish(f, copy(plan));
  expect(f.counts().puts).toBe(puts); expect(f.writes).toEqual(['']);
  expect(await f.original.entries(result.root)).toEqual([{ ...first, value: 2 }]);
});

it('reopens authority after interruption and on completed checkpoints, rejecting revoked keys', async () => {
  const f = await fixture(), entries = Array.from({ length: 64 }, (_, i) => ({ key: 'a' + i.toString(16).padStart(31, '0'), value: i }));
  const root = await f.original.create(entries), plan = await f.next().begin(root, [{ key: 'b'.repeat(32), value: 1 }]);
  const first = await f.next().step(plan, { maxReads: 1, maxWrites: 1 }, f.io);
  expect(first.root).toBeUndefined(); f.authority.remove('synthetic/v1'); f.reset();
  await expect(f.next().step(copy(first.plan), { maxReads: 3, maxWrites: 2 }, f.io)).rejects.toThrow();
  expect(f.counts()).toMatchObject({ puts: 0, seals: 0, active: 0 });
  const g = await fixture(), gRoot = await g.original.create([{ key: 'a'.repeat(32), value: 1 }]);
  const complete = await finish(g, await g.next().begin(gRoot, [{ key: 'a'.repeat(32), value: 2 }]));
  g.authority.remove('synthetic/v1'); g.reset();
  await expect(g.next().step(copy(complete.plan), { maxReads: 3, maxWrites: 2 }, g.io)).rejects.toThrow();
  expect(g.counts()).toMatchObject({ puts: 0, seals: 0, active: 0 });
});

it('rejects changed closure, foreign or zero-count children, wrong semantic hashes and unverified ciphertext', async () => {
  const f = await fixture(), entries = ['a', 'b'].flatMap(prefix => Array.from({ length: 40 }, (_, i) => ({
    key: prefix + i.toString(16).padStart(31, '0'), value: i,
  })));
  const root = await f.original.create(entries), plan = await f.next().begin(root, [{ ...entries[0]!, value: 999 }]);
  const opened = await f.next().step(plan, { maxReads: 1, maxWrites: 1 }, f.io);
  const cases = [copy(opened.plan), copy(opened.plan), copy(opened.plan)];
  cases[0]!.input.changes[0]!.value = 'tampered';
  cases[1]!.stack[0]!.children![0]!.before!.count = 0;
  cases[2]!.stack[0]!.children![0]!.before!.object.key = cases[2]!.stack[0]!.children![0]!.before!.object.key.replace(owner, '00000000-0000-4000-8000-000000000002');
  for (const damaged of cases) {
    f.reset(); await expect(f.next().step(damaged, { maxReads: 3, maxWrites: 2 }, f.io)).rejects.toThrow();
    expect(f.counts()).toMatchObject({ gets: 0, puts: 0, opens: 0, seals: 0 });
  }
  const wrongHash = copy(root); wrongHash.hash = 'f'.repeat(64);
  const semanticPlan = await f.next().begin(wrongHash, [{ ...entries[0]!, value: 999 }]);
  f.reset(); await expect(f.next().step(semanticPlan, { maxReads: 3, maxWrites: 2 }, f.io)).rejects.toThrow();
  expect(f.counts()).toMatchObject({ puts: 0, seals: 0, active: 0 });
  f.objects.get(root.object.key)!.body[0]! ^= 1;
  f.reset(); await expect(f.next().step(plan, { maxReads: 3, maxWrites: 2 }, f.io)).rejects.toThrow();
  expect(f.counts()).toMatchObject({ puts: 0, opens: 0, seals: 0, active: 0 });
});

it('fails closed on admission limits, invalid budgets, validator rejection and inconsistent writer metadata', async () => {
  const f = await fixture(), entry = { key: 'a'.repeat(32), value: 1 }, root = await f.original.create([entry]);
  for (const changes of [[], [entry, entry], [{ ...entry, value: 'x'.repeat(24 * 1024) }],
    Array.from({ length: 17 }, (_, i) => ({ key: i.toString(16).padStart(32, '0'), value: i }))]) {
    await expect(f.next().begin(root, changes)).rejects.toThrow();
  }
  const plan = await f.next().begin(root, [{ ...entry, value: 2 }]); f.reset();
  const oversized = copy(plan); oversized.input.changes[0]!.value = 'x'.repeat(1024 * 1024);
  await expect(f.next().step(oversized, { maxReads: 3, maxWrites: 2 }, f.io)).rejects.toThrow();
  for (const maxReads of [0, 5, 1.5, NaN]) await expect(f.next().step(plan, { maxReads, maxWrites: 1 }, f.io)).rejects.toThrow();
  expect(f.counts()).toMatchObject({ gets: 0, puts: 0, opens: 0, seals: 0 });
  await expect(f.next().step(plan, { maxReads: 3, maxWrites: 2 }, { ...f.io, validate() { throw Error('owner policy'); } })).rejects.toThrow('owner policy');
  expect(f.counts()).toMatchObject({ puts: 0, seals: 0, active: 0 });
  await expect(f.next().step(plan, { maxReads: 3, maxWrites: 2 }, { async durablePreparedNode() { return copy(root); } })).rejects.toThrow();
  const unchanged = await finish(f, await f.next().begin(root, [entry]));
  expect(unchanged.root).toEqual(root); expect(f.writes).toEqual([]);
});

it('supports 64-character owner keys and refuses root publication after old authority is revoked', async () => {
  const f = await fixture(64), entries = ['a', 'b'].flatMap(prefix => Array.from({ length: 40 }, (_, i) => ({
    key: prefix + i.toString(16).padStart(63, '0'), value: i,
  })));
  const root = await f.original.create(entries), changed = { ...entries[0]!, value: 'updated' };
  const plan = await f.next().begin(root, [changed]);
  const first = await f.next().step(plan, { maxReads: 2, maxWrites: 1 }, f.io);
  expect(first.root).toBeUndefined(); expect(f.writes).toEqual(['a']);
  await f.authority.rotate('synthetic/v2'); f.authority.remove('synthetic/v1'); f.reset();
  await expect(f.next().step(copy(first.plan), { maxReads: 3, maxWrites: 2 }, f.io)).rejects.toThrow();
  expect(f.writes).toEqual(['a']); expect(f.counts()).toMatchObject({ puts: 0, seals: 0, active: 0 });
});
