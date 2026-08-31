import { createHash, createHmac, timingSafeEqual } from "node:crypto";

export const PROTOCOL_VERSION = 1 as const;
export const VERIFY_PATH = "/internal/v1/apple-transactions/verify";
export const VERIFY_NOTIFICATION_PATH = "/internal/v1/apple-notifications/verify";
export const SUBSCRIPTION_STATUS_PATH = "/internal/v1/apple-subscriptions/status";

export function bodySHA256(body: Buffer): string {
  return createHash("sha256").update(body).digest("base64url");
}

export function requestTranscript(
  timestamp: number,
  nonce: string,
  bodyHash: string,
): Buffer {
  return Buffer.from([
    "NWB1.VERIFIER.REQUEST",
    String(timestamp),
    nonce,
    bodyHash,
  ].join("\n"), "utf8");
}

export function responseTranscript(
  requestNonce: string,
  status: number,
  bodyHash: string,
): Buffer {
  return Buffer.from([
    "NWB1.VERIFIER.RESPONSE",
    requestNonce,
    String(status),
    bodyHash,
  ].join("\n"), "utf8");
}

export function signTranscript(secret: Buffer, transcript: Buffer): string {
  return createHmac("sha256", secret).update(transcript).digest("base64url");
}

export function verifyTranscript(
  secret: Buffer,
  signature: string,
  transcript: Buffer,
): boolean {
  if (!/^[A-Za-z0-9_-]{43}$/u.test(signature)) return false;
  const expected = Buffer.from(signTranscript(secret, transcript), "ascii");
  const actual = Buffer.from(signature, "ascii");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}
