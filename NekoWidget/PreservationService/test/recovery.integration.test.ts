import { env } from 'cloudflare:workers';
import { beforeAll, expect, it } from 'vitest';
import { exportJWK, generateKeyPair, SignJWT, type JSONWebKeySet } from 'jose';
import { APPLE_ISSUER, APPLE_KEYS_URL, APPLE_TOKEN_URL, AppleIdentityVerifier } from '../src/apple';
import { DurableAuth } from '../src/auth';
import { ArchiveStore } from '../src/storage';
import { envelopeKeyCustody } from '../src/key-custody';
import { randomToken, type MembershipAuthority } from '../src/contracts';
import { route, type Services } from '../src/index';
import { syntheticKeyAuthority } from './key-fixture';

// Real local D1/R2 + JWT cryptography + HTTP routing + envelope + private key bridge.
// Apple HTTP, master-key custody and membership are synthetic. JPEG decoder has its
// own checked suite; here its boolean is injected, not a live Node service claim.
const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const photo = '/9j/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAIDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AAA//2Q==';
const document = { formatVersion: 1, text: '初めて膝で寝た日', capturedAt: '2023-03-02T05:00:00.000Z',
  writtenAt: null, updatedAt: null, catNames: ['むぎ'], photoFile: 'photo.jpg' };
let signingKey: CryptoKey; let jwks: JSONWebKeySet;
beforeAll(async () => {
  const pair = await generateKeyPair('RS256'); signingKey = pair.privateKey;
  jwks = { keys: [{ ...await exportJWK(pair.publicKey), kid: 'recovery-synthetic', alg: 'RS256', use: 'sig' }] };
});
async function fixture() {
  const authority = await syntheticKeyAuthority(); const indexSecret = randomToken();
  const subject = `synthetic-person-${randomToken()}`; const clientId = 'invalid.synthetic.neko';
  let now = Date.UTC(2026, 8, 22); let membership: Awaited<ReturnType<MembershipAuthority['status']>> = 'active';
  const create = () => {
    const keys = envelopeKeyCustody({ enabled: true, wrapper: authority.bridge() });
    const auth = new DurableAuth({ db: binding.DB, keys, identityIndexSecret: indexSecret, now: () => now });
    // All transport is injected. Any unrecognised URL fails instead of using network.
    const exchange = new Map<string, string>();
    const verifier = new AppleIdentityVerifier({ enabled: true, clientId, now: () => now,
      takeChallenge: input => auth.takeChallenge(input), getClientSecret: async () => 'synthetic-server-secret',
      fetchImpl: async (url, init) => {
        if (url === APPLE_KEYS_URL) return Response.json(jwks);
        if (url !== APPLE_TOKEN_URL) throw new Error('Unexpected network request');
        const form = new URLSearchParams(String(init.body)); const code = form.get('code') ?? '';
        const token = exchange.get(code); exchange.delete(code);
        if (!token) return Response.json({ error: 'invalid_grant' }, { status: 400 });
        return Response.json({ token_type: 'Bearer', expires_in: 3600, access_token: 'synthetic-access',
          refresh_token: 'synthetic-refresh', id_token: token });
      } });
    const services = { auth, verifier, archive: new ArchiveStore({ db: binding.DB, bucket: binding.ARCHIVE,
      keys, auth, now: () => now, quotaBytes: 10_000_000, maximumRecords: 100,
      membership: { status: async () => membership }, photos: { validateJPEG: async () => true } }) };
    const signIn = async (person = subject) => {
      const challengeResponse = await route(new Request('https://local.invalid/v1/auth/challenges', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }), services);
      const challenge = await challengeResponse.json() as { challengeId: string; challengeProof: string; nonce: string };
      const code = randomToken(); const idToken = await new SignJWT({ nonce: challenge.nonce })
        .setProtectedHeader({ alg: 'RS256', kid: 'recovery-synthetic' }).setIssuer(APPLE_ISSUER).setAudience(clientId)
        .setSubject(person).setIssuedAt(now / 1000).setExpirationTime(now / 1000 + 3600).sign(signingKey);
      exchange.set(code, idToken);
      const result = await route(new Request('https://local.invalid/v1/auth/sessions', { method: 'POST',
        headers: { 'content-type': 'application/json' }, body: JSON.stringify({ challengeId: challenge.challengeId,
          challengeProof: challenge.challengeProof, identityToken: idToken, authorizationCode: code }) }), services);
      return await result.json() as { token: string; ownerId: string; expiresAt: string };
    };
    return Object.assign(services, { signIn });
  };
  return { authority, create, advance: () => { now += 24 * 60 * 60_000; },
    expireMembership: () => { membership = 'expired'; } };
}
const put = (services: Services, token: string, id: string) => route(new Request(`https://local.invalid/v1/records/${id}`, {
  method: 'PUT', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
  body: JSON.stringify({ expectedRevision: null, consentVersion: 'managed-preservation-v1', document, photoBase64: photo }),
}), services);
const get = (services: Services, token: string, id: string) => route(new Request(`https://local.invalid/v1/records/${id}`, {
  headers: { authorization: `Bearer ${token}` },
}), services);

