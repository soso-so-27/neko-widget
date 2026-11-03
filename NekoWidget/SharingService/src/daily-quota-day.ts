import type { Env } from './env';

// The migration schedules the next JST midnight, keeping populated UTC
// counters intact for the remainder of the current product day.
export async function dailyQuotaDay(env:Pick<Env,'DB'>,now:number):Promise<number> {
  // Gate-OFF cleanup must also work before the additive migration is applied.
  const installed=await env.DB.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='daily_quota_day_policy'").first();
  if(!installed)return Math.floor(now/86400);
  const policy=await env.DB.prepare('SELECT effective_at,utc_offset_seconds FROM daily_quota_day_policy WHERE singleton=1')
    .first<{effective_at:number;utc_offset_seconds:number}>();
  if(!policy)throw new Error('Daily quota day policy is unavailable.');
  return Math.floor((now+(now>=policy.effective_at?policy.utc_offset_seconds:0))/86400);
}
