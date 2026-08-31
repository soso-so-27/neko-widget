import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { SignedDataVerifier } from "@apple/app-store-server-library";
import {
  AppleTransactionVerifier,
  InvalidAppleTransactionError,
  RetryableAppleVerificationError,
  type NormalizedBillingTransaction,
} from "./apple-transaction.js";
import {
  AppleNotificationVerifier,
  InvalidAppleNotificationError,
  RetryableAppleNotificationError,
  type NormalizedAppleNotification,
} from "./apple-notification.js";
import {
  AppleSubscriptionStatusService,
  InvalidAppleSubscriptionStatusError,
  RetryableAppleSubscriptionStatusError,
  type NormalizedSubscriptionStatus,
} from "./apple-subscription-status.js";
import type { VerificationServiceConfig } from "./config.js";
import {
  AppleAccountRecoveryVerifier,
  type AccountRecoveryEvidence,
  type AccountRecoveryVerificationInput,
} from "./apple-account-recovery.js";
import {
  PROTOCOL_VERSION,
  SUBSCRIPTION_STATUS_PATH,
  ACCOUNT_RECOVERY_VERIFY_PATH,
  VERIFY_PATH,
  VERIFY_NOTIFICATION_PATH,
  bodySHA256,
  requestTranscript,
  responseTranscript,
  signTranscript,
  verifyTranscript,
} from "./internal-auth.js";

interface TransactionVerifier {
  verify(signedTransactionInfo: string): Promise<NormalizedBillingTransaction>;
}

interface NotificationVerifier {
  verify(signedPayload: string): Promise<NormalizedAppleNotification>;
}

interface SubscriptionStatusService {
  get(transactionId: string): Promise<NormalizedSubscriptionStatus>;
}

interface AccountRecoveryVerifier {
  verify(input: AccountRecoveryVerificationInput): Promise<AccountRecoveryEvidence>;
}

export interface BillingAppleServices {
  notificationVerifier?: NotificationVerifier;
  subscriptionStatusService?: SubscriptionStatusService;
  accountRecoveryVerifier?: AccountRecoveryVerifier;
}

class RequestError extends Error {
  constructor(readonly status: number) {
    super();
  }
}

async function readBody(request: IncomingMessage, maximumBytes = 64 * 1024): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > maximumBytes) throw new RequestError(413);
    chunks.push(buffer);
  }
  return Buffer.concat(chunks, total);
}

function header(request: IncomingMessage, name: string): string {
  const value = request.headers[name];
  if (typeof value !== "string") throw new RequestError(401);
  return value;
}

function authenticate(
  request: IncomingMessage,
  body: Buffer,
  secret: Buffer,
): string {
  if (header(request, "neko-billing-protocol-version") !== String(PROTOCOL_VERSION)) {
    throw new RequestError(401);
  }
  const timestampValue = header(request, "neko-billing-timestamp");
  const timestamp = Number(timestampValue);
  const nonce = header(request, "neko-billing-nonce");
  const signature = header(request, "neko-billing-signature");
  if (
    !Number.isSafeInteger(timestamp)
    || String(timestamp) !== timestampValue
    || Math.abs(Math.floor(Date.now() / 1_000) - timestamp) > 300
    || !/^[A-Za-z0-9_-]{22}$/u.test(nonce)
    || Buffer.from(nonce, "base64url").length !== 16
    || !verifyTranscript(
      secret,
      signature,
      requestTranscript(timestamp, nonce, bodySHA256(body)),
    )
  ) {
    throw new RequestError(401);
  }
  return nonce;
}

function parseTransactionBody(body: Buffer): string {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new RequestError(400);
  }
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new RequestError(400);
  }
  const record = value as Record<string, unknown>;
  const fields = Object.keys(record).sort();
  if (
    fields.length !== 2
    || fields[0] !== "protocolVersion"
    || fields[1] !== "signedTransactionInfo"
    || record.protocolVersion !== PROTOCOL_VERSION
    || typeof record.signedTransactionInfo !== "string"
    || record.signedTransactionInfo.length > 48 * 1024
    || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(record.signedTransactionInfo)
  ) {
    throw new RequestError(400);
  }
  return record.signedTransactionInfo;
}

function parseSingleJWSBody(body: Buffer, field: "signedPayload"): string {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new RequestError(400);
  }
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new RequestError(400);
  }
  const record = value as Record<string, unknown>;
  const fields = Object.keys(record).sort();
  if (
    fields.length !== 2
    || fields[0] !== "protocolVersion"
    || fields[1] !== field
    || record.protocolVersion !== PROTOCOL_VERSION
    || typeof record[field] !== "string"
    || record[field].length > 60 * 1024
    || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(record[field])
  ) throw new RequestError(400);
  return record[field];
}

