import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const directory = fileURLToPath(new URL('../migrations/', import.meta.url));
const files = readdirSync(directory).filter(name => /^\d{4}_.*\.sql$/u.test(name)).sort();
const db = new DatabaseSync(':memory:');
for (const name of files.filter(name => name < '0013_')) db.exec(readFileSync(join(directory, name), 'utf8'));
const ownerId = crypto.randomUUID();
const recordId = crypto.randomUUID();
const legacyRecordId = crypto.randomUUID();
const metadata = Buffer.from([78, 75, 77, 49, 1, 2]);
db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
  .run(ownerId, `synthetic:${ownerId}`, 1);
db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').run(ownerId);
db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
  initial_operation,metadata,photo_key,photo_bytes,quota_bytes)
  VALUES(?,?,1,?,?,?,NULL,0,?)`)
  .run(ownerId, recordId, 'a'.repeat(64), crypto.randomUUID(), metadata, metadata.length);
db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
  initial_operation,metadata,photo_key,photo_bytes,quota_bytes)
  VALUES(?,?,1,?,?,?,NULL,0,?)`)
  .run(ownerId, legacyRecordId, 'a'.repeat(64), crypto.randomUUID(), metadata, metadata.length);
const before = db.prepare(`SELECT o.owner_id,o.epoch,o.disabled,i.generation,i.used_bytes,
  r.record_id,r.revision,hex(r.metadata) AS metadata,r.deleted
  FROM pa_owners o JOIN pa_inventory i ON i.owner_id=o.owner_id
  JOIN pa_records r ON r.owner_id=o.owner_id WHERE o.owner_id=?`).get(ownerId);
const migration = files.find(name => name.startsWith('0013_'));
assert.ok(migration, '0013 migration is required');
db.exec(readFileSync(join(directory, migration), 'utf8'));
const after = db.prepare(`SELECT o.owner_id,o.epoch,o.disabled,i.generation,i.used_bytes,
  r.record_id,r.revision,hex(r.metadata) AS metadata,r.deleted
  FROM pa_owners o JOIN pa_inventory i ON i.owner_id=o.owner_id
  JOIN pa_records r ON r.owner_id=o.owner_id WHERE o.owner_id=?`).get(ownerId);
assert.deepEqual(after, before);
assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pa_record_recovery_versions').get().count, 0);
db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,
  record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
  VALUES(?,?,?,?,?,?,?,?)`).run(ownerId, recordId, 1,
  `recovery/v1/${ownerId}/record/${crypto.randomUUID()}`, 'v1', 'b'.repeat(64), 42, 2);
assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pa_record_recovery_versions').get().count, 1);
const markerMigration = files.find(name => name.startsWith('0014_'));
assert.ok(markerMigration, '0014 migration is required');
db.exec(readFileSync(join(directory, markerMigration), 'utf8'));
assert.deepEqual(db.prepare(`SELECT o.owner_id,o.epoch,o.disabled,i.generation,i.used_bytes,
  r.record_id,r.revision,hex(r.metadata) AS metadata,r.deleted
  FROM pa_owners o JOIN pa_inventory i ON i.owner_id=o.owner_id
  JOIN pa_records r ON r.owner_id=o.owner_id WHERE o.owner_id=?`).get(ownerId), before);
assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pa_record_commit_markers').get().count, 0);
assert.deepEqual(db.prepare(`SELECT record_id,revision
  FROM pa_record_legacy_baseline`).all().map(row => ({ ...row })),
  [{ record_id: legacyRecordId, revision: 1 }]);
db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,
  marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
  VALUES(?,?,?,?,?,?,?,?)`).run(ownerId, recordId, 1,
  `recovery/v1/${ownerId}/manifest/${crypto.randomUUID()}`, 'v2', 'c'.repeat(64), 60, 3);
assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pa_record_commit_markers').get().count, 1);
const enablePolicy = db.prepare(`UPDATE pa_recovery_write_policy
  SET delete_intent_required=1 WHERE singleton=1`);
assert.throws(() => enablePolicy.run(), /RECOVERY_COVERAGE_INCOMPLETE/u);
db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,
  record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
  VALUES(?,?,?,?,?,?,?,?)`).run(ownerId, legacyRecordId, 1,
  `recovery/v1/${ownerId}/record/${crypto.randomUUID()}`, 'v4', 'e'.repeat(64), 42, 4);
db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,
  marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
  VALUES(?,?,?,?,?,?,?,?)`).run(ownerId, legacyRecordId, 1,
  `recovery/v1/${ownerId}/manifest/${crypto.randomUUID()}`, 'v5', 'f'.repeat(64), 60, 5);
enablePolicy.run();
const deleteOldWorker = db.prepare(`UPDATE pa_records SET revision=2,deleted=1,metadata=NULL,
  photo_key=NULL,photo_bytes=0,quota_bytes=0 WHERE owner_id=? AND record_id=?`);
assert.throws(() => deleteOldWorker.run(ownerId, recordId), /DELETE_INTENT_REQUIRED/u);
db.prepare(`INSERT INTO pa_record_delete_intents(owner_id,record_id,target_revision,
  record_object_key,intent_object_key,intent_version_id,intent_sha256,intent_bytes,created_at)
  VALUES(?,?,?,?,?,?,?,?,?)`).run(ownerId, recordId, 2,
  `recovery/v1/${ownerId}/record/${crypto.randomUUID()}`,
  `recovery/v1/${ownerId}/manifest/${crypto.randomUUID()}`, 'v3', 'd'.repeat(64), 60, 4);
assert.equal(deleteOldWorker.run(ownerId, recordId).changes, 1);
console.log('PASS: record recovery migrations preserve existing records and accept commit markers');
