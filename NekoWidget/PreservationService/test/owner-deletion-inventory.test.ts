import { env } from 'cloudflare:workers';
import { describe, it, expect, vi } from 'vitest';
import worker, { type Env } from '../src/index';
import { OwnerDeletionJournal } from '../src/owner-deletion-journal';
import { handleDeletionInventory, boundDeletionInventory } from '../src/owner-deletion-inventory';
import { randomToken, sha256 } from '../src/contracts';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';

describe('private deletion inventory binding', () => {
  it('requires the caller and an owner receipt, and cannot be reached by public HTTP', async () => {
    const secret = randomToken();
    const e = { ...env, OWNER_DELETION_ENABLED: 'YES', KEY_WRAPPER_CALLER_SECRET: secret,
      RECOVERY_S3_REGION: 'ap-northeast-1', RECOVERY_S3_BUCKET: 'neko-preservation-recovery',
      RECOVERY_S3_ACCOUNT_ID: '111122223333' } as unknown as Env;
    await e.ARCHIVE.put('__owner_deletion/v1/format.json', '{"version":1}');
    const ownerId = crypto.randomUUID();
    const reader = { listOwnerVersionsPage: vi.fn(async () => ({ versions: [], nextCursor: null })) };
    const request = (token = secret, cursor?: unknown) => new Request('https://private/recovery/versions', {
      method: 'POST', headers: { 'x-neko-preservation-key-token': token }, body: JSON.stringify({ ownerId, cursor }),
    });
    expect((await handleDeletionInventory(request(), e, reader)).status).toBe(503);
    await new OwnerDeletionJournal(e.ARCHIVE).prepare({ version: 1, ownerId, ownerEpoch: 1,
      requestId: crypto.randomUUID(), requestedAt: 1, receiptHash: await sha256(randomToken()) });
    expect((await handleDeletionInventory(request(randomToken()), e, reader)).status).toBe(503);
    expect(reader.listOwnerVersionsPage).not.toHaveBeenCalled();
    const response = await handleDeletionInventory(request(), e, reader);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ region: e.RECOVERY_S3_REGION, bucket: e.RECOVERY_S3_BUCKET,
      accountId: e.RECOVERY_S3_ACCOUNT_ID, versions: [], nextCursor: null });
    expect((await worker.fetch(request(), e)).status).not.toBe(200);
    const send = vi.fn<typeof fetch>();
    const actual = new S3RecoveryCopy({ enabled: 'YES', region: 'ap-northeast-1',
      bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
      accessKeyId: 'AKIA1234567890EXAMPLE', secretAccessKey: 'synthetic-secret-never-for-real-aws' }, send);
    expect((await handleDeletionInventory(request(secret, {
      keyMarker: `recovery/v1/${crypto.randomUUID()}/photo/${crypto.randomUUID()}`,
    }), e, actual)).status).toBe(503);
    expect(send).not.toHaveBeenCalled();
  });

  it('rejects a binding connected to a different account or bucket', async () => {
    const binding = { fetch: vi.fn(async () => Response.json({ region: 'ap-northeast-1',
      bucket: 'other-bucket', accountId: '111122223333', versions: [], nextCursor: null })) } as unknown as Fetcher;
    const reader = boundDeletionInventory(binding, randomToken(), { region: 'ap-northeast-1',
      bucket: 'expected-bucket', accountId: '111122223333' });
    await expect(reader.listOwnerVersionsPage(crypto.randomUUID())).rejects.toThrow();
  });
});
