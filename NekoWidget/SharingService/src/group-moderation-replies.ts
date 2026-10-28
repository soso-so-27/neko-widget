import { authenticateGroupRequest } from './group-auth';
import type { Env } from './env';
import { ApiError,jsonResponse } from './errors';
import {groupReceiptNumber} from './group-report-number';

export const groupReplyPath=/^\/v3\/group-windows\/([A-Za-z0-9_-]{22})\/reports\/([A-Za-z0-9_-]{22})\/status$/u;
/** Signed receipt read for exactly the original device. Leaving/blocking does
 * not require group membership, restore keys, or reveal another report. Device
 * revocation/account deletion still withdraws access. No report JPEG is served. */
export async function groupReportStatus(request:Request,env:Env):Promise<Response> {
 if(env.GROUP_MODERATION_RUNTIME_ENABLED!=='YES')throw new ApiError(503,'group_moderation_disabled','Report status is unavailable.');
 const match=groupReplyPath.exec(new URL(request.url).pathname);
 if(!match||request.method!=='GET')throw new ApiError(404,'not_found','Not found.');
 const {actor,body}=await authenticateGroupRequest(request,env,0);
 if(body.length)throw new ApiError(400,'invalid_request','An empty request is required.');
 const result=await env.DB.batch([
  env.DB.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
   WHERE d.id=? AND d.person_id=? AND d.state='active' AND p.state='active') THEN 'true' ELSE 'denied' END)`).bind(actor.deviceId,actor.personId),
  env.DB.prepare('DELETE FROM group_request_nonces WHERE device_id=? AND expires_at<?').bind(actor.deviceId,actor.now),
  env.DB.prepare('INSERT INTO group_request_nonces VALUES (?,?,?)').bind(actor.deviceId,actor.nonce,actor.now+601),
  env.DB.prepare(`SELECT COALESCE(r.state,'expired') AS submissionState,k.committed_at AS receivedAt,k.evidence_expires_at AS evidenceExpiresAt,
   k.outcome,k.revision,d.reply_template AS replyTemplate,d.created_at AS repliedAt
   FROM group_report_records k LEFT JOIN group_reports r ON r.id=k.report_id
   LEFT JOIN group_report_events d ON d.report_id=k.report_id AND d.revision=k.revision
   WHERE k.report_id=? AND k.space_id=? AND k.reporter_person_id=? AND k.reporter_device_id=?
   UNION ALL SELECT r.state,r.committed_at,r.content_expires_at,'received',0,NULL,NULL FROM group_reports r
   WHERE r.id=? AND r.space_id=? AND r.reporter_person_id=? AND r.reporter_device_id=? AND r.committed_at IS NULL`)
   .bind(match[2],match[1],actor.personId,actor.deviceId,match[2],match[1],actor.personId,actor.deviceId)
 ]);
 const row=result[3]!.results[0];if(!row)throw new ApiError(404,'report_not_found','The report was not found.');
 return jsonResponse({protocolVersion:3,report:{id:match[2],receiptNumber:await groupReceiptNumber(env.DB,match[2]!),...row}});
}
