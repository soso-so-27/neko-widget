import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { RecoveryWriteLease } from '../src/recovery-write-lease';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';

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
