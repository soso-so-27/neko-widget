export interface ArchiveDocument {
  formatVersion: 1;
  text: string;
  capturedAt: string | null;
  writtenAt: string | null;
  updatedAt: string | null;
  catNames: string[];
  photoFile: 'photo.jpg' | null;
}
export interface VerifiedIdentity { issuer: string; subject: string; refreshToken: string; verifiedEmail?: string; }
export const contactEmailValid = (email: unknown): email is string => typeof email === 'string'
  && email.length >= 3 && email.length <= 254
  && /^[^\s\x00-\x1f\x7f@]+@[^\s\x00-\x1f\x7f@]+\.[^\s\x00-\x1f\x7f@]+$/u.test(email);
export interface Challenge { nonce: string; createdAt: number; expiresAt: number; }
export interface IdentityVerifier {
  verifyNativeAuthorization(input: { challengeId: string; challengeProof: string; identityToken: string; authorizationCode: string }): Promise<VerifiedIdentity>;
}
export interface KeyCustody {
  seal(plaintext: Uint8Array, context: { ownerId: string; purpose: 'identity' | 'record' | 'contact' | 'recovery'; recordId?: string }): Promise<Uint8Array>;
  open(ciphertext: Uint8Array, context: { ownerId: string; purpose: 'identity' | 'record' | 'contact' | 'recovery'; recordId?: string }): Promise<Uint8Array>;
}
export interface MembershipAuthority { status(ownerId: string): Promise<'active' | 'grace' | 'expired' | 'unknown'>; }
export interface PhotoValidator { validateJPEG(bytes: Uint8Array): Promise<boolean>; }
export interface Session { ownerId: string; sessionHash: string; expiresAt: number; }
export interface AuthDependencies {
  db: D1Database;
  keys: KeyCustody;
  identityIndexSecret: string;
  now: () => number;
}
export class ServiceError extends Error {
  constructor(public code: string, public status = 400) { super(code); this.name = 'ServiceError'; }
}
export const sha256 = async (value: Uint8Array | string): Promise<string> => {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  const digest = await crypto.subtle.digest('SHA-256', bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
};
export const randomToken = (): string => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
};
