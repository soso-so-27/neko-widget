import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import type { Env } from "../src/env";
import { beginAppleNotificationHistoryRecovery, claimAppleNotificationHistoryRecovery,
  commitAppleNotificationHistoryPage, getAppleNotificationHistoryRecoveryState,
  retryAppleNotificationHistoryRecovery, releaseExpiredAppleNotificationHistoryLease,
} from "../src/billing-notification-history-state";

it("partitions history generations, equal receipts, lease failures and expiry by environment",async()=>{
  const settings={...env,BILLING_STORE_ENVIRONMENT:"Production"} as unknown as Env;
  const now=Math.floor(Date.now()/1000),uuid=crypto.randomUUID(),hash="A".repeat(43);
  await settings.DB.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,
    apple_notification_history_recovery_enabled=1,updated_at=unixepoch() WHERE singleton=1`).run();
  for(const environment of ["Production","Sandbox"] as const){
    await settings.DB.prepare(`INSERT INTO billing_apple_notification_events(notification_uuid,payload_hash,notification_type,
      signed_date_ms,environment,relevance) VALUES(?,?,'TEST',?,?,'ignored')`).bind(uuid,hash,now*1000,environment).run();
    expect(await beginAppleNotificationHistoryRecovery(settings,{expectedGeneration:0,storeEnvironment:environment,
      bundleId:"jp.nekowidget.app",frozenStartDateMs:(now-60)*1000,frozenEndDateMs:(now+60)*1000},now)).toBe(true);
  }
  const paid=await claimAppleNotificationHistoryRecovery(settings,now);
  const sandbox=await claimAppleNotificationHistoryRecovery(settings,now,"Sandbox");
  expect(paid).toMatchObject({storeEnvironment:"Production",generation:1});
  expect(sandbox).toMatchObject({storeEnvironment:"Sandbox",generation:1});
  const page={hasMore:false,nextPaginationCursor:null,records:[{notificationUUID:uuid,payloadHash:hash}]};
  await expect(commitAppleNotificationHistoryPage(settings,{...paid!,storeEnvironment:"Sandbox"},page,now)).rejects.toThrow();
  expect(await getAppleNotificationHistoryRecoveryState(settings,"Sandbox")).toMatchObject({state:"leased",leaseToken:sandbox!.leaseToken,committedPageCount:0});
  await commitAppleNotificationHistoryPage(settings,paid!,page,now);
  await commitAppleNotificationHistoryPage(settings,sandbox!,page,now);
  expect(await settings.DB.prepare("SELECT environment,generation,page_index FROM billing_apple_notification_history_page_records ORDER BY environment").all())
    .toMatchObject({results:[{environment:"Production",generation:1,page_index:1},{environment:"Sandbox",generation:1,page_index:1}]});
  for(const environment of ["Production","Sandbox"] as const){
    expect(await beginAppleNotificationHistoryRecovery(settings,{expectedGeneration:1,storeEnvironment:environment,
      bundleId:"jp.nekowidget.app",frozenStartDateMs:(now-60)*1000,frozenEndDateMs:(now+60)*1000},now)).toBe(true);
  }
  const paidNext=await claimAppleNotificationHistoryRecovery(settings,now);
  const sandboxNext=await claimAppleNotificationHistoryRecovery(settings,now,"Sandbox");
  expect(await retryAppleNotificationHistoryRecovery(settings,paidNext!,"synthetic_retry",now)).toBe(true);
  expect(await getAppleNotificationHistoryRecoveryState(settings,"Sandbox")).toMatchObject({state:"leased",leaseToken:sandboxNext!.leaseToken,attempts:0});
  expect(await releaseExpiredAppleNotificationHistoryLease(settings,now+600)).toBe(false);
  expect(await releaseExpiredAppleNotificationHistoryLease(settings,now+600,"Sandbox")).toBe(true);
  expect(await getAppleNotificationHistoryRecoveryState(settings)).toMatchObject({state:"retry_wait",generation:2,attempts:1});
});
