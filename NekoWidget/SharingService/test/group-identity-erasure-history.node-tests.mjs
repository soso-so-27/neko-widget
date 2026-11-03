import assert from 'node:assert/strict';
import {readdirSync,readFileSync} from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import test from 'node:test';

// Two SQL-valid, pre-0072 histories. IDs/times and unrelated rows are identical;
// only the original sender and its signed metadata differ before expiry.
function history(sender) {
  const db=new DatabaseSync(':memory:');
  let now=1793660000;
  db.function('unixepoch',{varargs:true},(...args)=>args.length?Number(args[0]):now);
  db.function('randomblob',n=>Buffer.alloc(n,1));
  const directory=new URL('../migrations/',import.meta.url);
  for(const f of readdirSync(directory).filter(f=>f.endsWith('.sql')&&Number(f.slice(0,4))<72).sort())
    db.exec(readFileSync(new URL(f,directory),'utf8'));
  const space='w'.repeat(22),moment='M'.repeat(22),report='R'.repeat(22);
  const photoKey=`groups/v3/${space}/${moment}/${'H'.repeat(43)}`;
  const reportKey=`groups/reports/v3/${report}/${'K'.repeat(32)}`;
  const run=(query,...args)=>db.prepare(query).run(...args);
  for(const p of ['a','b','r']){
    run("INSERT INTO group_people VALUES (?,?,'active',?)",p,'identity-'+p,now);
    run("INSERT INTO group_person_devices VALUES (?,?,?,?,?,'active',?,NULL)",'d'+p,p,'sig'+p,'hpke'+p,'certificate'+p,now);
  }
  run("INSERT INTO group_windows(space_id,owner_person_id,mode,revision,key_epoch,roster_hash,created_at,updated_at) VALUES (?,'a','active',1,1,'roster',?,?)",space,now,now);
  for(const p of ['a','b','r']){
    run("INSERT INTO group_members VALUES (?,?,?,?,'active',1,NULL,'name')",'m'+p,space,p,p==='a'?'owner':'member');
    run("INSERT INTO group_window_devices VALUES (?,?,?,'active',1,NULL)",space,'d'+p,'m'+p);
  }
  run("INSERT INTO group_rosters VALUES (?,1,'previous',1,X'01','roster','da','signature',?)",space,now);
  run("INSERT INTO group_moments VALUES (?,?,'client',?,?,1,1,'roster',42,'photo-hash',?,'photo','reserved',?,?,?,NULL,?,?,NULL)",moment,space,'m'+sender,'d'+sender,'photo-signature-'+sender,photoKey,now,now+600,now+30*86400,now+7*86400);
  run("UPDATE group_moments SET state='uploaded' WHERE id=?",moment);
  run("UPDATE group_moments SET state='committed',committed_at=? WHERE id=?",now,moment);
  run("INSERT INTO group_moment_deliveries VALUES (?,'dr','mr',1,'acknowledged',?,?)",moment,now+7*86400,now);
  run("INSERT INTO group_reports VALUES (?,?,?,'r','mr','dr',?,'privacy','moderation-v2',32,'hash',1,?,?,'dedupe','reserved',?,?,NULL,NULL,NULL,NULL)",report,space,moment,'m'+sender,now,reportKey,now,now+3600);
  run("INSERT INTO group_report_numbers(report_id) VALUES (?)",report);
  run("UPDATE group_reports SET state='uploaded',uploaded_at=? WHERE id=?",now,report);
  run("UPDATE group_reports SET state='committed',committed_at=?,content_expires_at=? WHERE id=?",now,now+7*86400,report);
  // Existing GC is independent of the bounded operator-decision queue. The
  // report record remains while both expiring sources cease to exist.
  now+=7*86400+1;
  run("UPDATE group_reports SET state='expired',expired_at=? WHERE id=?",now,report);
  run("UPDATE group_moments SET state='expired',expired_at=? WHERE id=?",now,moment);
  run("INSERT INTO group_object_deletions SELECT id,object_key,0,?,'pending' FROM group_moments WHERE id=? AND state='expired'",now,moment);
  run("INSERT INTO group_report_object_deletions SELECT id,object_key,0,?,'pending' FROM group_reports WHERE id=? AND state='expired'",now,report);
  // Model successful object deletion. Real R2 is not part of this SQL probe.
  assert.match(photoKey,/^groups\/v3\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{43}$/u);
  assert.match(reportKey,/^groups\/reports\/v3\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{32}$/u);
  run("UPDATE group_object_deletions SET state='completed' WHERE moment_id=? AND object_key=?",moment,photoKey);
  run("UPDATE group_report_object_deletions SET state='completed' WHERE report_id=? AND object_key=?",report,reportKey);
  now+=2*86400+1;
  run("DELETE FROM group_reports WHERE id IN (SELECT r.id FROM group_reports r JOIN group_report_object_deletions q ON q.report_id=r.id AND q.object_key=r.object_key WHERE r.state='expired' AND r.expired_at<=? AND q.state='completed' LIMIT 50)",now-2*86400);
  run("DELETE FROM group_moments WHERE id=? AND state='expired' AND expired_at<=? AND EXISTS(SELECT 1 FROM group_object_deletions q WHERE q.moment_id=group_moments.id AND q.state='completed')",moment,now-2*86400);
  run("DELETE FROM group_object_deletions WHERE state='completed' AND available_at<=? AND NOT EXISTS(SELECT 1 FROM group_moments m WHERE m.id=moment_id)",now-2*86400);
  run("DELETE FROM group_report_object_deletions WHERE state='completed' AND available_at<=? AND NOT EXISTS(SELECT 1 FROM group_reports r WHERE r.id=report_id)",now-2*86400);
  assert.equal(db.prepare('SELECT count(*) n FROM group_moments').get().n,0);
  assert.equal(db.prepare('SELECT count(*) n FROM group_reports').get().n,0);
  assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(),[]);
  assert.equal(db.prepare('SELECT count(*) n FROM group_report_records').get().n,1);
  assert.equal(db.prepare('SELECT count(*) n FROM group_moderation_restrictions WHERE active=1').get().n,0);
  const state=Object.fromEntries(db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all()
    .map(({name})=>[name,db.prepare(`SELECT * FROM ${name} ORDER BY rowid`).all()]));
  db.close();return state;
}

test('legacy relay cleanup can erase the only binding from an undecided report to its accused person',()=>{
  const accusedWasA=history('a'),accusedWasB=history('b');
  assert.deepEqual(accusedWasA,accusedWasB);
});
