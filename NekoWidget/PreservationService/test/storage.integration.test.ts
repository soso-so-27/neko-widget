import { env } from 'cloudflare:workers';
import type { D1Migration } from 'cloudflare:test';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore, cleanupArchive } from '../src/storage';
import { encodePhoto } from '../src/documents';
import { randomToken, ServiceError, type ArchiveDocument, type KeyCustody } from '../src/contracts';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import type { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { type RecoveryObject, S3RecoveryCopy } from '../src/s3-recovery-copy';
import worker, { route, type Services, type Env } from '../src/index';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const photo = new Uint8Array([255, 216, 255, 217]); // Synthetic, injected validator; not a real JPEG test.
const document: ArchiveDocument = { formatVersion: 1, text: 'ひざで寝た日', capturedAt: '2023-03-02T05:00:00.000Z',
  writtenAt: null, updatedAt: null, catNames: ['むぎ', 'そら'], photoFile: 'photo.jpg' };

async function fixture(overrides: { quotaBytes?: number; maximumRecords?: number } = {}) {
  await binding.DB.prepare(`UPDATE pa_recovery_write_policy SET delete_intent_required=0
    WHERE singleton=1`).run();
  let now = 1_790_035_200_000;
  let state: 'active' | 'expired' | 'unknown' | 'grace' = 'active';
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const keys: KeyCustody = {
    async seal(value, context) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value as BufferSource);
      const output = new Uint8Array(12 + cipher.byteLength); output.set(iv); output.set(new Uint8Array(cipher), 12); return output;
    },
    async open(value, context) {
      return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: value.slice(0, 12),
        additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value.slice(12)));
    },
  };
  const authOptions = { db: binding.DB, keys, identityIndexSecret: randomToken(), now: () => now };
  const auth = new DurableAuth(authOptions);
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() };
  const session = await auth.establish(identity);
  const options = { db: binding.DB, bucket: binding.ARCHIVE, keys, auth, now: () => now,
    membership: { status: async () => state }, photos: { validateJPEG: async () => true },
    quotaBytes: overrides.quotaBytes ?? 100_000, maximumRecords: overrides.maximumRecords ?? 100 };
  const archive = new ArchiveStore(options);
  const request = (patch: Record<string, unknown> = {}) => ({ expectedRevision: null, consentVersion: 'managed-preservation-v1',
    document, photoBase64: encodePhoto(photo), ...patch });
  return { auth, authOptions, identity, session, archive, options, request,
    setState(value: typeof state) { state = value; }, setNow(value: number) { now = value; } };
}

function syntheticRecovery(keys: KeyCustody) {
  const objects = new Map<string, Uint8Array>();
  const references: RecoveryObject[] = [];
  let rejectWrites = false;
  let rejectKind: 'photo' | 'record' | 'manifest' | null = null;
  let manifestWritesBeforeFailure: number | null = null;
  const s3 = {
    async putVersioned(key: string, value: Uint8Array): Promise<RecoveryObject> {
      if (rejectWrites || (rejectKind && key.includes(`/${rejectKind}/`))) throw new Error('S3 unavailable');
      if (key.includes('/manifest/') && manifestWritesBeforeFailure !== null) {
        if (manifestWritesBeforeFailure === 0) throw new Error('S3 manifest unavailable');
        manifestWritesBeforeFailure -= 1;
      }
      const sha256 = [...new Uint8Array(await crypto.subtle.digest('SHA-256', value as BufferSource))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('');
      const versionId = 'synthetic-version';
      objects.set(`${key}:${versionId}`, value.slice());
      const reference = { key, sha256, bytes: value.length, versionId };
      references.push(reference);
      return reference;
    },
    async getVerified(item: RecoveryObject): Promise<Uint8Array> {
      const value = objects.get(`${item.key}:${item.versionId}`);
      if (!value) throw new Error('copy unavailable');
      const sha256 = [...new Uint8Array(await crypto.subtle.digest('SHA-256', value as BufferSource))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('');
      if (sha256 !== item.sha256 || value.length !== item.bytes) throw new Error('copy corrupt');
      return value.slice();
    },
  } as S3RecoveryCopy;
  return { recovery: new RecordRecoveryCopy(keys, s3), objects, references,
    rejectWrites(value: boolean) { rejectWrites = value; },
    rejectKind(value: typeof rejectKind) { rejectKind = value; },
    failManifestAfter(value: number | null) { manifestWritesBeforeFailure = value; } };
}

async function enableRecoveryWritePolicy() {
  await binding.DB.prepare(`UPDATE pa_recovery_write_policy SET delete_intent_required=1
    WHERE singleton=1`).run();
}

it('ties each acknowledged D1 revision to an exact recovery version and fails closed on S3 outage', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery });
  const id = crypto.randomUUID();
  remote.rejectWrites(true);
  await expect(archive.put(f.session.token, id, f.request()))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  expect(await binding.DB.prepare('SELECT record_id FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId, id).first()).toBeNull();
  remote.rejectWrites(false);
  expect(await archive.put(f.session.token, id, f.request())).toEqual({ recordId: id, revision: 1 });
  remote.rejectWrites(true);
  await expect(archive.put(f.session.token, id, f.request({ expectedRevision: 1,
    document: { ...document, text: '未保存の編集' } })))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  await expect(archive.remove(f.session.token, id, 1))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  expect((await archive.read(f.session.token, id)).revision).toBe(1);
  remote.rejectWrites(false);
  expect(await archive.put(f.session.token, id, f.request({ expectedRevision: 1,
    document: { ...document, text: '編集後' } }))).toEqual({ recordId: id, revision: 2 });
  expect(await archive.remove(f.session.token, id, 2)).toEqual({ recordId: id, revision: 3 });
  const rows = await binding.DB.prepare(`SELECT revision,record_object_key,record_version_id,
    record_sha256,record_bytes,photo_object_key,photo_version_id,photo_sha256,photo_bytes
    FROM pa_record_recovery_versions WHERE owner_id=? AND record_id=? ORDER BY revision`)
    .bind(f.session.ownerId, id).all<{ revision: number; record_object_key: string;
      record_version_id: string; record_sha256: string; record_bytes: number;
      photo_object_key: string | null; photo_version_id: string | null;
      photo_sha256: string | null; photo_bytes: number | null }>();
  expect(rows.results.map(row => row.revision)).toEqual([1, 2, 3]);
  expect(rows.results[1]?.photo_object_key).toBe(rows.results[0]?.photo_object_key);
  expect(rows.results[1]?.photo_version_id).toBe(rows.results[0]?.photo_version_id);
  expect(remote.references.filter(ref => ref.key.includes('/photo/'))).toHaveLength(1);
  expect(rows.results[2]?.photo_object_key).toBeNull();
  const revisionTwo = rows.results[1]!;
  const restored = await remote.recovery.read(f.session.ownerId, id, {
    record: { key: revisionTwo.record_object_key, versionId: revisionTwo.record_version_id,
      sha256: revisionTwo.record_sha256, bytes: revisionTwo.record_bytes },
    photo: { key: revisionTwo.photo_object_key!, versionId: revisionTwo.photo_version_id!,
      sha256: revisionTwo.photo_sha256!, bytes: revisionTwo.photo_bytes! },
  });
  expect(restored.revision).toBe(2);
  expect(restored.deleted).toBe(false);
  expect(restored.photoCiphertext?.length).toBeGreaterThan(0);
});

it('acknowledges a record only after its owner-wide inventory copy succeeds', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  const id = crypto.randomUUID();
  const seen: number[] = [];
  let ownerCopyAvailable = false;
  const ownerRecovery = { async copyCurrent(db: D1Database, ownerId: string) {
    const row = await db.prepare(`SELECT COUNT(*) AS count FROM pa_record_commit_markers
      WHERE owner_id=?`).bind(ownerId).first<{ count: number }>();
    seen.push(row!.count);
    if (row!.count > 0 && !ownerCopyAvailable) {
      throw new ServiceError('OWNER_RECOVERY_UNAVAILABLE', 503);
    }
  } } as unknown as OwnerRecoveryCopy;
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery,
    ownerRecovery, requireOwnerRecovery: true });
  await expect(archive.put(f.session.token, id, f.request()))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  expect(seen).toContain(1);
  ownerCopyAvailable = true;
  expect(await archive.put(f.session.token, id, f.request()))
    .toEqual({ recordId: id, revision: 1 });
  expect(seen.at(-1)).toBe(1);
  expect(await archive.remove(f.session.token, id, 1)).toEqual({ recordId: id, revision: 2 });
  expect(seen.at(-1)).toBe(2);
});

