import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken } from '../src/contracts';
import { identityIndexKey, indexedNoticeEmail, indexedOwnerIdentity } from '../src/identity-index';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerArchiveRecovery } from '../src/owner-archive-recovery';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from '../src/owner-recovery-copy';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import { S3RecoveryCopy, type RecoveryObject } from '../src/s3-recovery-copy';
import { ArchiveStore } from '../src/storage';
import { syntheticKeyAuthority } from './key-fixture';

const ownerId = '00000000-0000-4000-8000-000000000001';
const otherOwnerId = '00000000-0000-4000-8000-000000000002';
const accountId = '00000000-0000-4000-8000-000000000003';
const image = (): OwnerRecoveryImage => ({ ownerId, generation: 7, identityKey: 'a'.repeat(64),
  epoch: 2, disabled: false, purgeFenceId: null, createdAt: 100,
  inventoryGeneration: 0, records: [],
  credential: { ownerEpoch: 2, sealedCredentials: new Uint8Array([78, 75, 77, 49, 1]), updatedAt: 200 },
  contact: { sealedEmail: new Uint8Array([78, 75, 77, 49, 2]), emailTag: 'b'.repeat(64),
    verifiedAt: 150, updatedAt: 150 },
  billing: { accountId, createdAt: 180 },
  retention: { revision: 4, episode: 1, status: 'expired', checkedAt: 300,
    expiredAt: 250, dueAt: 400, pausedAt: null, noticeNotBeforeAt: 250,
    finalNoticeDeliveredAt: null, finalNoticeReceipt: null },
});

async function fixture(compressWrites = false) {
  const authority = await syntheticKeyAuthority();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
  const identityIndexSecret = randomToken();
  const objects = new Map<string, Uint8Array>();
  const references: RecoveryObject[] = [];
  const omittedFromListing = new Set<string>();
  let pageSize = Number.MAX_SAFE_INTEGER;
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
      const reference = { key, versionId: 'synthetic-v1', sha256, bytes: bytes.length };
      references.push(reference);
      return reference;
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
    async listOwnerVersionsPage(requestedOwner: string,
      cursor?: { keyMarker: string; versionIdMarker?: string }) {
      if (!/^[0-9a-f-]{36}$/u.test(requestedOwner)) throw new Error('bad owner');
      const listed = references.filter(ref => ref.key.startsWith(`recovery/v1/${requestedOwner}/`)
        && !omittedFromListing.has(ref.key));
      const previous = cursor === undefined ? -1 : listed.findIndex(ref =>
        ref.key === cursor.keyMarker && ref.versionId === cursor.versionIdMarker);
      if (cursor !== undefined && previous < 0) throw new Error('missing cursor');
      const page = listed.slice(previous + 1, previous + 1 + pageSize);
      const last = page.at(-1);
      return { versions: page.map(ref => ({ key: ref.key, versionId: ref.versionId,
        bytes: ref.bytes, deleteMarker: false })),
      nextCursor: previous + 1 + page.length < listed.length && last
        ? { keyMarker: last.key, versionIdMarker: last.versionId } : null };
    },
    async referenceForListedVersion(item: { key: string; versionId: string; bytes: number | null }) {
      const found = references.find(ref => ref.key === item.key && ref.versionId === item.versionId);
      if (!found || found.bytes !== item.bytes || omittedFromListing.has(item.key)) {
        throw new Error('version missing');
      }
      return found;
    },
  } as S3RecoveryCopy;
  return { copy: new OwnerRecoveryCopy(keys, s3, identityIndexSecret, { compressWrites }), objects, keys, s3,
    identityIndexSecret,
    omitFromListing(key: string) { omittedFromListing.add(key); },
    setPageSize(value: number) { pageSize = value; },
    rejectOwner(value: string | null) { rejectOwner = value; },
    rejectAll(value: boolean) { rejectAll = value; } };
}

