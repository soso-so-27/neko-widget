import { sendOperatorMail, type GroupReportMailEnv, type OperatorMailKind, type IntakeClosureReason } from '../../SharingService/src/group-report-mail';
type Kind = Exclude<OperatorMailKind, 'received' | 'undecided'> | 'normal';
export interface NotificationEnv extends GroupReportMailEnv { DB: D1Database; }
/** No personal data, credentials, provider response or report identifier in logs/mail.
 * One notification per state transition; failed/uncertain sends retry after 6h.
 * A provider response lost after delivery can cause a duplicate, never an intake change. */
export async function notifyIntakeState(env: NotificationEnv, now = Date.now(),
  send = sendOperatorMail, log: (event: object) => void = event => console.log(JSON.stringify(event))): Promise<void> {
  const row = await env.DB.prepare(`SELECT r.enabled AS renewal_enabled,r.approved_until,r.last_result,r.warning,r.lease_until,
    c.enabled,c.valid_until FROM pa_intake_renewal r JOIN pa_intake_control c USING(singleton) WHERE r.singleton=1`).first<any>();
  if (!row || !Number.isSafeInteger(now) || now < 0) throw Error('Invalid notification state');
  if (row.last_result === 'checking' && row.lease_until > now) return;
  const kind: Kind = row.last_result === 'credentials' ? 'credentials' :
    row.last_result === 'expired' || (row.approved_until > 0 && row.approved_until <= now) ||
    (row.enabled === 1 && row.valid_until <= now) ? 'expired' :
    ['closed', 'cost-unavailable', 'limits', 'budget'].includes(row.last_result) || (row.enabled === 0 && row.approved_until > 0) ? 'closed' :
    row.warning === 1 ? 'warning' : 'normal';
  const changed = await env.DB.prepare(`UPDATE pa_intake_notification SET observed_kind=?
    WHERE singleton=1 AND observed_kind<>? RETURNING singleton`).bind(kind,kind).first();
  if (changed) log({event:'preservation_intake_status',kind,at:now});
  if (kind === 'normal') {
    // A concurrent in-flight sender cannot acknowledge a later transition.
    await env.DB.prepare(`UPDATE pa_intake_notification SET delivered_kind='normal',lease_token=NULL,lease_until=0,next_attempt=0
      WHERE singleton=1 AND observed_kind='normal'`).run(); return;
  }
  if (env.GROUP_REPORT_EMAIL_ENABLED !== 'YES') return;
  const token = crypto.randomUUID();
  const claimed = await env.DB.prepare(`UPDATE pa_intake_notification SET lease_token=?,lease_until=?,next_attempt=?
    WHERE singleton=1 AND observed_kind=? AND delivered_kind<>? AND lease_until<=? AND next_attempt<=? RETURNING singleton`)
    .bind(token,now+60000,now+21600000,kind,kind,now,now).first();
  if (!claimed) return;
  try {
    const reason: IntakeClosureReason = row.last_result === 'cost-unavailable' ? 'cost-unavailable' :
      row.last_result === 'limits' ? 'limits' : row.last_result === 'budget' ? 'budget' :
      row.last_result === 'closed' ? 'unknown' : 'stopped';
    await send(env,kind,reason);
    await env.DB.prepare(`UPDATE pa_intake_notification SET delivered_kind=?,lease_token=NULL,lease_until=0
      WHERE singleton=1 AND lease_token=? AND observed_kind=?`).bind(kind,token,kind).run();
    log({event:'preservation_intake_mail',kind,result:'submitted',at:now});
  } catch {
    await env.DB.prepare(`UPDATE pa_intake_notification SET lease_token=NULL,lease_until=0 WHERE singleton=1 AND lease_token=?`).bind(token).run();
    log({event:'preservation_intake_mail',kind,result:'failed',at:now});
  }
}
