import { env } from 'cloudflare:workers';
import { applyD1Migrations, reset, type D1Migration } from 'cloudflare:test';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ArchiveStore } from '../src/storage';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { fixture, finish, db } from './tool-metadata-batch-fixture';

const migrations = (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS;
beforeEach(async () => { await reset(); await applyD1Migrations(db, migrations); });
afterEach(() => vi.restoreAllMocks());
type Fixture = Awaited<ReturnType<typeof fixture>>;
const s3For = (f: Fixture) => (f.ownerCopy() as unknown as { s3: S3RecoveryCopy }).s3;
const privateCopy = (f: Fixture) => f.ownerCopy() as unknown as {
  keys: Fixture['options']['keys']; s3: S3RecoveryCopy; identityIndexSecret: string;
};
function latch() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}
async function staged() {
  const f = await fixture(); await f.archive().beginMetadataBatch(f.session.token, f.manifest);
  for (const part of f.parts) await f.archive().stageMetadataBatch(f.session.token, f.batchId, part.id, part.body);
  return f;
}
async function atNode() {
  const f = await staged();
  expect((await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).status).toBe('pending');
  expect((await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).status).toBe('pending');
  return f;
}
const nodes = (owner: string) => db.prepare('SELECT * FROM pa_owner_delta_nodes WHERE owner_id=? ORDER BY step_id')
  .bind(owner).all<{ work_id: string; step_id: string; object_key: string; ciphertext: ArrayBuffer; confirmed: number }>();
async function syntheticUnknown(owner: string, count: number) {
  for (let i = 0; i < count; i++) await db.prepare(`INSERT INTO pa_owner_delta_nodes
    (owner_id,work_id,step_id,object_key,ciphertext) VALUES(?,?,?,?,?)`)
    .bind(owner, crypto.randomUUID(), `unknown-${i}`, `recovery/v1/${owner}/record/${crypto.randomUUID()}`,
      new Uint8Array([1]).buffer).run();
}

