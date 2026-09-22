import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { type AuthDependencies, type KeyCustody, type VerifiedIdentity, sha256 } from '../src/contracts';

const db = (env as unknown as { DB: D1Database }).DB;
const START = Date.UTC(2026, 8, 22);
const secret = btoa(String.fromCharCode(...new Uint8Array(32).fill(7))).replace(/=+$/, '');
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function fixture() {
  let now = START;
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const keys: KeyCustody = {
    async seal(bytes, context) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const body = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
        additionalData: encoder.encode(JSON.stringify(context)) }, key, bytes as BufferSource));
      const result = new Uint8Array(iv.length + body.length);
      result.set(iv); result.set(body, iv.length); return result;
    },
    async open(bytes, context) {
      return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
        additionalData: encoder.encode(JSON.stringify(context)) }, key, bytes.slice(12)));
    },
  };
  const dependencies: AuthDependencies = { db, keys, identityIndexSecret: secret, now: () => now };
  return { auth: new DurableAuth(dependencies), dependencies, keys,
    advance: (ms: number) => { now += ms; },
    identity: { issuer: 'https://appleid.apple.com', subject: `synthetic-${crypto.randomUUID()}`,
      refreshToken: `synthetic-refresh-${crypto.randomUUID()}` } satisfies VerifiedIdentity };
}

