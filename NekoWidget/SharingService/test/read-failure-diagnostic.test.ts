import { afterEach, describe, expect, it, vi } from 'vitest';
import { route } from '../src/index';
import { ApiError, errorResponse } from '../src/errors';
import { beginReadDiagnostic, finishReadDiagnostic, readStage } from '../src/read-failure-diagnostic';
import { billingSignedRequestTranscript } from '../src/billing-protocol';
import { randomBase64url, sha256Base64url } from '../src/encoding';
import type { Env } from '../src/env';
import { billing, gates, settings } from './group-billing-fixture';
import { db, person, sign, signed } from './group-fixture';

afterEach(() => vi.restoreAllMocks());
const path = '/v1/billing/entitlement';
async function billingRequest() {
  const b = await billing(), timestamp = Math.floor(Date.now()/1000), nonce = randomBase64url(16);
  const signature = await sign(b.billingKey.privateKey, billingSignedRequestTranscript({
    billingAccountId: b.id, billingKeyId: b.keyId, timestamp, nonce, method: 'GET', pathname: path,
    bodySHA256: await sha256Base64url(new Uint8Array()),
  }));
  return new Request('https://example.invalid'+path, { headers: {
    'neko-billing-protocol-version': '1', 'neko-billing-account-id': b.id,
    'neko-billing-key-id': b.keyId, 'neko-billing-timestamp': String(timestamp),
    'neko-billing-nonce': nonce, 'neko-billing-signature': signature,
  } });
}
function brokenRead(table: string): D1Database {
  return new Proxy(db, { get(target, property) {
    if (property === 'prepare') return (sql: string) => {
      if (sql.includes(table)) throw new Error('SECRET SQL account signature and contents');
      return target.prepare(sql);
    };
    const value = Reflect.get(target, property);
    return typeof value === 'function' ? value.bind(target) : value;
  } });
}
async function response(request: Request, env: Env) {
  try { return await route(request, env); } catch (error) { return errorResponse(error); }
}
describe('bounded read failure diagnostics', () => {
  it.each([
    ['billing_account_keys', 'auth_key_lookup'],
    ['billing_effective_entitlement_current', 'entitlement'],
  ])('reproduces a storage 500 at %s without changing response or disclosing values', async (table, stage) => {
    await gates();
    const request = await billingRequest();
    const before = await db.prepare('SELECT count(*) AS n FROM billing_accounts').first('n');
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const result = await response(request, { ...settings, DB: brokenRead(table) } as Env);
    expect(result.status).toBe(500);
    expect(await result.json()).toEqual({ error: { code: 'internal_error', message: 'The request could not be completed.' } });
    expect(warn.mock.calls).toEqual([[JSON.stringify({ event: 'neko_read_failure_v1',
      route: 'billing_entitlement', stage, status: 500, reason: 'unexpected_exception' })]]);
    expect(JSON.stringify(warn.mock.calls)).not.toContain('SECRET');
    // No account deletion, grant synthesis, or automatic replay was introduced.
    expect(await db.prepare('SELECT count(*) AS n FROM billing_accounts').first('n')).toBe(before);
  });
  it('identifies a pre-handler retention storage failure without bypassing the guard', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const result = await response(new Request('https://example.invalid'+path), {
      ...settings, BILLING_TRANSACTION_RETENTION_REQUIRED: 'YES',
      MEDIA: { get: async () => { throw new Error('SECRET bucket locator'); } } as unknown as R2Bucket,
    } as Env);
    expect(result.status).toBe(500);
    expect(JSON.parse(warn.mock.calls[0]![0] as string)).toEqual({ event: 'neko_read_failure_v1',
      route: 'billing_entitlement', stage: 'retention_guard', status: 500, reason: 'unexpected_exception' });
  });
  it('distinguishes a throwing rate limiter from explicit rate rejection', async () => {
    await gates();
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const failure = await response(new Request('https://example.invalid'+path), {
      ...settings, BILLING_RATE_LIMITER: { limit: async () => { throw new Error('SECRET network address'); } },
    } as Env);
    expect(failure.status).toBe(500);
    expect(JSON.parse(warn.mock.calls[0]![0] as string)).toMatchObject({ stage: 'rate_limit', reason: 'unexpected_exception' });
    warn.mockClear();
    const limited = await response(new Request('https://example.invalid'+path), {
      ...settings, BILLING_RATE_LIMITER: { limit: async () => ({ success: false }) },
    } as Env);
    expect(limited.status).toBe(429);
    expect(warn).not.toHaveBeenCalled();
  });
  it('records payer replay separately from invalid authentication, without a family or device ID', async () => {
    const p = await person(), family = crypto.randomUUID();
    await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1 WHERE singleton=1').run();
    const enabled = { ...settings, FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'YES', FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES' } as Env;
    const url = `/v3/family-notebooks/${family}/payer`;
    const request = await signed(p, url);
    const first = await response(new Request(request.url, { headers: request.headers }), enabled);
    expect(first.status).toBe(404); // No family: valid authentication already consumed the nonce.
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect((await response(new Request(request.url, { headers: request.headers }), enabled)).status).toBe(401);
    expect(JSON.parse(warn.mock.calls[0]![0] as string)).toEqual({ event: 'neko_read_failure_v1',
      route: 'family_payer', stage: 'auth_nonce_claim', status: 401, reason: 'replay' });
    warn.mockClear();
    expect((await response(new Request('https://example.invalid'+url), enabled)).status).toBe(401);
    expect(JSON.parse(warn.mock.calls[0]![0] as string)).toMatchObject({ stage: 'auth_headers', reason: 'invalid_authentication' });
    expect(JSON.stringify(warn.mock.calls)).not.toContain(family);
    expect(JSON.stringify(warn.mock.calls)).not.toContain(p.deviceId);
  });
  it('does not leak arbitrary error codes, messages, query values, or exceptions from the logger', () => {
    const request = new Request('https://example.invalid'+path+'?private=SECRET');
    beginReadDiagnostic(request); readStage(request, 'retention_guard');
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    finishReadDiagnostic(request, new ApiError(503, 'SECRET', 'SECRET', { private: 'SECRET' }));
    expect(JSON.stringify(warn.mock.calls)).not.toContain('SECRET');
    expect(JSON.parse(warn.mock.calls[0]![0] as string).reason).toBe('other_api_error');
    warn.mockImplementation(() => { throw new Error('logger unavailable'); });
    beginReadDiagnostic(request);
    expect(() => finishReadDiagnostic(request, new Error('SECRET'))).not.toThrow();
  });
  it('does not log successful reads, unrelated routes or mutations', async () => {
    await gates();
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect((await response(await billingRequest(), settings as Env)).status).toBe(200);
    for (const request of [new Request('https://example.invalid/health'),
      new Request('https://example.invalid'+path, { method: 'POST' })]) {
      beginReadDiagnostic(request); finishReadDiagnostic(request, new Error('SECRET'));
    }
    expect(warn).not.toHaveBeenCalled();
  });
});
