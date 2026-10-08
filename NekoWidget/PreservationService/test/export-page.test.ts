import { env } from 'cloudflare:workers';
import { applyD1Migrations, reset, type D1Migration } from 'cloudflare:test';
import { beforeEach, expect, it, vi } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore } from '../src/storage';
import { randomToken, sha256 } from '../src/contracts';
import { OwnerDeletionJournal } from '../src/owner-deletion-journal';
import { OwnerRequestLimiter } from '../src/owner-request-limiter';
import { route, type Services } from '../src/index';
import type { RecordRecoveryCopy } from '../src/record-recovery-copy';
import { exportPage } from '../src/export-page';
import { envelopeKeyCustody } from '../src/key-custody';
import { syntheticKeyAuthority } from './key-fixture';

const bindings = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket; TEST_MIGRATIONS: D1Migration[] };
const db = bindings.DB;
beforeEach(async () => { await reset(); await applyD1Migrations(db, bindings.TEST_MIGRATIONS); });

async function fixture(count = 1, missingMarkers = false) {
  await bindings.ARCHIVE.put('__owner_deletion/v1/format.json', '{"version":1}');
  const journal = new OwnerDeletionJournal(bindings.ARCHIVE);
  let queries = 0;
  let beforeQuery: ((sql: string) => void) | undefined;
  const observed = new Proxy(db, { get(target, property) {
    if (property === 'prepare') return (sql: string) => { queries++; beforeQuery?.(sql); return target.prepare(sql); };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const keys = { async seal(value: Uint8Array) { return value.slice(); }, async open(value: Uint8Array) { return value.slice(); } };
  const auth = new DurableAuth({ db: observed, keys, identityIndexSecret: randomToken(), now: Date.now, ownerDeletion: journal });
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() };
  const session = await auth.establish(identity);
  const recovery = {
    async commit(ownerId: string, id: string) { return { key: `recovery/v1/${ownerId}/marker/${id}`,
      versionId: 'synthetic-marker', sha256: 'a'.repeat(64), bytes: 1 }; },
    async readCommitted() { return { revision: 1 }; },
  } as unknown as RecordRecoveryCopy;
  const archive = new ArchiveStore({ db: observed, bucket: bindings.ARCHIVE, keys, auth,
    now: Date.now, quotaBytes: 5 * 1024 ** 3, maximumRecords: 1000, requireRecovery: true, recovery,
    membership: { status: async () => 'expired' }, photos: { validateJPEG: async () => true } });
  const services: Services = { auth, archive, ownerRequestLimiter: new OwnerRequestLimiter(observed),
    verifier: { verifyNativeAuthorization: async () => identity } };
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(session.ownerId).run();
  const document = JSON.stringify({ formatVersion: 1, text: 'synthetic export', capturedAt: null,
    writtenAt: null, updatedAt: null, catNames: [], photoFile: null });
  if (count) {
    await db.prepare(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?),
      ids AS (SELECT printf('%08x-0000-4000-8000-%012x',x,x) AS id FROM n),
      payload AS (SELECT id,CAST(json_object('version',1,'ownerId',?,'recordId',id,'revision',1,
        'document',json(?),'photoSHA256',NULL,'photoBytes',0) AS BLOB) AS data FROM ids)
      INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,metadata,quota_bytes)
      SELECT ?,id,1,?,id,data,length(data) FROM payload`)
      .bind(count, session.ownerId, document, session.ownerId, 'a'.repeat(64)).run();
    await db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,record_object_key,
      record_version_id,record_sha256,record_bytes,committed_at)
      SELECT owner_id,record_id,revision,'recovery/v1/'||owner_id||'/record/'||record_id,'synthetic',?,1,1
      FROM pa_records WHERE owner_id=?`).bind('a'.repeat(64), session.ownerId).run();
    if (!missingMarkers) await db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,
      marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
      SELECT owner_id,record_id,revision,'recovery/v1/'||owner_id||'/marker/'||record_id,'synthetic',?,1,1
      FROM pa_records WHERE owner_id=?`).bind('a'.repeat(64), session.ownerId).run();
  }
  const make = (query = '', token = session.token, signal?: AbortSignal) => new Request(`https://preservation.test/v1/export-page${query}`, {
    headers: { authorization: `Bearer ${token}` }, ...(signal ? { signal } : {}) });
  return { auth, session, identity, archive, services, journal, make, observed,
    queries: () => queries, resetQueries: () => { queries = 0; },
    setBeforeQuery: (action?: (sql: string) => void) => { beforeQuery = action; } };
}
async function frames(response: Response): Promise<Record<string, unknown>[]> {
  const reader = response.body!.getReader(); const result: Record<string, unknown>[] = [];
  try { while (true) { const next = await reader.read(); if (next.done) break;
    result.push(JSON.parse(new TextDecoder().decode(next.value)) as Record<string, unknown>); } }
  finally { reader.releaseLock(); }
  return result;
}
async function lease(ownerId: string) {
  return db.prepare('SELECT export_lease_id,export_lease_expires_at FROM pa_owners WHERE owner_id=?').bind(ownerId)
    .first<{ export_lease_id: string | null; export_lease_expires_at: number }>();
}
it('probes workerd zero-buffer pull and cancellation before the next record read', async () => {
  let pulls = 0, cancelled = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) { pulls++; controller.enqueue(new TextEncoder().encode('record\n')); },
    cancel() { cancelled++; },
  }, { highWaterMark: 0 });
  const response = new Response(stream);
  await new Promise(resolve => setTimeout(resolve, 5)); expect(pulls).toBe(0);
  const reader = response.body!.getReader(); await reader.read();
  await new Promise(resolve => setTimeout(resolve, 5)); expect(pulls).toBe(1);
  await reader.cancel(); expect(cancelled).toBe(1); expect(pulls).toBe(1);
});

