import { ServiceError } from './contracts';

export const LINK_SIGNING_PATH = '/v1/preservation/membership-link';
export const LINK_TTL_MS = 5 * 60_000;
export const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
export interface LinkChallenge {
  version: 1; purpose: 'preservation-membership-link'; audience: string;
  challengeId: string; ownerId: string; billingAccountId: string; issuedAt: number; expiresAt: number;
}
export interface BillingProof { billingKeyId: string; timestamp: string; nonce: string; signature: string; }
export type MembershipStatus = 'active' | 'grace' | 'expired' | 'unknown';
export interface BillingLinkAuthority {
  verify(challenge: LinkChallenge, proof: BillingProof): Promise<void>;
  status(billingAccountId: string): Promise<MembershipStatus>;
}
export function validAudience(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u.test(value);
}
export function validateProof(value: unknown): BillingProof {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ServiceError('INVALID_BILLING_PROOF');
  const item = value as Record<string, unknown>;
  if (Object.keys(item).sort().join(',') !== 'billingKeyId,nonce,signature,timestamp'
      || typeof item.billingKeyId !== 'string' || !/^[A-Za-z0-9_-]{22}$/u.test(item.billingKeyId)
      || typeof item.nonce !== 'string' || !/^[A-Za-z0-9_-]{22}$/u.test(item.nonce)
      || typeof item.signature !== 'string' || !/^[A-Za-z0-9_-]{86}$/u.test(item.signature)
      || typeof item.timestamp !== 'string' || !/^[1-9][0-9]{8,12}$/u.test(item.timestamp)) {
    throw new ServiceError('INVALID_BILLING_PROOF');
  }
  return item as unknown as BillingProof;
}
export function validateChallenge(value: unknown, audience: string, now: number): LinkChallenge {
  const bad = () => new ServiceError('INVALID_LINK_CHALLENGE', 401);
  if (!validAudience(audience) || !Number.isSafeInteger(now) || now < 0) throw bad();
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw bad();
  const c = value as LinkChallenge;
  if (Object.keys(c).sort().join(',') !== 'audience,billingAccountId,challengeId,expiresAt,issuedAt,ownerId,purpose,version'
      || c.version !== 1 || c.purpose !== 'preservation-membership-link' || c.audience !== audience
      || typeof c.challengeId !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(c.challengeId)
      || typeof c.ownerId !== 'string' || !uuidV4.test(c.ownerId)
      || typeof c.billingAccountId !== 'string' || !uuidV4.test(c.billingAccountId)
      || !Number.isSafeInteger(c.issuedAt) || !Number.isSafeInteger(c.expiresAt)
      || c.issuedAt < 0 || c.issuedAt > now || c.expiresAt <= now || c.expiresAt - c.issuedAt !== LINK_TTL_MS) throw bad();
  return c;
}
// The native billing key signs these exact UTF-8 bytes with the existing NWB1
// request transcript. Never sign a client-selected URL or reserialize its JSON.
export function linkTranscript(c: LinkChallenge): string {
  return JSON.stringify({ version: c.version, purpose: c.purpose, audience: c.audience,
    challengeId: c.challengeId, ownerId: c.ownerId, billingAccountId: c.billingAccountId,
    issuedAt: c.issuedAt, expiresAt: c.expiresAt });
}
