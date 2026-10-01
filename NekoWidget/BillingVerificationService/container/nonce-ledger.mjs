import { DurableObject } from 'cloudflare:workers';
import { initializeNonceLedger, canonicalDigest, claimDurableNonce, expireNonceLedger, NONCE_RETENTION_MS } from './nonce-ledger-core.mjs';
const unavailable = () => Response.json({ error: 'nonce_unavailable' }, { status: 503,
  headers: { 'cache-control': 'no-store' } });
export async function expectedScopeDigest(env) {
  if (!['Sandbox', 'Production'].includes(env.BILLING_STORE_ENVIRONMENT)
    || typeof env.BILLING_BUNDLE_ID !== 'string' || !/^[A-Za-z0-9.-]{3,255}$/u.test(env.BILLING_BUNDLE_ID)) throw new Error();
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(
    `nwb:verifier:v1:${env.BILLING_STORE_ENVIRONMENT}:${env.BILLING_BUNDLE_ID}`));
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}
export async function readBoundedBytes(request, maximum) {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let count = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array) || (count += value.byteLength) > maximum) throw new Error();
      chunks.push(value);
    }
  } catch { void reader.cancel().catch(() => undefined); throw new Error(); }
  const bytes = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}
export class BillingNonceLedger extends DurableObject {
  constructor(ctx, env) { super(ctx, env); initializeNonceLedger(ctx.storage); }
  async fetch(request) {
    try {
      const url = new URL(request.url);
      if (this.env.BILLING_VERIFIER_CONTAINER_ENABLED !== 'YES' || request.signal.aborted || url.search
        || request.headers.get('neko-nonce-scope') !== await expectedScopeDigest(this.env)) return unavailable();
      if (request.method === 'GET' && url.pathname === '/ready') {
        this.ctx.storage.transactionSync(() => expireNonceLedger(this.ctx.storage, Date.now()));
        return Response.json({ ready: true }, { headers: { 'cache-control': 'no-store' } });
      }
      if (request.method !== 'POST' || url.pathname !== '/claim'
        || request.headers.get('content-type') !== 'application/json') return unavailable();
      const input = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readBoundedBytes(request, 128)));
      if (input === null || typeof input !== 'object' || Array.isArray(input)
        || Object.keys(input).length !== 1 || !canonicalDigest(input.digest)) return unavailable();
      const outcome = claimDurableNonce(this.ctx.storage, input.digest, Date.now());
      // The retention clock is owned by this Durable Object, never the caller.
      if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(Date.now() + NONCE_RETENTION_MS);
      return Response.json({ outcome }, { headers: { 'cache-control': 'no-store' } });
    } catch { return unavailable(); }
  }
  async alarm() {
    this.ctx.storage.transactionSync(() => expireNonceLedger(this.ctx.storage, Date.now()));
    const remaining = this.ctx.storage.sql.exec('SELECT MIN(expires_ms) AS earliest FROM claims').one().earliest;
    if (Number.isSafeInteger(remaining)) await this.ctx.storage.setAlarm(remaining);
  }
}
