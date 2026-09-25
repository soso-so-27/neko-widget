import { describe, expect, it } from 'vitest';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

describe('live staging S3 with synthetic ciphertext only', () => {
  it('writes a version, reads that exact version, and inventories it', async () => {
    const ownerId = required('NEKO_PROBE_OWNER_ID');
    const recordId = required('NEKO_PROBE_RECORD_ID');
    const key = `recovery/v1/${ownerId}/photo/${recordId}`;
    const copy = new S3RecoveryCopy({
      enabled: 'YES',
      region: required('NEKO_PROBE_AWS_REGION'),
      bucket: required('NEKO_PROBE_S3_BUCKET'),
      expectedAccountId: required('NEKO_PROBE_AWS_ACCOUNT_ID'),
      accessKeyId: required('NEKO_PROBE_AWS_ACCESS_KEY_ID'),
      secretAccessKey: required('NEKO_PROBE_AWS_SECRET_ACCESS_KEY'),
    }, async (input, init) => {
      let response: Response;
      try {
        response = await fetch(input, init);
      } catch (error) {
        console.log('S3_FETCH_EXCEPTION', error instanceof Error ? error.name : 'unknown');
        throw error;
      }
      const code = response.status >= 400
        ? (await response.clone().text()).match(/<Code>([^<]+)<\/Code>/u)?.[1] ?? 'unknown'
        : 'none';
      console.log('S3_RESPONSE', init?.method, response.status, code,
        response.headers.get('x-amz-checksum-type') ?? 'no-checksum-type',
        response.headers.has('x-amz-version-id') ? 'has-version' : 'no-version');
      return response;
    });
    const synthetic = new TextEncoder().encode('neko-preservation-synthetic-ciphertext-probe');
    const saved = await copy.putVersioned(key, synthetic);
    expect(saved.key).toBe(key);
    expect(saved.versionId).toBeTruthy();
    expect(await copy.getVerified(saved)).toEqual(synthetic);
    const listed = await copy.listOwnerVersionsPage(ownerId);
    expect(listed.nextCursor).toBeNull();
    expect(listed.versions).toContainEqual({
      key, versionId: saved.versionId, deleteMarker: false, bytes: synthetic.length,
    });
  });
});
