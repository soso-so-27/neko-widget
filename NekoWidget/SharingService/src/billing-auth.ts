import { base64urlDecode, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";
import { billingSignedRequestTranscript } from "./billing-protocol";

export interface AuthenticatedBillingAccount {
  billingAccountId: string;
  billingKeyId: string;
  nonce: string;
  now: number;
}

interface BillingKeyRow {
  billing_account_id: string;
  billing_key_id: string;
  signing_public_key: string;
}

const uuidV4Pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const opaqueIdPattern = /^[A-Za-z0-9_-]{22}$/u;

export async function authenticateBillingSignedRequest(
  request: Request,
  env: Env,
  body: Uint8Array,
): Promise<AuthenticatedBillingAccount> {
  if (request.headers.get("neko-billing-protocol-version") !== "1") {
    throw new ApiError(401, "invalid_billing_authentication", "Billing authentication failed.");
  }
  const billingAccountId = request.headers.get("neko-billing-account-id") ?? "";
  const billingKeyId = request.headers.get("neko-billing-key-id") ?? "";
  const timestampValue = request.headers.get("neko-billing-timestamp") ?? "";
  const timestamp = Number(timestampValue);
  const nonce = request.headers.get("neko-billing-nonce") ?? "";
  const signature = request.headers.get("neko-billing-signature") ?? "";
  if (
    !uuidV4Pattern.test(billingAccountId)
    || !opaqueIdPattern.test(billingKeyId)
    || !Number.isSafeInteger(timestamp)
    || String(timestamp) !== timestampValue
  ) {
    throw new ApiError(401, "invalid_billing_authentication", "Billing authentication failed.");
  }
  try {
    base64urlDecode(nonce, 16);
    base64urlDecode(signature, 64);
  } catch {
    throw new ApiError(401, "invalid_billing_authentication", "Billing authentication failed.");
  }
  const now = Math.floor(Date.now() / 1_000);
  if (Math.abs(now - timestamp) > 300) {
    throw new ApiError(401, "stale_billing_request", "Billing authentication failed.");
  }

  const key = await env.DB.prepare(
    `SELECT billing_account_id, id AS billing_key_id, signing_public_key
       FROM billing_account_keys
      WHERE id = ? AND billing_account_id = ? AND state = 'active'`,
  ).bind(billingKeyId, billingAccountId).first<BillingKeyRow>();
  if (key === null) {
    throw new ApiError(401, "invalid_billing_authentication", "Billing authentication failed.");
  }
  const transcript = billingSignedRequestTranscript({
    billingAccountId,
    billingKeyId,
    timestamp,
    nonce,
    method: request.method,
    pathname: new URL(request.url).pathname,
    bodySHA256: await sha256Base64url(body),
  });
  let valid = false;
  try {
    valid = await verifyEd25519(key.signing_public_key, signature, transcript);
  } catch {
    valid = false;
  }
  if (!valid) {
    throw new ApiError(401, "invalid_billing_authentication", "Billing authentication failed.");
  }
  return { billingAccountId, billingKeyId, nonce, now };
}

export async function consumeBillingNonce(
  env: Env,
  account: AuthenticatedBillingAccount,
): Promise<void> {
  try {
    await env.DB.batch([
      env.DB.prepare(
        "DELETE FROM billing_request_nonces WHERE billing_key_id = ? AND expires_at <= ?",
      ).bind(account.billingKeyId, account.now),
      env.DB.prepare(
        `INSERT INTO billing_request_nonces(
           billing_key_id, nonce, created_at, expires_at
         ) VALUES (?, ?, ?, ?)`,
      ).bind(account.billingKeyId, account.nonce, account.now, account.now + 601),
    ]);
  } catch {
    throw new ApiError(409, "replayed_billing_request", "This billing request was already used.");
  }
}
