import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import {
  APIError,
  APIException,
  AppStoreServerAPIClient,
  Environment,
  type NotificationHistoryRequest,
  type NotificationHistoryResponse,
} from "@apple/app-store-server-library";
import {
  InvalidAppleNotificationError,
  RetryableAppleNotificationError,
  type NormalizedAppleNotification,
} from "./apple-notification.js";
import type { VerificationServiceConfig } from "./config.js";

const maximumSignedPayloadBytes = 60 * 1024;
const maximumApplePaginationTokenBytes = 2_048;
const maximumBoundCursorBytes = 4_096;
const maximumClockSkewMs = 5 * 60 * 1_000;
const sandboxRetentionMs = 30 * 24 * 60 * 60 * 1_000;
const productionRetentionMs = 180 * 24 * 60 * 60 * 1_000;
const compactJWSPattern = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u;
const paginationTokenPattern = /^[\x21-\x7e]+$/u;
const boundCursorPattern = /^nh1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]{43})$/u;
const payloadHashPattern = /^[A-Za-z0-9_-]{43}$/u;

const sendAttemptResults = new Set([
  "SUCCESS",
  "TIMED_OUT",
  "TLS_ISSUE",
  "CIRCULAR_REDIRECT",
  "NO_RESPONSE",
  "SOCKET_ISSUE",
  "UNSUPPORTED_CHARSET",
  "INVALID_RESPONSE",
  "PREMATURE_CLOSE",
  "UNSUCCESSFUL_HTTP_RESPONSE_CODE",
  "OTHER",
]);

export interface AppleNotificationHistoryInput {
  startDateMs: number;
  endDateMs: number;
  paginationToken: string | null;
}

export interface NormalizedAppleNotificationHistoryRecord {
  payloadHash: string;
  notification: NormalizedAppleNotification;
}

export interface NormalizedAppleNotificationHistoryPage {
  protocolVersion: 1;
  requestedStartDateMs: number;
  requestedEndDateMs: number;
  environment: "Sandbox" | "Production";
  bundleId: string;
  hasMore: boolean;
  nextPaginationToken: string | null;
  records: NormalizedAppleNotificationHistoryRecord[];
}

export interface AppleNotificationHistoryProvider {
  getNotificationHistory(
    paginationToken: string | null,
    request: NotificationHistoryRequest,
  ): Promise<NotificationHistoryResponse>;
}

export interface AppleHistoryNotificationVerifier {
  verify(signedPayload: string): Promise<NormalizedAppleNotification>;
}

export class InvalidAppleNotificationHistoryError extends Error {}
export class RetryableAppleNotificationHistoryError extends Error {}
export class AppleNotificationHistoryCursorResetRequiredError extends Error {}
export class AppleNotificationHistoryConfigurationError extends Error {}

function record(value: unknown): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new InvalidAppleNotificationHistoryError();
  }
  return value as Record<string, unknown>;
}

function exactFields(value: Record<string, unknown>, expected: readonly string[]): void {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  if (
    actual.length !== sortedExpected.length
    || actual.some((field, index) => field !== sortedExpected[index])
  ) throw new InvalidAppleNotificationHistoryError();
}

function validBoundCursor(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 1
    && Buffer.byteLength(value, "utf8") <= maximumBoundCursorBytes
    && paginationTokenPattern.test(value);
}

function validApplePaginationToken(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 1
    && Buffer.byteLength(value, "utf8") <= maximumApplePaginationTokenBytes
    && paginationTokenPattern.test(value);
}

function configuredEnvironment(
  config: Pick<VerificationServiceConfig, "environment">,
): "Sandbox" | "Production" {
  return config.environment === Environment.SANDBOX ? "Sandbox" : "Production";
}

export function parseAppleNotificationHistoryInput(
  value: unknown,
  config: Pick<VerificationServiceConfig, "environment">,
  nowMs = Date.now(),
): AppleNotificationHistoryInput {
  const input = record(value);
  exactFields(input, ["protocolVersion", "startDateMs", "endDateMs", "paginationToken"]);
  const startDateMs = input.startDateMs;
  const endDateMs = input.endDateMs;
  const paginationToken = input.paginationToken;
  const retentionMs = config.environment === Environment.SANDBOX
    ? sandboxRetentionMs : productionRetentionMs;
  if (
    input.protocolVersion !== 1
    || !Number.isSafeInteger(startDateMs)
    || (startDateMs as number) <= 0
    || !Number.isSafeInteger(endDateMs)
    || (endDateMs as number) <= (startDateMs as number)
    || (startDateMs as number) < nowMs - retentionMs
    || (endDateMs as number) > nowMs + maximumClockSkewMs
    || (paginationToken !== null && !validBoundCursor(paginationToken))
  ) throw new InvalidAppleNotificationHistoryError();
  return {
    startDateMs: startDateMs as number,
    endDateMs: endDateMs as number,
    paginationToken: paginationToken as string | null,
  };
}

