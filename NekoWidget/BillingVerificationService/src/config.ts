import { Environment } from "@apple/app-store-server-library";

export interface VerificationServiceConfig {
  port: number;
  sharedSecret: Buffer;
  rootCertificates: Buffer[];
  environment: Environment.SANDBOX | Environment.PRODUCTION;
  bundleId: string;
  appAppleId?: number;
  subscriptionGroupId: string;
  productIds: ReadonlySet<string>;
  notificationVerificationEnabled?: boolean;
  subscriptionStatusEnabled?: boolean;
  accountRecoveryVerificationEnabled?: boolean;
  serverAPI?: {
    signingKey: string;
    keyId: string;
    issuerId: string;
  };
}

export interface VerificationRuntimeConfig extends VerificationServiceConfig {
  nonceRedisURL: string;
}

const base64Pattern = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;
const productIdPattern = /^[A-Za-z0-9._-]{1,100}$/u;
const bundleIdPattern = /^[A-Za-z0-9.-]{3,255}$/u;
const keyIdPattern = /^[A-Z0-9]{10}$/u;
const issuerIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

function explicitSwitch(env: NodeJS.ProcessEnv, name: string): boolean {
  const value = env[name] ?? "NO";
  if (value !== "YES" && value !== "NO") {
    throw new Error(`${name} must be YES or NO`);
  }
  return value === "YES";
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value === "" || value !== value.trim()) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function decodeSharedSecret(value: string): Buffer {
  if (!/^[A-Za-z0-9_-]{43}$/u.test(value)) {
    throw new Error("BILLING_VERIFIER_SHARED_SECRET must be canonical base64url");
  }
  const decoded = Buffer.from(value, "base64url");
  if (decoded.length !== 32 || decoded.toString("base64url") !== value) {
    throw new Error("BILLING_VERIFIER_SHARED_SECRET must encode 32 bytes");
  }
  return decoded;
}

function decodeRoots(value: string): Buffer[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error("APPLE_ROOT_CERTIFICATES_BASE64_JSON must be JSON");
  }
  if (!Array.isArray(parsed) || parsed.length < 1 || parsed.length > 8) {
    throw new Error("APPLE_ROOT_CERTIFICATES_BASE64_JSON must contain 1 to 8 roots");
  }
  return parsed.map((item) => {
    if (typeof item !== "string" || item.length > 16_384 || !base64Pattern.test(item)) {
      throw new Error("Apple root certificates must be canonical base64 DER");
    }
    const decoded = Buffer.from(item, "base64");
    if (decoded.length < 256 || decoded.toString("base64") !== item) {
      throw new Error("Apple root certificates must be canonical DER");
    }
    return decoded;
  });
}

function nonceRedisURL(env: NodeJS.ProcessEnv): string {
  const value = required(env, "BILLING_NONCE_REDIS_URL");
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("BILLING_NONCE_REDIS_URL is invalid");
  }
  if (
    parsed.protocol !== "rediss:"
    || parsed.hostname === ""
    || parsed.hash !== ""
    || parsed.search !== ""
  ) {
    throw new Error("BILLING_NONCE_REDIS_URL must use TLS without query or fragment");
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): VerificationRuntimeConfig {
  if (required(env, "BILLING_VERIFIER_RUNTIME_ENABLED") !== "YES") {
    throw new Error("Billing verifier runtime is disabled");
  }
  const portValue = env.PORT ?? "8080";
  const port = Number(portValue);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535 || String(port) !== portValue) {
    throw new Error("PORT is invalid");
  }
  const environmentValue = required(env, "BILLING_STORE_ENVIRONMENT");
  const environment = environmentValue === Environment.SANDBOX
    ? Environment.SANDBOX
    : environmentValue === Environment.PRODUCTION
      ? Environment.PRODUCTION
      : null;
  if (environment === null) throw new Error("BILLING_STORE_ENVIRONMENT is invalid");

  const bundleId = required(env, "BILLING_BUNDLE_ID");
  const subscriptionGroupId = required(env, "BILLING_SUBSCRIPTION_GROUP_ID");
  const monthlyProductId = required(env, "BILLING_MONTHLY_PRODUCT_ID");
  const annualProductId = required(env, "BILLING_ANNUAL_PRODUCT_ID");
  if (
    !bundleIdPattern.test(bundleId)
    || !productIdPattern.test(subscriptionGroupId)
    || !productIdPattern.test(monthlyProductId)
    || !productIdPattern.test(annualProductId)
    || monthlyProductId === annualProductId
  ) {
    throw new Error("Billing product identity is invalid");
  }

  let appAppleId: number | undefined;
  const appAppleIdValue = env.BILLING_APP_APPLE_ID;
  if (environment === Environment.PRODUCTION) {
    if (appAppleIdValue === undefined || !/^\d{1,18}$/u.test(appAppleIdValue)) {
      throw new Error("BILLING_APP_APPLE_ID is required in Production");
    }
    appAppleId = Number(appAppleIdValue);
    if (!Number.isSafeInteger(appAppleId) || appAppleId <= 0) {
      throw new Error("BILLING_APP_APPLE_ID is invalid");
    }
  } else if (appAppleIdValue !== undefined && appAppleIdValue !== "") {
    throw new Error("BILLING_APP_APPLE_ID must be omitted in Sandbox");
  }

  const config: VerificationServiceConfig = {
    port,
    sharedSecret: decodeSharedSecret(required(env, "BILLING_VERIFIER_SHARED_SECRET")),
    rootCertificates: decodeRoots(required(env, "APPLE_ROOT_CERTIFICATES_BASE64_JSON")),
    environment,
    bundleId,
    subscriptionGroupId,
    productIds: new Set([monthlyProductId, annualProductId]),
    notificationVerificationEnabled: explicitSwitch(
      env,
      "BILLING_NOTIFICATION_VERIFIER_RUNTIME_ENABLED",
    ),
    subscriptionStatusEnabled: explicitSwitch(
      env,
      "BILLING_SUBSCRIPTION_STATUS_RUNTIME_ENABLED",
    ),
    accountRecoveryVerificationEnabled: explicitSwitch(
      env,
      "BILLING_ACCOUNT_RECOVERY_VERIFIER_RUNTIME_ENABLED",
    ),
  };
  if (appAppleId !== undefined) config.appAppleId = appAppleId;
  if (config.subscriptionStatusEnabled === true) {
    const signingKey = required(env, "APP_STORE_SERVER_API_PRIVATE_KEY");
    const keyId = required(env, "APP_STORE_SERVER_API_KEY_ID");
    const issuerId = required(env, "APP_STORE_SERVER_API_ISSUER_ID").toLowerCase();
    if (
      signingKey.length > 16_384
      || !signingKey.startsWith("-----BEGIN PRIVATE KEY-----")
      || !signingKey.endsWith("-----END PRIVATE KEY-----")
      || !keyIdPattern.test(keyId)
      || !issuerIdPattern.test(issuerId)
    ) {
      throw new Error("App Store Server API credential is invalid");
    }
    config.serverAPI = { signingKey, keyId, issuerId };
  } else if (
    env.APP_STORE_SERVER_API_PRIVATE_KEY !== undefined
    || env.APP_STORE_SERVER_API_KEY_ID !== undefined
    || env.APP_STORE_SERVER_API_ISSUER_ID !== undefined
  ) {
    throw new Error("App Store Server API credentials require the exact runtime switch");
  }
  return { ...config, nonceRedisURL: nonceRedisURL(env) };
}
