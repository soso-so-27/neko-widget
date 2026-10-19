import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { RecoveryWriteLease } from '../src/recovery-write-lease';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { DurableAuth } from '../src/auth';
import { randomToken } from '../src/contracts';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { syntheticKeyAuthority } from './key-fixture';

const db = (env as unknown as { DB: D1Database }).DB;
const config = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE',
  secretAccessKey: 'synthetic-secret-never-for-real-aws' };
const bytes = new Uint8Array([1, 2, 3]);
const checksum = async () => btoa(String.fromCharCode(...new Uint8Array(
  await crypto.subtle.digest('SHA-256', bytes as BufferSource))));

it('holds a D1 lease across S3 PUT and HEAD so fencing cannot overtake a write', async () => {
  const ownerId = crypto.randomUUID();
  const fenceId = crypto.randomUUID();
  const key = `recovery/v1/${ownerId}/record/${crypto.randomUUID()}`;
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(ownerId, crypto.randomUUID()).run();
  let entered: (() => void) | undefined;
  const enteredPut = new Promise<void>(resolve => { entered = resolve; });
  let release: (() => void) | undefined;
  const allowPut = new Promise<void>(resolve => { release = resolve; });
  let requests = 0;
  const copy = new S3RecoveryCopy(config, async (_input, init) => {
    requests++;
    if (init?.method === 'PUT') {
      entered!();
      await allowPut;
      return new Response(null, { status: 200, headers: {
        'x-amz-checksum-sha256': await checksum(), 'x-amz-version-id': 'v1' } });
    }
    return new Response(null, { status: 200, headers: {
      'x-amz-checksum-sha256': await checksum(),
      'x-amz-checksum-type': 'FULL_OBJECT',
      'content-length': String(bytes.length), 'x-amz-version-id': 'v1' } });
  }, new RecoveryWriteLease(db, () => 1_800_000_000_000));
  const writing = copy.putVersioned(key, bytes);
  await enteredPut;
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases
    WHERE owner_id=?`).bind(ownerId).first()).toMatchObject({ n: 1 });
  await expect(db.prepare(`UPDATE pa_owners SET disabled=1,epoch=epoch+1,
    purge_fence_id=? WHERE owner_id=?`).bind(fenceId, ownerId).run()).rejects.toThrow();
  release!();
  await expect(writing).resolves.toMatchObject({ key, versionId: 'v1' });
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases
    WHERE owner_id=?`).bind(ownerId).first()).toMatchObject({ n: 0 });
  await db.prepare(`UPDATE pa_owners SET disabled=1,epoch=epoch+1,
    purge_fence_id=? WHERE owner_id=?`).bind(fenceId, ownerId).run();
  await expect(copy.putVersioned(`recovery/v1/${ownerId}/record/${crypto.randomUUID()}`, bytes))
    .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  expect(requests).toBe(2);
});

it('keeps the lease after an uncertain action failure and blocks fencing', async () => {
  const ownerId = crypto.randomUUID();
  const fenceId = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(ownerId, crypto.randomUUID()).run();
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000);
  await expect(lease.withOwnerWrite(ownerId, async () => { throw Error('S3 down'); }))
    .rejects.toThrow('S3 down');
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases
    WHERE owner_id=?`).bind(ownerId).first()).toMatchObject({ n: 1 });
  await expect(db.prepare(`UPDATE pa_owners SET disabled=1,epoch=epoch+1,
    purge_fence_id=? WHERE owner_id=?`).bind(fenceId, ownerId).run()).rejects.toThrow();
});

it('preserves even an undefined rejection while retaining the lease', async () => {
  const ownerId = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(ownerId, crypto.randomUUID()).run();
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000);
  await expect(lease.withOwnerWrite(ownerId, async () => { throw undefined; }))
    .rejects.toBeUndefined();
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases
    WHERE owner_id=?`).bind(ownerId).first()).toMatchObject({ n: 1 });
});

