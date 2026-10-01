import { WorkerEntrypoint } from "cloudflare:workers";
import { route } from "./index";
import { ApiError, errorResponse, jsonResponse } from "./errors";
import type { Env } from "./env";
import {
  billingAppleNotificationHistoryRecoveryRuntimeEnabled,
  billingSubscriptionReconciliationRuntimeEnabled,
} from "./env";
import { readBody, rejectQuery } from "./http";
import {
  effectiveBillingRuntimeGateHeaders,
  loadBillingRuntimeGate,
} from "./runtime-gate";
import { runBillingSubscriptionReconciliation } from "./billing-authority";
import { runAppleNotificationHistoryRecovery } from "./billing-notification-history-recovery";
import { LEGACY_CLEANUP_CRON } from "./scheduled";

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
      return jsonResponse({ status: "ok", protocolVersion: 1 }, 200,
        effectiveBillingRuntimeGateHeaders(env, snapshot));
    }
    // Forward the original, unconsumed request. Main applies static/runtime and
    // edge-rate guards before bounded stream reads, and authenticates the exact
    // signed bytes. It also owns nonce consumption, Apple verification and
    // entitlement. There is no family/photo fallback outside this allowlist.
    return await route(request, env, ctx);
  } catch (error) {
    return errorResponse(error);
  }
}

export class BillingGateway extends WorkerEntrypoint<Env> {
  async fetch(request: Request): Promise<Response> {
    return billingGatewayFetch(request, this.env, this.ctx);
  }
}

export default {
  fetch(): Response {
    // Even an accidentally configured public route cannot reach billing.
    return new Response(null, { status: 404 });
  },
  scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): void {
    if (!permitsEnvironment(env) || controller.cron !== LEGACY_CLEANUP_CRON) return;
    if (billingAppleNotificationHistoryRecoveryRuntimeEnabled(env)) {
      ctx.waitUntil(runAppleNotificationHistoryRecovery(env));
    }
    if (billingSubscriptionReconciliationRuntimeEnabled(env)) {
      ctx.waitUntil(runBillingSubscriptionReconciliation(env));
    }
    // This worker never runs legacy sharing, family-record, photo or APNs jobs.
  },
} satisfies ExportedHandler<Env>;
