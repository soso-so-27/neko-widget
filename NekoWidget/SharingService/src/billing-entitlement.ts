import type { VerifiedSubscriptionStatusItem } from "./billing-apple-client";
import type { Env } from "./env";

export const BILLING_AUTHORITY_FRESHNESS_MS = 36 * 60 * 60 * 1_000;

export type EffectiveEntitlementStatus =
  | "active"
  | "gracePeriod"
  | "billingRetry"
  | "expired"
  | "revoked"
  | "upgraded"
  | "unconfirmed";

export interface EffectiveBillingEntitlement {
  status: EffectiveEntitlementStatus;
  productId: string | null;
  accessUntilMs: number | null;
  authorityStaleAtMs: number | null;
  evaluatedAtMs: number;
  provisional: false;
  grantsPlus: boolean;
}

interface CurrentEntitlementRow {
  original_transaction_id: string;
  ownership_type: "PURCHASED" | "FAMILY_SHARED";
  apple_status: 1 | 2 | 3 | 4 | 5;
  product_id: string;
  expires_date_ms: number;
  revocation_date_ms: number | null;
  revocation_reason: 0 | 1 | null;
  is_upgraded: 0 | 1;
  grace_period_expires_date_ms: number | null;
  authority_stale_at_ms: number;
  evaluated_at_ms: number;
}

interface EvaluatedAuthority {
  status: EffectiveEntitlementStatus;
  productId: string;
  accessUntilMs: number | null;
  authorityStaleAtMs: number;
  evaluatedAtMs: number;
  provisional: false;
  grantsPlus: boolean;
}

function statusRestrictionRank(status: number): number {
  switch (status) {
    case 5: return 5;
    case 2: return 4;
    case 3: return 3;
    case 4: return 2;
    default: return 1;
  }
}

function itemRestrictionRank(item: VerifiedSubscriptionStatusItem): number {
  if (item.transaction.ownershipType !== "PURCHASED") return 9;
  if (
    item.status === 5
    || item.transaction.revocationDateMs !== null
    || item.transaction.revocationReason !== null
  ) return 8;
  if (item.transaction.isUpgraded) return 7;
  return statusRestrictionRank(item.status);
}

function latestSignedDate(item: VerifiedSubscriptionStatusItem): number {
  return Math.max(item.transaction.signedDateMs, item.renewal.signedDateMs);
}

/**
 * A Subscription Status response should contain one item for a lineage. If a
 * malformed-but-verified response contains more, choose the newest signed
 * facts deterministically. Exact-time status conflicts fail toward the more
 * restrictive state instead of conveniently selecting active access.
 */
export function selectAuthoritativeStatusItem(
  items: readonly VerifiedSubscriptionStatusItem[],
): VerifiedSubscriptionStatusItem {
  if (items.length === 0) throw new Error("missing authoritative status item");
  return [...items].sort((left, right) => {
    const latestDifference = latestSignedDate(right) - latestSignedDate(left);
    if (latestDifference !== 0) return latestDifference;
    const transactionDifference = right.transaction.signedDateMs
      - left.transaction.signedDateMs;
    if (transactionDifference !== 0) return transactionDifference;
    const renewalDifference = right.renewal.signedDateMs - left.renewal.signedDateMs;
    if (renewalDifference !== 0) return renewalDifference;
    const restrictionDifference = itemRestrictionRank(right) - itemRestrictionRank(left);
    if (restrictionDifference !== 0) return restrictionDifference;
    if (right.transaction.transactionId === left.transaction.transactionId) return 0;
    return right.transaction.transactionId > left.transaction.transactionId ? 1 : -1;
  })[0]!;
}

