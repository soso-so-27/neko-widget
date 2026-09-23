import { expect, it } from 'vitest';
import { envelopeKeyCustody } from '../src/key-custody';
import { RecordRecoveryCopy, type StoredRecordImage } from '../src/record-recovery-copy';
import { type RecoveryObject, S3RecoveryCopy } from '../src/s3-recovery-copy';
import { syntheticKeyAuthority } from './key-fixture';

const ownerId = '00000000-0000-4000-8000-000000000001';
const recordId = '00000000-0000-4000-8000-000000000002';
const operationId = '00000000-0000-4000-8000-000000000003';
const image = (): StoredRecordImage => ({ ownerId, recordId, revision: 1,
  initialFingerprint: 'a'.repeat(64), initialOperation: operationId,
  metadata: new Uint8Array([78, 75, 77, 49, 1, 2, 3]),
  photoKey: `personal/${ownerId}/${recordId}/${operationId}`,
  photoBytes: 3, photoCiphertext: new Uint8Array([78, 75, 77, 49, 4, 5]),
  quotaBytes: 13, deleted: false });

async function fixture(failOn?: 'photo' | 'record') {
  const authority = await syntheticKeyAuthority();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
  const objects = new Map<string, Uint8Array>();
  const s3 = {
    async putVersioned(key: string, bytes: Uint8Array): Promise<RecoveryObject> {
      if (failOn && key.includes(`/${failOn}/`)) throw new Error('synthetic S3 failure');
      const sha256 = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
        .map(value => value.toString(16).padStart(2, '0')).join('');
      const versionId = 'synthetic-v1';
      objects.set(`${key}:${versionId}`, bytes.slice());
      return { key, sha256, bytes: bytes.length, versionId };
    },
    async getVerified(item: RecoveryObject): Promise<Uint8Array> {
      const bytes = objects.get(`${item.key}:${item.versionId}`);
      if (!bytes) throw new Error('missing copy');
      const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
        .map(value => value.toString(16).padStart(2, '0')).join('');
      if (digest !== item.sha256 || bytes.length !== item.bytes) throw new Error('corrupt copy');
      return bytes.slice();
    },
  } as S3RecoveryCopy;
  return { records: new RecordRecoveryCopy(keys, s3), objects };
}

it('copies an encrypted record and photo as owner-bound versioned objects and reads exact versions', async () => {
  const f = await fixture(); const original = image();
  const copied = await f.records.copy(original);
  expect(copied.record.key).toMatch(new RegExp(`^recovery/v1/${ownerId}/record/`));
  expect(copied.photo?.key).toMatch(new RegExp(`^recovery/v1/${ownerId}/photo/`));
  expect(await f.records.read(ownerId, recordId, copied)).toEqual(original);
  const envelope = f.objects.get(`${copied.record.key}:${copied.record.versionId}`)!;
  expect(new TextDecoder().decode(envelope)).not.toContain('metadataBase64');
  expect(new TextDecoder().decode(envelope)).not.toContain(original.initialFingerprint);
});

it('copies a tombstone without resurrecting the prior photo or note', async () => {
  const f = await fixture(); const prior = await f.records.copy(image());
  const tombstone: StoredRecordImage = { ...image(), revision: 2, metadata: null,
    photoKey: null, photoBytes: 0, photoCiphertext: null, quotaBytes: 0, deleted: true };
  const latest = await f.records.copy(tombstone);
  expect(latest.photo).toBeNull();
  expect(await f.records.read(ownerId, recordId, latest)).toEqual(tombstone);
  expect(prior.record.key).not.toBe(latest.record.key);
});

it('fails closed if either S3 copy is unavailable and rejects foreign or corrupted references', async () => {
  await expect((await fixture('photo')).records.copy(image()))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  await expect((await fixture('record')).records.copy(image()))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  const f = await fixture(); const copied = await f.records.copy(image());
  await expect(f.records.read('00000000-0000-4000-8000-000000000099', recordId, copied))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  await expect(f.records.read(ownerId, recordId, { ...copied,
    photo: { ...copied.photo!, versionId: 'another-version' } }))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  const bytes = f.objects.get(`${copied.record.key}:${copied.record.versionId}`)!;
  bytes.set([bytes.at(-1)! ^ 1], bytes.length - 1);
  await expect(f.records.read(ownerId, recordId, copied))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
});

it('rejects a purported live record missing the photo or with mismatched ownership/accounting', async () => {
  const f = await fixture();
  await expect(f.records.copy({ ...image(), photoCiphertext: null }))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  await expect(f.records.copy({ ...image(), quotaBytes: 99 }))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  await expect(f.records.copy({ ...image(), photoKey: `personal/${ownerId}/${crypto.randomUUID()}/${operationId}` }))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
});

it('handles a valid large encrypted memo without a JavaScript argument-limit failure', async () => {
  const f = await fixture(); const metadata = new Uint8Array(200_000);
  metadata.fill(77);
  const large: StoredRecordImage = { ...image(), metadata, photoKey: null,
    photoBytes: 0, photoCiphertext: null, quotaBytes: metadata.length };
  const copied = await f.records.copy(large);
  expect(await f.records.read(ownerId, recordId, copied)).toEqual(large);
});

it('accepts the existing API contract for non-v4 record identifiers', async () => {
  const f = await fixture(); const olderRecordId = '00000000-0000-1000-8000-000000000002';
  const original: StoredRecordImage = { ...image(), recordId: olderRecordId,
    photoKey: `personal/${ownerId}/${olderRecordId}/${operationId}` };
  const copied = await f.records.copy(original);
  expect(await f.records.read(ownerId, olderRecordId, copied)).toEqual(original);
});
