import { CostDiagnostic, type CostDiagnosticEvent } from './intake-cost-diagnostic';
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
async function json(fetcher: CostFetch, url: RequestInfo | URL, init: RequestInit, diagnostic: CostDiagnostic): Promise<any> {
  const signal = AbortSignal.timeout(8000);
  diagnostic.stage = 'fetch'; diagnostic.reason = 'transport'; diagnostic.httpStatus = null;
  const response = await fetcher(url, { ...init, signal, redirect: 'manual' });
  diagnostic.httpStatus = response.status; diagnostic.reason = 'http';
  if (response.status === 401 || response.status === 403) throw new ServiceError('COST_CREDENTIAL_REJECTED', 503);
  if (response.status !== 200 || !response.body) throw unavailable();
  diagnostic.stage = 'body'; diagnostic.reason = 'invalid_body';
  const bytes = await readBoundedBody(response.body, 2 * 1024 * 1024, unavailable, signal);
  diagnostic.stage = 'json'; diagnostic.reason = 'invalid_json';
  const result = JSON.parse(new TextDecoder().decode(bytes));
  diagnostic.stage = 'integrity'; diagnostic.reason = 'invalid_evidence';
  return result;
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
type Interval = { from: number; to: number };
type ChargeSeries = { service: string; cost: number; intervals: Interval[] };
type BillingCycle = Map<string, ChargeSeries>;

function coveredThrough(start: number, intervals: Interval[]): number {
  let end = start;
  for (const interval of [...intervals].sort((a, b) => a.from - b.from)) {
    if (interval.from > end) break;
    end = Math.max(end, interval.to);
  }
  return end;
}

function cloudflareCosts(cf: any, account: string, started: number, diagnostic: CostDiagnostic) {
  if (cf.success !== true || (cf.errors?.length ?? 0) > 0 || (cf.messages?.length ?? 0) > 0
      || !Array.isArray(cf.result) || !cf.result.length || cf.result_info) throw unavailable();

  const subscriptions = new Map<string, Map<number, BillingCycle>>();
  for (const row of cf.result) {
    diagnostic.stage = 'integrity'; diagnostic.reason = 'invalid_evidence';
    if (row.BillingAccountId !== account || row.BillingCurrency !== 'USD' || row.ChargeCategory !== 'Usage'
        || typeof row.ServiceName !== 'string' || !row.ServiceName
        || typeof row.SubscriptionId !== 'string' || !row.SubscriptionId) throw unavailable();
    diagnostic.stage = 'period'; diagnostic.reason = 'invalid_period';
    const start = time(row.BillingPeriodStart), from = time(row.ChargePeriodStart), to = time(row.ChargePeriodEnd);
    if (start > from || from >= to || to > started) throw unavailable();

    const cycles = subscriptions.get(row.SubscriptionId) ?? new Map<number, BillingCycle>();
    subscriptions.set(row.SubscriptionId, cycles);
    const cycle = cycles.get(start) ?? new Map<string, ChargeSeries>();
    cycles.set(start, cycle);
    const key = JSON.stringify([row.ServiceName, row.ChargeDescription, row.ZoneId, row.PricingUnit]);
    const series: ChargeSeries = cycle.get(key) ?? { service: row.ServiceName, cost: 0, intervals: [] };
    cycle.set(key, series);
    diagnostic.stage = 'integrity'; diagnostic.reason = 'duplicate_or_invalid_amount';
    series.cost += positive(row.ContractedCost);
    series.intervals.push({ from, to });
  }

  let monthlyUsd = 0, coveredAt = started;
  for (const cycles of subscriptions.values()) {
    const starts = [...cycles.keys()].sort((a, b) => a - b);
    for (const [index, start] of starts.entries()) {
      const next = starts[index + 1] ?? started;
      for (const series of cycles.get(start)!.values()) {
        series.intervals.sort((a, b) => a.from - b.from);
        let previousEnd = start;
        for (const interval of series.intervals) {
          diagnostic.stage = 'period'; diagnostic.reason = 'invalid_period';
          if (interval.to > next) throw unavailable();
          diagnostic.stage = 'integrity'; diagnostic.reason = 'duplicate_or_invalid_amount';
          if (interval.from < previousEnd) throw unavailable();
          previousEnd = interval.to;
        }
      }
    }

    const currentStart = starts.at(-1)!;
    const current = cycles.get(currentStart)!;
    diagnostic.stage = 'freshness'; diagnostic.reason = 'short_or_stale_period';
    if (currentStart < started - 32 * day) throw unavailable();
    let currentForecast = 0, latest = currentStart;
    for (const series of current.values()) {
      const end = series.intervals.at(-1)!.to;
      if (end - currentStart < day || end < started - 2 * day) throw unavailable();
      latest = Math.max(latest, end);
      coveredAt = Math.min(coveredAt, end);
      currentForecast += series.cost * 31 * day / (end - currentStart);
      diagnostic.addCloudflare(series.service, series.cost);
    }

    diagnostic.stage = 'coverage'; diagnostic.reason = 'missing_days_or_services';
    const currentIntervals = [...current.values()].flatMap(series => series.intervals);
    if (coveredThrough(currentStart, currentIntervals) !== latest) throw unavailable();

    let previousForecast = 0;
    const previousStart = starts.at(-2);
    if (previousStart !== undefined) {
      const previous = cycles.get(previousStart)!;
      const previousIntervals = [...previous.values()].flatMap(series => series.intervals);
      if (coveredThrough(previousStart, previousIntervals) !== currentStart) throw unavailable();
      let previousCost = 0;
      for (const [key, series] of previous) {
        previousCost += series.cost;
        // A series present for the whole prior cycle must still be present without gaps.
        // Metered series with sparse usage need only contribute where reported.
        if (coveredThrough(previousStart, series.intervals) !== currentStart) continue;
        const intervals = current.get(key)?.intervals;
        if (!intervals || coveredThrough(currentStart, intervals) !== intervals.at(-1)!.to) throw unavailable();
      }
      previousForecast = previousCost * 31 * day / (currentStart - previousStart);
    }
    monthlyUsd += Math.max(currentForecast, previousForecast);
  }
  if (!Number.isFinite(monthlyUsd)) throw unavailable();
  return { monthlyUsd, coveredAt };
}

/** Full account totals are conservative: no unverified resource allocation,
 * credit, refund, free plan, or missing provider is treated as zero. */
export async function collectCosts(env: CostEnv, now: () => number, fetcher: CostFetch = fetch,
  log: (event: CostDiagnosticEvent) => void = () => {}): Promise<CostObservation> {
  const diagnostic = new CostDiagnostic();
  try {
    const result = await collect(env, now, fetcher, diagnostic);
    diagnostic.succeeded = true;
    return result;
  } finally { diagnostic.emit(log); }
}
async function collect(env: CostEnv, now: () => number, fetcher: CostFetch, diagnostic: CostDiagnostic): Promise<CostObservation> {
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
    diagnostic.provider = 'aws'; diagnostic.stage = 'sign'; diagnostic.reason = 'signing';
    const signed = await new AwsV4Signer({ url: 'https://ce.us-east-1.amazonaws.com/', service: 'ce', region: 'us-east-1',
      method: 'POST', body, accessKeyId: env.COST_AWS_ACCESS_KEY_ID, secretAccessKey: env.COST_AWS_SECRET_ACCESS_KEY,
      headers: { 'content-type': 'application/x-amz-json-1.1', 'x-amz-target': 'AWSInsightsIndexService.GetCostAndUsage' } }).sign();
    pages++; diagnostic.pages = pages;
    const data = await json(fetcher, signed.url, { method: signed.method, headers: signed.headers, body: signed.body ?? null }, diagnostic);
    if (!Array.isArray(data.ResultsByTime) || !data.ResultsByTime.length) throw unavailable();
    for (const period of data.ResultsByTime) {
      const from = time(period.TimePeriod?.Start), to = time(period.TimePeriod?.End);
      if (from < start || to > end || to - from !== day || typeof period.Estimated !== 'boolean'
          || !Array.isArray(period.Groups)) throw unavailable();
      dates.add(iso(from)); diagnostic.days = dates.size; diagnostic.previousDayPresent = dates.has(iso(end - day));
      for (const g of period.Groups) {
        if (!Array.isArray(g.Keys) || g.Keys.length !== 1 || typeof g.Keys[0] !== 'string'
            || !g.Keys[0].length || g.Metrics?.UnblendedCost?.Unit !== 'USD') throw unavailable();
        const key = iso(from) + ':' + g.Keys[0]; if (seen.has(key)) throw unavailable(); seen.add(key);
        const amount = positive(g.Metrics.UnblendedCost.Amount);
        aws += amount; diagnostic.addAWS(g.Keys[0], amount);
      }
    }
    diagnostic.stage = 'pagination'; diagnostic.reason = 'invalid_page';
    if (data.NextPageToken !== undefined && (typeof data.NextPageToken !== 'string' || !data.NextPageToken)) throw unavailable();
    pageToken = data.NextPageToken;
    if (pageToken && (pages >= p.maxCostPages || tokens.has(pageToken))) throw unavailable();
    if (pageToken) tokens.add(pageToken);
  } while (pageToken);
  diagnostic.stage = 'coverage'; diagnostic.reason = 'missing_days_or_services';
  if (dates.size !== 30 || !seen.size) throw unavailable();
  // Omitting dates lets the provider return each subscription's billing cycles.
  // A calendar range without the subscription anchor can return an empty set.
  diagnostic.provider = 'cloudflare';
  const cf = await json(fetcher, `https://api.cloudflare.com/client/v4/accounts/${env.COST_CLOUDFLARE_ACCOUNT_ID}/billable-usage`,
    { headers: { Authorization: `Bearer ${env.COST_CLOUDFLARE_TOKEN}` } }, diagnostic);
  const cloudflare = cloudflareCosts(cf, env.COST_CLOUDFLARE_ACCOUNT_ID!, started, diagnostic);
  diagnostic.awsMonthlyUsd = aws * 31 / 30; diagnostic.cloudflareMonthlyUsd = cloudflare.monthlyUsd;
  return { collectedAt: now(), awsMonthlyUsd: aws * 31 / 30, cloudflareMonthlyUsd: cloudflare.monthlyUsd,
    awsPages: pages, oldestCoveredAt: Math.min(end, cloudflare.coveredAt), includesEntireAccounts: true };
}
