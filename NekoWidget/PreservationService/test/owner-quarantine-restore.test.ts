import { env } from 'cloudflare:workers';
import { beforeEach, expect, it } from 'vitest';
import { randomToken, sha256, type ArchiveDocument } from '../src/contracts';
import { identityIndexKey, indexedOwnerIdentity } from '../src/identity-index';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerArchiveRecovery } from '../src/owner-archive-recovery';
import { OwnerQuarantineRestore } from '../src/owner-quarantine-restore';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from '../src/owner-recovery-copy';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import { S3RecoveryCopy, type RecoveryObject } from '../src/s3-recovery-copy';
import type { PurgeIntentEvent, S3PurgeIntentStore } from '../src/s3-purge-intent';
import { syntheticKeyAuthority } from './key-fixture';
import { OwnerRequestLimiter } from '../src/owner-request-limiter';
import { ownerD1DeleteOrder } from '../src/owner-d1-residue';

const ownerId = '00000000-0000-4000-8000-000000000001';

beforeEach(async () => {
  // Each offline restore requires its own empty test target. The Worker pool
  // shares this file's D1/R2 bindings; previous staged targets are not retries.
  const { DB: db, ARCHIVE: bucket } = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
  await db.prepare(`UPDATE pa_recovery_write_policy SET delete_intent_required=0,
    owner_snapshot_required=0 WHERE singleton=1`).run();
  for (const table of ownerD1DeleteOrder) await db.prepare(`DELETE FROM ${table}`).run();
  const listed = await bucket.list({ prefix: `personal/${ownerId}/` });
  for (const object of listed.objects) await bucket.delete(object.key);
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owners').first()).toEqual({ n: 0 });
});

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
  const document = { formatVersion: 1, text: 'restored record', capturedAt: null,
    writtenAt: null, updatedAt: null, catNames: [], photoFile: 'photo.jpg' };
  const metadata = await keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1,
    ownerId, recordId, revision: 2, document, photoSHA256: 'a'.repeat(64), photoBytes: 3 })),
  { ownerId, purpose: 'record', recordId: `${recordId}/document` });
  const firstMetadata = await keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1,
    ownerId, recordId, revision: 1, document: { ...document, photoFile: null }, photoSHA256: null, photoBytes: 0 })),
  { ownerId, purpose: 'record', recordId: `${recordId}/document` });
  const photoCiphertext = new Uint8Array([78, 75, 77, 49, 2, 3]);
  const initialOperation = crypto.randomUUID();
  const base = { ownerId, recordId, initialFingerprint: 'a'.repeat(64), initialOperation };
  const firstCopy = await records.copy({ ...base, revision: 1,
    metadata: firstMetadata, photoKey: null, photoBytes: 0, quotaBytes: firstMetadata.length,
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
    purgeIntents, { async assertNotRequested() {} });
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
  await binding.DB.prepare(`INSERT INTO pa_auth_challenges(challenge_id,proof_hash,nonce,created_at,expires_at)
    VALUES(?,?,?,1,300001)`).bind(randomToken(), 'a'.repeat(64), randomToken()).run();
  expect(await restore.restore(ownerId, 1_001)).toEqual({ status: 'staged-disabled',
    ownerId, records: 1, photos: 1 });
  expect(await binding.DB.prepare(`SELECT disabled,epoch,http_request_minute,http_request_count,
    export_lease_id,export_lease_expires_at FROM pa_owners WHERE owner_id=?`)
    .bind(ownerId).first()).toEqual({ disabled: 1, epoch: 0, http_request_minute: 0, http_request_count: 0,
      export_lease_id: null, export_lease_expires_at: 0 });
  await expect(new OwnerRequestLimiter(binding.DB).admit({ ownerId, sessionHash: 'a'.repeat(64), expiresAt: Date.now() + 60_000 }))
    .rejects.toMatchObject({ code: 'RATE_LIMITED' });
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
  // Offline staging restores data, never device/session/trial authority.
  for (const table of ['pa_tool_owner_trials','pa_tool_trial_records','pa_tool_trial_resume_repairs',
    'pa_auth_challenges','pa_device_session_grants','pa_device_session_challenges','pa_device_identity_checks']) {
    expect(await binding.DB.prepare(`SELECT count(*) AS count FROM ${table}`).first()).toMatchObject({count:0});
  }
  await expect(binding.DB.prepare(`INSERT INTO pa_tool_owner_trials(owner_id,owner_epoch,enabled,starts_at,ends_at,
    reviewed_at,valid_until,cost_evidence_sha256,byte_limit,attempt_limit,record_limit)
    VALUES(?,0,1,1,2000,1,2000,?,20971520,400,200)`).bind(ownerId,'a'.repeat(64)).run()).rejects.toThrow();
  await expect(restore.restore(ownerId, 1_002))
    .rejects.toMatchObject({ code: 'OWNER_QUARANTINE_RESTORE_UNAVAILABLE' });
});