it('only the winning concurrent edit can attach a recovery version to the next revision', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery });
  const id = crypto.randomUUID(); await archive.put(f.session.token, id, f.request());
  const results = await Promise.allSettled(['A', 'B'].map(text => archive.put(f.session.token, id,
    f.request({ expectedRevision: 1, document: { ...document, text } }))));
  expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1);
  const failure = results.find(result => result.status === 'rejected');
  expect(failure).toMatchObject({ reason: { code: 'REVISION_CONFLICT' } });
  const references = await binding.DB.prepare(`SELECT revision FROM pa_record_recovery_versions
    WHERE owner_id=? AND record_id=? ORDER BY revision`).bind(f.session.ownerId, id)
    .all<{ revision: number }>();
  expect(references.results.map(row => row.revision)).toEqual([1, 2]);
});

it('missing recovery configuration blocks mutations but keeps existing records readable', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const remote = syntheticRecovery(f.options.keys);
  await enableRecoveryWritePolicy();
  await new ArchiveStore({ ...f.options, recovery: remote.recovery, requireRecovery: true })
    .put(f.session.token, id, f.request());
  const readOnly = new ArchiveStore({ ...f.options, requireRecovery: true });
  expect((await readOnly.read(f.session.token, id)).recordId).toBe(id);
  expect((await readOnly.list(f.session.token)).items.some(item => item.recordId === id)).toBe(true);
  await expect(readOnly.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  await expect(readOnly.remove(f.session.token, id, 1))
    .rejects.toMatchObject({ code: 'RECOVERY_COPY_UNAVAILABLE' });
  expect((await readOnly.read(f.session.token, id)).revision).toBe(1);
});

