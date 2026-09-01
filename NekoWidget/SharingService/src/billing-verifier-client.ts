import {
  BILLING_NOTIFICATION_HISTORY_PATH,
  BILLING_NOTIFICATION_VERIFIER_PATH,
  BILLING_SUBSCRIPTION_STATUS_PATH,
  BILLING_VERIFIER_PATH,
  BILLING_VERIFIER_PROTOCOL_VERSION,
  BILLING_ACCOUNT_RECOVERY_VERIFIER_PATH,
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
  | typeof BILLING_NOTIFICATION_HISTORY_PATH
  | typeof BILLING_SUBSCRIPTION_STATUS_PATH
  | typeof BILLING_ACCOUNT_RECOVERY_VERIFIER_PATH;

export class AppleNotificationHistoryCursorResetRequiredError extends ApiError {
  readonly recovery = "reset-cursor" as const;

  constructor() {
    super(
      409,
      "apple_notification_history_cursor_reset_required",
      "Billing notification recovery must restart from the beginning.",
    );
  }
}

export class AppleNotificationHistoryConfigurationBlockedError extends ApiError {
  readonly recovery = "operator-action-required" as const;

  constructor() {
    super(
      503,
      "apple_notification_history_configuration_blocked",
      "Billing notification recovery is temporarily unavailable.",
    );
  }
}

export class AppleNotificationHistoryDisabledError extends ApiError {
  readonly recovery = "runtime-enable-required" as const;

  constructor() {
    super(
      503,
      "apple_notification_history_disabled",
      "Billing notification recovery is temporarily unavailable.",
    );
  }
}

export class InvalidAppleNotificationHistoryError extends ApiError {
  readonly recovery = "reject-window" as const;

  constructor() {
    super(
      400,
      "invalid_apple_notification_history",
      "The App Store notification history request is invalid.",
    );
  }
}

export interface VerifiedAccountRecoveryEvidence {
  appTransactionIdHash: string;
  transaction: VerifiedBillingTransaction;
}

export interface VerifierConfig {
  origin: string;
  accessServiceToken: {
    clientId: string;
    clientSecret: string;
  } | null;
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
const accessCredentialPattern = /^[\x21-\x7e]{1,512}$/u;

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
  const isLocalLoopback = env.ENVIRONMENT === "local"
    && parsedOrigin.protocol === "http:"
    && parsedOrigin.hostname === "127.0.0.1";
  const permitsLocalHTTP = isLocalLoopback;
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

  const rawAccessClientId = env.BILLING_VERIFIER_ACCESS_CLIENT_ID;
  const rawAccessClientSecret = env.BILLING_VERIFIER_ACCESS_CLIENT_SECRET;
  const permitsLocalAccessBypass = isLocalLoopback
    && rawAccessClientId === undefined
    && rawAccessClientSecret === undefined;
  let accessServiceToken: VerifierConfig["accessServiceToken"] = null;
  if (!permitsLocalAccessBypass) {
    const accessClientId = requiredSetting(rawAccessClientId);
    const accessClientSecret = requiredSetting(rawAccessClientSecret);
    if (
      accessClientId.length > 256
      || !accessCredentialPattern.test(accessClientId)
      || !accessCredentialPattern.test(accessClientSecret)
    ) {
      throw new ApiError(
        503,
        "billing_configuration_unavailable",
        "Billing is temporarily unavailable.",
      );
    }
    accessServiceToken = {
      clientId: accessClientId,
      clientSecret: accessClientSecret,
    };
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
    accessServiceToken,
    sharedSecret,
    bundleId,
    environment,
    subscriptionGroupId,
    productIds: new Set([monthlyProductId, annualProductId]),
  };
}

async function boundedResponseBody(
  response: Response,
  maximumBytes: number,
): Promise<Uint8Array> {
  if (response.body === null) return new Uint8Array();
  let reader: ReadableStreamDefaultReader<Uint8Array>;
  try {
    reader = response.body.getReader();
  } catch {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > maximumBytes) {
        try { void reader.cancel().catch(() => undefined); } catch { /* fail closed below */ }
        throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof ApiError) throw error;
    try { void reader.cancel().catch(() => undefined); } catch { /* the response is already unusable */ }
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

function assertNoDuplicateJSONKeys(source: string): void {
  let index = 0;
  const maximumDepth = 64;
  const skipWhitespace = () => {
    while (
      source[index] === " "
      || source[index] === "\t"
      || source[index] === "\r"
      || source[index] === "\n"
    ) index += 1;
  };
  const parseString = (): string => {
    if (source[index] !== "\"") throw new Error();
    const start = index;
    index += 1;
    while (index < source.length) {
      const character = source[index];
      if (character === "\"") {
        index += 1;
        const decoded = JSON.parse(source.slice(start, index)) as unknown;
        if (typeof decoded !== "string") throw new Error();
        return decoded;
      }
      if (character === "\\") {
        index += 1;
        const escape = source[index];
        if (escape === "u") {
          const digits = source.slice(index + 1, index + 5);
          if (!/^[0-9a-fA-F]{4}$/u.test(digits)) throw new Error();
          index += 5;
          continue;
        }
        if (
          escape === undefined
          || !["\"", "\\", "/", "b", "f", "n", "r", "t"].includes(escape)
        ) throw new Error();
        index += 1;
        continue;
      }
      if (character === undefined || character.charCodeAt(0) < 0x20) throw new Error();
      index += 1;
    }
    throw new Error();
  };
  const parseValue = (depth: number): void => {
    if (depth > maximumDepth) throw new Error();
    skipWhitespace();
    const character = source[index];
    if (character === "{") {
      index += 1;
      skipWhitespace();
      const keys = new Set<string>();
      if (source[index] === "}") {
        index += 1;
        return;
      }
      while (true) {
        skipWhitespace();
        const key = parseString();
        if (keys.has(key)) throw new Error();
        keys.add(key);
        skipWhitespace();
        if (source[index] !== ":") throw new Error();
        index += 1;
        parseValue(depth + 1);
        skipWhitespace();
        if (source[index] === "}") {
          index += 1;
          return;
        }
        if (source[index] !== ",") throw new Error();
        index += 1;
      }
    }
    if (character === "[") {
      index += 1;
      skipWhitespace();
      if (source[index] === "]") {
        index += 1;
        return;
      }
      while (true) {
        parseValue(depth + 1);
        skipWhitespace();
        if (source[index] === "]") {
          index += 1;
          return;
        }
        if (source[index] !== ",") throw new Error();
        index += 1;
      }
    }
    if (character === "\"") {
      parseString();
      return;
    }
    for (const literal of ["true", "false", "null"]) {
      if (source.startsWith(literal, index)) {
        index += literal.length;
        return;
      }
    }
    const number = source.slice(index).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/u)?.[0];
    if (number === undefined) throw new Error();
    index += number.length;
  };
  parseValue(0);
  skipWhitespace();
  if (index !== source.length) throw new Error();
}

function decodedJSON(body: Uint8Array): unknown {
  try {
    const source = new TextDecoder("utf-8", { fatal: true }).decode(body);
    assertNoDuplicateJSONKeys(source);
    return JSON.parse(source);
  } catch {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
}

function exactVerifierErrorCode(body: Uint8Array): string {
  const envelope = record(decodedJSON(body));
  const envelopeFields = Object.keys(envelope);
  if (envelopeFields.length !== 1 || envelopeFields[0] !== "error") {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  const error = record(envelope.error);
  const errorFields = Object.keys(error);
  if (
    errorFields.length !== 1
    || errorFields[0] !== "code"
    || typeof error.code !== "string"
  ) {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  return error.code;
}

function throwAppleNotificationHistoryServiceError(
  status: number,
  body: Uint8Array,
): never {
  const code = exactVerifierErrorCode(body);
  if (status === 409 && code === "apple_notification_history_cursor_reset_required") {
    throw new AppleNotificationHistoryCursorResetRequiredError();
  }
  if (status === 503 && code === "apple_notification_history_configuration_blocked") {
    throw new AppleNotificationHistoryConfigurationBlockedError();
  }
  if (status === 503 && code === "apple_notification_history_disabled") {
    throw new AppleNotificationHistoryDisabledError();
  }
  if (status === 400 && code === "invalid_apple_notification_history") {
    throw new InvalidAppleNotificationHistoryError();
  }
  const retryable = (
    status === 503
    && (
      code === "apple_verification_temporarily_unavailable"
      || code === "billing_verifier_busy"
      || code === "billing_verifier_nonce_store_unavailable"
      || code === "billing_verifier_replayed_request"
    )
  ) || (status === 500 && code === "internal_error");
  if (retryable) {
    throw new ApiError(503, "billing_verifier_unavailable", "Billing is temporarily unavailable.");
  }
  throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
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

export async function verifyAppleAccountRecoveryViaService(
  input: {
    signedAppTransactionInfo: string;
    signedTransactionInfo: string;
    deviceVerificationId: string;
    expectedAppTransactionId: string;
    expectedTransactionId: string;
    expectedOriginalTransactionId: string;
    billingAccountId: string;
  },
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<VerifiedAccountRecoveryEvidence> {
  const raw = record(await callBillingVerifierService(
    BILLING_ACCOUNT_RECOVERY_VERIFIER_PATH,
    { protocolVersion: BILLING_VERIFIER_PROTOCOL_VERSION, ...input },
    env,
    fetchImpl,
  ));
  const fields = Object.keys(raw).sort();
  if (fields.join(",") !== "appTransactionIdHash,protocolVersion,transaction"
    || raw.protocolVersion !== 1
    || typeof raw.appTransactionIdHash !== "string"
    || !/^[A-Za-z0-9_-]{43}$/u.test(raw.appTransactionIdHash)) {
    throw new ApiError(503, "billing_verifier_invalid_response", "Billing is temporarily unavailable.");
  }
  return {
    appTransactionIdHash: raw.appTransactionIdHash,
    transaction: normalizeVerifiedBillingTransaction(raw.transaction, loadVerifierConfig(env)),
  };
}

export async function callBillingVerifierService(
  path: BillingVerifierServicePath,
  value: Record<string, unknown>,
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<unknown> {
  const config = loadVerifierConfig(env);
  const body = new TextEncoder().encode(JSON.stringify(value));
  const maximumBodyBytes = path === BILLING_ACCOUNT_RECOVERY_VERIFIER_PATH
    ? 128 * 1024 : 64 * 1024;
  if (body.length > maximumBodyBytes) {
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
        ...(config.accessServiceToken === null ? {} : {
          "CF-Access-Client-Id": config.accessServiceToken.clientId,
          "CF-Access-Client-Secret": config.accessServiceToken.clientSecret,
        }),
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

  const responseBody = await boundedResponseBody(
    response,
    path === BILLING_NOTIFICATION_HISTORY_PATH ? 64 * 1024 : 32 * 1024,
  );
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
    if (path === BILLING_NOTIFICATION_HISTORY_PATH) {
      throwAppleNotificationHistoryServiceError(response.status, responseBody);
    }
    const status = response.status >= 500 ? 503 : 400;
    throw new ApiError(
      status,
      status === 503 ? "billing_verifier_unavailable" : "invalid_apple_transaction",
      status === 503 ? "Billing is temporarily unavailable." : "The App Store transaction is invalid.",
    );
  }
  return decodedJSON(responseBody);
}
