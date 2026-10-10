import { authenticateCloudflareAccessRequest, type CloudflareAccessAuthenticationOptions } from "./moderation-operator-auth";
import { base64urlEncode, sha256 } from "./encoding";
import { hashLocalEnrollmentAuthoritySet, hashLocalEnrollmentInstallationScope,
  type LocalEnrollmentInstallationScope, type LocalEnrollmentOfflineAuthority } from "./moderation-operator-enrollment-canonical";
import { createLocalModerationEnrollmentCeremony, verifyLocalModerationEnrollmentRegistration,
  verifyLocalModerationEnrollmentPossession, type LocalModerationEnrollmentBinding } from "./moderation-operator-enrollment-ceremony";
import { createLocalInitialEnrollmentRequest, admitLocalInitialEnrollment,
  readLocalInitialEnrollmentStatus } from "./moderation-operator-enrollment-admission";
import { localModerationEnrollmentConsole } from "./moderation-operator-enrollment-console";

/** Trusted local integration only. Production Worker neither imports nor routes here.
 * Offline administration must prepare the target identity/state/role tuple and two
 * authority public keys. This handler never selects identities or grants from a body. */
export interface LocalModerationEnrollmentEnvironment {
  environment: string;
  db: D1Database;
  operatorID: string;
  scope: LocalEnrollmentInstallationScope;
  activeRoles: readonly string[];
  authorities: readonly LocalEnrollmentOfflineAuthority[];
  access: CloudflareAccessAuthenticationOptions;
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const root = "/operator/v1/enrollment";
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), {status, headers: {
  "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
}});
function fail(): never { throw new Error("local_enrollment_route_unavailable"); }

/** JSON.parse alone normalizes duplicate fields, including escaped duplicates.
 * Use the same bounded syntax inspection as the existing Access parser before
 * parsing the registration/approval package. JSON.parse still checks grammar. */
function parseUniqueObject(source: string): Record<string, unknown> {
  const stack: ({kind: "array"} | {kind: "object"; key: boolean; keys: Set<string>})[] = [];
  for (let i = 0; i < source.length; i++) {
    const char = source[i];
    if (char === '"') {
      const start = i; let escaped = false;
      for (i++; i < source.length; i++) {
        const next = source[i];
        if (escaped) { escaped = false; continue; }
        if (next === "\\") { escaped = true; continue; }
        if (next === '"') break;
      }
      if (i >= source.length) fail();
      const container = stack.at(-1);
      if (container?.kind === "object" && container.key) {
        const key: unknown = JSON.parse(source.slice(start, i + 1));
        if (typeof key !== "string" || container.keys.has(key)) fail();
        container.keys.add(key); container.key = false;
      }
    } else if (char === "{") stack.push({kind: "object", key: true, keys: new Set()});
    else if (char === "[") stack.push({kind: "array"});
    else if (char === "}" || char === "]") {
      const container = stack.pop();
      if (!container || (char === "}") !== (container.kind === "object")) fail();
    } else if (char === ",") { const container = stack.at(-1); if (container?.kind === "object") container.key = true; }
  }
  if (stack.length) fail();
  const value: unknown = JSON.parse(source);
  if (typeof value !== "object" || value === null || Array.isArray(value)) fail();
  return value as Record<string, unknown>;
}
async function body(request: Request): Promise<Record<string, unknown>> {
  if (request.headers.get("content-type") !== "application/json" || !request.body) fail();
  const reader = request.body.getReader(); let size = 0; const chunks: Uint8Array[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => { reject(new Error("body_timeout")); void reader.cancel().catch(() => {}); }, 15000); });
  try {
    while (true) {
      const part = await Promise.race([reader.read(), timeout]); if (part.done) break;
      size += part.value.byteLength; if (size > 32768) fail(); chunks.push(new Uint8Array(part.value));
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return parseUniqueObject(new TextDecoder("utf-8", {fatal: true}).decode(bytes));
  } finally { if (timer !== undefined) clearTimeout(timer); void reader.cancel().catch(() => {}); }
}
function exact(value: Record<string, unknown>, keys: readonly string[]) {
  if (Object.keys(value).length !== keys.length || keys.some((key) => !Object.hasOwn(value, key))) fail();
}

