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
