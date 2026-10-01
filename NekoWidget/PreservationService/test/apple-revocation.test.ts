import { expect, it, vi } from 'vitest';
import { AppleTokenRevoker } from '../src/apple-revocation';

const clientId = 'invalid.synthetic.neko';
const secret = 'synthetic-client-secret';
const token = 'synthetic-refresh-token';
const failure = { code: 'APPLE_REVOCATION_UNAVAILABLE', status: 503 };

it('defaults OFF and rejects invalid input before contacting Apple or opening the signing key', async () => {
  const key = vi.fn(async () => secret), send = vi.fn();
  await expect(new AppleTokenRevoker({ clientId, getClientSecret: key, fetchImpl: send })
    .revokeRefreshToken(token)).rejects.toMatchObject({ code: 'APPLE_REVOCATION_DISABLED' });
  for (const input of ['', 'x'.repeat(16385), 'a\nb']) {
    await expect(new AppleTokenRevoker({ enabled: true, clientId, getClientSecret: key, fetchImpl: send })
      .revokeRefreshToken(input)).rejects.toMatchObject(failure);
  }
  expect(key).not.toHaveBeenCalled(); expect(send).not.toHaveBeenCalled();
});

it('uses only Apples fixed revocation endpoint and permits an idempotent explicit retry', async () => {
  const calls: string[] = [];
  const revoker = new AppleTokenRevoker({ enabled: true, clientId, getClientSecret: async () => secret,
    fetchImpl: async (url, init) => {
      calls.push(String(url)); expect(String(url)).toBe('https://appleid.apple.com/auth/revoke');
      expect(init?.method).toBe('POST'); expect(init?.redirect).toBe('manual');
      expect(init?.cache).toBe('no-store'); expect(init?.signal).toBeDefined();
      expect(Object.fromEntries(new URLSearchParams(String(init?.body))))
        .toEqual({ client_id: clientId, client_secret: secret, token, token_type_hint: 'refresh_token' });
      return new Response(null, { status: 200 });
    } });
  await revoker.revokeRefreshToken(token); await revoker.revokeRefreshToken(token);
  expect(calls).toHaveLength(2);
});

it('does not treat redirects, provider errors, nonempty success, or transport failure as revocation', async () => {
  for (const response of [new Response(null, { status: 302, headers: { location: 'https://invalid.example' } }),
    Response.json({ error: 'invalid_client' }, { status: 400 }), new Response(null, { status: 503 }),
    Response.json({ error: 'synthetic-error' }), new Response('x'.repeat(65537))]) {
    const send = vi.fn(async () => response);
    await expect(new AppleTokenRevoker({ enabled: true, clientId, getClientSecret: async () => secret, fetchImpl: send })
      .revokeRefreshToken(token)).rejects.toMatchObject(failure);
    expect(send).toHaveBeenCalledTimes(1); // No automatic retries.
  }
  const send = vi.fn(async () => { throw new Error('contains synthetic credentials'); });
  await expect(new AppleTokenRevoker({ enabled: true, clientId, getClientSecret: async () => secret, fetchImpl: send })
    .revokeRefreshToken(token)).rejects.toMatchObject(failure);
  const error = new AppleTokenRevoker({ enabled: true, clientId, getClientSecret: async () => { throw new Error(secret); }, fetchImpl: send });
  await expect(error.revokeRefreshToken(token)).rejects.toMatchObject({ message: 'APPLE_REVOCATION_UNAVAILABLE' });
});

it('returns a provider failure without waiting for unresponsive stream cleanup', async () => {
  const cancel = vi.fn(() => new Promise<void>(() => {}));
  const body = new ReadableStream<Uint8Array>({ cancel });
  const revoker = new AppleTokenRevoker({ enabled: true, clientId, getClientSecret: async () => secret,
    fetchImpl: async () => new Response(body, { status: 503 }) });
  await expect(revoker.revokeRefreshToken(token)).rejects.toMatchObject(failure);
  expect(cancel).toHaveBeenCalledTimes(1);
}, 1000);
