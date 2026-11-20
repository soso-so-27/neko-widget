import { authenticateGroupRequest,groupAuthorizationStatements,type GroupActor } from './group-auth';
import type { Env } from './env';
import { ApiError,jsonResponse } from './errors';
import {groupReceiptNumber} from './group-report-number';
import {requireEmptyBody} from './http';

export const groupReplyPath=/^\/v3\/group-windows\/([A-Za-z0-9_-]{22})\/reports\/([A-Za-z0-9_-]{22})\/status$/u;
export const groupReportRepliesPath='/v3/group-windows/report-replies';

type GroupReportReply={
 reportId:string;windowId:string;momentId:string;receiptNumber:string|null;
 receivedAt:number;repliedAt:number|null;outcome:string;replyTemplate:string|null;
};

async function retainedReplies(env:Env,actor:GroupActor):Promise<GroupReportReply[]>{
 const only=env.ownerTrial?.window??null,excluded=env.reservedTrial?.window??null;
 const batch=await env.DB.batch<GroupReportReply>([
  ...groupAuthorizationStatements(env,actor),
  env.DB.prepare(`SELECT k.report_id AS reportId,k.space_id AS windowId,k.moment_id AS momentId,
   n.receipt_number AS receiptNumber,k.committed_at AS receivedAt,e.created_at AS repliedAt,k.outcome,e.reply_template AS replyTemplate
   FROM group_report_records k JOIN group_report_numbers n ON n.report_id=k.report_id
   LEFT JOIN group_report_events e ON e.report_id=k.report_id AND e.revision=k.revision
   WHERE k.reporter_person_id=? AND k.committed_at IS NOT NULL AND k.space_id IS NOT NULL AND k.moment_id IS NOT NULL
    AND (? IS NULL OR k.space_id=?) AND (? IS NULL OR k.space_id<>?)
    AND NOT EXISTS(SELECT 1 FROM group_report_retention_due due WHERE due.report_id=k.report_id)
   ORDER BY k.committed_at DESC,k.report_id DESC LIMIT 100`).bind(actor.personId,only,only,excluded,excluded),
 ]);
 return batch.at(-1)!.results;
}

/** A person's receipt history follows them to an active device. Receipt data
 * grants no access to a window or its evidence, even after departure. */
export async function groupReportReplies(request:Request,env:Env):Promise<Response>{
 if(request.method!=='GET')throw new ApiError(405,'method_not_allowed','Only GET is supported.');
 if(env.GROUP_MODERATION_RUNTIME_ENABLED!=='YES')throw new ApiError(503,'group_moderation_disabled','Report status is unavailable.');
 const {actor,body}=await authenticateGroupRequest(request,env,0);
 requireEmptyBody(body);
 let replies=await retainedReplies(env,actor);
 const unnumbered=replies.filter(reply=>reply.receiptNumber===null);
 if(unnumbered.length){
  // Older reports assign numbers exactly once through the existing helper.
  // Limit concurrent D1 connections, then recheck auth and retention.
  for(let i=0;i<unnumbered.length;i+=4){
   await Promise.all(unnumbered.slice(i,i+4).map(reply=>groupReceiptNumber(env.DB,reply.reportId)));
  }
  replies=await retainedReplies(env,actor);
  if(replies.some(reply=>reply.receiptNumber===null))throw new ApiError(503,'report_replies_unavailable','Report replies are unavailable.');
 }
 return jsonResponse({protocolVersion:3,replies});
}

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
  env.DB.prepare(`SELECT COALESCE(r.state,'expired') AS submissionState,k.committed_at AS receivedAt,k.evidence_expires_at AS evidenceExpiresAt,
   k.outcome,k.revision,d.reply_template AS replyTemplate,d.created_at AS repliedAt
   FROM group_report_records k LEFT JOIN group_reports r ON r.id=k.report_id
   LEFT JOIN group_report_events d ON d.report_id=k.report_id AND d.revision=k.revision
   WHERE k.report_id=? AND k.space_id=? AND k.reporter_person_id=? AND k.reporter_device_id=?
   UNION ALL SELECT r.state,r.committed_at,r.content_expires_at,'received',0,NULL,NULL FROM group_reports r
   WHERE r.id=? AND r.space_id=? AND r.reporter_person_id=? AND r.reporter_device_id=? AND r.committed_at IS NULL`)
   .bind(match[2],match[1],actor.personId,actor.deviceId,match[2],match[1],actor.personId,actor.deviceId)
 ]);
 const row=result.at(-1)!.results[0];if(!row)throw new ApiError(404,'report_not_found','The report was not found.');
 return jsonResponse({protocolVersion:3,report:{id:match[2],receiptNumber:await groupReceiptNumber(env.DB,match[2]!),...row}});
}
