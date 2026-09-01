import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import type { Env } from "../src/env";
import { route } from "../src/index";

const headerNames = [
  "neko-runtime-billing-account-bootstrap",
  "neko-runtime-billing-transaction-ingestion",
  "neko-runtime-billing-apple-notification-ingestion",
  "neko-runtime-billing-apple-notification-history-recovery",
  "neko-runtime-billing-subscription-reconciliation",
  "neko-runtime-billing-effective-entitlement",
  "neko-runtime-billing-window-sponsorship",
  "neko-runtime-billing-account-recovery",
] as const;

interface BillingGateRow {
  generation: number;
  account_bootstrap_enabled: number;
  transaction_ingestion_enabled: number;
  apple_notification_ingestion_enabled: number;
  apple_notification_history_recovery_enabled: number;
  subscription_reconciliation_enabled: number;
  effective_entitlement_enabled: number;
  window_sponsorship_enabled: number;
  account_recovery_enabled: number;
}

const gateColumns = [
  "account_bootstrap_enabled",
  "transaction_ingestion_enabled",
  "apple_notification_ingestion_enabled",
  "apple_notification_history_recovery_enabled",
  "subscription_reconciliation_enabled",
  "effective_entitlement_enabled",
  "window_sponsorship_enabled",
  "account_recovery_enabled",
] as const;

describe("billing runtime health attestation", () => {
  it("reports every effective billing gate without identifiers", async () => {
    const testEnv = env as unknown as Env;
    const prior = await testEnv.DB.prepare(
      `SELECT generation, ${gateColumns.join(", ")}
         FROM billing_runtime_gate
        WHERE singleton=1`,
    ).first<BillingGateRow>();
    expect(prior).not.toBeNull();
    if (prior === null) throw new Error("billing runtime gate fixture missing");
    for (const name of gateColumns) expect(prior[name]).toBe(0);

    const closed = await route(
      new Request("https://sharing.invalid/health"),
      testEnv,
    );
    expect(closed.headers.get("neko-runtime-billing-gate-generation"))
      .toBe(String(prior.generation));
    for (const name of headerNames) expect(closed.headers.get(name)).toBe("OFF");
    expect(closed.headers.get("neko-runtime-billing-apple-notification-rate-limiter"))
      .toBe("MISSING");

    const changed = await testEnv.DB.prepare(
      `UPDATE billing_runtime_gate
          SET generation=generation+1,
              account_bootstrap_enabled=1,
              transaction_ingestion_enabled=1,
              apple_notification_ingestion_enabled=1,
              apple_notification_history_recovery_enabled=1,
              subscription_reconciliation_enabled=1,
              effective_entitlement_enabled=1,
              window_sponsorship_enabled=1,
              account_recovery_enabled=1,
              updated_at=unixepoch()
        WHERE singleton=1 AND generation=?`,
    ).bind(prior.generation).run();
    expect(changed.meta.changes).toBe(1);
    try {
      const upperGates = {
        ...testEnv,
        BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED: "YES",
        BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED: "YES",
        BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED: "YES",
        BILLING_APPLE_NOTIFICATION_HISTORY_RECOVERY_RUNTIME_ENABLED: "YES",
        BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED: "YES",
        BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "YES",
        BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED: "YES",
        BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED: "YES",
      };
      const missingLimiter = await route(
        new Request("https://sharing.invalid/health"),
        upperGates,
      );
      expect(missingLimiter.headers.get("neko-runtime-billing-apple-notification-ingestion"))
        .toBe("OFF");
      expect(missingLimiter.headers.get("neko-runtime-billing-apple-notification-rate-limiter"))
        .toBe("MISSING");

      const enabled = await route(
        new Request("https://sharing.invalid/health"),
        {
          ...upperGates,
          BILLING_APPLE_NOTIFICATION_RATE_LIMITER: {
            async limit() { return { success: true }; },
          },
        },
      );
      expect(enabled.headers.get("neko-runtime-billing-gate-generation"))
        .toBe(String(prior.generation + 1));
      for (const name of headerNames) expect(enabled.headers.get(name)).toBe("ON");
      expect(enabled.headers.get("neko-runtime-billing-apple-notification-rate-limiter"))
        .toBe("READY");
      let serialized = "";
      enabled.headers.forEach((value, name) => { serialized += `${name}:${value}\n`; });
      expect(serialized).not.toMatch(/account-id|database-id|token|secret|jws/iu);
    } finally {
      const restored = await testEnv.DB.prepare(
        `UPDATE billing_runtime_gate
            SET generation=generation+1,
                account_bootstrap_enabled=0,
                transaction_ingestion_enabled=0,
                apple_notification_ingestion_enabled=0,
                apple_notification_history_recovery_enabled=0,
                subscription_reconciliation_enabled=0,
                effective_entitlement_enabled=0,
                window_sponsorship_enabled=0,
                account_recovery_enabled=0,
                updated_at=unixepoch()
          WHERE singleton=1 AND generation=?`,
      ).bind(prior.generation + 1).run();
      expect(restored.meta.changes).toBe(1);
    }
  });
});
