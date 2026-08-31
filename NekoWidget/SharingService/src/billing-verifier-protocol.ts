import { base64urlDecode, base64urlEncode, sha256Base64url } from "./encoding";

export const BILLING_VERIFIER_PROTOCOL_VERSION = 1 as const;
export const BILLING_VERIFIER_PATH = "/internal/v1/apple-transactions/verify";
export const BILLING_NOTIFICATION_VERIFIER_PATH = "/internal/v1/apple-notifications/verify";
export const BILLING_SUBSCRIPTION_STATUS_PATH = "/internal/v1/apple-subscriptions/status";
export const BILLING_ACCOUNT_RECOVERY_VERIFIER_PATH = "/internal/v1/apple-billing-recoveries/verify";

const encoder = new TextEncoder();

function ownedBytes(value: Uint8Array): Uint8Array<ArrayBuffer> {
  return new Uint8Array(value);
}

export function billingVerifierRequestTranscript(
  timestamp: number,
  nonce: string,
  bodySHA256: string,
): Uint8Array {
  return encoder.encode([
    "NWB1.VERIFIER.REQUEST",
    String(timestamp),
    nonce,
    bodySHA256,
  ].join("\n"));
}

export function billingVerifierResponseTranscript(
  requestNonce: string,
  status: number,
  bodySHA256: string,
): Uint8Array {
  return encoder.encode([
    "NWB1.VERIFIER.RESPONSE",
    requestNonce,
    String(status),
    bodySHA256,
  ].join("\n"));
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    ownedBytes(base64urlDecode(secret, 32)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export async function signBillingVerifierTranscript(
  secret: string,
  transcript: Uint8Array,
): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    await hmacKey(secret),
    ownedBytes(transcript),
  );
  return base64urlEncode(new Uint8Array(signature));
}

export async function verifyBillingVerifierTranscript(
  secret: string,
  signature: string,
  transcript: Uint8Array,
): Promise<boolean> {
  let signatureBytes: Uint8Array;
  try {
    signatureBytes = base64urlDecode(signature, 32);
  } catch {
    return false;
  }
  return crypto.subtle.verify(
    "HMAC",
    await hmacKey(secret),
    ownedBytes(signatureBytes),
    ownedBytes(transcript),
  );
}

export async function bodySHA256(body: Uint8Array): Promise<string> {
  return sha256Base64url(body);
}
