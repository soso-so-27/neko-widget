import { env } from 'cloudflare:workers';
import { applyD1Migrations, reset, type D1Migration } from 'cloudflare:test';
import { beforeEach, expect, it, vi } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken, type KeyCustody } from '../src/contracts';
import { OwnerRequestLimiter } from '../src/owner-request-limiter';
import { OwnerDeletionJournal } from '../src/owner-deletion-journal';
import { OwnerDeletionRequests } from '../src/owner-deletion';
import { ArchiveStore } from '../src/storage';
import { IntakeControl } from '../src/intake-control';
import { route, type Services } from '../src/index';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket; TEST_MIGRATIONS: D1Migration[] };
const db = binding.DB;
const keys: KeyCustody = {
  async seal(bytes) { return bytes.slice(); },
  async open(bytes) { return bytes.slice(); },
};
beforeEach(async () => { await reset(); await applyD1Migrations(db, binding.TEST_MIGRATIONS); });

async function fixture() {
  await binding.ARCHIVE.put('__owner_deletion/v1/format.json', '{"version":1}');
  const journal = new OwnerDeletionJournal(binding.ARCHIVE);
  const auth = new DurableAuth({ db, keys, identityIndexSecret: randomToken(), now: Date.now, ownerDeletion: journal });
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() };
  const first = await auth.establish(identity);
  const ownerRequestLimiter = new OwnerRequestLimiter(db);
  const ownerDeletion = new OwnerDeletionRequests({ db, journal, auth, now: Date.now });
  const archive = new ArchiveStore({ db, bucket: binding.ARCHIVE, keys, auth, now: Date.now,
    membership: { status: async () => 'active' }, photos: { validateJPEG: async () => true },
    quotaBytes: 100_000, maximumRecords: 100 });
  const services: Services = { auth, archive, ownerRequestLimiter, ownerDeletion,
    verifier: { verifyNativeAuthorization: async () => identity } };
  return { auth, identity, first, ownerRequestLimiter, journal, services };
}
const request = (token: string, path = '/v1/notice-contact', method = 'GET', input?: unknown) =>
  new Request(`https://preservation.test${path}`, { method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(input === undefined ? {} : { body: JSON.stringify(input) }) });
async function count(ownerId: string): Promise<number> {
  return (await db.prepare('SELECT http_request_count FROM pa_owners WHERE owner_id=?')
    .bind(ownerId).first<{ http_request_count: number }>())!.http_request_count;
}
async function exhaust(ownerId: string): Promise<void> {
  await db.prepare(`UPDATE pa_owners SET http_request_count=30,
    http_request_minute=CAST(unixepoch()/60 AS INTEGER) WHERE owner_id=?`).bind(ownerId).run();
}
async function nextWindow(ownerId: string): Promise<void> {
  // Model a counter from the preceding minute without injecting an edge clock.
  await db.prepare(`UPDATE pa_owners SET http_request_minute=CAST(unixepoch()/60 AS INTEGER)-1
    WHERE owner_id=?`).bind(ownerId).run();
}
async function awayFromBoundary(): Promise<void> {
  const seconds = await db.prepare('SELECT unixepoch() AS seconds').first<{ seconds: number }>();
  if (seconds!.seconds % 60 >= 57) await new Promise(resolve => setTimeout(resolve, (61 - seconds!.seconds % 60) * 1000));
}

it('shares exactly 30 admitted HTTP requests across simultaneous sessions of one owner', async () => {
  const f = await fixture(); const second = await f.auth.establish(f.identity);
  await awayFromBoundary();
  const outcomes = await Promise.allSettled(Array.from({ length: 31 }, (_, i) =>
    route(request(i % 2 ? f.first.token : second.token), f.services)));
  expect(outcomes.filter(item => item.status === 'fulfilled')).toHaveLength(30);
  expect(outcomes.filter(item => item.status === 'rejected')).toMatchObject([
    { reason: { code: 'RATE_LIMITED', status: 429 } },
  ]);
  expect(await count(f.first.ownerId)).toBe(30);
});

