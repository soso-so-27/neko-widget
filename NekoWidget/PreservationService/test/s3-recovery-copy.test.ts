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
});