interface BoundHistoryCursor {
  appleToken: string;
  startDateMs: number;
  endDateMs: number;
  environment: "Sandbox" | "Production";
  bundleId: string;
}

function cursorSignature(payload: string, secret: Buffer): Buffer {
  return createHmac("sha256", secret)
    .update("NWB1.NOTIFICATION.HISTORY.CURSOR\n", "ascii")
    .update(payload, "ascii")
    .digest();
}

function encodeBoundCursor(
  cursor: BoundHistoryCursor,
  secret: Buffer,
): string {
  if (!validApplePaginationToken(cursor.appleToken)) {
    throw new InvalidAppleNotificationHistoryError();
  }
  const payload = Buffer.from(JSON.stringify({
    protocolVersion: 1,
    appleToken: cursor.appleToken,
    startDateMs: cursor.startDateMs,
    endDateMs: cursor.endDateMs,
    environment: cursor.environment,
    bundleId: cursor.bundleId,
  }), "utf8").toString("base64url");
  const result = `nh1.${payload}.${cursorSignature(payload, secret).toString("base64url")}`;
  if (!validBoundCursor(result)) throw new InvalidAppleNotificationHistoryError();
  return result;
}

function decodeBoundCursor(
  value: string,
  expected: Omit<BoundHistoryCursor, "appleToken">,
  secret: Buffer,
): string {
  const match = value.match(boundCursorPattern);
  if (match?.[1] === undefined || match[2] === undefined) {
    throw new AppleNotificationHistoryCursorResetRequiredError();
  }
  const payload = match[1];
  const suppliedSignature = Buffer.from(match[2], "base64url");
  const expectedSignature = cursorSignature(payload, secret);
  if (suppliedSignature.length !== expectedSignature.length
      || !timingSafeEqual(suppliedSignature, expectedSignature)) {
    throw new AppleNotificationHistoryCursorResetRequiredError();
  }
  let raw: unknown;
  try {
    const bytes = Buffer.from(payload, "base64url");
    if (bytes.toString("base64url") !== payload) throw new Error();
    raw = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new AppleNotificationHistoryCursorResetRequiredError();
  }
  if (raw === null || Array.isArray(raw) || typeof raw !== "object") {
    throw new AppleNotificationHistoryCursorResetRequiredError();
  }
  const cursor = raw as Record<string, unknown>;
  const actual = Object.keys(cursor).sort();
  const fields = [
    "appleToken", "bundleId", "endDateMs", "environment",
    "protocolVersion", "startDateMs",
  ].sort();
  if (
    actual.length !== fields.length
    || actual.some((field, index) => field !== fields[index])
    || cursor.protocolVersion !== 1
    || !validApplePaginationToken(cursor.appleToken)
    || cursor.startDateMs !== expected.startDateMs
    || cursor.endDateMs !== expected.endDateMs
    || cursor.environment !== expected.environment
    || cursor.bundleId !== expected.bundleId
  ) throw new AppleNotificationHistoryCursorResetRequiredError();
  return cursor.appleToken;
}

function validateSendAttempts(value: unknown): void {
  if (!Array.isArray(value) || value.length > 6) {
    throw new InvalidAppleNotificationHistoryError();
  }
  for (const rawAttempt of value) {
    const attempt = record(rawAttempt);
    exactFields(attempt, ["attemptDate", "sendAttemptResult"]);
    if (
      !Number.isSafeInteger(attempt.attemptDate)
      || (attempt.attemptDate as number) <= 0
      || typeof attempt.sendAttemptResult !== "string"
      || !sendAttemptResults.has(attempt.sendAttemptResult)
    ) throw new InvalidAppleNotificationHistoryError();
  }
}