it('only migration-pinned legacy revisions stay readable and are copied before the first edit', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  const remote = syntheticRecovery(f.options.keys);
  const guarded = new ArchiveStore({ ...f.options, recovery: remote.recovery, requireRecovery: true });
  await expect(guarded.read(f.session.token, id)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  await expect(guarded.usage(f.session.token)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  await binding.DB.prepare(`INSERT INTO pa_record_legacy_baseline(owner_id,record_id,revision,
    initial_operation,initial_fingerprint,photo_key,photo_bytes,quota_bytes,deleted)
    SELECT owner_id,record_id,revision,initial_operation,initial_fingerprint,
      photo_key,photo_bytes,quota_bytes,deleted
    FROM pa_records WHERE owner_id=? AND record_id=?`).bind(f.session.ownerId, id).run();
  expect((await guarded.read(f.session.token, id)).revision).toBe(1);
  expect((await guarded.usage(f.session.token)).records.saved).toBe(1);
  await expect(enableRecoveryWritePolicy()).rejects.toThrow(/RECOVERY_COVERAGE_INCOMPLETE/u);
  const preparing = new ArchiveStore({ ...f.options, recovery: remote.recovery });
  expect(await preparing.put(f.session.token, id, f.request({ expectedRevision: 1,
    document: { ...document, text: '移行後の編集' } }))).toEqual({ recordId: id, revision: 2 });
  await enableRecoveryWritePolicy();
  const refs = await binding.DB.prepare(`SELECT revision FROM pa_record_commit_markers
    WHERE owner_id=? AND record_id=? ORDER BY revision`).bind(f.session.ownerId, id)
    .all<{ revision: number }>();
  expect(refs.results.map(row => row.revision)).toEqual([1, 2]);
  expect((await guarded.read(f.session.token, id)).document.text).toBe('移行後の編集');
});

it('repairs all legacy owners in bounded batches without one damaged photo starving later rows', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  const ids = [crypto.randomUUID(), crypto.randomUUID()].sort();
  for (const id of ids) await f.archive.put(f.session.token, id, f.request());
  await binding.DB.prepare(`INSERT INTO pa_record_legacy_baseline(owner_id,record_id,revision,
    initial_operation,initial_fingerprint,photo_key,photo_bytes,quota_bytes,deleted)
    SELECT owner_id,record_id,revision,initial_operation,initial_fingerprint,
      photo_key,photo_bytes,quota_bytes,deleted FROM pa_records WHERE owner_id=?`)
    .bind(f.session.ownerId).run();
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery });
  const before = await archive.recoveryLedgerCoverage();
  expect(before.legacyUnbacked).toBe(2);
  const first = await binding.DB.prepare(`SELECT photo_key FROM pa_records
    WHERE owner_id=? AND record_id=?`).bind(f.session.ownerId, ids[0])
    .first<{ photo_key: string }>();
  const ciphertext = new Uint8Array(await (await binding.ARCHIVE.get(first!.photo_key))!.arrayBuffer());
  await binding.ARCHIVE.delete(first!.photo_key);
  expect(await archive.repairRecoveryBatch(2)).toEqual({ processed: 2, failed: 1 });
  expect(await archive.recoveryLedgerCoverage()).toMatchObject({
    confirmed: before.confirmed + 1, legacyUnbacked: 1 });
  expect(await binding.DB.prepare(`SELECT attempts FROM pa_recovery_repair_failures
    WHERE owner_id=? AND record_id=?`).bind(f.session.ownerId, ids[0]).first())
    .toMatchObject({ attempts: 1 });
  await binding.ARCHIVE.put(first!.photo_key, ciphertext);
  expect(await archive.repairRecoveryBatch(2)).toEqual({ processed: 1, failed: 0 });
  expect(await archive.recoveryLedgerCoverage()).toMatchObject({
    confirmed: before.confirmed + 2, legacyUnbacked: 0 });
});

it('does not create a new record recovery version for a fenced owner during maintenance', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  await binding.DB.prepare(`INSERT INTO pa_record_legacy_baseline(owner_id,record_id,revision,
    initial_operation,initial_fingerprint,photo_key,photo_bytes,quota_bytes,deleted)
    SELECT owner_id,record_id,revision,initial_operation,initial_fingerprint,
      photo_key,photo_bytes,quota_bytes,deleted FROM pa_records
    WHERE owner_id=? AND record_id=?`).bind(f.session.ownerId, id).run();
  const fenceId = crypto.randomUUID();
  const at = 1_790_035_200_000;
  await binding.DB.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
    delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',1,1,1,1,?,?,?,?,?,?,?)`)
    .bind(fenceId, f.session.ownerId, at - 1, at - 31 * 86_400_000,
      `delivery-${crypto.randomUUID()}`, at - 32 * 86_400_000,
      at, at, at + 600_000).run();
  await binding.DB.prepare(`UPDATE pa_owners SET disabled=1,epoch=epoch+1,
    purge_fence_id=? WHERE owner_id=?`).bind(fenceId, f.session.ownerId).run();
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery });
  expect(await archive.repairRecoveryBatch(2)).toEqual({ processed: 0, failed: 0 });
  expect(remote.references).toHaveLength(0);
  // Leave this shared-file fixture eligible for later write-policy tests.
  await binding.DB.prepare(`UPDATE pa_owners SET disabled=0,epoch=epoch+1,
    purge_fence_id=NULL WHERE owner_id=?`).bind(f.session.ownerId).run();
  await binding.DB.prepare(`UPDATE pa_purge_fences SET state='aborted'
    WHERE fence_id=?`).bind(fenceId).run();
  expect(await archive.repairRecoveryBatch(2)).toEqual({ processed: 1, failed: 0 });
});

