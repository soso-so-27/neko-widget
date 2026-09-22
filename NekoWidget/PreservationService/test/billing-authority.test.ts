import { env } from 'cloudflare:workers';
import { applyD1Migrations, createExecutionContext, type D1Migration } from 'cloudflare:test';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import publicWorker, { BillingAuthority, type BillingAuthorityEnv } from '../src/billing-authority';
import { type BillingProof, type LinkChallenge, LINK_SIGNING_PATH, LINK_TTL_MS, linkTranscript } from '../src/billing-link-protocol';
import { randomToken, sha256 } from '../src/contracts';
import { DurableAuth } from '../src/auth';
import { envelopeKeyCustody } from '../src/key-custody';
import { MembershipLinks } from '../src/membership-links';
import { boundBillingAuthority } from '../src/providers';
import { syntheticKeyAuthority } from './key-fixture';
import { billingSignedRequestTranscript } from '../../SharingService/src/billing-protocol';
import { base64urlEncode, randomBase64url, sha256Base64url } from '../../SharingService/src/encoding';
import { runBillingSubscriptionReconciliation } from '../../SharingService/src/billing-authority';
import { requestBillingReconciliation } from '../../SharingService/src/billing-reconciliation-queue';
import type { Env as SharingEnv } from '../../SharingService/src/env';
import type { VerifiedBillingTransaction } from '../../SharingService/src/billing-verifier-client';

// Real existing billing migrations and Ed25519 keys, synthetic accounts only.
// The DB is local Cloudflare test SQLite; all Apple fetches are injected fixtures.
const bindings = env as unknown as { DB: D1Database; TEST_BILLING_MIGRATIONS: D1Migration[] };
const db = bindings.DB;
const audience = 'preservation.synthetic-test';
const enabled: BillingAuthorityEnv = { DB: db, PRESERVATION_BILLING_ENABLED: 'YES',
  PRESERVATION_LINK_AUDIENCE: audience, BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: 'YES' };