it('fresh Apple login on a new service instance restores the same owner/photo/note after session and membership expiry', async () => {
  const f = await fixture(); const oldDevice = f.create(); const original = await oldDevice.signIn(); const id = crypto.randomUUID();
  expect((await put(oldDevice, original.token, id)).status).toBe(200);
  const record = await binding.DB.prepare('SELECT metadata,photo_key FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(original.ownerId, id).first<{ metadata: number[]; photo_key: string }>();
  expect(new TextDecoder().decode(new Uint8Array(record!.metadata))).not.toContain(document.text);
  const stored = await binding.ARCHIVE.get(record!.photo_key); const encrypted = new Uint8Array(await stored!.arrayBuffer());
  expect(encrypted.subarray(0, 4)).toEqual(new Uint8Array([78, 75, 77, 49]));
  f.advance(); f.expireMembership(); await f.authority.rotate('synthetic/v2');
  const newDevice = f.create(); const restored = await newDevice.signIn();
  expect(restored.ownerId).toBe(original.ownerId); expect(restored.token).not.toBe(original.token);
  await expect(get(newDevice, original.token, id)).rejects.toMatchObject({ code: 'unauthorized' });
  const result = await (await get(newDevice, restored.token, id)).json() as { document: unknown; photoBase64: string };
  expect(result.document).toEqual(document); expect(result.photoBase64).toBe(photo);
  await expect(put(newDevice, restored.token, crypto.randomUUID())).rejects.toMatchObject({ code: 'NEW_SAVE_REQUIRES_MEMBERSHIP' });
  const other = await newDevice.signIn('synthetic-other-person'); expect(other.ownerId).not.toBe(original.ownerId);
  await expect(get(newDevice, other.token, id)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
});
it('missing old wrapping key is an explicit read failure, not an empty successful archive or new owner', async () => {
  const f = await fixture(); const before = f.create(); const original = await before.signIn(); const id = crypto.randomUUID();
  await put(before, original.token, id); await f.authority.rotate('synthetic/v2'); f.authority.remove('synthetic/v1');
  const after = f.create(); const restored = await after.signIn(); expect(restored.ownerId).toBe(original.ownerId);
  await expect(get(after, restored.token, id)).rejects.toMatchObject({ code: 'ARCHIVE_INTEGRITY_FAILED' });
  await expect(after.archive.list(restored.token)).rejects.toMatchObject({ code: 'ARCHIVE_INTEGRITY_FAILED' });
  const row = await binding.DB.prepare('SELECT deleted FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(original.ownerId, id).first<{ deleted: number }>(); expect(row?.deleted).toBe(0);
});
it('owner revocation wins over a valid new Apple login and preserves stored records for trusted recovery policy', async () => {
  const f = await fixture(); const before = f.create(); const original = await before.signIn(); const id = crypto.randomUUID();
  await put(before, original.token, id); await before.auth.revokeOwner(original.ownerId);
  const after = f.create(); await expect(after.signIn()).rejects.toMatchObject({ code: 'unauthorized' });
  await expect(get(after, original.token, id)).rejects.toMatchObject({ code: 'unauthorized' });
  expect(await binding.DB.prepare('SELECT record_id FROM pa_records WHERE owner_id=?').bind(original.ownerId).first()).not.toBeNull();
});
