import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { snapshotFencedOwnerCloudStorage } from '../src/owner-cloud-snapshot';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const { DB: db, ARCHIVE: archive } = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };

async function fixture(): Promise<{ ownerId: string; recordId: string; photoKey: string }> {
  const ownerId = crypto.randomUUID();
  const recordId = crypto.randomUUID();
  const photoKey = `personal/${ownerId}/${recordId}/${crypto.randomUUID()}`;
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,disabled,created_at) VALUES(?,?,1,1)')
    .bind(ownerId, crypto.randomUUID()).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
    initial_operation,metadata,photo_key,photo_bytes,quota_bytes,deleted)
    VALUES(?,?,1,'synthetic','synthetic',?,?,?,?,0)`)
    .bind(ownerId, recordId, new Uint8Array([1]).buffer, photoKey, 1, 2).run();
  await archive.put(photoKey, new Uint8Array([1]));
  return { ownerId, recordId, photoKey };
}

function versions(ownerId: string, recordId: string, revision: string) {
  return [{ key: `recovery/v1/${ownerId}/record/${recordId}`, versionId: revision,
    deleteMarker: false, bytes: 120 }];
}

it('reports a stable fenced owner without modifying D1, R2 or S3', async () => {
  const { ownerId, recordId, photoKey } = await fixture();
  let calls = 0;
  const s3 = { listOwnerVersionsPage: async () => {
    calls++;
    return { versions: versions(ownerId, recordId, 'v1'), nextCursor: null };
  } } as unknown as S3RecoveryCopy;
  const snapshot = await snapshotFencedOwnerCloudStorage(db, archive, s3, ownerId);
  expect(snapshot).toMatchObject({ ownerId, records: 1, photos: 1, r2Bytes: 1,
    s3Versions: 1, s3VersionBytes: 120, s3DeleteMarkers: 0 });
  expect(calls).toBe(2);
  expect((await archive.head(photoKey))?.size).toBe(1);
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(ownerId).first())
    .toMatchObject({ disabled: 1 });
});

it('rejects a changed S3 version during the second physical pass', async () => {
  const { ownerId, recordId } = await fixture();
  let calls = 0;
  const s3 = { listOwnerVersionsPage: async () => ({
    versions: versions(ownerId, recordId, ++calls === 1 ? 'v1' : 'v2'), nextCursor: null,
  }) } as unknown as S3RecoveryCopy;
  await expect(snapshotFencedOwnerCloudStorage(db, archive, s3, ownerId))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_SNAPSHOT_UNAVAILABLE' });
});

it('rejects a new unreferenced R2 photo and a changed DB generation', async () => {
  const { ownerId, recordId } = await fixture();
  let calls = 0;
  const s3 = { listOwnerVersionsPage: async () => {
    if (++calls === 1) {
      await archive.put(`personal/${ownerId}/${recordId}/${crypto.randomUUID()}`,
        new Uint8Array([2]));
    }
    return { versions: versions(ownerId, recordId, 'v1'), nextCursor: null };
  } } as unknown as S3RecoveryCopy;
  await expect(snapshotFencedOwnerCloudStorage(db, archive, s3, ownerId))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_SNAPSHOT_UNAVAILABLE' });

  const another = await fixture();
  let changed = false;
  const changingS3 = { listOwnerVersionsPage: async () => {
    if (!changed) {
      changed = true;
      await db.prepare('UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=?')
        .bind(another.ownerId).run();
    }
    return { versions: versions(another.ownerId, another.recordId, 'v1'), nextCursor: null };
  } } as unknown as S3RecoveryCopy;
  await expect(snapshotFencedOwnerCloudStorage(db, archive, changingS3, another.ownerId))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_SNAPSHOT_UNAVAILABLE' });
});