export async function routeLocalModerationEnrollment(request: Request, input: LocalModerationEnrollmentEnvironment): Promise<Response> {
  if (input.environment !== "local") return json({error: "local_enrollment_disabled"}, 503);
  // Trusted policy is copied before asynchronous hashing/authentication can yield.
  const env = {...input, scope: {...input.scope}, activeRoles: [...input.activeRoles],
    authorities: input.authorities.map((key) => ({...key})), access: {...input.access,
      subjectHmacKey: input.access.subjectHmacKey instanceof Uint8Array ? new Uint8Array(input.access.subjectHmacKey) : input.access.subjectHmacKey}};
  try {
    const url = new URL(request.url);
    if (url.origin !== env.scope.expectedOrigin || url.search !== "" || !uuid.test(env.operatorID)) fail();
    // The GET page is data-free. Every read/write API requires fresh Access and
    // browser Origin; a successful past response cannot authenticate a new call.
    if (url.pathname === "/operator/enrollment" && request.method === "GET") return localModerationEnrollmentConsole();
    const ceremony = new RegExp(`^${root}/ceremonies/(${uuid.source.slice(1, -1)})/(registration|possession|status)$`, "u").exec(url.pathname);
    const admission = new RegExp(`^${root}/requests/(${uuid.source.slice(1, -1)})/(admit|status)$`, "u").exec(url.pathname);
    if (request.method !== "POST" || !(url.pathname === `${root}/start` || ceremony || admission)) return json({error: "not_found"}, 404);
    if (request.headers.get("origin") !== env.scope.expectedOrigin
        || env.access.issuer !== env.scope.accessIssuer || env.access.audience !== env.scope.accessAudience) fail();
    let access;
    try { access = await authenticateCloudflareAccessRequest(request, env.access); }
    catch { return json({error: "operator_authentication_failed"}, 401); }
    const binding: LocalModerationEnrollmentBinding = {operatorID: env.operatorID, access,
      installationScopeSHA256: await hashLocalEnrollmentInstallationScope(env.scope),
      authoritySetSHA256: await hashLocalEnrollmentAuthoritySet(env.authorities),
      expectedOrigin: env.scope.expectedOrigin, expectedRPID: env.scope.expectedRPID};
    const policy = {binding, scope: env.scope, activeRoles: env.activeRoles, authorities: env.authorities};
    const identity = await env.db.prepare(`SELECT 1 AS admitted FROM moderation_operator_subject_identities i
      WHERE i.operator_id=? AND i.access_subject_hmac_key_version=? AND i.access_subject_hmac=?
        AND NOT EXISTS(SELECT 1 FROM moderation_operator_subject_identities n WHERE n.operator_id=i.operator_id
          AND n.access_subject_hmac_key_version>i.access_subject_hmac_key_version)
        AND EXISTS(SELECT 1 FROM moderation_operator_state_events WHERE operator_id=i.operator_id AND event_type='activated')
        AND NOT EXISTS(SELECT 1 FROM moderation_operator_state_events WHERE operator_id=i.operator_id AND event_type='revoked')
        AND ?<=unixepoch() AND ?>unixepoch()`)
      .bind(env.operatorID, access.subjectHmacKeyVersion, access.operatorSubjectHmac, access.issuedAt, access.expiresAt).first();
    if (!identity) return json({error: "operator_target_unavailable"}, 403);
    if (url.pathname === `${root}/start`) {
      if (request.body !== null) fail();
      const challenge = await createLocalModerationEnrollmentCeremony(env.db, binding);
      const userID = base64urlEncode(await sha256(new TextEncoder().encode(`NW.LOCAL.OPERATOR-USER.v1:${env.operatorID}`)));
      return json({...challenge, rpId: env.scope.expectedRPID, userID}, 202);
    }
    if (ceremony?.[2] === "status") {
      if (request.body !== null) fail();
      return json(await readLocalInitialEnrollmentStatus(env.db, {...policy, ceremonyID: ceremony[1]!}));
    }
    if (admission?.[2] === "status") {
      if (request.body !== null) fail();
      return json(await readLocalInitialEnrollmentStatus(env.db, {...policy, requestID: admission[1]!}));
    }
    const payload = await body(request);
    if (ceremony) {
      if (ceremony[2] === "registration") {
        const next = await verifyLocalModerationEnrollmentRegistration(env.db, {ceremonyID: ceremony[1]!, binding, response: payload});
        return json({...next, rpId: env.scope.expectedRPID}, 202);
      }
      await verifyLocalModerationEnrollmentPossession(env.db, {ceremonyID: ceremony[1]!, binding, response: payload});
      return json(await createLocalInitialEnrollmentRequest(env.db, {...policy, ceremonyID: ceremony[1]!}), 202);
    }
    exact(payload, ["approvals"]);
    return json(await admitLocalInitialEnrollment(env.db, {...policy, requestID: admission![1]!, approvals: payload.approvals as never}));
  } catch { return json({error: "local_enrollment_unavailable"}, 409); }
}