it('binds each acknowledged record and tombstone to a current owner-wide manifest', async () => {
  const f = await fixture();
  const db = (env as unknown as { DB: D1Database; ARCHIVE: R2Bucket }).DB;
  const bucket = (env as unknown as { ARCHIVE: R2Bucket }).ARCHIVE;
  const now = 1_790_035_200_000;
  const auth = new DurableAuth({ db, keys: f.keys, identityIndexSecret: f.identityIndexSecret,
    now: () => now, ownerRecovery: f.copy, requireOwnerRecovery: true });
  const session = await auth.establish({ issuer: 'https://appleid.apple.com',
    subject: crypto.randomUUID(), refreshToken: randomToken() });
  const archive = new ArchiveStore({ db, bucket, keys: f.keys, auth, now: () => now,
    membership: { status: async () => 'active' }, photos: { validateJPEG: async () => true },
    quotaBytes: 100_000, maximumRecords: 100,
    recovery: new RecordRecoveryCopy(f.keys, f.s3), ownerRecovery: f.copy,
    requireOwnerRecovery: true });
  const recordId = crypto.randomUUID();
  const request = { expectedRevision: null, consentVersion: 'managed-preservation-v1',
    document: { formatVersion: 1, text: 'ひざで寝た日', capturedAt: null,
      writtenAt: null, updatedAt: null, catNames: [], photoFile: null }, photoBase64: null };
  expect(await archive.put(session.token, recordId, request))
    .toEqual({ recordId, revision: 1 });
  const live = await f.copy.capture(db, session.ownerId);
  expect(live.records).toHaveLength(1);
  expect(live.records[0]).toMatchObject({ recordId, revision: 1, deleted: false });
  expect(await f.copy.copyCurrent(db, session.ownerId, now)).toMatchObject({ key: expect.any(String) });
  expect(await archive.remove(session.token, recordId, 1))
    .toEqual({ recordId, revision: 2 });
  const deleted = await f.copy.capture(db, session.ownerId);
  expect(deleted.generation).toBeGreaterThan(live.generation);
  expect(deleted.records).toHaveLength(1);
  expect(deleted.records[0]).toMatchObject({ recordId, revision: 2, deleted: true });
  expect(deleted.records[0]?.marker.key).not.toBe(live.records[0]?.marker.key);
  f.setPageSize(2);
  const candidate = await new OwnerArchiveRecovery(f.s3, f.copy,
    new RecordRecoveryCopy(f.keys, f.s3)).assembleQuarantineCandidate(session.ownerId, now + 1);
  expect(candidate.status).toBe('ready-for-quarantine');
  if (candidate.status !== 'ready-for-quarantine') throw new Error('expected candidate');
  expect(candidate.owner.disabled).toBe(true);
  expect(candidate.owner.records).toMatchObject([{ recordId, revision: 2, deleted: true }]);
  expect(candidate.verifiedRecords).toBe(1);
  f.omitFromListing(deleted.records[0]!.marker.key);
  expect(await new OwnerArchiveRecovery(f.s3, f.copy,
    new RecordRecoveryCopy(f.keys, f.s3)).assembleQuarantineCandidate(session.ownerId, now + 2))
    .toEqual({ status: 'quarantined' });
});

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
  const opened = await f.keys.open(f.objects.get(ref.key)!, { ownerId, purpose: 'recovery' });
  expect(JSON.parse(new TextDecoder().decode(opened))).toMatchObject({
    version: 2, inventoryGeneration: 0, records: [],
  });
  const raw = new TextDecoder().decode(f.objects.get(ref.key)!);
  expect(raw).not.toContain(original.identityKey);
  expect(raw).not.toContain(accountId);
});

it('reads legacy and compressed inventories with either write gate, without changing owner binding', async () => {
  const f = await fixture();
  const original = image();
  original.inventoryGeneration = 1000;
  original.records = Array.from({ length: 1000 }, (_, i) => ({
    recordId: crypto.randomUUID(),
    revision: 1, deleted: i % 3 === 0,
    marker: { key: `recovery/v1/${ownerId}/manifest/${crypto.randomUUID()}`,
      versionId: randomToken(), sha256: Array.from(crypto.getRandomValues(new Uint8Array(32)),
        byte => byte.toString(16).padStart(2, '0')).join(''), bytes: 400 },
  })).sort((left, right) => left.recordId.localeCompare(right.recordId));
  const compressedWriter = new OwnerRecoveryCopy(f.keys, f.s3, f.identityIndexSecret,
    { compressWrites: true });
  const legacyRef = await f.copy.copy(original);
  const compressedRef = await compressedWriter.copy(original);
  expect(compressedRef.bytes).toBeLessThan(legacyRef.bytes / 2);
  console.log('synthetic 1000-record encrypted snapshot bytes', {
    legacy: legacyRef.bytes, compressed: compressedRef.bytes,
    reductionPercent: Math.round((1 - compressedRef.bytes / legacyRef.bytes) * 100),
  });
  const opened = await f.keys.open(f.objects.get(compressedRef.key)!, { ownerId, purpose: 'recovery' });
  expect(new TextDecoder().decode(opened.subarray(0, 4))).toBe('NKZ1');
  for (const reader of [f.copy, compressedWriter]) {
    expect(await reader.read(ownerId, legacyRef)).toEqual(original);
    expect(await reader.read(ownerId, compressedRef)).toEqual(original);
    await expect(reader.read(otherOwnerId, compressedRef))
      .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  }
  // Relabelling an object and recomputing its storage hash cannot bypass AES owner binding.
  const relabelled = await f.s3.putVersioned(compressedRef.key.replace(ownerId, otherOwnerId),
    f.objects.get(compressedRef.key)!);
  await expect(f.copy.read(otherOwnerId, relabelled))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
});

