import { AwsV4Signer } from 'aws4fetch';
import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';
import { renewalPolicy as p, type CostObservation } from './intake-renewal-policy';
export interface CostEnv {
  COST_AWS_ACCOUNT_ID?: string; COST_AWS_ACCESS_KEY_ID?: string; COST_AWS_SECRET_ACCESS_KEY?: string;
  COST_CLOUDFLARE_ACCOUNT_ID?: string; COST_CLOUDFLARE_TOKEN?: string;
}
export type CostFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
const day = 86400000;
const unavailable = () => new ServiceError('COST_EVIDENCE_UNAVAILABLE', 503);
async function json(fetcher: CostFetch, url: RequestInfo | URL, init: RequestInit): Promise<any> {
  const signal = AbortSignal.timeout(8000);
  const response = await fetcher(url, { ...init, signal, redirect: 'manual' });
  if (response.status !== 200 || !response.body) throw unavailable();
  const bytes = await readBoundedBody(response.body, 2 * 1024 * 1024, unavailable, signal);
  return JSON.parse(new TextDecoder().decode(bytes));
}
function positive(value: unknown): number {
  if ((typeof value !== 'string' && typeof value !== 'number') || value === '') throw unavailable();
  const result = Number(value);
  if (!Number.isFinite(result) || result < 0) throw unavailable();
  return result;
}
function time(value: unknown): number {
  if (typeof value !== 'string') throw unavailable();
  const n = Date.parse(value); if (!Number.isSafeInteger(n)) throw unavailable(); return n;
}
/** Full account totals are conservative: no unverified resource allocation,
 * credit, refund, free plan, or missing provider is treated as zero. */
export async function collectCosts(env: CostEnv, now: () => number, fetcher: CostFetch = fetch): Promise<CostObservation> {
  if (!/^\d{12}$/.test(env.COST_AWS_ACCOUNT_ID ?? '')
      || !/^[0-9a-f]{32}$/.test(env.COST_CLOUDFLARE_ACCOUNT_ID ?? '')
      || !env.COST_AWS_ACCESS_KEY_ID || !env.COST_AWS_SECRET_ACCESS_KEY || !env.COST_CLOUDFLARE_TOKEN) throw unavailable();
  const started = now(); const end = Math.floor(started / day) * day, start = end - 30 * day;
  const iso = (t: number) => new Date(t).toISOString().slice(0, 10);
  let pageToken: string | undefined, pages = 0, aws = 0;
  const seen = new Set<string>(); const dates = new Set<string>(); const tokens = new Set<string>();
  do {
    const body = JSON.stringify({ TimePeriod: { Start: iso(start), End: iso(end) }, Granularity: 'DAILY',
      Metrics: ['UnblendedCost'], GroupBy: [{ Type: 'DIMENSION', Key: 'SERVICE' }],
      Filter: { And: [{ Dimensions: { Key: 'LINKED_ACCOUNT', Values: [env.COST_AWS_ACCOUNT_ID] } },
        { Not: { Dimensions: { Key: 'RECORD_TYPE', Values: ['Credit', 'Refund'] } } }] },
      ...(pageToken ? { NextPageToken: pageToken } : {}) });
    const signed = await new AwsV4Signer({ url: 'https://ce.us-east-1.amazonaws.com/', service: 'ce', region: 'us-east-1',
      method: 'POST', body, accessKeyId: env.COST_AWS_ACCESS_KEY_ID, secretAccessKey: env.COST_AWS_SECRET_ACCESS_KEY,
      headers: { 'content-type': 'application/x-amz-json-1.1', 'x-amz-target': 'AWSInsightsIndexService.GetCostAndUsage' } }).sign();
    pages++;
    const data = await json(fetcher, signed.url, { method: signed.method, headers: signed.headers, body: signed.body ?? null });
    if (!Array.isArray(data.ResultsByTime) || !data.ResultsByTime.length) throw unavailable();
    for (const period of data.ResultsByTime) {
      const from = time(period.TimePeriod?.Start), to = time(period.TimePeriod?.End);
      if (from < start || to > end || to - from !== day || typeof period.Estimated !== 'boolean'
          || !Array.isArray(period.Groups)) throw unavailable();
      dates.add(iso(from));
      for (const g of period.Groups) {
        if (!Array.isArray(g.Keys) || g.Keys.length !== 1 || typeof g.Keys[0] !== 'string'
            || !g.Keys[0].length || g.Metrics?.UnblendedCost?.Unit !== 'USD') throw unavailable();
        const key = iso(from) + ':' + g.Keys[0]; if (seen.has(key)) throw unavailable(); seen.add(key);
        aws += positive(g.Metrics.UnblendedCost.Amount);
      }
    }
    if (data.NextPageToken !== undefined && (typeof data.NextPageToken !== 'string' || !data.NextPageToken)) throw unavailable();
    pageToken = data.NextPageToken;
    if (pageToken && (pages >= p.maxCostPages || tokens.has(pageToken))) throw unavailable();
    if (pageToken) tokens.add(pageToken);
  } while (pageToken);
  if (dates.size !== 30 || !seen.size) throw unavailable();
  // Omitting dates intentionally uses the current billing cycle: a calendar
  // range without the subscription anchor can return a misleading empty set.
  const cf = await json(fetcher, `https://api.cloudflare.com/client/v4/accounts/${env.COST_CLOUDFLARE_ACCOUNT_ID}/billable-usage`,
    { headers: { Authorization: `Bearer ${env.COST_CLOUDFLARE_TOKEN}` } });
  if (cf.success !== true || (cf.errors?.length ?? 0) > 0 || (cf.messages?.length ?? 0) > 0
      || !Array.isArray(cf.result) || !cf.result.length || cf.result_info) throw unavailable();
  const periods = new Map<string, { start: number; end: number; cost: number }>();
  const cfSeen = new Set<string>();
  for (const row of cf.result) {
    if (row.BillingAccountId !== env.COST_CLOUDFLARE_ACCOUNT_ID || row.BillingCurrency !== 'USD'
        || row.ChargeCategory !== 'Usage' || typeof row.ServiceName !== 'string' || !row.ServiceName
        || typeof row.SubscriptionId !== 'string' || !row.SubscriptionId) throw unavailable();
    const from = time(row.BillingPeriodStart), usageFrom = time(row.ChargePeriodStart), to = time(row.ChargePeriodEnd);
    if (from > usageFrom || usageFrom >= to || to > started || from < started - 32 * day) throw unavailable();
    const identity = JSON.stringify([row.SubscriptionId, row.ServiceName, row.ChargeDescription, row.ZoneId, row.PricingUnit, usageFrom, to]);
    if (cfSeen.has(identity)) throw unavailable(); cfSeen.add(identity);
    const key = row.SubscriptionId + ':' + row.ServiceName + ':' + from;
    const item = periods.get(key) ?? { start: from, end: to, cost: 0 };
    item.end = Math.max(item.end, to); item.cost += positive(row.ContractedCost); periods.set(key, item);
  }
  let cloudflare = 0, covered = end;
  for (const period of periods.values()) {
    if (period.end - period.start < day || period.end < started - 2 * day) throw unavailable();
    covered = Math.min(covered, period.end);
    cloudflare += period.cost * 31 * day / (period.end - period.start);
  }
  return { collectedAt: now(), awsMonthlyUsd: aws * 31 / 30, cloudflareMonthlyUsd: cloudflare,
    awsPages: pages, oldestCoveredAt: covered, includesEntireAccounts: true };
}