it('retains the fence against a late S3 commit after the PUT response is lost', async () => {
  const ownerId = crypto.randomUUID();
  const fenceId = crypto.randomUUID();
  const key = `recovery/v1/${ownerId}/record/${crypto.randomUUID()}`;
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(ownerId, crypto.randomUUID()).run();
  let finishCommit: (() => void) | undefined;
  let committed = false;
  let simulatedRemoteWrite: Promise<void> | undefined;
  const copy = new S3RecoveryCopy(config, async (_input, init) => {
    if (init?.method === 'PUT') {
      simulatedRemoteWrite = new Promise<void>(resolve => {
        finishCommit = () => { committed = true; resolve(); };
      });
      throw new Error('PUT response lost');
    }
    throw new Error('unexpected request');
  }, new RecoveryWriteLease(db, () => 1_800_000_000_000));
  await expect(copy.putVersioned(key, bytes)).rejects
    .toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  const tryFence = () => db.prepare(`UPDATE pa_owners SET disabled=1,epoch=epoch+1,
    purge_fence_id=? WHERE owner_id=?`).bind(fenceId, ownerId).run();
  await expect(tryFence()).rejects.toThrow();
  finishCommit!(); // The remote write may finish after the caller saw an error.
  await simulatedRemoteWrite;
  expect(committed).toBe(true);
  await expect(tryFence()).rejects.toThrow();
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases
    WHERE owner_id=?`).bind(ownerId).first()).toMatchObject({ n: 1 });
});

async function groupFixture() {
  const owner = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(owner, crypto.randomUUID()).run();
  const count = async () => (await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases
    WHERE owner_id=?`).bind(owner).first<{ n: number }>())!.n;
  const fence = () => db.prepare(`UPDATE pa_owners SET disabled=1,epoch=epoch+1,
    purge_fence_id=? WHERE owner_id=?`).bind(crypto.randomUUID(), owner).run();
  return { owner, count, fence };
}

it('shares one durable fence across real sequential and concurrent S3 PUT/HEAD pairs', async () => {
  const f = await groupFixture();
  const ids = new Set<string>();
  let requests = 0, deletionChecks = 0;
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000,
    { async assertNotRequested(owner) { expect(owner).toBe(f.owner); deletionChecks++; } });
  const copy = new S3RecoveryCopy(config, async (_input, init) => {
    requests++;
    const row = await db.prepare(`SELECT write_id FROM pa_recovery_write_leases WHERE owner_id=?`)
      .bind(f.owner).first<{ write_id: string }>();
    expect(await f.count()).toBe(1); ids.add(row!.write_id);
    await expect(f.fence()).rejects.toThrow();
    return new Response(null, { status: 200, headers: {
      'x-amz-checksum-sha256': await checksum(), 'x-amz-version-id': 'v1',
      ...(init?.method === 'HEAD' ? { 'x-amz-checksum-type': 'FULL_OBJECT',
        'content-length': String(bytes.length) } : {}),
    } });
  }, lease);
  await copy.withOwnerWriteGroup(f.owner, async scoped => {
    await scoped.putVersioned(`recovery/v1/${f.owner}/record/${crypto.randomUUID()}`, bytes);
    await Promise.all(Array.from({ length: 3 }, () => scoped.putVersioned(
      `recovery/v1/${f.owner}/owner/${crypto.randomUUID()}`, bytes)));
  });
  expect(requests).toBe(8); expect(ids.size).toBe(1);
  expect(deletionChecks).toBe(5); // acquire + each individual PUT
  expect(await f.count()).toBe(0); await f.fence();
});

it('rechecks a new deletion request before each write without stranding a confirmed group', async () => {
  const f = await groupFixture();
  let denied = false, writes = 0;
  const refusal = new Error('deletion requested');
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000,
    { async assertNotRequested() { if (denied) throw refusal; } });
  await expect(lease.withOwnerWriteGroup(f.owner, async scoped => {
    await scoped.withOwnerWrite(f.owner, async () => { writes++; });
    denied = true;
    // Swallowing a failed member cannot turn the group into success.
    await scoped.withOwnerWrite(f.owner, async () => { writes++; }).catch(() => {});
  })).rejects.toBe(refusal);
  expect(writes).toBe(1); expect(await f.count()).toBe(0); await f.fence();
});

