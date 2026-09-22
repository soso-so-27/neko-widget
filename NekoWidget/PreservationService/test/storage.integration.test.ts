import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore, cleanupArchive } from '../src/storage';
import { encodePhoto } from '../src/documents';
import { randomToken, type ArchiveDocument, type KeyCustody } from '../src/contracts';
import worker, { route, type Services, type Env } from '../src/index';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const photo = new Uint8Array([255, 216, 255, 217]); // Synthetic, injected validator; not a real JPEG test.
const document: ArchiveDocument = { formatVersion: 1, text: 'ひざで寝た日', capturedAt: '2023-03-02T05:00:00.000Z',
  writtenAt: null, updatedAt: null, catNames: ['むぎ', 'そら'], photoFile: 'photo.jpg' };

async function fixture(overrides: { quotaBytes?: number; maximumRecords?: number } = {}) {
  let now = 1_790_035_200_000;
  let state: 'active' | 'expired' | 'unknown' | 'grace' = 'active';
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const keys: KeyCustody = {
    async seal(value, context) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value as BufferSource);
      const output = new Uint8Array(12 + cipher.byteLength); output.set(iv); output.set(new Uint8Array(cipher), 12); return output;
    },
    async open(value, context) {
      return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: value.slice(0, 12),
        additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value.slice(12)));
    },
  };
  const authOptions = { db: binding.DB, keys, identityIndexSecret: randomToken(), now: () => now };
  const auth = new DurableAuth(authOptions);
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() };
  const session = await auth.establish(identity);
  const options = { db: binding.DB, bucket: binding.ARCHIVE, keys, auth, now: () => now,
    membership: { status: async () => state }, photos: { validateJPEG: async () => true },
    quotaBytes: overrides.quotaBytes ?? 100_000, maximumRecords: overrides.maximumRecords ?? 100 };
  const archive = new ArchiveStore(options);
  const request = (patch: Record<string, unknown> = {}) => ({ expectedRevision: null, consentVersion: 'managed-preservation-v1',
    document, photoBase64: encodePhoto(photo), ...patch });
  return { auth, authOptions, identity, session, archive, options, request,
    setState(value: typeof state) { state = value; }, setNow(value: number) { now = value; } };
}

it('real D1/R2 round trip survives new auth/store instances and expires membership without losing access', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request());
  f.setState('expired');
  const auth = new DurableAuth(f.authOptions); const session = await auth.establish(f.identity);
  const archive = new ArchiveStore({ ...f.options, auth });
  const restored = await archive.read(session.token, id);
  expect(restored.document).toEqual(document); expect(restored.photoBase64).toBe(encodePhoto(photo));
  const row = await binding.DB.prepare('SELECT metadata FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(session.ownerId, id).first<{ metadata: number[] }>();
  expect(new TextDecoder().decode(new Uint8Array(row!.metadata))).not.toContain('ひざ');
  await expect(archive.put(session.token, crypto.randomUUID(), f.request())).rejects.toMatchObject({ code: 'NEW_SAVE_REQUIRES_MEMBERSHIP' });
  await archive.put(session.token, id, f.request({ expectedRevision: 1, consentVersion: null,
    document: { ...document, text: '解約後に編集' } }));
  expect((await archive.read(session.token, id)).document.text).toBe('解約後に編集');
  await archive.remove(session.token, id, 2);
  await expect(archive.read(session.token, id)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
  expect(await archive.remove(session.token, id, 2)).toEqual({ recordId: id, revision: 3 });
  await expect(archive.put(session.token, id, f.request())).rejects.toMatchObject({ code: 'RECORD_DELETED' });
});