it('quarantines a committed record absent from the owner-wide inventory', async () => {
  const f = await fixture();
  await f.copy.copy(await verifiedImage(f));
  const records = new RecordRecoveryCopy(f.keys, f.s3);
  const recordId = crypto.randomUUID();
  const metadata = new Uint8Array([78, 75, 77, 49, 1]);
  const copied = await records.copy({ ownerId, recordId, revision: 1,
    initialFingerprint: 'a'.repeat(64), initialOperation: crypto.randomUUID(),
    metadata, photoKey: null, photoBytes: 0, quotaBytes: metadata.length,
    deleted: false, photoCiphertext: null });
  await records.commit(ownerId, recordId, 1, copied);
  expect(await new OwnerArchiveRecovery(f.s3, f.copy, records)
    .assembleQuarantineCandidate(ownerId, 1_000)).toEqual({ status: 'quarantined' });
});

it('quarantines a live owner snapshot when a later delete intent has no commit', async () => {
  const f = await fixture();
  const records = new RecordRecoveryCopy(f.keys, f.s3);
  const recordId = crypto.randomUUID();
  const initialOperation = crypto.randomUUID();
  const metadata = new Uint8Array([78, 75, 77, 49, 1]);
  const base = { ownerId, recordId, initialFingerprint: 'a'.repeat(64), initialOperation,
    photoKey: null, photoBytes: 0, photoCiphertext: null };
  const live = await records.copy({ ...base, revision: 1, metadata,
    quotaBytes: metadata.length, deleted: false });
  const marker = await records.commit(ownerId, recordId, 1, live);
  const owner = await verifiedImage(f);
  await f.copy.copy({ ...owner, inventoryGeneration: 1,
    records: [{ recordId, revision: 1, deleted: false, marker }] });
  const tombstone = await records.copy({ ...base, revision: 2, metadata: null,
    quotaBytes: 0, deleted: true });
  await records.prepareDelete(ownerId, recordId, 1, tombstone);
  expect(await new OwnerArchiveRecovery(f.s3, f.copy, records)
    .assembleQuarantineCandidate(ownerId, 1_000)).toEqual({ status: 'quarantined' });
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
  const recordId = crypto.randomUUID();
  const markerKey = `recovery/v1/${session.ownerId}/manifest/${crypto.randomUUID()}`;
  await db.prepare('INSERT OR IGNORE INTO pa_inventory(owner_id) VALUES(?)').bind(session.ownerId).run();
  await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
    initial_operation,metadata,deleted) VALUES(?,?,1,?,?,NULL,1)`)
    .bind(session.ownerId, recordId, 'd'.repeat(64), crypto.randomUUID()).run();
  await db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,
    record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
    VALUES(?,?,1,?,'synthetic-v1',?,10,?)`)
    .bind(session.ownerId, recordId,
      `recovery/v1/${session.ownerId}/record/${crypto.randomUUID()}`, 'e'.repeat(64), now).run();
  await db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,
    marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
    VALUES(?,?,1,?,'synthetic-v1',?,10,?)`)
    .bind(session.ownerId, recordId, markerKey, 'f'.repeat(64), now).run();
  const withRecord = await f.copy.capture(db, session.ownerId);
  expect(withRecord.generation).toBe(second.generation + 1);
  expect(withRecord.inventoryGeneration).toBe(1);
  expect(withRecord.records).toEqual([{ recordId, revision: 1, deleted: true,
    marker: { key: markerKey, versionId: 'synthetic-v1', sha256: 'f'.repeat(64), bytes: 10 } }]);
  await f.copy.copyCurrent(db, session.ownerId, now + 2);
  await db.prepare('UPDATE pa_owners SET identity_key=? WHERE owner_id=?')
    .bind('c'.repeat(64), session.ownerId).run();
  await expect(f.copy.copyCurrent(db, session.ownerId, now + 3))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  await db.prepare('UPDATE pa_owners SET identity_key=? WHERE owner_id=?')
    .bind(first.identityKey, session.ownerId).run();
  await f.copy.copyCurrent(db, session.ownerId, now + 4);
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
