import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { positiveIntegerSetting } from "./env";

interface IdempotencyRow {
  request_hash: string;
  response_status: number;
  response_json: string;
}

export async function storedIdempotentResponse(
  env: Env,
  operation: string,
  actorId: string,
  clientRequestId: string,
  requestHash: string,
): Promise<Response | null> {
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `DELETE FROM idempotency_records
      WHERE operation = ? AND actor_id = ? AND client_request_id = ? AND expires_at <= ?`,
  ).bind(operation, actorId, clientRequestId, now).run();
  const row = await env.DB.prepare(
    `SELECT request_hash, response_status, response_json
       FROM idempotency_records
      WHERE operation = ? AND actor_id = ? AND client_request_id = ?`,
  ).bind(operation, actorId, clientRequestId).first<IdempotencyRow>();
  if (row === null) return null;
  if (row.request_hash !== requestHash) {
    throw new ApiError(409, "idempotency_conflict", "The idempotency key was already used with another request.");
  }
  return jsonResponse(JSON.parse(row.response_json) as unknown, row.response_status);
}

export function idempotencyStatement(
  env: Env,
  operation: string,
  actorId: string,
  clientRequestId: string,
  spaceId: string,
  requestHash: string,
  responseStatus: number,
  responseBody: unknown,
  now: number,
): D1PreparedStatement {
  const expiresAt = now + positiveIntegerSetting(env.IDEMPOTENCY_TTL_SECONDS, 172_800);
  return env.DB.prepare(
    `INSERT INTO idempotency_records(
       operation, actor_id, client_request_id, space_id, request_hash,
       response_status, response_json, created_at, expires_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    operation,
    actorId,
    clientRequestId,
    spaceId,
    requestHash,
    responseStatus,
    JSON.stringify(responseBody),
    now,
    expiresAt,
  );
}
