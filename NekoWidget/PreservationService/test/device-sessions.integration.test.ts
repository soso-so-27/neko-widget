import { env } from 'cloudflare:workers';
import { beforeEach, describe, expect, it } from 'vitest';
import { exportJWK, generateKeyPair, SignJWT, type JWTPayload } from 'jose';
import { DurableAuth } from '../src/auth';
import { deviceBinding } from '../src/device-proof';
import { type AuthDependencies, type IdentityVerifier, type VerifiedIdentity, ServiceError } from '../src/contracts';
import { route, type Services } from '../src/index';
import { ownerD1DeleteOrder } from '../src/owner-d1-residue';

const db = (env as unknown as { DB: D1Database }).DB;
const ORIGIN = 'https://preservation.invalid';
const START = Date.UTC(2026, 9, 18);
const DAY = 86_400_000;
beforeEach(async () => {
  await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=0 WHERE singleton=1').run();
  for (const table of ownerD1DeleteOrder) await db.prepare(`DELETE FROM ${table}`).run();
});
async function fixture(database = db) {
  let now = START;
  let opens = 0; let seals = 0; let remote = 0;
  const pair = await generateKeyPair('ES256', { extractable: true });
  const jwk = await exportJWK(pair.publicKey);
  const binding = await deviceBinding(jwk, ORIGIN);
  const aes = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const dependencies: AuthDependencies = { db: database, identityIndexSecret: 'B'.repeat(42) + 'A', now: () => now, keys: {
    async seal(bytes) {
      seals++; const iv = crypto.getRandomValues(new Uint8Array(12));
      const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, aes, bytes as BufferSource));
      const result = new Uint8Array(iv.length + ciphertext.length); result.set(iv); result.set(ciphertext, iv.length); return result;
    },
    async open(bytes) { opens++; return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) }, aes, bytes.slice(12))); },
  } };
  const identity: VerifiedIdentity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(),
    refreshToken: 'synthetic-refresh', deviceBinding: binding };
  const auth = new DurableAuth(dependencies);
  const session = await auth.establish(identity);
  const verifier: IdentityVerifier = { async verifyNativeAuthorization() { throw new Error('not used'); },
    async verifyRefreshIdentity(value) { remote++; return value; } };
  const signed = async (purpose: 'renew' | 'revoke' = 'renew', claims: JWTPayload = {}, privateKey = pair.privateKey,
    header: Record<string, unknown> = {}, grantId = session.deviceGrant!.grantId) => {
    const challenge = await auth.devices.issueChallenge(grantId, purpose, ORIGIN);
    const deviceProof = await new SignJWT({ v: 1, jti: challenge.challengeId, sub: grantId, nonce: challenge.nonce,
      htm: 'POST', htu: ORIGIN + (purpose === 'renew' ? '/v1/auth/session-renewals' : '/v1/auth/session-revocations'),
      iat: Math.floor(now / 1000), exp: Math.floor(now / 1000) + 90, ...claims })
      .setProtectedHeader({ alg: 'ES256', typ: 'dpop+jwt', jwk, ...header }).sign(privateKey);
    return { grantId, challengeId: challenge.challengeId, deviceProof, origin: ORIGIN };
  };
  return { auth, dependencies, identity, session, verifier, signed, pair, binding,
    advance: (ms: number) => { now += ms; }, now: () => now,
    counts: () => ({ opens, seals, remote }) };
}
const count = async (table: string, owner: string) => (await db.prepare(`SELECT count(*) AS n FROM ${table} WHERE owner_id=?`)
  .bind(owner).first<{ n: number }>())!.n;
async function acknowledgeRecovery(ownerId: string) {
  await db.prepare(`INSERT INTO pa_owner_recovery_versions(owner_id,generation,object_key,version_id,sha256,bytes,confirmed_at)
    SELECT owner_id,generation,?,?,?,1,? FROM pa_owner_recovery_generations WHERE owner_id=?`)
    .bind('synthetic/' + crypto.randomUUID(), 'version', 'a'.repeat(64), START, ownerId).run();
}

