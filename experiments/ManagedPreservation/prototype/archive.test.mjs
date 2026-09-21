import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readdirSync, readFileSync, unlinkSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { OfflineArchive } from './archive.mjs';
import { OfflineIdentityVerifier } from './identity.mjs';
import { createSyntheticIdentity } from './synthetic-identity.mjs';

const synthetic = await createSyntheticIdentity();
const photoBytes = Buffer.from('synthetic-JPEG-byte-fixture-NOT-a-quality-test');
const initial = {
  recordId: 'cat-photo-1', photoBytes, note: '合成データ：初めてひざで眠った日',
  metadata: { capturedAt: '2023-03-02T14:00:00+09:00', recordedAt: '2026-09-22T00:00:00+09:00', catName: 'テスト猫' },
};
const code = (expected) => (error) => error.code === expected;
const collect = async (items) => { const result = []; for await (const item of items) result.push(item); return result; };

async function fixture(t) {
  const folder = mkdtempSync(join(tmpdir(), 'neko-offline-preservation-'));
  const databasePath = join(folder, 'synthetic.sqlite');
  let identity = new OfflineIdentityVerifier(synthetic);
  const keys = new Map([['synthetic-key-1', randomBytes(32)]]);
  let access = { entitlement: 'active', consentVersion: 'offline-explicit-v1' };
  const options = () => ({ databasePath, identity, keys, activeKeyId: 'synthetic-key-1', newSaveAccess: () => access });
  let archive = new OfflineArchive({ ...options(), initialize: true });
  t.after(() => {
    archive.close();
    // Only the exact mkdtemp directory this test owns, no recursive workspace cleanup.
    for (const name of readdirSync(folder)) unlinkSync(join(folder, name));
    rmdirSync(folder);
  });
  const session = await synthetic.login(identity, { sub: 'person-a' });
  return {
    get archive() { return archive; }, session, keys, databasePath,
    setAccess(value) { access = value; },
    otherSession: () => synthetic.login(identity, { sub: 'person-b' }),
    reopen() {
      archive.close();
      // Drop all prior device sessions; fresh verifier, same independent identity provider.
      identity = new OfflineIdentityVerifier(synthetic);
      archive = new OfflineArchive(options());
    },
    newDeviceSession: () => synthetic.login(identity, { sub: 'person-a' }),
    raw(operation) { const db = new DatabaseSync(databasePath); try { return operation(db); } finally { db.close(); } },
    missingDatabase() { return new OfflineArchive({ ...options(), databasePath: join(folder, 'absent.sqlite') }); },
  };
}

test('expired, no old session: reopen persisted archive, same identity recovers photo/note/date and exports', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  f.setAccess({ entitlement: 'expired', consentVersion: null });
  f.reopen();
  assert.throws(() => f.archive.list(f.session));
  const freshSession = await f.newDeviceSession();
  assert.deepEqual(f.archive.list(freshSession), [{ recordId: initial.recordId, revision: 1 }]);
  const record = await f.archive.read(freshSession, initial.recordId);
  assert.deepEqual(record.photoBytes, photoBytes);
  assert.equal(record.note, initial.note);
  assert.deepEqual(record.metadata, initial.metadata);
  const exported = await collect(f.archive.exportRecords(freshSession));
  assert.equal(exported.length, 1);
  assert.deepEqual(exported[0].photoBytes, photoBytes);
  assert.equal(exported[0].noteText.toString('utf8'), initial.note);
  assert.equal(exported[0].manifest.photoSHA256, record.photoSHA256);
  assert.equal(exported[0].manifest.capturedAt, initial.metadata.capturedAt);
  await assert.rejects(f.archive.preserve(freshSession, { ...initial, recordId: 'new-photo' }), code('NEW_SAVE_REQUIRES_MEMBERSHIP'));
  await f.archive.editNote(freshSession, { recordId: initial.recordId, expectedRevision: 1, note: '解約後に修正' });
  assert.equal((await f.archive.read(freshSession, initial.recordId)).note, '解約後に修正');
});

