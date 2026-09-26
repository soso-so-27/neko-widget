import { expect, it } from 'vitest';
import { buildOwnerPurgeManifest } from '../src/owner-purge-manifest';
import { S3PurgeManifestStore } from '../src/s3-purge-manifest';
import type { PurgeFence } from '../src/owner-purge-fence';

const ownerId = '00000000-0000-4000-8000-000000000001';
const intentId = '00000000-0000-4000-8000-000000000002';
const photoKey = `personal/${ownerId}/00000000-0000-4000-8000-000000000003/00000000-0000-4000-8000-000000000004`;
const recoveryKey = `recovery/v1/${ownerId}/record/00000000-0000-4000-8000-000000000005`;
const config = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE',
  secretAccessKey: 'synthetic-secret-never-for-real-aws' };
const manifest = () => buildOwnerPurgeManifest({ ownerId, fenceId: intentId,
  ownerEpoch: 2, inventoryGeneration: 4 } as PurgeFence,
{ ownerId, epoch: 2, generation: 4, records: 1, photos: 1,
  photoKeys: [photoKey], recordDigest: 'a'.repeat(64) },
{ ownerId, r2Objects: [{ key: photoKey, version: 'r2-v1', bytes: 8 }], r2Bytes: 8,
  s3Versions: [{ key: recoveryKey, versionId: 's3-v1', deleteMarker: false, bytes: 12 }],
  s3VersionBytes: 12, s3DeleteMarkers: 0 });

it('writes immutable, exact-version chunks before a header and accepts an identical retry', async () => {
  const objects = new Map<string, { bytes: Uint8Array; checksum: string; versionId: string }>();
  let writes = 0;
  const store = new S3PurgeManifestStore(config, async (input, init) => {
    const url = new URL(String(input));
    if (url.searchParams.has('versions')) {
      const entries = [...objects.entries()].map(([key, item]) =>
        `<Version><Key>${key}</Key><VersionId>${item.versionId}</VersionId>`
        + `<Size>${item.bytes.length}</Size></Version>`).join('');
      return new Response(`<?xml version="1.0"?><ListVersionsResult>`
        + `<Name>${config.bucket}</Name>`
        + `<Prefix>purge-plan/v1/${ownerId}/${intentId}/</Prefix>`
        + `<MaxKeys>1000</MaxKeys><EncodingType>url</EncodingType>`
        + `<IsTruncated>false</IsTruncated>${entries}</ListVersionsResult>`,
      { status: 200 });
    }
    const key = decodeURIComponent(url.pathname.slice(1));
    expect(key).toMatch(new RegExp(`^purge-plan/v1/${ownerId}/${intentId}/`));
    expect(new Headers(init?.headers).get('x-amz-expected-bucket-owner'))
      .toBe(config.expectedAccountId);
    const existing = objects.get(key);
    if (init?.method === 'PUT') {
      expect(new Headers(init.headers).get('if-none-match')).toBe('*');
      if (existing) return new Response(null, { status: 412 });
      const bytes = new Uint8Array(await new Response(init.body).arrayBuffer());
      const checksum = btoa(String.fromCharCode(...new Uint8Array(
        await crypto.subtle.digest('SHA-256', bytes as BufferSource))));
      expect(new Headers(init.headers).get('x-amz-checksum-sha256')).toBe(checksum);
      const versionId = `v-${++writes}`;
      objects.set(key, { bytes, checksum, versionId });
      return new Response(null, { status: 200, headers: {
        'x-amz-version-id': versionId, 'x-amz-checksum-sha256': checksum } });
    }
    if (!existing || (url.searchParams.has('versionId')
      && url.searchParams.get('versionId') !== existing.versionId)) {
      return new Response(null, { status: 404 });
    }
    const headers = { 'x-amz-version-id': existing.versionId,
      'x-amz-checksum-sha256': existing.checksum,
      'x-amz-checksum-type': 'FULL_OBJECT',
      'content-length': String(existing.bytes.length) };
    return init?.method === 'HEAD'
      ? new Response(null, { status: 200, headers })
      : new Response(existing.bytes as BodyInit, { status: 200, headers });
  });
  const plan = await manifest();
  for (let i = 0; i < plan.chunks.length; i++) await store.putChunk(plan, i);
  const header = await store.putHeader(plan);
  expect(header.key).toBe(`purge-plan/v1/${ownerId}/${intentId}/header`);
  expect(objects.size).toBe(plan.chunks.length + 1);
  expect(writes).toBe(plan.chunks.length + 1);
  expect(await store.putChunk(plan, 0)).toMatchObject({ versionId: 'v-1' });
  expect(await store.putHeader(plan)).toEqual(header);
  expect(writes).toBe(plan.chunks.length + 1);
  const parsed = JSON.parse(new TextDecoder().decode(await store.readExact(header)));
  expect(parsed).toMatchObject({ ownerId, intentId, sha256: plan.sha256,
    r2Count: 1, s3Count: 1 });
  await expect(store.verifyPublished(plan)).resolves.toBeUndefined();
  await expect(store.loadPublished(ownerId, intentId, plan.sha256)).resolves.toEqual(plan);
  await expect(store.loadPublished(ownerId, intentId, 'f'.repeat(64))).rejects
    .toMatchObject({ code: 'PURGE_MANIFEST_COPY_UNAVAILABLE' });
  objects.delete(`purge-plan/v1/${ownerId}/${intentId}/chunk/000000`);
  await expect(store.verifyPublished(plan)).rejects.toMatchObject({
    code: 'PURGE_MANIFEST_COPY_UNAVAILABLE' });
});

