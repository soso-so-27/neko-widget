import {
  BILLING_NOTIFICATION_VERIFIER_PATH,
  BILLING_SUBSCRIPTION_STATUS_PATH,
  BILLING_VERIFIER_PATH,
  BILLING_VERIFIER_PROTOCOL_VERSION,
  billingVerifierRequestTranscript,
  billingVerifierResponseTranscript,
  bodySHA256,
  signBillingVerifierTranscript,
  verifyBillingVerifierTranscript,
} from "./billing-verifier-protocol";
import { randomBase64url } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";

export interface VerifiedBillingTransaction {
  transactionId: string;
  originalTransactionId: string;
  billingAccountId: string;
  productId: string;
  subscriptionGroupId: string;
  bundleId: string;
  environment: "Sandbox" | "Production";
  ownershipType: "PURCHASED" | "FAMILY_SHARED";
  transactionReason: "PURCHASE" | "RENEWAL";
  purchaseDateMs: number;
  originalPurchaseDateMs: number;
  expiresDateMs: number;
  signedDateMs: number;
  revocationDateMs: number | null;
  revocationReason: 0 | 1 | null;
  isUpgraded: boolean;
}

export type BillingVerifierServicePath =
  | typeof BILLING_VERIFIER_PATH
  | typeof BILLING_NOTIFICATION_VERIFIER_PATH
  | typeof BILLING_SUBSCRIPTION_STATUS_PATH;

export interface VerifierConfig {
  origin: string;
  sharedSecret: string;
  bundleId: string;
  environment: "Sandbox" | "Production";
  subscriptionGroupId: string;
  productIds: ReadonlySet<string>;
}

const productIdPattern = /^[A-Za-z0-9._-]{1,100}$/u;
const subscriptionGroupPattern = /^[A-Za-z0-9._-]{1,100}$/u;
const bundleIdPattern = /^[A-Za-z0-9.-]{3,255}$/u;
const uuidV4Pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const transactionIdPattern = /^\d{1,32}$/u;

function requiredSetting(value: string | undefined): string {
  if (value === undefined || value === "" || value !== value.trim()) {
    throw new ApiError(
      503,
      "billing_configuration_unavailable",
      "Billing is temporarily unavailable.",
    );
  }
  return value;
}

export function loadVerifierConfig(env: Env): VerifierConfig {
  const rawOrigin = requiredSetting(env.BILLING_VERIFIER_ORIGIN);
  let parsedOrigin: URL;
  try {
    parsedOrigin = new URL(rawOrigin);
  } catch {
    throw new ApiError(503, "billing_configuration_unavailable", "Billing is temporarily unavailable.");
  }
  const permitsLocalHTTP = env.ENVIRONMENT === "local" && parsedOrigin.protocol === "http:";
  if (
    (!permitsLocalHTTP && parsedOrigin.protocol !== "https:")
    || parsedOrigin.username !== ""
    || parsedOrigin.password !== ""
    || parsedOrigin.pathname !== "/"
    || parsedOrigin.search !== ""
    || parsedOrigin.hash !== ""
  ) {
    throw new ApiError(503, "billing_configuration_unavailable", "Billing is temporarily unavailable.");
  }

  const sharedSecret = requiredSetting(env.BILLING_VERIFIER_SHARED_SECRET);
  try {
    // signBillingVerifierTranscript performs the same canonical 32-byte check.
    // Decode indirectly only when making a request so malformed secrets never
    // create a partially initialized verifier client.
    if (!/^[A-Za-z0-9_-]{43}$/u.test(sharedSecret)) throw new Error();
  } catch {
    throw new ApiError(503, "billing_configuration_unavailable", "Billing is temporarily unavailable.");
  }

  const bundleId = requiredSetting(env.BILLING_BUNDLE_ID);
  const environment = requiredSetting(env.BILLING_STORE_ENVIRONMENT);
  const subscriptionGroupId = requiredSetting(env.BILLING_SUBSCRIPTION_GROUP_ID);
  const monthlyProductId = requiredSetting(env.BILLING_MONTHLY_PRODUCT_ID);
  const annualProductId = requiredSetting(env.BILLING_ANNUAL_PRODUCT_ID);
  if (
    !bundleIdPattern.test(bundleId)
    || (environment !== "Sandbox" && environment !== "Production")
    || !subscriptionGroupPattern.test(subscriptionGroupId)
    || !productIdPattern.test(monthlyProductId)
    || !productIdPattern.test(annualProductId)
    || monthlyProductId === annualProductId
  ) {
    throw new ApiError(503, "billing_configuration_unavailable", "Billing is temporarily unavailable.");
  }
  return {
    origin: parsedOrigin.origin,
    sharedSecret,
    bundleId,
    environment,
    subscriptionGroupId,
    productIds: new Set([monthlyProductId, annualProductId]),
  };
}

async function boundedResponseBody(response: Response): Promise<Uint8Array> {
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > 32 * 1024) {
      await reader.cancel();
      throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
    }
    chunks.push(value);
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

function record(value: unknown): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  return value as Record<string, unknown>;
}

