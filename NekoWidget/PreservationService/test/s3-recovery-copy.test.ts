import { describe, expect, it } from 'vitest';
import { S3RecoveryCopy, type S3RecoveryConfig } from '../src/s3-recovery-copy';

const config: S3RecoveryConfig = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE', secretAccessKey: 'synthetic-secret-never-for-real-aws' };
const owner = '00000000-0000-4000-8000-000000000001';
const key = `recovery/v1/${owner}/photo/00000000-0000-4000-8000-000000000002`;
const data = new Uint8Array([1, 2, 3, 4, 5]); // opaque synthetic ciphertext
const base64 = (value: Uint8Array) => btoa(String.fromCharCode(...value));
const digest = async (value: Uint8Array) => base64(new Uint8Array(
  await crypto.subtle.digest('SHA-256', value as BufferSource)));

describe('private, versioned S3 recovery-object transport', () => {
  it('accepts the owner bootstrap kind under the same fixed-account version contract', async () => {
    const ownerKey = `recovery/v1/${owner}/owner/00000000-0000-4000-8000-000000000008`;
    const copy = new S3RecoveryCopy(config, async (input, init) => {
      expect(new URL(String(input)).pathname).toBe(`/${ownerKey}`);
      if (init?.method === 'PUT') return new Response(null, { status: 412 });
      return new Response(null, { status: 200,
        headers: { 'x-amz-checksum-sha256': await digest(data),
          'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(data.length),
          'x-amz-version-id': 'owner-v1' } });
    });
    expect(await copy.putVersioned(ownerKey, data)).toMatchObject({ key: ownerKey,
      versionId: 'owner-v1', bytes: data.length });
  });

  it('signs to a fixed bucket, validates a versioned checksum and reads the same version', async () => {
    let stored: Uint8Array | null = null;
    const calls: string[] = [];
    const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const headers = new Headers(init?.headers);
      expect(url.origin).toBe('https://neko-preservation-recovery.s3.ap-northeast-1.amazonaws.com');
      expect(url.pathname).toBe(`/${key}`);
      expect(headers.get('authorization')).toContain('/ap-northeast-1/s3/aws4_request');
      expect(headers.get('x-amz-expected-bucket-owner')).toBe('111122223333');
      expect(init?.redirect).toBe('manual');
      calls.push(String(init?.method));
      if (init?.method === 'PUT') {
        expect(headers.get('if-none-match')).toBe('*');
        const bytes = new Uint8Array(await new Response(init.body).arrayBuffer());
        expect(bytes).toEqual(data);
        expect(headers.get('x-amz-checksum-sha256')).toBe(await digest(bytes));
        stored = bytes;
        return new Response(null, { status: 200,
          headers: { 'x-amz-checksum-sha256': await digest(bytes), 'x-amz-version-id': 'v123' } });
      }
      if (init?.method === 'HEAD') {
        expect(url.searchParams.get('versionId')).toBe('v123');
        expect(headers.get('x-amz-checksum-mode')).toBe('ENABLED');
        return new Response(null, { status: 200,
          headers: { 'x-amz-checksum-sha256': await digest(stored!),
            'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(stored!.length),
            'x-amz-version-id': 'v123' } });
      }
      expect(url.searchParams.get('versionId')).toBe('v123');
      return new Response(stored! as BodyInit, { status: 200, headers: { 'x-amz-version-id': 'v123' } });
    };
    const copy = new S3RecoveryCopy(config, fetcher);
    const saved = await copy.putVersioned(key, data);
    expect(saved).toMatchObject({ key, bytes: data.length, versionId: 'v123' });
    expect(await copy.getVerified(saved)).toEqual(data);
    expect(calls).toEqual(['PUT', 'HEAD', 'GET']);
  });

  it('recovers a checksum-verified exact reference from a D1-independent S3 version listing', async () => {
    const marker = `recovery/v1/${owner}/manifest/00000000-0000-4000-8000-000000000009`;
    const copy = new S3RecoveryCopy(config, async (input, init) => {
      const url = new URL(String(input));
      expect(url.pathname).toBe(`/${marker}`);
      expect(url.searchParams.get('versionId')).toBe('marker-v1');
      if (init?.method === 'HEAD') return new Response(null, { status: 200,
        headers: { 'x-amz-checksum-sha256': await digest(data),
          'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(data.length),
          'x-amz-version-id': 'marker-v1' } });
      return new Response(data as BodyInit, { status: 200,
        headers: { 'x-amz-version-id': 'marker-v1' } });
    });
    const reference = await copy.referenceForListedVersion({ key: marker,
      versionId: 'marker-v1', bytes: data.length, deleteMarker: false });
    expect(await copy.getVerified(reference)).toEqual(data);
    await expect(copy.referenceForListedVersion({ key: marker,
      versionId: 'marker-v1', bytes: null, deleteMarker: true }))
      .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  });

  it('accepts only an identical already-present current version on retry', async () => {
    const copy = new S3RecoveryCopy(config, async (_input, init) => init?.method === 'PUT'
      ? new Response(null, { status: 412 })
      : new Response(null, { status: 200, headers: { 'x-amz-checksum-sha256': await digest(data),
        'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(data.length),
        'x-amz-version-id': 'same-version' } }));
    expect((await copy.putVersioned(key, data)).versionId).toBe('same-version');
    const mismatch = new S3RecoveryCopy(config, async (_input, init) => init?.method === 'PUT'
      ? new Response(null, { status: 412 })
      : new Response(null, { status: 200, headers: { 'x-amz-checksum-sha256': await digest(data),
        'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': '999',
        'x-amz-version-id': 'wrong-version' } }));
    await expect(mismatch.putVersioned(key, data)).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  });

  it('rejects a HEAD response for a different version after PUT', async () => {
    const copy = new S3RecoveryCopy(config, async (_input, init) => init?.method === 'PUT'
      ? new Response(null, { status: 200,
        headers: { 'x-amz-checksum-sha256': await digest(data), 'x-amz-version-id': 'written-v1' } })
      : new Response(null, { status: 200,
        headers: { 'x-amz-checksum-sha256': await digest(data),
          'x-amz-checksum-type': 'FULL_OBJECT', 'content-length': String(data.length),
          'x-amz-version-id': 'different-v2' } }));
    await expect(copy.putVersioned(key, data)).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  });

  it('fails closed on disabled credentials, non-versioned buckets, redirects and corrupted restore', async () => {
    expect(() => new S3RecoveryCopy({ ...config, enabled: 'NO' }, async () => {
      throw new Error('unexpected request');
    })).toThrowError();
    const noVersion = new S3RecoveryCopy(config, async (_input, init) => init?.method === 'PUT'
      ? new Response(null, { status: 200,
        headers: { 'x-amz-checksum-sha256': await digest(data), 'x-amz-version-id': 'null' } })
      : new Response(null, { status: 200 }));
    await expect(noVersion.putVersioned(key, data)).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    const redirect = new S3RecoveryCopy(config, async () => new Response(null,
      { status: 301, headers: { location: 'https://wrong.example' } }));
    await expect(redirect.putVersioned(key, data)).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    const corrupt = new S3RecoveryCopy(config, async () => new Response(new Uint8Array([9, 9, 9]),
      { status: 200, headers: { 'x-amz-version-id': 'v123' } }));
    await expect(corrupt.getVerified({ key, bytes: data.length, sha256: 'a'.repeat(64),
      versionId: 'v123' })).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    await expect(corrupt.putVersioned(`recovery/v1/${owner}/photo/../wrong`, data))
      .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  });

  it('lists every version and delete marker with an owner-bound pagination cursor', async () => {
    const second = `recovery/v1/${owner}/record/00000000-0000-4000-8000-000000000003`;
    let calls = 0;
    const copy = new S3RecoveryCopy(config, async (input, init) => {
      const url = new URL(String(input)); const headers = new Headers(init?.headers);
      expect(url.pathname).toBe('/');
      expect(url.searchParams.has('versions')).toBe(true);
      expect(url.searchParams.get('prefix')).toBe(`recovery/v1/${owner}/`);
      expect(url.searchParams.get('max-keys')).toBe('1000');
      expect(url.searchParams.get('encoding-type')).toBe('url');
      expect(headers.get('x-amz-expected-bucket-owner')).toBe(config.expectedAccountId);
      expect(init?.method).toBe('GET');
      calls += 1;
      if (calls === 1) {
        expect(url.searchParams.has('key-marker')).toBe(false);
        return new Response(`<?xml version="1.0"?><ListVersionsResult>
          <Name>${config.bucket}</Name><Prefix>recovery/v1/${owner}/</Prefix>
          <EncodingType>url</EncodingType><MaxKeys>1000</MaxKeys><IsTruncated>true</IsTruncated>
          <Version><Key>${key}</Key><VersionId>v1</VersionId><Size>5</Size></Version>
          <DeleteMarker><Key>${key}</Key><VersionId>m2</VersionId></DeleteMarker>
          <NextKeyMarker>${second}</NextKeyMarker><NextVersionIdMarker>v3</NextVersionIdMarker>
          </ListVersionsResult>`);
      }
      expect(url.searchParams.get('key-marker')).toBe(second);
      expect(url.searchParams.get('version-id-marker')).toBe('v3');
      return new Response(`<?xml version="1.0"?><ListVersionsResult>
        <Name>${config.bucket}</Name><Prefix>recovery/v1/${owner}/</Prefix>
        <EncodingType>url</EncodingType><MaxKeys>1000</MaxKeys>
        <KeyMarker>${second}</KeyMarker><VersionIdMarker>v3</VersionIdMarker>
        <IsTruncated>false</IsTruncated>
        <Version><Key>${second}</Key><VersionId>v3</VersionId><Size>42</Size></Version>
        </ListVersionsResult>`);
    });
    const first = await copy.listOwnerVersionsPage(owner);
    expect(first).toEqual({ versions: [
      { key, versionId: 'v1', bytes: 5, deleteMarker: false },
      { key, versionId: 'm2', bytes: null, deleteMarker: true },
    ], nextCursor: { keyMarker: second, versionIdMarker: 'v3' } });
    const last = await copy.listOwnerVersionsPage(owner, first.nextCursor!);
    expect(last).toEqual({ versions: [
      { key: second, versionId: 'v3', bytes: 42, deleteMarker: false },
    ], nextCursor: null });
    expect(calls).toBe(2);
  });

  it('never treats malformed, foreign, truncated or non-versioned S3 listings as a full inventory', async () => {
    const listing = (middle: string) => `<?xml version="1.0"?><ListVersionsResult>
      <Name>${config.bucket}</Name><Prefix>recovery/v1/${owner}/</Prefix>
      <EncodingType>url</EncodingType><MaxKeys>1000</MaxKeys>${middle}</ListVersionsResult>`;
    const bad = [
      '<ListVersionsResult>',
      listing('<IsTruncated>true</IsTruncated>'),
      listing(`<IsTruncated>false</IsTruncated><Version><Key>${key}</Key><VersionId>null</VersionId><Size>5</Size></Version>`),
      listing(`<IsTruncated>false</IsTruncated><Version><Key>recovery/v1/00000000-0000-4000-8000-000000000099/photo/00000000-0000-4000-8000-000000000002</Key><VersionId>v1</VersionId><Size>5</Size></Version>`),
      listing(`<IsTruncated>false</IsTruncated><Version><Key>${key}</Key><VersionId>v1</VersionId><Size>5</Size></Version><DeleteMarker><Key>${key}</Key><VersionId>v1</VersionId></DeleteMarker>`),
      listing(`<IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>recovery/v1/${owner}/photo/</Prefix></CommonPrefixes>`),
      listing(`<IsTruncated>false</IsTruncated><NextKeyMarker>${key}</NextKeyMarker>`),
      listing(`<IsTruncated>true</IsTruncated><Version><Key>${key}</Key><VersionId>v1</VersionId><Size>5</Size></Version><NextKeyMarker>${key}</NextKeyMarker>`),
      `<!DOCTYPE s3 [<!ENTITY x "bad">]>${listing('<IsTruncated>false</IsTruncated>')}`,
    ];
    for (const xml of bad) {
      const copy = new S3RecoveryCopy(config, async () => new Response(xml));
      await expect(copy.listOwnerVersionsPage(owner)).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    }
    const copy = new S3RecoveryCopy(config, async () => { throw new Error('unexpected network'); });
    await expect(copy.listOwnerVersionsPage('not-an-owner')).rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    await expect(copy.listOwnerVersionsPage(owner, { keyMarker: key, versionIdMarker: 'null' }))
      .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    const repeat = new S3RecoveryCopy(config, async () => new Response(listing(
      `<IsTruncated>true</IsTruncated><Version><Key>${key}</Key><VersionId>v1</VersionId><Size>5</Size></Version><NextKeyMarker>${key}</NextKeyMarker><NextVersionIdMarker>v1</NextVersionIdMarker>`)));
    await expect(repeat.listOwnerVersionsPage(owner, { keyMarker: key, versionIdMarker: 'v1' }))
      .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
    const missingEcho = new S3RecoveryCopy(config, async () => new Response(listing(
      `<IsTruncated>false</IsTruncated><Version><Key>${key}</Key><VersionId>v2</VersionId><Size>5</Size></Version>`)));
    await expect(missingEcho.listOwnerVersionsPage(owner, { keyMarker: key, versionIdMarker: 'v1' }))
      .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  });
});
