import type { Env } from './env';

const twoDays = 172800;
const fiveDays = 432000;
const missedHeartbeatAfter = 900;
const openCases = { group: 'group_report_records', family: 'family_photo_report_records' } as const;
type Scope = keyof typeof openCases;

export async function withReportDeadlineHeartbeat(env: Env, scope: Scope, run: () => Promise<void>): Promise<void> {
  await run();
  if (env.REPORT_DEADLINE_MONITOR_ENABLED !== 'YES' || env.GROUP_MODERATION_RUNTIME_ENABLED !== 'YES') return;
  await env.DB.prepare(`INSERT INTO report_deadline_heartbeat(kind,completed_at) VALUES(?,unixepoch())
    ON CONFLICT(kind) DO UPDATE SET completed_at=MAX(completed_at,excluded.completed_at)`).bind(scope).run();
}

export async function reportDeadlineHealth(db: D1Database, scope: Scope, expectHeartbeat: boolean, now: number) {
  const state = await db.prepare(`SELECT
    (SELECT committed_at FROM ${openCases[scope]} WHERE outcome='received' ORDER BY committed_at LIMIT 1) AS oldest,
    (SELECT completed_at FROM report_deadline_heartbeat WHERE kind=?) AS completedAt`)
    .bind(scope).first<{ oldest: number | null; completedAt: number | null }>();
  if (!state) throw new Error('report_deadline_health_unavailable');
  const oldestAgeSeconds = state.oldest === null ? null : Math.max(0, now - state.oldest);
  const heartbeatMissing = expectHeartbeat && (state.completedAt === null || state.completedAt < now - missedHeartbeatAfter);
  const review = oldestAgeSeconds !== null && oldestAgeSeconds >= twoDays;
  return { scope, oldestAgeSeconds, completedAt: state.completedAt, heartbeatMissing,
    severity: oldestAgeSeconds !== null && oldestAgeSeconds >= fiveDays ? 'urgent' : (review || heartbeatMissing ? 'warning' : 'ok') };
}

export async function monitorReportDeadlines(env: Env, expectGroupHeartbeat: boolean): Promise<void> {
  if (env.REPORT_DEADLINE_MONITOR_ENABLED !== 'YES') return;
  const now = Math.floor(Date.now() / 1000);
  const enabled = env.GROUP_MODERATION_RUNTIME_ENABLED === 'YES';
  const snapshots = await Promise.all([
    reportDeadlineHealth(env.DB, 'group', enabled && expectGroupHeartbeat, now),
    reportDeadlineHealth(env.DB, 'family', enabled, now),
  ]);
  for (const state of snapshots) {
    const event = JSON.stringify({ event: 'neko_report_deadline_watch_v1', ...state });
    if (state.severity !== 'ok') console.warn(event);
    else if (now % 900 < 60) console.info(event);
  }
}