it('retains an uncertain grouped write even for a swallowed undefined rejection', async () => {
  const f = await groupFixture();
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000);
  await expect(lease.withOwnerWriteGroup(f.owner, async scoped => {
    await scoped.withOwnerWrite(f.owner, async () => { throw undefined; }).catch(() => {});
  })).rejects.toBeUndefined();
  expect(await f.count()).toBe(1); await expect(f.fence()).rejects.toThrow();
});

it('drains calls admitted during asynchronous guards before releasing on early callback failure', async () => {
  const f = await groupFixture();
  let openGuard!: () => void, enteredGuard!: () => void;
  const guard = new Promise<void>(resolve => { openGuard = resolve; });
  const entered = new Promise<void>(resolve => { enteredGuard = resolve; });
  let checks = 0, writes = 0, completed = false;
  let admitted!: Promise<void>, escaped!: Pick<RecoveryWriteLease, 'withOwnerWrite'>;
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000,
    { async assertNotRequested() { if (++checks === 2) { enteredGuard(); await guard; } } });
  const refusal = new Error('readback failed');
  const grouped = lease.withOwnerWriteGroup(f.owner, async scoped => {
    escaped = scoped;
    admitted = scoped.withOwnerWrite(f.owner, async () => { writes++; });
    await entered;
    throw refusal;
  });
  const outcome = grouped.then(() => { completed = true; }, error => {
    completed = true; expect(error).toBe(refusal);
  });
  await entered; await new Promise(resolve => setTimeout(resolve, 0));
  expect(completed).toBe(false); expect(await f.count()).toBe(1);
  await expect(f.fence()).rejects.toThrow();
  await expect(escaped.withOwnerWrite(f.owner, async () => { writes++; })).rejects.toThrow();
  openGuard(); await outcome; await admitted;
  expect(writes).toBe(1); expect(await f.count()).toBe(0);
  await expect(escaped.withOwnerWrite(f.owner, async () => { writes++; })).rejects.toThrow();
});

it('creates no lease for reads and rejects other owners before any transport', async () => {
  const f = await groupFixture();
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000);
  await expect(lease.withOwnerWriteGroup(f.owner, async () => 42)).resolves.toBe(42);
  expect(await f.count()).toBe(0);
  let writes = 0;
  await expect(lease.withOwnerWriteGroup(f.owner, async scoped => {
    await scoped.withOwnerWrite(crypto.randomUUID(), async () => { writes++; });
  })).rejects.toMatchObject({ code: 'RECOVERY_WRITE_FENCED' });
  expect(writes).toBe(0); expect(await f.count()).toBe(0);
});

it('rechecks disabled state even while the shared lease still exists', async () => {
  const f = await groupFixture();
  const lease = new RecoveryWriteLease(db, () => 1_800_000_000_000);
  let writes = 0;
  await expect(lease.withOwnerWriteGroup(f.owner, async scoped => {
    await scoped.withOwnerWrite(f.owner, async () => { writes++; });
    await db.prepare(`UPDATE pa_owners SET disabled=1 WHERE owner_id=?`).bind(f.owner).run();
    await scoped.withOwnerWrite(f.owner, async () => { writes++; });
  })).rejects.toMatchObject({ code: 'RECOVERY_WRITE_FENCED' });
  expect(writes).toBe(1); expect(await f.count()).toBe(0);
});

it('does not release after a lost grouped PUT response and late remote commit', async () => {
  const f = await groupFixture();
  let finish!: () => void, committed = false;
  const remote = new Promise<void>(resolve => { finish = () => { committed = true; resolve(); }; });
  const copy = new S3RecoveryCopy(config, async () => { throw new Error('response lost'); },
    new RecoveryWriteLease(db, () => 1_800_000_000_000));
  await expect(copy.withOwnerWriteGroup(f.owner, async scoped => {
    await scoped.putVersioned(`recovery/v1/${f.owner}/record/${crypto.randomUUID()}`, bytes).catch(() => {});
  })).rejects.toThrow();
  await expect(f.fence()).rejects.toThrow();
  finish(); await remote; expect(committed).toBe(true);
  expect(await f.count()).toBe(1); await expect(f.fence()).rejects.toThrow();
});

