// Offline key-custody experiment. Standard JWE, NOT a KMS/HSM implementation.
// The wrapping key is supplied by the synthetic test harness, never stored here.
import { CompactEncrypt, compactDecrypt, decodeProtectedHeader } from 'jose';

export class KeyBundleError extends Error {
  constructor(code) { super(code); this.code = code; this.name = 'KeyBundleError'; }
}
const fail = (code) => { throw new KeyBundleError(code); };
const validID = (value) => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(value);
const requireKey = (key) => {
  if (!(key instanceof Uint8Array) || key.byteLength !== 32) fail('WRAPPING_KEY_UNAVAILABLE');
};
const requireScope = (scope) => {
  if (typeof scope !== 'string' || !/^[a-zA-Z0-9_-]{1,120}$/.test(scope)) fail('INVALID_KEY_SCOPE');
};

export async function sealKeyBundle({ keys, activeKeyId, wrappingKey, wrappingKeyId, scope }) {
  requireKey(wrappingKey);
  requireScope(scope);
  if (!validID(wrappingKeyId) || !(keys instanceof Map) || keys.size < 1 || keys.size > 32
      || !validID(activeKeyId) || !keys.has(activeKeyId)) fail('INVALID_KEY_BUNDLE');
  const entries = [...keys].map(([id, bytes]) => {
    if (!validID(id) || !(bytes instanceof Uint8Array) || bytes.byteLength !== 32) fail('INVALID_KEY_BUNDLE');
    return { id, key: Buffer.from(bytes).toString('base64url') };
  });
  return new CompactEncrypt(Buffer.from(JSON.stringify({ version: 1, scope, activeKeyId, entries })))
    .setProtectedHeader({ alg: 'dir', enc: 'A256GCM', kid: wrappingKeyId, typ: 'neko-offline-key-bundle+jwe' })
    .encrypt(wrappingKey);
}

export async function openKeyBundle({ jwe, wrappingKey, wrappingKeyId, expectedScope }) {
  requireKey(wrappingKey);
  requireScope(expectedScope);
  if (!validID(wrappingKeyId) || typeof jwe !== 'string' || jwe.length > 16_384) fail('INVALID_KEY_BUNDLE');
  try {
    const header = decodeProtectedHeader(jwe);
    if (header.alg !== 'dir' || header.enc !== 'A256GCM' || header.kid !== wrappingKeyId
        || header.typ !== 'neko-offline-key-bundle+jwe') throw new Error();
    const { plaintext } = await compactDecrypt(jwe, wrappingKey, {
      keyManagementAlgorithms: ['dir'], contentEncryptionAlgorithms: ['A256GCM'],
    });
    const bundle = JSON.parse(Buffer.from(plaintext).toString('utf8'));
    if (bundle.version !== 1 || bundle.scope !== expectedScope || !validID(bundle.activeKeyId)
        || !Array.isArray(bundle.entries) || bundle.entries.length < 1 || bundle.entries.length > 32) throw new Error();
    const keys = new Map();
    for (const entry of bundle.entries) {
      if (!validID(entry.id) || keys.has(entry.id) || typeof entry.key !== 'string') throw new Error();
      const bytes = Buffer.from(entry.key, 'base64url');
      if (bytes.length !== 32 || bytes.toString('base64url') !== entry.key) throw new Error();
      keys.set(entry.id, bytes);
    }
    if (!keys.has(bundle.activeKeyId)) throw new Error();
    return { keys, activeKeyId: bundle.activeKeyId };
  } catch { fail('KEY_BUNDLE_UNREADABLE'); }
}
