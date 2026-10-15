import { sha256 } from "./encoding";
import { WorkerEntrypoint } from "cloudflare:workers";
import { route } from "./index";
import { ApiError, errorResponse, jsonResponse } from "./errors";
import type { Env } from "./env";
import {
  billingSubscriptionReconciliationRuntimeEnabled,
} from "./env";
import { readBody, rejectQuery } from "./http";
import {
  effectiveBillingRuntimeGateHeaders,
  loadBillingRuntimeGate,
} from "./runtime-gate";
import { reconcileBillingTransactionNow, runBillingSubscriptionReconciliation, type AppleSubscriptionStatusFetcher } from "./billing-authority";
import { fetchAppleSubscriptionStatusViaService } from "./billing-apple-client";
import { LEGACY_CLEANUP_CRON } from "./scheduled";
import { billingSandboxOwnerAdmission } from "./billing-sandbox-owner";

const BILLING_GATEWAY_HEALTH_PATH = "/v1/billing/health";

function permitsEnvironment(env: Env): boolean {
  return (env.ENVIRONMENT === "local" || env.ENVIRONMENT === "staging")
    && env.BILLING_STORE_ENVIRONMENT === "Sandbox";
}

function permitsRoute(method: string, pathname: string): boolean {
  if (method === "GET" && (pathname === BILLING_GATEWAY_HEALTH_PATH
    || pathname === "/v1/billing/entitlement")) return true;
  if (method === "POST") {
    if (pathname === "/v1/billing/accounts"
      || pathname === "/v1/billing/accounts/recover"
      || pathname === "/v1/billing/transactions"
      || pathname === "/v1/billing/apple-notifications") return true;
  }
  if ((method === "PUT" || method === "DELETE")
    && /^\/v1\/billing\/window-sponsorships\/[A-Za-z0-9_-]{22}$/u.test(pathname)) {
    return true;
  }
  return false;
}

async function billingGatewayFetch(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  try {
    const url = new URL(request.url);
    if (!permitsRoute(request.method, url.pathname)) {
      throw new ApiError(404, "not_found", "The endpoint was not found.");
    }
    rejectQuery(url);
    if (!permitsEnvironment(env)) {
      throw new ApiError(503, "billing_gateway_unavailable", "Billing is temporarily unavailable.");
    }
    if (url.pathname === BILLING_GATEWAY_HEALTH_PATH) {
      await readBody(request, 0);
      const snapshot = await loadBillingRuntimeGate(env);
      if (snapshot === null) {
        throw new ApiError(503, "billing_runtime_gate_unavailable", "Billing is temporarily unavailable.");
      }
      let ready = false;
      try { billingSandboxOwnerAdmission(env); ready = true; } catch { /* Closed policy never opens intake. */ }
      const headers = effectiveBillingRuntimeGateHeaders(env, snapshot);
      if (!ready) for (const name of ['account-bootstrap', 'transaction-ingestion', 'apple-notification-ingestion',
        'subscription-reconciliation', 'effective-entitlement', 'window-sponsorship', 'account-recovery']) {
        headers.set(`neko-runtime-billing-${name}`, 'OFF');
      }
      headers.set('neko-runtime-billing-apple-notification-history-recovery', 'OFF');
      headers.set('neko-runtime-billing-owner-admission', ready ? 'READY' : 'CLOSED');
      if (ready) headers.set('neko-runtime-billing-owner-policy-sha256',
        [...await sha256(new TextEncoder().encode(env.BILLING_SANDBOX_OWNER_ADMISSION!))]
          .map(value => value.toString(16).padStart(2, '0')).join(''));
      // Hashing may cross expiry: never advertise an expired policy as READY.
      if (ready) billingSandboxOwnerAdmission(env);
      return jsonResponse({ status: "ok", protocolVersion: 1 }, 200, headers);
    }
    // Mandatory even when the operator accidentally enables all existing gates.
    // The public caller cannot switch off owner admission with a header/body.
    billingSandboxOwnerAdmission(env);
    // Forward the original, unconsumed request. Main applies static/runtime and
    // edge-rate guards before bounded stream reads, and authenticates the exact
    // signed bytes. It also owns nonce consumption, Apple verification and
    // entitlement. There is no family/photo fallback outside this allowlist.
    return await route(request, { ...env, BILLING_SANDBOX_OWNER_ONLY_REQUIRED: 'YES' }, ctx);
  } catch (error) {
    return errorResponse(error);
  }
}

export class BillingGateway extends WorkerEntrypoint<Env> {
  async fetch(request: Request): Promise<Response> {
    return billingGatewayFetch(request, this.env, this.ctx);
  }
}

/** Private retention checks must continue after purchase-test admission ends.
 * This entrypoint cannot create accounts, ingest a client transaction, grant
 * storage, or expose a public route. The caller supplies an already signed
 * owner-to-billing link; Apple verification and durable leases remain shared.
 */
