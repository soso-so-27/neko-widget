/** Fixed categories only. Provider labels, identifiers, bodies and exceptions
 * are never copied to the diagnostic. Logging cannot affect admission. */
export interface CostDiagnosticEvent {
  event: 'preservation_cost_check_v1';
  outcome: 'success' | 'failure';
  provider: 'configuration' | 'aws' | 'cloudflare';
  stage: 'configuration' | 'sign' | 'fetch' | 'body' | 'json' | 'integrity' | 'pagination' | 'coverage' | 'period' | 'freshness';
  reason: 'missing_configuration' | 'signing' | 'transport' | 'http' | 'invalid_body' | 'invalid_json'
    | 'invalid_evidence' | 'invalid_page' | 'missing_days_or_services' | 'invalid_period'
    | 'duplicate_or_invalid_amount' | 'short_or_stale_period' | 'ok';
  httpStatus: number | null; awsPages: number; awsDays: number; awsPreviousDayPresent: boolean;
  costs?: { aws30DayUsd: Record<'kms' | 's3' | 'costExplorer' | 'other', number>;
    cloudflareCycleUsd: Record<'workers' | 'r2' | 'd1' | 'logs' | 'other', number>;
    awsMonthlyUsd: number; cloudflareMonthlyUsd: number };
}
export class CostDiagnostic {
  provider: CostDiagnosticEvent['provider'] = 'configuration';
  stage: CostDiagnosticEvent['stage'] = 'configuration';
  reason: CostDiagnosticEvent['reason'] = 'missing_configuration';
  httpStatus: number | null = null;
  pages = 0; days = 0; previousDayPresent = false; succeeded = false;
  awsMonthlyUsd = 0; cloudflareMonthlyUsd = 0;
  private aws = { kms: 0, s3: 0, costExplorer: 0, other: 0 };
  private cloudflare = { workers: 0, r2: 0, d1: 0, logs: 0, other: 0 };
  addAWS(service: string, amount: number) {
    const key = service === 'AWS Key Management Service' ? 'kms'
      : service === 'Amazon Simple Storage Service' ? 's3'
      : service === 'AWS Cost Explorer' ? 'costExplorer' : 'other';
    this.aws[key] += amount;
  }
  addCloudflare(service: string, amount: number) {
    const key = /\blogs?\b|observability/i.test(service) ? 'logs'
      : /\br2\b/i.test(service) ? 'r2' : /\bd1\b/i.test(service) ? 'd1'
      : /\bworkers?\b/i.test(service) ? 'workers' : 'other';
    this.cloudflare[key] += amount;
  }
  emit(log: (event: CostDiagnosticEvent) => void) {
    try {
      log({ event: 'preservation_cost_check_v1', outcome: this.succeeded ? 'success' : 'failure',
        provider: this.provider, stage: this.stage, reason: this.succeeded ? 'ok' : this.reason,
        httpStatus: this.httpStatus, awsPages: this.pages, awsDays: this.days, awsPreviousDayPresent: this.previousDayPresent,
        ...(this.succeeded ? { costs: { aws30DayUsd: this.aws, cloudflareCycleUsd: this.cloudflare,
          awsMonthlyUsd: this.awsMonthlyUsd, cloudflareMonthlyUsd: this.cloudflareMonthlyUsd } } : {}) });
    } catch { /* Preserve the original result, including the original exception. */ }
  }
}
