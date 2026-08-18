import { ApiError } from "./errors";

export const PROTOCOL_VERSION = 1 as const;
export const ENVELOPE_ALGORITHM =
  "X25519-HKDF-SHA256-CHACHA20POLY1305" as const;

const encoder = new TextEncoder();

export function encodeCanonicalFields(fields: readonly string[]): Uint8Array {
  const encoded = fields.map((field) => encoder.encode(field));
  const byteLength = encoded.reduce((total, field) => total + 2 + field.length, 0);
  const output = new Uint8Array(byteLength);
  const view = new DataView(output.buffer);
  let offset = 0;

  for (const field of encoded) {
    if (field.length > 0xffff) {
      throw new ApiError(400, "field_too_long", "A canonical field is too long.");
    }
    view.setUint16(offset, field.length, false);
    offset += 2;
    output.set(field, offset);
    offset += field.length;
  }
  return output;
}

export interface CreationFields {
  clientRequestId: string;
  participantId: string;
  agreementPublicKey: string;
  signingPublicKey: string;
  invitationProofPublicKey: string;
  dailyBoundaryMinuteUTC: number;
}

export function creationTranscript(fields: CreationFields): Uint8Array {
  return encodeCanonicalFields([
    "NW1.CREATE",
    "1",
    fields.clientRequestId,
    fields.participantId,
    fields.agreementPublicKey,
    fields.signingPublicKey,
    fields.invitationProofPublicKey,
    String(fields.dailyBoundaryMinuteUTC),
  ]);
}

export interface EnrollmentFields {
  spaceId: string;
  invitationId: string;
  challengeId: string;
  challengeValue: string;
  challengeExpiresAt: number;
  clientRequestId: string;
  participantId: string;
  agreementPublicKey: string;
  signingPublicKey: string;
}

export function enrollmentTranscript(fields: EnrollmentFields): Uint8Array {
  return encodeCanonicalFields([
    "NW1.ENROLL",
    "1",
    fields.spaceId,
    fields.invitationId,
    fields.challengeId,
    fields.challengeValue,
    String(fields.challengeExpiresAt),
    fields.clientRequestId,
    fields.participantId,
    fields.agreementPublicKey,
    fields.signingPublicKey,
  ]);
}

export interface PairingFields {
  spaceId: string;
  invitationId: string;
  enrollmentId: string;
  dailyBoundaryMinuteUTC: number;
  inviterMemberId: string;
  inviterParticipantId: string;
  inviterAgreementPublicKey: string;
  inviterSigningPublicKey: string;
  inviteeMemberId: string;
  inviteeParticipantId: string;
  inviteeAgreementPublicKey: string;
  inviteeSigningPublicKey: string;
}

export function pairingTranscript(fields: PairingFields): Uint8Array {
  return encodeCanonicalFields([
    "NW1.PAIRING",
    "1",
    fields.spaceId,
    fields.invitationId,
    fields.enrollmentId,
    String(fields.dailyBoundaryMinuteUTC),
    fields.inviterMemberId,
    fields.inviterParticipantId,
    fields.inviterAgreementPublicKey,
    fields.inviterSigningPublicKey,
    fields.inviteeMemberId,
    fields.inviteeParticipantId,
    fields.inviteeAgreementPublicKey,
    fields.inviteeSigningPublicKey,
  ]);
}

export function approvalTranscript(
  transcriptHash: string,
  envelopeAlgorithm: string,
  keyEnvelope: string,
): Uint8Array {
  return encodeCanonicalFields([
    "NW1.APPROVE",
    "1",
    transcriptHash,
    envelopeAlgorithm,
    keyEnvelope,
  ]);
}

export interface SignedRequestFields {
  memberId: string;
  timestamp: number;
  nonce: string;
  method: string;
  pathname: string;
  bodySHA256: string;
}

export function signedRequestTranscript(fields: SignedRequestFields): Uint8Array {
  return encodeCanonicalFields([
    "NW1.REQUEST",
    "1",
    fields.memberId,
    String(fields.timestamp),
    fields.nonce,
    fields.method.toUpperCase(),
    fields.pathname,
    fields.bodySHA256,
  ]);
}

export interface SharedMediaAADFields {
  spaceId: string;
  sourceId: string;
  publisherMemberId: string;
  generationId: string;
  shareDayKey: number;
  mediaId: string;
  mediaBindingHash: string;
}

/**
 * AEAD associated data for one canonical encrypted preview. The binding hash is
 * intentionally never sent to or stored by the service; it is learned by the
 * receiver only after opening the encrypted manifest.
 */
export function sharedMediaAAD(fields: SharedMediaAADFields): Uint8Array {
  return encodeCanonicalFields([
    "NW1.SHARED-MEDIA",
    "1",
    fields.spaceId,
    fields.sourceId,
    fields.publisherMemberId,
    fields.generationId,
    String(fields.shareDayKey),
    fields.mediaId,
    fields.mediaBindingHash,
  ]);
}

export interface SharedManifestAADFields {
  spaceId: string;
  sourceId: string;
  publisherMemberId: string;
  generationId: string;
  shareDayKey: number;
  prepareAttemptId: string;
  prepareAttemptRevision: number;
  reservedRevision: number;
  rotationAnchorUTC: number;
  itemCount: number;
}

/**
 * AEAD associated data for the encrypted schedule/render manifest. Every field
 * needed to reconstruct this value is returned by the authenticated current API.
 */
export function sharedManifestAAD(fields: SharedManifestAADFields): Uint8Array {
  return encodeCanonicalFields([
    "NW1.SHARED-MANIFEST",
    "1",
    fields.spaceId,
    fields.sourceId,
    fields.publisherMemberId,
    fields.generationId,
    String(fields.shareDayKey),
    fields.prepareAttemptId,
    String(fields.prepareAttemptRevision),
    String(fields.reservedRevision),
    String(fields.rotationAnchorUTC),
    String(fields.itemCount),
  ]);
}

export function shareDayKey(now: number, dailyBoundaryMinuteUTC: number): number {
  return Math.floor((now - dailyBoundaryMinuteUTC * 60) / 86_400);
}

export function nextShareDayBoundary(
  dayKey: number,
  dailyBoundaryMinuteUTC: number,
): number {
  return (dayKey + 1) * 86_400 + dailyBoundaryMinuteUTC * 60;
}

/** Returns the first 20-minute boundary at least five minutes in the future. */
export function nextRotationAnchor(now: number): number {
  return Math.ceil((now + 300) / 1_200) * 1_200;
}

const verificationWords = [
  "あさ", "あめ", "いと", "うみ", "えき", "おと", "かぎ", "かぜ",
  "きり", "くも", "こえ", "さくら", "しずく", "すず", "そら", "たね",
  "つき", "てらす", "とり", "なみ", "にじ", "ねこ", "のはら", "はな",
  "ひかり", "ふね", "ほし", "まど", "みち", "もり", "ゆき", "よる",
] as const;

export function verificationPhrase(transcriptHash: Uint8Array): string {
  const indices: number[] = [];
  let accumulator = 0n;
  let bitCount = 0;
  for (const byte of transcriptHash) {
    accumulator = (accumulator << 8n) | BigInt(byte);
    bitCount += 8;
    while (bitCount >= 5 && indices.length < 12) {
      bitCount -= 5;
      indices.push(Number((accumulator >> BigInt(bitCount)) & 0x1fn));
    }
    if (indices.length === 12) break;
    accumulator = bitCount === 0 ? 0n : accumulator & ((1n << BigInt(bitCount)) - 1n);
  }
  return indices.map((index) => verificationWords[index]).join("・");
}