export class RetentionBillingObserver extends WorkerEntrypoint<Env & { PRESERVATION_RETENTION_REFRESH_ENABLED?: string }> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== 'POST' || url.pathname !== '/internal/retention/refresh' || url.search) {
      return new Response(null, { status: 404 });
    }
    try {
      if (!permitsEnvironment(this.env) || this.env.PRESERVATION_RETENTION_REFRESH_ENABLED !== 'YES'
          || !billingSubscriptionReconciliationRuntimeEnabled(this.env)
          || this.env.BILLING_VERIFIER_TRANSPORT !== 'private-binding'
          || typeof this.env.BILLING_VERIFIER_SERVICE?.fetch !== 'function') {
        throw new ApiError(503, 'billing_retention_unavailable', 'Billing is temporarily unavailable.');
      }
      const input = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readBody(request, 1024)));
      if (!input || Array.isArray(input) || Object.keys(input).join(',') !== 'billingAccountId'
          || typeof input.billingAccountId !== 'string'
          || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(input.billingAccountId)) {
        throw new ApiError(400, 'invalid_request', 'The request is invalid.');
      }
      const gate = await this.env.DB.prepare(`SELECT subscription_reconciliation_enabled,effective_entitlement_enabled
        FROM billing_runtime_gate WHERE singleton=1`).first<{subscription_reconciliation_enabled:number;effective_entitlement_enabled:number}>();
      if (gate?.subscription_reconciliation_enabled !== 1 || gate.effective_entitlement_enabled !== 1) {
        throw new ApiError(503, 'billing_retention_unavailable', 'Billing is temporarily unavailable.');
      }
      const deadline = new AbortController();
      const canceled = () => deadline.abort();
      const timer = setTimeout(canceled, 30_000);
      request.signal.addEventListener('abort', canceled, { once: true });
      if (request.signal.aborted) canceled();
      const verifier = this.env.BILLING_VERIFIER_SERVICE;
      const refreshEnv = verifier ? { ...this.env, BILLING_VERIFIER_SERVICE: { fetch: (input: RequestInfo | URL, init?: RequestInit) => {
        const outbound = new Request(input, init);
        return verifier.fetch(new Request(outbound, { signal: deadline.signal }));
      } } as Fetcher } : this.env;
      try { await refreshRetentionBilling(refreshEnv, input.billingAccountId); }
      finally { clearTimeout(timer); request.signal.removeEventListener('abort', canceled); }
      return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
    } catch (error) {
      return errorResponse(error instanceof ApiError ? error
        : new ApiError(503, 'billing_retention_unavailable', 'Billing is temporarily unavailable.'));
    }
  }
}

/** At most one 30-second verifier request per invocation. Repeated observations
 * rotate through oldest stale lineages; all must be fresh before returning.
 * Existing leases/backoff are never reset, including on a disconnected caller.
 */
export async function refreshRetentionBilling(env: Env, billingAccountId: string,
  fetchStatus: AppleSubscriptionStatusFetcher = fetchAppleSubscriptionStatusViaService): Promise<void> {
      const read = () => env.DB.prepare(`SELECT l.original_transaction_id,l.environment,l.subscription_group_id,
        c.source_fetched_at_ms,c.authority_stale_at_ms FROM billing_transaction_lineages l
        LEFT JOIN billing_effective_entitlement_current c ON c.original_transaction_id=l.original_transaction_id
          AND c.billing_account_id=l.billing_account_id AND c.environment=l.environment AND c.subscription_group_id=l.subscription_group_id
        WHERE l.billing_account_id=? ORDER BY c.source_fetched_at_ms,l.original_transaction_id LIMIT 9`).bind(billingAccountId)
        .all<{original_transaction_id:string;environment:string;subscription_group_id:string;source_fetched_at_ms:number|null;authority_stale_at_ms:number|null}>();
      const valid = (rows: Awaited<ReturnType<typeof read>>) => rows.results.length > 0 && rows.results.length <= 8
        && rows.results.every(row => row.environment === env.BILLING_STORE_ENVIRONMENT
          && row.subscription_group_id === env.BILLING_SUBSCRIPTION_GROUP_ID);
      const rows = await read();
      if (!valid(rows)) {
        throw new ApiError(503, 'billing_retention_unavailable', 'Billing is temporarily unavailable.');
      }
      const now = Date.now(), seconds = Math.floor(now / 1000);
      const fresh = (row: (typeof rows.results)[number], now: number) =>
        row.source_fetched_at_ms !== null && row.source_fetched_at_ms <= now
            && now - row.source_fetched_at_ms < 24 * 60 * 60 * 1000 && row.authority_stale_at_ms !== null
            && row.authority_stale_at_ms > now;
      const row = rows.results.find(row => !fresh(row, now));
      if (row) {
        // Re-create only absent jobs for expired subscriptions. Existing retry
        // backoff, request generations and in-flight leases must never reset.
        await env.DB.prepare(`INSERT OR IGNORE INTO billing_reconciliation_jobs
          (original_transaction_id,requested_at,not_before,request_generation)
          SELECT ?,?,?,COALESCE((SELECT request_generation FROM billing_effective_entitlement_current
            WHERE original_transaction_id=?),0)+1`)
          .bind(row.original_transaction_id, seconds, seconds, row.original_transaction_id).run();
        await reconcileBillingTransactionNow(env, billingAccountId, row.original_transaction_id, fetchStatus);
      }
      // The shared reconciler intentionally returns normally on backoff, a held
      // lease, or an outage. Only fresh committed observations establish success.
      const after = await read();
      if (!valid(after) || after.results.some(row => !fresh(row, Date.now()))) {
        throw new ApiError(503, 'billing_retention_unavailable', 'Billing is temporarily unavailable.');
      }
}

export default {
  fetch(): Response {
    // Even an accidentally configured public route cannot reach billing.
    return new Response(null, { status: 404 });
  },
  scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): void {
    if (!permitsEnvironment(env) || controller.cron !== LEGACY_CLEANUP_CRON) return;
    try { billingSandboxOwnerAdmission(env); } catch { return; }
    // History recovery has no owner admission and remains forbidden in this pilot.
    if (billingSubscriptionReconciliationRuntimeEnabled(env)) {
      ctx.waitUntil(runBillingSubscriptionReconciliation({ ...env, BILLING_SANDBOX_OWNER_ONLY_REQUIRED: 'YES' }));
    }
    // This worker never runs legacy sharing, family-record, photo or APNs jobs.
  },
} satisfies ExportedHandler<Env>;