async function sharedToolRestoreFixture(change?: 'deleted-source' | 'missing' | 'path' | 'source' | 'hash' | 'bytes' | 'json-hash' | 'manifest' | 'photo-name' | 'head') {
  const authority = await syntheticKeyAuthority();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
  const secret = randomToken(), stored = new Map<string, Uint8Array>(), references: RecoveryObject[] = [];
  const s3 = {
    async putVersioned(key: string, body: Uint8Array) {
      const reference = { key, versionId: 'synthetic-v1', bytes: body.length, sha256: await sha256(body) };
      stored.set(key, body.slice()); references.push(reference); return reference;
    },
    async getVerified(reference: RecoveryObject) {
      const body = stored.get(reference.key);
      if (!body || reference.versionId !== 'synthetic-v1' || body.length !== reference.bytes
        || await sha256(body) !== reference.sha256) throw Error('bad fixture object');
      return body.slice();
    },
    async listOwnerVersionsPage(requested: string) {
      return { versions: references.filter(ref => ref.key.startsWith(`recovery/v1/${requested}/`))
        .map(ref => ({ key: ref.key, versionId: ref.versionId, bytes: ref.bytes, deleteMarker: false })), nextCursor: null };
    },
    async referenceForListedVersion(item: { key: string; versionId: string }) {
      const ref = references.find(ref => ref.key === item.key && ref.versionId === item.versionId);
      if (!ref) throw Error('missing fixture version'); return ref;
    },
  } as S3RecoveryCopy;
  const records = new RecordRecoveryCopy(keys, s3), owners = new OwnerRecoveryCopy(keys, s3, secret);
  const original = crypto.randomUUID(), newer = crypto.randomUUID(), photoId = crypto.randomUUID();
  const photoPath = `CareHandoff/${crypto.randomUUID()}.jpg`, photo = new Uint8Array([1, 2, 3]);
  const photoHash = await sha256(photo), json = new TextEncoder().encode('{"cats":[]}'), jsonHash = await sha256(json);
  const jsonIds = [crypto.randomUUID(), crypto.randomUUID()];
  const ownerRecords: OwnerRecoveryImage['records'] = [];
  async function publish(id: string, snapshotId: string, kind: 'json' | 'photo' | 'index', path: string, content: Uint8Array) {
    const toolBackup = { snapshotId, kind, path, part: 0, count: 1, sha256: await sha256(content),
      payload: kind === 'photo' ? '' : btoa(String.fromCharCode(...content)) };
    const document: ArchiveDocument = { formatVersion: 3, text: '', capturedAt: null, writtenAt: null,
      updatedAt: null, catNames: [], photoFile: kind === 'photo' ? 'photo.jpg' : null, toolBackup };
    const photoCiphertext = kind === 'photo' ? await keys.seal(content,
      { ownerId, purpose: 'record', recordId: `${id}/photo` }) : null;
    const metadata = await keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1, ownerId,
      recordId: id, revision: 1, document, photoSHA256: kind === 'photo' ? toolBackup.sha256 : null,
      photoBytes: kind === 'photo' ? content.length : 0 })),
    { ownerId, purpose: 'record', recordId: `${id}/document` });
    const base = { ownerId, recordId: id, revision: 1, initialFingerprint: 'a'.repeat(64),
      initialOperation: crypto.randomUUID(), metadata,
      photoKey: photoCiphertext ? `personal/${ownerId}/${id}/${crypto.randomUUID()}` : null,
      photoBytes: kind === 'photo' ? content.length : 0, photoCiphertext,
      quotaBytes: metadata.length + (photoCiphertext?.length ?? 0), deleted: false };
    const copy = await records.copy(base), marker = await records.commit(ownerId, id, 1, copy);
    ownerRecords.push({ recordId: id, revision: 1, deleted: false, marker });
    return base;
  }
  await publish(photoId, original, 'photo', photoPath, photo);
  for (const [at, snapshot] of [original, newer].entries()) {
    await publish(jsonIds[at]!, snapshot, 'json', 'CareHandoff/plan.json', json);
  }
  const jsonFile = (id: string) => ({ path: 'CareHandoff/plan.json', bytes: json.length, sha256: jsonHash, records: [id] });
  const photoFile = { path: photoPath, bytes: photo.length, sha256: photoHash, records: [photoId] };
  const originalIndex = await publish(original, original, 'index', 'index.json', new TextEncoder().encode(JSON.stringify({
    version: change === 'head' ? 3 : 1, snapshotID: original, createdAt: 1, files: [jsonFile(jsonIds[0]!), photoFile] }))) ;
  const reused = { ...photoFile, records: [...photoFile.records], sourceSnapshotID: original };
  if (change === 'missing') reused.records = [crypto.randomUUID()];
  if (change === 'path') reused.path = `CareHandoff/${crypto.randomUUID()}.jpg`;
  if (change === 'source') reused.sourceSnapshotID = crypto.randomUUID();
  if (change === 'hash') reused.sha256 = 'b'.repeat(64);
  if (change === 'bytes') reused.bytes++;
  if (change === 'photo-name') reused.path = 'CareHandoff/not-a-uuid.jpg';
  const newerJson = jsonFile(jsonIds[1]!);
  if (change === 'json-hash') newerJson.sha256 = 'c'.repeat(64);
  if (change === 'manifest') newerJson.path = 'CareHandoff/other.json';
  const newerIndex = { version: change === 'head' ? 3 : 2, snapshotID: newer, createdAt: 2,
    files: [change === 'head' ? { ...jsonFile(jsonIds[0]!), sourceSnapshotID: original } : newerJson, reused] };
  await publish(newer, newer, 'index', 'index.json', new TextEncoder().encode(JSON.stringify(newerIndex)));
  const headID = crypto.randomUUID();
  if (change === 'head') {
    const operation = crypto.randomUUID();
    for (let revision = 1; revision <= 2; revision++) {
      const snapshotID = revision === 1 ? original : newer;
      const index = revision === 1 ? { version: 3, snapshotID: original, createdAt: 1, files: [jsonFile(jsonIds[0]!), photoFile] } : newerIndex;
      const document: ArchiveDocument = { formatVersion: 1, text: JSON.stringify({ kind: 'app-records-v1', snapshotID,
        indexHash: await sha256(JSON.stringify(index)) }), capturedAt: null, writtenAt: null, updatedAt: null, catNames: [], photoFile: null };
      const metadata = await keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1, ownerId, recordId: headID,
        revision, document, photoSHA256: null, photoBytes: 0 })), { ownerId, purpose: 'record', recordId: `${headID}/document` });
      const copied = await records.copy({ ownerId, recordId: headID, revision, initialFingerprint: 'd'.repeat(64),
        initialOperation: operation, metadata, photoKey: null, photoBytes: 0, quotaBytes: metadata.length, deleted: false, photoCiphertext: null });
      const marker = await records.commit(ownerId, headID, revision, copied);
      if (revision === 2) ownerRecords.push({ recordId: headID, revision, deleted: false, marker });
    }
  }
  if (change === 'deleted-source' || change === 'head') {
    const tombstone = await records.copy({ ...originalIndex, revision: 2, deleted: true,
      metadata: null, photoKey: null, photoBytes: 0, photoCiphertext: null, quotaBytes: 0 });
    await records.prepareDelete(ownerId, original, 1, tombstone);
    const marker = await records.commit(ownerId, original, 2, tombstone);
    const prior = ownerRecords.find(record => record.recordId === original)!;
    Object.assign(prior, { revision: 2, deleted: true, marker });
  }
  const issuer = 'https://appleid.apple.com', subject = 'shared-tool-restore';
  const credential = await keys.seal(new TextEncoder().encode(JSON.stringify({ issuer, subject, refreshToken: randomToken() })),
    { ownerId, purpose: 'identity' });
  await owners.copy({ ownerId, generation: 1, epoch: 0, disabled: false, purgeFenceId: null, createdAt: 100,
    identityKey: await indexedOwnerIdentity(await identityIndexKey(secret), issuer, subject),
    credential: { ownerEpoch: 0, sealedCredentials: credential, updatedAt: 100 }, contact: null,
    billing: null, retention: null, inventoryGeneration: ownerRecords.length + 1,
    records: ownerRecords.sort((a, b) => a.recordId.localeCompare(b.recordId)) });
  const { DB: db, ARCHIVE: bucket } = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
  const purge = { async listOwnerVersionsPage() { return { versions: [], nextCursor: null }; } } as unknown as S3PurgeIntentStore;
  return { restore: new OwnerQuarantineRestore(new OwnerArchiveRecovery(s3, owners, records), records,
    db, bucket, purge, { async assertNotRequested() {} }), db, bucket, original, newer, photoId, jsonIds,
    references, objectCount: references.length, headID };
}

