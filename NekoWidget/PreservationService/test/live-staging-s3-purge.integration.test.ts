import { describe, expect, it } from 'vitest';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { S3VersionPurge } from '../src/s3-version-purge';

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

describe('live staging exact-version purge of synthetic ciphertext only', () => {
  it('deletes one listed version and confirms its owner prefix is empty', async () => {
    const ownerId = required('NEKO_PROBE_OWNER_ID');
    const recordId = required('NEKO_PROBE_RECORD_ID');
    const key = `recovery/v1/${ownerId}/photo/${recordId}`;
    const config = {
      enabled: 'YES', region: required('NEKO_PROBE_AWS_REGION'),
      bucket: required('NEKO_PROBE_S3_BUCKET'),
      expectedAccountId: required('NEKO_PROBE_AWS_ACCOUNT_ID'),
      accessKeyId: required('NEKO_PROBE_AWS_ACCESS_KEY_ID'),
      secretAccessKey: required('NEKO_PROBE_AWS_SECRET_ACCESS_KEY'),
    };
    const copy = new S3RecoveryCopy(config);
    const purge = new S3VersionPurge(config);
    const synthetic = new TextEncoder().encode('synthetic-ciphertext-for-exact-version-purge');
    const saved = await copy.putVersioned(key, synthetic);
    expect(await copy.getVerified(saved)).toEqual(synthetic);
    const before = await copy.listOwnerVersionsPage(ownerId);
    expect(before.nextCursor).toBeNull();
    expect(before.versions).toEqual([{
      key, versionId: saved.versionId, deleteMarker: false, bytes: synthetic.length,
    }]);
    await purge.requestExactVersionDeletion(ownerId, before.versions[0]!);
    const after = await copy.listOwnerVersionsPage(ownerId);
    expect(after.nextCursor).toBeNull();
    expect(after.versions).toEqual([]);
  });
});
