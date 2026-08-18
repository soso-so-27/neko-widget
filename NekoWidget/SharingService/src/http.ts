import { ApiError } from "./errors";
import type { Env } from "./env";
import { asObject, type JsonRecord } from "./validation";

const defaultMaximumBodyBytes = 16 * 1024;

export async function readBody(
  request: Request,
  maximumBodyBytes = defaultMaximumBodyBytes,
): Promise<Uint8Array> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength)) {
      throw new ApiError(400, "invalid_content_length", "Content-Length is invalid.");
    }
    if (Number(contentLength) > maximumBodyBytes) {
      throw new ApiError(413, "body_too_large", "The request body is too large.");
    }
  }
  if (request.body === null) return new Uint8Array();

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maximumBodyBytes) {
      await reader.cancel();
      throw new ApiError(413, "body_too_large", "The request body is too large.");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}

export function parseJsonBody(request: Request, body: Uint8Array): JsonRecord {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/json.");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new ApiError(400, "invalid_json", "The JSON body is invalid UTF-8 JSON.");
  }
  return asObject(decoded);
}

export function requireEmptyBody(body: Uint8Array): void {
  if (body.length !== 0) {
    throw new ApiError(400, "body_must_be_empty", "This request must have an empty body.");
  }
}

export function rejectQuery(url: URL): void {
  if (url.search !== "") {
    throw new ApiError(400, "query_not_allowed", "Query parameters are not accepted.");
  }
}

export async function enforceRateLimit(
  env: Env,
  binding: RateLimit | undefined,
  key: string,
): Promise<void> {
  if (binding === undefined) {
    if (env.ENVIRONMENT !== "local") {
      throw new ApiError(503, "rate_limiter_unavailable", "The service is temporarily unavailable.");
    }
    return;
  }
  const result = await binding.limit({ key });
  if (!result.success) {
    throw new ApiError(429, "rate_limited", "Too many requests. Try again later.");
  }
}

export function transientNetworkKey(request: Request, suffix: string): string {
  // This value is passed only to Cloudflare's transient rate-limit binding. It is never stored in D1.
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  return `${suffix}:${address}`;
}