function evaluateFacts(
  facts: Pick<
    CurrentEntitlementRow,
    | "ownership_type"
    | "apple_status"
    | "product_id"
    | "expires_date_ms"
    | "revocation_date_ms"
    | "revocation_reason"
    | "is_upgraded"
    | "grace_period_expires_date_ms"
    | "authority_stale_at_ms"
  >,
  evaluatedAtMs: number,
): EvaluatedAuthority {
  const base = {
    productId: facts.product_id,
    authorityStaleAtMs: facts.authority_stale_at_ms,
    evaluatedAtMs,
    provisional: false as const,
  };
  if (facts.ownership_type !== "PURCHASED") {
    return { ...base, status: "unconfirmed", accessUntilMs: null, grantsPlus: false };
  }
  if (
    facts.apple_status === 5
    || facts.revocation_date_ms !== null
    || facts.revocation_reason !== null
  ) return { ...base, status: "revoked", accessUntilMs: null, grantsPlus: false };
  if (facts.is_upgraded === 1) {
    return { ...base, status: "upgraded", accessUntilMs: null, grantsPlus: false };
  }
  if (facts.apple_status === 2) {
    return { ...base, status: "expired", accessUntilMs: null, grantsPlus: false };
  }
  if (facts.apple_status === 3) {
    return { ...base, status: "billingRetry", accessUntilMs: null, grantsPlus: false };
  }

  const accessUntilMs = facts.apple_status === 4
    ? facts.grace_period_expires_date_ms
    : facts.expires_date_ms;
  if (accessUntilMs === null || evaluatedAtMs >= accessUntilMs) {
    return { ...base, status: "expired", accessUntilMs: null, grantsPlus: false };
  }
  if (evaluatedAtMs >= facts.authority_stale_at_ms) {
    return { ...base, status: "unconfirmed", accessUntilMs, grantsPlus: false };
  }
  return {
    ...base,
    status: facts.apple_status === 4 ? "gracePeriod" : "active",
    accessUntilMs,
    grantsPlus: true,
  };
}

export function evaluateAuthoritativeStatusItem(
  item: VerifiedSubscriptionStatusItem,
  evaluatedAtMs: number,
  authorityStaleAtMs = evaluatedAtMs + BILLING_AUTHORITY_FRESHNESS_MS,
): EvaluatedAuthority {
  return evaluateFacts({
    ownership_type: item.transaction.ownershipType,
    apple_status: item.status,
    product_id: item.transaction.productId,
    expires_date_ms: item.transaction.expiresDateMs,
    revocation_date_ms: item.transaction.revocationDateMs,
    revocation_reason: item.transaction.revocationReason,
    is_upgraded: item.transaction.isUpgraded ? 1 : 0,
    grace_period_expires_date_ms: item.renewal.gracePeriodExpiresDateMs,
    authority_stale_at_ms: authorityStaleAtMs,
  }, evaluatedAtMs);
}

function noAuthority(evaluatedAtMs: number): EffectiveBillingEntitlement {
  return {
    status: "unconfirmed",
    productId: null,
    accessUntilMs: null,
    authorityStaleAtMs: null,
    evaluatedAtMs,
    provisional: false,
    grantsPlus: false,
  };
}

export async function effectiveBillingEntitlement(
  env: Env,
  billingAccountId: string,
  evaluatedAtMs = Date.now(),
): Promise<EffectiveBillingEntitlement> {
  const rows = await env.DB.prepare(
    `SELECT original_transaction_id, ownership_type, apple_status, product_id,
            expires_date_ms, revocation_date_ms, revocation_reason, is_upgraded,
            grace_period_expires_date_ms, authority_stale_at_ms, evaluated_at_ms
       FROM billing_effective_entitlement_current
      WHERE billing_account_id = ?
      ORDER BY evaluated_at_ms DESC, original_transaction_id ASC`,
  ).bind(billingAccountId).all<CurrentEntitlementRow>();
  if (rows.results.length === 0) return noAuthority(evaluatedAtMs);

  const evaluated = rows.results.map((row) => evaluateFacts(row, evaluatedAtMs));
  const granting = evaluated.filter((item) => item.grantsPlus).sort((left, right) => {
    const leftLimit = Math.min(left.accessUntilMs!, left.authorityStaleAtMs);
    const rightLimit = Math.min(right.accessUntilMs!, right.authorityStaleAtMs);
    return rightLimit - leftLimit || left.productId.localeCompare(right.productId);
  });
  return granting[0] ?? evaluated[0] ?? noAuthority(evaluatedAtMs);
}