function exactResponseFields(value: Record<string, unknown>): void {
  const expected = [
    "billingAccountId", "bundleId", "environment", "expiresDateMs",
    "isUpgraded", "originalPurchaseDateMs", "originalTransactionId",
    "ownershipType", "productId", "protocolVersion", "purchaseDateMs",
    "revocationDateMs", "revocationReason", "signedDateMs",
    "subscriptionGroupId", "transactionId", "transactionReason",
  ].sort();
  const actual = Object.keys(value).sort();
  if (actual.length !== expected.length || actual.some((field, index) => field !== expected[index])) {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
}

function positiveInteger(value: unknown): number | null {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : null;
}

export function normalizeVerifiedBillingTransaction(
  raw: unknown,
  config: VerifierConfig,
): VerifiedBillingTransaction {
  const value = record(raw);
  exactResponseFields(value);
  const transactionId = value.transactionId;
  const originalTransactionId = value.originalTransactionId;
  const billingAccountId = value.billingAccountId;
  const productId = value.productId;
  const subscriptionGroupId = value.subscriptionGroupId;
  const bundleId = value.bundleId;
  const environment = value.environment;
  const ownershipType = value.ownershipType;
  const transactionReason = value.transactionReason;
  const purchaseDateMs = positiveInteger(value.purchaseDateMs);
  const originalPurchaseDateMs = positiveInteger(value.originalPurchaseDateMs);
  const expiresDateMs = positiveInteger(value.expiresDateMs);
  const signedDateMs = positiveInteger(value.signedDateMs);
  const revocationDateMs = value.revocationDateMs === null
    ? null : positiveInteger(value.revocationDateMs);
  const revocationReason = value.revocationReason;
  if (
    value.protocolVersion !== BILLING_VERIFIER_PROTOCOL_VERSION
    || typeof transactionId !== "string" || !transactionIdPattern.test(transactionId)
    || typeof originalTransactionId !== "string" || !transactionIdPattern.test(originalTransactionId)
    || typeof billingAccountId !== "string" || !uuidV4Pattern.test(billingAccountId)
    || typeof productId !== "string" || !config.productIds.has(productId)
    || subscriptionGroupId !== config.subscriptionGroupId
    || bundleId !== config.bundleId
    || environment !== config.environment
    || (ownershipType !== "PURCHASED" && ownershipType !== "FAMILY_SHARED")
    || (transactionReason !== "PURCHASE" && transactionReason !== "RENEWAL")
    || purchaseDateMs === null
    || originalPurchaseDateMs === null
    || expiresDateMs === null
    || signedDateMs === null
    || (value.revocationDateMs !== null && revocationDateMs === null)
    || (revocationReason !== null && revocationReason !== 0 && revocationReason !== 1)
    || typeof value.isUpgraded !== "boolean"
  ) {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  return {
    transactionId,
    originalTransactionId,
    billingAccountId,
    productId,
    subscriptionGroupId: config.subscriptionGroupId,
    bundleId: config.bundleId,
    environment: config.environment,
    ownershipType,
    transactionReason,
    purchaseDateMs,
    originalPurchaseDateMs,
    expiresDateMs,
    signedDateMs,
    revocationDateMs,
    revocationReason,
    isUpgraded: value.isUpgraded,
  };
}

export async function verifyAppleTransactionViaService(
  signedTransactionInfo: string,
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<VerifiedBillingTransaction> {
  const decoded = await callBillingVerifierService(
    BILLING_VERIFIER_PATH,
    {
      protocolVersion: BILLING_VERIFIER_PROTOCOL_VERSION,
      signedTransactionInfo,
    },
    env,
    fetchImpl,
  );
  return normalizeVerifiedBillingTransaction(decoded, loadVerifierConfig(env));
}

export async function callBillingVerifierService(
  path: BillingVerifierServicePath,
  value: Record<string, unknown>,
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<unknown> {
  const config = loadVerifierConfig(env);
  const body = new TextEncoder().encode(JSON.stringify(value));
  if (body.length > 64 * 1024) {
    throw new ApiError(400, "invalid_apple_payload", "The App Store payload is invalid.");
  }
  const timestamp = Math.floor(Date.now() / 1_000);
  const nonce = randomBase64url(16);
  let signature: string;
  try {
    signature = await signBillingVerifierTranscript(
      config.sharedSecret,
      billingVerifierRequestTranscript(timestamp, nonce, await bodySHA256(body)),
    );
  } catch {
    throw new ApiError(503, "billing_configuration_unavailable", "Billing is temporarily unavailable.");
  }

  let response: Response;
  try {
    response = await fetchImpl(`${config.origin}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Neko-Billing-Protocol-Version": String(BILLING_VERIFIER_PROTOCOL_VERSION),
        "Neko-Billing-Timestamp": String(timestamp),
        "Neko-Billing-Nonce": nonce,
        "Neko-Billing-Signature": signature,
      },
      body,
      redirect: "error",
      signal: AbortSignal.timeout(30_000),
    });
  } catch {
    throw new ApiError(503, "billing_verifier_unavailable", "Billing is temporarily unavailable.");
  }

  const responseBody = await boundedResponseBody(response);
  const responseSignature = response.headers.get("neko-billing-response-signature") ?? "";
  let authentic = false;
  try {
    authentic = await verifyBillingVerifierTranscript(
      config.sharedSecret,
      responseSignature,
      billingVerifierResponseTranscript(
        nonce,
        response.status,
        await bodySHA256(responseBody),
      ),
    );
  } catch {
    authentic = false;
  }
  if (!authentic) {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  if (!response.ok) {
    const status = response.status >= 500 ? 503 : 400;
    throw new ApiError(
      status,
      status === 503 ? "billing_verifier_unavailable" : "invalid_apple_transaction",
      status === 503 ? "Billing is temporarily unavailable." : "The App Store transaction is invalid.",
    );
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(responseBody));
  } catch {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  return decoded;
}