it('refuses an old stage after A to B to A nonce replacement while record encryption waits', async () => {
  const f = await fixture(); await f.archive().beginMetadataBatch(f.session.token, f.manifest);
  const before = await db.prepare('SELECT batch_nonce FROM pa_tool_metadata_batches WHERE owner_id=?').bind(f.session.ownerId).first();
  const entered = latch(), held = latch(), seal = f.options.keys.seal.bind(f.options.keys);
  let blocked = false;
  vi.spyOn(f.options.keys, 'seal').mockImplementation(async (bytes, context) => {
    if (!blocked && context.purpose === 'record') { blocked = true; entered.release(); await held.promise; }
    return seal(bytes, context);
  });
  const part = f.parts[0]!;
  const pending = f.archive().stageMetadataBatch(f.session.token, f.batchId, part.id, part.body);
  const denied = expect(pending).rejects.toThrow();
  try {
    await entered.promise;
    await f.archive().beginMetadataBatch(f.session.token, { ...f.manifest, batchId: crypto.randomUUID() });
    await f.archive().beginMetadataBatch(f.session.token, { batchId: f.batchId, items: [f.parts[1]!.descriptor] });
    expect(await db.prepare('SELECT batch_nonce FROM pa_tool_metadata_batches WHERE owner_id=?').bind(f.session.ownerId).first()).not.toEqual(before);
  } finally { held.release(); }
  await denied;
  expect(await db.prepare('SELECT record_id FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, part.id).first()).toBeNull();
  await f.auth.requireSession(f.session.token);
}, 60_000);

it('seeds a missing derived cursor before accepting any part and finishes the resulting batch', async () => {
  const f = await fixture();
  await db.prepare('DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.session.ownerId).run();
  await f.auth.requireSession(f.session.token);
  await f.archive().beginMetadataBatch(f.session.token, f.manifest);
  expect(await db.prepare('SELECT owner_id FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.session.ownerId).first()).not.toBeNull();
  for (const part of f.parts) await f.archive().stageMetadataBatch(f.session.token, f.batchId, part.id, part.body);
  await finish(f); await f.auth.requireSession(f.session.token);
}, 60_000);

it('does not advertise or write any batch in non-paged configuration', async () => {
  const f = await fixture(), p = privateCopy(f);
  const legacy = new OwnerRecoveryCopy(p.keys, p.s3, p.identityIndexSecret, { pagedWrites: false, compressWrites: true });
  const store = new ArchiveStore({ ...f.options, ownerRecovery: legacy });
  expect((await store.usage(f.session.token)).toolSnapshots.metadataBatchVersion).toBe(0);
  const puts = f.count.PUT;
  await expect(store.beginMetadataBatch(f.session.token, f.manifest)).rejects.toMatchObject({ code: 'PRESERVATION_NOT_CONFIGURED' });
  expect(f.count.PUT).toBe(puts);
  expect(await db.prepare('SELECT owner_id FROM pa_tool_metadata_batches WHERE owner_id=?').bind(f.session.ownerId).first()).toBeNull();
});

it('fences a generation race on the already-covered fast path without entering a full copy', async () => {
  const f = await fixture(), copy = f.ownerCopy(), s3 = s3For(f);
  const original = s3.getVerified.bind(s3); let changed = false;
  vi.spyOn(copy, 'copyCurrent').mockImplementation(async () => { throw Error('unbounded fallback called'); });
  vi.spyOn(s3, 'getVerified').mockImplementation(async ref => {
    const result = await original(ref);
    if (!changed) { changed = true; await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?').bind(f.session.ownerId).run(); }
    return result;
  });
  const before = { ...f.count };
  await expect(copy.copyCurrentStep(db, f.session.ownerId, f.now())).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  expect(copy.copyCurrent).not.toHaveBeenCalled();
  expect(f.count.PUT).toBe(before.PUT); expect(f.count.GET - before.GET).toBeLessThanOrEqual(2);
});

it('refuses a legacy owner ACK at publication without full-copy fallback', async () => {
  const f = await atNode();
  await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now());
  const p = privateCopy(f);
  await new OwnerRecoveryCopy(p.keys, p.s3, p.identityIndexSecret, { pagedWrites: false }).copyCurrent(db, f.session.ownerId, f.now());
  const before = { ...f.count };
  await expect(f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  expect(f.count.PUT).toBe(before.PUT); expect(f.count.GET - before.GET).toBeLessThanOrEqual(1);
}, 60_000);

it('retries a committed PUT with a lost response using exact key/ciphertext even at the unknown-row cap', async () => {
  const f = await atNode(), io = s3For(f) as unknown as { fetcher: typeof fetch }, send = io.fetcher;
  let lost = false; const attempts: { key: string; body: Uint8Array }[] = [];
  io.fetcher = async (url, init) => {
    if (init?.method === 'PUT') {
      attempts.push({ key: new URL(String(url)).pathname, body: new Uint8Array(init.body as ArrayBuffer).slice() });
      const result = await send(url, init);
      if (!lost) { lost = true; throw Error('synthetic response lost after committed PUT'); }
      return result;
    }
    return send(url, init);
  };
  try {
    await expect(f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).rejects.toThrow();
    const retained = (await nodes(f.session.ownerId)).results;
    expect(retained).toHaveLength(1); expect(retained[0]!.confirmed).toBe(0);
    const leases = await db.prepare('SELECT write_id FROM pa_recovery_write_leases WHERE owner_id=?').bind(f.session.ownerId).all();
    expect(leases.results).toHaveLength(1);
    await syntheticUnknown(f.session.ownerId, 31);
    expect((await nodes(f.session.ownerId)).results).toHaveLength(32);
    expect((await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).status).toBe('pending');
    expect(attempts).toHaveLength(2); expect(attempts[1]).toEqual(attempts[0]);
    expect((await nodes(f.session.ownerId)).results).toHaveLength(31);
    expect((await db.prepare('SELECT write_id FROM pa_recovery_write_leases WHERE owner_id=?').bind(f.session.ownerId).all()).results).toEqual(leases.results);
  } finally { io.fetcher = send; }
}, 60_000);

it('refuses a 33rd unknown node atomically without PUT and keeps another owner untouched', async () => {
  const other = await fixture(), f = await atNode();
  await syntheticUnknown(f.session.ownerId, 32); await syntheticUnknown(other.session.ownerId, 1);
  const otherBefore = (await nodes(other.session.ownerId)).results, puts = f.count.PUT;
  const results = await Promise.allSettled([f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now()),
    f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())]);
  expect(results.every(result => result.status === 'rejected')).toBe(true);
  expect(f.count.PUT).toBe(puts); expect((await nodes(f.session.ownerId)).results).toHaveLength(32);
  expect((await nodes(other.session.ownerId)).results).toEqual(otherBefore);
}, 60_000);

it('cleans only confirmed old-work rows after generation changes and retains unknown mappings', async () => {
  const f = await atNode();
  // Stop after real PUT/HEAD confirmation, before the checkpoint CAS is issued.
  const interrupted = new Proxy(db, { get(target, property) {
    if (property !== 'prepare') return Reflect.get(target, property, target);
    return (sql: string) => {
      const statement = target.prepare(sql);
      if (!sql.includes('UPDATE pa_owner_delta_work SET plan_json=')) return statement;
      return { bind: (...values: unknown[]) => { statement.bind(...values); return { all: async () => { throw Error('synthetic checkpoint interruption'); } }; } };
    };
  } });
  await expect(f.ownerCopy().copyCurrentStep(interrupted, f.session.ownerId, f.now())).rejects.toThrow();
  expect((await nodes(f.session.ownerId)).results).toHaveLength(1);
  expect((await nodes(f.session.ownerId)).results[0]!.confirmed).toBe(1);
  await syntheticUnknown(f.session.ownerId, 1);
  const unknown = (await nodes(f.session.ownerId)).results.find(row => row.confirmed === 0)!;
  await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?').bind(f.session.ownerId).run();
  expect((await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).status).toBe('pending');
  expect((await nodes(f.session.ownerId)).results).toEqual([unknown]);
}, 60_000);

it('rejects a stale step after another step checkpoints while its encryption is pending', async () => {
  const f = await atNode(), entered = latch(), held = latch(), seal = f.options.keys.seal.bind(f.options.keys);
  let stopped = false;
  vi.spyOn(f.options.keys, 'seal').mockImplementation(async (bytes, context) => {
    if (!stopped && context.purpose === 'recovery') { stopped = true; entered.release(); await held.promise; }
    return seal(bytes, context);
  });
  const before = f.count.PUT;
  const stale = f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now());
  const denied = expect(stale).rejects.toThrow();
  try {
    await entered.promise;
    expect((await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).status).toBe('pending');
  } finally { held.release(); }
  await denied;
  expect(f.count.PUT - before).toBe(1);
  expect((await nodes(f.session.ownerId)).results).toHaveLength(0);
}, 60_000);

it('does not erase a newer work prepared row after an older current-ACK fence succeeds', async () => {
  const f = await fixture(); await f.archive().beginMetadataBatch(f.session.token, f.manifest);
  const stopCheckpoint = new Proxy(db, { get(target, property) {
    if (property !== 'prepare') return Reflect.get(target, property, target);
    return (sql: string) => {
      const statement = target.prepare(sql);
      if (!sql.includes('UPDATE pa_owner_delta_work SET plan_json=')) return statement;
      return { bind: (...values: unknown[]) => { statement.bind(...values); return { all: async () => { throw Error('new checkpoint not yet committed'); } }; } };
    };
  } });
  let expected: Awaited<ReturnType<typeof nodes>>['results'] = [];
  const race = new Proxy(db, { get(target, property) {
    if (property !== 'prepare') return Reflect.get(target, property, target);
    return (sql: string) => {
      const statement = target.prepare(sql);
      if (!sql.includes('INSERT INTO pa_owner_recovery_tree_cursors')) return statement;
      return { bind: (...values: unknown[]) => {
        const bound = statement.bind(...values);
        return { run: async () => {
          const result = await bound.run();
          for (const part of f.parts) await f.archive().stageMetadataBatch(f.session.token, f.batchId, part.id, part.body);
          await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now());
          await f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now());
          await expect(f.ownerCopy().copyCurrentStep(stopCheckpoint, f.session.ownerId, f.now())).rejects.toThrow();
          expected = (await nodes(f.session.ownerId)).results;
          expect(expected).toHaveLength(1); expect(expected[0]!.confirmed).toBe(1);
          return result;
        } };
      } };
    };
  } });
  expect((await f.ownerCopy().copyCurrentStep(race, f.session.ownerId, f.now())).status).toBe('complete');
  expect((await nodes(f.session.ownerId)).results).toEqual(expected);
}, 60_000);

it.each(['checkpoint MAC', 'wrapping key'] as const)('rejects changed %s on resume before any new PUT', async kind => {
  const f = await atNode(), before = f.count.PUT;
  if (kind === 'checkpoint MAC') await db.prepare("UPDATE pa_owner_delta_work SET plan_json=json_set(plan_json,'$.after',999999) WHERE owner_id=?")
    .bind(f.session.ownerId).run();
  else f.authority.remove('synthetic/v1');
  await expect(f.ownerCopy().copyCurrentStep(db, f.session.ownerId, f.now())).rejects.toThrow();
  expect(f.count.PUT).toBe(before);
}, 60_000);