test('other identity cannot list, read, edit, delete or export personal records', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  const other = await f.otherSession();
  assert.deepEqual(f.archive.list(other), []);
  await assert.rejects(f.archive.read(other, initial.recordId), code('RECORD_NOT_FOUND'));
  await assert.rejects(f.archive.editNote(other, { recordId: initial.recordId, expectedRevision: 1, note: 'intruder' }), code('RECORD_NOT_FOUND'));
  assert.throws(() => f.archive.delete(other, { recordId: initial.recordId, expectedRevision: 1 }), code('RECORD_NOT_FOUND'));
  assert.deepEqual(await collect(f.archive.exportRecords(other)), []);
  assert.equal((await f.archive.read(f.session, initial.recordId)).note, initial.note);
});

test('missing and wrong encryption key fail closed; encrypted SQLite does not contain note or image plaintext', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  const file = readFileSync(f.databasePath);
  assert.equal(file.includes(Buffer.from(initial.note)), false);
  assert.equal(file.includes(photoBytes), false);
  const originalKey = f.keys.get('synthetic-key-1');
  f.keys.clear();
  await assert.rejects(f.archive.read(f.session, initial.recordId), code('ARCHIVE_KEY_UNAVAILABLE'));
  await assert.rejects(collect(f.archive.exportRecords(f.session)), code('ARCHIVE_KEY_UNAVAILABLE'));
  f.keys.set('synthetic-key-1', randomBytes(32));
  await assert.rejects(f.archive.read(f.session, initial.recordId), code('ARCHIVE_INTEGRITY_FAILED'));
  f.keys.set('synthetic-key-1', originalKey);
  assert.deepEqual((await f.archive.read(f.session, initial.recordId)).photoBytes, photoBytes);
});

test('ciphertext copied to another record cannot decrypt under a different record identity', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  await f.archive.preserve(f.session, { ...initial, recordId: 'photo-2' });
  f.raw((db) => db.exec("UPDATE archive_records SET ciphertext = (SELECT ciphertext FROM archive_records WHERE record_id = 'cat-photo-1') WHERE record_id = 'photo-2'"));
  await assert.rejects(f.archive.read(f.session, 'photo-2'), code('ARCHIVE_INTEGRITY_FAILED'));
  await assert.rejects(collect(f.archive.exportRecords(f.session)), code('ARCHIVE_INTEGRITY_FAILED'));
});

test('concurrent memo edits have one winner; delete tombstone rejects stale edit and resurrection', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  const results = await Promise.allSettled(['first', 'second'].map((note) => f.archive.editNote(f.session,
    { recordId: initial.recordId, expectedRevision: 1, note })));
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(results.find((r) => r.status === 'rejected').reason.code, 'REVISION_CONFLICT');
  f.setAccess({ entitlement: 'expired' });
  assert.deepEqual(f.archive.delete(f.session, { recordId: initial.recordId, expectedRevision: 2 }), { recordId: initial.recordId, revision: 3 });
  await assert.rejects(f.archive.read(f.session, initial.recordId), code('RECORD_NOT_FOUND'));
  await assert.rejects(f.archive.editNote(f.session, { recordId: initial.recordId, expectedRevision: 2, note: 'old device' }), code('RECORD_NOT_FOUND'));
  f.setAccess({ entitlement: 'active', consentVersion: 'offline-explicit-v1' });
  await assert.rejects(f.archive.preserve(f.session, initial), code('RECORD_ALREADY_EXISTS'));
  assert.deepEqual(f.archive.list(f.session), []);
});

test('no consent, unknown membership, or consent withdrawn during encryption never commits a record', async (t) => {
  const f = await fixture(t);
  f.setAccess({ entitlement: 'active' });
  await assert.rejects(f.archive.preserve(f.session, initial), code('PRESERVATION_CONSENT_REQUIRED'));
  f.setAccess({ entitlement: 'unknown', consentVersion: 'offline-explicit-v1' });
  await assert.rejects(f.archive.preserve(f.session, initial), code('ACCESS_UNCONFIRMED'));
  f.setAccess({ entitlement: 'active', consentVersion: 'offline-explicit-v1' });
  const pending = f.archive.preserve(f.session, initial);
  f.setAccess({ entitlement: 'active', consentVersion: null });
  await assert.rejects(pending, code('PRESERVATION_CONSENT_REQUIRED'));
  assert.deepEqual(f.archive.list(f.session), []);
});

