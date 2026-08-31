import { encodeCanonicalFields } from "./protocol";

export interface BillingAccountCreationFields {
  clientRequestId: string;
  signingPublicKey: string;
}

export function billingAccountCreationTranscript(
  fields: BillingAccountCreationFields,
): Uint8Array {
  return encodeCanonicalFields([
    "NWB1.ACCOUNT.CREATE",
    "1",
    fields.clientRequestId,
    fields.signingPublicKey,
  ]);
}

export interface BillingAccountRecoveryFields {
  clientRequestId: string;
  billingAccountId: string;
  signingPublicKey: string;
  deviceVerificationId: string;
  expectedAppTransactionId: string;
  expectedTransactionId: string;
  expectedOriginalTransactionId: string;
  signedAppTransactionHash: string;
  signedTransactionHash: string;
}

export function billingAccountRecoveryTranscript(fields: BillingAccountRecoveryFields): Uint8Array {
  return encodeCanonicalFields([
    "NWB1.ACCOUNT.RECOVER", "1", fields.clientRequestId, fields.billingAccountId,
    fields.signingPublicKey, fields.deviceVerificationId, fields.expectedAppTransactionId, fields.expectedTransactionId,
    fields.expectedOriginalTransactionId, fields.signedAppTransactionHash,
    fields.signedTransactionHash,
  ]);
}

export interface BillingSignedRequestFields {
  billingAccountId: string;
  billingKeyId: string;
  timestamp: number;
  nonce: string;
  method: string;
  pathname: string;
  bodySHA256: string;
}

export function billingSignedRequestTranscript(
  fields: BillingSignedRequestFields,
): Uint8Array {
  return encodeCanonicalFields([
    "NWB1.REQUEST",
    "1",
    fields.billingAccountId,
    fields.billingKeyId,
    String(fields.timestamp),
    fields.nonce,
    fields.method.toUpperCase(),
    fields.pathname,
    fields.bodySHA256,
  ]);
}