async function normalizeHistoryResponse(
  response: NotificationHistoryResponse,
  input: AppleNotificationHistoryInput,
  verifier: AppleHistoryNotificationVerifier,
  config: Pick<VerificationServiceConfig, "bundleId" | "environment" | "sharedSecret">,
): Promise<NormalizedAppleNotificationHistoryPage> {
  const page = record(response);
  const pageFields = Object.keys(page).sort();
  const fieldsWithoutToken = ["hasMore", "notificationHistory"];
  const fieldsWithToken = ["hasMore", "notificationHistory", "paginationToken"];
  if (
    (pageFields.join(",") !== fieldsWithoutToken.sort().join(",")
      && pageFields.join(",") !== fieldsWithToken.sort().join(","))
    || typeof page.hasMore !== "boolean"
    || !Array.isArray(page.notificationHistory)
    || page.notificationHistory.length > 20
    || (page.hasMore && !validApplePaginationToken(page.paginationToken))
    || (page.paginationToken !== undefined
      && !validApplePaginationToken(page.paginationToken))
  ) throw new InvalidAppleNotificationHistoryError();

  const environment = configuredEnvironment(config);
  const records: NormalizedAppleNotificationHistoryRecord[] = [];
  const hashes = new Set<string>();
  const notificationUUIDs = new Set<string>();
  for (const rawItem of page.notificationHistory) {
    const item = record(rawItem);
    const itemFields = Object.keys(item).sort().join(",");
    if (itemFields !== "signedPayload" && itemFields !== "sendAttempts,signedPayload") {
      throw new InvalidAppleNotificationHistoryError();
    }
    const signedPayload = item.signedPayload;
    if (
      typeof signedPayload !== "string"
      || Buffer.byteLength(signedPayload, "ascii") > maximumSignedPayloadBytes
      || !compactJWSPattern.test(signedPayload)
    ) throw new InvalidAppleNotificationHistoryError();
    if (item.sendAttempts !== undefined) validateSendAttempts(item.sendAttempts);

    const payloadHash = createHash("sha256").update(signedPayload, "ascii").digest("base64url");
    if (!payloadHashPattern.test(payloadHash) || hashes.has(payloadHash)) {
      throw new InvalidAppleNotificationHistoryError();
    }
    let notification: NormalizedAppleNotification;
    try {
      notification = await verifier.verify(signedPayload);
    } catch (error) {
      if (error instanceof InvalidAppleNotificationError) {
        throw new InvalidAppleNotificationHistoryError();
      }
      if (error instanceof RetryableAppleNotificationError) {
        throw new RetryableAppleNotificationHistoryError();
      }
      throw new RetryableAppleNotificationHistoryError();
    }
    if (
      notification.protocolVersion !== 1
      || notification.environment !== environment
      || notification.bundleId !== config.bundleId
      || notificationUUIDs.has(notification.notificationUUID)
    ) throw new InvalidAppleNotificationHistoryError();
    hashes.add(payloadHash);
    notificationUUIDs.add(notification.notificationUUID);
    records.push({ payloadHash, notification });
  }

  return {
    protocolVersion: 1,
    requestedStartDateMs: input.startDateMs,
    requestedEndDateMs: input.endDateMs,
    environment,
    bundleId: config.bundleId,
    hasMore: page.hasMore,
    nextPaginationToken: page.hasMore ? encodeBoundCursor({
      appleToken: page.paginationToken as string,
      startDateMs: input.startDateMs,
      endDateMs: input.endDateMs,
      environment,
      bundleId: config.bundleId,
    }, config.sharedSecret) : null,
    records,
  };
}

export class AppleNotificationHistoryService {
  private readonly provider: AppleNotificationHistoryProvider;

  constructor(
    private readonly config: VerificationServiceConfig,
    private readonly verifier: AppleHistoryNotificationVerifier,
    provider?: AppleNotificationHistoryProvider,
  ) {
    const api = config.serverAPI;
    if (provider !== undefined) {
      this.provider = provider;
    } else if (api !== undefined) {
      this.provider = new AppStoreServerAPIClient(
        api.signingKey,
        api.keyId,
        api.issuerId,
        config.bundleId,
        config.environment,
      );
    } else {
      this.provider = {
        async getNotificationHistory() {
          throw new RetryableAppleNotificationHistoryError();
        },
      };
    }
  }

  async get(
    input: AppleNotificationHistoryInput,
    nowMs = Date.now(),
  ): Promise<NormalizedAppleNotificationHistoryPage> {
    const safeInput = parseAppleNotificationHistoryInput(
      { protocolVersion: 1, ...input },
      this.config,
      nowMs,
    );
    let response: NotificationHistoryResponse;
    try {
      const applePaginationToken = safeInput.paginationToken === null ? null : decodeBoundCursor(
        safeInput.paginationToken,
        {
          startDateMs: safeInput.startDateMs,
          endDateMs: safeInput.endDateMs,
          environment: configuredEnvironment(this.config),
          bundleId: this.config.bundleId,
        },
        this.config.sharedSecret,
      );
      response = await this.provider.getNotificationHistory(
        applePaginationToken,
        { startDate: safeInput.startDateMs, endDate: safeInput.endDateMs },
      );
    } catch (error) {
      if (
        error instanceof InvalidAppleNotificationHistoryError
        || error instanceof RetryableAppleNotificationHistoryError
        || error instanceof AppleNotificationHistoryCursorResetRequiredError
        || error instanceof AppleNotificationHistoryConfigurationError
      ) throw error;
      if (error instanceof APIException) {
        if (
          error.apiError === APIError.INVALID_PAGINATION_TOKEN
          || error.apiError === APIError.PAGINATION_TOKEN_EXPIRED
        ) throw new AppleNotificationHistoryCursorResetRequiredError();
        if (
          error.httpStatusCode === 401
          || error.httpStatusCode === 403
          || error.httpStatusCode === 404
        ) throw new AppleNotificationHistoryConfigurationError();
        if (
          error.httpStatusCode >= 400
          && error.httpStatusCode < 500
          && error.httpStatusCode !== 429
        ) throw new InvalidAppleNotificationHistoryError();
      }
      throw new RetryableAppleNotificationHistoryError();
    }
    return normalizeHistoryResponse(response, safeInput, this.verifier, this.config);
  }
}
