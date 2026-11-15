import { ApiError } from './errors';

/** Only called after the authenticated, signed append batch rejected a limit. */
export async function familyQuotaFailure(db: D1Database, family: string, person: string, error: unknown): Promise<void> {
  const message = error instanceof Error ? error.message : '';
  const reasons = ['total_operations', 'total_bytes', 'daily_operations', 'daily_bytes'] as const;
  const reason = reasons.find(value => message.includes('family_quota_' + value));
  if (!reason) return;
  const values = await db.prepare(`SELECT p.maximum_operations AS maximumOperations,p.maximum_bytes AS maximumBytes,
    p.daily_operations AS dailyMaximumOperations,p.daily_bytes AS dailyMaximumBytes,
    u.operations AS usedOperations,u.bytes AS usedBytes,
    COALESCE(d.operations,0) AS dailyUsedOperations,COALESCE(d.bytes,0) AS dailyUsedBytes
    FROM family_notebook_quota_policy p JOIN family_notebook_usage u ON u.family_id=?
    LEFT JOIN family_notebook_daily_usage d ON d.person_id=? AND d.day=(unixepoch()+32400)/86400
    WHERE p.singleton=1`).bind(family,person).first<Record<string,number>>();
  if (!values) throw new ApiError(503,'family_notebook_quota_unavailable','Quota accounting is unavailable.');
  throw new ApiError(409,'family_notebook_limit_exceeded','This notebook has reached its storage allowance.',
    { reason, ...values });
}