function meteredDatabase() {
  const totals = { statements: 0, rowsRead: 0, rowsWritten: 0 };
  const originals = new WeakMap<D1PreparedStatement, D1PreparedStatement>();
  const record = (result: D1Result) => {
    totals.statements++; totals.rowsRead += result.meta.rows_read; totals.rowsWritten += result.meta.rows_written;
  };
  const wrap = (statement: D1PreparedStatement): D1PreparedStatement => {
    const proxy = new Proxy(statement, { get(target, key) {
      if (key === 'bind') return (...values: unknown[]) => wrap(target.bind(...values));
      if (key === 'first') return async (column?: string) => {
        const result = await target.all<Record<string, unknown>>(); record(result);
        const row = result.results[0] ?? null; return column && row ? row[column] : row;
      };
      if (key === 'run' || key === 'all') return async () => { const result = await target[key](); record(result); return result; };
      const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
    } });
    originals.set(proxy, statement); return proxy;
  };
  return { database: new Proxy(db, { get(target, key) {
    if (key === 'prepare') return (query: string) => wrap(target.prepare(query));
    if (key === 'batch') return async (statements: D1PreparedStatement[]) => {
      const results = await target.batch(statements.map(statement => originals.get(statement) ?? statement));
      results.forEach(record); return results;
    };
    const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
  } }), take() { const value = { ...totals }; totals.statements = 0; totals.rowsRead = 0; totals.rowsWritten = 0; return value; } };
}

