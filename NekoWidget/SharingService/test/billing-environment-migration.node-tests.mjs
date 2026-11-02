import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync, backup } from "node:sqlite";
import { readFileSync, readdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { fixture, seedReviewedFixture, sponsor } from "./fixtures/billing-ledger-before-0062.mjs";

const directory = new URL("../migrations/", import.meta.url);
const migration = readFileSync(new URL("0062_billing_environment_ledger.sql", directory), "utf8");
const affected = [...migration.matchAll(/CREATE TABLE (billing_\w+)__new \(/gu)].map(m => m[1]);
function snapshot(db) {
  const schema = db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
  const rows = Object.fromEntries(schema.filter(x => x.type === 'table').map(x => [x.name, db.prepare(`SELECT * FROM ${x.name} ORDER BY rowid`).all()]));
  return { schema, rows };
}
function gates(db, enabled) {
  db.exec(`UPDATE billing_runtime_gate SET generation=generation+1,
    effective_entitlement_enabled=${enabled},window_sponsorship_enabled=${enabled},
    apple_notification_history_recovery_enabled=${enabled},updated_at=unixepoch() WHERE singleton=1`);
}
function history(db, environment, notification = null) {
  const now = Math.floor(Date.now()/1000), token = 'L'.repeat(21)+'A';
  db.prepare(`UPDATE billing_apple_notification_history_recovery SET generation=generation+1,
    state='ready',store_environment=?,bundle_id='jp.nekowidget.app',frozen_start_date_ms=?,frozen_end_date_ms=?,
    pagination_cursor=NULL,committed_page_count=0,committed_record_count=0,cursor_reset_count=0,
    attempts=0,not_before=?,started_at=?,completed_at=NULL,updated_at=unixepoch() WHERE singleton=1`)
    .run(environment,(now-100)*1000,(now+100)*1000,now,now);
  const {generation} = db.prepare('SELECT generation FROM billing_apple_notification_history_recovery').get();
  const gate = db.prepare('SELECT generation FROM billing_runtime_gate').get().generation;
  db.prepare(`UPDATE billing_apple_notification_history_recovery SET state='leased',lease_token=?,lease_expires_at=?,
    claimed_gate_generation=?,updated_at=unixepoch()`).run(token,now+120,gate);
  db.prepare(`INSERT INTO billing_apple_notification_history_page_commits(generation,page_index,gate_generation,lease_token,has_more,record_count)
    VALUES(?,1,?,?,0,?)`).run(generation,gate,token,notification ? 1 : 0);
  if(notification)db.prepare(`INSERT INTO billing_apple_notification_history_page_records(generation,page_index,record_index,notification_uuid,payload_hash)
    VALUES(?,1,0,?,?)`).run(generation,notification,'P'.repeat(43));
  db.prepare(`UPDATE billing_apple_notification_history_recovery SET state='completed',committed_page_count=1,committed_record_count=?,
    lease_token=NULL,lease_expires_at=NULL,claimed_gate_generation=NULL,completed_at=?,updated_at=unixepoch()`)
    .run(notification ? 1 : 0,now);
  db.prepare('INSERT INTO billing_apple_notification_history_page_finalizations(generation,page_index) VALUES(?,1)').run(generation);
}
function oldDatabase() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  for(const name of readdirSync(directory).filter(n=>n.endsWith('.sql')&&n<'0062').sort()) db.exec(readFileSync(new URL(name,directory),'utf8'));
  const consent = seedReviewedFixture(db);
  gates(db,1);
  sponsor(db,{requestId:'20000000-0000-4000-8000-000000000001',requestHash:'S'.repeat(43),expectedGeneration:0,
    expectedCurrentBillingAccountId:null,...consent});
  db.prepare(`INSERT INTO billing_transaction_events(event_fingerprint,transaction_id,original_transaction_id,billing_account_id,
    source,product_id,subscription_group_id,environment,ownership_type,transaction_reason,purchase_date_ms,original_purchase_date_ms,
    expires_date_ms,signed_date_ms,is_upgraded) VALUES(?,?,?,?,'apple_notification','jp.nekowidget.plus.monthly','20999999',
    'Sandbox','PURCHASED','PURCHASE',1,1,9999999999999,unixepoch()*1000,0)`)
    .run('T'.repeat(43),fixture.transactionId,fixture.originalTransactionId,fixture.billingAccountId);
  const notification='30000000-0000-4000-8000-000000000001';
  db.prepare(`INSERT INTO billing_apple_notification_events(notification_uuid,payload_hash,notification_type,signed_date_ms,environment,
    apple_status,relevance,transaction_id,original_transaction_id,billing_account_id) VALUES(?,?,'DID_RENEW',unixepoch()*1000,
    'Sandbox',1,'linked',?,?,?)`).run(notification,'P'.repeat(43),fixture.transactionId,fixture.originalTransactionId,fixture.billingAccountId);
  db.prepare('INSERT INTO billing_apple_notification_reconciliation_causes(notification_uuid,original_transaction_id) VALUES(?,?)')
    .run(notification,fixture.originalTransactionId);
  history(db,'Production'); // Old empty pages have no trustworthy environment in 0061.
  history(db,'Sandbox',notification);
  db.prepare(`INSERT INTO billing_account_recovery_requests(client_request_id,request_hash,billing_account_id,expected_generation,
    expected_transaction_id,expected_original_transaction_id,app_transaction_id_hash,replaced_billing_key_id,new_billing_key_id,new_signing_public_key)
    VALUES(?,?,?,0,?,?,?,?,?,?)`).run('40000000-0000-4000-8000-000000000001','R'.repeat(42)+'A',fixture.billingAccountId,
    fixture.transactionId,fixture.originalTransactionId,'A'.repeat(43),fixture.billingKeyId,'N'.repeat(21)+'A','E'.repeat(43));
  db.exec('UPDATE billing_reconciliation_jobs SET lease_token=NULL,lease_expires_at=NULL');
  gates(db,0);
  assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(),[]);
  for(const name of affected)assert.ok(db.prepare(`SELECT count(*) n FROM ${name}`).get().n>0, `unpopulated fixture: ${name}`);
  return db;
}
test('0061 populated ledger upgrades without loss and restores the exact quiescent snapshot before writes resume', async()=>{
  const db=oldDatabase();
  const temp=mkdtempSync(join(tmpdir(),'neko-ledger-migration-'));
  try {
    const before=snapshot(db);
    await backup(db,join(temp,'before.sqlite'));
    db.exec('BEGIN;'+migration+'COMMIT;');
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(),[]);
    for(const name of affected) {
      const actual=db.prepare(`SELECT * FROM ${name.startsWith('billing_apple_notification_history_') ? name+'_legacy_0061' : name} ORDER BY rowid`).all();
      const columns=Object.keys(before.rows[name][0]);
      assert.deepEqual(actual.map(row=>Object.fromEntries(columns.map(k=>[k,row[k]]))),before.rows[name].map(row=>({...row})), name);
    }
    assert.deepEqual(db.prepare('SELECT environment,generation FROM billing_apple_notification_history_page_commits').all().map(r=>({...r})),[{environment:'Sandbox',generation:2}]);
    assert.equal(db.prepare("SELECT state FROM billing_apple_notification_history_recovery WHERE environment='Production'").get().state,'idle');
    assert.throws(()=>db.exec('DELETE FROM billing_apple_notification_history_page_commits_legacy_0061'),/immutable/);
    const restored=new DatabaseSync(join(temp,'before.sqlite'));
    try { restored.exec('PRAGMA foreign_keys=ON');assert.deepEqual(snapshot(restored),before);assert.deepEqual(restored.prepare('PRAGMA foreign_key_check').all(),[]); }
    finally { restored.close(); }
  } finally {
    db.close();
    assert.equal(dirname(resolve(temp)),resolve(tmpdir()));
    assert.ok(basename(temp).startsWith('neko-ledger-migration-'));
    rmSync(temp,{recursive:true,force:true});
  }
});
test('migration refuses an open gate or an outstanding lease atomically',()=>{
  for(const block of ['gate','lease']) {
    const db=oldDatabase();
    try {
      if(block==='gate')gates(db,1);
      else db.exec("UPDATE billing_reconciliation_jobs SET lease_token='LLLLLLLLLLLLLLLLLLLLLA',lease_expires_at=unixepoch()+120");
      const before=snapshot(db);
      assert.throws(()=>db.exec('BEGIN;'+migration+'COMMIT;'),/CHECK constraint failed/);
      db.exec('ROLLBACK');assert.deepEqual(snapshot(db),before);
    } finally { db.close(); }
  }
});
test('environment keys permit equal Apple identifiers and retain same-environment uniqueness/FKs',()=>{
  const db=oldDatabase();
  try {
    db.exec('BEGIN;'+migration+'COMMIT;');
    db.prepare(`INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id)
      SELECT original_transaction_id,billing_account_id,'Production',subscription_group_id FROM billing_transaction_lineages WHERE environment='Sandbox'`).run();
    const event=db.prepare('SELECT * FROM billing_transaction_events').get();
    const keys=Object.keys(event),sql=`INSERT INTO billing_transaction_events(${keys.join(',')}) VALUES(${keys.map(()=>'?').join(',')})`;
    db.prepare(sql).run(...keys.map(k=>k==='environment'?'Production':k==='event_fingerprint'?'U'.repeat(43):event[k]));
    assert.throws(()=>db.prepare(sql).run(...keys.map(k=>k==='event_fingerprint'?'V'.repeat(43):event[k])),/UNIQUE constraint failed/);
    db.prepare(`INSERT INTO billing_apple_notification_events SELECT notification_uuid,payload_hash,notification_type,subtype,signed_date_ms,
      'Production',apple_status,relevance,transaction_id,original_transaction_id,billing_account_id,received_at FROM billing_apple_notification_events WHERE environment='Sandbox'`).run();
    assert.equal(db.prepare('SELECT count(*) n FROM billing_apple_notification_events').get().n,2);
    assert.throws(()=>db.exec("INSERT INTO billing_reconciliation_jobs(environment,original_transaction_id,requested_at,not_before) VALUES('Production','777',1,1)"),/FOREIGN KEY/);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(),[]);
    // New cross-environment rows cannot be represented by the old PK: do not apply a lossy down migration or restore an old snapshot after this point.
    assert.equal(db.prepare('SELECT count(*) n FROM billing_transaction_lineages WHERE original_transaction_id=?').get(fixture.originalTransactionId).n,2);
  } finally { db.close(); }
});

