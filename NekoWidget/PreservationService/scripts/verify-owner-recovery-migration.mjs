import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const directory = fileURLToPath(new URL('../migrations/', import.meta.url));
const files = readdirSync(directory).filter(name => /^\d{4}_.*\.sql$/u.test(name)).sort();
const db = new DatabaseSync(':memory:');
for (const name of files.filter(name => name < '0015_')) {
  db.exec(readFileSync(join(directory, name), 'utf8'));
}
const ownerId = crypto.randomUUID();
db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
  .run(ownerId, 'a'.repeat(64), 100);
db.prepare(`INSERT INTO pa_identity_credentials(owner_id,owner_epoch,sealed_credentials,updated_at)
  VALUES(?,0,?,200)`).run(ownerId, Buffer.from([78, 75, 77, 49, 1]));
const before = db.prepare(`SELECT o.owner_id,o.identity_key,o.epoch,o.disabled,
  hex(c.sealed_credentials) AS credential FROM pa_owners o
  JOIN pa_identity_credentials c ON c.owner_id=o.owner_id WHERE o.owner_id=?`).get(ownerId);
const migration = files.find(name => name.startsWith('0015_'));
assert.ok(migration, '0015 migration is required');
db.exec(readFileSync(join(directory, migration), 'utf8'));
assert.deepEqual(db.prepare(`SELECT o.owner_id,o.identity_key,o.epoch,o.disabled,
  hex(c.sealed_credentials) AS credential FROM pa_owners o
  JOIN pa_identity_credentials c ON c.owner_id=o.owner_id WHERE o.owner_id=?`).get(ownerId), before);
const generation = () => db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?')
  .get(ownerId).generation;
assert.equal(generation(), 1);
const activate = db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=1 WHERE singleton=1`);
assert.throws(() => activate.run(), /OWNER_RECOVERY_COVERAGE_INCOMPLETE/u);
const insertSnapshot = (revision) => db.prepare(`INSERT INTO pa_owner_recovery_versions
  (owner_id,generation,object_key,version_id,sha256,bytes,confirmed_at)
  VALUES(?,?,?,?,?,?,?)`).run(ownerId, revision,
  `recovery/v1/${ownerId}/owner/${crypto.randomUUID()}`, 'synthetic-v1', 'b'.repeat(64), 50, 300);
insertSnapshot(1);
activate.run();
db.prepare(`UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?`).run(ownerId);
assert.equal(generation(), 2);
assert.throws(() => insertSnapshot(1), /OWNER_RECOVERY_STALE_GENERATION/u);
assert.throws(() => activate.run(), /OWNER_RECOVERY_COVERAGE_INCOMPLETE/u);
insertSnapshot(2);
activate.run();
db.prepare(`INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,verified_at,updated_at,email_tag)
  VALUES(?,?,'apple',250,250,?)`).run(ownerId, Buffer.from([78, 75, 77, 49, 2]), 'c'.repeat(64));
assert.equal(generation(), 3);
db.prepare(`UPDATE pa_notice_contacts SET email_tag=? WHERE owner_id=?`).run('d'.repeat(64), ownerId);
assert.equal(generation(), 4);
db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
  VALUES(?,?,300)`).run(ownerId, crypto.randomUUID());
assert.equal(generation(), 5);
db.prepare(`UPDATE pa_owners SET epoch=epoch+1,disabled=1 WHERE owner_id=?`).run(ownerId);
assert.equal(generation(), 6);
assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pa_owner_recovery_versions WHERE owner_id=?')
  .get(ownerId).count, 2);
console.log('PASS: owner recovery migration preserves rows, advances generations and fences stale refs');