it('isolates authenticated owners and rejects a mismatched session or client owner header', async () => {
  const f = await fixture(); const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
  await awayFromBoundary(); await exhaust(f.first.ownerId);
  const forged = request(f.first.token); forged.headers.set('x-owner-id', other.ownerId);
  await expect(route(forged, f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  await expect(f.ownerRequestLimiter.admit({ ...await f.auth.requireSession(f.first.token), ownerId: other.ownerId }))
    .rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect(await count(other.ownerId)).toBe(0);
  expect((await route(request(other.token), f.services)).status).toBe(200);
  expect(await count(other.ownerId)).toBe(1); expect(await count(f.first.ownerId)).toBe(30);
});

it('starts a new fixed UTC minute and fails closed on a backward database window', async () => {
  const f = await fixture(); const session = await f.auth.requireSession(f.first.token);
  await awayFromBoundary(); await exhaust(f.first.ownerId);
  await expect(f.ownerRequestLimiter.admit(session)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  await nextWindow(f.first.ownerId); await f.ownerRequestLimiter.admit(session);
  expect(await count(f.first.ownerId)).toBe(1);
  expect(await db.prepare(`SELECT http_request_minute=CAST(unixepoch()/60 AS INTEGER) AS current
    FROM pa_owners WHERE owner_id=?`).bind(f.first.ownerId).first()).toEqual({ current: 1 });
  await db.prepare('UPDATE pa_owners SET http_request_minute=http_request_minute+1 WHERE owner_id=?').bind(f.first.ownerId).run();
  await expect(f.ownerRequestLimiter.admit(session)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect(await count(f.first.ownerId)).toBe(1);
});

it.each(['revoked', 'expired', 'epoch', 'disabled'] as const)(
  'rechecks a %s session atomically without consuming its owner quota', async kind => {
    const f = await fixture(); const session = await f.auth.requireSession(f.first.token);
    if (kind === 'revoked') await f.auth.revokeSession(f.first.token);
    if (kind === 'expired') await db.prepare('UPDATE pa_sessions SET expires_at=created_at+1 WHERE session_hash=?').bind(session.sessionHash).run();
    if (kind === 'epoch') await db.prepare('UPDATE pa_owners SET epoch=epoch+1 WHERE owner_id=?').bind(session.ownerId).run();
    if (kind === 'disabled') await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(session.ownerId).run();
    await expect(f.ownerRequestLimiter.admit(session)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
    expect(await count(session.ownerId)).toBe(0);
    await expect(route(request(f.first.token), f.services)).rejects.toMatchObject({ code: 'unauthorized', status: 401 });
    expect(await count(session.ownerId)).toBe(0);
  });

it('blocks a revocation between route authentication and admission before the handler', async () => {
  const f = await fixture(); const original = f.auth.requireSession.bind(f.auth);
  vi.spyOn(f.auth, 'requireSession').mockImplementationOnce(async token => {
    const session = await original(token); await f.auth.revokeSession(token); return session;
  });
  const downstream = vi.spyOn(f.auth, 'noticeContact');
  await expect(route(request(f.first.token), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect(downstream).not.toHaveBeenCalled(); expect(await count(f.first.ownerId)).toBe(0);
});

it('fails closed on limiter storage failure before any downstream handler', async () => {
  const f = await fixture();
  f.services.ownerRequestLimiter = new OwnerRequestLimiter({ prepare() { throw new Error('synthetic outage'); } } as unknown as D1Database);
  const downstream = vi.spyOn(f.auth, 'noticeContact');
  await expect(route(request(f.first.token), f.services)).rejects.toMatchObject({ code: 'OWNER_REQUEST_LIMIT_UNAVAILABLE', status: 503 });
  expect(downstream).not.toHaveBeenCalled(); expect(await count(f.first.ownerId)).toBe(0);
});

it.each([
  ['GET', '/v1/usage'], ['GET', '/v1/retention'], ['GET', '/v1/membership'],
  ['POST', '/v1/membership/challenges'], ['POST', '/v1/membership/link'],
  ['GET', '/v1/records'], ['GET', '/v1/records/00000000-0000-4000-8000-000000000001'],
  ['PUT', '/v1/records/00000000-0000-4000-8000-000000000001'],
  ['DELETE', '/v1/records/00000000-0000-4000-8000-000000000001'],
  ['DELETE', '/v1/auth/session'], ['POST', '/v1/account-deletion'],
])('stops exhausted %s %s before handler or body work', async (method, path) => {
  const f = await fixture(); await awayFromBoundary(); await exhaust(f.first.ownerId);
  await expect(route(request(f.first.token, path, method), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect(await count(f.first.ownerId)).toBe(30);
  expect(await f.auth.requireSession(f.first.token)).toMatchObject({ ownerId: f.first.ownerId });
  expect(await f.journal.request(f.first.ownerId)).toBeNull();
});

it('counts failed attempts and permits logout after rollover without resetting the other session quota', async () => {
  const f = await fixture(); const second = await f.auth.establish(f.identity);
  await expect(route(request(f.first.token, '/v1/account-deletion', 'POST', { ownerId: crypto.randomUUID() }), f.services))
    .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  expect(await count(f.first.ownerId)).toBe(1);
  await awayFromBoundary(); await exhaust(f.first.ownerId);
  await expect(route(request(f.first.token, '/v1/auth/session', 'DELETE'), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  await nextWindow(f.first.ownerId);
  expect((await route(request(f.first.token, '/v1/auth/session', 'DELETE'), f.services)).status).toBe(204);
  await expect(f.auth.requireSession(f.first.token)).rejects.toMatchObject({ code: 'unauthorized' });
  expect((await route(request(second.token), f.services)).status).toBe(200); expect(await count(f.first.ownerId)).toBe(2);
});

it('admits owner deletion after rollover and polls a receipt without requiring the invalidated login', async () => {
  const f = await fixture(); const receipt = randomToken();
  const deletion = () => request(f.first.token, '/v1/account-deletion', 'POST', { confirmation: 'delete-service-account', receipt });
  await awayFromBoundary(); await exhaust(f.first.ownerId);
  await expect(route(deletion(), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect(await f.journal.request(f.first.ownerId)).toBeNull();
  await nextWindow(f.first.ownerId); expect((await route(deletion(), f.services)).status).toBe(202);
  expect(await count(f.first.ownerId)).toBe(1);
  await expect(route(request(f.first.token), f.services)).rejects.toMatchObject({ code: 'OWNER_DELETION_PENDING' });
  const auth = vi.spyOn(f.auth, 'requireSession'); const limiter = vi.spyOn(f.ownerRequestLimiter, 'admit');
  const result = await route(request(receipt, `/v1/account-deletion/${f.first.ownerId}`), f.services);
  expect(result.status).toBe(200); expect(await result.json()).toEqual({ state: 'processing' });
  expect(auth).not.toHaveBeenCalled(); expect(limiter).not.toHaveBeenCalled();
  await expect(route(request(randomToken(), `/v1/account-deletion/${f.first.ownerId}`), f.services))
    .rejects.toMatchObject({ code: 'OWNER_DELETION_NOT_FOUND' });
});

it('excludes auth bootstrap but a freshly issued session still shares the exhausted owner', async () => {
  const f = await fixture(); await awayFromBoundary(); await exhaust(f.first.ownerId);
  expect((await route(request(f.first.token, '/v1/auth/challenges', 'POST', {}), f.services)).status).toBe(200);
  const established = await route(request(f.first.token, '/v1/auth/sessions', 'POST', {
    challengeId: 'synthetic', challengeProof: 'synthetic', identityToken: 'synthetic', authorizationCode: 'synthetic',
  }), f.services);
  const fresh = await established.json() as { token: string; ownerId: string };
  expect(fresh.ownerId).toBe(f.first.ownerId);
  await expect(route(request(fresh.token), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect(await count(f.first.ownerId)).toBe(30);
});

it('preserves expired-member read/export/delete after cost-review expiry until request exhaustion', async () => {
  const f = await fixture(); const recordId = crypto.randomUUID();
  const options = { db, bucket: binding.ARCHIVE, keys, auth: f.auth, now: Date.now,
    membership: { status: async (): Promise<'active'> => 'active' },
    photos: { validateJPEG: async () => true }, quotaBytes: 100_000, maximumRecords: 100 };
  const archive = new ArchiveStore(options);
  const document = { formatVersion: 1, text: 'synthetic retained memory', capturedAt: '2026-01-01T00:00:00.000Z',
    writtenAt: null, updatedAt: null, catNames: [], photoFile: null };
  await archive.put(f.first.token, recordId, { expectedRevision: null, consentVersion: 'managed-preservation-v1', document, photoBase64: null });
  f.services.archive = new ArchiveStore({ ...options, membership: { status: async () => 'expired' },
    intakeControl: new IntakeControl(db, Date.now, { requireCostEvidence: true }), requireIntakeControl: true });
  expect(await db.prepare('SELECT enabled,valid_until FROM pa_intake_control WHERE singleton=1').first()).toEqual({ enabled: 0, valid_until: 0 });
  expect((await route(request(f.first.token, '/v1/records'), f.services)).status).toBe(200);
  expect(await (await route(request(f.first.token, `/v1/records/${recordId}`), f.services)).json()).toMatchObject({ recordId, document });
  const removal = request(f.first.token, `/v1/records/${recordId}`, 'DELETE'); removal.headers.set('if-match', '1');
  expect((await route(removal, f.services)).status).toBe(200);
  await awayFromBoundary(); await exhaust(f.first.ownerId);
  await expect(route(request(f.first.token, '/v1/records'), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
});

it('requires migration, upgrades existing owners with bounded defaults, and leaves recovery generation unchanged', async () => {
  await reset(); await applyD1Migrations(db, binding.TEST_MIGRATIONS.filter(m => !m.name.startsWith('0032_')));
  const f = await fixture(); const session = await f.auth.requireSession(f.first.token);
  await expect(f.ownerRequestLimiter.admit(session)).rejects.toMatchObject({ code: 'OWNER_REQUEST_LIMIT_UNAVAILABLE' });
  await applyD1Migrations(db, binding.TEST_MIGRATIONS); expect(await count(session.ownerId)).toBe(0);
  const generation = () => db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?').bind(session.ownerId).first();
  const before = await generation(); await f.ownerRequestLimiter.admit(session); expect(await generation()).toEqual(before);
  for (const invalid of [-1, 31, 1.5]) await expect(db.prepare('UPDATE pa_owners SET http_request_count=? WHERE owner_id=?')
    .bind(invalid, session.ownerId).run()).rejects.toThrow();
  expect(await count(session.ownerId)).toBe(1);
  expect(await db.prepare('PRAGMA foreign_key_check').all()).toMatchObject({ results: [] });
});

it('reproduces the unresolved bulk-export failure: two pages plus 28 details exhaust one minute', async () => {
  const f = await fixture();
  const document = { formatVersion: 1, text: 'synthetic export record', capturedAt: '2026-01-01T00:00:00.000Z',
    writtenAt: null, updatedAt: null, catNames: [], photoFile: null };
  // Fixture writes are not HTTP traffic. Mirror the native client's real
  // 20-item pagination, then sequential detail reads, without an automatic retry.
  for (let i = 0; i < 30; i++) await f.services.archive.put(f.first.token, crypto.randomUUID(), {
    expectedRevision: null, consentVersion: 'managed-preservation-v1', document, photoBase64: null,
  });
  await awayFromBoundary();
  const records: string[] = []; let cursor: string | null = null;
  do {
    const result = await route(request(f.first.token, `/v1/records?limit=20${cursor ? `&after=${cursor}` : ''}`), f.services);
    const page = await result.json() as { items: { recordId: string }[]; nextCursor: string | null };
    records.push(...page.items.map(item => item.recordId)); cursor = page.nextCursor;
  } while (cursor);
  expect(records).toHaveLength(30);
  for (const recordId of records.slice(0, 28)) {
    expect((await route(request(f.first.token, `/v1/records/${recordId}`), f.services)).status).toBe(200);
  }
  await expect(route(request(f.first.token, `/v1/records/${records[28]}`), f.services))
    .rejects.toMatchObject({ code: 'RATE_LIMITED', status: 429 });
  expect(await count(f.first.ownerId)).toBe(30);
});