it('probes the SQL budget for fifty actual archive reads before implementing export paging', async () => {
  const keys = { async seal(value: Uint8Array) { return value.slice(); }, async open(value: Uint8Array) { return value.slice(); } };
  let queries = 0;
  const observed = new Proxy(db, { get(target, property) {
    if (property === 'prepare') return (sql: string) => { queries++; return target.prepare(sql); };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const auth = new DurableAuth({ db: observed, keys, identityIndexSecret: randomToken(), now: Date.now });
  const session = await auth.establish({ issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() });
  const archive = new ArchiveStore({ db: observed, bucket: (env as unknown as { ARCHIVE: R2Bucket }).ARCHIVE, keys, auth,
    now: Date.now, quotaBytes: 1_000_000, maximumRecords: 100,
    membership: { status: async () => 'active' }, photos: { validateJPEG: async () => true } });
  const id = crypto.randomUUID();
  await archive.put(session.token, id, { expectedRevision: null, consentVersion: 'managed-preservation-v1', photoBase64: null,
    document: { formatVersion: 1, text: 'synthetic SQL probe', capturedAt: null, writtenAt: null, updatedAt: null, catNames: [], photoFile: null } });
  queries = 0;
  for (let i = 0; i < 50; i++) await archive.read(session.token, id);
  expect(queries).toBe(200);
});

it('streams an actual 20 MiB encrypted photo with Japanese metadata through archive read and UTF8 in local workerd', async () => {
  const f = await fixture(0);
  const keys = envelopeKeyCustody({ enabled: true, wrapper: (await syntheticKeyAuthority()).bridge() });
  const id = crypto.randomUUID(), photoBytes = 20 * 1024 * 1024;
  const text = '日本語の思い出。ねこが窓辺で眠っている。';
  // Synthetic bytes exercise the real envelope/R2/read/hash/base64 path. JPEG
  // validation is intake work, not an export operation; no user photo is used.
  const expectedHash = await (async () => {
    const photo = new Uint8Array(photoBytes).fill(0x5a), photoSHA256 = await sha256(photo);
    const encrypted = await keys.seal(photo, { ownerId: f.session.ownerId, purpose: 'record', recordId: `${id}/photo` });
    const key = `synthetic-export/${f.session.ownerId}/${id}`;
    await bindings.ARCHIVE.put(key, encrypted);
    const metadata = await keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1, ownerId: f.session.ownerId,
      recordId: id, revision: 1, document: { formatVersion: 1, text, capturedAt: null,
        writtenAt: null, updatedAt: null, catNames: [], photoFile: 'photo.jpg' }, photoSHA256, photoBytes })),
    { ownerId: f.session.ownerId, purpose: 'record', recordId: `${id}/document` });
    await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,
      metadata,photo_key,photo_bytes,quota_bytes) VALUES(?,?,1,?,?,?,?,?,?)`)
      .bind(f.session.ownerId, id, 'a'.repeat(64), id, metadata, key, photoBytes, metadata.length + encrypted.length).run();
    return photoSHA256;
  })();
  f.services.archive = new ArchiveStore({ db, bucket: bindings.ARCHIVE, keys, auth: f.auth, now: Date.now,
    quotaBytes: 5 * 1024 ** 3, maximumRecords: 1000, membership: { status: async () => 'expired' },
    photos: { validateJPEG: async () => { throw new Error('export must not call intake validator'); } } });
  const reader = (await route(f.make(), f.services)).body!.getReader();
  expect(JSON.parse(new TextDecoder().decode((await reader.read()).value!))).toMatchObject({ type: 'header', totalRecords: 1 });
  await (async () => {
    const next = await reader.read(); expect(next.done).toBe(false);
    expect(next.value!.byteLength).toBeLessThanOrEqual(29 * 1024 * 1024);
    const record = JSON.parse(new TextDecoder().decode(next.value!));
    expect(record).toMatchObject({ type: 'record', recordId: id, document: { text }, photoSHA256: expectedHash });
    expect(record.photoBase64.length).toBe(Math.ceil(photoBytes / 3) * 4);
    // Fixed synthetic pattern checks encoding without duplicating a 20 MiB decoded buffer in the test isolate.
    expect(record.photoBase64.slice(0, 12)).toBe('WlpaWlpaWlpa'); expect(record.photoBase64.endsWith('Wlo=')).toBe(true);
    // A successful local workerd run is not a measurement of production's
    // per-isolate memory peak or proof that its 128 MiB limit is reproduced.
  })();
  expect(JSON.parse(new TextDecoder().decode((await reader.read()).value!)))
    .toMatchObject({ type: 'complete', recordCount: 1, nextCursor: null });
  expect((await reader.read()).done).toBe(true);
  expect(await lease(f.session.ownerId)).toEqual({ export_lease_id: null, export_lease_expires_at: 0 });
}, 20_000);

it('exports 1000 small records in 20 pages below owner quota and 1000 SQL statements per request', async () => {
  const f = await fixture(1000); let cursor: string | null = null, generation: number | undefined;
  const identifiers: string[] = [], counts: number[] = [];
  for (let page = 0; page < 20; page++) {
    f.resetQueries();
    const response = await route(f.make(cursor ? `?after=${cursor}&generation=${generation}` : ''), f.services);
    expect(response.headers.get('content-type')).toBe('application/x-ndjson');
    const output = await frames(response); counts.push(f.queries());
    expect(output[0]).toMatchObject({ version: 1, type: 'header', totalRecords: 1000 });
    generation ??= output[0]!.generation as number;
    expect(output[0]!.generation).toBe(generation);
    const records = output.slice(1, -1); expect(records).toHaveLength(50);
    expect(records.every(value => value.type === 'record')).toBe(true);
    identifiers.push(...records.map(value => value.recordId as string));
    const complete = output.at(-1)!;
    expect(complete).toMatchObject({ type: 'complete', generation, recordCount: 50 });
    cursor = complete.nextCursor as string | null;
    expect(cursor === null).toBe(page === 19);
    expect(await lease(f.session.ownerId)).toEqual({ export_lease_id: null, export_lease_expires_at: 0 });
  }
  expect(new Set(identifiers).size).toBe(1000); expect(identifiers).toEqual([...identifiers].sort());
  expect(counts).toEqual([463, ...Array<number>(19).fill(464)]);
  expect(await db.prepare('SELECT http_request_count FROM pa_owners WHERE owner_id=?').bind(f.session.ownerId).first())
    .toMatchObject({ http_request_count: expect.any(Number) });
  expect(Math.max(...counts)).toBeLessThan(1000);
}, 120_000);

it('keeps the missing-marker repair path below 1000 SQL statements for 50 records', async () => {
  const f = await fixture(50, true); f.resetQueries();
  const output = await frames(await route(f.make(), f.services));
  expect(output.at(-1)).toMatchObject({ type: 'complete', recordCount: 50, nextCursor: null });
  expect(f.queries()).toBe(613);
}, 20_000);

it('does not decrypt ahead of demand and releases the lease on consumer cancellation', async () => {
  const f = await fixture(2); const reads = vi.spyOn(f.archive, 'read');
  const pending: Promise<unknown>[] = [];
  const response = await route(f.make(), f.services, { waitUntil: promise => { pending.push(promise); } });
  expect(reads).not.toHaveBeenCalled();
  const reader = response.body!.getReader(); await reader.read();
  expect(reads).not.toHaveBeenCalled();
  await reader.read(); expect(reads).toHaveBeenCalledTimes(1);
  await new Promise(resolve => setTimeout(resolve, 5)); expect(reads).toHaveBeenCalledTimes(1);
  await reader.cancel(); expect(reads).toHaveBeenCalledTimes(1);
  expect(pending).toHaveLength(1); await Promise.all(pending);
  expect(await lease(f.session.ownerId)).toEqual({ export_lease_id: null, export_lease_expires_at: 0 });
});

it('permits one page per owner across sessions, isolates another owner, and releases only its own lease', async () => {
  const f = await fixture(); const otherSession = await f.auth.establish(f.identity);
  const results = await Promise.allSettled([route(f.make(), f.services), route(f.make('', otherSession.token), f.services)]);
  expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1);
  expect(results.filter(result => result.status === 'rejected')).toMatchObject([{ reason: { code: 'EXPORT_PAGE_BUSY' } }]);
  const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
  expect((await frames(await route(f.make('', other.token), f.services))).at(-1))
    .toMatchObject({ type: 'complete', recordCount: 0, nextCursor: null });
  await expect(route(f.make('?after=00000001-0000-4000-8000-000000000001&generation=0', other.token), f.services))
    .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  const replacement = crypto.randomUUID();
  await db.prepare('UPDATE pa_owners SET export_lease_id=? WHERE owner_id=?').bind(replacement, f.session.ownerId).run();
  const winner = results.find(result => result.status === 'fulfilled') as PromiseFulfilledResult<Response>;
  await winner.value.body!.cancel(); expect((await lease(f.session.ownerId))!.export_lease_id).toBe(replacement);
});

it.each(['?after=invalid', '?after=00000000-0000-4000-8000-000000000001', '?generation=-1',
  '?generation=9007199254740992', '?generation=01', '?generation=1&generation=1', '?limit=50'])(
  'rejects invalid continuation parameters %s before retaining a lease', async query => {
    const f = await fixture(); await expect(route(f.make(query), f.services)).rejects.toThrow();
    expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
  });

it('rejects changed generations and cross-owner/nonexistent cursors without output', async () => {
  const f = await fixture(2);
  await expect(route(f.make('?generation=999'), f.services)).rejects.toMatchObject({ code: 'ARCHIVE_CHANGED' });
  await expect(route(f.make('?after=ffffffff-0000-4000-8000-000000000001&generation=2'), f.services))
    .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
});

it.each(['generation', 'session', 'owner', 'lease-expiry', 'abort'] as const)(
  'emits no record or complete after %s changes during an actual read', async kind => {
    const f = await fixture(2); const abort = new AbortController();
    const original = f.archive.read.bind(f.archive);
    vi.spyOn(f.archive, 'read').mockImplementationOnce(async (token, id) => {
      const result = await original(token, id);
      if (kind === 'generation') await db.prepare('UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=?').bind(f.session.ownerId).run();
      if (kind === 'session') await f.auth.revokeSession(token);
      if (kind === 'owner') await db.prepare('UPDATE pa_owners SET disabled=1,epoch=epoch+1 WHERE owner_id=?').bind(f.session.ownerId).run();
      if (kind === 'lease-expiry') await db.prepare('UPDATE pa_owners SET export_lease_expires_at=1 WHERE owner_id=?').bind(f.session.ownerId).run();
      if (kind === 'abort') abort.abort();
      return result;
    });
    const reader = (await route(f.make('', f.session.token, abort.signal), f.services)).body!.getReader();
    expect(JSON.parse(new TextDecoder().decode((await reader.read()).value)).type).toBe('header');
    await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
    await new Promise(resolve => setTimeout(resolve, 5));
    expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
  });

it('checks the final generation even after the last record was delivered', async () => {
  const f = await fixture(); const reader = (await route(f.make(), f.services)).body!.getReader();
  await reader.read(); await reader.read();
  await db.prepare('UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=?').bind(f.session.ownerId).run();
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
});

it('fails closed on database failure during streaming and does not claim completion', async () => {
  const f = await fixture(); const reader = (await route(f.make(), f.services)).body!.getReader();
  await reader.read();
  f.setBeforeQuery(sql => { if (sql.includes('SELECT 1 AS allowed')) throw new Error('synthetic DB outage'); });
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
  await new Promise(resolve => setTimeout(resolve, 5));
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
});

it('uses a fixed lease within the original session deadline and rejects an expired session mid-page', async () => {
  const f = await fixture(); const current = await f.auth.requireSession(f.session.token);
  const reader = (await route(f.make(), f.services)).body!.getReader();
  expect((await lease(f.session.ownerId))!.export_lease_expires_at).toBe(current.expiresAt);
  await reader.read();
  await db.prepare('UPDATE pa_sessions SET expires_at=created_at+1 WHERE session_hash=?').bind(current.sessionHash).run();
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
});

it('splits at the exact 64MiB quota boundary and fails closed on invalid accounting', async () => {
  const f = await fixture(5);
  const ids = (await db.prepare('SELECT record_id FROM pa_records WHERE owner_id=? ORDER BY record_id').bind(f.session.ownerId)
    .all<{ record_id: string }>()).results.map(row => row.record_id);
  for (const [index, bytes] of [20, 20, 20, 4, 1].entries()) {
    await db.prepare('UPDATE pa_records SET quota_bytes=? WHERE owner_id=? AND record_id=?')
      .bind(bytes * 1024 * 1024, f.session.ownerId, ids[index]).run();
  }
  const output = await frames(await route(f.make(), f.services));
  expect(output.at(-1)).toMatchObject({ recordCount: 4, nextCursor: ids[3] });
  const next = await frames(await route(f.make(`?after=${ids[3]}&generation=${output[0]!.generation}`), f.services));
  expect(next.at(-1)).toMatchObject({ recordCount: 1, nextCursor: null });
  await db.prepare('UPDATE pa_records SET quota_bytes=-1 WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, ids[0]).run();
  await expect(route(f.make(), f.services)).rejects.toMatchObject({ code: 'EXPORT_UNAVAILABLE' });
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
});

it('checks schema defaults, owner snapshot generation, and atomic final-release conditions', async () => {
  const f = await fixture();
  const generation = () => db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?')
    .bind(f.session.ownerId).first();
  const before = await generation();
  const reader = (await route(f.make(), f.services)).body!.getReader(); await reader.read(); await reader.read();
  expect(await generation()).toEqual(before);
  f.setBeforeQuery(sql => {
    if (sql.includes('UPDATE pa_owners SET export_lease_id=NULL') && sql.includes('AND disabled=0')) {
      // Return an error exactly at final release: even all delivered records
      // must not be advertised complete when the final transaction is uncertain.
      throw new Error('synthetic final-commit outage');
    }
  });
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
  await new Promise(resolve => setTimeout(resolve, 5));
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
  expect(await generation()).toEqual(before);
  expect(await db.prepare('PRAGMA foreign_key_check').all()).toMatchObject({ results: [] });
});

it('bounds declared total and refuses a non-empty owner without generation accounting', async () => {
  const f = await fixture(1001);
  await expect(route(f.make(), f.services)).rejects.toMatchObject({ code: 'EXPORT_UNAVAILABLE' });
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
  await db.prepare(`UPDATE pa_records SET deleted=1,metadata=NULL,quota_bytes=0
    WHERE owner_id=? AND record_id='00000001-0000-4000-8000-000000000001'`).bind(f.session.ownerId).run();
  await db.prepare('DELETE FROM pa_inventory WHERE owner_id=?').bind(f.session.ownerId).run();
  await expect(route(f.make(), f.services)).rejects.toMatchObject({ code: 'EXPORT_UNAVAILABLE' });
});

it('rejects a frame over 29MiB without sending that record or a complete frame', async () => {
  const f = await fixture(); const original = f.archive.read.bind(f.archive);
  vi.spyOn(f.archive, 'read').mockImplementationOnce(async (token, id) => ({ ...await original(token, id),
    photoBase64: 'A'.repeat(29 * 1024 * 1024) }));
  const reader = (await route(f.make(), f.services)).body!.getReader(); await reader.read();
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
});

it.each(['"}\n{"type":"complete"}', '写真'])(
  'refuses non-base64 photo content before writing unescaped NDJSON: %s', async photoBase64 => {
    const f = await fixture(); const original = f.archive.read.bind(f.archive);
    vi.spyOn(f.archive, 'read').mockImplementation(async (token, id) => ({ ...await original(token, id), photoBase64 }));
    const reader = (await route(f.make(), f.services)).body!.getReader(); await reader.read();
    await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
  });

it('refuses export under an exhausted owner request quota without taking a lease', async () => {
  const f = await fixture();
  await db.prepare(`UPDATE pa_owners SET http_request_minute=CAST(unixepoch()/60 AS INTEGER)+1,http_request_count=30
    WHERE owner_id=?`).bind(f.session.ownerId).run();
  await expect(route(f.make(), f.services)).rejects.toMatchObject({ code: 'RATE_LIMITED' });
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
});

it('rejects a generation mutation between the last fence and the atomic lease completion', async () => {
  const f = await fixture();
  const racing = new Proxy(db, { get(target, property) {
    if (property === 'prepare') return (sql: string) => {
      const statement = target.prepare(sql);
      if (!sql.includes('UPDATE pa_owners SET export_lease_id=NULL') || !sql.includes('AND disabled=0')) return statement;
      return { bind(...parameters: unknown[]) {
        const bound = statement.bind(...parameters);
        return { async first() {
          await db.prepare('UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=?').bind(f.session.ownerId).run();
          return bound.first();
        } };
      } } as D1PreparedStatement;
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const response = await exportPage({ db: racing, auth: f.auth, read: f.archive.read.bind(f.archive) }, f.make(), f.session.token);
  const reader = response.body!.getReader(); await reader.read(); await reader.read();
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
});

it('enforces the original absolute session deadline even when the consumer stops reading', async () => {
  const f = await fixture(); const session = await f.auth.requireSession(f.session.token);
  await db.prepare(`UPDATE pa_sessions SET expires_at=CAST(unixepoch('subsec')*1000 AS INTEGER)+1000
    WHERE session_hash=?`).bind(session.sessionHash).run();
  const response = await route(f.make(), f.services);
  await new Promise(resolve => setTimeout(resolve, 1250));
  expect((await lease(f.session.ownerId))!.export_lease_id).toBeNull();
  await expect(response.body!.getReader().read()).rejects.toThrow('EXPORT_INTERRUPTED');
});

it('bounds aggregate wire bytes without accumulating earlier records in the Worker', async () => {
  const f = await fixture(50); const original = f.archive.read.bind(f.archive);
  vi.spyOn(f.archive, 'read').mockImplementation(async (token, id) => ({ ...await original(token, id),
    photoBase64: 'A'.repeat(2 * 1024 * 1024) }));
  const reader = (await route(f.make(), f.services)).body!.getReader(); await reader.read();
  for (let i = 0; i < 47; i++) expect((await reader.read()).value!.byteLength).toBeGreaterThan(2 * 1024 * 1024);
  await expect(reader.read()).rejects.toThrow('EXPORT_INTERRUPTED');
}, 20_000);

it('upgrades an existing owner without changing quota or snapshot generation and keeps old-schema export closed', async () => {
  await reset(); await applyD1Migrations(db, bindings.TEST_MIGRATIONS.filter(m => !m.name.startsWith('0033_')));
  const f = await fixture();
  await expect(route(f.make(), f.services)).rejects.toMatchObject({ code: 'EXPORT_UNAVAILABLE' });
  const before = await db.prepare(`SELECT o.http_request_count,g.generation FROM pa_owners o
    JOIN pa_owner_recovery_generations g ON g.owner_id=o.owner_id WHERE o.owner_id=?`).bind(f.session.ownerId).first();
  await applyD1Migrations(db, bindings.TEST_MIGRATIONS);
  expect(await db.prepare(`SELECT o.http_request_count,g.generation FROM pa_owners o
    JOIN pa_owner_recovery_generations g ON g.owner_id=o.owner_id WHERE o.owner_id=?`).bind(f.session.ownerId).first()).toEqual(before);
  expect(await lease(f.session.ownerId)).toEqual({ export_lease_id: null, export_lease_expires_at: 0 });
  expect((await frames(await route(f.make(), f.services))).at(-1)).toMatchObject({ type: 'complete', recordCount: 1 });
});
