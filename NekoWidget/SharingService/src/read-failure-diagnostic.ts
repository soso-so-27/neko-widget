import { ApiError } from './errors';

type ReadRoute = 'billing_entitlement' | 'family_payer';
export type ReadStage = 'routing' | 'retention_guard' | 'billing_gate' | 'rate_limit'
  | 'body' | 'authentication' | 'billing_nonce' | 'entitlement'
  | 'family_gate' | 'family_state' | 'family_authorization'
  | 'auth_headers' | 'auth_encoding' | 'auth_key_lookup' | 'auth_signature'
  | 'auth_identity' | 'auth_device_rate_limit' | 'auth_nonce_cleanup' | 'auth_nonce_claim';
const contexts = new WeakMap<Request, { route: ReadRoute; stage: ReadStage }>();
const reasons = new Set([
  'invalid_authentication', 'replay', 'invalid_billing_authentication', 'stale_billing_request',
  'billing_runtime_disabled', 'billing_runtime_gate_unavailable', 'rate_limiter_unavailable',
  'family_notebook_disabled', 'family_notebook_unavailable', 'deletion_recovery_required',
  'billing_retention_unavailable', 'billing_account_unavailable',
]);

/** Only two read routes, with no raw URL, identifiers, headers, error text or body. */
export function beginReadDiagnostic(request: Request): void {
  if (request.method !== 'GET') return;
  const path = new URL(request.url).pathname;
  const route = path === '/v1/billing/entitlement' ? 'billing_entitlement'
    : /^\/v3\/family-notebooks\/[A-Za-z0-9_-]{1,128}\/payer$/u.test(path) ? 'family_payer' : null;
  if (route) contexts.set(request, { route, stage: 'routing' });
}
export function readStage(request: Request, stage: ReadStage): void {
  const context = contexts.get(request);
  if (context) context.stage = stage;
}
export function finishReadDiagnostic(request: Request, error?: unknown): void {
  const context = contexts.get(request);
  contexts.delete(request);
  if (!context || error === undefined) return;
  const status = error instanceof ApiError ? error.status : 500;
  if (status !== 401 && !(status >= 500 && status <= 599)) return;
  const reason = error instanceof ApiError
    ? (reasons.has(error.code) ? error.code : 'other_api_error') : 'unexpected_exception';
  // Diagnostics must never change the original response or retry a billing operation.
  try { console.warn(JSON.stringify({ event: 'neko_read_failure_v1', ...context, status, reason })); }
  catch { /* The original failure remains authoritative even if logging fails. */ }
}
