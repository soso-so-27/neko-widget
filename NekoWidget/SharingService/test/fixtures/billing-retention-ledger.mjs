import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { fixture, seedReviewedFixture, sponsor } from './billing-ledger-before-0062.mjs';

export const target = fixture.billingAccountId;
export const other = '10000000-0000-4000-8000-000000000002';
const directory = new URL('../../migrations/', import.meta.url);
const replacements = new Map([
 [fixture.billingAccountId, other], [fixture.billingKeyId, 'K'.repeat(21)+'A'],
 [fixture.billingPublicKey, 'K'.repeat(42)+'A'], [fixture.lineageId, 'other-lineage'],
 [fixture.spaceId, 'other-space'], [fixture.ownerParticipantId, 'other-owner'],
 [fixture.ownerDeviceId, 'other-device'], [fixture.originalTransactionId,'900000000002001'],
 [fixture.transactionId,'900000000002002'], [fixture.observationFingerprint,'J'.repeat(43)],
 [fixture.leaseToken,'L'.repeat(21)+'A'], [fixture.decisionId,'M'.repeat(21)+'A'],
 ['E'.repeat(43),'N'.repeat(42)+'A'], ['F'.repeat(43),'P'.repeat(42)+'A'],
 ['G'.repeat(43),'Q'.repeat(43)], ['H'.repeat(43),'R'.repeat(43)],
]);
const map = value => replacements.get(value) ?? value;
function mapped(db) {
 return { prepare(sql) { const statement=db.prepare(sql);return {
  run(...args){return statement.run(...args.map(map));},get(...args){return statement.get(...args.map(map));}
 };}, exec(sql) { db.exec(sql.replace('FROM billing_effective_entitlement_decisions',
  `FROM billing_effective_entitlement_decisions WHERE billing_account_id='${other}'`)); } };
}
export function populatedRetentionLedger() {
 const db=new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON');
 const files=readdirSync(directory).filter(n=>n.endsWith('.sql')).sort();
 for(const file of files.filter(n=>n<'0062'))db.exec(readFileSync(new URL(file,directory),'utf8'));
 const consent=seedReviewedFixture(db), otherConsent=seedReviewedFixture(mapped(db));
 db.exec('UPDATE billing_runtime_gate SET generation=generation+1,effective_entitlement_enabled=1,window_sponsorship_enabled=1,apple_notification_history_recovery_enabled=1,updated_at=unixepoch()');
 sponsor(db,{requestId:'20000000-0000-4000-8000-000000000001',requestHash:'S'.repeat(43),expectedGeneration:0,expectedCurrentBillingAccountId:null,...consent});
 sponsor(mapped(db),{requestId:'20000000-0000-4000-8000-000000000002',requestHash:'T'.repeat(43),expectedGeneration:0,expectedCurrentBillingAccountId:null,...otherConsent});
 const notifications=[];
 for(const [index,account,lineage,transaction] of [[1,target,fixture.originalTransactionId,fixture.transactionId],[2,other,'900000000002001','900000000002002']]) {
  const notification=`30000000-0000-4000-8000-00000000000${index}`;
  notifications.push(notification);
  db.prepare(`INSERT INTO billing_transaction_events(event_fingerprint,transaction_id,original_transaction_id,billing_account_id,source,
   product_id,subscription_group_id,environment,ownership_type,transaction_reason,purchase_date_ms,original_purchase_date_ms,
   expires_date_ms,signed_date_ms,is_upgraded) VALUES(?,?,?,?,'apple_notification','jp.nekowidget.plus.monthly','20999999',
   'Sandbox','PURCHASED','PURCHASE',1,1,9999999999999,unixepoch()*1000,0)`)
   .run(String(index).repeat(43),transaction,lineage,account);
  db.prepare(`INSERT INTO billing_apple_notification_events(notification_uuid,payload_hash,notification_type,signed_date_ms,environment,
   apple_status,relevance,transaction_id,original_transaction_id,billing_account_id) VALUES(?,?,'DID_RENEW',unixepoch()*1000,
   'Sandbox',1,'linked',?,?,?)`).run(notification,String(index+2).repeat(43),transaction,lineage,account);
  db.prepare('INSERT INTO billing_apple_notification_reconciliation_causes(notification_uuid,original_transaction_id) VALUES(?,?)').run(notification,lineage);
 }
 const now=Math.floor(Date.now()/1000),lease='V'.repeat(21)+'A';
 db.prepare(`UPDATE billing_apple_notification_history_recovery SET generation=generation+1,state='ready',store_environment='Sandbox',
  bundle_id='jp.nekowidget.app',frozen_start_date_ms=?,frozen_end_date_ms=?,pagination_cursor=NULL,committed_page_count=0,
  committed_record_count=0,cursor_reset_count=0,attempts=0,not_before=?,started_at=?,completed_at=NULL,updated_at=unixepoch()`)
  .run((now-100)*1000,(now+100)*1000,now,now);
 const gate=db.prepare('SELECT generation FROM billing_runtime_gate').get().generation;
 const generation=db.prepare('SELECT generation FROM billing_apple_notification_history_recovery').get().generation;
 db.prepare(`UPDATE billing_apple_notification_history_recovery SET state='leased',lease_token=?,lease_expires_at=?,claimed_gate_generation=?,updated_at=unixepoch()`).run(lease,now+120,gate);
 db.prepare(`INSERT INTO billing_apple_notification_history_page_commits(generation,page_index,gate_generation,lease_token,has_more,record_count) VALUES(?,1,?,?,0,2)`).run(generation,gate,lease);
 notifications.forEach((id,i)=>db.prepare(`INSERT INTO billing_apple_notification_history_page_records(generation,page_index,record_index,notification_uuid,payload_hash) VALUES(?,1,?,?,?)`).run(generation,i,id,String(i+3).repeat(43)));
 db.prepare(`UPDATE billing_apple_notification_history_recovery SET state='completed',committed_page_count=1,committed_record_count=2,
  lease_token=NULL,lease_expires_at=NULL,claimed_gate_generation=NULL,completed_at=?,updated_at=unixepoch()`).run(now);
 db.prepare('INSERT INTO billing_apple_notification_history_page_finalizations(generation,page_index) VALUES(?,1)').run(generation);
 db.prepare(`INSERT INTO billing_account_recovery_requests(client_request_id,request_hash,billing_account_id,expected_generation,
  expected_transaction_id,expected_original_transaction_id,app_transaction_id_hash,replaced_billing_key_id,new_billing_key_id,new_signing_public_key)
  VALUES(?,?,?,0,?,?,?,?,?,?)`).run('40000000-0000-4000-8000-000000000001','R'.repeat(42)+'A',target,
  fixture.transactionId,fixture.originalTransactionId,'A'.repeat(43),fixture.billingKeyId,'N'.repeat(21)+'A','S'.repeat(42)+'A');
 db.exec('UPDATE billing_reconciliation_jobs SET lease_token=NULL,lease_expires_at=NULL; UPDATE billing_runtime_gate SET generation=generation+1,effective_entitlement_enabled=0,window_sponsorship_enabled=0,apple_notification_history_recovery_enabled=0,updated_at=unixepoch()');
 for(const file of files.filter(n=>n>='0062'))db.exec(readFileSync(new URL(file,directory),'utf8'));
 // Equal raw lineage IDs in different stores remain independent; early account deletion covers both.
 db.prepare(`INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id)
  VALUES(?,?,'Production','20999999')`).run(fixture.originalTransactionId,target);
 const event=db.prepare('SELECT * FROM billing_transaction_events WHERE billing_account_id=?').get(target);
 const columns=Object.keys(event);
 db.prepare(`INSERT INTO billing_transaction_events(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`)
  .run(...columns.map(c=>c==='environment'?'Production':c==='event_fingerprint'?'W'.repeat(43):event[c]));
 for(const person of ['a','b']) {
  db.prepare("INSERT INTO group_people VALUES(?,?,'active',unixepoch())").run('person-'+person,'identity-'+person);
  db.prepare("INSERT INTO group_person_devices VALUES(?,?,?,?,?,'active',unixepoch(),NULL)")
   .run('device-'+person,'person-'+person,'signing-'+person,'hpke-'+person,'authorization');
 }
 db.prepare('INSERT INTO group_billing_connections VALUES(?,?,?,?,unixepoch())').run('person-a',target,'device-a','N'.repeat(21)+'A');
 db.exec('UPDATE billing_runtime_gate SET generation=generation+1,effective_entitlement_enabled=1,updated_at=unixepoch(); UPDATE family_notebook_runtime_gate SET generation=generation+1,enabled=1');
 db.prepare(`INSERT INTO family_notebook_admission_events(actor_device_id,operation_id,actor_person_id,request_hash,family_id,operation,expected_generation,
  resulting_generation,invitation_id,join_id,proof_public_key,ciphertext,store_environment,maximum_members)
  VALUES('device-a','create-family','person-a','hash','family-kept','create',0,1,NULL,NULL,NULL,NULL,'Sandbox',6)`).run();
 db.exec(`INSERT INTO family_notebook_members VALUES('family-kept','person-b','active',1,NULL); INSERT INTO family_notebook_crypto_rosters VALUES('family-kept',1,'synthetic-hash','{"synthetic":"roster"}'); INSERT INTO family_notebook_crypto_operations VALUES('family-kept',1,'synthetic-operation',1,'person-a','device-a','{"synthetic":"history"}')`);
 return db;
}
export function snapshot(db) {
 const schema=db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
 const rows=Object.fromEntries(schema.filter(r=>r.type==='table').map(r=>[r.name,db.prepare(`SELECT * FROM ${r.name} ORDER BY rowid`).all().map(x=>({...x}))]));
 return {schema,rows};
}
export async function restoreD1(db,before) {
 const statements=[db.prepare('PRAGMA defer_foreign_keys=ON')];
 for(const item of before.schema.filter(x=>x.type==='table'))statements.push(db.prepare(item.sql));
 for(const [table,rows] of Object.entries(before.rows))for(const row of rows){
  const columns=Object.keys(row);
  statements.push(db.prepare(`INSERT INTO ${table}(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`).bind(...Object.values(row)));
 }
 for(const type of ['index','view','trigger'])for(const item of before.schema.filter(x=>x.type===type))statements.push(db.prepare(item.sql));
 await db.batch(statements);
}
