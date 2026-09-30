import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import worker, { configuredServices, type Env } from '../src/index';
import { randomToken, sha256 } from '../src/contracts';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };

it('cannot bypass owner/write admission by omitting both environment and pilot mode', async () => {
  let externalCalls = 0;
  const provider = { fetch: async () => { externalCalls++; throw new Error('must not call'); } } as unknown as Fetcher;
  const db = new Proxy(binding.DB, { get(target, property) {
    if (property === 'prepare') return (sql: string) => sql.includes('SELECT delete_intent_required,owner_snapshot_required')
      ? { first: async () => ({ delete_intent_required: 1, owner_snapshot_required: 1 }) }
      : target.prepare(sql);
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const services = configuredServices({ ...binding, DB: db, PRESERVATION_ENABLED: 'YES',
    KEY_WRAPPER: provider, KEY_WRAPPER_CALLER_SECRET: randomToken(), MEMBERSHIP_AUTHORITY: provider,
    PHOTO_VALIDATOR: provider, IDENTITY_INDEX_SECRET: randomToken(),
    APPLE_CREDENTIALS_JSON: JSON.stringify({ clientId: 'test.neko.preservation' }),
    PRESERVATION_LINK_AUDIENCE: 'neko-pilot-test', REQUEST_LIMITER: { limit: async () => ({ success: true }) },
    RECOVERY_COPY_ENABLED: 'YES', RECOVERY_S3_REGION: 'ap-northeast-1',
    RECOVERY_S3_BUCKET: 'neko-preservation-test', RECOVERY_S3_ACCOUNT_ID: '123456789012',
    RECOVERY_S3_ACCESS_KEY_ID: 'AKIA' + 'A'.repeat(16), RECOVERY_S3_SECRET_ACCESS_KEY: 'a'.repeat(40),
    OWNER_QUOTA_BYTES: '1073741824', MAXIMUM_RECORDS: '200', GLOBAL_ACTIVE_STORAGE_LIMIT_BYTES: '3221225472',
  });
  await expect(services.auth.establish({ issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(),
    refreshToken: randomToken() })).rejects.toMatchObject({ code: 'PILOT_WRITES_PAUSED' });
  // Seed an existing local owner/session, without bypassing session validation.
  const ownerId = crypto.randomUUID(), token = randomToken(), now = Date.now();
  await binding.DB.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, 'a'.repeat(64), now).run();
  await binding.DB.prepare(`INSERT INTO pa_sessions(session_hash,owner_id,owner_epoch,created_at,expires_at)
    VALUES(?,?,0,?,?)`).bind(await sha256(token), ownerId, now, now + 60_000).run();
  await expect(services.archive.put(token, crypto.randomUUID(), {}))
    .rejects.toMatchObject({ code: 'PILOT_WRITES_PAUSED' });
  expect((await services.archive.usage(token)).records.saved).toBe(0);
  expect(externalCalls).toBe(0);
});

it('rejects rate-limited traffic before a D1 query or provider setup', async () => {
  let databaseCalls = 0;
  const db = { prepare: () => { databaseCalls++; throw new Error('must not query'); } } as unknown as D1Database;
  const response = await worker.fetch(new Request('https://preservation.test/v1/records', {
    headers: { 'CF-Connecting-IP': '192.0.2.1' },
  }), { ...binding, DB: db, PRESERVATION_ENABLED: 'YES', REQUEST_LIMITER: { limit: async () => ({ success: false }) } });
  expect(response.status).toBe(429);
  expect(await response.json()).toEqual({ error: { code: 'RATE_LIMITED' } });
  expect(databaseCalls).toBe(0);
});

it('records one finite pilot failure without retaining credentials or changing the rejection', async () => {
  const provider = { fetch: async () => { throw new Error('must not call'); } } as unknown as Fetcher;
  const db = new Proxy(binding.DB, { get(target, property) {
    if (property === 'prepare') return (sql: string) => sql.includes('SELECT delete_intent_required,owner_snapshot_required')
      ? { first: async () => ({ delete_intent_required: 1, owner_snapshot_required: 1 }) } : target.prepare(sql);
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const options: Env = { ...binding, DB: db, PRESERVATION_ENABLED: 'YES', ENVIRONMENT: 'staging',
    PILOT_MODE: 'YES', PILOT_REGISTRATION_ENABLED: 'YES',
    OWNER_QUOTA_BYTES: '1073741824', MAXIMUM_RECORDS: '200', GLOBAL_ACTIVE_STORAGE_LIMIT_BYTES: '3221225472',
    KEY_WRAPPER: provider, KEY_WRAPPER_CALLER_SECRET: randomToken(), MEMBERSHIP_AUTHORITY: provider,
    PHOTO_VALIDATOR: provider, IDENTITY_INDEX_SECRET: randomToken(),
    APPLE_CREDENTIALS_JSON: JSON.stringify({ clientId: 'test.neko.preservation' }),
    PRESERVATION_LINK_AUDIENCE: 'neko-pilot-test', REQUEST_LIMITER: { limit: async () => ({ success: true }) },
  };
  const makeRequest = async () => new Request('https://preservation.test/v1/auth/sessions', {
    method: 'POST', headers: { 'CF-Connecting-IP': '192.0.2.1', 'content-type': 'application/json' },
    body: JSON.stringify({ ...await configuredServices(options).auth.issueChallenge(),
      identityToken: 'not-a-real-private-token', authorizationCode: 'private-code-must-not-be-recorded' }),
  });
  // The wire does not accept the challenge's nonce/expiry fields.
  const request = async () => {
    const r = await makeRequest(), input = await r.json() as Record<string, unknown>;
    delete input.nonce; delete input.expiresAt;
    return new Request(r.url, { method: r.method, headers: r.headers, body: JSON.stringify(input) });
  };
  const key = '__service_diagnostics/apple-auth-first.json';
  expect((await worker.fetch(await request(), options)).status).toBe(401);
  expect(await binding.ARCHIVE.get(key)).toBeNull();
  options.APPLE_AUTH_DIAGNOSTICS_UNTIL = String(Date.now() + 60_000);
  const response = await worker.fetch(await request(), options);
  expect(response.status).toBe(401);
  expect(await response.json()).toEqual({ error: { code: 'APPLE_IDENTITY_UNCONFIRMED' } });
  const saved = await (await binding.ARCHIVE.get(key))!.text();
  expect(Object.keys(JSON.parse(saved)).sort()).toEqual(['at', 'claim', 'code', 'stage']);
  expect(JSON.parse(saved)).toMatchObject({ stage: 'native-jwt', claim: 'none' });
  expect(saved).not.toContain('private-token'); expect(saved).not.toContain('private-code');
  await worker.fetch(await request(), options);
  expect(await (await binding.ARCHIVE.get(key))!.text()).toBe(saved);
  const failingBucket = { put: async () => { throw new Error('diagnostic storage unavailable'); } } as unknown as R2Bucket;
  expect((await worker.fetch(await request(), { ...options, ARCHIVE: failingBucket })).status).toBe(401);
});