describe('durable private preservation authentication', () => {
  it('takes a proof-bound challenge exactly once across verifier restarts and races', async () => {
    const f = await fixture();
    const challenge = await f.auth.issueChallenge();
    const stored = await db.prepare('SELECT * FROM pa_auth_challenges WHERE challenge_id = ?').bind(challenge.challengeId).first();
    expect(JSON.stringify(stored)).not.toContain(challenge.challengeProof);
    expect(stored?.proof_hash).toBe(await sha256(challenge.challengeProof));
    const restarted = new DurableAuth(f.dependencies);
    const outcomes = await Promise.allSettled([f.auth.takeChallenge(challenge), restarted.takeChallenge(challenge)]);
    expect(outcomes.filter((item) => item.status === 'fulfilled')).toHaveLength(1);
    const success = outcomes.find((item) => item.status === 'fulfilled');
    expect(success?.status === 'fulfilled' && success.value.nonce).toBe(challenge.nonce);
    await expect(restarted.takeChallenge(challenge)).rejects.toMatchObject({ code: 'unauthorized' });
  });

  it('rejects wrong proofs without destroying the real challenge and enforces exact expiry', async () => {
    const f = await fixture();
    const challenge = await f.auth.issueChallenge();
    await expect(f.auth.takeChallenge({ ...challenge, challengeProof: 'X'.repeat(43) })).rejects.toMatchObject({ code: 'unauthorized' });
    expect((await f.auth.takeChallenge(challenge)).nonce).toBe(challenge.nonce);
    const expired = await f.auth.issueChallenge();
    f.advance(300_000);
    await expect(f.auth.takeChallenge(expired)).rejects.toMatchObject({ code: 'unauthorized' });
  });

  it('keeps one opaque owner across concurrent logins, new instances and refresh rotation', async () => {
    const f = await fixture();
    const restarted = new DurableAuth(f.dependencies);
    const sessions = await Promise.all([f.auth.establish(f.identity), restarted.establish({ ...f.identity, refreshToken: 'replacement' })]);
    expect(sessions[0]!.ownerId).toBe(sessions[1]!.ownerId);
    expect(sessions[0]!.token).not.toBe(sessions[1]!.token);
    expect((await restarted.requireSession(sessions[0]!.token)).ownerId).toBe(sessions[0]!.ownerId);
    expect(JSON.stringify(sessions)).not.toContain(f.identity.subject);
  });

  it('separates different subjects and issuers without email, device or billing identifiers', async () => {
    const f = await fixture();
    const results = await Promise.all([
      f.auth.establish(f.identity), f.auth.establish({ ...f.identity, subject: `${f.identity.subject}-other` }),
      f.auth.establish({ ...f.identity, issuer: 'https://other.invalid' }),
    ]);
    expect(new Set(results.map((item) => item.ownerId)).size).toBe(3);
  });

  it('persists only HMAC identity, hashed session tokens and context-bound encrypted credentials', async () => {
    const f = await fixture();
    const session = await f.auth.establish(f.identity);
    const owner = await db.prepare('SELECT * FROM pa_owners WHERE owner_id = ?').bind(session.ownerId).first();
    const stored = await db.prepare('SELECT * FROM pa_sessions WHERE owner_id = ?').bind(session.ownerId).first();
    const credential = await db.prepare('SELECT sealed_credentials FROM pa_identity_credentials WHERE owner_id = ?')
      .bind(session.ownerId).first<{ sealed_credentials: number[] }>();
    expect(owner?.identity_key).toMatch(/^[a-f0-9]{64}$/);
    expect(stored?.session_hash).toBe(await sha256(session.token));
    const raw = JSON.stringify({ owner, stored, credential });
    for (const value of [f.identity.subject, f.identity.refreshToken, session.token]) expect(raw).not.toContain(value);
    const sealed = new Uint8Array(credential!.sealed_credentials);
    const decoded = await f.keys.open(sealed, { ownerId: session.ownerId, purpose: 'identity' });
    expect(JSON.parse(decoder.decode(decoded))).toEqual(f.identity);
    await expect(f.keys.open(sealed, { ownerId: 'someone-else', purpose: 'identity' })).rejects.toThrow();
  });

  it('fails closed on custody failure without issuing a session or leaking provider errors', async () => {
    const f = await fixture();
    let attemptedOwner: string | undefined;
    const auth = new DurableAuth({ ...f.dependencies,
      keys: { ...f.keys, seal: async (_bytes, context) => {
        attemptedOwner = context.ownerId;
        throw new Error(f.identity.refreshToken);
      } } });
    await expect(auth.establish(f.identity)).rejects.toMatchObject({ code: 'identity_key_unavailable', message: 'identity_key_unavailable' });
    expect(attemptedOwner).toBeDefined();
    const count = await db.prepare('SELECT COUNT(*) AS count FROM pa_sessions WHERE owner_id = ?')
      .bind(attemptedOwner!).first<{ count: number }>();
    expect(count?.count).toBe(0);
  });

  it('rejects malformed/unknown sessions and expires sessions at fifteen minutes', async () => {
    const f = await fixture();
    for (const value of ['', 'owner-id', 'X'.repeat(43)]) await expect(f.auth.requireSession(value)).rejects.toMatchObject({ code: 'unauthorized' });
    const session = await f.auth.establish(f.identity);
    f.advance(899_999);
    expect((await f.auth.requireSession(session.token)).ownerId).toBe(session.ownerId);
    f.advance(1);
    await expect(f.auth.requireSession(session.token)).rejects.toMatchObject({ code: 'unauthorized' });
  });

  it('logs out one session durably while leaving another and the owner intact', async () => {
    const f = await fixture();
    const first = await f.auth.establish(f.identity);
    const second = await f.auth.establish(f.identity);
    await f.auth.revokeSession(first.token);
    await f.auth.revokeSession(first.token);
    const restarted = new DurableAuth(f.dependencies);
    await expect(restarted.requireSession(first.token)).rejects.toMatchObject({ code: 'unauthorized' });
    expect((await restarted.requireSession(second.token)).ownerId).toBe(first.ownerId);
  });

  it('owner revocation preserves its row but rejects old sessions and future establishment', async () => {
    const f = await fixture();
    const session = await f.auth.establish(f.identity);
    await f.auth.revokeOwner(session.ownerId);
    const restarted = new DurableAuth(f.dependencies);
    await expect(restarted.requireSession(session.token)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(restarted.establish(f.identity)).rejects.toMatchObject({ code: 'unauthorized' });
    expect(await db.prepare('SELECT epoch, disabled FROM pa_owners WHERE owner_id = ?').bind(session.ownerId).first())
      .toEqual({ epoch: 1, disabled: 1 });
  });

  it('fences an owner revoked while asynchronous key sealing is in flight', async () => {
    const f = await fixture();
    const prior = await f.auth.establish(f.identity);
    const auth = new DurableAuth({ ...f.dependencies, keys: { ...f.keys, async seal(bytes, context) {
      await f.auth.revokeOwner(prior.ownerId);
      return f.keys.seal(bytes, context);
    } } });
    await expect(auth.establish({ ...f.identity, refreshToken: 'must-not-replace' })).rejects.toMatchObject({ code: 'unauthorized' });
    const credential = await db.prepare('SELECT sealed_credentials FROM pa_identity_credentials WHERE owner_id = ?')
      .bind(prior.ownerId).first<{ sealed_credentials: number[] }>();
    const decoded = await f.keys.open(new Uint8Array(credential!.sealed_credentials), { ownerId: prior.ownerId, purpose: 'identity' });
    expect(JSON.parse(decoder.decode(decoded)).refreshToken).toBe(f.identity.refreshToken);
    expect((await db.prepare('SELECT COUNT(*) AS count FROM pa_sessions WHERE owner_id = ?').bind(prior.ownerId).first<{ count: number }>())?.count).toBe(1);
  });

  it('bounds expiry cleanup and preserves owners', async () => {
    const f = await fixture();
    const session = await f.auth.establish(f.identity);
    for (let i = 0; i < 4; i++) await f.auth.issueChallenge();
    f.advance(900_000);
    const current = await f.auth.issueChallenge();
    const removed = await f.auth.cleanup(2);
    expect(removed).toBeGreaterThan(0);
    expect(removed).toBeLessThanOrEqual(4);
    expect((await f.auth.takeChallenge(current)).nonce).toBe(current.nonce);
    expect(await db.prepare('SELECT owner_id FROM pa_owners WHERE owner_id = ?').bind(session.ownerId).first()).not.toBeNull();
    await expect(f.auth.cleanup(501)).rejects.toMatchObject({ code: 'invalid_cleanup_limit' });
  });

  it('requires a canonical server secret of at least thirty-two bytes', async () => {
    const f = await fixture();
    for (const bad of ['', 'short-secret', `${secret}=`, 'A'.repeat(42), ' '.repeat(43)]) {
      expect(() => new DurableAuth({ ...f.dependencies, identityIndexSecret: bad }))
        .toThrow('auth_configuration_invalid');
    }
    const sameSecret = new DurableAuth(f.dependencies);
    const a = await f.auth.establish(f.identity);
    const b = await sameSecret.establish(f.identity);
    expect(a.ownerId).toBe(b.ownerId);
  });
});
