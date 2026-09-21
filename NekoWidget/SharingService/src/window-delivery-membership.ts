import { effectiveBillingEntitlement } from "./billing-entitlement";
import { billingEffectiveEntitlementRuntimeEnabled, billingWindowSponsorshipRuntimeEnabled, type Env } from "./env";
import { ApiError } from "./errors";

/** Only new content acceptance uses this gate. It is not participant authorization. */
export function windowDeliverySupportGuard(env: Env, spaceID: string): { sql: string; bindings: string[] } {
  if (env.WINDOW_DELIVERY_MEMBERSHIP_ENFORCED !== "YES") return { sql: "1", bindings: [] };
  if (!billingEffectiveEntitlementRuntimeEnabled(env) || !billingWindowSponsorshipRuntimeEnabled(env)) {
    return { sql: "0", bindings: [] };
  }
  // Evaluate again inside the accepting mutation, using DB time (not request-start time).
  // A reservation uses CASE WHEN guard THEN request_hash ELSE NULL END in its
  // existing NOT NULL column: losing support rolls back the entire D1 batch,
  // including its idempotency response. No new persistence/schema is needed.
  return { sql: `EXISTS (
    SELECT 1 FROM moment_spaces space
    JOIN billing_window_sponsorships sponsorship ON sponsorship.window_lineage_id=space.lineage_id
    JOIN billing_effective_entitlement_current authority ON authority.billing_account_id=sponsorship.billing_account_id
    JOIN billing_runtime_gate gate ON gate.singleton=1
    WHERE space.space_id=? AND space.state='active' AND sponsorship.state='active'
      AND gate.window_sponsorship_enabled=1 AND gate.effective_entitlement_enabled=1
      AND authority.materialized_grants_plus=1 AND authority.ownership_type='PURCHASED'
      AND authority.materialized_status IN ('active','gracePeriod')
      AND authority.revocation_date_ms IS NULL AND authority.revocation_reason IS NULL
      AND authority.is_upgraded=0 AND authority.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)
      AND authority.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)
  )`, bindings: [spaceID] };
}

export async function requireWindowDeliverySupport(env: Env, spaceID: string): Promise<void> {
  if (env.WINDOW_DELIVERY_MEMBERSHIP_ENFORCED !== "YES") return;
  const unavailable = () => new ApiError(503, "window_support_unavailable", "Window support could not be verified.");
  const required = () => new ApiError(403, "window_support_required", "This window needs active support for new content.");
  try {
    if (!billingEffectiveEntitlementRuntimeEnabled(env) || !billingWindowSponsorshipRuntimeEnabled(env)) throw unavailable();
    const gate = await env.DB.prepare(
      "SELECT window_sponsorship_enabled,effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton=1",
    ).first<{ window_sponsorship_enabled: number; effective_entitlement_enabled: number }>();
    if (gate?.window_sponsorship_enabled !== 1 || gate.effective_entitlement_enabled !== 1) throw unavailable();
    const guard = windowDeliverySupportGuard(env, spaceID);
    const result = await env.DB.prepare(`SELECT ${guard.sql} AS allowed`).bind(...guard.bindings).first<{ allowed: number }>();
    if (result?.allowed === 1) return;
    const sponsorship = await env.DB.prepare(`SELECT sponsorship.state,sponsorship.billing_account_id
      FROM moment_spaces space LEFT JOIN billing_window_sponsorships sponsorship
        ON sponsorship.window_lineage_id=space.lineage_id WHERE space.space_id=?`)
      .bind(spaceID).first<{ state: string | null; billing_account_id: string | null }>();
    if (!sponsorship || sponsorship.state !== "active" || !sponsorship.billing_account_id) throw required();
    const entitlement = await effectiveBillingEntitlement(env, sponsorship.billing_account_id);
    if (entitlement.status === "unconfirmed" || entitlement.grantsPlus) throw unavailable();
    throw required();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw unavailable();
  }
}
