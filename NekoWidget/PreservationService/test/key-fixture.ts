import { type KeyWrappingAuthority } from '../src/key-custody';
import { boundKeyWrapper } from '../src/providers';
import { encodePhoto } from '../src/documents';

// Test-only synthetic authority. Never wired from Env or production source.
export async function syntheticKeyAuthority() {
  const versions = new Map<string, CryptoKey>(); let active = 'synthetic/v1';
  const rotate = async (id: string) => {
    versions.set(id, await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']));
    active = id;
  };
  await rotate(active);
  const rawKeys: Uint8Array[] = [];
  const make = (): KeyWrappingAuthority => ({
    async wrap(raw, context) {
      rawKeys.push(raw);
      const id = active; const iv = crypto.getRandomValues(new Uint8Array(12));
      const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
        additionalData: new TextEncoder().encode(context) }, versions.get(id)!, raw as BufferSource));
      const wrappedKey = new Uint8Array(12 + ciphertext.length); wrappedKey.set(iv); wrappedKey.set(ciphertext, 12);
      return { keyId: id, wrappedKey };
    },
    async unwrap(id, wrapped, context) {
      const key = versions.get(id); if (!key) throw new Error('synthetic master unavailable');
      const raw = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: wrapped.slice(0, 12),
        additionalData: new TextEncoder().encode(context) }, key, wrapped.slice(12)));
      rawKeys.push(raw); return raw;
    },
  });
  const bridge = (): KeyWrappingAuthority => {
    const authority = make();
    const binding = { async fetch(url: string | Request | URL, init?: RequestInit) {
      const input = JSON.parse(String(init?.body));
      if (String(url) === 'https://preservation-internal/keys/wrap') {
        const value = await authority.wrap(Uint8Array.from(atob(input.key), char => char.charCodeAt(0)), input.contextSHA256);
        return Response.json({ version: 1, keyId: value.keyId, wrappedKey: encodePhoto(value.wrappedKey) });
      }
      if (String(url) === 'https://preservation-internal/keys/unwrap') {
        const key = await authority.unwrap(input.keyId,
          Uint8Array.from(atob(input.wrappedKey), char => char.charCodeAt(0)), input.contextSHA256);
        return Response.json({ version: 1, key: encodePhoto(key) });
      }
      throw new Error('Unexpected endpoint');
    } } as unknown as Fetcher;
    return boundKeyWrapper(binding);
  };
  return { make, bridge, rotate, rawKeys, remove: (id: string) => versions.delete(id) };
}
