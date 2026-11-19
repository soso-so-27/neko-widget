import type {Env} from './env';
import {sendGroupReportMail} from './group-report-mail';

// Both the decision receipt and the app's reply list use this retention window.
// e is the evidence descriptor and r is the durable report record.
export const familyPhotoReplyRetainedSQL = `e.committed_at IS NOT NULL
 AND e.content_expires_at + 172800 > unixepoch()
 AND (r.retention_until IS NULL OR r.retention_until > unixepoch())`;

/** Only the immutable reported asset is selected. A replacement asset, local
 * original, notebook operations and membership are never touched here. */
export async function advanceFamilyPhotoReportDeadlines(db:D1Database, enforcementEnabled:boolean):Promise<void>{
 await db.batch([1,5].map(day=>db.prepare(`INSERT INTO family_photo_report_reminders(report_id,day,available_at)
 SELECT report_id,?,committed_at+?*86400 FROM family_photo_report_records r
 WHERE outcome='received' AND committed_at+?*86400<=unixepoch() AND evidence_expires_at>unixepoch()
 AND NOT EXISTS(SELECT 1 FROM family_photo_report_reminders q WHERE q.report_id=r.report_id AND q.day=?)
 ORDER BY committed_at,report_id LIMIT 50 ON CONFLICT(report_id,day) DO NOTHING`).bind(day,day,day,day)));
 if(!enforcementEnabled)return;
 // DB time and the revision predicate also protect delayed or concurrent cron.
 await db.prepare(`INSERT INTO family_photo_report_deadlines(report_id,family_id,asset_id,applied_at)
 SELECT report_id,family_id,asset_id,unixepoch() FROM family_photo_report_records
 WHERE outcome='received' AND revision=0 AND evidence_expires_at<=unixepoch()
 ORDER BY evidence_expires_at,report_id LIMIT 50 ON CONFLICT(report_id) DO NOTHING`).run();
}
export async function drainFamilyPhotoReportMail(env:Env):Promise<void>{
 if(env.GROUP_REPORT_EMAIL_ENABLED!=='YES')return;
 const due=await env.DB.prepare(`SELECT q.report_id,q.day FROM family_photo_report_reminders q
 JOIN family_photo_report_records r USING(report_id)
 WHERE q.state='pending' AND q.available_at<=unixepoch() AND (q.day=0 OR r.outcome='received')
 ORDER BY q.available_at,q.report_id,q.day LIMIT 10`).all<{report_id:string;day:number}>();
 for(const row of due.results){
  const claimed=await env.DB.prepare(`UPDATE family_photo_report_reminders SET available_at=unixepoch()+300
   WHERE report_id=? AND day=? AND state='pending' AND available_at<=unixepoch() RETURNING available_at`)
   .bind(row.report_id,row.day).first<{available_at:number}>();
  if(!claimed)continue;
  try{
   await sendGroupReportMail(env,row.day===0?'received':'undecided');
   await env.DB.prepare(`UPDATE family_photo_report_reminders SET state='sent'
    WHERE report_id=? AND day=? AND state='pending' AND available_at=?`)
    .bind(row.report_id,row.day,claimed.available_at).run();
  }catch{/* Fixed mail remains retryable; never log provider text or report data. */}
 }
}
/** Expiry is independent of operator-PC availability and of intake switches. */
export async function cleanupFamilyPhotoReportEvidence(env:Env):Promise<void>{
 const late=await env.DB.prepare(`SELECT d.report_id,d.object_key FROM family_photo_report_object_deletions d
 WHERE d.available_at<=unixepoch() AND NOT EXISTS(SELECT 1 FROM family_photo_reports r
 WHERE r.report_id=d.report_id AND r.object_key=d.object_key AND r.state<>'expired'
 AND COALESCE(r.content_expires_at,r.upload_expires_at)>unixepoch()) ORDER BY d.available_at LIMIT 50`)
 .all<{report_id:string;object_key:string}>();
 if(late.results.length&&!env.MODERATION_MEDIA)throw Error('family_report_cleanup_unavailable');
 for(const row of late.results){
  if(!/^family\/reports\/v1\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{32}$/.test(row.object_key)
   ||row.object_key.split('/')[3]!==row.report_id)throw Error('family_report_cleanup_scope');
  await env.MODERATION_MEDIA!.delete(row.object_key);
  if(!await env.MODERATION_MEDIA!.head(row.object_key))await env.DB.prepare(
   'DELETE FROM family_photo_report_object_deletions WHERE object_key=? AND report_id=?').bind(row.object_key,row.report_id).run();
 }
 const rows=await env.DB.prepare(`SELECT report_id,object_key FROM family_photo_reports
 WHERE next_cleanup_at<=unixepoch() AND ((state='reserved' AND upload_expires_at<=unixepoch()) OR
 (state IN('committed','expired') AND COALESCE(content_expires_at,upload_expires_at)<=unixepoch()))
 ORDER BY next_cleanup_at,COALESCE(content_expires_at,upload_expires_at),report_id LIMIT 50`).all<{report_id:string;object_key:string}>();
 if(rows.results.length&&!env.MODERATION_MEDIA)throw Error('family_report_cleanup_unavailable');
 for(const row of rows.results){
  if(!/^family\/reports\/v1\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{32}$/.test(row.object_key))throw Error('family_report_cleanup_scope');
  await env.DB.prepare("UPDATE family_photo_reports SET state='expired',next_cleanup_at=unixepoch()+60 WHERE report_id=? AND object_key=?")
   .bind(row.report_id,row.object_key).run();
  await env.MODERATION_MEDIA!.delete(row.object_key);
  // Retain the expired descriptor for two days to catch an in-flight late PUT.
  if(!await env.MODERATION_MEDIA!.head(row.object_key))await env.DB.prepare(`DELETE FROM family_photo_reports
   WHERE report_id=? AND object_key=? AND state='expired'
   AND COALESCE(content_expires_at,upload_expires_at)<unixepoch()-172800`)
   .bind(row.report_id,row.object_key).run();
 }
 await env.DB.prepare('DELETE FROM family_photo_report_deliveries WHERE rowid IN (SELECT rowid FROM family_photo_report_deliveries WHERE expires_at<=unixepoch() LIMIT 100)').run();
 await env.DB.prepare(`INSERT INTO family_photo_report_purge_tickets(report_id,revision)
  SELECT report_id,revision FROM family_photo_report_records WHERE outcome<>'photo' AND retention_until<=unixepoch()
  ORDER BY retention_until,report_id LIMIT 50`).run();
 // Case-free queue challenges expire separately; preserve authenticator counters.
 const queue=await env.DB.prepare(`SELECT id FROM family_photo_moderation_challenges
  WHERE case_reference IS NULL AND expires_at<unixepoch()-172800 ORDER BY expires_at LIMIT 50`).all<{id:string}>();
 for(const q of queue.results)await env.DB.batch([
  ...['receipts','read_events','consumptions','attempts'].map(table=>env.DB.prepare(`DELETE FROM family_photo_moderation_${table} WHERE challenge_id=?`).bind(q.id)),
  env.DB.prepare('DELETE FROM family_photo_moderation_challenges WHERE id=?').bind(q.id)
 ]);
}
export async function familyPhotoStopped(db:D1Database,familyID:string,assetID:string):Promise<boolean>{
 return Boolean(await db.prepare(`SELECT 1 FROM family_photo_report_records
 WHERE family_id=? AND asset_id=? AND outcome='photo' LIMIT 1`).bind(familyID,assetID).first());
}
