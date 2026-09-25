import { expect, it } from 'vitest';
import { S3VersionPurge, type S3VersionPurgeConfig } from '../src/s3-version-purge';

const owner = '00000000-0000-4000-8000-000000000001';
const key = `recovery/v1/${owner}/record/00000000-0000-4000-8000-000000000002`;
const config: S3VersionPurgeConfig = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE', secretAccessKey: 'synthetic-secret-never-for-real-aws' };

it('signs a request for the exact owner and version, never a key-only delete', async () => {
  let calls = 0;
  const purge = new S3VersionPurge(config, async (input, init) => {
    calls++;
    const url = new URL(String(input));
    const headers = new Headers(init?.headers);
    expect(url.origin).toBe('https://neko-preservation-recovery.s3.ap-northeast-1.amazonaws.com');
    expect(url.pathname).toBe(`/${key}`);
    expect(url.searchParams.get('versionId')).toBe('v1');
    expect(init?.method).toBe('DELETE');
    expect(init?.redirect).toBe('manual');
    expect(headers.get('x-amz-expected-bucket-owner')).toBe(config.expectedAccountId);
    expect(headers.get('authorization')).toContain('/ap-northeast-1/s3/aws4_request');
    expect(headers.has('x-amz-bypass-governance-retention')).toBe(false);
    return new Response(null, { status: 204, headers: { 'x-amz-version-id': 'v1' } });
  });
  await purge.requestExactVersionDeletion(owner,
    { key, versionId: 'v1', deleteMarker: false, bytes: 10 });
  expect(calls).toBe(1);
});

it('rejects disabled credentials, cross-owner keys, missing versions and malformed entries', async () => {
  expect(() => new S3VersionPurge({ ...config, enabled: 'NO' })).toThrowError();
  let calls = 0;
  const purge = new S3VersionPurge(config, async () => { calls++; throw Error('must not request'); });
  for (const item of [
    { key, versionId: '', deleteMarker: false, bytes: 10 },
    { key, versionId: 'null', deleteMarker: false, bytes: 10 },
    { key, versionId: 'v1', deleteMarker: true, bytes: 10 },
    { key, versionId: 'v1', deleteMarker: false, bytes: null },
    { key: key.replace(owner, '00000000-0000-4000-8000-000000000099'),
      versionId: 'v1', deleteMarker: false, bytes: 10 },
    { key: `${key}/wrong`, versionId: 'v1', deleteMarker: false, bytes: 10 },
  ]) {
    await expect(purge.requestExactVersionDeletion(owner, item))
      .rejects.toMatchObject({ code: 'RECOVERY_VERSION_PURGE_UNAVAILABLE' });
  }
  expect(calls).toBe(0);
});

it('requires a matching 204 response and distinguishes delete markers from data', async () => {
  const markerItem = { key, versionId: 'marker-v1', deleteMarker: true, bytes: null };
  const marker = new S3VersionPurge(config, async () => new Response(null, { status: 204,
    headers: { 'x-amz-version-id': 'marker-v1', 'x-amz-delete-marker': 'true' } }));
  await marker.requestExactVersionDeletion(owner, markerItem);
  for (const [status, versionId, deleteMarker] of [
    [403, 'v1', null], [301, 'v1', null], [204, 'other', null], [204, null, null],
    [204, 'v1', 'true'],
  ] as const) {
    const purge = new S3VersionPurge(config, async () => new Response(null, { status,
      headers: { ...(versionId ? { 'x-amz-version-id': versionId } : {}),
        ...(deleteMarker ? { 'x-amz-delete-marker': deleteMarker } : {}) } }));
    await expect(purge.requestExactVersionDeletion(owner,
      { key, versionId: 'v1', deleteMarker: false, bytes: 10 }))
      .rejects.toMatchObject({ code: 'RECOVERY_VERSION_PURGE_UNAVAILABLE' });
  }
});
