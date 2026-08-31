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

export interface WindowSponsorshipConsentFields {
  operation: "sponsor" | "unsponsor";
  clientRequestId: string;
  billingAccountId: string;
  windowLineageId: string;
  expectedGeneration: number;
  expectedCurrentBillingAccountId?: string | undefined;
  consentSpaceId?: string | undefined;
  ownerParticipantId?: string | undefined;
  ownerDeviceId?: string | undefined;
  consentIssuedAt?: number | undefined;
  consentMembershipRevision?: number | undefined;
  ownerConsentNonce?: string | undefined;
}

export function windowSponsorshipConsentTranscript(
  fields: WindowSponsorshipConsentFields,
): Uint8Array {
  return encodeCanonicalFields([
    "NWB1.WINDOW.SPONSORSHIP", "1", fields.operation, fields.clientRequestId,
    fields.billingAccountId, fields.windowLineageId, String(fields.expectedGeneration),
    fields.expectedCurrentBillingAccountId ?? "",
    fields.consentSpaceId ?? "", fields.ownerParticipantId ?? "", fields.ownerDeviceId ?? "",
    fields.consentIssuedAt === undefined ? "" : String(fields.consentIssuedAt),
    fields.consentMembershipRevision === undefined ? "" : String(fields.consentMembershipRevision),
    fields.ownerConsentNonce ?? "",
  ]);
}
