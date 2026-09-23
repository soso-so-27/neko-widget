import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken } from '../src/contracts';
import { identityIndexKey, indexedNoticeEmail, indexedOwnerIdentity } from '../src/identity-index';
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
  const identityIndexSecret = randomToken();
  const objects = new Map<string, Uint8Array>();
  let rejectOwner: string | null = null;
  let rejectAll = false;
  const s3 = {
    async putVersioned(key: string, bytes: Uint8Array): Promise<RecoveryObject> {
      if (rejectAll || (rejectOwner && key.startsWith(`recovery/v1/${rejectOwner}/`))) {
        throw new Error('synthetic S3 outage');
      }
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
  return { copy: new OwnerRecoveryCopy(keys, s3, identityIndexSecret), objects, keys,
    identityIndexSecret,
    rejectOwner(value: string | null) { rejectOwner = value; },
    rejectAll(value: boolean) { rejectAll = value; } };
}

async function verifiedImage(f: Awaited<ReturnType<typeof fixture>>): Promise<OwnerRecoveryImage> {
  const original = image();
  const key = await identityIndexKey(f.identityIndexSecret);
  const issuer = 'https://appleid.apple.com';
  const subject = 'recovery-test-subject';
  const email = 'owner@example.com';
  return { ...original, identityKey: await indexedOwnerIdentity(key, issuer, subject),
    credential: { ...original.credential,
      sealedCredentials: await f.keys.seal(new TextEncoder().encode(JSON.stringify({
        issuer, subject, refreshToken: randomToken(),
      })), { ownerId, purpose: 'identity' }) },
    contact: { ...original.contact!,
      sealedEmail: await f.keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1, email })),
        { ownerId, purpose: 'contact' }),
      emailTag: await indexedNoticeEmail(key, ownerId, email) } };
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

it('stages S3-only recovery without reusing an old recipient or deletion notice', async () => {
  const f = await fixture();
  const original = await verifiedImage(f);
  original.retention = { ...original.retention!, finalNoticeDeliveredAt: 350,
    finalNoticeReceipt: 'delivery-event-00000001' };
  const ref = await f.copy.copy(original);
  const selected = await f.copy.selectRecoveredOwner(ownerId, [ref], 1_000);
  expect(selected.status).toBe('reauth-required');
  if (selected.status !== 'reauth-required') throw new Error('expected quarantined owner');
  expect(selected.image.disabled).toBe(true);
  expect(selected.image.contact).toBeNull();
  expect(selected.image.credential).toEqual(original.credential);
  expect(selected.image.retention).toMatchObject({ status: 'unknown', checkedAt: 0,
    revision: 5, pausedAt: 1_000, noticeNotBeforeAt: 1_000,
    finalNoticeDeliveredAt: null, finalNoticeReceipt: null });
  expect((await f.copy.read(ownerId, ref)).contact).toEqual(original.contact);
  const disabled = { ...original, disabled: true };
  const disabledRef = await f.copy.copy(disabled);
  expect(await f.copy.selectRecoveredOwner(ownerId, [disabledRef], 1_000))
    .toEqual({ status: 'disabled' });
});

it('refuses an owner image whose sealed credential does not match the owner identity key', async () => {
  const f = await fixture();
  const valid = await verifiedImage(f);
  const wrong = { ...valid, identityKey: 'c'.repeat(64) };
  const ref = await f.copy.copy(wrong);
  expect(await f.copy.selectRecoveredOwner(ownerId, [ref], 1_000))
    .toEqual({ status: 'quarantined' });
  const wrongContact = { ...valid, contact: { ...valid.contact!, emailTag: 'd'.repeat(64) } };
  const contactRef = await f.copy.copy(wrongContact);
  expect(await f.copy.selectRecoveredOwner(ownerId, [contactRef], 1_000))
    .toEqual({ status: 'quarantined' });
});

it('captures a consistent D1 owner image, commits its current generation and advances after a link', async () => {
  const f = await fixture();
  const db = (env as unknown as { DB: D1Database }).DB;
  const now = 1_790_035_200_000;
  const auth = new DurableAuth({ db, keys: f.keys, identityIndexSecret: f.identityIndexSecret, now: () => now });
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
  await db.prepare('UPDATE pa_owners SET identity_key=? WHERE owner_id=?')
    .bind('c'.repeat(64), session.ownerId).run();
  await expect(f.copy.copyCurrent(db, session.ownerId, now + 2))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  await db.prepare('UPDATE pa_owners SET identity_key=? WHERE owner_id=?')
    .bind(first.identityKey, session.ownerId).run();
  await f.copy.copyCurrent(db, session.ownerId, now + 3);
});

it('does not acknowledge sign-in while S3 is down and repairs independent owner rows fairly', async () => {
  const f = await fixture();
  const db = (env as unknown as { DB: D1Database }).DB;
  const now = 1_790_035_200_000;
  const auth = new DurableAuth({ db, keys: f.keys, identityIndexSecret: f.identityIndexSecret,
    now: () => now, ownerRecovery: f.copy, requireOwnerRecovery: true });
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(),
    refreshToken: randomToken() };
  f.rejectAll(true);
  await expect(auth.establish(identity))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  f.rejectAll(false);
  const first = await auth.establish(identity);
  await expect(auth.revokeOwner(first.ownerId))
    .rejects.toMatchObject({ code: 'OWNER_REVOCATION_NOT_CONFIGURED' });
  expect((await auth.requireSession(first.token)).ownerId).toBe(first.ownerId);
  const second = await auth.establish({ ...identity, subject: crypto.randomUUID() });
  const ids = [first.ownerId, second.ownerId].sort();
  await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?')
    .bind(ids[0]).run();
  await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?')
    .bind(ids[1]).run();
  f.rejectOwner(ids[0]!);
  expect(await f.copy.repairBatch(db, now + 1, 2)).toEqual({ processed: 2, failed: 1 });
  expect((await f.copy.ledgerCoverage(db)).pending).toBe(1);
  f.rejectOwner(null);
  expect(await f.copy.repairBatch(db, now + 2, 2)).toEqual({ processed: 1, failed: 0 });
  expect((await f.copy.ledgerCoverage(db)).pending).toBe(0);
  expect(await db.prepare('SELECT owner_id FROM pa_owner_recovery_repair_failures WHERE owner_id=?')
    .bind(ids[0]).first()).toBeNull();
});