it('fails closed if the durable group cannot be released after confirmed writes', async () => {
  const f = await groupFixture();
  const failingDB = new Proxy(db, { get(target, property) {
    if (property === 'prepare') return (sql: string) => {
      const statement = target.prepare(sql);
      if (!sql.startsWith('DELETE FROM pa_recovery_write_leases')) return statement;
      const fake = { bind: () => fake, all: async () => { throw Error('D1 unavailable'); } };
      return fake;
    };
    const value = Reflect.get(target, property, target);
    return typeof value === 'function' ? value.bind(target) : value;
  } });
  const lease = new RecoveryWriteLease(failingDB, () => 1_800_000_000_000);
  await expect(lease.withOwnerWriteGroup(f.owner, scoped =>
    scoped.withOwnerWrite(f.owner, async () => 42)))
    .rejects.toMatchObject({ code: 'RECOVERY_WRITE_FENCED' });
  expect(await f.count()).toBe(1); await expect(f.fence()).rejects.toThrow();
});

it('groups real owner full-copy fallback and readback, retaining old versions through a generation race', async () => {
  const authority = await syntheticKeyAuthority();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() });
  const identityIndexSecret = randomToken(), now = 1_800_000_000_000;
  const objects = new Map<string, { bytes: Uint8Array; checksum: string; version: string }>();
  const leaseIds = new Set<string>();
  let race = false, owner = '', puts = 0, gets = 0;
  const s3 = new S3RecoveryCopy(config, async (input, init) => {
    const url = new URL(String(input)), key = url.pathname.slice(1);
    const object = objects.get(key);
    if (init?.method === 'PUT' || init?.method === 'HEAD') {
      const currentOwner = key.split('/')[2]!;
      const row = await db.prepare(`SELECT write_id FROM pa_recovery_write_leases WHERE owner_id=?`)
        .bind(currentOwner).first<{ write_id: string }>();
      expect(row).not.toBeNull(); leaseIds.add(row!.write_id);
      if (init.method === 'PUT') {
        expect(object).toBeUndefined(); puts++;
        const body = new Uint8Array(init.body as ArrayBuffer);
        objects.set(key, { bytes: body.slice(),
          checksum: new Headers(init.headers).get('x-amz-checksum-sha256')!, version: `v${puts}` });
      } else if (race && key.includes('/owner/')) {
        race = false;
        await db.prepare(`UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=?`)
          .bind(owner).run();
      }
    } else { gets++; }
    const stored = objects.get(key);
    if (!stored || (url.searchParams.has('versionId') && url.searchParams.get('versionId') !== stored.version)) {
      return new Response(null, { status: 404 });
    }
    return new Response(init?.method === 'GET' ? stored.bytes as BodyInit : null, { headers: {
      'x-amz-checksum-sha256': stored.checksum, 'x-amz-checksum-type': 'FULL_OBJECT',
      'x-amz-version-id': stored.version, 'content-length': String(stored.bytes.length),
    } });
  }, new RecoveryWriteLease(db, () => now));
  const copy = new OwnerRecoveryCopy(keys, s3, identityIndexSecret, { compressWrites: true, pagedWrites: true });
  const auth = new DurableAuth({ db, keys, identityIndexSecret, now: () => now,
    ownerRecovery: copy, requireOwnerRecovery: true });
  const session = await auth.establish({ issuer: 'https://appleid.apple.com',
    subject: crypto.randomUUID(), refreshToken: randomToken() });
  owner = session.ownerId;
  expect(puts).toBeGreaterThanOrEqual(2); expect(gets).toBeGreaterThan(0);
  expect(leaseIds.size).toBe(1);
  const original = new Map([...objects].map(([key, value]) => [key, value.bytes.slice()]));
  const oldGeneration = (await copy.capture(db, owner)).generation;
  await db.prepare(`UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=?`)
    .bind(owner).run();
  race = true;
  await expect(copy.copyCurrent(db, owner, now)).rejects.toThrow();
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_recovery_write_leases WHERE owner_id=?`)
    .bind(owner).first()).toEqual({ n: 0 });
  const ref = await copy.copyCurrent(db, owner, now);
  expect((await copy.read(owner, ref)).generation).toBe(oldGeneration + 2);
  for (const [key, data] of original) expect(objects.get(key)!.bytes).toEqual(data);
});
