import type { VerificationServiceConfig } from "./config.js";

export const BILLING_VERIFIER_NONCE_RETENTION_SECONDS = 601;

export interface BillingVerifierNonceClaim {
  scope: string;
  nonce: string;
  retentionSeconds: number;
}

export interface BillingVerifierNonceStore {
  claim(input: BillingVerifierNonceClaim): Promise<"claimed" | "replayed">;
  ready(): boolean;
}

export function billingVerifierNonceScope(config: VerificationServiceConfig): string {
  return `nwb:verifier:v1:${config.environment}:${config.bundleId}`;
}
