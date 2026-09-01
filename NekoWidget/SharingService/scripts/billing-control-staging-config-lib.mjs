import {
  renderStagingConfig,
  validateStagingConfig,
} from "./staging-config-lib.mjs";

export const billingControlEnabledFlags = Object.freeze([
  "BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED",
  "BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED",
  "BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED",
  "BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED",
  "BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED",
  "BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED",
  "BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED",
]);

const preservedGeneralStagingPolicy = Object.freeze({
  expectedMomentRuntime: "YES",
  expectedAPNSRuntime: "YES",
  expectedReportIngestionRuntime: "YES",
});

export function renderBillingControlStagingPair(template, environment) {
  return Object.freeze({
    off: renderStagingConfig(
      template,
      environment,
      preservedGeneralStagingPolicy,
    ),
    on: renderStagingConfig(template, environment, {
      ...preservedGeneralStagingPolicy,
      expectedBillingRuntimeProfile: "billing-control-on",
    }),
  });
}

export function validateBillingControlStagingPair(offConfig, onConfig) {
  validateStagingConfig(offConfig, preservedGeneralStagingPolicy);
  validateStagingConfig(onConfig, {
    ...preservedGeneralStagingPolicy,
    expectedBillingRuntimeProfile: "billing-control-on",
  });

  const normalizedOn = structuredClone(onConfig);
  for (const flag of billingControlEnabledFlags) {
    normalizedOn.vars[flag] = "NO";
  }
  if (JSON.stringify(normalizedOn) !== JSON.stringify(offConfig)) {
    throw new Error(
      "Billing control ON/OFF configs may differ only by the seven reviewed upper runtime flags.",
    );
  }
  if (Object.keys(onConfig.vars).some((key) => key.includes("SECRET"))) {
    throw new Error("Billing control Wrangler vars must not contain a secret.");
  }
  return Object.freeze({ offConfig, onConfig });
}