it('rejects a changed chunk or a mismatched exact-version read', async () => {
  const plan = await manifest();
  const store = new S3PurgeManifestStore(config, async () => new Response(null, { status: 404 }));
  const bad = { ...plan, chunks: [{ ...plan.chunks[0]!, bytes: plan.chunks[0]!.bytes + 1 },
    ...plan.chunks.slice(1)] };
  await expect(store.putChunk(bad, 0)).rejects.toMatchObject({
    code: 'PURGE_MANIFEST_COPY_UNAVAILABLE' });
  await expect(store.readExact({ key: `purge-plan/v1/${ownerId}/${intentId}/header`,
    versionId: 'stale', bytes: 123, sha256: 'a'.repeat(64) }))
    .rejects.toMatchObject({ code: 'PURGE_MANIFEST_COPY_UNAVAILABLE' });
});

it('pages the exact owner plan prefix and surfaces every version and marker', async () => {
  let calls = 0;
  const headerKey = `purge-plan/v1/${ownerId}/${intentId}/header`;
  const chunkKey = `purge-plan/v1/${ownerId}/${intentId}/chunk/000000`;
  const page = (truncated: boolean, entries: string, cursor = '') =>
    `<?xml version="1.0"?><ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`
    + `<Name>${config.bucket}</Name><Prefix>purge-plan/v1/${ownerId}/${intentId}/</Prefix>`
    + `<MaxKeys>1000</MaxKeys><EncodingType>url</EncodingType>`
    + `<IsTruncated>${truncated}</IsTruncated>${cursor}${entries}</ListVersionsResult>`;
  const store = new S3PurgeManifestStore(config, async (input) => {
    const url = new URL(String(input));
    expect(url.searchParams.get('prefix'))
      .toBe(`purge-plan/v1/${ownerId}/${intentId}/`);
    if (++calls === 1) return new Response(page(true,
      `<Version><Key>${headerKey}</Key><VersionId>v1</VersionId><Size>123</Size></Version>`,
      `<NextKeyMarker>${headerKey}</NextKeyMarker><NextVersionIdMarker>v1</NextVersionIdMarker>`),
    { status: 200 });
    expect(url.searchParams.get('key-marker')).toBe(headerKey);
    expect(url.searchParams.get('version-id-marker')).toBe('v1');
    return new Response(page(false,
      `<Version><Key>${chunkKey}</Key><VersionId>v2</VersionId><Size>99</Size></Version>`
      + `<DeleteMarker><Key>${chunkKey}</Key><VersionId>v3</VersionId></DeleteMarker>`,
      `<KeyMarker>${headerKey}</KeyMarker><VersionIdMarker>v1</VersionIdMarker>`),
    { status: 200 });
  });
  const first = await store.listOwnerVersionsPage(ownerId, intentId);
  expect(first.versions).toEqual([{ key: headerKey, versionId: 'v1',
    deleteMarker: false, bytes: 123 }]);
  expect(first.nextCursor).toEqual({ keyMarker: headerKey, versionIdMarker: 'v1' });
  const second = await store.listOwnerVersionsPage(ownerId, intentId, first.nextCursor!);
  expect(second.versions).toHaveLength(2);
  expect(second.versions[1]).toMatchObject({ key: chunkKey, versionId: 'v3',
    deleteMarker: true, bytes: null });
  expect(second.nextCursor).toBeNull();
  calls = 0;
  await expect(store.loadPublished(ownerId, intentId, 'a'.repeat(64)))
    .rejects.toMatchObject({ code: 'PURGE_MANIFEST_COPY_UNAVAILABLE' });
  expect(calls).toBe(2);
});
