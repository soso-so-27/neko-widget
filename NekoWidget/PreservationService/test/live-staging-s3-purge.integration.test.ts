import { describe, expect, it } from 'vitest';
import { AwsV4Signer } from 'aws4fetch';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { S3VersionPurge } from '../src/s3-version-purge';

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

describe('live staging exact-version purge of synthetic ciphertext only', () => {
  it('deletes two data versions and a delete marker, then confirms the owner prefix is empty', async () => {
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
    const first = await copy.putVersioned(key, synthetic);
    expect(await copy.getVerified(first)).toEqual(synthetic);
    // A normal unversioned DELETE only adds a marker. Create one for this
    // synthetic key so the exact-version purge must remove it as well.
    const markerUrl = `https://${config.bucket}.s3.${config.region}.amazonaws.com/${key}`;
    const signer = new AwsV4Signer({ url: markerUrl, method: 'DELETE', service: 's3',
      region: config.region, accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey, allHeaders: true,
      headers: { 'x-amz-expected-bucket-owner': config.expectedAccountId } });
    const signed = await signer.sign();
    const markerReply = await fetch(signed.url, { method: 'DELETE', headers: signed.headers,
      redirect: 'manual', signal: AbortSignal.timeout(30_000) });
    expect(markerReply.status).toBe(204);
    expect(markerReply.headers.get('x-amz-delete-marker')).toBe('true');
    const markerVersionId = markerReply.headers.get('x-amz-version-id');
    expect(markerVersionId).toBeTruthy();
    const secondBytes = new TextEncoder().encode('second-synthetic-ciphertext-after-delete-marker');
    const second = await copy.putVersioned(key, secondBytes);
    expect(second.versionId).not.toBe(first.versionId);
    expect(await copy.getVerified(second)).toEqual(secondBytes);
    const before = await copy.listOwnerVersionsPage(ownerId);
    expect(before.nextCursor).toBeNull();
    expect(before.versions).toHaveLength(3);
    expect(before.versions).toEqual(expect.arrayContaining([
      { key, versionId: first.versionId, deleteMarker: false, bytes: synthetic.length },
      { key, versionId: markerVersionId, deleteMarker: true, bytes: null },
      { key, versionId: second.versionId, deleteMarker: false, bytes: secondBytes.length },
    ]));
    for (const version of before.versions) {
      await purge.requestExactVersionDeletion(ownerId, version);
    }
    const after = await copy.listOwnerVersionsPage(ownerId);
    expect(after.nextCursor).toBeNull();
    expect(after.versions).toEqual([]);
  });
});