test('database write failure rolls back the inserted row and can retry; missing database is not an empty recovery', async (t) => {
  const f = await fixture(t);
  f.raw((db) => db.exec("CREATE TRIGGER reject_insert AFTER INSERT ON archive_records BEGIN SELECT RAISE(ABORT, 'synthetic-write-failure'); END"));
  await assert.rejects(f.archive.preserve(f.session, initial), /synthetic-write-failure/);
  assert.deepEqual(f.archive.list(f.session), []);
  f.raw((db) => db.exec('DROP TRIGGER reject_insert'));
  await f.archive.preserve(f.session, initial);
  assert.equal(f.archive.list(f.session).length, 1);
  assert.throws(() => f.missingDatabase(), code('ARCHIVE_DATABASE_UNAVAILABLE'));
});

test('export traverses pages, one record at a time', async (t) => {
  const f = await fixture(t);
  for (let i = 0; i < 23; i += 1) await f.archive.preserve(f.session, { ...initial, recordId: `photo-${String(i).padStart(2, '0')}` });
  const exported = await collect(f.archive.exportRecords(f.session));
  assert.equal(exported.length, 23);
  assert.equal(new Set(exported.map((item) => item.manifest.recordId)).size, 23);
});

test('lost success response retries after expiry, without overwriting a later memo or resurrecting deletion', async (t) => {
  const f = await fixture(t);
  const concurrent = await Promise.all([f.archive.preserve(f.session, initial), f.archive.preserve(f.session, initial)]);
  assert.equal(concurrent.filter((r) => r.alreadyPreserved).length, 1);
  f.setAccess({ entitlement: 'expired', consentVersion: null });
  await f.archive.editNote(f.session, { recordId: initial.recordId, expectedRevision: 1, note: 'new memo' });
  assert.deepEqual(await f.archive.preserve(f.session, initial), { recordId: initial.recordId, revision: 2, alreadyPreserved: true });
  assert.equal((await f.archive.read(f.session, initial.recordId)).note, 'new memo');
  await assert.rejects(f.archive.preserve(f.session, { ...initial, photoBytes: Buffer.from('new-image') }), code('RECORD_ALREADY_EXISTS'));
  f.archive.delete(f.session, { recordId: initial.recordId, expectedRevision: 2 });
  await assert.rejects(f.archive.preserve(f.session, initial), code('RECORD_ALREADY_EXISTS'));
});

for (const mutation of ['insert-before-cursor', 'delete-not-yet-exported', 'edit']) {
  test(`export reports incomplete on concurrent ${mutation}`, async (t) => {
    const f = await fixture(t);
    await f.archive.preserve(f.session, initial);
    await f.archive.preserve(f.session, { ...initial, recordId: 'z-last' });
    const exporting = f.archive.exportRecords(f.session);
    assert.equal((await exporting.next()).done, false);
    if (mutation === 'insert-before-cursor') await f.archive.preserve(f.session, { ...initial, recordId: 'a-new' });
    if (mutation === 'delete-not-yet-exported') f.archive.delete(f.session, { recordId: 'z-last', expectedRevision: 1 });
    if (mutation === 'edit') await f.archive.editNote(f.session, { recordId: 'z-last', expectedRevision: 1, note: 'changed' });
    await assert.rejects(exporting.next(), code('EXPORT_CHANGED'));
  });
}

test('another owner changing their archive does not invalidate this export', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  const exporting = f.archive.exportRecords(f.session);
  await exporting.next();
  await f.archive.preserve(await f.otherSession(), initial);
  assert.equal((await exporting.next()).done, true);
});

test('export checks generation again after acquiring the final empty page', async (t) => {
  const f = await fixture(t);
  await f.archive.preserve(f.session, initial);
  const originalList = f.archive.list.bind(f.archive);
  // Deterministic seam for an external writer between generation read and page return.
  f.archive.list = (session, options) => {
    const page = originalList(session, options);
    if (options.after && !page.length) f.archive.delete(f.session, { recordId: initial.recordId, expectedRevision: 1 });
    return page;
  };
  const exporting = f.archive.exportRecords(f.session);
  await exporting.next();
  await assert.rejects(exporting.next(), code('EXPORT_CHANGED'));
});
