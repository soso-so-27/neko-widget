import type { Env } from './env';
import { ApiError,jsonResponse } from './errors';
import { authenticateGroupRequest } from './group-auth';
import { loadRuntimeGate,reportIngestionGateOpen } from './runtime-gate';
import { currentModerationReportKey } from './moderation-report-key-policy';

export const groupReportingAvailabilityPath='/v3/group-identities/reporting-availability';
/** A short-lived UI affordance, never a report grant or a membership restore.
 * Mutation routes continue to enforce every current gate independently. */
export async function groupReportingAvailability(request:Request,env:Env):Promise<Response>{
  if(request.method!=='GET')throw new ApiError(405,'method_not_allowed','Not supported.');
  const {actor,body}=await authenticateGroupRequest(request,env,0);
  if(body.length)throw new ApiError(400,'invalid_request','An empty request is required.');
  await env.DB.batch([
    env.DB.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
      WHERE d.id=? AND d.person_id=? AND d.state='active' AND p.state='active') THEN 'true' ELSE 'denied' END)`).bind(actor.deviceId,actor.personId),
    env.DB.prepare('DELETE FROM group_request_nonces WHERE device_id=? AND expires_at<?').bind(actor.deviceId,actor.now),
    env.DB.prepare('INSERT INTO group_request_nonces VALUES (?,?,?)').bind(actor.deviceId,actor.nonce,actor.now+601)
  ]);
  const enabled=env.GROUP_REPORT_RUNTIME_ENABLED==='YES'&&env.GROUP_MODERATION_RUNTIME_ENABLED==='YES'
    &&env.REPORT_INGESTION_RUNTIME_ENABLED==='YES'&&!!env.MODERATION_MEDIA
    &&reportIngestionGateOpen(await loadRuntimeGate(env))&&await currentModerationReportKey(env.DB,'moderation-v2');
  return jsonResponse({protocolVersion:3,reportingAvailable:enabled});
}