it.each([undefined, 'deleted-source'] as const)('rebuilds v2 photo edges without duplicating the photo or requiring its original index (%s)', async change => {
  const f = await sharedToolRestoreFixture(change);
  expect(await f.restore.restore(ownerId, 1_000)).toEqual({ status: 'staged-disabled', ownerId, records: 5, photos: 1 });
  const edges = (await f.db.prepare(`SELECT snapshot_id,part_id FROM pa_tool_snapshot_references
    WHERE owner_id=? ORDER BY part_id`).bind(ownerId).all<{ snapshot_id: string; part_id: string }>()).results;
  expect(edges).toEqual([f.photoId, f.jsonIds[1]!].sort().map(id => ({ snapshot_id: f.newer, part_id: id })));
  expect(await f.db.prepare('SELECT count(*) AS n FROM pa_tool_part_delete_claims').first()).toEqual({ n: 0 });
  expect(await f.db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(ownerId).first()).toEqual({ disabled: 1 });
  expect(f.references).toHaveLength(f.objectCount);
  if (change) expect(await f.db.prepare('SELECT deleted FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(ownerId, f.original).first()).toEqual({ deleted: 1 });
});

it.each(['missing', 'path', 'source', 'hash', 'bytes', 'json-hash', 'manifest', 'photo-name'] as const)(
  'refuses staged success for an incomplete or inconsistent shared tool graph (%s)', async change => {
    const f = await sharedToolRestoreFixture(change);
    await expect(f.restore.restore(ownerId, 1_000)).rejects.toMatchObject({ code:
      ['manifest', 'photo-name'].includes(change) ? 'INVALID_RECORD' : 'OWNER_QUARANTINE_RESTORE_UNAVAILABLE' });
    expect(await f.db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(ownerId).first()).toEqual({ disabled: 1 });
    expect(await f.db.prepare('SELECT count(*) AS n FROM pa_sessions').first()).toEqual({ n: 0 });
    expect(f.references).toHaveLength(f.objectCount);
  });


it('restores a mutable automatic head and v3 JSON references before publishing disabled staged success', async () => {
  const f = await sharedToolRestoreFixture('head');
  expect(await f.restore.restore(ownerId, 1_000)).toEqual({ status: 'staged-disabled', ownerId, records: 6, photos: 1 });
  expect(await f.db.prepare('SELECT part_id,source_revision FROM pa_tool_snapshot_references WHERE owner_id=? AND snapshot_id=?')
    .bind(ownerId, f.headID).first()).toEqual({ part_id: f.newer, source_revision: 2 });
  expect(await f.db.prepare('SELECT count(*) AS n FROM pa_tool_snapshot_references WHERE owner_id=?').bind(ownerId).first()).toEqual({ n: 3 });
  expect(await f.db.prepare('SELECT deleted FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(ownerId, f.original).first()).toEqual({ deleted: 1 });
  await expect(f.db.prepare('UPDATE pa_records SET deleted=1 WHERE owner_id=? AND record_id=?')
    .bind(ownerId, f.newer).run()).rejects.toThrow();
  await expect(f.db.prepare(`INSERT INTO pa_tool_snapshot_references(owner_id,snapshot_id,part_id,source_revision)
    VALUES(?,?,?,2)`).bind(ownerId, f.headID, f.original).run()).rejects.toThrow();
  expect(await f.db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(ownerId).first()).toEqual({ disabled: 1 });
});
