import type { Env } from './env';
import { runGroupReportCleanup } from './group-report-cleanup';

// Only this feature's temporary relay objects. This never follows local file
// paths or private archive/legacy prefixes and never reacts to Plus pausing.
export const GROUP_RELAY_KEY=/^groups\/v3\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{43}$/u;
const BATCH=50,RECEIPT_SECONDS=172800;
const due="state IN ('reserved','uploaded','committed') AND cleanup_at<=?";

export async function runGroupRelayCleanup(env:Env,now=Math.floor(Date.now()/1000)):Promise<void> {
  // Deploying code with gate OFF must not require this migration to be live.
  const schema=await env.DB.prepare("SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name='group_moments'").first();
  if(!schema)return;
  const expired=await env.DB.prepare(`SELECT id FROM group_moments WHERE ${due} ORDER BY created_at,id LIMIT ?`)
    .bind(now,BATCH).all<{id:string}>();
  for(const row of expired.results)await env.DB.batch([
    env.DB.prepare(`UPDATE group_moments SET state='expired',expired_at=? WHERE id=? AND ${due}`).bind(now,row.id,now),
    env.DB.prepare(`INSERT INTO group_object_deletions SELECT id,object_key,0,?,'pending' FROM group_moments WHERE id=? AND state='expired'
      ON CONFLICT(moment_id) DO NOTHING`).bind(now,row.id),
  ]);
  if(env.MEDIA) {
    const jobs=await env.DB.prepare(`SELECT q.moment_id,q.object_key,q.attempts FROM group_object_deletions q
      LEFT JOIN group_moments m ON m.id=q.moment_id
      WHERE q.state='pending' AND (m.id IS NULL OR (m.state='expired' AND m.object_key=q.object_key))
        AND q.available_at<=? ORDER BY q.available_at,q.moment_id LIMIT ?`)
      .bind(now,BATCH).all<{moment_id:string;object_key:string;attempts:number}>();
    for(const job of jobs.results) {
      if(!GROUP_RELAY_KEY.test(job.object_key))continue;
      try {
        await env.MEDIA.delete(job.object_key);
        await env.DB.prepare("UPDATE group_object_deletions SET state='completed' WHERE moment_id=? AND object_key=? AND attempts=?")
          .bind(job.moment_id,job.object_key,job.attempts).run();
      } catch {
        await env.DB.prepare("UPDATE group_object_deletions SET attempts=attempts+1,available_at=? WHERE moment_id=? AND state='pending' AND attempts=?")
          .bind(now+Math.min(3600,30*2**Math.min(job.attempts,7)),job.moment_id,job.attempts).run();
      }
    }
  }
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM group_moments WHERE id IN (SELECT m.id FROM group_moments m JOIN group_object_deletions q ON q.moment_id=m.id
      WHERE m.state='expired' AND m.expired_at<=? AND q.state='completed' ORDER BY m.expired_at,m.id LIMIT ?)`)
      .bind(now-RECEIPT_SECONDS,BATCH),
    env.DB.prepare('DELETE FROM group_notification_events WHERE id IN (SELECT id FROM group_notification_events WHERE expires_at<=? LIMIT 100)').bind(now),
    env.DB.prepare('DELETE FROM group_heart_usage WHERE rowid IN (SELECT rowid FROM group_heart_usage WHERE day_key<? LIMIT 100)').bind(Math.floor(now/86400)-2),
    env.DB.prepare('DELETE FROM group_request_nonces WHERE rowid IN (SELECT rowid FROM group_request_nonces WHERE expires_at<=? LIMIT 1000)').bind(now),
    env.DB.prepare('DELETE FROM group_mutations WHERE rowid IN (SELECT rowid FROM group_mutations WHERE expires_at<=? LIMIT 100)').bind(now),
    env.DB.prepare(`DELETE FROM group_object_deletions WHERE moment_id IN (SELECT q.moment_id FROM group_object_deletions q
      WHERE q.state='completed' AND q.available_at<=? AND NOT EXISTS (SELECT 1 FROM group_moments m WHERE m.id=q.moment_id) LIMIT 100)`)
      .bind(now-RECEIPT_SECONDS),
  ]);
  await runGroupReportCleanup(env,now);
}

// An upload whose final authorization fails may finish after cleanup has
// already deleted its reservation. Never delete a successfully committed photo.
export async function cleanLateGroupUpload(env:Env,momentId:string,objectKey:string):Promise<void> {
  if(!env.MEDIA || !GROUP_RELAY_KEY.test(objectKey))return;
  const row=await env.DB.prepare('SELECT state FROM group_moments WHERE id=? AND object_key=?').bind(momentId,objectKey).first<{state:string}>();
  if(row && row.state!=='expired')return;
  await env.DB.prepare(`INSERT INTO group_object_deletions VALUES (?,?,0,unixepoch(),'pending')
    ON CONFLICT(moment_id) DO UPDATE SET attempts=attempts+1,state='pending',available_at=unixepoch()`).bind(momentId,objectKey).run();
}
