import type { Env } from './env';
import { GROUP_REPORT_OBJECT_KEY } from './group-reports';

/** Separate private moderation bucket/prefix; never follows a group photo key.
 * Uses the existing cleanup invocation even with report/media gates OFF. */
export async function runGroupReportCleanup(env:Env,now=Math.floor(Date.now()/1000)):Promise<void> {
  if(!await env.DB.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='group_reports'").first())return;
  const rows=await env.DB.prepare(`SELECT id FROM group_reports WHERE
    (state IN ('reserved','uploaded') AND upload_expires_at<=?) OR (state='committed' AND content_expires_at<=?)
    ORDER BY created_at,id LIMIT 50`).bind(now,now).all<{id:string}>();
  for(const row of rows.results)await env.DB.batch([
    env.DB.prepare(`UPDATE group_reports SET state='expired',expired_at=? WHERE id=? AND
      ((state IN ('reserved','uploaded') AND upload_expires_at<=?) OR (state='committed' AND content_expires_at<=?))`)
      .bind(now,row.id,now,now),
    env.DB.prepare(`INSERT INTO group_report_object_deletions SELECT id,object_key,0,?,'pending'
      FROM group_reports WHERE id=? AND state='expired' ON CONFLICT(report_id) DO NOTHING`).bind(now,row.id),
  ]);
  if(env.MODERATION_MEDIA) {
    const jobs=await env.DB.prepare(`SELECT q.* FROM group_report_object_deletions q LEFT JOIN group_reports r ON r.id=q.report_id
      WHERE q.state='pending' AND q.available_at<=? AND (r.id IS NULL OR (r.state='expired' AND r.object_key=q.object_key))
      ORDER BY q.available_at,q.report_id LIMIT 50`).bind(now)
      .all<{report_id:string;object_key:string;attempts:number}>();
    for(const job of jobs.results) {
      if(!GROUP_REPORT_OBJECT_KEY.test(job.object_key))continue;
      try {
        await env.MODERATION_MEDIA.delete(job.object_key);
        await env.DB.prepare("UPDATE group_report_object_deletions SET state='completed' WHERE report_id=? AND object_key=? AND attempts=?")
          .bind(job.report_id,job.object_key,job.attempts).run();
      } catch {
        await env.DB.prepare("UPDATE group_report_object_deletions SET attempts=attempts+1,available_at=? WHERE report_id=? AND state='pending' AND attempts=?")
          .bind(now+Math.min(3600,30*2**Math.min(job.attempts,7)),job.report_id,job.attempts).run();
      }
    }
  }
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM group_reports WHERE id IN (SELECT r.id FROM group_reports r
      JOIN group_report_object_deletions q ON q.report_id=r.id AND q.object_key=r.object_key
      WHERE r.state='expired' AND r.expired_at<=? AND q.state='completed' LIMIT 50)`).bind(now-172800),
    env.DB.prepare('DELETE FROM group_report_access WHERE rowid IN (SELECT rowid FROM group_report_access WHERE expires_at<=? LIMIT 100)').bind(now),
    env.DB.prepare('DELETE FROM group_report_daily_usage WHERE rowid IN (SELECT rowid FROM group_report_daily_usage WHERE day_key<? LIMIT 100)').bind(Math.floor(now/86400)-2),
    env.DB.prepare(`DELETE FROM group_report_object_deletions WHERE report_id IN (SELECT q.report_id FROM group_report_object_deletions q
      WHERE q.state='completed' AND q.available_at<=? AND NOT EXISTS (SELECT 1 FROM group_reports r WHERE r.id=q.report_id) LIMIT 50)`).bind(now-172800),
  ]);
}
