export interface ModerationOperatorWorkerEnv {
  readonly OPERATOR_RUNTIME_ENABLED: string;
}

const operatorApiRoot = "/operator/v1";

const responseHeaders = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
} as const;

type OperatorWorkerErrorCode =
  | "not_found"
  | "operator_runtime_disabled"
  | "operator_runtime_not_ready";

function errorResponse(status: 404 | 503, code: OperatorWorkerErrorCode): Response {
  return new Response(JSON.stringify({ error: { code } }), {
    status,
    headers: responseHeaders,
  });
}

function isOperatorApiPath(pathname: string): boolean {
  return pathname === operatorApiRoot || pathname.startsWith(`${operatorApiRoot}/`);
}

export function routeModerationOperatorRequest(
  request: Request,
  env: ModerationOperatorWorkerEnv,
): Response {
  const pathname = new URL(request.url).pathname;

  if (!isOperatorApiPath(pathname)) {
    return errorResponse(404, "not_found");
  }

  // Keep this gate before headers, request bodies, authentication, or bindings.
  if (env.OPERATOR_RUNTIME_ENABLED !== "YES") {
    return errorResponse(503, "operator_runtime_disabled");
  }

  // No operator operation is exposed until its full authentication and audit path exists.
  return errorResponse(503, "operator_runtime_not_ready");
}

export default {
  fetch(request, env): Response {
    return routeModerationOperatorRequest(request, env);
  },
} satisfies ExportedHandler<ModerationOperatorWorkerEnv>;