it('does not acknowledge a D1 commit until the independent S3 marker exists; retries finish it', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  await enableRecoveryWritePolicy();
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery, requireRecovery: true });
  const id = crypto.randomUUID();
  remote.rejectKind('manifest');
  await expect(archive.put(f.session.token, id, f.request()))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  expect(await binding.DB.prepare('SELECT revision FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId, id).first<{ revision: number }>()).toMatchObject({ revision: 1 });
  await expect(archive.read(f.session.token, id)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  await expect(archive.list(f.session.token)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  await expect(archive.usage(f.session.token)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  remote.rejectKind(null);
  expect(await archive.put(f.session.token, id, f.request())).toEqual({ recordId: id, revision: 1 });
  expect((await archive.read(f.session.token, id)).revision).toBe(1);
  remote.rejectKind('manifest');
  const edit = f.request({ expectedRevision: 1, document: { ...document, text: '記録の編集' } });
  await expect(archive.put(f.session.token, id, edit))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  await expect(archive.read(f.session.token, id)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  remote.rejectKind(null);
  expect(await archive.put(f.session.token, id, edit)).toEqual({ recordId: id, revision: 2 });
  expect((await archive.read(f.session.token, id)).document.text).toBe('記録の編集');
  const markers = await binding.DB.prepare(`SELECT revision FROM pa_record_commit_markers
    WHERE owner_id=? AND record_id=? ORDER BY revision`).bind(f.session.ownerId, id)
    .all<{ revision: number }>();
  expect(markers.results.map(row => row.revision)).toEqual([1, 2]);
});

it('keeps a deleted photo quarantined if its post-D1 S3 commit marker fails', async () => {
  const f = await fixture(); const remote = syntheticRecovery(f.options.keys);
  await enableRecoveryWritePolicy();
  const archive = new ArchiveStore({ ...f.options, recovery: remote.recovery, requireRecovery: true });
  const id = crypto.randomUUID();
  await archive.put(f.session.token, id, f.request());
  remote.failManifestAfter(1); // durable delete intent succeeds; post-D1 commit fails.
  await expect(archive.remove(f.session.token, id, 1))
    .rejects.toMatchObject({ code: 'RECOVERY_RECORD_UNAVAILABLE' });
  expect(await binding.DB.prepare('SELECT revision,deleted FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId, id).first()).toMatchObject({ revision: 2, deleted: 1 });
  const manifests = remote.references.filter(ref => ref.key.includes('/manifest/'));
  expect(await remote.recovery.selectRecoveredRecord(f.session.ownerId, id, manifests))
    .toEqual({ status: 'quarantined' });
  await expect(archive.usage(f.session.token)).rejects.toMatchObject({ code: 'RECOVERY_PENDING' });
  remote.failManifestAfter(null);
  expect(await archive.remove(f.session.token, id, 1)).toEqual({ recordId: id, revision: 2 });
  expect(await remote.recovery.selectRecoveredRecord(f.session.ownerId, id,
    remote.references.filter(ref => ref.key.includes('/manifest/'))))
    .toMatchObject({ status: 'ready', image: { revision: 2, deleted: true } });
});

it('real D1/R2 round trip survives new auth/store instances and expires membership without losing access', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  f.setState('expired');
  const auth = new DurableAuth(f.authOptions); const session = await auth.establish(f.identity);
  const archive = new ArchiveStore({ ...f.options, auth });
  const restored = await archive.read(session.token, id);
  expect(restored.document).toEqual(document); expect(restored.photoBase64).toBe(encodePhoto(photo));
  const row = await binding.DB.prepare('SELECT metadata FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(session.ownerId, id).first<{ metadata: number[] }>();
  expect(new TextDecoder().decode(new Uint8Array(row!.metadata))).not.toContain('ひざ');
  await expect(archive.put(session.token, crypto.randomUUID(), f.request())).rejects.toMatchObject({ code: 'NEW_SAVE_REQUIRES_MEMBERSHIP' });
  await archive.put(session.token, id, f.request({ expectedRevision: 1, consentVersion: null,
    document: { ...document, text: '解約後に編集' } }));
  expect((await archive.read(session.token, id)).document.text).toBe('解約後に編集');
  await archive.remove(session.token, id, 2);
  await expect(archive.read(session.token, id)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
  expect(await archive.remove(session.token, id, 2)).toEqual({ recordId: id, revision: 3 });
  await expect(archive.put(session.token, id, f.request())).rejects.toMatchObject({ code: 'RECORD_DELETED' });
});

it('another verified Apple identity cannot read, edit or delete another owner records', async () => {
  const f = await fixture(); const id = crypto.randomUUID(); await f.archive.put(f.session.token, id, f.request());
  const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
  expect((await f.archive.list(other.token)).items).toEqual([]);
  await expect(f.archive.read(other.token, id)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
  await expect(f.archive.put(other.token, id, f.request({ expectedRevision: 1 }))).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await expect(f.archive.remove(other.token, id, 1)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
});

it('photo-only first memo remains editable after expiry; text-only exports no invented photo', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request({ document: { ...document, text: '' } }));
  const textOnly = crypto.randomUUID();
  await f.archive.put(f.session.token, textOnly, f.request({ document: { ...document, photoFile: null }, photoBase64: null }));
  f.setState('unknown');
  await f.archive.put(f.session.token, id, f.request({ expectedRevision: 1 }));
  expect((await f.archive.read(f.session.token, id)).document.text).toBe(document.text);
  expect((await f.archive.read(f.session.token, textOnly)).photoBase64).toBeNull();
});

it('lost create reply retry after later edit preserves the newer memo', async () => {
  const f = await fixture(); const id = crypto.randomUUID(); await f.archive.put(f.session.token, id, f.request());
  await f.archive.put(f.session.token, id, f.request({ expectedRevision: 1, document: { ...document, text: '新しいメモ' } }));
  f.setState('expired');
  expect(await f.archive.put(f.session.token, id, f.request())).toEqual({ recordId: id, revision: 2 });
  expect((await f.archive.read(f.session.token, id)).document.text).toBe('新しいメモ');
});

it('parallel revision edits have one winner; photo replacement cannot bypass new-save membership', async () => {
  const f = await fixture(); const id = crypto.randomUUID(); await f.archive.put(f.session.token, id, f.request());
  const results = await Promise.allSettled(['a', 'b'].map((text) => f.archive.put(f.session.token, id,
    f.request({ expectedRevision: 1, document: { ...document, text } }))));
  expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
  await expect(f.archive.put(f.session.token, id, f.request({ expectedRevision: 2, photoBase64: encodePhoto(new Uint8Array([1, 2, 3])) })))
    .rejects.toMatchObject({ code: 'PHOTO_REPLACEMENT_REQUIRES_NEW_RECORD' });
});

it('consent, grace, unknown entitlement and capacity boundaries are distinct', async () => {
  const f = await fixture({ maximumRecords: 1 });
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request({ consentVersion: null })))
    .rejects.toMatchObject({ code: 'PRESERVATION_CONSENT_REQUIRED' });
  f.setState('unknown');
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request())).rejects.toMatchObject({ code: 'ACCESS_UNCONFIRMED' });
  f.setState('grace'); await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request())).rejects.toMatchObject({ code: 'ARCHIVE_CAPACITY_REACHED' });
  const small = await fixture({ quotaBytes: 1 });
  await expect(small.archive.put(small.session.token, crypto.randomUUID(), small.request())).rejects.toMatchObject({ code: 'ARCHIVE_CAPACITY_REACHED' });
});

it('concurrent reservations cannot exceed the owner record limit', async () => {
  const f = await fixture({ maximumRecords: 1 });
  const results = await Promise.allSettled([crypto.randomUUID(), crypto.randomUUID()]
    .map((id) => f.archive.put(f.session.token, id, f.request())));
  expect(results.filter((value) => value.status === 'fulfilled')).toHaveLength(1);
  expect((await f.archive.list(f.session.token)).items).toHaveLength(1);
});

it('cleanup advances beyond its first page and one failed object does not block the rest', async () => {
  const prefix = crypto.randomUUID(); const now = Date.now();
  const keys = Array.from({ length: 23 }, (_, index) => `${prefix}/${String(index).padStart(2, '0')}`);
  for (const key of keys) {
    await binding.ARCHIVE.put(key, 'encrypted');
    await binding.DB.prepare('INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)').bind(key, now).run();
  }
  const bucket = new Proxy(binding.ARCHIVE, { get(target, property) {
    if (property === 'delete') return async (key: string) => {
      if (key === keys[0]) throw new Error('injected storage outage');
      return target.delete(key);
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  await expect(cleanupArchive({ db: binding.DB, bucket, now: () => now }, 20))
    .rejects.toMatchObject({ code: 'CLEANUP_INCOMPLETE' });
  await cleanupArchive({ db: binding.DB, bucket, now: () => now }, 20);
  expect(await binding.ARCHIVE.get(keys[22]!)).toBeNull();
  expect(await binding.ARCHIVE.get(keys[0]!)).not.toBeNull();
  await cleanupArchive({ db: binding.DB, bucket: binding.ARCHIVE, now: () => now + 3_600_001 }, 100);
  expect(await binding.ARCHIVE.get(keys[0]!)).toBeNull();
});

it('maintenance works while Apple, membership and public requests are disabled', async () => {
  const key = crypto.randomUUID(); await binding.ARCHIVE.put(key, 'encrypted');
  await binding.DB.prepare('INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)').bind(key, Date.now()).run();
  await worker.scheduled({} as ScheduledEvent, { ...binding, CLEANUP_ENABLED: 'YES' });
  expect(await binding.ARCHIVE.get(key)).toBeNull();
});

it('required owner snapshots cannot silently skip scheduled repair when S3 is unavailable', async () => {
  const pending = await binding.DB.prepare(`SELECT g.owner_id,g.generation
    FROM pa_owner_recovery_generations g LEFT JOIN pa_owner_recovery_versions v
      ON v.owner_id=g.owner_id AND v.generation=g.generation WHERE v.owner_id IS NULL`)
    .all<{ owner_id: string; generation: number }>();
  const inserted: string[] = [];
  try {
    for (const row of pending.results) {
      const key = `recovery/v1/${row.owner_id}/owner/${crypto.randomUUID()}`;
      await binding.DB.prepare(`INSERT INTO pa_owner_recovery_versions
        (owner_id,generation,object_key,version_id,sha256,bytes,confirmed_at)
        VALUES(?,?,?,'synthetic-v1',?,1,1)`)
        .bind(row.owner_id, row.generation, key, 'a'.repeat(64)).run();
      inserted.push(key);
    }
    await binding.DB.prepare(`UPDATE pa_recovery_write_policy
      SET owner_snapshot_required=1 WHERE singleton=1`).run();
    await expect(worker.scheduled({} as ScheduledEvent, { ...binding, CLEANUP_ENABLED: 'NO' }))
      .rejects.toMatchObject({ code: 'PRESERVATION_UNAVAILABLE' });
  } finally {
    await binding.DB.prepare(`UPDATE pa_recovery_write_policy
      SET owner_snapshot_required=0 WHERE singleton=1`).run();
    for (const key of inserted) {
      await binding.DB.prepare('DELETE FROM pa_owner_recovery_versions WHERE object_key=?').bind(key).run();
    }
  }
});

it('session revoked during R2 upload cannot commit and leaves no live record/reservation', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const bucket = new Proxy(binding.ARCHIVE, { get(target, property) {
    if (property === 'put') return async (...args: Parameters<R2Bucket['put']>) => {
      const result = await target.put(...args); await f.auth.revokeSession(f.session.token); return result;
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const archive = new ArchiveStore({ ...f.options, bucket });
  await expect(archive.put(f.session.token, id, f.request())).rejects.toMatchObject({ status: 401 });
  const row = await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, id).first();
  expect(row).toBeNull();
  expect(await binding.DB.prepare('SELECT 1 FROM pa_uploads WHERE owner_id=?').bind(f.session.ownerId).first()).toBeNull();
});

it('invalid JPEG cannot become a saved record and missing/corrupt object is not a successful recovery', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const strict = new ArchiveStore({ ...f.options, photos: { validateJPEG: async () => false } });
  await expect(strict.put(f.session.token, id, f.request())).rejects.toMatchObject({ code: 'INVALID_JPEG' });
  await f.archive.put(f.session.token, id, f.request());
  const row = await binding.DB.prepare('SELECT photo_key FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId, id).first<{ photo_key: string }>();
  await binding.ARCHIVE.delete(row!.photo_key);
  await expect(f.archive.read(f.session.token, id)).rejects.toMatchObject({ code: 'ARCHIVE_PHOTO_UNAVAILABLE' });
});

it('listing is paged and carries a mutation generation without downloading images', async () => {
  const f = await fixture();
  for (let i = 0; i < 3; i++) await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  const first = await f.archive.list(f.session.token, '', 2);
  expect(first.items).toHaveLength(2); expect(first.nextCursor).not.toBeNull();
  const last = await f.archive.list(f.session.token, first.nextCursor!, 2);
  expect(last.items).toHaveLength(1); expect(last.nextCursor).toBeNull(); expect(last.generation).toBe(first.generation);
  expect(JSON.stringify(first)).not.toContain('photoBase64');
});

it('HTTP stays disabled until both the environment gate and recovery policy are active', async () => {
  const request = new Request('https://preservation.test/v1/records', { headers: { 'CF-Connecting-IP': '192.0.2.1' } });
  const closed = await worker.fetch(request, binding as Env);
  expect(closed.status).toBe(503); expect(closed.headers.get('cache-control')).toBe('no-store');
  expect(await closed.json()).toEqual({ error: { code: 'PRESERVATION_DISABLED' } });
  const missing = await worker.fetch(request, { ...binding, PRESERVATION_ENABLED: 'YES',
    REQUEST_LIMITER: { limit: async () => ({ success: true }) } });
  expect(await missing.json()).toEqual({ error: { code: 'RECOVERY_POLICY_INACTIVE' } });
});

it('HTTP record endpoints use bearer identity and fixed document fields, never caller-supplied owner', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const services: Services = { auth: f.auth, archive: f.archive, verifier: { verifyNativeAuthorization: async () => f.identity } };
  const url = `https://preservation.test/v1/records/${id}`;
  const headers = { authorization: `Bearer ${f.session.token}`, 'content-type': 'application/json' };
  const put = await route(new Request(url, { method: 'PUT', headers, body: JSON.stringify(f.request()) }), services);
  expect(put.status).toBe(200); expect(await put.json()).toEqual({ recordId: id, revision: 1 });
  await expect(route(new Request(url, { method: 'PUT', headers, body: JSON.stringify(f.request({ ownerId: 'other' })) }), services))
    .rejects.toMatchObject({ code: 'INVALID_RECORD' });
  const get = await route(new Request(url, { headers }), services);
  expect((await get.json() as { document: ArchiveDocument }).document).toEqual(document);
});

it('usage starts empty without creating inventory and never queries membership, keys or photos', async () => {
  const f = await fixture();
  const unavailable = async (): Promise<never> => { throw new Error('must not be called'); };
  const archive = new ArchiveStore({ ...f.options, membership: { status: unavailable },
    keys: { seal: unavailable, open: unavailable }, photos: { validateJPEG: unavailable } });
  expect(await archive.usage(f.session.token)).toEqual({ version: 1, accounting: 'encrypted-records-v1',
    storage: { usedBytes: 0, reservedBytes: 0, limitBytes: 100_000, availableBytes: 100_000, overLimit: false },
    records: { saved: 0, pending: 0, creationLimitReached: false } });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_inventory WHERE owner_id=?').bind(f.session.ownerId).first()).toBeNull();
});

it('deleted IDs prevent replay without consuming a new active record slot', async () => {
  const f = await fixture({ maximumRecords: 1 }); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  const saved = await f.archive.usage(f.session.token);
  expect(saved.records).toEqual({ saved: 1, pending: 0, creationLimitReached: true });
  expect(saved.storage.usedBytes).toBeGreaterThan(photo.length);
  expect(saved.storage.availableBytes).toBe(100_000 - saved.storage.usedBytes);
  f.setState('expired');
  await f.archive.put(f.session.token, id, f.request({ expectedRevision: 1,
    document: { ...document, text: document.text.repeat(10) } }));
  expect((await f.archive.usage(f.session.token)).storage.usedBytes).toBeGreaterThan(saved.storage.usedBytes);
  await f.archive.remove(f.session.token, id, 2);
  const removed = await f.archive.usage(f.session.token);
  expect(removed.storage.usedBytes).toBe(0); expect(removed.storage.availableBytes).toBe(100_000);
  expect(removed.records).toEqual({ saved: 0, pending: 0, creationLimitReached: false });
  // Pending physical erasure is not customer quota, nor a seven-day undo period.
  expect(await binding.DB.prepare('SELECT 1 FROM pa_pending_deletes').first()).not.toBeNull();
  f.setState('active');
  const replacement = crypto.randomUUID();
  await f.archive.put(f.session.token, replacement, f.request());
  expect((await f.archive.usage(f.session.token)).records)
    .toEqual({ saved: 1, pending: 0, creationLimitReached: true });
  await expect(f.archive.put(f.session.token, id, f.request()))
    .rejects.toMatchObject({ code: 'RECORD_DELETED' });
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'ARCHIVE_CAPACITY_REACHED' });
  await f.archive.remove(f.session.token, replacement, 1);
  const concurrent = await Promise.allSettled([crypto.randomUUID(), crypto.randomUUID()]
    .map(nextId => f.archive.put(f.session.token, nextId, f.request())));
  expect(concurrent.filter(result => result.status === 'fulfilled')).toHaveLength(1);
  expect(concurrent.filter(result => result.status === 'rejected'))
    .toMatchObject([{ reason: { code: 'ARCHIVE_CAPACITY_REACHED' } }]);
});

it('pauses only new intake before decoding and preserves retry/read/edit/delete', async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  let admissions = 0; let decodes = 0;
  const paused = new ArchiveStore({ ...f.options, requireIntakeControl: true,
    intakeControl: { async admit() { admissions++; throw new ServiceError('PRESERVATION_INTAKE_PAUSED', 503); } },
    photos: { async validateJPEG() { decodes++; return true; } } });
  await expect(paused.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'PRESERVATION_INTAKE_PAUSED', status: 503 });
  expect(decodes).toBe(0);
  expect(await paused.put(f.session.token, id, f.request())).toEqual({ recordId: id, revision: 1 });
  expect((await paused.read(f.session.token, id)).document.text).toBe(document.text);
  expect((await paused.usage(f.session.token)).records.saved).toBe(1);
  await paused.put(f.session.token, id, f.request({ expectedRevision: 1,
    document: { ...document, text: '新規停止中も既存メモは残す' } }));
  await paused.remove(f.session.token, id, 2);
  expect(admissions).toBe(1);
  const missing = new ArchiveStore({ ...f.options, requireIntakeControl: true });
  await expect(missing.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'PRESERVATION_INTAKE_PAUSED' });
});

it('reserves new intake before recovery, key use or malformed photo/document parsing', async () => {
  const f = await fixture();
  let work = 0; const unavailable = async (): Promise<never> => { work++; throw new Error('must not run'); };
  const amounts: number[] = [];
  const archive = new ArchiveStore({ ...f.options, requireIntakeControl: true, requireOwnerRecovery: true,
    ownerRecovery: { copyCurrent: unavailable } as unknown as OwnerRecoveryCopy,
    keys: { seal: unavailable, open: unavailable }, photos: { validateJPEG: unavailable },
    intakeControl: { async admit(amount) {
      amounts.push(amount); throw new ServiceError('PRESERVATION_INTAKE_PAUSED', 503);
    } } });
  for (const input of [f.request(), f.request({ document: null }),
    f.request({ photoBase64: '!'.repeat(1_000_000) }), f.request({ expectedRevision: 1 }), null]) {
    await expect(archive.put(f.session.token, crypto.randomUUID(), input))
      .rejects.toMatchObject({ code: 'PRESERVATION_INTAKE_PAUSED' });
  }
  expect(work).toBe(0); expect(amounts).toHaveLength(5);
  expect(amounts[2]).toBe(750_000 + 512 * 1024 + 8192);
  f.setState('expired');
  await expect(archive.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'NEW_SAVE_REQUIRES_MEMBERSHIP' });
  expect(amounts).toHaveLength(5);
});

