export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: Readonly<Record<string, string | number | boolean>>,
  ) {
    super(message);
  }
}

const sharedHeaders = {
  "Cache-Control": "no-store, max-age=0",
  "Content-Type": "application/json; charset=utf-8",
  Pragma: "no-cache",
  "X-Content-Type-Options": "nosniff",
} as const;

export function jsonResponse(
  value: unknown,
  status = 200,
  additionalHeaders?: HeadersInit,
): Response {
  const headers = new Headers(sharedHeaders);
  if (additionalHeaders !== undefined) {
    new Headers(additionalHeaders).forEach((headerValue, headerName) => {
      headers.set(headerName, headerValue);
    });
  }
  return new Response(JSON.stringify(value), { status, headers });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) {
    return jsonResponse(
      { error: { code: error.code, message: error.message, ...error.details } },
      error.status,
    );
  }

  // Request bodies, credentials, secrets and signatures are intentionally not logged.
  return jsonResponse(
    { error: { code: "internal_error", message: "The request could not be completed." } },
    500,
  );
}
