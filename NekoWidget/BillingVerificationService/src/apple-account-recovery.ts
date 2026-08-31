import { createHash, timingSafeEqual } from "node:crypto";
import {
  Environment,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
  type AppTransaction,
  type JWSTransactionDecodedPayload,
} from "@apple/app-store-server-library";
import {
  InvalidAppleTransactionError,
  RetryableAppleVerificationError,
  normalizeVerifiedTransaction,
  type NormalizedBillingTransaction,
} from "./apple-transaction.js";
import type { VerificationServiceConfig } from "./config.js";

export interface AccountRecoveryEvidence {
  protocolVersion: 1;
  appTransactionIdHash: string;
  transaction: NormalizedBillingTransaction;
}

export interface AccountRecoveryVerificationInput {
  signedAppTransactionInfo: string;
  signedTransactionInfo: string;
  deviceVerificationId: string;
  expectedAppTransactionId: string;
  expectedTransactionId: string;
  expectedOriginalTransactionId: string;
  billingAccountId: string;
}

interface RecoveryDecoder {
  verifyAndDecodeAppTransaction(value: string): Promise<AppTransaction>;
  verifyAndDecodeTransaction(value: string): Promise<JWSTransactionDecodedPayload>;
}

const canonicalUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const opaqueId = /^[^\u0000-\u001f\u007f-\u009f]{1,256}$/u;
const maximumClockSkewMs = 5 * 60 * 1_000;

function deviceProof(payload: {
  deviceVerification?: unknown;
  deviceVerificationNonce?: unknown;
}, deviceVerificationId: string): boolean {
  const nonce = typeof payload.deviceVerificationNonce === "string"
    ? payload.deviceVerificationNonce.toLowerCase() : undefined;
  const proof = payload.deviceVerification;
  if (nonce === undefined || !canonicalUuid.test(nonce) || typeof proof !== "string") return false;
  let actual: Buffer;
  try {
    actual = Buffer.from(proof, "base64");
  } catch {
    return false;
  }
  if (actual.length !== 48 || actual.toString("base64") !== proof) return false;
  const expected = createHash("sha384")
    .update(`${nonce}${deviceVerificationId}`, "ascii")
    .digest();
  return timingSafeEqual(actual, expected);
}

function appTransactionIdHash(environment: string, value: string): string {
  return createHash("sha256")
    .update("NWB1.APP_TRANSACTION_ID\0", "ascii")
    .update(environment, "ascii")
    .update("\0", "ascii")
    .update(value, "utf8")
    .digest("base64url");
}

export class AppleAccountRecoveryVerifier {
  private readonly verifier: RecoveryDecoder;

  constructor(private readonly config: VerificationServiceConfig, verifier?: RecoveryDecoder) {
    this.verifier = verifier ?? new SignedDataVerifier(
      config.rootCertificates,
      true,
      config.environment,
      config.bundleId,
      config.appAppleId,
    );
  }

  async verify(input: AccountRecoveryVerificationInput): Promise<AccountRecoveryEvidence> {
    if (!canonicalUuid.test(input.deviceVerificationId)) throw new InvalidAppleTransactionError();
    let app: AppTransaction;
    let rawTransaction: JWSTransactionDecodedPayload;
    try {
      [app, rawTransaction] = await Promise.all([
        this.verifier.verifyAndDecodeAppTransaction(input.signedAppTransactionInfo),
        this.verifier.verifyAndDecodeTransaction(input.signedTransactionInfo),
      ]);
    } catch (error) {
      if (error instanceof VerificationException
        && error.status !== VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
        throw new InvalidAppleTransactionError();
      }
      throw new RetryableAppleVerificationError();
    }
    const transaction = normalizeVerifiedTransaction(rawTransaction, this.config);
    const stableId = app.appTransactionId;
    if (
      typeof stableId !== "string" || !opaqueId.test(stableId)
      || stableId !== input.expectedAppTransactionId
      || rawTransaction.appTransactionId !== stableId
      || app.bundleId !== this.config.bundleId
      || app.receiptType !== this.config.environment
      || (this.config.environment === Environment.PRODUCTION
        && app.appAppleId !== this.config.appAppleId)
      || !Number.isSafeInteger(app.receiptCreationDate)
      || (app.receiptCreationDate as number) <= 0
      || (app.receiptCreationDate as number) > Date.now() + maximumClockSkewMs
      || !deviceProof(app, input.deviceVerificationId)
      || !deviceProof(rawTransaction as JWSTransactionDecodedPayload & {
        deviceVerification?: unknown;
        deviceVerificationNonce?: unknown;
      }, input.deviceVerificationId)
      || transaction.transactionId !== input.expectedTransactionId
      || transaction.originalTransactionId !== input.expectedOriginalTransactionId
      || transaction.billingAccountId !== input.billingAccountId
      || transaction.revocationDateMs !== null
      || transaction.revocationReason !== null
      || transaction.isUpgraded
    ) throw new InvalidAppleTransactionError();
    return { protocolVersion: 1, appTransactionIdHash: appTransactionIdHash(transaction.environment, stableId), transaction };
  }
}
