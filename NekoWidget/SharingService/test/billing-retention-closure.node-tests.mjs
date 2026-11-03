import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { populatedRetentionLedger, snapshot, restoreD1, target, other } from './fixtures/billing-retention-ledger.mjs';

const bundled = await build({ stdin: { contents:
  "export * from './src/billing-retention-executor.ts'; export * from './src/billing-retention-journal.ts'; export * from './src/billing-recovery.ts'; export * from './src/billing-protocol.ts'; export * from './src/encoding.ts'; export * from './src/billing.ts'; export * from './src/billing-authority.ts'; export * from './src/billing-retention-api.ts'; export * from './src/billing-entitlement.ts';",
  resolveDir: process.cwd(), loader: 'ts' }, bundle: true, platform: 'node', format: 'esm', write: false });
const code = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString('base64')}`);
const prefix='__billing_retention/v1/';

test('actual D1 FK closure, other payer/family/R2 preservation, interruption and restored-snapshot receipt recheck', {timeout:180000}, async()=>{
  const sqlite=populatedRetentionLedger();
  const before=snapshot(sqlite);
  for(const [table,predicate] of code.billingRetentionEraseSteps) {
    assert.ok(sqlite.prepare(`SELECT COUNT(*) n FROM ${table} WHERE ${predicate}`).get(target).n>0,`missing dependency fixture ${table}`);
  }
  assert.deepEqual(sqlite.prepare('PRAGMA foreign_key_check').all(),[]);
  sqlite.close();
  const mf=new Miniflare(convertV4MiniflareOptions({cf:false,modules:true,compatibilityDate:'2026-08-17',
    script:'export default { fetch() { return new Response(null,{status:404}); } };',
    d1Databases:{DB:'billing-retention-working',RESTORE:'billing-retention-restored'},r2Buckets:{MEDIA:'billing-retention-journal-local'}}));
  try {
    const DB=await mf.getD1Database('DB'), RESTORE=await mf.getD1Database('RESTORE'),MEDIA=await mf.getR2Bucket('MEDIA');
    await restoreD1(DB,before);
    await restoreD1(RESTORE,before);
    await MEDIA.put(`${prefix}control`,JSON.stringify({version:1,deployment:'local',sequence:0}));
    await MEDIA.put('group-media/other-owner/object','untouched ciphertext');
    const env={DB,MEDIA,ENVIRONMENT:'local',BILLING_TRANSACTION_RETENTION_REQUIRED:'YES'};
    const journal=new code.BillingRetentionJournal(MEDIA);
    const now=Date.now();
    const entry=await journal.append({requestId:crypto.randomUUID(),billingAccountId:target,receiptHash:'R'.repeat(43),
      reason:'account-deletion',requestedAtMs:now,endedAtMs:null,cutoffMs:now,expectedRevision: 0, factsHash:'F'.repeat(43)});
    assert.equal(await code.billingDeletionCompleted(env,entry),false);
    await assert.rejects(code.requireBillingRetentionSnapshot(env),{code:'billing_retention_recovery_required'});
    // One bounded invocation makes progress but must not claim completion.
    await code.runBillingTransactionDeletion(env,now+1,5);
    assert.equal(await code.billingDeletionCompleted(env,entry),false);
    assert.equal((await DB.prepare("SELECT count(*) n FROM group_verified_plus_people WHERE person_id='person-a'").first()).n,0);
    await assert.rejects(code.requireBillingAccountNotErasing(env,target),{code:'billing_account_erased'});
    await code.requireBillingAccountNotErasing(env,other);
    // A fresh executor instance resumes the same durable receipt.
    let failCompletion=true;
    const interrupted={...env,MEDIA:{get:MEDIA.get.bind(MEDIA),put:async(key,...args)=>{
      if(failCompletion && key===prefix+'completed/'+entry.requestId){failCompletion=false;throw new Error('synthetic completion interruption');}
      return MEDIA.put(key,...args);
    }}};
    await assert.rejects(code.runBillingTransactionDeletion(interrupted,now+2),/synthetic completion interruption/);
    assert.equal(await code.billingDeletionCompleted(env,entry),false,'D1 completion alone is not an independent receipt');
    await code.runBillingTransactionDeletion({...env},now+2);
    assert.equal(await code.billingDeletionCompleted(env,entry),true);
    assert.equal(await code.remainingBillingTransactionRows(env,target),0);
    assert.deepEqual((await DB.prepare('PRAGMA foreign_key_check').all()).results,[]);
    for(const table of Object.keys(before.rows).filter(n=>n.startsWith('family_notebook_') || n.startsWith('moment_') || n.startsWith('group_'))) {
      const actual=(await DB.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all()).results;
      assert.deepEqual(actual,before.rows[table],`other/shared data changed: ${table}`);
    }
    for(const [table] of code.billingRetentionEraseSteps) {
      const columns=(await DB.prepare(`PRAGMA table_info(${table})`).all()).results;
      if(columns.some(c=>c.name==='billing_account_id')) {
        assert.deepEqual((await DB.prepare(`SELECT * FROM ${table} WHERE billing_account_id=? ORDER BY rowid`).bind(other).all()).results,
          before.rows[table].filter(r=>r.billing_account_id===other),`other billing rows changed: ${table}`);
      }
    }
    const history=(await DB.prepare('SELECT notification_uuid FROM billing_apple_notification_history_page_records').all()).results;
    assert.deepEqual(history,[{notification_uuid:'30000000-0000-4000-8000-000000000002'}]);
    assert.equal(await (await MEDIA.get('group-media/other-owner/object')).text(),'untouched ciphertext');
    // Restore the complete old schema/data to another D1 while R2 survives unchanged.
    const restored={...env,DB:RESTORE};
    assert.equal((await RESTORE.prepare("SELECT count(*) n FROM group_verified_plus_people WHERE person_id='person-a'").first()).n,1);
    assert.equal(await code.billingDeletionCompleted(restored,entry),false);
    await assert.rejects(code.requireBillingRetentionSnapshot(restored),{code:'billing_retention_recovery_required'});
    await assert.rejects(code.effectiveBillingEntitlement(restored,target),{code:'billing_retention_recovery_required'});
    await code.reconcileBillingRetentionJournal(restored);
    await code.requireBillingRetentionSnapshot(restored);
    assert.equal(await code.billingDeletionCompleted(restored,entry),false,'same control sequence with older deleting state is not completion');
    await code.runBillingTransactionDeletion(restored,now+3);
    assert.equal(await code.billingDeletionCompleted(restored,entry),true);
    assert.equal(await code.remainingBillingTransactionRows(restored,target),0);
    assert.deepEqual((await RESTORE.prepare('PRAGMA foreign_key_check').all()).results,[]);
    assert.equal((await RESTORE.prepare("SELECT count(*) n FROM group_verified_plus_people WHERE person_id='person-a'").first()).n,0);
    assert.equal(await code.billingAccountRetentionCandidate({...env,DB:RESTORE},other,Date.now()),null,'active payer cannot expire');
    const transaction={transactionId:'900000000001002',originalTransactionId:'900000000001001',billingAccountId:target,
      productId:'jp.nekowidget.plus.monthly',subscriptionGroupId:'20999999',bundleId:'jp.nekowidget.app',environment:'Production',
      ownershipType:'PURCHASED',transactionReason:'PURCHASE',purchaseDateMs:now-100000,originalPurchaseDateMs:now-100000,
      expiresDateMs:now+3600000,signedDateMs:now,revocationDateMs:null,revocationReason:null,isUpgraded:false};
    await assert.rejects(code.storeVerifiedTransaction(env,transaction,{kind:'apple_notification'}),{code:'billing_account_erased'});
    const oldNotification={notificationUUID:crypto.randomUUID(),notificationType:'DID_RENEW',subtype:null,signedDateMs:now,
      environment:'Production',status:1,relevant:true,transaction,renewal:null};
    await code.ingestVerifiedAppleBillingNotification(env,oldNotification,'H'.repeat(43));
    const ignored=await DB.prepare('SELECT relevance,transaction_id,original_transaction_id,billing_account_id FROM billing_apple_notification_events WHERE notification_uuid=?')
      .bind(oldNotification.notificationUUID).first();
    assert.deepEqual(ignored,{relevance:'ignored',transaction_id:null,original_transaction_id:null,billing_account_id:null});
    assert.equal(await code.billingDeletionCompleted(env,entry),true);
    await DB.prepare('UPDATE billing_runtime_gate SET generation=generation+1,account_recovery_enabled=1,updated_at=unixepoch()').run();
    const keys=await crypto.subtle.generateKey({name:'Ed25519'},true,['sign','verify']);
    const publicKey=Buffer.from(await crypto.subtle.exportKey('raw',keys.publicKey)).toString('base64url');
    const clientRequestId=crypto.randomUUID(), deviceVerificationId=crypto.randomUUID();
    const recovery={protocolVersion:1,clientRequestId,billingAccountId:target,signingPublicKey:publicKey,deviceVerificationId,
      expectedAppTransactionId:'synthetic-app-id',signedAppTransactionInfo:'a.b.c',signedTransactionInfo:'d.e.f',
      expectedTransactionId:transaction.transactionId,expectedOriginalTransactionId:transaction.originalTransactionId};
    const transcript=code.billingAccountRecoveryTranscript({...recovery,
      signedAppTransactionHash:await code.retentionDigest('a.b.c'),signedTransactionHash:await code.retentionDigest('d.e.f')});
    recovery.recoverySignature=Buffer.from(await crypto.subtle.sign('Ed25519',keys.privateKey,transcript)).toString('base64url');
    const recoveryRequest=()=>new Request('https://example.test/v1/billing/accounts/recover',{
      method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(recovery)});
    const verify=async()=>({transaction,appTransactionIdHash:'A'.repeat(43)});
    const authority=()=>({environment:'Production',bundleId:'jp.nekowidget.app',fetchedAtMs:Date.now(),items:[{
      originalTransactionId:transaction.originalTransactionId,status:1,transaction,
      renewal:{environment:'Production',originalTransactionId:transaction.originalTransactionId,billingAccountId:target,productId:transaction.productId,autoRenewProductId:transaction.productId,autoRenewStatus:1,isInBillingRetryPeriod:false,gracePeriodExpiresDateMs:null,renewalDateMs:transaction.expiresDateMs,signedDateMs:transaction.signedDateMs}}]});
    await assert.rejects(code.recoverBillingAccount(recoveryRequest(),env,verify,async()=>({...authority(),environment:'Sandbox'})),
      {code:'billing_recovery_authority_denied'});
    await assert.rejects(code.recoverBillingAccount(recoveryRequest(),env,verify,async()=>({...authority(),fetchedAtMs:now-120000})),
      {code:'billing_recovery_authority_denied'});
    assert.equal((await code.billingRetentionFence(env,target)).state,'closed');
    const recovered=await (await code.recoverBillingAccount(recoveryRequest(),env,verify,async()=>authority())).json();
    assert.equal(recovered.billingAccountId,target);
    await DB.prepare('UPDATE billing_runtime_gate SET generation=generation+1,subscription_reconciliation_enabled=1,effective_entitlement_enabled=1,updated_at=unixepoch()').run();
    const bothStores={...env,BILLING_STORE_ENVIRONMENT:'Production',BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'YES'};
    await code.runBillingSubscriptionReconciliation(bothStores,async()=>authority());
    const productionRight=await DB.prepare("SELECT * FROM billing_effective_entitlement_current WHERE billing_account_id=? AND environment='Production'").bind(target).first();
    assert.equal(productionRight?.materialized_grants_plus,1,'fresh explicit Production recovery can regain rights');
    await code.ingestVerifiedAppleBillingNotification(bothStores,{...oldNotification,notificationUUID:crypto.randomUUID(),
      notificationType:'REVOKE',environment:'Sandbox',status:5,transaction:{...transaction,environment:'Sandbox',revocationDateMs:Date.now(),revocationReason:1}},'S'.repeat(43));
    assert.deepEqual(await DB.prepare("SELECT * FROM billing_effective_entitlement_current WHERE billing_account_id=? AND environment='Production'").bind(target).first(),productionRight,
      'Sandbox revocation cannot remove recovered active Production authority');
    await code.storeVerifiedTransaction(env,transaction,{kind:'apple_notification'});
    assert.equal(await code.billingDeletionCompleted(env,entry),true,'old completed receipt remains valid for authorized new era');
    await assert.rejects(code.storeVerifiedTransaction(env,{...transaction,environment:'Sandbox'},{kind:'apple_notification'}),{code:'billing_retention_old_transaction'});
    await assert.rejects(code.storeVerifiedTransaction(env,{...transaction,transactionId:'900000000000000'},{kind:'apple_notification'}),{code:'billing_retention_old_transaction'});
    const allowed=await DB.prepare('SELECT environment,lineage_hash,transaction_hash FROM billing_retention_recoveries').all();
    assert.equal(allowed.results.length,1); assert.equal(allowed.results[0].environment,'Production');
    assert.ok(!JSON.stringify(allowed.results).includes(transaction.originalTransactionId));
    // A genuine signed deletion API request immediately precedes ordinary retention.
    const receipt=Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url'), deletionId=crypto.randomUUID();
    const deletionBody=JSON.stringify({protocolVersion:1,clientRequestId:deletionId,receipt});
    const timestamp=Math.floor(Date.now()/1000),nonce=Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('base64url');
    const deletionTranscript=code.billingSignedRequestTranscript({billingAccountId:target,billingKeyId:recovered.billingKeyId,
      timestamp,nonce,method:'POST',pathname:'/v1/billing/transaction-deletion-requests',bodySHA256:await code.retentionDigest(deletionBody)});
    const signature=Buffer.from(await crypto.subtle.sign('Ed25519',keys.privateKey,deletionTranscript)).toString('base64url');
    const request=new Request('https://example.test/v1/billing/transaction-deletion-requests',{method:'POST',body:deletionBody,
      headers:{'content-type':'application/json','neko-billing-protocol-version':'1','neko-billing-account-id':target,
      'neko-billing-key-id':recovered.billingKeyId,'neko-billing-timestamp':String(timestamp),'neko-billing-nonce':nonce,'neko-billing-signature':signature}});
    const accepted=await code.requestBillingTransactionDeletion(request,env); assert.equal(accepted.status,202);
    const statusRequest=new Request('https://example.test/',{headers:{Authorization:'Bearer '+receipt}});
    assert.equal((await (await code.billingTransactionDeletionStatus(statusRequest,env,deletionId)).json()).state,'processing');
    await code.runBillingTransactionDeletion(env,Date.now()+1);
    assert.equal((await (await code.billingTransactionDeletionStatus(statusRequest,env,deletionId)).json()).state,'completed');
    await assert.rejects(code.billingTransactionDeletionStatus(new Request('https://example.test/',{headers:{Authorization:'Bearer '+'A'.repeat(43)}}),env,deletionId),{code:'invalid_deletion_receipt'});
    assert.equal(await code.remainingBillingTransactionRows(env,target),0);
    assert.deepEqual((await DB.prepare('PRAGMA foreign_key_check').all()).results,[]);
    // A verified renewal already in flight can commit after external publication,
    // before the local fence. Its revision cancels ordinary expiry atomically.
    const revision=(await DB.prepare('SELECT revision FROM billing_retention_account_revisions WHERE billing_account_id=?').bind(other).first()).revision;
    const canceled=await journal.append({requestId:crypto.randomUUID(),billingAccountId:other,receiptHash:'C'.repeat(43),
      reason:'subscription-ended',requestedAtMs:Date.now(),endedAtMs:now-400*86400000,cutoffMs:now,
      expectedRevision:revision,factsHash:'D'.repeat(43)});
    const otherEvent=await DB.prepare('SELECT * FROM billing_transaction_events WHERE billing_account_id=? LIMIT 1').bind(other).first();
    const columns=Object.keys(otherEvent);
    await DB.prepare(`INSERT INTO billing_transaction_events(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`)
      .bind(...columns.map(c=>c==='event_fingerprint'?'Z'.repeat(43):c==='signed_date_ms'?now+1:otherEvent[c])).run();
    await code.reconcileBillingRetentionJournal(env);
    assert.equal(await journal.canceled(canceled),true);
    assert.equal((await DB.prepare('SELECT state FROM billing_retention_requests WHERE request_id=?').bind(canceled.requestId).first()).state,'canceled');
    assert.equal(await code.billingDeletionCompleted(env,canceled),false);
    assert.equal(await DB.prepare('SELECT state FROM billing_retention_fences WHERE billing_account_id=?').bind(other).first(),null);
    assert.ok(await code.remainingBillingTransactionRows(env,other)>0);
    // This older D1 has neither the new renewal nor the canceled receipt. R2
    // cancellation must prevent reclassifying the restored old facts as deletion.
    await code.reconcileBillingRetentionJournal(restored);
    assert.equal((await RESTORE.prepare('SELECT state FROM billing_retention_requests WHERE request_id=?').bind(canceled.requestId).first()).state,'canceled');
    assert.ok(await code.remainingBillingTransactionRows(restored,other)>0);
    // SQL-level recovery race must abort before any key rotation or allow-row.
    const keyBefore=await DB.prepare('SELECT generation FROM billing_account_key_state WHERE billing_account_id=?').bind(target).first();
    await assert.rejects(DB.batch([
      DB.prepare(`UPDATE billing_retention_fences SET state='active',recovery_environment='Production',recovery_lineage_hash=?,recovery_transaction_hash=?,recovery_request_id=? WHERE billing_account_id=? AND sequence=?`)
        .bind('L'.repeat(43),'T'.repeat(43),crypto.randomUUID(),target,entry.sequence),
      DB.prepare(`INSERT INTO billing_retention_recoveries VALUES(?,?,'Production',?,?,?)`).bind(target,entry.sequence,'L'.repeat(43),'T'.repeat(43),crypto.randomUUID()),
      DB.prepare('UPDATE billing_account_key_state SET generation=generation+1 WHERE billing_account_id=?').bind(target),
    ]),/retention recovery fence changed/);
    assert.deepEqual(await DB.prepare('SELECT generation FROM billing_account_key_state WHERE billing_account_id=?').bind(target).first(),keyBefore);


  } finally { await mf.dispose(); }
});