it('another verified Apple identity cannot read, edit or delete another owner records', async () => {
  const f = await fixture(); const id = crypto.randomUUID(); await f.archive.put(f.session.token, id, f.request());
  const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
  expect((await f.archive.list(other.token)).items).toEqual([]);
  await expect(f.archive.read(other.token, id)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
  await expect(f.archive.put(other.token, id, f.request({ expectedRevision: 1 }))).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await expect(f.archive.remove(other.token, id, 1)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
});

it('photo-only first memo remains editable after expiry; text-only exports no invented photo', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  await f.archive.put(f.session.token, id, f.request({ document: { ...document, text: '' } }));
  const textOnly = crypto.randomUUID();
  await f.archive.put(f.session.token, textOnly, f.request({ document: { ...document, photoFile: null }, photoBase64: null }));
  f.setState('unknown');
  await f.archive.put(f.session.token, id, f.request({ expectedRevision: 1 }));
  expect((await f.archive.read(f.session.token, id)).document.text).toBe(document.text);
  expect((await f.archive.read(f.session.token, textOnly)).photoBase64).toBeNull();
});

it('lost create reply retry after later edit preserves the newer memo', async () => {
  const f = await fixture(); const id = crypto.randomUUID(); await f.archive.put(f.session.token, id, f.request());
  await f.archive.put(f.session.token, id, f.request({ expectedRevision: 1, document: { ...document, text: '新しいメモ' } }));
  f.setState('expired');
  expect(await f.archive.put(f.session.token, id, f.request())).toEqual({ recordId: id, revision: 2 });
  expect((await f.archive.read(f.session.token, id)).document.text).toBe('新しいメモ');
});

it('parallel revision edits have one winner; photo replacement cannot bypass new-save membership', async () => {
  const f = await fixture(); const id = crypto.randomUUID(); await f.archive.put(f.session.token, id, f.request());
  const results = await Promise.allSettled(['a', 'b'].map((text) => f.archive.put(f.session.token, id,
    f.request({ expectedRevision: 1, document: { ...document, text } }))));
  expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
  await expect(f.archive.put(f.session.token, id, f.request({ expectedRevision: 2, photoBase64: encodePhoto(new Uint8Array([1, 2, 3])) })))
    .rejects.toMatchObject({ code: 'PHOTO_REPLACEMENT_REQUIRES_NEW_RECORD' });
});

it('consent, grace, unknown entitlement and capacity boundaries are distinct', async () => {
  const f = await fixture({ maximumRecords: 1 });
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request({ consentVersion: null })))
    .rejects.toMatchObject({ code: 'PRESERVATION_CONSENT_REQUIRED' });
  f.setState('unknown');
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request())).rejects.toMatchObject({ code: 'ACCESS_UNCONFIRMED' });
  f.setState('grace'); await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), f.request())).rejects.toMatchObject({ code: 'ARCHIVE_CAPACITY_REACHED' });
  const small = await fixture({ quotaBytes: 1 });
  await expect(small.archive.put(small.session.token, crypto.randomUUID(), small.request())).rejects.toMatchObject({ code: 'ARCHIVE_CAPACITY_REACHED' });
});

it('concurrent reservations cannot exceed the owner record limit', async () => {
  const f = await fixture({ maximumRecords: 1 });
  const results = await Promise.allSettled([crypto.randomUUID(), crypto.randomUUID()]
    .map((id) => f.archive.put(f.session.token, id, f.request())));
  expect(results.filter((value) => value.status === 'fulfilled')).toHaveLength(1);
  expect((await f.archive.list(f.session.token)).items).toHaveLength(1);
});

