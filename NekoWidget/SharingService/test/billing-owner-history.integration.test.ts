import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { runAppleNotificationHistoryRecovery as run } from '../src/billing-notification-history-recovery';
import { getAppleNotificationHistoryRecoveryState as state } from '../src/billing-notification-history-state';
import { ingestVerifiedAppleBillingNotification as ingest } from '../src/billing-authority';
import { base64urlEncode } from '../src/encoding';
import type { Env } from '../src/env';
import type { VerifiedAppleNotificationHistoryRecord as Record, AppleNotificationHistoryPageRequest as Request } from '../src/billing-apple-client';
const dbEnv=env as unknown as Env;
const owner='17b8ac72-0000-4000-8000-000000000181',other='17b8ac72-0000-4000-8000-000000000182';
const bootstrap='17b8ac72-0000-4000-8000-000000000183';
const cursor=`nh1.integration.${'A'.repeat(43)}`;
function record(n:number,account:string,signed:number):Record {
 const id=`2200000000001${n}`;
 return {payloadHash:String.fromCharCode(65+n).repeat(43),notification:{notificationUUID:`b113ede5-4eba-4e06-8a9d-${String(n).padStart(12,'0')}`,
 notificationType:'DID_RENEW',subtype:null,signedDateMs:signed,environment:'Sandbox',bundleId:'jp.nekowidget.app',status:1,relevant:true,renewal:null,
 transaction:{transactionId:id,originalTransactionId:id,billingAccountId:account,productId:'jp.nekowidget.plus.monthly',subscriptionGroupId:'20999999',
 bundleId:'jp.nekowidget.app',environment:'Sandbox',ownershipType:'PURCHASED',transactionReason:'RENEWAL',purchaseDateMs:signed-1000,
 originalPurchaseDateMs:signed-1000,expiresDateMs:signed+86400000,signedDateMs:signed,revocationDateMs:null,revocationReason:null,isUpgraded:false}}};
}
const page=(r:Request,records:Record[],more=false)=>({requestedStartDateMs:r.startDateMs,requestedEndDateMs:r.endDateMs,
 environment:'Sandbox' as const,bundleId:'jp.nekowidget.app',records,hasMore:more,nextPaginationToken:more?cursor:null});
it('advances mixed owner pages without storing other purchasers and preserves retries and admission',async()=>{
 const key=base64urlEncode(new Uint8Array(16).fill(8)),pub=new Uint8Array(32).fill(11);
 await dbEnv.DB.batch([
 dbEnv.DB.prepare('INSERT INTO billing_accounts(id) VALUES (?)').bind(owner),
 dbEnv.DB.prepare('INSERT INTO billing_accounts(id) VALUES (?)').bind(other),
 dbEnv.DB.prepare("INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state) VALUES (?,?,?,'active')").bind(key,owner,base64urlEncode(pub)),
 dbEnv.DB.prepare('INSERT INTO billing_account_bootstrap_requests(client_request_id,request_hash,billing_account_id,billing_key_id) VALUES (?,?,?,?)').bind(bootstrap,'B'.repeat(43),owner,key),
 dbEnv.DB.prepare('UPDATE billing_runtime_gate SET generation=generation+1,apple_notification_history_recovery_enabled=1,updated_at=unixepoch() WHERE singleton=1')]);
 const fingerprint=[...new Uint8Array(await crypto.subtle.digest('SHA-256',pub))].map(x=>x.toString(16).padStart(2,'0')).join('');
 const policy={version:1,bootstrapClientRequestId:bootstrap,initialPublicKeySHA256:fingerprint,startsAtMs:Date.now()-1000,expiresAtMs:Date.now()+600000};
 const value={...dbEnv,ENVIRONMENT:'local',BILLING_STORE_ENVIRONMENT:'Sandbox',BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES',
 BILLING_SANDBOX_OWNER_ADMISSION:JSON.stringify(policy),BILLING_APPLE_NOTIFICATION_HISTORY_RECOVERY_RUNTIME_ENABLED:'YES',
 BILLING_VERIFIER_ORIGIN:'http://127.0.0.1:8080',BILLING_VERIFIER_SHARED_SECRET:'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
 BILLING_BUNDLE_ID:'jp.nekowidget.app',BILLING_SUBSCRIPTION_GROUP_ID:'20999999',BILLING_MONTHLY_PRODUCT_ID:'jp.nekowidget.plus.monthly',BILLING_ANNUAL_PRODUCT_ID:'jp.nekowidget.plus.annual'} as Env;
 const now=Math.floor(Date.now()/1000),signed=(now-700)*1000;
 const foreign=record(1,other,signed),own=record(2,owner,signed),own2=record(3,owner,signed),unrelated=record(4,other,signed);
 unrelated.notification={...unrelated.notification,notificationType:'TEST',relevant:false,transaction:null,status:null};
 await expect(ingest(value,foreign.notification,foreign.payloadHash)).rejects.toMatchObject({code:'billing_owner_admission_required'});
 let interrupted=true;
 const consumer=async(e:Env,r:Record)=>{if(r.payloadHash===own2.payloadHash&&interrupted){interrupted=false;throw new Error('synthetic interruption');}await ingest(e,r.notification,r.payloadHash);};
 const fetch=async(r:Request)=>page(r,[foreign,own,unrelated,own2],true);
 await run(value,fetch,consumer,now,now);
 expect(await state(value)).toMatchObject({state:'retry_wait',paginationCursor:null,committedRecordCount:0});
 await run(value,fetch,consumer,now+30,now+30);
 expect(await state(value)).toMatchObject({state:'ready',paginationCursor:cursor,committedPageCount:1,committedRecordCount:2});
 expect(await dbEnv.DB.prepare('SELECT billing_account_id FROM billing_transaction_lineages ORDER BY original_transaction_id').all()).toMatchObject({results:[{billing_account_id:owner},{billing_account_id:owner}]});
 for(const table of ['billing_apple_notification_events','billing_apple_notification_history_page_records','billing_apple_notification_reconciliation_causes'])
 expect(await dbEnv.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first()).toEqual({n:2});
 await run(value,async r=>{expect(r.paginationToken).toBe(cursor);return page(r,[foreign,unrelated]);},undefined,now+30,now+30);
 expect(await state(value)).toMatchObject({state:'completed',committedPageCount:2,committedRecordCount:2});
 expect(await dbEnv.DB.prepare('SELECT record_count FROM billing_apple_notification_history_page_commits ORDER BY page_index').all()).toMatchObject({results:[{record_count:2},{record_count:0}]});
 await run(value,async r=>{value.BILLING_SANDBOX_OWNER_ADMISSION=JSON.stringify({...policy,expiresAtMs:Date.now()-1});return page(r,[foreign]);},undefined,now+900,now+900);
 expect(await state(value)).toMatchObject({state:'retry_wait',committedPageCount:0,committedRecordCount:0});
 value.BILLING_SANDBOX_OWNER_ADMISSION=JSON.stringify({...policy,bootstrapClientRequestId:crypto.randomUUID()});
 await run(value,async r=>page(r,[foreign]),undefined,now+930,now+930);
 expect(await state(value)).toMatchObject({state:'retry_wait',committedPageCount:0,committedRecordCount:0});
 expect(await dbEnv.DB.prepare('SELECT COUNT(*) AS n FROM billing_apple_notification_events').first()).toEqual({n:2});
});
