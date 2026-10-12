import { errorResponse } from './errors';
import type { Env } from './env';
import { getMomentReportResponses } from './moments';

/** Reuse the signed, participant-scoped reader; never serve operator rows directly. */
export async function readModerationResponses(request: Request, env: Env): Promise<Response> {
  const path = new URL(request.url).pathname;
  const cursor = path === '/v2/reports/responses' ? undefined : path.slice('/v2/reports/responses/'.length);
  try { return await getMomentReportResponses(request, env, cursor); }
  catch (error) { return errorResponse(error); }
}