describe('device-bound preservation sessions', () => {
  it('records actual local D1 and key-operation costs for the bounded renewal lifecycle', async () => {
    const meter = meteredDatabase();
    const f = await fixture(meter.database);
    await f.auth.takeChallenge(await f.auth.issueChallenge(f.binding.publicKey, ORIGIN));
    const initial = { ...meter.take(), ...f.counts() };
    f.advance(900_000);
    await f.auth.devices.renew(await f.signed(), f.verifier);
    const renewal = { ...meter.take(), ...f.counts() };
    f.advance(DAY);
    await f.auth.devices.renew(await f.signed(), f.verifier);
    const daily = { ...meter.take(), ...f.counts() };
    await f.auth.devices.revoke(await f.signed('revoke'));
    const revoke = { ...meter.take(), ...f.counts() };
    expect(renewal.opens).toBe(0); expect(renewal.remote).toBe(0);
    expect(daily.opens).toBe(1); expect(daily.remote).toBe(1); expect(daily.seals).toBe(1);
    expect(revoke.opens).toBe(daily.opens); expect(revoke.remote).toBe(daily.remote);
    // No PII, token, key or content is emitted. These are measured local D1
    // metadata (including trigger/index writes), not a production billing claim.
    console.info('device-session-local-cost', JSON.stringify({ initial, renewal, daily, revoke }));
  });
  it('keeps 15-minute bearer expiry and renews the same owner without KMS or Apple work', async () => {
    const f = await fixture();
    expect(f.session.deviceGrant).toMatchObject({ appleUserID: f.identity.subject });
    expect(f.session.deviceGrant!.grantId).toMatch(/^[0-9a-f-]{36}$/u);
    expect(f.counts()).toEqual({ opens: 0, seals: 1, remote: 0 });
    f.advance(900_000);
    await expect(f.auth.requireSession(f.session.token)).rejects.toMatchObject({ code: 'unauthorized' });
    const renewed = await f.auth.devices.renew(await f.signed(), f.verifier);
    expect(renewed.ownerId).toBe(f.session.ownerId);
    expect(renewed.deviceGrant).toEqual({ grantId: f.session.deviceGrant!.grantId,
      idleExpiresAt: new Date(f.now() + 30 * DAY).toISOString() });
    expect(renewed.expiresAt).toBe(new Date(f.now() + 900_000).toISOString());
    expect((await f.auth.requireSession(renewed.token)).ownerId).toBe(f.session.ownerId);
    expect(f.counts()).toEqual({ opens: 0, seals: 1, remote: 0 });
  });

  it('preserves legacy login without a device grant and its original expiry', async () => {
    const f = await fixture();
    const { deviceBinding: ignored, ...identity } = f.identity;
    const old = await f.auth.establish(identity);
    expect(old.deviceGrant).toBeUndefined();
    expect(await count('pa_device_session_grants', old.ownerId)).toBe(1);
    f.advance(900_000);
    await expect(f.auth.requireSession(old.token)).rejects.toMatchObject({ code: 'unauthorized' });
  });

  it('has one atomic winner across replay and concurrent proofs, with bounded challenge rows', async () => {
    const f = await fixture();
    const first = await f.auth.devices.issueChallenge(f.session.deviceGrant!.grantId, 'renew', ORIGIN);
    expect(await f.auth.devices.issueChallenge(f.session.deviceGrant!.grantId, 'renew', ORIGIN)).toEqual(first);
    const proof = await f.signed();
    const results = await Promise.allSettled([f.auth.devices.renew(proof, f.verifier), f.auth.devices.renew(proof, f.verifier)]);
    expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1);
    await expect(f.auth.devices.renew(proof, f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    expect(await count('pa_sessions', f.session.ownerId)).toBe(2);
    expect(await count('pa_device_session_challenges', f.session.ownerId)).toBe(1);
  });

  it.each([
    { v: 2 }, { sub: 'other-grant' }, { jti: 'other-challenge' }, { nonce: 'other-nonce' },
    { htm: 'GET' }, { htu: ORIGIN + '/v1/auth/session-revocations' },
    { htu: 'https://other.invalid/v1/auth/session-renewals' },
    { iat: START / 1000 + 31 }, { exp: START / 1000 }, { exp: START / 1000 + 121 },
    { unexpected: true },
  ])('rejects a signed proof with substituted claims %j', async claims => {
    const f = await fixture();
    await expect(f.auth.devices.renew(await f.signed('renew', claims), f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    expect(await count('pa_sessions', f.session.ownerId)).toBe(1);
    expect(f.counts().remote).toBe(0);
  });

  it('rejects a different key, header, request origin, grant, expired challenge and cross-purpose proof', async () => {
    const f = await fixture();
    const other = await generateKeyPair('ES256');
    await expect(f.auth.devices.renew(await f.signed('renew', {}, other.privateKey), f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(f.auth.devices.renew(await f.signed('renew', {}, other.privateKey,
      { jwk: await exportJWK(other.publicKey) }), f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(f.auth.devices.renew(await f.signed('renew', {}, f.pair.privateKey, { typ: 'JWT' }), f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    const proof = await f.signed();
    await expect(f.auth.devices.renew({ ...proof, origin: 'https://other.invalid' }, f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(f.auth.devices.renew({ ...proof, grantId: crypto.randomUUID() }, f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(f.auth.devices.revoke(proof)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(f.auth.devices.renew(await f.signed('revoke'), f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    f.advance(300_000);
    await expect(f.auth.devices.renew(proof, f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
  });

  it('expires an idle grant after 30 days but permits signed revocation without live access', async () => {
    const f = await fixture();
    f.advance(30 * DAY);
    await expect(f.auth.devices.issueChallenge(f.session.deviceGrant!.grantId, 'renew', ORIGIN)).rejects.toMatchObject({ code: 'unauthorized' });
    await f.auth.devices.revoke(await f.signed('revoke'));
    expect(await count('pa_sessions', f.session.ownerId)).toBe(0);
    expect(f.counts().remote).toBe(0);
  });

  it('revokes only the captured device and all its access tokens without Apple validation', async () => {
    const f = await fixture();
    const other = await f.auth.establish(f.identity);
    const renewed = await f.auth.devices.renew(await f.signed(), f.verifier);
    f.advance(DAY);
    await f.auth.devices.revoke(await f.signed('revoke'));
    await expect(f.auth.requireSession(renewed.token)).rejects.toMatchObject({ code: 'unauthorized' });
    expect(await count('pa_sessions', f.session.ownerId)).toBe(1);
    await expect(f.auth.devices.issueChallenge(other.deviceGrant!.grantId, 'renew', ORIGIN)).resolves.toHaveProperty('nonce');
    expect(f.counts().remote).toBe(0);
  });

  it('legacy logout also revokes a bound grant while leaving other devices alone', async () => {
    const f = await fixture();
    const other = await f.auth.establish(f.identity);
    const renewed = await f.auth.devices.renew(await f.signed(), f.verifier);
    await f.auth.revokeSession(f.session.token);
    await expect(f.auth.requireSession(renewed.token)).rejects.toMatchObject({ code: 'unauthorized' });
    await expect(f.auth.requireSession(other.token)).resolves.toHaveProperty('ownerId');
  });

  it.each(['epoch', 'disabled', 'identity', 'deletion'] as const)('refuses %s owner changes and invalidates surviving device authority', async reason => {
    const f = await fixture();
    const proof = await f.signed();
    if (reason === 'deletion') await db.prepare(`INSERT INTO pa_owner_deletion_requests
      (owner_id,request_id,receipt_hash,owner_epoch,requested_at,request_sha256,state)
      VALUES(?,?,?,1,?,?,'requested')`).bind(f.session.ownerId, crypto.randomUUID(), 'a'.repeat(64), START, 'b'.repeat(64)).run();
    else await db.prepare(`UPDATE pa_owners SET ${reason === 'epoch' ? 'epoch=epoch+1' : reason === 'identity' ? "identity_key='changed-identity'" : 'disabled=1'} WHERE owner_id=?`)
      .bind(f.session.ownerId).run();
    await expect(f.auth.devices.renew(proof, f.verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    if (reason !== 'deletion') {
      expect(await count('pa_device_session_challenges', f.session.ownerId)).toBe(0);
      expect(await count('pa_sessions', f.session.ownerId)).toBe(0);
      await db.prepare('UPDATE pa_owners SET disabled=0,epoch=epoch+1 WHERE owner_id=?').bind(f.session.ownerId).run();
      await expect(f.auth.devices.issueChallenge(f.session.deviceGrant!.grantId, 'renew', ORIGIN)).rejects.toMatchObject({ code: 'unauthorized' });
    }
  });

  it('single-flights daily Apple validation and keeps unchanged credentials sealed without a recovery rewrite', async () => {
    const f = await fixture();
    f.advance(DAY);
    let calls = 0; let release!: () => void; let started!: () => void;
    const pending = new Promise<void>(resolve => { release = resolve; });
    const entered = new Promise<void>(resolve => { started = resolve; });
    const verifier: IdentityVerifier = { ...f.verifier, async verifyRefreshIdentity(identity) { calls++; started(); await pending; return identity; } };
    const proof = await f.signed();
    const first = f.auth.devices.renew(proof, verifier);
    await entered;
    await expect(f.auth.devices.renew(proof, verifier)).rejects.toMatchObject({ code: 'auth_unavailable', status: 503 });
    release(); await first;
    expect(calls).toBe(1);
    expect(f.counts()).toEqual({ opens: 1, seals: 1, remote: 0 });
    await f.auth.devices.renew(await f.signed(), verifier);
    expect(calls).toBe(1);
  });

  it('retains credentials and grants after temporary Apple failure and respects the daily attempt limit', async () => {
    const f = await fixture();
    const prior = await db.prepare('SELECT hex(sealed_credentials) AS bytes FROM pa_identity_credentials WHERE owner_id=?')
      .bind(f.session.ownerId).first();
    f.advance(DAY);
    let calls = 0;
    const failing = { ...f.verifier, async verifyRefreshIdentity(): Promise<VerifiedIdentity> { calls++; throw new ServiceError('APPLE_UNAVAILABLE', 503); } };
    await expect(f.auth.devices.renew(await f.signed(), failing)).rejects.toMatchObject({ code: 'APPLE_UNAVAILABLE' });
    await expect(f.auth.devices.renew(await f.signed(), failing)).rejects.toMatchObject({ code: 'auth_unavailable' });
    expect(calls).toBe(1);
    expect(await db.prepare('SELECT hex(sealed_credentials) AS bytes FROM pa_identity_credentials WHERE owner_id=?')
      .bind(f.session.ownerId).first()).toEqual(prior);
    expect((await db.prepare('SELECT revoked_at FROM pa_device_session_grants WHERE grant_id=?')
      .bind(f.session.deviceGrant!.grantId).first())!.revoked_at).toBeNull();
    f.advance(DAY);
    await expect(f.auth.devices.renew(await f.signed(), f.verifier)).resolves.toHaveProperty('token');
  });

  it('invalid_grant revokes device sessions without deleting original owner or credentials', async () => {
    const f = await fixture();
    await f.auth.establish(f.identity);
    f.advance(DAY);
    await expect(f.auth.devices.renew(await f.signed(), { ...f.verifier,
      async verifyRefreshIdentity() { throw new ServiceError('APPLE_AUTHORIZATION_REJECTED', 401); },
    })).rejects.toMatchObject({ code: 'APPLE_AUTHORIZATION_REJECTED' });
    expect(await count('pa_sessions', f.session.ownerId)).toBe(0);
    expect(await count('pa_owners', f.session.ownerId)).toBe(1);
    expect(await count('pa_identity_credentials', f.session.ownerId)).toBe(1);
    expect(await db.prepare('SELECT 1 FROM pa_device_session_grants WHERE owner_id=? AND revoked_at IS NULL')
      .bind(f.session.ownerId).first()).toBeNull();
  });

  it('seals a rotated refresh token with CAS and copies the changed owner before granting access', async () => {
    const f = await fixture();
    let copies = 0;
    const auth = new DurableAuth({ ...f.dependencies, ownerRecovery: { async copyCurrent(database, ownerId) {
      copies++;
      const row = await database.prepare('SELECT sealed_credentials FROM pa_identity_credentials WHERE owner_id=?').bind(ownerId).first<{ sealed_credentials: ArrayBuffer }>();
      const bytes = await f.dependencies.keys.open(new Uint8Array(row!.sealed_credentials), { ownerId, purpose: 'identity' });
      expect(JSON.parse(new TextDecoder().decode(bytes))).toEqual({ issuer: f.identity.issuer, subject: f.identity.subject, refreshToken: 'rotated' });
    } } });
    f.advance(DAY);
    await auth.devices.renew(await f.signed(), { ...f.verifier, async verifyRefreshIdentity(identity) { return { ...identity, refreshToken: 'rotated' }; } });
    expect(copies).toBe(1);
    expect(f.counts().seals).toBe(2);
  });

  it('blocks the failed rotation and the next renewal until the current recovery generation is backed', async () => {
    const f = await fixture();
    await acknowledgeRecovery(f.session.ownerId);
    await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=1 WHERE singleton=1').run();
    const auth = new DurableAuth({ ...f.dependencies, requireOwnerRecovery: true,
      ownerRecovery: { async copyCurrent() { throw new ServiceError('OWNER_RECOVERY_UNAVAILABLE', 503); } } });
    f.advance(DAY);
    const proof = await f.signed();
    let calls = 0;
    const verifier = { ...f.verifier, async verifyRefreshIdentity(identity: VerifiedIdentity) { calls++; return { ...identity, refreshToken: 'rotated' }; } };
    await expect(auth.devices.renew(proof, verifier)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
    await expect(auth.devices.renew(proof, verifier)).rejects.toMatchObject({ code: 'unauthorized' });
    expect(await count('pa_sessions', f.session.ownerId)).toBe(1);
    expect(calls).toBe(1);
    // The existing independent recovery repair can acknowledge this exact
    // generation. No second Apple call is needed and the failed proof was not consumed.
    await acknowledgeRecovery(f.session.ownerId);
    await expect(auth.devices.renew(proof, verifier)).resolves.toHaveProperty('token');
    expect(calls).toBe(1);
  });

  it.each(['rotation', 'invalid_grant'] as const)('a late %s response cannot overwrite or revoke a newer Apple login', async late => {
    const f = await fixture();
    f.advance(DAY);
    const proof = await f.signed();
    let replacement: Awaited<ReturnType<DurableAuth['establish']>>;
    const verifier = { ...f.verifier, async verifyRefreshIdentity(identity: VerifiedIdentity) {
      replacement = await f.auth.establish({ ...f.identity, refreshToken: 'new-sign-in' });
      if (late === 'invalid_grant') throw new ServiceError('APPLE_AUTHORIZATION_REJECTED', 401);
      return { ...identity, refreshToken: 'late-old-response' };
    } };
    await expect(f.auth.devices.renew(proof, verifier)).rejects.toBeInstanceOf(ServiceError);
    await expect(f.auth.requireSession(replacement!.token)).resolves.toHaveProperty('ownerId');
    await expect(f.auth.devices.issueChallenge(replacement!.deviceGrant!.grantId, 'renew', ORIGIN)).resolves.toHaveProperty('nonce');
    const row = await db.prepare('SELECT sealed_credentials FROM pa_identity_credentials WHERE owner_id=?')
      .bind(f.session.ownerId).first<{ sealed_credentials: ArrayBuffer }>();
    const opened = await f.dependencies.keys.open(new Uint8Array(row!.sealed_credentials), { ownerId: f.session.ownerId, purpose: 'identity' });
    expect(JSON.parse(new TextDecoder().decode(opened)).refreshToken).toBe('new-sign-in');
  });

  it.each(['revocation', 'deletion', 'recovery'] as const)('refuses %s that occurs during provider work', async event => {
      const f = await fixture(); f.advance(DAY);
      if (event === 'recovery') {
        await acknowledgeRecovery(f.session.ownerId);
        await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=1 WHERE singleton=1').run();
      }
      const proof = await f.signed();
      let deleted = false;
      const auth = new DurableAuth({ ...f.dependencies, ownerDeletion: { async assertNotRequested() {
        if (deleted) throw new ServiceError('OWNER_DELETION_REQUESTED', 401);
      } } });
      await expect(auth.devices.renew(proof, { ...f.verifier, async verifyRefreshIdentity(identity) {
        if (event === 'revocation') await f.auth.revokeOwner(f.session.ownerId);
        if (event === 'deletion') deleted = true;
        if (event === 'recovery') await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?').bind(f.session.ownerId).run();
        return identity;
      } })).rejects.toBeInstanceOf(ServiceError);
  });

  it('bounded cleanup prunes expired device authority while keeping owner and sealed originals', async () => {
    const f = await fixture();
    await f.signed();
    await f.signed('revoke');
    f.advance(30 * DAY);
    const removed = await f.auth.cleanup(1);
    expect(removed).toBeLessThanOrEqual(5);
    expect(await count('pa_device_session_challenges', f.session.ownerId)).toBe(1);
    expect(await count('pa_device_session_grants', f.session.ownerId)).toBe(1);
    await f.auth.cleanup(1);
    expect(await count('pa_device_session_challenges', f.session.ownerId)).toBe(0);
    expect(await count('pa_device_session_grants', f.session.ownerId)).toBe(0);
    expect(await count('pa_device_identity_checks', f.session.ownerId)).toBe(0);
    expect(await count('pa_identity_credentials', f.session.ownerId)).toBe(1);
    expect(await count('pa_owners', f.session.ownerId)).toBe(1);
  });

  it('routes grant operations without a bearer but rejects client-selected fields and cross-purpose paths', async () => {
    const f = await fixture();
    const services = { auth: f.auth, verifier: f.verifier } as Services;
    const call = (path: string, value: unknown) => route(new Request(ORIGIN + path, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify(value) }), services);
    await expect(call('/v1/auth/challenges', { devicePublicKey: { ...f.binding.publicKey, d: 'private' } }))
      .rejects.toMatchObject({ code: 'unauthorized' });
    await expect(call('/v1/auth/challenges', { devicePublicKey: f.binding.publicKey, ownerId: f.session.ownerId }))
      .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
    await expect(call('/v1/auth/session-challenges', { grantId: f.session.deviceGrant!.grantId, purpose: 'other' }))
      .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
    const { origin: ignored, ...proof } = await f.signed();
    expect((await call('/v1/auth/session-renewals', proof)).status).toBe(200);
    const { origin: ignoredAgain, ...revoke } = await f.signed('revoke');
    const result = await call('/v1/auth/session-revocations', revoke);
    expect(result.status).toBe(204); expect(await result.text()).toBe('');
  });
});
