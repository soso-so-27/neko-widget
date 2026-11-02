import assert from 'node:assert/strict';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { seedReviewedFixture } from './fixtures/billing-ledger-before-0062.mjs';
import { billingOperatorStatusSQL, parseBillingOperatorSnapshot, renderBillingOperatorSnapshot } from '../scripts/billing-operator-status-lib.mjs';

const migrationDirectory = new URL('../migrations/', import.meta.url);
const cli = fileURLToPath(new URL('../scripts/billing-operator-status.mjs', import.meta.url));
function snapshot(db) { return db.prepare(billingOperatorStatusSQL).get().snapshot; }
function allMigrations() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  for (const name of readdirSync(migrationDirectory).filter(name => name.endsWith('.sql')).sort()) {
    if (name.startsWith('0062')) {
      seedReviewedFixture(db);
      db.exec('UPDATE billing_reconciliation_jobs SET lease_token=NULL,lease_expires_at=NULL');
    }
    db.exec(readFileSync(new URL(name, migrationDirectory), 'utf8'));
  }
  return db;
}

// A projection fixture exercises aggregate semantics independently of authority ingestion.
// The separate full-schema case below executes the identical SELECT against all real migrations.
function projection() {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE billing_runtime_gate(singleton,generation,effective_entitlement_enabled,subscription_reconciliation_enabled,apple_notification_history_recovery_enabled);
    INSERT INTO billing_runtime_gate VALUES(1,3,0,1,1);
    CREATE TABLE billing_apple_notification_history_recovery(environment,state,generation,committed_page_count,committed_record_count,attempts,not_before,completed_at,last_error_code);
    INSERT INTO billing_apple_notification_history_recovery VALUES('Production','completed',1,2,3,0,0,1700000000,NULL),('Sandbox','retry_wait',1,4,5,2,1800000000,NULL,'synthetic_retry');
    CREATE TABLE billing_reconciliation_jobs(environment,original_transaction_id,lease_token,lease_expires_at,not_before,last_error_code);
    INSERT INTO billing_reconciliation_jobs VALUES('Production','same',NULL,NULL,0,NULL),('Production','second','private-token',unixepoch()+1000,0,NULL),('Sandbox','same',NULL,NULL,unixepoch()+1000,'synthetic_retry'),('Sandbox','second','expired-token',unixepoch()-100,0,NULL);
    CREATE TABLE billing_effective_entitlement_current(environment,billing_account_id,original_transaction_id,ownership_type,product_id,apple_status,revocation_date_ms,revocation_reason,is_upgraded,grace_period_expires_date_ms,expires_date_ms,authority_stale_at_ms,source_fetched_at_ms);
    CREATE TABLE billing_apple_notification_history_page_commits_legacy_0061(generation,page_index);
    INSERT INTO billing_apple_notification_history_page_commits_legacy_0061 VALUES(1,1),(2,1);
    CREATE TABLE billing_apple_notification_history_page_records_legacy_0061(generation,page_index,notification_uuid);
    INSERT INTO billing_apple_notification_history_page_records_legacy_0061 VALUES(1,1,'private-notification'),(2,1,'private-notification-2');
    CREATE TABLE billing_apple_notification_history_recovery_legacy_0061(generation,store_environment);
    INSERT INTO billing_apple_notification_history_recovery_legacy_0061 VALUES(2,'Sandbox');`);
  const future = Date.now() + 86400000, past = Date.now() - 1000;
  const insert = db.prepare('INSERT INTO billing_effective_entitlement_current VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)');
  for (const environment of ['Production', 'Sandbox']) {
    insert.run(environment,'private-account','same','PURCHASED','jp.nekowidget.plus.monthly',1,null,null,0,null,future,future,past);
  }
  // Equal account with two valid lineages counts once in Production.
  insert.run('Production','private-account','second','PURCHASED','jp.nekowidget.plus.monthly',4,null,null,0,future,past,future,past);
  for (const [id,ownership,product,status,revoked,upgraded,expiry,stale] of [
    ['stale','PURCHASED','jp.nekowidget.plus.monthly',1,null,0,future,past],
    ['expired','PURCHASED','jp.nekowidget.plus.monthly',1,null,0,past,future],
    ['family','FAMILY_SHARED','jp.nekowidget.plus.monthly',1,null,0,future,future],
    ['other','PURCHASED','other.product',1,null,0,future,future],
    ['revoked','PURCHASED','jp.nekowidget.plus.monthly',5,past,0,future,future],
    ['upgraded','PURCHASED','jp.nekowidget.plus.monthly',1,null,1,future,future],
  ]) insert.run('Sandbox',id,id,ownership,product,status,revoked,null,upgraded,null,expiry,stale,past);
  return db;
}

test('fixed SELECT runs read-only against every real migration and renders a populated 0062 ledger', () => {
  const db = allMigrations();
  try {
    const changes = db.prepare('SELECT total_changes() n').get().n;
    db.exec('PRAGMA query_only=ON');
    const text = snapshot(db), value = parseBillingOperatorSnapshot(text);
    assert.equal(value.environments[0].entitlement.freshPlusAccounts, 0);
    assert.equal(value.environments[1].entitlement.freshPlusAccounts, 1);
    assert.equal(value.gate.effectiveEntitlement, 0);
    assert.match(renderBillingOperatorSnapshot(text), /Sandbox（テスト・非売上）/u);
    assert.equal(db.prepare('SELECT total_changes() n').get().n, changes);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  } finally { db.close(); }
});

test('real SELECT isolates equal identifiers, classifies jobs and excludes unknown legacy pages despite later generation collisions', () => {
  const db = projection();
  try {
    db.exec('PRAGMA query_only=ON');
    const text = snapshot(db), value = parseBillingOperatorSnapshot(text);
    const [production,sandbox] = value.environments;
    assert.deepEqual(production.reconciliation, {pending:2,leased:1,ready:1,retryWait:0,withErrors:0});
    assert.deepEqual(sandbox.reconciliation, {pending:2,leased:0,ready:1,retryWait:1,withErrors:1});
    assert.equal(production.entitlement.lineages,2);
    assert.equal(production.entitlement.freshPlusAccounts,1);
    assert.equal(sandbox.entitlement.lineages,7);
    assert.equal(sandbox.entitlement.freshPlusAccounts,1);
    assert.equal(sandbox.entitlement.staleAuthorityLineages,1);
    assert.equal(sandbox.entitlement.expiredAccessLineages,1);
    assert.deepEqual(value.unknownLegacy,{pages:1,records:1});
    assert.equal(production.history.pages,2);
    assert.equal(sandbox.history.pages,4);
    assert.doesNotMatch(text,/private-account|private-token|private-notification|expired-token/u);
    const rendered = renderBillingOperatorSnapshot(text);
    assert.match(rendered,/現在の上位設定・サービス利用許可・売上は確認しません/u);
    assert.match(rendered,/両環境から除外/u);
  } finally { db.close(); }
});

test('revoking Sandbox leaves the Production aggregate intact; expired snapshots recompute freshness at query time', () => {
  const db=projection();
  try {
    db.exec("UPDATE billing_effective_entitlement_current SET revocation_date_ms=1 WHERE environment='Sandbox'");
    let value=parseBillingOperatorSnapshot(snapshot(db));
    assert.equal(value.environments[0].entitlement.freshPlusAccounts,1);
    assert.equal(value.environments[1].entitlement.freshPlusAccounts,0);
    db.exec('UPDATE billing_effective_entitlement_current SET authority_stale_at_ms=1');
    value=parseBillingOperatorSnapshot(snapshot(db));
    assert.equal(value.environments[0].entitlement.freshPlusAccounts,0);
  } finally { db.close(); }
});

test('strict snapshot parser rejects extra sensitive fields, missing/unknown/duplicate environments and inconsistent aggregates', () => {
  const db=projection();
  try {
    const valid=JSON.parse(snapshot(db));
    for(const mutate of [
      value=>{value.rawJWS='secret';}, value=>{value.environments.pop();},
      value=>{value.environments[1].environment='Production';}, value=>{value.environments[0].environment='Unknown';},
      value=>{value.environments[0].history.cursor='secret';}, value=>{value.environments[0].history.errorCode='secret\n';},
      value=>{value.environments[0].reconciliation.pending=0;}, value=>{value.environments[0].entitlement.freshPlusAccounts=100;},
      value=>{value.unknownLegacy.pages=-1;}, value=>{value.gate=null;}, value=>{value.environments[0].history=null;},
    ]) {
      const bad=structuredClone(valid);mutate(bad);
      assert.throws(()=>renderBillingOperatorSnapshot(JSON.stringify(bad)),/invalid billing operator snapshot/u);
    }
    assert.throws(()=>parseBillingOperatorSnapshot('x'.repeat(65537)),/invalid billing operator snapshot/u);
  } finally { db.close(); }
});

test('CLI reads only a bounded local snapshot, prints fixed SQL without executing, and redacts invalid input errors', () => {
  const temp=mkdtempSync(join(tmpdir(),'neko-billing-operator-')),db=projection();
  const run=args=>spawnSync(process.execPath,[cli,...args],{encoding:'utf8',timeout:10000});
  try {
    const path=join(temp,'snapshot.json');writeFileSync(path,snapshot(db));
    const result=run(['--input',path]);assert.equal(result.status,0);assert.match(result.stdout,/Sandbox（テスト・非売上）/u);
    assert.equal(run(['--sql']).stdout.trim(),billingOperatorStatusSQL.trim());
    for(const args of [['--remote'],['--input','https://invalid.example/snapshot'],['--input','//server/share'],['--confirm-off'],['--input',path,'--sql']]) {
      const failed=run(args);assert.equal(failed.status,1);assert.equal(failed.stdout,'');
      assert.equal(failed.stderr.trim(),'FAIL billing operator status: invalid arguments or local snapshot');
    }
    writeFileSync(path,'{"secret":"do-not-print"}');
    const failed=run(['--input',path]);assert.equal(failed.status,1);assert.doesNotMatch(failed.stderr,/do-not-print|snapshot.json/u);
    writeFileSync(path,'x'.repeat(65537));assert.equal(run(['--input',path]).status,1);
  } finally {
    db.close();assert.equal(dirname(resolve(temp)),resolve(tmpdir()));
    rmSync(temp,{recursive:true,force:true});
  }
});
