import { ApiError, errorResponse, jsonResponse } from "./errors";
import type { Env } from "./env";
import {
  approveEnrollment,
  cancelEnrollment,
  completeEnrollment,
  createChallenge,
  createSpace,
  getPending,
  getStatus,
  redeemInvitation,
  revokeSpace,
} from "./handlers";
import { rejectQuery } from "./http";
import { runScheduledCleanup } from "./scheduled";

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  rejectQuery(url);
  const { pathname } = url;

  if (request.method === "GET" && pathname === "/health") {
    return jsonResponse({ status: "ok", protocolVersion: 1 });
  }
  if (request.method === "POST" && pathname === "/v1/spaces") {
    return createSpace(request, env);
  }

  const challengeMatch = pathname.match(/^\/v1\/invitations\/([^/]+)\/challenges$/u);
  if (request.method === "POST" && challengeMatch?.[1] !== undefined) {
    return createChallenge(request, env, challengeMatch[1]);
  }
  const enrollmentMatch = pathname.match(/^\/v1\/invitations\/([^/]+)\/enrollments$/u);
  if (request.method === "POST" && enrollmentMatch?.[1] !== undefined) {
    return redeemInvitation(request, env, enrollmentMatch[1]);
  }
  if (request.method === "GET" && pathname === "/v1/pairing/pending") {
    return getPending(request, env);
  }
  if (request.method === "GET" && pathname === "/v1/pairing/status") {
    return getStatus(request, env);
  }
  const approveMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/approve$/u);
  if (request.method === "POST" && approveMatch?.[1] !== undefined) {
    return approveEnrollment(request, env, approveMatch[1]);
  }
  const completeMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/complete$/u);
  if (request.method === "POST" && completeMatch?.[1] !== undefined) {
    return completeEnrollment(request, env, completeMatch[1]);
  }
  const cancelMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/cancel$/u);
  if (request.method === "POST" && cancelMatch?.[1] !== undefined) {
    return cancelEnrollment(request, env, cancelMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v1/pairing/revoke") {
    return revokeSpace(request, env);
  }
  throw new ApiError(404, "not_found", "The endpoint was not found.");
}

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      return errorResponse(error);
    }
  },
  async scheduled(_controller, env, ctx): Promise<void> {
    ctx.waitUntil(runScheduledCleanup(env));
  },
} satisfies ExportedHandler<Env>;
