import { describe, expect, it } from "vitest";

import type { VerifiedSubscriptionStatusItem } from "../src/billing-apple-client";
import {
  BILLING_AUTHORITY_FRESHNESS_MS,
  evaluateAuthoritativeStatusItem,
  selectAuthoritativeStatusItem,
} from "../src/billing-entitlement";

const now = 2_000_000_000_000;

function item(
  status: 1 | 2 | 3 | 4 | 5,
  overrides: {
    expiresDateMs?: number;
    gracePeriodExpiresDateMs?: number | null;
    ownershipType?: "PURCHASED" | "FAMILY_SHARED";
    revocationDateMs?: number | null;
    revocationReason?: 0 | 1 | null;
    isUpgraded?: boolean;
    transactionSignedDateMs?: number;
    renewalSignedDateMs?: number;
    transactionId?: string;
  } = {},
): VerifiedSubscriptionStatusItem {
  const originalTransactionId = "220000000000001";
  return {
    status,
    originalTransactionId,
    transaction: {
      transactionId: overrides.transactionId ?? originalTransactionId,
      originalTransactionId,
      billingAccountId: "5f30c0de-0000-4000-8000-000000000201",
      productId: "jp.nekowidget.plus.monthly",
      subscriptionGroupId: "20999999",
      bundleId: "jp.nekowidget.app",
      environment: "Sandbox",
      ownershipType: overrides.ownershipType ?? "PURCHASED",
      transactionReason: "RENEWAL",
      purchaseDateMs: now - 1_000,
      originalPurchaseDateMs: now - 2_000,
      expiresDateMs: overrides.expiresDateMs ?? now + 60_000,
      signedDateMs: overrides.transactionSignedDateMs ?? now - 500,
      revocationDateMs: overrides.revocationDateMs ?? null,
      revocationReason: overrides.revocationReason ?? null,
      isUpgraded: overrides.isUpgraded ?? false,
    },
    renewal: {
      originalTransactionId,
      billingAccountId: "5f30c0de-0000-4000-8000-000000000201",
      productId: "jp.nekowidget.plus.monthly",
      autoRenewProductId: "jp.nekowidget.plus.monthly",
      autoRenewStatus: 0,
      isInBillingRetryPeriod: status === 3 || status === 4,
      gracePeriodExpiresDateMs: overrides.gracePeriodExpiresDateMs
        ?? (status === 4 ? now + 30_000 : null),
      renewalDateMs: now + 60_000,
      signedDateMs: overrides.renewalSignedDateMs ?? now - 500,
      environment: "Sandbox",
    },
  };
}

describe("effective Plus entitlement rules", () => {
  it.each([
    [1, "active", true],
    [2, "expired", false],
    [3, "billingRetry", false],
    [4, "gracePeriod", true],
    [5, "revoked", false],
  ] as const)("maps Apple status %s to %s", (status, expectedStatus, grantsPlus) => {
    expect(evaluateAuthoritativeStatusItem(item(status), now)).toMatchObject({
      status: expectedStatus,
      grantsPlus,
      provisional: false,
    });
  });

  it("treats access and authority deadlines as exclusive", () => {
    expect(evaluateAuthoritativeStatusItem(item(1, { expiresDateMs: now }), now))
      .toMatchObject({ status: "expired", grantsPlus: false });
    expect(evaluateAuthoritativeStatusItem(
      item(4, { gracePeriodExpiresDateMs: now }), now,
    )).toMatchObject({ status: "expired", grantsPlus: false });
    expect(evaluateAuthoritativeStatusItem(
      item(1, { expiresDateMs: now + BILLING_AUTHORITY_FRESHNESS_MS + 60_000 }),
      now + BILLING_AUTHORITY_FRESHNESS_MS,
      now + BILLING_AUTHORITY_FRESHNESS_MS,
    )).toMatchObject({ status: "unconfirmed", grantsPlus: false });
  });

  it("denies refunds, upgrades, and Family Sharing even with active status", () => {
    expect(evaluateAuthoritativeStatusItem(item(1, {
      revocationDateMs: now - 1,
      revocationReason: 1,
    }), now)).toMatchObject({ status: "revoked", grantsPlus: false });
    expect(evaluateAuthoritativeStatusItem(item(1, { isUpgraded: true }), now))
      .toMatchObject({ status: "upgraded", grantsPlus: false });
    expect(evaluateAuthoritativeStatusItem(item(1, {
      ownershipType: "FAMILY_SHARED",
    }), now)).toMatchObject({ status: "unconfirmed", grantsPlus: false });
  });

  it("keeps active access through its paid term when auto-renew is off", () => {
    const value = item(1);
    value.renewal.autoRenewStatus = 0;
    expect(evaluateAuthoritativeStatusItem(value, now))
      .toMatchObject({ status: "active", grantsPlus: true });
  });

  it("selects newest signed facts and fails restrictive on an exact-time conflict", () => {
    const olderRevoked = item(5, {
      transactionSignedDateMs: now - 2_000,
      renewalSignedDateMs: now - 2_000,
      transactionId: "220000000000002",
    });
    const newerActive = item(1, {
      transactionSignedDateMs: now - 1_000,
      renewalSignedDateMs: now - 1_000,
      transactionId: "220000000000003",
    });
    expect(selectAuthoritativeStatusItem([olderRevoked, newerActive])).toBe(newerActive);

    const tiedExpired = item(2, { transactionId: "220000000000004" });
    const tiedActive = item(1, { transactionId: "220000000000005" });
    expect(selectAuthoritativeStatusItem([tiedActive, tiedExpired])).toBe(tiedExpired);
  });
});
