import { type KeyCustody, ServiceError, sha256 } from './contracts';

// The wrapping authority MUST authenticate its caller and bind contextSHA256.
// It owns durable wrapping-key versions. No static/test-key or plaintext fallback.
export interface KeyWrappingAuthority {
  wrap(key: Uint8Array, contextSHA256: string): Promise<{ keyId: string; wrappedKey: Uint8Array }>;
  unwrap(keyId: string, wrappedKey: Uint8Array, contextSHA256: string): Promise<Uint8Array>;
}
const MAX_PLAINTEXT = 21 * 1024 * 1024;
const MAX_HEADER = 8192;
const MAGIC = new Uint8Array([78, 75, 77, 49]); // NKM1; not JWE or an AWS SDK envelope.
const utf8 = new TextEncoder();
const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
// Record IDs match the existing HTTP/native UUID contract, not only randomUUID v4.
const recordPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(?:photo|document)$/u;
const unavailable = () => new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)); // Small key/header values only.
const from64 = (value: unknown, maximum: number): Uint8Array => {
  if (typeof value !== 'string' || value.length > Math.ceil(maximum / 3) * 4) throw unavailable();
  const raw = atob(value);
  if (!raw.length || raw.length > maximum || btoa(raw) !== value) throw unavailable();
  return Uint8Array.from(raw, (char) => char.charCodeAt(0));
};
interface Header {
  version: 1; algorithm: 'A256GCM'; keyId: string;
  contextSHA256: string; wrappedKey: string; iv: string;
}
const validKeyID = (value: unknown): value is string => typeof value === 'string'
  && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/u.test(value);
async function contextHash(context: Parameters<KeyCustody['seal']>[1]): Promise<string> {
  if (!context || typeof context !== 'object' || Array.isArray(context)
      || Object.keys(context).some(key => !['ownerId', 'purpose', 'recordId'].includes(key))
      || !ownerPattern.test(context.ownerId)
      || !['identity', 'record', 'contact'].includes(context.purpose)
      || (context.purpose === 'record'
        ? typeof context.recordId !== 'string' || !recordPattern.test(context.recordId)
        : context.recordId !== undefined)) throw unavailable();
  return sha256(JSON.stringify(['neko-preservation-context-v1', context.ownerId, context.purpose, context.recordId ?? null]));
}
async function dataKey(raw: Uint8Array, usage: 'encrypt' | 'decrypt'): Promise<CryptoKey> {
  if (!(raw instanceof Uint8Array) || raw.length !== 32) throw unavailable();
  return crypto.subtle.importKey('raw', raw as BufferSource, { name: 'AES-GCM' }, false, [usage]);
}

export function envelopeKeyCustody(options: { enabled?: boolean; wrapper: KeyWrappingAuthority }): KeyCustody {
  const enabled = () => {
    if (options.enabled !== true || typeof options.wrapper?.wrap !== 'function'
        || typeof options.wrapper?.unwrap !== 'function') throw unavailable();
  };
  return {
    async seal(plaintext, context) {
      let raw: Uint8Array | undefined;
      try {
        enabled();
        if (!(plaintext instanceof Uint8Array) || !plaintext.length || plaintext.length > MAX_PLAINTEXT) throw unavailable();
        const contextSHA256 = await contextHash(context);
        raw = crypto.getRandomValues(new Uint8Array(32));
        const key = await dataKey(raw, 'encrypt');
        const wrapped = await options.wrapper.wrap(raw, contextSHA256);
        if (!wrapped || !validKeyID(wrapped.keyId) || !(wrapped.wrappedKey instanceof Uint8Array)
            || !wrapped.wrappedKey.length || wrapped.wrappedKey.length > 4096) throw unavailable();
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const header: Header = { version: 1, algorithm: 'A256GCM', keyId: wrapped.keyId,
          contextSHA256, wrappedKey: b64(wrapped.wrappedKey), iv: b64(iv) };
        const encoded = utf8.encode(JSON.stringify(header));
        if (encoded.length > MAX_HEADER) throw unavailable();
        const prefix = new Uint8Array(8 + encoded.length);
        prefix.set(MAGIC); new DataView(prefix.buffer).setUint32(4, encoded.length); prefix.set(encoded, 8);
        const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
          additionalData: prefix, tagLength: 128 }, key, plaintext as BufferSource));
        const result = new Uint8Array(prefix.length + ciphertext.length);
        result.set(prefix); result.set(ciphertext, prefix.length);
        return result;
      } catch { throw unavailable(); }
      finally { raw?.fill(0); }
    },
    async open(envelope, context) {
      let raw: Uint8Array | undefined;
      try {
        enabled();
        if (!(envelope instanceof Uint8Array) || envelope.length < 25
            || envelope.length > MAX_PLAINTEXT + MAX_HEADER + 24
            || !MAGIC.every((value, index) => envelope[index] === value)) throw unavailable();
        const length = new DataView(envelope.buffer, envelope.byteOffset, envelope.byteLength).getUint32(4);
        if (length < 1 || length > MAX_HEADER || envelope.length <= 8 + length + 16
            || envelope.length - 8 - length - 16 > MAX_PLAINTEXT) throw unavailable();
        const encoded = new TextDecoder('utf-8', { fatal: true }).decode(envelope.subarray(8, 8 + length));
        const header = JSON.parse(encoded) as Header;
        if (!header || header.version !== 1 || header.algorithm !== 'A256GCM' || !validKeyID(header.keyId)
            || Object.keys(header).sort().join(',') !== 'algorithm,contextSHA256,iv,keyId,version,wrappedKey'
            || JSON.stringify(header) !== encoded || header.contextSHA256 !== await contextHash(context)) throw unavailable();
        const wrapped = from64(header.wrappedKey, 4096); const iv = from64(header.iv, 12);
        if (iv.length !== 12) throw unavailable();
        raw = await options.wrapper.unwrap(header.keyId, wrapped, header.contextSHA256);
        const key = await dataKey(raw, 'decrypt');
        return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv as BufferSource,
          additionalData: envelope.subarray(0, 8 + length) as BufferSource, tagLength: 128 }, key,
        envelope.subarray(8 + length) as BufferSource));
      } catch { throw unavailable(); }
      finally { if (raw instanceof Uint8Array) raw.fill(0); }
    },
  };
}
