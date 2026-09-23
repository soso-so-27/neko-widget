import { expect, it } from 'vitest';
import { envelopeKeyCustody, type KeyWrappingAuthority } from '../src/key-custody';
import { boundKeyWrapper } from '../src/providers';
import { sha256 } from '../src/contracts';
import { syntheticKeyAuthority } from './key-fixture';

const context = () => ({ ownerId: crypto.randomUUID(), purpose: 'record' as const, recordId: `${crypto.randomUUID()}/photo` });
const text = new TextEncoder().encode('写真と、その日の大切な記録');
const error = { code: 'KEY_CUSTODY_UNAVAILABLE', status: 503, message: 'KEY_CUSTODY_UNAVAILABLE' };
it('envelope survives new instances and key rotation while preserving input and erasing borrowed data keys', async () => {
  const authority = await syntheticKeyAuthority(); const scope = context();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() });
  const sealed = await keys.seal(text, scope); const again = await keys.seal(text, scope);
  expect(sealed).not.toEqual(again); expect(new TextDecoder().decode(sealed)).not.toContain('写真');
  await authority.rotate('synthetic/v2');
  const restored = envelopeKeyCustody({ enabled: true, wrapper: authority.make() });
  expect(await restored.open(sealed, scope)).toEqual(text);
  const newer = await restored.seal(text, scope); expect(await restored.open(newer, scope)).toEqual(text);
  authority.remove('synthetic/v1');
  await expect(restored.open(sealed, scope)).rejects.toMatchObject(error);
  expect(await restored.open(newer, scope)).toEqual(text);
  expect(new TextDecoder().decode(text)).toBe('写真と、その日の大切な記録');
  expect(authority.rawKeys.every(key => key.every(byte => byte === 0))).toBe(true);
});
it('another owner, another record and another purpose cannot open a valid envelope', async () => {
  const authority = await syntheticKeyAuthority(); const scope = context();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() }); const sealed = await keys.seal(text, scope);
  for (const other of [{ ...scope, ownerId: crypto.randomUUID() }, { ...scope, recordId: `${crypto.randomUUID()}/photo` },
    { ...scope, recordId: scope.recordId.replace('/photo', '/document') }, { ownerId: scope.ownerId, purpose: 'identity' as const }]) {
    await expect(keys.open(sealed, other)).rejects.toMatchObject(error);
  }
});
it('isolates a verified notice contact from identity and record ciphertext', async () => {
  const authority = await syntheticKeyAuthority(); const ownerId = crypto.randomUUID();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() });
  const contact = { ownerId, purpose: 'contact' as const };
  const sealed = await keys.seal(new TextEncoder().encode('person@privaterelay.appleid.com'), contact);
  expect(new TextDecoder().decode(sealed)).not.toContain('person@');
  expect(new TextDecoder().decode(await keys.open(sealed, contact))).toBe('person@privaterelay.appleid.com');
  for (const wrong of [{ ownerId: crypto.randomUUID(), purpose: 'contact' as const },
    { ownerId, purpose: 'identity' as const },
    { ownerId, purpose: 'record' as const, recordId: `${crypto.randomUUID()}/document` }]) {
    await expect(keys.open(sealed, wrong)).rejects.toMatchObject(error);
  }
  await expect(keys.open(sealed, { ...contact, recordId: `${crypto.randomUUID()}/document` }))
    .rejects.toMatchObject(error);
});
it('tampered header, key version, ciphertext, unsupported format and noncanonical envelope fail closed', async () => {
  const authority = await syntheticKeyAuthority(); const scope = context();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() }); const sealed = await keys.seal(text, scope);
  for (const index of [0, 7, 10, sealed.length - 1]) {
    const altered = sealed.slice(); altered[index] = altered[index]! ^ 1;
    await expect(keys.open(altered, scope)).rejects.toMatchObject(error);
  }
  for (const size of [0, 7, 20, sealed.length - 1]) await expect(keys.open(sealed.slice(0, size), scope)).rejects.toMatchObject(error);
  const extra = new Uint8Array(sealed.length + 1); extra.set(sealed);
  await expect(keys.open(extra, scope)).rejects.toMatchObject(error);
});
it('defaults OFF, validates contexts and never silently substitutes a missing or malformed wrapping key', async () => {
  let calls = 0;
  const wrapper: KeyWrappingAuthority = { wrap: async () => { ++calls; throw new Error('secret'); },
    unwrap: async () => { ++calls; throw new Error('secret'); } };
  const disabled = envelopeKeyCustody({ wrapper });
  await expect(disabled.seal(text, context())).rejects.toMatchObject(error); expect(calls).toBe(0);
  const enabled = envelopeKeyCustody({ enabled: true, wrapper });
  await expect(enabled.seal(text, { ...context(), ownerId: '../another-owner' })).rejects.toMatchObject(error); expect(calls).toBe(0);
  await expect(enabled.seal(text, context())).rejects.toMatchObject(error); expect(calls).toBe(1);
  let borrowed: Uint8Array | undefined;
  const wrong = envelopeKeyCustody({ enabled: true, wrapper: { ...wrapper, wrap: async raw => {
    borrowed = raw; return { keyId: '', wrappedKey: new Uint8Array([1]) };
  } } });
  await expect(wrong.seal(text, context())).rejects.toMatchObject(error); expect(borrowed?.every(byte => byte === 0)).toBe(true);
});
it('preserves a full allowed-size photo and rejects empty/over-limit input before wrapping', async () => {
  const authority = await syntheticKeyAuthority(); const scope = context();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() });
  const photo = new Uint8Array(20 * 1024 * 1024).fill(123);
  const encrypted = await keys.seal(photo, scope); const opened = await keys.open(encrypted, scope);
  expect(opened.length).toBe(photo.length); expect(await sha256(opened)).toBe(await sha256(photo));
  await expect(keys.seal(new Uint8Array(), scope)).rejects.toMatchObject(error);
  await expect(keys.seal(new Uint8Array(21 * 1024 * 1024 + 1), scope)).rejects.toMatchObject(error);
});
it('keeps the public UUID contract for records including non-v4 identifiers', async () => {
  const authority = await syntheticKeyAuthority(); const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.make() });
  const scope = { ...context(), recordId: '01890f3e-7b3b-7000-8000-000000000001/document' };
  const encrypted = await keys.seal(text, scope); expect(await keys.open(encrypted, scope)).toEqual(text);
});
it('private bridge transports only a data key, round-trips context, and fails on incompatible provider responses', async () => {
  const authority = await syntheticKeyAuthority(); const scope = context();
  const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
  const encrypted = await keys.seal(text, scope); expect(await keys.open(encrypted, scope)).toEqual(text);
  const malformed = boundKeyWrapper({ fetch: async () => Response.json({ version: 1, key: 'AA==' }) } as unknown as Fetcher,
    'x'.repeat(43));
  await expect(malformed.unwrap('synthetic/v1', new Uint8Array([1]), 'a'.repeat(64))).rejects.toMatchObject(error);
  await expect(malformed.wrap(new Uint8Array(32), 'a'.repeat(64))).rejects.toMatchObject(error);
});