test('local D1 upgrades a populated 0061 snapshot in one batch and can restore the pre-write snapshot', {timeout:120000}, async()=>{
  const source=oldDatabase(), before=snapshot(source);source.close();
  const mf=new Miniflare(convertV4MiniflareOptions({cf:false,modules:true,compatibilityDate:'2026-08-17',
    script:'export default { fetch() { return new Response(null,{status:404}); } };',
    d1Databases:{DB:'environment-migration-local',RESTORE:'environment-restore-local'}}));
  const restore=async(db)=>{
    const statements=[db.prepare('PRAGMA defer_foreign_keys=ON')];
    for(const item of before.schema.filter(x=>x.type==='table'))statements.push(db.prepare(item.sql));
    for(const [table,rows] of Object.entries(before.rows))for(const row of rows){
      const columns=Object.keys(row);
      statements.push(db.prepare(`INSERT INTO ${table}(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`).bind(...Object.values(row)));
    }
    for(const kind of ['index','view','trigger'])for(const item of before.schema.filter(x=>x.type===kind))statements.push(db.prepare(item.sql));
    await db.batch(statements);
    assert.deepEqual((await db.prepare('PRAGMA foreign_key_check').all()).results,[]);
  };
  try{
    const db=await mf.getD1Database('DB');await restore(db);
    const migrations=await readD1Migrations(fileURLToPath(directory));
    const upgrade=migrations.find(m=>m.name==='0062_billing_environment_ledger.sql');
    assert.ok(upgrade);
    await db.batch(upgrade.queries.map(sql=>db.prepare(sql)));
    assert.deepEqual((await db.prepare('PRAGMA foreign_key_check').all()).results,[]);
    const migratedRows=await db.batch(affected.map(table=>{
      const name=table.startsWith('billing_apple_notification_history_')?table+'_legacy_0061':table;
      const columns=Object.keys(before.rows[table][0]);
      return db.prepare(`SELECT ${columns.join(',')} FROM ${name} ORDER BY rowid`);
    }));
    affected.forEach((table,index)=>assert.deepEqual(migratedRows[index].results,before.rows[table].map(r=>({...r})),table));
    const reverted=await mf.getD1Database('RESTORE');await restore(reverted);
    const restoredRows=await reverted.batch(Object.keys(before.rows).map(table=>reverted.prepare(`SELECT * FROM ${table} ORDER BY rowid`)));
    Object.entries(before.rows).forEach(([table,rows],index)=>assert.deepEqual(restoredRows[index].results,rows.map(r=>({...r})),table));
  }finally{await mf.dispose();}
});
