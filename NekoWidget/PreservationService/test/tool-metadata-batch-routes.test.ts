import { env } from 'cloudflare:workers';
import { applyD1Migrations, reset, type D1Migration } from 'cloudflare:test';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { route, type Services } from '../src/index';
import { OwnerRequestLimiter } from '../src/owner-request-limiter';
import { payloadWork } from '../src/payload-work';
import { fixture, db } from './tool-metadata-batch-fixture';

const migrations = (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS;
beforeEach(async () => { await reset(); await applyD1Migrations(db, migrations); });
afterEach(() => vi.restoreAllMocks());
type Fixture = Awaited<ReturnType<typeof fixture>>;
const services = (f: Fixture) => ({ auth: f.auth, archive: f.archive(), ownerRequestLimiter: new OwnerRequestLimiter(db) } as Services);
function request(f: Fixture, path: string, method = 'POST', body?: string | Uint8Array, signal?: AbortSignal) {
  return new Request(`https://preservation.test${path}`, { method, ...(signal ? { signal } : {}),
    headers: { authorization: `Bearer ${f.session.token}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: body as BodyInit }) });
}
const prefix = '/v1/tool-metadata-batches';
function latch() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

it('uses the real owner limiter for second stage and finish while ordinary auth stays covered-only', async () => {
  const f = await fixture(), s = services(f);
  expect((await route(request(f, prefix, 'POST', JSON.stringify(f.manifest)), s)).status).toBe(200);
  for (const [index, part] of f.parts.entries()) {
    const reply = await route(request(f, `${prefix}/${f.batchId}/parts/${part.id}`, 'PUT', part.body), s);
    expect(await reply.json()).toMatchObject({ status: 'part-staged', recordId: part.id });
    if (index === 0) {
      await expect(route(request(f, '/v1/usage', 'GET'), s)).rejects.toThrow();
      await expect(route(request(f, `/v1/records/${part.id}`, 'PUT', part.body), s)).rejects.toThrow();
      expect((await route(request(f, prefix, 'POST', JSON.stringify(f.manifest)), s)).status).toBe(200);
    }
  }
  let ready = false;
  for (let i = 0; i < 12; i++) {
    const reply = await route(request(f, `${prefix}/${f.batchId}/finish`), s);
    const result = await reply.json() as { status: string };
    if (result.status === 'parts-ready') { ready = true; break; }
    expect(result.status).toBe('pending');
  }
  expect(ready).toBe(true); await f.auth.requireSession(f.session.token);
}, 60_000);

it('shares the 30-attempt counter with continuation and refuses work at the cap', async () => {
  const f = await fixture(), s = services(f);
  await route(request(f, prefix, 'POST', JSON.stringify(f.manifest)), s);
  const first = f.parts[0]!, second = f.parts[1]!;
  await route(request(f, `${prefix}/${f.batchId}/parts/${first.id}`, 'PUT', first.body), s);
  await db.prepare('UPDATE pa_owners SET http_request_count=29,http_request_minute=CAST(unixepoch()/60 AS INTEGER) WHERE owner_id=?').bind(f.session.ownerId).run();
  await route(request(f, `${prefix}/${f.batchId}/parts/${second.id}`, 'PUT', second.body), s);
  const before = { ...f.count };
  await expect(route(request(f, `${prefix}/${f.batchId}/finish`), s)).rejects.toMatchObject({ code: 'RATE_LIMITED', status: 429 });
  expect(f.count).toEqual(before);
  expect(await db.prepare('SELECT http_request_count FROM pa_owners WHERE owner_id=?').bind(f.session.ownerId).first()).toEqual({ http_request_count: 30 });
}, 60_000);

it('keeps the payload permit after abort until active encryption settles, then lets a waiter proceed', async () => {
  const f = await fixture(), s = services(f);
  await route(request(f, prefix, 'POST', JSON.stringify(f.manifest)), s);
  const entered = latch(), hold = latch(), seal = f.options.keys.seal.bind(f.options.keys);
  let once = false;
  vi.spyOn(f.options.keys, 'seal').mockImplementation(async (bytes, context) => {
    if (!once && context.purpose === 'record') { once = true; entered.release(); await hold.promise; }
    return seal(bytes, context);
  });
  const abort = new AbortController(), part = f.parts[0]!;
  const active = route(request(f, `${prefix}/${f.batchId}/parts/${part.id}`, 'PUT', part.body, abort.signal), s);
  await entered.promise; abort.abort();
  let waiterEntered = false;
  const waiter = payloadWork.run(async () => { waiterEntered = true; });
  try {
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(waiterEntered).toBe(false);
  } finally { hold.release(); }
  await Promise.allSettled([active]); await waiter;
  expect(waiterEntered).toBe(true);
}, 60_000);

it('does not read a queued batch body after its request is aborted', async () => {
  const f = await fixture(), s = services(f);
  await route(request(f, prefix, 'POST', JSON.stringify(f.manifest)), s);
  const release = await payloadWork.acquire(), abort = new AbortController(); let reads = 0;
  const body = new ReadableStream<Uint8Array>({ pull(controller) { reads++; controller.enqueue(new Uint8Array([1])); } }, { highWaterMark: 0 });
  const pending = route(new Request(`https://preservation.test${prefix}/${f.batchId}/parts/${f.parts[0]!.id}`,
    { method: 'PUT', body, signal: abort.signal, headers: { authorization: `Bearer ${f.session.token}`, 'content-type': 'application/json' } }), s);
  const denied = expect(pending).rejects.toMatchObject({ code: 'PRESERVATION_BUSY' });
  abort.abort();
  try { await denied; expect(reads).toBe(0); } finally { release(); await body.cancel(); }
});
