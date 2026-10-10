import { routeLocalModerationEnrollment, type LocalModerationEnrollmentEnvironment } from "./moderation-operator-enrollment-local";
import { routeLocalModerationOperatorTriage, type LocalModerationTriageEnvironment } from "./moderation-operator-triage-local";

/** Trusted local composition only; neither public nor disabled Worker imports it.
 * Offline administration supplies the existing identity, roles and authority keys.
 * The host never provisions them or treats an admission receipt as authentication. */
export interface LocalModerationOperatorHostEnvironment extends LocalModerationTriageEnvironment {
  enrollment: Pick<LocalModerationEnrollmentEnvironment, "operatorID" | "scope" | "activeRoles" | "authorities">;
}
type LocalOperatorHost = (request: Request) => Promise<Response>;
const failure = (status: number) => new Response(JSON.stringify({error:status === 404 ? "not_found" : "local_operator_host_unavailable"}),
  {status,headers:{"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"}});

/** Snapshot the single installation at startup, before any request or await.
 * Mutable caller configuration cannot mix enrollment and subsequent case routes.
 * Current roles/revocations and Access authentication remain checked by each handler. */
export function createLocalModerationOperatorHost(input: LocalModerationOperatorHostEnvironment): LocalOperatorHost {
  if (input.environment !== "local" || input.runtimeEnabled !== "YES") return async () => failure(503);
  try {
    const access = Object.freeze({...input.access,subjectHmacKey:input.access.subjectHmacKey instanceof Uint8Array
      ? new Uint8Array(input.access.subjectHmacKey) : input.access.subjectHmacKey});
    const enrollment = Object.freeze({operatorID:input.enrollment.operatorID,scope:Object.freeze({...input.enrollment.scope}),
      activeRoles:Object.freeze([...input.enrollment.activeRoles]),
      authorities:Object.freeze(input.enrollment.authorities.map(key => Object.freeze({...key})))});
    const env: LocalModerationTriageEnvironment = Object.freeze({runtimeEnabled:"YES",environment:"local",db:input.db,
      origin:input.origin,rpId:input.rpId,access,...(input.reviewEvidence === undefined ? {} : {reviewEvidence:input.reviewEvidence})});
    const origin = new URL(env.origin);
    if (origin.protocol !== "https:" || origin.origin !== env.origin || origin.username || origin.password
        || origin.search || origin.hash || origin.hostname !== env.rpId
        || enrollment.scope.expectedOrigin !== env.origin || enrollment.scope.expectedRPID !== env.rpId
        || enrollment.scope.accessIssuer !== access.issuer || enrollment.scope.accessAudience !== access.audience) {
      return async () => failure(503);
    }
    const registration: LocalModerationEnrollmentEnvironment = Object.freeze({environment:"local",db:env.db,access,...enrollment});
    return async request => {
      const url = new URL(request.url);
      if (url.origin !== env.origin || url.username || url.password || url.search || url.hash) return failure(403);
      if (url.pathname === "/operator/enrollment" || url.pathname.startsWith("/operator/v1/enrollment/")) {
        return routeLocalModerationEnrollment(request,registration);
      }
      if (url.pathname === "/operator/console" || url.pathname === "/operator/v1/cases"
          || url.pathname.startsWith("/operator/v1/cases/") || url.pathname.startsWith("/operator/owner/")
          || url.pathname.startsWith("/operator/resolution/")) return routeLocalModerationOperatorTriage(request,env);
      return failure(404);
    };
  } catch { return async () => failure(503); }
}
