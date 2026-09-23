import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const migrations = fileURLToPath(new URL('../migrations/', import.meta.url));
const db = new DatabaseSync(':memory:');
const files = readdirSync(migrations).filter(name => /^\d{4}_.*\.sql$/u.test(name)).sort();
for (const name of files.filter(name => name < '0010_')) {
  db.exec(readFileSync(join(migrations, name), 'utf8'));
}

const now = Date.now();
const expiredAt = now - 365 * 86_400_000;
const dueAt = now - 86_400_000;
const deliveredAt = now - 45 * 86_400_000;
const oldTag = 'a'.repeat(64);
const owners = [crypto.randomUUID(), crypto.randomUUID()];
const events = [];
for (const ownerId of owners) {
  const eventId = crypto.randomUUID();
  events.push(eventId);
  const messageId = `mail-${crypto.randomUUID()}`;
  db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .run(ownerId, `synthetic:${ownerId}`, expiredAt);
  db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
    .run(ownerId, crypto.randomUUID(), expiredAt);
  db.prepare(`INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,verified_at,updated_at)
    VALUES(?,?,'apple',?,?)`).run(ownerId, Buffer.from([1, 2, 3]), expiredAt, expiredAt);
  db.prepare(`INSERT INTO pa_retention(owner_id,revision,episode,verified_status,checked_at,
    expired_at,due_at,notice_not_before_at,final_notice_delivered_at,final_notice_receipt)
    VALUES(?,2,1,'expired',?,?,?,?,?,?)`)
    .run(ownerId, now, expiredAt, dueAt, expiredAt, deliveredAt, eventId);
  db.prepare(`INSERT INTO pa_notice_submissions(message_id,owner_id,episode,retention_revision,
    due_at,contact_updated_at,recipient_tag,account_id,zone_id,subscription_id,domain,sender,
    submitted_at,delivered_at,delivery_event_id)
    VALUES(?,?,1,1,?,?,?,?,?,?,?,?,?,?,?)`)
    .run(messageId, ownerId, dueAt, expiredAt, oldTag, 'b'.repeat(32), 'c'.repeat(32),
      'd'.repeat(32), 'example.com', 'notice@example.com', deliveredAt - 1000,
      deliveredAt, eventId);
  db.prepare(`INSERT INTO pa_notice_claims(owner_id,claim_id,episode,due_at,
    contact_updated_at,recipient_tag,claimed_at,expires_at)
    VALUES(?,?,1,?,?,?,?,?)`)
    .run(ownerId, crypto.randomUUID(), dueAt, expiredAt, oldTag, now - 1000, now + 86_400_000);
}

const migration = files.find(name => name.startsWith('0010_'));
assert.ok(migration, '0010 migration is required');
db.exec(readFileSync(join(migrations, migration), 'utf8'));
const rows = db.prepare(`SELECT r.owner_id,r.revision,r.final_notice_delivered_at,
  r.final_notice_receipt,r.notice_not_before_at,s.evidence_version,s.recipient_tag
  FROM pa_retention r JOIN pa_notice_submissions s ON s.owner_id=r.owner_id
  ORDER BY r.owner_id`).all();
assert.equal(rows.length, 2);
for (const row of rows) {
  assert.equal(row.revision, 3);
  assert.equal(row.final_notice_delivered_at, null);
  assert.equal(row.final_notice_receipt, null);
  assert.ok(row.notice_not_before_at >= Math.floor(now / 1000) * 1000);
  assert.equal(row.evidence_version, 1);
  assert.match(row.recipient_tag, /^[0-9a-f]{64}$/u);
  assert.notEqual(row.recipient_tag, oldTag);
}
assert.notEqual(rows[0].recipient_tag, rows[1].recipient_tag);
const claims = db.prepare('SELECT evidence_version,recipient_tag FROM pa_notice_claims').all();
assert.equal(claims.length, 2);
assert.ok(claims.every(row => row.evidence_version === 1 && row.recipient_tag !== oldTag));
assert.notEqual(claims[0].recipient_tag, claims[1].recipient_tag);
assert.throws(() => db.prepare(`UPDATE pa_notice_submissions SET delivered_at=delivered_at+1
  WHERE owner_id=?`).run(owners[0]), /notice evidence v2 required/u);
assert.throws(() => db.prepare(`UPDATE pa_retention SET final_notice_delivered_at=?,final_notice_receipt=?
  WHERE owner_id=?`).run(deliveredAt, events[0], owners[0]), /legacy notice receipt cannot be promoted/u);
assert.throws(() => db.prepare(`INSERT INTO pa_notice_submissions(message_id,owner_id,episode,
  retention_revision,due_at,contact_updated_at,recipient_tag,account_id,zone_id,
  subscription_id,domain,sender,submitted_at)
  VALUES(?,?,1,1,?,?,?,?,?,?,?,?,?)`).run(`mail-${crypto.randomUUID()}`, owners[0],
  dueAt, expiredAt, oldTag, 'b'.repeat(32), 'c'.repeat(32), 'd'.repeat(32),
  'example.com', 'notice@example.com', now), /notice evidence v2 required/u);
const replacementClaim = crypto.randomUUID();
db.prepare(`INSERT INTO pa_notice_claims(owner_id,claim_id,episode,due_at,
  contact_updated_at,recipient_tag,claimed_at,expires_at,evidence_version)
  VALUES(?,?,1,?,?,?,?,?,2)
  ON CONFLICT(owner_id) DO UPDATE SET claim_id=excluded.claim_id,
    recipient_tag=excluded.recipient_tag,evidence_version=excluded.evidence_version
  WHERE pa_notice_claims.evidence_version<>2`)
  .run(owners[0], replacementClaim, dueAt, expiredAt, 'e'.repeat(64), now, now + 86_400_000);
assert.equal(db.prepare('SELECT evidence_version FROM pa_notice_claims WHERE owner_id=?')
  .get(owners[0]).evidence_version, 2);
db.close();
console.log('PASS: legacy notice evidence requires re-notice and no longer links owners');
