import { authenticateGroupRequest, groupAuthorizationStatements } from './group-auth';
import { requireEmptyBody } from './http';
import { ApiError, jsonResponse } from './errors';
import type { Env } from './env';

export const familyPhotoReportRepliesPath = '/v3/family-notebooks/report-replies';

type Reply = {
  receiptNumber: string;
  receivedAt: number;
  status: 'received' | 'reviewed' | 'photo_stopped';
};

/** The existing evidence descriptor supplies ownership even after departure.
 * Report replies do not add a copy of the reporter ID or extend its retention. */
export async function familyPhotoReportReplies(request: Request, env: Env): Promise<Response> {
  if (request.method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Only GET is supported.');
  if (env.FAMILY_NOTEBOOK_API_RUNTIME_ENABLED !== 'YES' || env.GROUP_MODERATION_RUNTIME_ENABLED !== 'YES') {
    throw new ApiError(503, 'family_photo_replies_disabled', 'Report replies are unavailable.');
  }
  const { actor, body } = await authenticateGroupRequest(request, env, 0);
  requireEmptyBody(body);
  const results = await env.DB.batch<Reply>([
    ...groupAuthorizationStatements(env, actor),
    env.DB.prepare(`SELECT e.report_id AS receiptNumber, r.committed_at AS receivedAt,
        CASE r.outcome WHEN 'received' THEN 'received'
          WHEN 'photo' THEN 'photo_stopped' ELSE 'reviewed' END AS status
      FROM family_photo_reports e JOIN family_photo_report_records r USING (report_id)
      WHERE e.reporter_person_id = ? AND e.committed_at IS NOT NULL
        AND e.content_expires_at + 172800 > unixepoch()
        AND (r.retention_until IS NULL OR r.retention_until > unixepoch())
      ORDER BY e.committed_at DESC, e.report_id DESC LIMIT 100`).bind(actor.personId),
  ]);
  return jsonResponse({ schemaVersion: 1, replies: results[results.length - 1]!.results });
}
