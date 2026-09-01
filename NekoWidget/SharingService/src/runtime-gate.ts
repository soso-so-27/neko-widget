import {
  apnsRuntimeEnabled,
  billingAccountBootstrapRuntimeEnabled,
  billingAccountRecoveryRuntimeEnabled,
  billingAppleNotificationRuntimeEnabled,
  billingEffectiveEntitlementRuntimeEnabled,
  billingSubscriptionReconciliationRuntimeEnabled,
  billingTransactionIngestionRuntimeEnabled,
  billingWindowSponsorshipRuntimeEnabled,
  momentRuntimeEnabled,
  reactionRuntimeEnabled,
  reportIngestionRuntimeEnabled,
  windowNameRuntimeEnabled,
  type Env,
} from "./env";

interface RuntimeGateRow {
  generation: number;
  media_enabled: number;
  apns_enabled: number;
  report_ingestion_enabled: number;
}

export interface RuntimeGateSnapshot {
  readonly generation: number;
  readonly mediaEnabled: boolean;
  readonly apnsEnabled: boolean;
  readonly reportIngestionEnabled: boolean;
}

interface BillingRuntimeGateRow {
  generation: number;
  account_bootstrap_enabled: number;
  transaction_ingestion_enabled: number;
  apple_notification_ingestion_enabled: number;
  subscription_reconciliation_enabled: number;
  effective_entitlement_enabled: number;
  account_recovery_enabled: number;
  window_sponsorship_enabled: number;
}

export interface BillingRuntimeGateSnapshot {
  readonly generation: number;
  readonly accountBootstrapEnabled: boolean;
  readonly transactionIngestionEnabled: boolean;
  readonly appleNotificationEnabled: boolean;
  readonly subscriptionReconciliationEnabled: boolean;
  readonly effectiveEntitlementEnabled: boolean;
  readonly accountRecoveryEnabled: boolean;
  readonly windowSponsorshipEnabled: boolean;
}

function bit(value: number): boolean | null {
  if (value === 0) return false;
  if (value === 1) return true;
  return null;
}

/** Missing, malformed, or unreadable gate state is always closed. */
export async function loadRuntimeGate(
  env: Pick<Env, "DB">,
): Promise<RuntimeGateSnapshot | null> {
  try {
    const row = await env.DB.prepare(
      `SELECT generation, media_enabled, apns_enabled,
              report_ingestion_enabled
         FROM personal_staging_runtime_gate
        WHERE singleton = 1`,
    ).first<RuntimeGateRow>();
    if (row === null || !Number.isSafeInteger(row.generation) || row.generation < 0) {
      return null;
    }
    const mediaEnabled = bit(row.media_enabled);
    const apnsEnabled = bit(row.apns_enabled);
    const reportIngestionEnabled = bit(row.report_ingestion_enabled);
    if (mediaEnabled === null || apnsEnabled === null
        || reportIngestionEnabled === null || (apnsEnabled && !mediaEnabled)) {
      return null;
    }
    return Object.freeze({
      generation: row.generation,
      mediaEnabled,
      apnsEnabled,
      reportIngestionEnabled,
    });
  } catch {
    return null;
  }
}

/** The seven billing lower bounds are read as one generation-bound snapshot. */
export async function loadBillingRuntimeGate(
  env: Pick<Env, "DB">,
): Promise<BillingRuntimeGateSnapshot | null> {
  try {
    const row = await env.DB.prepare(
      `SELECT generation,
              account_bootstrap_enabled, transaction_ingestion_enabled,
              apple_notification_ingestion_enabled,
              subscription_reconciliation_enabled,
              effective_entitlement_enabled, account_recovery_enabled,
              window_sponsorship_enabled
         FROM billing_runtime_gate
        WHERE singleton = 1`,
    ).first<BillingRuntimeGateRow>();
    if (row === null || !Number.isSafeInteger(row.generation)
        || row.generation < 0) {
      return null;
    }
    const accountBootstrapEnabled = bit(row.account_bootstrap_enabled);
    const transactionIngestionEnabled = bit(row.transaction_ingestion_enabled);
    const appleNotificationEnabled = bit(
      row.apple_notification_ingestion_enabled,
    );
    const subscriptionReconciliationEnabled = bit(
      row.subscription_reconciliation_enabled,
    );
    const effectiveEntitlementEnabled = bit(row.effective_entitlement_enabled);
    const accountRecoveryEnabled = bit(row.account_recovery_enabled);
    const windowSponsorshipEnabled = bit(row.window_sponsorship_enabled);
    if (accountBootstrapEnabled === null
        || transactionIngestionEnabled === null
        || appleNotificationEnabled === null
        || subscriptionReconciliationEnabled === null
        || effectiveEntitlementEnabled === null
        || accountRecoveryEnabled === null
        || windowSponsorshipEnabled === null) {
      return null;
    }
    return Object.freeze({
      generation: row.generation,
      accountBootstrapEnabled,
      transactionIngestionEnabled,
      appleNotificationEnabled,
      subscriptionReconciliationEnabled,
      effectiveEntitlementEnabled,
      accountRecoveryEnabled,
      windowSponsorshipEnabled,
    });
  } catch {
    return null;
  }
}