it('cleanup advances beyond its first page and one failed object does not block the rest', async () => {
  const prefix = crypto.randomUUID(); const now = Date.now();
  const keys = Array.from({ length: 23 }, (_, index) => `${prefix}/${String(index).padStart(2, '0')}`);
  for (const key of keys) {
    await binding.ARCHIVE.put(key, 'encrypted');
    await binding.DB.prepare('INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)').bind(key, now).run();
  }
  const bucket = new Proxy(binding.ARCHIVE, { get(target, property) {
    if (property === 'delete') return async (key: string) => {
      if (key === keys[0]) throw new Error('injected storage outage');
      return target.delete(key);
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  await expect(cleanupArchive({ db: binding.DB, bucket, now: () => now }, 20))
    .rejects.toMatchObject({ code: 'CLEANUP_INCOMPLETE' });
  await cleanupArchive({ db: binding.DB, bucket, now: () => now }, 20);
  expect(await binding.ARCHIVE.get(keys[22]!)).toBeNull();
  expect(await binding.ARCHIVE.get(keys[0]!)).not.toBeNull();
  await cleanupArchive({ db: binding.DB, bucket: binding.ARCHIVE, now: () => now + 3_600_001 }, 100);
  expect(await binding.ARCHIVE.get(keys[0]!)).toBeNull();
});

it('maintenance works while Apple, membership and public requests are disabled', async () => {
  const key = crypto.randomUUID(); await binding.ARCHIVE.put(key, 'encrypted');
  await binding.DB.prepare('INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)').bind(key, Date.now()).run();
  await worker.scheduled({} as ScheduledEvent, { ...binding, CLEANUP_ENABLED: 'YES' });
  expect(await binding.ARCHIVE.get(key)).toBeNull();
});

it('session revoked during R2 upload cannot commit and leaves no live record/reservation', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const bucket = new Proxy(binding.ARCHIVE, { get(target, property) {
    if (property === 'put') return async (...args: Parameters<R2Bucket['put']>) => {
      const result = await target.put(...args); await f.auth.revokeSession(f.session.token); return result;
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const archive = new ArchiveStore({ ...f.options, bucket });
  await expect(archive.put(f.session.token, id, f.request())).rejects.toMatchObject({ status: 401 });
  const row = await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, id).first();
  expect(row).toBeNull();
  expect(await binding.DB.prepare('SELECT 1 FROM pa_uploads WHERE owner_id=?').bind(f.session.ownerId).first()).toBeNull();
});

it('invalid JPEG cannot become a saved record and missing/corrupt object is not a successful recovery', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const strict = new ArchiveStore({ ...f.options, photos: { validateJPEG: async () => false } });
  await expect(strict.put(f.session.token, id, f.request())).rejects.toMatchObject({ code: 'INVALID_JPEG' });
  await f.archive.put(f.session.token, id, f.request());
  const row = await binding.DB.prepare('SELECT photo_key FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId, id).first<{ photo_key: string }>();
  await binding.ARCHIVE.delete(row!.photo_key);
  await expect(f.archive.read(f.session.token, id)).rejects.toMatchObject({ code: 'ARCHIVE_PHOTO_UNAVAILABLE' });
});

it('listing is paged and carries a mutation generation without downloading images', async () => {
  const f = await fixture();
  for (let i = 0; i < 3; i++) await f.archive.put(f.session.token, crypto.randomUUID(), f.request());
  const first = await f.archive.list(f.session.token, '', 2);
  expect(first.items).toHaveLength(2); expect(first.nextCursor).not.toBeNull();
  const last = await f.archive.list(f.session.token, first.nextCursor!, 2);
  expect(last.items).toHaveLength(1); expect(last.nextCursor).toBeNull(); expect(last.generation).toBe(first.generation);
  expect(JSON.stringify(first)).not.toContain('photoBase64');
});

it('HTTP is disabled without explicit gate and missing providers cannot enable it', async () => {
  const request = new Request('https://preservation.test/v1/records');
  const closed = await worker.fetch(request, binding as Env);
  expect(closed.status).toBe(503); expect(closed.headers.get('cache-control')).toBe('no-store');
  expect(await closed.json()).toEqual({ error: { code: 'PRESERVATION_DISABLED' } });
  const missing = await worker.fetch(request, { ...binding, PRESERVATION_ENABLED: 'YES' });
  expect(await missing.json()).toEqual({ error: { code: 'PRESERVATION_NOT_CONFIGURED' } });
});

it('HTTP record endpoints use bearer identity and fixed document fields, never caller-supplied owner', async () => {
  const f = await fixture(); const id = crypto.randomUUID();
  const services: Services = { auth: f.auth, archive: f.archive, verifier: { verifyNativeAuthorization: async () => f.identity } };
  const url = `https://preservation.test/v1/records/${id}`;
  const headers = { authorization: `Bearer ${f.session.token}`, 'content-type': 'application/json' };
  const put = await route(new Request(url, { method: 'PUT', headers, body: JSON.stringify(f.request()) }), services);
  expect(put.status).toBe(200); expect(await put.json()).toEqual({ recordId: id, revision: 1 });
  await expect(route(new Request(url, { method: 'PUT', headers, body: JSON.stringify(f.request({ ownerId: 'other' })) }), services))
    .rejects.toMatchObject({ code: 'INVALID_RECORD' });
  const get = await route(new Request(url, { headers }), services);
  expect((await get.json() as { document: ArchiveDocument }).document).toEqual(document);
});