function parseStatusBody(body: Buffer): string {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new RequestError(400);
  }
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new RequestError(400);
  }
  const record = value as Record<string, unknown>;
  const fields = Object.keys(record).sort();
  if (
    fields.length !== 2
    || fields[0] !== "originalTransactionId"
    || fields[1] !== "protocolVersion"
    || record.protocolVersion !== PROTOCOL_VERSION
    || typeof record.originalTransactionId !== "string"
    || !/^\d{1,32}$/u.test(record.originalTransactionId)
  ) throw new RequestError(400);
  return record.originalTransactionId;
}

function parseRecoveryBody(body: Buffer): AccountRecoveryVerificationInput {
  let value: unknown;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body)); }
  catch { throw new RequestError(400); }
  if (value === null || Array.isArray(value) || typeof value !== "object") throw new RequestError(400);
  const record = value as Record<string, unknown>;
  const expected = [
    "billingAccountId", "deviceVerificationId", "expectedAppTransactionId", "expectedOriginalTransactionId",
    "expectedTransactionId", "protocolVersion", "signedAppTransactionInfo",
    "signedTransactionInfo",
  ].sort();
  const actual = Object.keys(record).sort();
  const jws = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
  const appleUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
  const tx = /^\d{1,32}$/u;
  if (
    actual.length !== expected.length || actual.some((field, index) => field !== expected[index])
    || record.protocolVersion !== PROTOCOL_VERSION
    || typeof record.billingAccountId !== "string" || !uuid.test(record.billingAccountId)
    || typeof record.deviceVerificationId !== "string" || !appleUuid.test(record.deviceVerificationId)
    || typeof record.expectedAppTransactionId !== "string"
    || !/^[^\u0000-\u001f\u007f-\u009f]{1,256}$/u.test(record.expectedAppTransactionId)
    || typeof record.expectedTransactionId !== "string" || !tx.test(record.expectedTransactionId)
    || typeof record.expectedOriginalTransactionId !== "string" || !tx.test(record.expectedOriginalTransactionId)
    || typeof record.signedAppTransactionInfo !== "string"
    || record.signedAppTransactionInfo.length > 60 * 1024 || !jws.test(record.signedAppTransactionInfo)
    || typeof record.signedTransactionInfo !== "string"
    || record.signedTransactionInfo.length > 60 * 1024 || !jws.test(record.signedTransactionInfo)
  ) throw new RequestError(400);
  return record as unknown as AccountRecoveryVerificationInput;
}

function sendUnsigned(response: ServerResponse, status: number): void {
  const body = Buffer.from(JSON.stringify({ error: { code: "unauthorized" } }));
  response.writeHead(status, {
    "Cache-Control": "no-store, max-age=0",
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    "X-Content-Type-Options": "nosniff",
  });
  response.end(body);
}

function sendSigned(
  response: ServerResponse,
  status: number,
  value: unknown,
  requestNonce: string,
  secret: Buffer,
): void {
  const body = Buffer.from(JSON.stringify(value));
  const signature = signTranscript(
    secret,
    responseTranscript(requestNonce, status, bodySHA256(body)),
  );
  response.writeHead(status, {
    "Cache-Control": "no-store, max-age=0",
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    "Neko-Billing-Response-Signature": signature,
    "X-Content-Type-Options": "nosniff",
  });
  response.end(body);
}