export function mediaGateOpen(snapshot: RuntimeGateSnapshot | null): boolean {
  return snapshot?.mediaEnabled === true;
}

export function apnsGateOpen(snapshot: RuntimeGateSnapshot | null): boolean {
  return snapshot?.mediaEnabled === true && snapshot.apnsEnabled;
}

export function reportIngestionGateOpen(
  snapshot: RuntimeGateSnapshot | null,
): boolean {
  return snapshot?.reportIngestionEnabled === true;
}

export function effectiveRuntimeGateHeaders(
  env: Env,
  snapshot: RuntimeGateSnapshot,
): Headers {
  const media = snapshot.mediaEnabled
    && momentRuntimeEnabled(env)
    && reactionRuntimeEnabled(env)
    && windowNameRuntimeEnabled(env);
  const apns = snapshot.mediaEnabled
    && snapshot.apnsEnabled
    && apnsRuntimeEnabled(env);
  const report = snapshot.reportIngestionEnabled
    && reportIngestionRuntimeEnabled(env);
  return new Headers({
    "Cache-Control": "no-store",
    "Neko-Runtime-Gate-Generation": String(snapshot.generation),
    "Neko-Runtime-Media": media ? "ON" : "OFF",
    "Neko-Runtime-Apns": apns ? "ON" : "OFF",
    "Neko-Runtime-Report-Ingestion": report ? "ON" : "OFF",
  });
}

/** Public health attestation contains effective switches only, never IDs. */
export function effectiveBillingRuntimeGateHeaders(
  env: Env,
  snapshot: BillingRuntimeGateSnapshot,
): Headers {
  const effective = Object.freeze({
    accountBootstrap: snapshot.accountBootstrapEnabled
      && billingAccountBootstrapRuntimeEnabled(env),
    transactionIngestion: snapshot.transactionIngestionEnabled
      && billingTransactionIngestionRuntimeEnabled(env),
    appleNotification: snapshot.appleNotificationEnabled
      && billingAppleNotificationRuntimeEnabled(env),
    subscriptionReconciliation: snapshot.subscriptionReconciliationEnabled
      && billingSubscriptionReconciliationRuntimeEnabled(env),
    effectiveEntitlement: snapshot.effectiveEntitlementEnabled
      && billingEffectiveEntitlementRuntimeEnabled(env),
    accountRecovery: snapshot.accountRecoveryEnabled
      && billingAccountRecoveryRuntimeEnabled(env),
    windowSponsorship: snapshot.windowSponsorshipEnabled
      && billingWindowSponsorshipRuntimeEnabled(env),
  });
  return new Headers({
    "Neko-Runtime-Billing-Gate-Generation": String(snapshot.generation),
    "Neko-Runtime-Billing-Account-Bootstrap":
      effective.accountBootstrap ? "ON" : "OFF",
    "Neko-Runtime-Billing-Transaction-Ingestion":
      effective.transactionIngestion ? "ON" : "OFF",
    "Neko-Runtime-Billing-Apple-Notification-Ingestion":
      effective.appleNotification ? "ON" : "OFF",
    "Neko-Runtime-Billing-Subscription-Reconciliation":
      effective.subscriptionReconciliation ? "ON" : "OFF",
    "Neko-Runtime-Billing-Effective-Entitlement":
      effective.effectiveEntitlement ? "ON" : "OFF",
    "Neko-Runtime-Billing-Account-Recovery":
      effective.accountRecovery ? "ON" : "OFF",
    "Neko-Runtime-Billing-Window-Sponsorship":
      effective.windowSponsorship ? "ON" : "OFF",
  });
}
