import { ServiceError } from './contracts';

const encoder = new TextEncoder();

export function identityIndexKey(value: string): Promise<CryptoKey> {
  try {
    if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43,4096}$/u.test(value)) throw new Error();
    const decoded = atob(value.replaceAll('-', '+').replaceAll('_', '/'));
    const canonical = btoa(decoded).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
    if (decoded.length < 32 || canonical !== value) throw new Error();
    const raw = Uint8Array.from(decoded, character => character.charCodeAt(0));
    const key = crypto.subtle.importKey('raw', raw as BufferSource,
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    raw.fill(0);
    return key;
  } catch { throw new ServiceError('auth_configuration_invalid', 503); }
}

async function hmac(key: CryptoKey, message: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(message)));
  return [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

export const indexedOwnerIdentity = (key: CryptoKey, issuer: string, subject: string): Promise<string> =>
  hmac(key, `neko-preservation-identity-v1\0${JSON.stringify([issuer, subject])}`);

export const indexedNoticeEmail = (key: CryptoKey, ownerId: string, email: string): Promise<string> =>
  hmac(key, `neko-preservation-contact-email-v1\0${JSON.stringify([ownerId, email])}`);
