import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import { runAppleNotificationHistoryRecovery as run } from "../src/billing-notification-history-recovery";
import { getAppleNotificationHistoryRecoveryState as state } from "../src/billing-notification-history-state";
import type { AppleNotificationHistoryPageRequest, VerifiedAppleNotificationHistoryPage } from "../src/billing-apple-client";
import type { Env } from "../src/env";

const dual = { ...env, ENVIRONMENT: "local", BILLING_STORE_ENVIRONMENT: "Production",
  BILLING_ACCEPT_SANDBOX_IN_PRODUCTION: "YES", BILLING_APPLE_NOTIFICATION_HISTORY_RECOVERY_RUNTIME_ENABLED: "YES",
  BILLING_VERIFIER_ORIGIN: "http://127.0.0.1:8080",
  BILLING_VERIFIER_SHARED_SECRET: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
  BILLING_BUNDLE_ID: "jp.nekowidget.app", BILLING_SUBSCRIPTION_GROUP_ID: "20999999",
  BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly" } as unknown as Env;
async function openHistory() {
  await dual.DB.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,
    apple_notification_history_recovery_enabled=1,updated_at=unixepoch() WHERE singleton=1`).run();
}
function page(request: AppleNotificationHistoryPageRequest): VerifiedAppleNotificationHistoryPage {
  if (!request.storeEnvironment) throw new Error("a dual history claim requires a verified environment");
  return { requestedStartDateMs: request.startDateMs, requestedEndDateMs: request.endDateMs,
    environment: request.storeEnvironment, bundleId: "jp.nekowidget.app", hasMore: false,
    nextPaginationToken: null, records: [] };
}
it("alternates one page per tick and isolates retry, cursor and frozen windows", async () => {
  await openHistory();
  const now = Math.ceil(Date.now() / 600_000) * 600;
  const requests: AppleNotificationHistoryPageRequest[] = [];
  const fetchPage = async (r: AppleNotificationHistoryPageRequest) => {
    requests.push(r);
    if (requests.length === 1) throw new Error("synthetic Production outage");
    return page(r);
  };
  await run(dual, fetchPage, undefined, now, now);
  expect(requests).toHaveLength(1);
  expect(await state(dual, "Production")).toMatchObject({state:"retry_wait",committedPageCount:0});
  expect(await state(dual, "Sandbox")).toMatchObject({state:"idle",committedPageCount:0});
  await run(dual, fetchPage, undefined, now+300, now+300);
  expect(requests).toHaveLength(2);
  expect(requests[1]?.storeEnvironment).toBe("Sandbox");
  expect(await state(dual, "Sandbox")).toMatchObject({state:"completed",committedPageCount:1});
  expect(await state(dual, "Production")).toMatchObject({state:"retry_wait",committedPageCount:0});
  await run(dual, fetchPage, undefined, now+600, now+600);
  expect(requests).toHaveLength(3);
  expect(requests[2]).toEqual(requests[0]);
  expect(await state(dual, "Production")).toMatchObject({state:"completed",committedPageCount:1});
  const rows = await dual.DB.prepare(`SELECT environment,record_count FROM billing_apple_notification_history_page_commits ORDER BY environment`).all();
  expect(rows.results).toEqual([{environment:"Production",record_count:0},{environment:"Sandbox",record_count:0}]);
  // Advance to a later Production window; the just-completed frozen window
  // correctly causes no fetch at the same tick.
  let ingests = 0, wrongPageFetches = 0;
  await run(dual, async r => { wrongPageFetches++; return { ...page(r), environment:"Sandbox" }; },
    async () => { ingests++; }, now+1200, now+1200);
  expect(wrongPageFetches).toBe(1);
  expect(ingests).toBe(0);
  expect(await state(dual,"Production")).toMatchObject({state:"blocked",committedPageCount:0,lastErrorCode:"billing_verifier_invalid_response"});
  expect(await state(dual,"Sandbox")).toMatchObject({state:"completed",committedPageCount:1});
});