export function createBillingVerificationServer(
  config: VerificationServiceConfig,
  transactionVerifier: TransactionVerifier = new AppleTransactionVerifier(config),
  suppliedServices: BillingAppleServices = {},
) {
  let signedDataVerifier: SignedDataVerifier | undefined;
  const sharedSignedDataVerifier = (): SignedDataVerifier => {
    signedDataVerifier ??= new SignedDataVerifier(
      config.rootCertificates,
      true,
      config.environment,
      config.bundleId,
      config.appAppleId,
    );
    return signedDataVerifier;
  };
  // Disabled capabilities must not initialize credentials, certificates, or
  // network clients. This keeps each runtime switch an actual isolation
  // boundary instead of merely rejecting after partial startup.
  const notificationVerifier = suppliedServices.notificationVerifier
    ?? (config.notificationVerificationEnabled === true
      ? new AppleNotificationVerifier(config, sharedSignedDataVerifier()) : null);
  const subscriptionStatusService = suppliedServices.subscriptionStatusService
    ?? (config.subscriptionStatusEnabled === true && config.serverAPI !== undefined
      ? new AppleSubscriptionStatusService(config, sharedSignedDataVerifier()) : null);
  const accountRecoveryVerifier = suppliedServices.accountRecoveryVerifier
    ?? (config.accountRecoveryVerificationEnabled === true
      ? new AppleAccountRecoveryVerifier(config, sharedSignedDataVerifier()) : null);
  return createServer(async (request, response) => {
    if (request.method === "GET" && request.url === "/health") {
      const body = Buffer.from(JSON.stringify({ status: "ok", protocolVersion: 1 }));
      response.writeHead(200, {
        "Cache-Control": "no-store, max-age=0",
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": body.length,
        "X-Content-Type-Options": "nosniff",
      });
      response.end(body);
      return;
    }
    const supportedPath = request.url === VERIFY_PATH
      || request.url === VERIFY_NOTIFICATION_PATH
      || request.url === SUBSCRIPTION_STATUS_PATH
      || request.url === ACCOUNT_RECOVERY_VERIFY_PATH;
    if (request.method !== "POST" || !supportedPath) {
      sendUnsigned(response, 404);
      return;
    }

    let nonce: string;
    let body: Buffer;
    try {
      if (request.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase()
        !== "application/json") throw new RequestError(415);
      body = await readBody(request, request.url === ACCOUNT_RECOVERY_VERIFY_PATH ? 128 * 1024 : 64 * 1024);
      nonce = authenticate(request, body, config.sharedSecret);
    } catch (error) {
      sendUnsigned(response, error instanceof RequestError ? error.status : 400);
      return;
    }

    try {
      if (request.url === VERIFY_PATH) {
        const signedTransactionInfo = parseTransactionBody(body);
        const verified = await transactionVerifier.verify(signedTransactionInfo);
        sendSigned(response, 200, verified, nonce, config.sharedSecret);
      } else if (request.url === VERIFY_NOTIFICATION_PATH) {
        if (config.notificationVerificationEnabled !== true || notificationVerifier === null) {
          sendSigned(
            response,
            503,
            { error: { code: "apple_notification_verifier_disabled" } },
            nonce,
            config.sharedSecret,
          );
          return;
        }
        const signedPayload = parseSingleJWSBody(body, "signedPayload");
        sendSigned(
          response,
          200,
          await notificationVerifier.verify(signedPayload),
          nonce,
          config.sharedSecret,
        );
      } else if (request.url === SUBSCRIPTION_STATUS_PATH) {
        if (config.subscriptionStatusEnabled !== true || subscriptionStatusService === null) {
          sendSigned(
            response,
            503,
            { error: { code: "apple_subscription_status_disabled" } },
            nonce,
            config.sharedSecret,
          );
          return;
        }
        const originalTransactionId = parseStatusBody(body);
        sendSigned(
          response,
          200,
          await subscriptionStatusService.get(originalTransactionId),
          nonce,
          config.sharedSecret,
        );
      } else {
        if (config.accountRecoveryVerificationEnabled !== true || accountRecoveryVerifier === null) {
          sendSigned(response, 503, { error: { code: "apple_account_recovery_verifier_disabled" } }, nonce, config.sharedSecret);
          return;
        }
        sendSigned(response, 200, await accountRecoveryVerifier.verify(parseRecoveryBody(body)), nonce, config.sharedSecret);
      }
    } catch (error) {
      if (
        error instanceof RetryableAppleVerificationError
        || error instanceof RetryableAppleNotificationError
        || error instanceof RetryableAppleSubscriptionStatusError
      ) {
        sendSigned(
          response,
          503,
          { error: { code: "apple_verification_temporarily_unavailable" } },
          nonce,
          config.sharedSecret,
        );
      } else {
        const status = error instanceof InvalidAppleTransactionError
          || error instanceof InvalidAppleNotificationError
          || error instanceof InvalidAppleSubscriptionStatusError
          || error instanceof RequestError ? 400 : 500;
        sendSigned(
          response,
          status,
          { error: { code: status === 400 ? "invalid_apple_transaction" : "internal_error" } },
          nonce,
          config.sharedSecret,
        );
      }
    }
  });
}

export async function listen(
  config: VerificationServiceConfig,
): Promise<{ close: () => Promise<void>; port: number }> {
  const server = createBillingVerificationServer(config);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, "127.0.0.1", resolve);
  });
  const address = server.address() as AddressInfo;
  return {
    port: address.port,
    close: () => new Promise<void>((resolve, reject) => {
      server.close((error) => error === undefined ? resolve() : reject(error));
    }),
  };
}
