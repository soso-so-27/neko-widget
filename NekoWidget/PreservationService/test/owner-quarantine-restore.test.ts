import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { randomToken } from '../src/contracts';
import { identityIndexKey, indexedOwnerIdentity } from '../src/identity-index';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerArchiveRecovery } from '../src/owner-archive-recovery';
import { OwnerQuarantineRestore } from '../src/owner-quarantine-restore';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from '../src/owner-recovery-copy';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import { S3RecoveryCopy, type RecoveryObject } from '../src/s3-recovery-copy';
import type { PurgeIntentEvent, S3PurgeIntentStore } from '../src/s3-purge-intent';
import { syntheticKeyAuthority } from './key-fixture';

const ownerId = '00000000-0000-4000-8000-000000000001';

it('stages a verified owner and photo in empty D1/R2 while keeping access disabled', async () => {
  const authority = await syntheticKeyAuthority();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
  const secret = randomToken();
  const stored = new Map<string, Uint8Array>();
  const references: RecoveryObject[] = [];
  const omitted = new Set<string>();
  const s3 = {
    async putVersioned(key: string, bytes: Uint8Array): Promise<RecoveryObject> {
      const sha256 = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('');
      const reference = { key, versionId: 'synthetic-v1', sha256, bytes: bytes.length };
      stored.set(key, bytes.slice());
      references.push(reference);
      return reference;
    },
    async getVerified(reference: RecoveryObject): Promise<Uint8Array> {
      const bytes = stored.get(reference.key);
      if (!bytes || bytes.length !== reference.bytes || reference.versionId !== 'synthetic-v1') {
        throw new Error('missing object');
      }
      const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('');
      if (hash !== reference.sha256) throw new Error('corrupt object');
      return bytes.slice();
    },
    async listOwnerVersionsPage(requestedOwner: string) {
      return { versions: references.filter(ref => ref.key.startsWith(`recovery/v1/${requestedOwner}/`)
        && !omitted.has(ref.key)).map(ref => ({ key: ref.key, versionId: ref.versionId,
        deleteMarker: false, bytes: ref.bytes })), nextCursor: null };
    },
    async referenceForListedVersion(item: { key: string; versionId: string }) {
      const found = references.find(ref => ref.key === item.key && ref.versionId === item.versionId);
      if (!found) throw new Error('missing version');
      return found;
    },
  } as S3RecoveryCopy;
  const owners = new OwnerRecoveryCopy(keys, s3, secret);
  const records = new RecordRecoveryCopy(keys, s3);
  const recordId = crypto.randomUUID();
  const photoKey = `personal/${ownerId}/${recordId}/${crypto.randomUUID()}`;
  const metadata = new Uint8Array([78, 75, 77, 49, 1]);
  const photoCiphertext = new Uint8Array([78, 75, 77, 49, 2, 3]);
  const initialOperation = crypto.randomUUID();
  const base = { ownerId, recordId, initialFingerprint: 'a'.repeat(64), initialOperation };
  const firstCopy = await records.copy({ ...base, revision: 1,
    metadata, photoKey: null, photoBytes: 0, quotaBytes: metadata.length,
    deleted: false, photoCiphertext: null });
  await records.commit(ownerId, recordId, 1, firstCopy);
  const copied = await records.copy({ ...base, revision: 2,
    metadata, photoKey, photoBytes: 3, quotaBytes: metadata.length + photoCiphertext.length,
    deleted: false, photoCiphertext });
  const marker = await records.commit(ownerId, recordId, 2, copied);
  const issuer = 'https://appleid.apple.com';
  const subject = 'restore-test-subject';
  const credential = await keys.seal(new TextEncoder().encode(JSON.stringify({ issuer, subject,
    refreshToken: randomToken() })), { ownerId, purpose: 'identity' });
  const owner: OwnerRecoveryImage = { ownerId, generation: 1,
    identityKey: await indexedOwnerIdentity(await identityIndexKey(secret), issuer, subject),
    epoch: 0, disabled: false, purgeFenceId: null, createdAt: 100,
    credential: { ownerEpoch: 0, sealedCredentials: credential, updatedAt: 100 },
    contact: null, billing: null, retention: null, inventoryGeneration: 2,
    records: [{ recordId, revision: 2, deleted: false, marker }] };
  await owners.copy(owner);
  const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
  const purgeEvents: PurgeIntentEvent[] = [];
  const purgeIntents = {
    async listOwnerVersionsPage(requestedOwner: string) {
      return { versions: purgeEvents.filter(event => event.ownerId === requestedOwner)
        .map(event => ({ key: `purge/v1/${event.ownerId}/${event.intentId}/${event.stage}`,
          versionId: 'synthetic-v1', deleteMarker: false, bytes: 100 })), nextCursor: null };
    },
    async referenceForListedVersion(item: { key: string; versionId: string }) {
      return { ...item, sha256: 'a'.repeat(64), bytes: 100 };
    },
    async readExact(reference: { key: string }) {
      const found = purgeEvents.find(event =>
        `purge/v1/${event.ownerId}/${event.intentId}/${event.stage}` === reference.key);
      if (!found) throw new Error('missing purge event');
      return found;
    },
  } as S3PurgeIntentStore;
  const restore = new OwnerQuarantineRestore(
    new OwnerArchiveRecovery(s3, owners, records), records, binding.DB, binding.ARCHIVE,
    purgeIntents);
  omitted.add(marker.key);
  expect(await restore.restore(ownerId, 1_000)).toEqual({ status: 'quarantined' });
  expect(await binding.DB.prepare('SELECT count(*) AS count FROM pa_owners').first())
    .toMatchObject({ count: 0 });
  omitted.delete(marker.key);
  const purgeBase: PurgeIntentEvent = { version: 1, ownerId, intentId: crypto.randomUUID(),
    stage: 'prepared', ownerEpoch: 0, inventoryGeneration: 2,
    retentionEpisode: 1, retentionRevision: 1, dueAt: 900, recordedAt: 901,
    manifestSha256: null };
  purgeEvents.push(purgeBase);
  await expect(restore.restore(ownerId, 1_001))
    .rejects.toMatchObject({ code: 'OWNER_QUARANTINE_RESTORE_UNAVAILABLE' });
  purgeEvents.push({ ...purgeBase, stage: 'erasing', recordedAt: 902,
    manifestSha256: 'b'.repeat(64) },
  { ...purgeBase, stage: 'completed', recordedAt: 903,
    manifestSha256: 'b'.repeat(64) });
  await expect(restore.restore(ownerId, 1_001))
    .rejects.toMatchObject({ code: 'OWNER_QUARANTINE_RESTORE_UNAVAILABLE' });
  expect(await binding.ARCHIVE.head(photoKey)).toBeNull();
  purgeEvents.length = 0;
  expect(await restore.restore(ownerId, 1_001)).toEqual({ status: 'staged-disabled',
    ownerId, records: 1, photos: 1 });
  expect(await binding.DB.prepare('SELECT disabled,epoch FROM pa_owners WHERE owner_id=?')
    .bind(ownerId).first()).toMatchObject({ disabled: 1, epoch: 0 });
  expect(await binding.DB.prepare(`SELECT revision,deleted,photo_key FROM pa_records
    WHERE owner_id=? AND record_id=?`).bind(ownerId, recordId).first())
    .toMatchObject({ revision: 2, deleted: 0, photo_key: photoKey });
  expect(await binding.DB.prepare(`SELECT count(*) AS count FROM pa_record_recovery_versions
    WHERE owner_id=? AND record_id=?`).bind(ownerId, recordId).first())
    .toMatchObject({ count: 2 });
  expect(await binding.DB.prepare(`SELECT count(*) AS count FROM pa_record_commit_markers
    WHERE owner_id=? AND record_id=?`).bind(ownerId, recordId).first())
    .toMatchObject({ count: 2 });
  expect(new Uint8Array(await (await binding.ARCHIVE.get(photoKey))!.arrayBuffer()))
    .toEqual(photoCiphertext);
  expect(await binding.DB.prepare('SELECT count(*) AS count FROM pa_sessions').first())
    .toMatchObject({ count: 0 });
  await expect(restore.restore(ownerId, 1_002))
    .rejects.toMatchObject({ code: 'OWNER_QUARANTINE_RESTORE_UNAVAILABLE' });
});
