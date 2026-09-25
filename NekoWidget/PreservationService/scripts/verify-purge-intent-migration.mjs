import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const directory = fileURLToPath(new URL('../migrations/', import.meta.url));
const files = readdirSync(directory).filter(name => /^\d{4}_.*\.sql$/u.test(name)).sort();
const db = new DatabaseSync(':memory:');
for (const name of files.filter(name => name < '0016_')) {
  db.exec(readFileSync(join(directory, name), 'utf8'));
}
const ownerId = crypto.randomUUID();
db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
  .run(ownerId, crypto.randomUUID(), 100);
const before = db.prepare('SELECT owner_id,identity_key,epoch,disabled FROM pa_owners WHERE owner_id=?')
  .get(ownerId);
const migration = files.find(name => name.startsWith('0016_'));
assert.ok(migration, '0016 migration is required');
db.exec(readFileSync(join(directory, migration), 'utf8'));
assert.deepEqual(db.prepare('SELECT owner_id,identity_key,epoch,disabled FROM pa_owners WHERE owner_id=?')
  .get(ownerId), before);
assert.equal(db.prepare('SELECT COUNT(*) AS n FROM pa_owner_purge_events').get().n, 0);

const intentId = crypto.randomUUID();
const event = (stage, manifest) => db.prepare(`INSERT INTO pa_owner_purge_events
  (owner_id,intent_id,stage,owner_epoch,inventory_generation,retention_episode,
  retention_revision,due_at,recorded_at,manifest_sha256,s3_object_key,
  s3_version_id,s3_sha256,s3_bytes)
  VALUES(?,?,?,0,0,1,1,100,200,?,?,'synthetic-v1',?,100)`)
  .run(ownerId, intentId, stage, manifest, `purge/v1/${ownerId}/${intentId}/${stage}`,
    'a'.repeat(64));
assert.throws(() => event('erasing', 'b'.repeat(64)), /PURGE_EVENT_PREPARATION_MISSING/u);
event('prepared', null);
assert.throws(() => event('completed', 'b'.repeat(64)), /PURGE_EVENT_ERASURE_MISSING/u);
event('aborted', null);
assert.throws(() => event('erasing', 'b'.repeat(64)), /PURGE_EVENT_ABORTED_CANNOT_ERASE/u);
assert.throws(() => db.prepare(`UPDATE pa_owner_purge_events SET s3_version_id='other' WHERE owner_id=?`)
  .run(ownerId), /PURGE_EVENT_IMMUTABLE/u);
assert.deepEqual(db.prepare('SELECT owner_id,identity_key,epoch,disabled FROM pa_owners WHERE owner_id=?')
  .get(ownerId), before);
console.log('PASS: purge-intent migration preserves existing owner and rejects invalid transitions');