const makeWorker = (overrides: Partial<BillingAuthorityEnv> = {}) => new BillingAuthority(createExecutionContext(), { ...enabled, ...overrides });
const request = (path: string, value: unknown) => new Request(`https://private.invalid/membership/${path}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value),
});
const verify = (challenge: LinkChallenge, proof: BillingProof, worker = makeWorker()) => worker.fetch(request('verify-link', { challenge, proof }));
const status = (billingAccountId: string, worker = makeWorker()) => worker.fetch(request('verified-status', { billingAccountId }));

async function fixture() {
  const keys = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const billingAccountId = crypto.randomUUID(); const billingKeyId = randomBase64url(16);
  const publicKey = base64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey)));
  await db.batch([
    db.prepare('INSERT INTO billing_accounts(id) VALUES (?)').bind(billingAccountId),
    db.prepare("INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state) VALUES (?,?,?,'active')")
      .bind(billingKeyId, billingAccountId, publicKey),
  ]);
  const now = Date.now();
  const challenge: LinkChallenge = { version: 1, purpose: 'preservation-membership-link', audience,
    challengeId: randomToken(), ownerId: crypto.randomUUID(), billingAccountId, issuedAt: now, expiresAt: now + LINK_TTL_MS };
  async function sign(value = challenge, overrides: { body?: string; method?: string; pathname?: string; timestamp?: number } = {}): Promise<BillingProof> {
    const timestamp = overrides.timestamp ?? Math.floor(Date.now() / 1000); const nonce = randomBase64url(16);
    const transcript = billingSignedRequestTranscript({ billingAccountId: value.billingAccountId, billingKeyId, timestamp, nonce,
      method: overrides.method ?? 'POST', pathname: overrides.pathname ?? LINK_SIGNING_PATH,
      bodySHA256: await sha256Base64url(new TextEncoder().encode(overrides.body ?? linkTranscript(value))) });
    const signature = base64urlEncode(new Uint8Array(await crypto.subtle.sign('Ed25519', keys.privateKey, transcript as BufferSource)));
    return { billingKeyId, timestamp: String(timestamp), nonce, signature };
  }
  const revoke = () => db.prepare("UPDATE billing_account_keys SET state='revoked',revoked_at=unixepoch() WHERE id=?")
    .bind(billingKeyId).run();
  return { billingAccountId, billingKeyId, challenge, sign, revoke };
}

let transactionCounter = 0;
async function entitlement(billingAccountId: string, appleStatus: 1 | 2 | 3 | 4 | 5) {
  const now = Date.now(); const originalTransactionId = `${now}${++transactionCounter}`;
  const transaction: VerifiedBillingTransaction = { billingAccountId, originalTransactionId, transactionId: originalTransactionId,
    productId: 'jp.synthetic.monthly', subscriptionGroupId: 'synthetic', bundleId: 'jp.synthetic.app', environment: 'Sandbox',
    ownershipType: 'PURCHASED', transactionReason: 'PURCHASE', purchaseDateMs: now - 1000, originalPurchaseDateMs: now - 1000,
    expiresDateMs: now + 7 * 86_400_000, signedDateMs: now,
    revocationDateMs: appleStatus === 5 ? now : null, revocationReason: null, isUpgraded: false };
  await db.prepare(`INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id)
    VALUES (?,?,'Sandbox','synthetic')`).bind(originalTransactionId, billingAccountId).run();
  await requestBillingReconciliation(enabled as SharingEnv, originalTransactionId);
  await runBillingSubscriptionReconciliation(enabled as SharingEnv, async () => ({
    requestedTransactionId: originalTransactionId, environment: 'Sandbox', bundleId: 'jp.synthetic.app', fetchedAtMs: now,
    items: [{ status: appleStatus, originalTransactionId, transaction,
      renewal: { originalTransactionId, billingAccountId, productId: transaction.productId, autoRenewProductId: transaction.productId,
        autoRenewStatus: 1, isInBillingRetryPeriod: appleStatus === 3 || appleStatus === 4,
        gracePeriodExpiresDateMs: appleStatus === 4 ? now + 86_400_000 : null,
        renewalDateMs: transaction.expiresDateMs, signedDateMs: now, environment: 'Sandbox' } }],
  }));
  expect(await db.prepare('SELECT original_transaction_id FROM billing_effective_entitlement_current WHERE original_transaction_id=?')
    .bind(originalTransactionId).first()).not.toBeNull();
}

describe('private preservation billing authority', () => {
  beforeAll(async () => {
    expect(bindings.TEST_BILLING_MIGRATIONS).toHaveLength(3);
    await applyD1Migrations(db, bindings.TEST_BILLING_MIGRATIONS, 'test_billing_migrations');
  });
  beforeEach(async () => {
    await db.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,updated_at=unixepoch(),
      effective_entitlement_enabled=1,subscription_reconciliation_enabled=1 WHERE singleton=1`).run();
  });

  it('keeps default public fetch closed and requires explicit private configuration before DB access', async () => {
    expect((await publicWorker.fetch(request('verify-link', {}))).status).toBe(404);
    const inaccessible = new Proxy({} as D1Database, { get() { throw new Error('must not touch DB'); } });
    for (const overrides of [{ PRESERVATION_BILLING_ENABLED: 'NO' }, { PRESERVATION_LINK_AUDIENCE: '' },
      { PRESERVATION_LINK_AUDIENCE: 'https://arbitrary.invalid' }]) {
      expect((await status(crypto.randomUUID(), makeWorker({ ...overrides, DB: inaccessible }))).status).toBe(503);
    }
    expect((await makeWorker().fetch(request('unknown', {}))).status).toBe(404);
    expect((await makeWorker().fetch(new Request('https://private.invalid/membership/verify-link'))).status).toBe(404);
  });

  it('verifies a real billing key without paid access and consumes each nonce once, including concurrent attempts', async () => {
    const f = await fixture(); const proof = await f.sign();
    const results = await Promise.all([verify(f.challenge, proof), verify(f.challenge, proof)]);
    expect(results.map(result => result.status).sort()).toEqual([200, 409]);
    const success = results.find(result => result.status === 200)!;
    expect(await success.json()).toEqual({ version: 1, billingAccountId: f.billingAccountId,
      challengeSHA256: await sha256(linkTranscript(f.challenge)) });
    expect((await status(f.billingAccountId)).status).toBe(200);
    expect(await (await status(f.billingAccountId)).json()).toMatchObject({ status: 'unknown' });
  });

  it('binds proof to owner, account, canonical body, method, path, audience and live challenge', async () => {
    const f = await fixture(); const proof = await f.sign();
    for (const challenge of [{ ...f.challenge, ownerId: crypto.randomUUID() }, { ...f.challenge, billingAccountId: crypto.randomUUID() },
      { ...f.challenge, audience: 'other-audience' }, { ...f.challenge, issuedAt: 0, expiresAt: LINK_TTL_MS }]) {
      expect((await verify(challenge, proof)).status).toBe(401);
    }
    for (const overrides of [{ method: 'GET' }, { pathname: '/v1/billing/entitlement' }, { body: '{}'},
      { timestamp: Math.floor(Date.now() / 1000) - 301 }]) {
      expect((await verify(f.challenge, await f.sign(f.challenge, overrides))).status).toBe(401);
    }
    expect((await verify(f.challenge, { ...proof, signature: randomBase64url(64) })).status).toBe(401);
    expect((await verify(f.challenge, { ...proof, billingKeyId: randomBase64url(16) })).status).toBe(401);
    expect((await verify(f.challenge, proof)).status).toBe(200); // rejected mutations never consumed the legitimate nonce
  });

  it('rejects revocation before verification and on either side of nonce persistence', async () => {
    const revoked = await fixture(); const revokedProof = await revoked.sign(); await revoked.revoke();
    expect((await verify(revoked.challenge, revokedProof)).status).toBe(401);
    for (const moment of ['before', 'after']) {
      const f = await fixture(); const proof = await f.sign();
      const racing = new Proxy(db, { get(target, key) {
        if (key === 'batch') return async (statements: D1PreparedStatement[]) => {
          if (moment === 'before') await f.revoke();
          const result = await target.batch(statements);
          if (moment === 'after') await f.revoke();
          return result;
        };
        const value = Reflect.get(target, key, target); return typeof value === 'function' ? value.bind(target) : value;
      } });
      expect((await verify(f.challenge, proof, makeWorker({ DB: racing }))).status).toBe(401);
    }
  });

  it('maps only fresh verified active/grace authority to paid status, never provisional data', async () => {
    for (const [appleStatus, expected] of [[1, 'active'], [4, 'grace'], [2, 'expired'], [3, 'expired'], [5, 'expired']] as const) {
      const f = await fixture(); await entitlement(f.billingAccountId, appleStatus);
      expect(await (await status(f.billingAccountId)).json()).toMatchObject({ status: expected });
    }
    const f = await fixture(); await entitlement(f.billingAccountId, 1);
    const now = Date.now(); const clock = vi.spyOn(Date, 'now').mockReturnValue(now + 37 * 3_600_000);
    try { expect(await (await status(f.billingAccountId)).json()).toMatchObject({ status: 'unknown' }); }
    finally { clock.mockRestore(); }
  });

  it('respects both entitlement gates but never makes paid state a link prerequisite', async () => {
    const f = await fixture(); await entitlement(f.billingAccountId, 2);
    expect((await status(f.billingAccountId, makeWorker({ BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: 'NO' }))).status).toBe(503);
    await db.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,updated_at=unixepoch(),effective_entitlement_enabled=0
      WHERE singleton=1`).run();
    expect((await status(f.billingAccountId)).status).toBe(503);
    expect((await verify(f.challenge, await f.sign())).status).toBe(200);
  });

  it('bounds and validates private requests and sanitizes database failures without echoing credentials', async () => {
    const f = await fixture(); const proof = await f.sign();
    expect((await makeWorker().fetch(request('verify-link', { challenge: f.challenge, proof, extra: true }))).status).toBe(400);
    expect((await makeWorker().fetch(request('verify-link', { padding: 'x'.repeat(4096) }))).status).toBe(400);
    expect((await status('client-guessed-owner')).status).toBe(400);
    const failing = new Proxy(db, { get() { throw new Error(`synthetic-secret-${proof.signature}`); } });
    const result = await verify(f.challenge, proof, makeWorker({ DB: failing }));
    expect(result.status).toBe(503);
    expect(await result.json()).toEqual({ error: { code: 'billing_authority_unavailable' } });
  });

  it('links the durable owner through the real private adapter and keeps that link across expired membership and a new session', async () => {
    const wrapper = await syntheticKeyAuthority();
    const auth = new DurableAuth({ db, keys: envelopeKeyCustody({ enabled: true, wrapper: wrapper.make() }),
      identityIndexSecret: base64urlEncode(new Uint8Array(32).fill(9)), now: () => Date.now() });
    const identity = { issuer: 'https://synthetic.apple.invalid', subject: randomToken(), refreshToken: 'synthetic-only' };
    const session = await auth.establish(identity); const f = await fixture(); await entitlement(f.billingAccountId, 2);
    const worker = makeWorker();
    const binding = { fetch: (input: RequestInfo | URL, init?: RequestInit) => worker.fetch(new Request(input, init)) } as unknown as Fetcher;
    const links = new MembershipLinks({ db, auth, authority: boundBillingAuthority(binding), audience, now: () => Date.now() });
    const issued = await links.issue(session.token, f.billingAccountId);
    expect(await links.complete(session.token, issued.challenge.challengeId, await f.sign(issued.challenge))).toEqual({ linked: true });
    expect(await links.forSession(session.token)).toEqual({ linked: true, status: 'expired' });
    const next = await auth.establish(identity);
    expect(next.ownerId).toBe(session.ownerId);
    expect(await links.forSession(next.token)).toEqual({ linked: true, status: 'expired' });
    expect((await auth.requireSession(next.token)).ownerId).toBe(session.ownerId);
  });
});
