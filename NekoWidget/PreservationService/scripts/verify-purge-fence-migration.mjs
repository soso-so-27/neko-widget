import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const directory = fileURLToPath(new URL('../migrations/', import.meta.url));
const db = new DatabaseSync(':memory:');
const files = readdirSync(directory).filter(name => /^\d{4}_.*\.sql$/u.test(name)).sort();
for (const name of files.filter(name => name < '0012_')) {
  db.exec(readFileSync(join(directory, name), 'utf8'));
}
const ownerId = crypto.randomUUID();
const recordId = crypto.randomUUID();
const credential = Buffer.from([1, 2, 3]);
const metadata = Buffer.from([4, 5, 6]);
db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
  .run(ownerId, `synthetic:${ownerId}`, 1);
db.prepare(`INSERT INTO pa_identity_credentials(owner_id,owner_epoch,sealed_credentials,updated_at)
  VALUES(?,0,?,1)`).run(ownerId, credential);
db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').run(ownerId);
db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,
  metadata,photo_key,photo_bytes,quota_bytes) VALUES(?,?,1,'fingerprint','operation',?,NULL,0,3)`)
  .run(ownerId, recordId, metadata);
db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,1)')
  .run(ownerId, crypto.randomUUID());
db.prepare('INSERT INTO pa_retention(owner_id) VALUES(?)').run(ownerId);
const before = db.prepare(`SELECT o.owner_id,o.identity_key,o.epoch,o.disabled,
  i.generation,i.used_bytes,hex(c.sealed_credentials) AS credential,
  hex(r.metadata) AS metadata,r.photo_key,l.billing_account_id,t.revision AS retention_revision
  FROM pa_owners o JOIN pa_inventory i ON i.owner_id=o.owner_id
  JOIN pa_identity_credentials c ON c.owner_id=o.owner_id
  JOIN pa_records r ON r.owner_id=o.owner_id
  JOIN pa_membership_links l ON l.owner_id=o.owner_id
  JOIN pa_retention t ON t.owner_id=o.owner_id WHERE o.owner_id=?`)
  .get(ownerId);
const migration = files.find(name => name.startsWith('0012_'));
assert.ok(migration, '0012 migration is required');
db.exec(readFileSync(join(directory, migration), 'utf8'));
const after = db.prepare(`SELECT o.owner_id,o.identity_key,o.epoch,o.disabled,o.purge_fence_id,
  i.generation,i.used_bytes,hex(c.sealed_credentials) AS credential,
  hex(r.metadata) AS metadata,r.photo_key,l.billing_account_id,t.revision AS retention_revision
  FROM pa_owners o JOIN pa_inventory i ON i.owner_id=o.owner_id
  JOIN pa_identity_credentials c ON c.owner_id=o.owner_id
  JOIN pa_records r ON r.owner_id=o.owner_id
  JOIN pa_membership_links l ON l.owner_id=o.owner_id
  JOIN pa_retention t ON t.owner_id=o.owner_id WHERE o.owner_id=?`)
  .get(ownerId);
assert.deepEqual({ ...after }, { ...before, purge_fence_id: null });
assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pa_purge_fences').get().count, 0);
console.log('PASS: purge fence migration preserves existing owner, credential and record state');
