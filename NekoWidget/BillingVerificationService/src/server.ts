import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import {
  AppleTransactionVerifier,
  InvalidAppleTransactionError,
  RetryableAppleVerificationError,
  type NormalizedBillingTransaction,
} from "./apple-transaction.js";
import type { VerificationServiceConfig } from "./config.js";
import {
  PROTOCOL_VERSION,
  VERIFY_PATH,
  bodySHA256,
  requestTranscript,
  responseTranscript,
  signTranscript,
  verifyTranscript,
} from "./internal-auth.js";

interface TransactionVerifier {
  verify(signedTransactionInfo: string): Promise<NormalizedBillingTransaction>;
}

class RequestError extends Error {
  constructor(readonly status: number) {
    super();
  }
}

async function readBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > 64 * 1024) throw new RequestError(413);
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
) {
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
    if (request.method !== "POST" || request.url !== VERIFY_PATH) {
      sendUnsigned(response, 404);
      return;
    }

    let nonce: string;
    let body: Buffer;
    try {
      if (request.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase()
        !== "application/json") throw new RequestError(415);
      body = await readBody(request);
      nonce = authenticate(request, body, config.sharedSecret);
    } catch (error) {
      sendUnsigned(response, error instanceof RequestError ? error.status : 400);
      return;
    }

    try {
      const signedTransactionInfo = parseTransactionBody(body);
      const verified = await transactionVerifier.verify(signedTransactionInfo);
      sendSigned(response, 200, verified, nonce, config.sharedSecret);
    } catch (error) {
      if (error instanceof RetryableAppleVerificationError) {
        sendSigned(
          response,
          503,
          { error: { code: "apple_verification_temporarily_unavailable" } },
          nonce,
          config.sharedSecret,
        );
      } else {
        const status = error instanceof InvalidAppleTransactionError
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
