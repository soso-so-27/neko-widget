import { WorkerEntrypoint } from 'cloudflare:workers';
import { authenticateBillingSignedRequest, consumeBillingNonce, type AuthenticatedBillingAccount } from '../../SharingService/src/billing-auth';
import { effectiveBillingEntitlement } from '../../SharingService/src/billing-entitlement';
import { billingEffectiveEntitlementRuntimeEnabled, type Env as SharingEnv } from '../../SharingService/src/env';
import { ApiError } from '../../SharingService/src/errors';
import { LINK_SIGNING_PATH, linkTranscript, validAudience, validateChallenge, validateProof } from './billing-link-protocol';
import { readBoundedBody } from './bounded-body';
import { ServiceError, sha256 } from './contracts';

export interface BillingAuthorityEnv extends Pick<SharingEnv, 'DB' | 'BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED'> {
  PRESERVATION_BILLING_ENABLED?: string;
  PRESERVATION_LINK_AUDIENCE?: string;
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const response = (body: unknown, status = 200): Response => Response.json(body, { status,
  headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
const failure = (code: string, status: number): Response => response({ error: { code } }, status);
function object(value: unknown, fields: string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).length !== fields.length || fields.some(field => !Object.hasOwn(value, field))) {
    throw new ServiceError('invalid_request');
  }
  return value as Record<string, unknown>;
}

// These imported functions use only DB. No Sharing runtime routes or credentials
// are exposed here; the binding must point at the existing billing database.
const billingEnv = (env: BillingAuthorityEnv): SharingEnv => env as SharingEnv;
async function requireActiveKey(env: BillingAuthorityEnv, account: AuthenticatedBillingAccount, consumed = false): Promise<void> {
  const row = await env.DB.prepare(`SELECT k.id FROM billing_account_keys k
    WHERE k.id = ? AND k.billing_account_id = ? AND k.state = 'active'
    ${consumed ? `AND EXISTS (SELECT 1 FROM billing_request_nonces n
      WHERE n.billing_key_id = k.id AND n.nonce = ? AND n.expires_at > unixepoch())` : ''}`)
    .bind(...(consumed ? [account.billingKeyId, account.billingAccountId, account.nonce]
      : [account.billingKeyId, account.billingAccountId])).first();
  if (!row) throw new ServiceError('invalid_billing_proof', 401);
}

async function verifyLink(value: unknown, env: BillingAuthorityEnv, audience: string): Promise<Response> {
  const input = object(value, ['challenge', 'proof']);
  const challenge = validateChallenge(input.challenge, audience, Date.now());
  const proof = validateProof(input.proof);
  const transcript = linkTranscript(challenge);
  const challengeSHA256 = await sha256(transcript);
  // Sign exactly the canonical challenge, not a caller-selected URL or envelope.
  const signed = new Request(`https://billing.invalid${LINK_SIGNING_PATH}`, { method: 'POST', headers: {
    'neko-billing-protocol-version': '1', 'neko-billing-account-id': challenge.billingAccountId,
    'neko-billing-key-id': proof.billingKeyId, 'neko-billing-timestamp': proof.timestamp,
    'neko-billing-nonce': proof.nonce, 'neko-billing-signature': proof.signature,
  } });
  const account = await authenticateBillingSignedRequest(signed, billingEnv(env), new TextEncoder().encode(transcript));
  await requireActiveKey(env, account);
  validateChallenge(challenge, audience, Date.now());
  await consumeBillingNonce(billingEnv(env), account);
  // A key rotated/revoked during nonce persistence must not produce a proof.
  // The final read is the verification point, not a cross-database transaction.
  await requireActiveKey(env, account, true);
  validateChallenge(challenge, audience, Date.now());
  return response({ version: 1, billingAccountId: account.billingAccountId, challengeSHA256 });
}

async function verifiedStatus(value: unknown, env: BillingAuthorityEnv): Promise<Response> {
  const input = object(value, ['billingAccountId']);
  if (typeof input.billingAccountId !== 'string' || !uuid.test(input.billingAccountId)) throw new ServiceError('invalid_request');
  if (!billingEffectiveEntitlementRuntimeEnabled(env)) throw new ServiceError('billing_authority_unavailable', 503);
  const gate = await env.DB.prepare('SELECT effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton = 1')
    .first<{ effective_entitlement_enabled: number }>();
  if (gate?.effective_entitlement_enabled !== 1) throw new ServiceError('billing_authority_unavailable', 503);
  const entitlement = await effectiveBillingEntitlement(billingEnv(env), input.billingAccountId);
  const status = entitlement.grantsPlus && entitlement.status === 'active' ? 'active'
    : entitlement.grantsPlus && entitlement.status === 'gracePeriod' ? 'grace'
    : entitlement.status === 'unconfirmed' ? 'unknown' : 'expired';
  return response({ version: 1, billingAccountId: input.billingAccountId, status });
}

/** Only a service binding to this named entrypoint can use the authority. */
export class BillingAuthority extends WorkerEntrypoint<BillingAuthorityEnv> {
  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== 'POST' || url.search || !['/membership/verify-link', '/membership/verified-status'].includes(url.pathname)) {
      return failure('not_found', 404);
    }
    const audience = this.env.PRESERVATION_LINK_AUDIENCE;
    if (this.env.PRESERVATION_BILLING_ENABLED !== 'YES' || !validAudience(audience)) {
      return failure('billing_authority_unavailable', 503);
    }
    try {
      if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json') {
        throw new ServiceError('invalid_request');
      }
      const bytes = await readBoundedBody(request.body, 4096, () => new ServiceError('invalid_request'), request.signal);
      let body: unknown;
      try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
      catch { throw new ServiceError('invalid_request'); }
      return url.pathname === '/membership/verify-link'
        ? await verifyLink(body, this.env, audience) : await verifiedStatus(body, this.env);
    } catch (error) {
      if (error instanceof ApiError) {
        return failure(error.code === 'replayed_billing_request' ? 'billing_proof_replayed' : 'invalid_billing_proof',
          error.code === 'replayed_billing_request' ? 409 : 401);
      }
      if (error instanceof ServiceError && ['invalid_request', 'invalid_billing_proof'].includes(error.code)) {
        return failure(error.code, error.status);
      }
      if (error instanceof ServiceError && ['INVALID_LINK_CHALLENGE', 'INVALID_BILLING_PROOF'].includes(error.code)) {
        return failure('invalid_billing_proof', 401);
      }
      return failure('billing_authority_unavailable', 503);
    }
  }
}

// No externally routable billing verification endpoint, even if enabled.
export default { fetch: async (_request: Request): Promise<Response> => failure('not_found', 404) };
