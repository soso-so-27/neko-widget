import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken } from '../src/contracts';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from '../src/owner-recovery-copy';
import { S3RecoveryCopy, type RecoveryObject } from '../src/s3-recovery-copy';
import { syntheticKeyAuthority } from './key-fixture';

const ownerId = '00000000-0000-4000-8000-000000000001';
const otherOwnerId = '00000000-0000-4000-8000-000000000002';
const accountId = '00000000-0000-4000-8000-000000000003';
const image = (): OwnerRecoveryImage => ({ ownerId, generation: 7, identityKey: 'a'.repeat(64),
  epoch: 2, disabled: false, purgeFenceId: null, createdAt: 100,
  credential: { ownerEpoch: 2, sealedCredentials: new Uint8Array([78, 75, 77, 49, 1]), updatedAt: 200 },
  contact: { sealedEmail: new Uint8Array([78, 75, 77, 49, 2]), emailTag: 'b'.repeat(64),
    verifiedAt: 150, updatedAt: 150 },
  billing: { accountId, createdAt: 180 },
  retention: { revision: 4, episode: 1, status: 'expired', checkedAt: 300,
    expiredAt: 250, dueAt: 400, pausedAt: null, noticeNotBeforeAt: 250,
    finalNoticeDeliveredAt: null, finalNoticeReceipt: null },
});

async function fixture() {
  const authority = await syntheticKeyAuthority();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
  const objects = new Map<string, Uint8Array>();
  const s3 = {
    async putVersioned(key: string, bytes: Uint8Array): Promise<RecoveryObject> {
      const sha256 = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('');
      objects.set(key, bytes.slice());
      return { key, versionId: 'synthetic-v1', sha256, bytes: bytes.length };
    },
    async getVerified(reference: RecoveryObject) {
      const bytes = objects.get(reference.key);
      if (!bytes || reference.versionId !== 'synthetic-v1' || bytes.length !== reference.bytes) {
        throw new Error('missing version');
      }
      const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('');
      if (digest !== reference.sha256) throw new Error('checksum');
      return bytes.slice();
    },
  } as S3RecoveryCopy;
  return { copy: new OwnerRecoveryCopy(keys, s3), objects, keys };
}

it('stores and verifies an encrypted owner bootstrap image without exposing the credentials', async () => {
  const f = await fixture();
  const original = image();
  const ref = await f.copy.copy(original);
  expect(ref.key).toMatch(new RegExp(`^recovery/v1/${ownerId}/owner/`));
  expect(await f.copy.read(ownerId, ref)).toEqual(original);
  const raw = new TextDecoder().decode(f.objects.get(ref.key)!);
  expect(raw).not.toContain(original.identityKey);
  expect(raw).not.toContain(accountId);
});

it('rejects cross-owner reads, stale references and malformed snapshots', async () => {
  const f = await fixture();
  const ref = await f.copy.copy(image());
  await expect(f.copy.read(otherOwnerId, ref))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  await expect(f.copy.read(ownerId, { ...ref, versionId: 'missing' }))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  await expect(f.copy.copy({ ...image(), billing: { accountId: otherOwnerId, createdAt: 0 } }))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  await expect(f.copy.copy({ ...image(), disabled: false, epoch: 3 }))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
});

it('captures a consistent D1 owner image, commits its current generation and advances after a link', async () => {
  const f = await fixture();
  const db = (env as unknown as { DB: D1Database }).DB;
  const now = 1_790_035_200_000;
  const auth = new DurableAuth({ db, keys: f.keys, identityIndexSecret: randomToken(), now: () => now });
  const session = await auth.establish({ issuer: 'https://appleid.apple.com',
    subject: crypto.randomUUID(), refreshToken: randomToken(), verifiedEmail: 'owner@example.com' });
  const first = await f.copy.capture(db, session.ownerId);
  expect(first.generation).toBeGreaterThan(1);
  expect(first.contact?.emailTag).toMatch(/^[a-f0-9]{64}$/u);
  expect(first.billing).toBeNull();
  const ref = await f.copy.copyCurrent(db, session.ownerId, now);
  expect(await f.copy.read(session.ownerId, ref)).toEqual(first);
  expect(await f.copy.copyCurrent(db, session.ownerId, now)).toEqual(ref);
  const count = await db.prepare('SELECT COUNT(*) AS count FROM pa_owner_recovery_versions WHERE owner_id=?')
    .bind(session.ownerId).first<{ count: number }>();
  expect(count?.count).toBe(1);
  const billingId = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
    VALUES(?,?,?)`).bind(session.ownerId, billingId, now).run();
  const second = await f.copy.capture(db, session.ownerId);
  expect(second.generation).toBe(first.generation + 1);
  expect(second.billing?.accountId).toBe(billingId);
  const next = await f.copy.copyCurrent(db, session.ownerId, now + 1);
  expect(next.key).not.toBe(ref.key);
  expect(await f.copy.read(session.ownerId, next)).toEqual(second);
});
