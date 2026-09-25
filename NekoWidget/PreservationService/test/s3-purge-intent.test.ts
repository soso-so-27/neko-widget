import { expect, it } from 'vitest';
import { S3PurgeIntentStore, type PurgeIntentEvent,
  type S3PurgeIntentConfig } from '../src/s3-purge-intent';

const ownerId = '00000000-0000-4000-8000-000000000001';
const intentId = '00000000-0000-4000-8000-000000000002';
const config: S3PurgeIntentConfig = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE', secretAccessKey: 'synthetic-secret-never-for-real-aws' };
const prepared: PurgeIntentEvent = { version: 1, ownerId, intentId, stage: 'prepared',
  ownerEpoch: 2, inventoryGeneration: 8, retentionEpisode: 1, retentionRevision: 4,
  dueAt: 1_800_000_000_000, recordedAt: 1_800_000_001_000, manifestSha256: null };
const base64Digest = async (bytes: Uint8Array): Promise<string> => btoa(String.fromCharCode(
  ...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))));

it('writes an identifier-only event once, checks the exact S3 version and reads it back', async () => {
  let stored: Uint8Array | undefined;
  const calls: string[] = [];
  const store = new S3PurgeIntentStore(config, async (input, init) => {
    const url = new URL(String(input));
    const headers = new Headers(init?.headers);
    calls.push(String(init?.method));
    expect(url.origin).toBe('https://neko-preservation-recovery.s3.ap-northeast-1.amazonaws.com');
    expect(url.pathname).toBe(`/purge/v1/${ownerId}/${intentId}/prepared`);
    expect(headers.get('x-amz-expected-bucket-owner')).toBe(config.expectedAccountId);
    expect(headers.get('authorization')).toContain('/ap-northeast-1/s3/aws4_request');
    expect(init?.redirect).toBe('manual');
    if (init?.method === 'PUT') {
      expect(headers.get('if-none-match')).toBe('*');
      stored = new Uint8Array(await new Response(init.body).arrayBuffer());
      expect(new TextDecoder().decode(stored)).not.toContain('email');
      expect(headers.get('x-amz-checksum-sha256')).toBe(await base64Digest(stored));
      return new Response(null, { status: 200, headers: {
        'x-amz-version-id': 'intent-v1', 'x-amz-checksum-sha256': await base64Digest(stored) } });
    }
    expect(url.searchParams.get('versionId')).toBe('intent-v1');
    if (init?.method === 'HEAD') return new Response(null, { status: 200, headers: {
      'x-amz-version-id': 'intent-v1', 'x-amz-checksum-sha256': await base64Digest(stored!),
      'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(stored!.length) } });
    return new Response(stored as BodyInit, { status: 200,
      headers: { 'x-amz-version-id': 'intent-v1' } });
  });
  const saved = await store.putOnce(prepared);
  expect(saved).toMatchObject({ key: `purge/v1/${ownerId}/${intentId}/prepared`,
    versionId: 'intent-v1', bytes: stored!.length });
  expect(await store.readExact(saved)).toEqual(prepared);
  expect(calls).toEqual(['PUT', 'HEAD', 'GET', 'GET']);
});

it('idempotent retry accepts only exactly matching already-present bytes', async () => {
  const bytes = new TextEncoder().encode(JSON.stringify(prepared));
  const same = new S3PurgeIntentStore(config, async (_input, init) => init?.method === 'PUT'
    ? new Response(null, { status: 412 })
    : init?.method === 'HEAD'
      ? new Response(null, { status: 200, headers: {
        'x-amz-version-id': 'existing-v1', 'x-amz-checksum-sha256': await base64Digest(bytes),
        'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(bytes.length) } })
      : new Response(bytes as BodyInit, { status: 200,
        headers: { 'x-amz-version-id': 'existing-v1' } }));
  expect((await same.putOnce(prepared)).versionId).toBe('existing-v1');
  const conflict = new S3PurgeIntentStore(config, async (_input, init) => init?.method === 'PUT'
    ? new Response(null, { status: 412 })
    : new Response(null, { status: 200, headers: {
      'x-amz-version-id': 'existing-v1', 'x-amz-checksum-sha256': await base64Digest(bytes),
      'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': '1' } }));
  await expect(conflict.putOnce(prepared))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_UNAVAILABLE' });
});

it('rejects malformed stages, missing manifest hashes, wrong owner references and corrupt reads', async () => {
  expect(() => new S3PurgeIntentStore({ ...config, enabled: 'NO' })).toThrow();
  let calls = 0;
  const store = new S3PurgeIntentStore(config, async () => { calls++; throw Error('no request'); });
  for (const event of [
    { ...prepared, ownerId: '../other' },
    { ...prepared, stage: 'erasing' },
    { ...prepared, stage: 'completed', manifestSha256: 'not-a-digest' },
    { ...prepared, dueAt: -1 },
    { ...prepared, recordedAt: prepared.dueAt - 1 },
  ] as PurgeIntentEvent[]) {
    await expect(store.putOnce(event)).rejects.toMatchObject({ code: 'PURGE_INTENT_UNAVAILABLE' });
  }
  await expect(store.readExact({ key: `purge/v1/${ownerId}/${intentId}/prepared`,
    versionId: 'null', bytes: 20, sha256: '0'.repeat(64) }))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_UNAVAILABLE' });
  expect(calls).toBe(0);

  const tampered = new TextEncoder().encode(JSON.stringify({ ...prepared,
    ownerId: '00000000-0000-4000-8000-000000000099' }));
  const corrupt = new S3PurgeIntentStore(config, async () => new Response(tampered as BodyInit,
    { status: 200, headers: { 'x-amz-version-id': 'v1' } }));
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', tampered as BufferSource));
  await expect(corrupt.readExact({ key: `purge/v1/${ownerId}/${intentId}/prepared`,
    versionId: 'v1', bytes: tampered.length,
    sha256: Array.from(hash, byte => byte.toString(16).padStart(2, '0')).join('') }))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_UNAVAILABLE' });
});

it('discovers all event versions with cursors and verifies an exact listed version', async () => {
  const key = `purge/v1/${ownerId}/${intentId}/prepared`;
  const next = `purge/v1/${ownerId}/${intentId}/erasing`;
  const bytes = new TextEncoder().encode(JSON.stringify(prepared));
  let calls = 0;
  const store = new S3PurgeIntentStore(config, async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname !== '/') {
      expect(url.pathname).toBe(`/${key}`);
      expect(url.searchParams.get('versionId')).toBe('v1');
      return init?.method === 'HEAD' ? new Response(null, { status: 200, headers: {
        'x-amz-version-id': 'v1', 'x-amz-checksum-sha256': await base64Digest(bytes),
        'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(bytes.length) } })
        : new Response(bytes as BodyInit, { status: 200,
          headers: { 'x-amz-version-id': 'v1' } });
    }
    expect(url.searchParams.has('versions')).toBe(true);
    expect(url.searchParams.get('prefix')).toBe(`purge/v1/${ownerId}/`);
    calls++;
    if (calls === 1) return new Response(`<ListVersionsResult>
      <Name>${config.bucket}</Name><Prefix>purge/v1/${ownerId}/</Prefix>
      <EncodingType>url</EncodingType><MaxKeys>1000</MaxKeys><IsTruncated>true</IsTruncated>
      <Version><Key>${key}</Key><VersionId>v1</VersionId><Size>${bytes.length}</Size></Version>
      <NextKeyMarker>${next}</NextKeyMarker><NextVersionIdMarker>v2</NextVersionIdMarker>
      </ListVersionsResult>`);
    expect(url.searchParams.get('key-marker')).toBe(next);
    expect(url.searchParams.get('version-id-marker')).toBe('v2');
    return new Response(`<ListVersionsResult>
      <Name>${config.bucket}</Name><Prefix>purge/v1/${ownerId}/</Prefix>
      <EncodingType>url</EncodingType><MaxKeys>1000</MaxKeys>
      <KeyMarker>${next}</KeyMarker><VersionIdMarker>v2</VersionIdMarker>
      <IsTruncated>false</IsTruncated>
      <DeleteMarker><Key>${next}</Key><VersionId>m1</VersionId></DeleteMarker>
      </ListVersionsResult>`);
  });
  const first = await store.listOwnerVersionsPage(ownerId);
  expect(first).toEqual({ versions: [{ key, versionId: 'v1', bytes: bytes.length,
    deleteMarker: false }], nextCursor: { keyMarker: next, versionIdMarker: 'v2' } });
  const last = await store.listOwnerVersionsPage(ownerId, first.nextCursor!);
  expect(last).toEqual({ versions: [{ key: next, versionId: 'm1', bytes: null,
    deleteMarker: true }], nextCursor: null });
  const reference = await store.referenceForListedVersion(first.versions[0]!);
  expect(await store.readExact(reference)).toEqual(prepared);
  await expect(store.referenceForListedVersion(last.versions[0]!))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_UNAVAILABLE' });
});

it('refuses malformed or foreign listings rather than assuming deletion evidence is absent', async () => {
  const key = `purge/v1/${ownerId}/${intentId}/prepared`;
  const listing = (content: string) => `<ListVersionsResult><Name>${config.bucket}</Name>
    <Prefix>purge/v1/${ownerId}/</Prefix><EncodingType>url</EncodingType>
    <MaxKeys>1000</MaxKeys>${content}</ListVersionsResult>`;
  for (const xml of [
    listing('<IsTruncated>true</IsTruncated>'),
    listing(`<IsTruncated>false</IsTruncated><Version><Key>${key}</Key>
      <VersionId>null</VersionId><Size>2</Size></Version>`),
    listing(`<IsTruncated>false</IsTruncated><Version><Key>${key.replace(ownerId,
      '00000000-0000-4000-8000-000000000099')}</Key><VersionId>v1</VersionId>
      <Size>2</Size></Version>`),
    listing(`<IsTruncated>false</IsTruncated><Version><Key>${key}</Key>
      <VersionId>v1</VersionId><Size>2</Size></Version><DeleteMarker>
      <Key>${key}</Key><VersionId>v1</VersionId></DeleteMarker>`),
    listing(`<IsTruncated>false</IsTruncated><NextKeyMarker>${key}</NextKeyMarker>`),
    `<!DOCTYPE s3 [<!ENTITY x "bad">]>${listing('<IsTruncated>false</IsTruncated>')}`,
  ]) {
    const store = new S3PurgeIntentStore(config, async () => new Response(xml));
    await expect(store.listOwnerVersionsPage(ownerId))
      .rejects.toMatchObject({ code: 'PURGE_INTENT_UNAVAILABLE' });
  }
});