it('pilot mutation stop covers edit and retry without stopping existing read/list/delete', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  let attempts = 0;
  const archive = new ArchiveStore({ ...f.options, mutationAdmission: {
    async admitMutation(ownerId) {
      expect(ownerId).toBe(f.session.ownerId); attempts++;
      throw new ServiceError('PILOT_WRITES_PAUSED', 503);
    },
  } });
  for (const request of [f.request(), f.request({ expectedRevision: 1 }), f.request({ document: null })]) {
    await expect(archive.put(f.session.token, id, request)).rejects.toMatchObject({ code: 'PILOT_WRITES_PAUSED' });
  }
  expect(attempts).toBe(3);
  expect((await archive.read(f.session.token, id)).document).toEqual(document);
  expect((await archive.list(f.session.token)).items).toHaveLength(1);
  await archive.remove(f.session.token, id, 1);
  expect(attempts).toBe(3);
});

it('usage accounts for an in-flight upload exactly once before and after its atomic commit', async () => {
  const f = await fixture({ maximumRecords: 1 });
  let release!: () => void; let entered!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const waiting = new Promise<void>(resolve => { entered = resolve; });
  const bucket = new Proxy(binding.ARCHIVE, { get(target, property) {
    if (property === 'put') return async (...args: Parameters<R2Bucket['put']>) => {
      entered(); await gate; return target.put(...args);
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const archive = new ArchiveStore({ ...f.options, bucket });
  const upload = archive.put(f.session.token, crypto.randomUUID(), f.request());
  let reserved = 0;
  try {
    await waiting;
    const during = await archive.usage(f.session.token);
    reserved = during.storage.reservedBytes;
    expect(reserved).toBeGreaterThan(0); expect(during.storage.usedBytes).toBe(0);
    expect(during.records).toEqual({ saved: 0, pending: 1, creationLimitReached: true });
    expect(during.storage.availableBytes).toBe(100_000 - reserved);
  } finally { release(); await upload; }
  const after = await archive.usage(f.session.token);
  expect(after.storage.usedBytes).toBe(reserved); expect(after.storage.reservedBytes).toBe(0);
  expect(after.records).toEqual({ saved: 1, pending: 0, creationLimitReached: true });
});

it('expired reservations remain allocated until cleanup releases them, not merely until the clock passes', async () => {
  const f = await fixture(); const now = 1_790_035_200_000;
  await binding.DB.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(f.session.ownerId).run();
  await binding.DB.prepare(`INSERT INTO pa_uploads(operation_id,owner_id,record_id,object_key,reserved_bytes,expires_at)
    VALUES(?,?,?,?,?,?)`).bind(crypto.randomUUID(), f.session.ownerId, crypto.randomUUID(), crypto.randomUUID(), 500, now - 1).run();
  expect((await f.archive.usage(f.session.token)).storage.reservedBytes).toBe(500);
  await f.archive.cleanup();
  expect((await f.archive.usage(f.session.token)).storage.reservedBytes).toBe(0);
  expect((await f.archive.usage(f.session.token)).records.pending).toBe(0);
});

it('concurrent byte reservations cannot overbook while a lower quota never deletes or locks existing records', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  const size = (await f.archive.usage(f.session.token)).storage.usedBytes;
  const bounded = new ArchiveStore({ ...f.options, quotaBytes: size * 2 });
  const attempts = await Promise.allSettled([crypto.randomUUID(), crypto.randomUUID()]
    .map(newId => bounded.put(f.session.token, newId, f.request())));
  expect(attempts.filter(value => value.status === 'fulfilled')).toHaveLength(1);
  expect(attempts.filter(value => value.status === 'rejected')).toMatchObject([
    { reason: { code: 'ARCHIVE_CAPACITY_REACHED' } }]);
  expect((await bounded.usage(f.session.token)).storage).toEqual({ usedBytes: size * 2,
    reservedBytes: 0, limitBytes: size * 2, availableBytes: 0, overLimit: false });
  const reduced = new ArchiveStore({ ...f.options, quotaBytes: 1 });
  f.setState('expired');
  expect((await reduced.usage(f.session.token)).storage).toMatchObject({ availableBytes: 0, overLimit: true });
  expect((await reduced.read(f.session.token, id)).document).toEqual(document);
  await reduced.put(f.session.token, id, f.request({ expectedRevision: 1, document: { ...document, text: '期限後も編集' } }));
  expect((await reduced.list(f.session.token)).items).toHaveLength(2);
});

it('atomically bounds new storage across owners without blocking existing records', async () => {
  const baseline = (await binding.DB.prepare(`SELECT coalesce(sum(used_bytes+reserved_bytes),0) AS bytes
    FROM pa_inventory`).first<{ bytes: number }>())!.bytes;
  const f = await fixture();
  const firstId = crypto.randomUUID();
  await f.archive.put(f.session.token, firstId, f.request());
  const bytes = (await f.archive.usage(f.session.token)).storage.usedBytes;
  const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
  const bounded = new ArchiveStore({ ...f.options, globalActiveBytesLimit: baseline + bytes * 2 });
  const attempts = await Promise.allSettled([
    bounded.put(f.session.token, crypto.randomUUID(), f.request()),
    bounded.put(other.token, crypto.randomUUID(), f.request()),
  ]);
  expect(attempts.filter(value => value.status === 'fulfilled'),
    JSON.stringify(attempts.map(value => value.status === 'rejected'
      ? { status: value.status, reason: String(value.reason), code: value.reason?.code } : value)))
    .toHaveLength(1);
  expect(attempts.filter(value => value.status === 'rejected'))
    .toMatchObject([{ reason: { code: 'ARCHIVE_CAPACITY_REACHED' } }]);
  const total = await binding.DB.prepare('SELECT sum(used_bytes+reserved_bytes) AS bytes FROM pa_inventory')
    .first<{ bytes: number }>();
  expect(total?.bytes).toBe(baseline + bytes * 2);
  const closed = new ArchiveStore({ ...f.options, globalActiveBytesLimit: 1 });
  expect((await closed.read(f.session.token, firstId)).recordId).toBe(firstId);
  expect((await closed.list(f.session.token)).items.length).toBeGreaterThan(0);
  await expect(closed.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'ARCHIVE_CAPACITY_REACHED' });
  const unconfigured = new ArchiveStore({ ...f.options, requireGlobalAdmissionLimit: true });
  await expect(unconfigured.put(f.session.token, crypto.randomUUID(), f.request()))
    .rejects.toMatchObject({ code: 'PRESERVATION_NOT_CONFIGURED' });
  expect((await unconfigured.read(f.session.token, firstId)).recordId).toBe(firstId);
  await unconfigured.put(f.session.token, firstId, f.request({ expectedRevision: 1,
    document: { ...document, text: '保存済みのメモを編集' } }));
  expect((await unconfigured.read(f.session.token, firstId)).revision).toBe(2);
  expect(() => new ArchiveStore({ ...f.options, globalActiveBytesLimit: Number.NaN }))
    .toThrowError(expect.objectContaining({ code: 'PRESERVATION_NOT_CONFIGURED' }));
});

it('usage rejects inconsistent inventory instead of reporting an empty or inflated archive', async () => {
  const f = await fixture(); await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  await binding.DB.prepare('UPDATE pa_inventory SET used_bytes=used_bytes+1 WHERE owner_id=?').bind(f.session.ownerId).run();
  await expect(f.archive.usage(f.session.token)).rejects.toMatchObject({ code: 'ARCHIVE_ACCOUNTING_UNAVAILABLE' });
  await binding.DB.prepare('DELETE FROM pa_inventory WHERE owner_id=?').bind(f.session.ownerId).run();
  await expect(f.archive.usage(f.session.token)).rejects.toMatchObject({ code: 'ARCHIVE_ACCOUNTING_UNAVAILABLE' });
  expect((await f.archive.list(f.session.token)).items).toHaveLength(1);
});

it('usage rechecks session revocation after its snapshot and refuses expired or disabled owners', async () => {
  const f = await fixture(); let reads = 0;
  const archive = new ArchiveStore({ ...f.options, auth: { requireSession: async token => {
    if (++reads === 2) await f.auth.revokeSession(token);
    return f.auth.requireSession(token);
  } } });
  await expect(archive.usage(f.session.token)).rejects.toMatchObject({ status: 401 });
  const second = await f.auth.establish(f.identity);
  await f.auth.revokeOwner(second.ownerId);
  await expect(f.archive.usage(second.token)).rejects.toMatchObject({ status: 401 });
  const expired = await fixture(); expired.setNow(1_790_035_200_000 + 15 * 60_000);
  await expect(expired.archive.usage(expired.session.token)).rejects.toMatchObject({ status: 401 });
});

it('HTTP usage is owner-isolated, read-only, no-store, and accepts neither owner selectors nor anonymous requests', async () => {
  const f = await fixture(); await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
  const services: Services = { auth: f.auth, archive: f.archive, verifier: { verifyNativeAuthorization: async () => f.identity } };
  const url = 'https://preservation.test/v1/usage';
  const headers = { authorization: `Bearer ${other.token}` };
  const result = await route(new Request(url, { headers }), services);
  expect(result.status).toBe(200); expect(result.headers.get('cache-control')).toBe('no-store');
  const data = await result.json() as { records: { saved: number }; storage: { usedBytes: number } };
  expect(data.records.saved).toBe(0); expect(data.storage.usedBytes).toBe(0);
  expect(JSON.stringify(data)).not.toContain(f.session.ownerId);
  await expect(route(new Request(`${url}?ownerId=${f.session.ownerId}`, { headers }), services))
    .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  await expect(route(new Request(url), services)).rejects.toMatchObject({ status: 401 });
  await expect(route(new Request(url, { headers, method: 'POST' }), services)).rejects.toMatchObject({ status: 404 });
  expect((await worker.fetch(new Request(url, { headers }), binding as Env)).status).toBe(503);
});

it('the additive owner index preserves populated accounting and avoids scanning other owners uploads', async () => {
  const f = await fixture(); await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  await binding.DB.prepare(`INSERT INTO pa_uploads(operation_id,owner_id,record_id,object_key,reserved_bytes,expires_at)
    VALUES(?,?,?,?,?,?)`).bind(crypto.randomUUID(), f.session.ownerId, crypto.randomUUID(), crypto.randomUUID(), 500, 1_790_035_200_001).run();
  const before = await f.archive.usage(f.session.token);
  // Local isolated test DB only: reproduce the populated pre-0004 schema, then
  // run the actual migration SQL. Never edit a previously-applied migration.
  await binding.DB.prepare('DROP INDEX pa_upload_owner_bytes').run();
  const migration = (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS
    .find(item => item.name === '0004_upload_owner_index.sql');
  expect(migration).toBeDefined();
  await binding.DB.batch(migration!.queries.map(query => binding.DB.prepare(query)));
  expect(await f.archive.usage(f.session.token)).toEqual(before);
  for (const expression of ['count(*)', 'coalesce(sum(reserved_bytes),0)']) {
    const plan = await binding.DB.prepare(`EXPLAIN QUERY PLAN SELECT ${expression} FROM pa_uploads u WHERE u.owner_id=?`)
      .bind(f.session.ownerId).all<{ detail: string }>();
    expect(plan.results.some(row => row.detail.includes('SEARCH u USING COVERING INDEX pa_upload_owner_bytes'))).toBe(true);
    expect(plan.results.some(row => row.detail.includes('SCAN u'))).toBe(false);
  }
});
