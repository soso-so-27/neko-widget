import { env } from 'cloudflare:workers';
import { describe, expect, it, vi } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken, sha256, type KeyCustody } from '../src/contracts';
import { MembershipLinks } from '../src/membership-links';
import { type BillingLinkAuthority, type BillingProof, type MembershipStatus } from '../src/billing-link-protocol';
import { boundBillingAuthority } from '../src/providers';
import { ArchiveStore } from '../src/storage';
import { route } from '../src/index';
const { DB: db, ARCHIVE: bucket } = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const proof: BillingProof = { billingKeyId: 'a'.repeat(22), nonce: 'b'.repeat(22), signature: 'c'.repeat(86), timestamp: '1800000000' };
async function fixture() {
  let now = Date.UTC(2026, 8, 22); let membership: MembershipStatus = 'active';
  // Tests of identity fencing, not cryptography (the existing custody suite covers it).
  const keys: KeyCustody = { seal: async bytes => bytes.slice(), open: async bytes => bytes.slice() };
  const auth = new DurableAuth({ db, keys, identityIndexSecret: randomToken(), now: () => now });
  const identity = { issuer: 'https://appleid.apple.com', subject: randomToken(), refreshToken: 'synthetic-only' };
  const user = await auth.establish(identity); const account = crypto.randomUUID();
  const authority: BillingLinkAuthority = { verify: vi.fn(async () => {}), status: vi.fn(async () => membership) };
  const links = new MembershipLinks({ db, auth, authority, audience: 'local-preservation-v1', now: () => now });
  const services = { auth, membership: links, verifier: { verifyNativeAuthorization: async () => identity },
    archive: new ArchiveStore({ db, bucket, keys, auth, now: () => now, membership: links,
      quotaBytes: 1_000_000, maximumRecords: 100, photos: { validateJPEG: async () => true } }) };
  const request = async (path: string, method: string, body?: unknown, token = user.token) => route(new Request(`https://local.invalid${path}`, {
    method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), services);
  const link = async (token = user.token, billing = account) => {
    const c = await links.issue(token, billing);
    return links.complete(token, c.challenge.challengeId, proof);
  };
  return { auth, user, account, authority, links, request, link, services, identity,
    advance: (ms: number) => { now += ms; }, status: (value: MembershipStatus) => { membership = value; } };
}
describe('two-proof preservation membership link', () => {
  it('does not grant from an account ID; routes bind owner/session and hide billing ID in status', async () => {
    const f = await fixture();
    expect(await f.links.status(f.user.ownerId)).toBe('unknown');
    const reply = await f.request('/v1/membership/challenges', 'POST', { billingAccountId: f.account });
    const challenge = await reply.json() as { challenge: { challengeId: string; ownerId: string }; signingBody: string };
    expect(challenge.challenge.ownerId).toBe(f.user.ownerId);
    expect(JSON.parse(challenge.signingBody)).toEqual(challenge.challenge);
    expect(await f.links.status(f.user.ownerId)).toBe('unknown');
    expect(await (await f.request('/v1/membership/link', 'POST', { challengeId: challenge.challenge.challengeId, proof })).json())
      .toEqual({ linked: true });
    expect(await (await f.request('/v1/membership', 'GET')).json()).toEqual({ linked: true, status: 'active' });
    expect(f.authority.verify).toHaveBeenCalledOnce();
    await expect(f.request('/v1/membership/challenges', 'POST', { billingAccountId: f.account, ownerId: f.user.ownerId }))
      .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
    await expect(f.request('/v1/membership?ownerId=other', 'GET')).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  });
  it('rejects another session and a replay without consuming the rightful session challenge', async () => {
    const f = await fixture(); const c = await f.links.issue(f.user.token, f.account);
    const sameOwnerOtherSession = await f.auth.establish(f.identity);
    await expect(f.links.complete(sameOwnerOtherSession.token, c.challenge.challengeId, proof)).rejects.toMatchObject({ code: 'LINK_CHALLENGE_INVALID' });
    const outcomes = await Promise.allSettled([f.links.complete(f.user.token, c.challenge.challengeId, proof), f.links.complete(f.user.token, c.challenge.challengeId, proof)]);
    expect(outcomes.filter(x => x.status === 'fulfilled')).toHaveLength(1);
    expect(f.authority.verify).toHaveBeenCalledOnce();
  });
  it('rejects expired or superseded challenges', async () => {
    const f = await fixture(); const old = await f.links.issue(f.user.token, f.account);
    const latest = await f.links.issue(f.user.token, f.account);
    await expect(f.links.complete(f.user.token, old.challenge.challengeId, proof)).rejects.toMatchObject({ code: 'LINK_CHALLENGE_INVALID' });
    f.advance(300_000);
    await expect(f.links.complete(f.user.token, latest.challenge.challengeId, proof)).rejects.toMatchObject({ code: 'LINK_CHALLENGE_INVALID' });
    expect(f.authority.verify).not.toHaveBeenCalled();
  });
  it('burns a failed proof and requires a fresh challenge', async () => {
    const f = await fixture(); const c = await f.links.issue(f.user.token, f.account);
    vi.mocked(f.authority.verify).mockRejectedValueOnce(new Error('unavailable'));
    await expect(f.links.complete(f.user.token, c.challenge.challengeId, proof)).rejects.toThrow();
    await expect(f.links.complete(f.user.token, c.challenge.challengeId, proof)).rejects.toMatchObject({ code: 'LINK_CHALLENGE_INVALID' });
    expect(await f.links.status(f.user.ownerId)).toBe('unknown');
    expect(await f.link()).toEqual({ linked: true });
  });
  it.each(['session', 'owner', 'deadline'] as const)('fences %s changes while billing verification awaits', async reason => {
    const f = await fixture(); const c = await f.links.issue(f.user.token, f.account);
    vi.mocked(f.authority.verify).mockImplementationOnce(async () => {
      if (reason === 'session') await f.auth.revokeSession(f.user.token);
      if (reason === 'owner') await f.auth.revokeOwner(f.user.ownerId);
      if (reason === 'deadline') f.advance(300_000);
    });
    await expect(f.links.complete(f.user.token, c.challenge.challengeId, proof)).rejects.toThrow();
    expect(await db.prepare('SELECT * FROM pa_membership_links WHERE owner_id=?').bind(f.user.ownerId).first()).toBeNull();
  });
  it('enforces one account per owner and one owner per account, also during concurrent links', async () => {
    const f = await fixture();
    const other = await f.auth.establish({ ...f.identity, subject: randomToken() });
    const a = await f.links.issue(f.user.token, f.account); const b = await f.links.issue(other.token, f.account);
    const results = await Promise.allSettled([f.links.complete(f.user.token, a.challenge.challengeId, proof),
      f.links.complete(other.token, b.challenge.challengeId, proof)]);
    expect(results.filter(r => r.status === 'fulfilled')).toHaveLength(1);
    const winner = results[0]?.status === 'fulfilled' ? f.user : other;
    await expect(f.link(winner.token, crypto.randomUUID())).rejects.toMatchObject({ code: 'MEMBERSHIP_LINK_CONFLICT' });
    expect(await f.link(winner.token)).toEqual({ linked: true });
    await expect(db.prepare('UPDATE pa_membership_links SET billing_account_id=? WHERE owner_id=?')
      .bind(crypto.randomUUID(), winner.ownerId).run()).rejects.toThrow();
    await expect(db.prepare('DELETE FROM pa_membership_links WHERE owner_id=?').bind(winner.ownerId).run()).rejects.toThrow();
  });
  it('allows expired owners to link and read existing photos after re-login, but not create new ones', async () => {
    const f = await fixture(); const id = crypto.randomUUID();
    const document = { formatVersion: 1, text: 'この日に残した記録', capturedAt: null, writtenAt: null, updatedAt: null,
      catNames: [], photoFile: 'photo.jpg' };
    await f.link();
    await f.services.archive.put(f.user.token, id, { expectedRevision: null, consentVersion: 'managed-preservation-v1', document,
      photoBase64: btoa('synthetic-photo') });
    f.status('expired'); await f.auth.revokeSession(f.user.token);
    const again = await f.auth.establish(f.identity);
    expect(await f.link(again.token)).toEqual({ linked: true });
    const result = await f.services.archive.read(again.token, id);
    expect(result.document.text).toBe(document.text);
    expect(result.photoSHA256).toBe(await sha256('synthetic-photo'));
    await expect(f.services.archive.put(again.token, crypto.randomUUID(), { expectedRevision: null,
      consentVersion: 'managed-preservation-v1', document, photoBase64: btoa('synthetic-photo') }))
      .rejects.toMatchObject({ status: 403 });
    // A billing outage cannot revoke access to already retained data.
    vi.mocked(f.authority.status).mockRejectedValueOnce(new Error('authority unavailable'));
    expect((await f.services.archive.read(again.token, id)).document.text).toBe(document.text);
  });
  it('rejects provider responses for the wrong challenge/account and malformed grant', async () => {
    const f = await fixture(); const c = (await f.links.issue(f.user.token, f.account)).challenge;
    const binding = (value: unknown) => ({ fetch: async () => Response.json(value) }) as unknown as Fetcher;
    await expect(boundBillingAuthority(binding({ version: 1, billingAccountId: f.account, challengeSHA256: '0'.repeat(64) }))
      .verify(c, proof)).rejects.toMatchObject({ code: 'BILLING_PROOF_UNCONFIRMED' });
    await expect(boundBillingAuthority(binding({ version: 1, billingAccountId: crypto.randomUUID(), status: 'active' }))
      .status(f.account)).rejects.toMatchObject({ code: 'MEMBERSHIP_UNCONFIRMED' });
    await expect(boundBillingAuthority(binding({ version: 1, billingAccountId: f.account, status: 'active', ownerId: f.user.ownerId }))
      .status(f.account)).rejects.toMatchObject({ code: 'MEMBERSHIP_UNCONFIRMED' });
  });
  it('does not follow a private provider redirect', async () => {
    let calls = 0;
    const authority = boundBillingAuthority({ fetch: async (_url: unknown, init: RequestInit) => {
      calls++; expect(init.redirect).toBe('manual');
      return new Response(null, { status: 302, headers: { location: 'https://untrusted.invalid' } });
    } } as unknown as Fetcher);
    await expect(authority.status(crypto.randomUUID())).rejects.toMatchObject({ code: 'DEPENDENCY_UNAVAILABLE' });
    expect(calls).toBe(1);
  });
});
