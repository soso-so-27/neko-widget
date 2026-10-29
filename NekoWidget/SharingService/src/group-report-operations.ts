import type {Env} from './env';
import {sendGroupReportMail,type GroupReportMailEnv} from './group-report-mail';

async function available(db:D1Database):Promise<boolean> {
 return Boolean(await db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='group_report_records'").first());
}

/** Runs independently from evidence cleanup and the operator PC. The DB clock,
 * immutable commit target and current revision authorize each deadline action. */
export async function runGroupReportOperations(env:Env):Promise<void> {
 if(!await available(env.DB))return;
 const db=env.DB;
 // A late cron catches up. A unique obligation suppresses repeated reminders.
 await db.prepare(`INSERT INTO group_report_mail_outbox(id,report_id,kind,available_at)
  SELECT lower(hex(randomblob(16))),r.report_id,'undecided',unixepoch() FROM group_report_records r
  WHERE r.outcome='received' AND r.evidence_expires_at-172800<=unixepoch() AND r.evidence_expires_at>unixepoch()
  AND NOT EXISTS(SELECT 1 FROM group_report_mail_outbox q WHERE q.report_id=r.report_id AND q.kind='undecided')
  ORDER BY r.evidence_expires_at,r.report_id LIMIT 50 ON CONFLICT(report_id,kind) DO NOTHING`).run();
 // Never promise a restriction while the enforcement runtime is disabled.
 // Turning intake off alone does not stop processing accepted cases.
 if(env.GROUP_MODERATION_RUNTIME_ENABLED==='YES'){
  const due=await db.prepare(`SELECT report_id FROM group_report_records WHERE outcome='received'
   AND evidence_expires_at<=unixepoch() ORDER BY evidence_expires_at,report_id LIMIT 50`).all<{report_id:string}>();
  for(const row of due.results)await db.batch([
   db.prepare(`INSERT INTO group_report_events(report_id,revision,origin,outcome,reply_template)
    SELECT report_id,revision+1,'deadline','photo','review_restricted_v1' FROM group_report_records
    WHERE report_id=? AND outcome='received' AND revision=0 AND evidence_expires_at<=unixepoch()`)
    .bind(row.report_id),
   db.prepare(`INSERT INTO group_moderation_restrictions(id,case_reference,space_id,target_kind,target_id,active,revision,created_at,updated_at)
    SELECT ?, 'deadline:'||r.report_id,r.space_id,'photo',r.moment_id,1,1,unixepoch(),unixepoch()
    FROM group_report_records r JOIN group_report_events e ON e.report_id=r.report_id AND e.revision=r.revision
    WHERE r.report_id=? AND r.outcome='photo' AND e.origin='deadline'
    AND EXISTS(SELECT 1 FROM group_windows WHERE space_id=r.space_id)
    ON CONFLICT(case_reference,space_id,target_kind,target_id) DO NOTHING`).bind(crypto.randomUUID(),row.report_id),
  ]);
 }
 await purgeGroupReportRecords(db);
}

/** All deletions belong to one transaction, while a DB-validated ticket remains
 * visible. An old ticket cannot authorize purging a later re-stopped case. */
export async function purgeGroupReportRecords(db:D1Database):Promise<void> {
 const rows=await db.prepare(`SELECT report_id FROM group_report_records WHERE retention_until<=unixepoch()
  ORDER BY retention_until,report_id LIMIT 20`).all<{report_id:string}>();
 for(const {report_id:id} of rows.results){
  const caseQuery='SELECT case_reference FROM group_moderation_cases WHERE report_id=?';
  const challenges=`SELECT id FROM group_moderation_challenges WHERE case_reference IN (${caseQuery})`;
  await db.batch([
   db.prepare('DELETE FROM group_report_purge_tickets WHERE report_id=?').bind(id),
   db.prepare(`INSERT INTO group_report_purge_tickets(report_id,revision)
    SELECT report_id,revision FROM group_report_records WHERE report_id=? AND retention_until<=unixepoch()
    AND outcome IN('release','no_action')`).bind(id),
   // Abort the whole batch if a concurrent stop made this candidate ineligible.
   db.prepare("SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_report_purge_allowed WHERE report_id=?) THEN 'true' ELSE 'denied' END)").bind(id),
   db.prepare('DELETE FROM group_report_events WHERE report_id=?').bind(id),
   db.prepare(`DELETE FROM group_moderation_decisions WHERE case_reference IN (${caseQuery})`).bind(id),
   db.prepare(`DELETE FROM group_moderation_receipts WHERE challenge_id IN (${challenges})`).bind(id),
   db.prepare(`DELETE FROM group_moderation_read_events WHERE challenge_id IN (${challenges})`).bind(id),
   // A BEFORE DELETE trigger retains only the credential's maximum counter.
   db.prepare(`DELETE FROM group_moderation_consumptions WHERE challenge_id IN (${challenges})`).bind(id),
   db.prepare(`DELETE FROM group_moderation_attempts WHERE challenge_id IN (${challenges})`).bind(id),
   db.prepare(`DELETE FROM group_moderation_challenges WHERE case_reference IN (${caseQuery})`).bind(id),
   db.prepare(`DELETE FROM group_moderation_restrictions WHERE active=0 AND
    (case_reference='deadline:'||? OR case_reference IN (${caseQuery}))`).bind(id,id),
   db.prepare('DELETE FROM group_moderation_cases WHERE report_id=?').bind(id),
   db.prepare('DELETE FROM group_report_mail_outbox WHERE report_id=?').bind(id),
   db.prepare('DELETE FROM group_report_records WHERE report_id=?').bind(id),
   db.prepare('DELETE FROM group_report_numbers WHERE report_id=? AND NOT EXISTS(SELECT 1 FROM group_reports WHERE id=?)').bind(id,id),
   db.prepare('DELETE FROM group_report_purge_tickets WHERE report_id=?').bind(id),
  ]);
 }
 // Uncommitted reservations retain their previous two-day cleanup. Numbers
 // have no independent purpose after both the evidence row and record are gone.
 await db.prepare(`DELETE FROM group_report_numbers WHERE report_id IN(SELECT n.report_id FROM group_report_numbers n
  WHERE NOT EXISTS(SELECT 1 FROM group_reports WHERE id=n.report_id)
   AND NOT EXISTS(SELECT 1 FROM group_report_records WHERE report_id=n.report_id) LIMIT 50)`).run();
 // Queue-auth proofs do not belong to a decision. Drop them after two days;
 // case-bound proofs follow that case's one-year/active-stop policy above.
 const queues=await db.prepare(`SELECT id FROM group_moderation_challenges WHERE case_reference IS NULL
  AND expires_at+172800<=unixepoch() ORDER BY expires_at LIMIT 50`).all<{id:string}>();
 for(const row of queues.results)await db.batch([
  db.prepare('DELETE FROM group_moderation_consumptions WHERE challenge_id=?').bind(row.id),
  db.prepare('DELETE FROM group_moderation_attempts WHERE challenge_id=?').bind(row.id),
  db.prepare('DELETE FROM group_moderation_challenges WHERE id=?').bind(row.id),
 ]);
}

/** The sender sees only a fixed kind, not a report ID or evidence. Leases bound
 * concurrent drains; response-loss at the provider can still duplicate mail. */
export async function drainGroupReportMail(env:GroupReportMailEnv&{DB:D1Database},send=sendGroupReportMail):Promise<void> {
 if(env.GROUP_REPORT_EMAIL_ENABLED!=='YES'||!await available(env.DB))return;
 const db=env.DB;
 await db.prepare(`UPDATE group_report_mail_outbox SET state='cancelled',lease_token=NULL,lease_until=NULL
  WHERE kind='undecided' AND state IN('pending','leased') AND (lease_until IS NULL OR lease_until<=unixepoch())
  AND EXISTS(SELECT 1 FROM group_report_records r WHERE r.report_id=group_report_mail_outbox.report_id AND r.outcome<>'received')`).run();
 const jobs=await db.prepare(`SELECT id FROM group_report_mail_outbox WHERE available_at<=unixepoch()
  AND (state='pending' OR (state='leased' AND lease_until<=unixepoch())) ORDER BY available_at,id LIMIT 10`).all<{id:string}>();
 for(const job of jobs.results){
  const token=crypto.randomUUID();
  const claimed=await db.prepare(`UPDATE group_report_mail_outbox SET state='leased',lease_token=?,lease_until=unixepoch()+300,attempts=attempts+1
   WHERE id=? AND available_at<=unixepoch() AND (state='pending' OR (state='leased' AND lease_until<=unixepoch()))
   RETURNING kind,attempts`).bind(token,job.id).first<{kind:'received'|'undecided';attempts:number}>();
  if(!claimed)continue;
  try{
   await send(env,claimed.kind);
   await db.prepare(`UPDATE group_report_mail_outbox SET state='sent',sent_at=unixepoch(),lease_token=NULL,lease_until=NULL
    WHERE id=? AND state='leased' AND lease_token=?`).bind(job.id,token).run();
  }catch{
   // No provider error text, mailbox or report identifier is logged.
   await db.prepare(`UPDATE group_report_mail_outbox SET state='pending',available_at=unixepoch()+?,lease_token=NULL,lease_until=NULL
    WHERE id=? AND state='leased' AND lease_token=?`).bind(Math.min(3600,30*2**Math.min(claimed.attempts,7)),job.id,token).run();
  }
 }
}
