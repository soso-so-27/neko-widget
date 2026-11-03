import type { Env } from './env';
import { ApiError } from './errors';

// Independent of D1 snapshots and of media/content deletion prefixes.
// Provision the sentinel explicitly before enabling the guard. Missing state
// is never recreated by a request, scheduled task, or recovery invocation.
const prefix = '__billing_retention/v1/';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const digest = /^[A-Za-z0-9_-]{43}$/u;
const unavailable = () => new ApiError(503, 'billing_retention_unavailable', 'Billing is temporarily unavailable.');

export interface BillingRetentionEntry {
  version: 1;
  sequence: number;
  requestId: string;
  billingAccountId: string;
  receiptHash: string;
  reason: 'subscription-ended' | 'account-deletion';
  requestedAtMs: number;
  endedAtMs: number | null;
  cutoffMs: number;
  factsHash: string;
  expectedRevision: number;
}
interface Control { version: 1; deployment: string; sequence: number }
export type BillingRetentionEnv = Env & { BILLING_TRANSACTION_RETENTION_REQUIRED?: string };

export class BillingRetentionJournal {
  constructor(private readonly bucket: R2Bucket, private readonly deployment = 'local') {}

  private async read(key: string, maximum = 4096): Promise<{ text: string; etag: string } | null> {
    const object = await this.bucket.get(key);
    if (!object) return null;
    if (object.size < 1 || object.size > maximum) throw unavailable();
    const bytes = await object.arrayBuffer();
    if (bytes.byteLength !== object.size) throw unavailable();
    return { text: new TextDecoder('utf-8', { fatal: true }).decode(bytes), etag: object.etag };
  }

  async control(): Promise<Control & { etag: string }> {
    const object = await this.read(`${prefix}control`, 256);
    if (!object) throw unavailable();
    const value = JSON.parse(object.text) as Control;
    if (Object.keys(value).sort().join(',') !== 'deployment,sequence,version' || value.version !== 1
      || !['local','staging','production'].includes(this.deployment) || value.deployment !== this.deployment
      || !Number.isSafeInteger(value.sequence) || value.sequence < 0) throw unavailable();
    return { ...value, etag: object.etag };
  }

  private validate(value: BillingRetentionEntry): BillingRetentionEntry {
    if (!value || Object.keys(value).sort().join(',') !==
      'billingAccountId,cutoffMs,endedAtMs,expectedRevision,factsHash,reason,receiptHash,requestId,requestedAtMs,sequence,version'
      || value.version !== 1 || !Number.isSafeInteger(value.sequence) || value.sequence < 1
      || !uuid.test(value.requestId) || !uuid.test(value.billingAccountId)
      || !Number.isSafeInteger(value.expectedRevision) || value.expectedRevision < 0
      || !digest.test(value.receiptHash) || !digest.test(value.factsHash)
      || !['subscription-ended', 'account-deletion'].includes(value.reason)
      || !Number.isSafeInteger(value.requestedAtMs) || value.requestedAtMs < 1
      || !Number.isSafeInteger(value.cutoffMs) || value.cutoffMs < 1
      || value.cutoffMs > value.requestedAtMs
      || (value.reason === 'subscription-ended'
        ? !Number.isSafeInteger(value.endedAtMs) || value.endedAtMs! < 1 || value.endedAtMs! > value.cutoffMs
        : value.endedAtMs !== null)) throw unavailable();
    return value;
  }

  async entry(sequence: number): Promise<BillingRetentionEntry> {
    if (!Number.isSafeInteger(sequence) || sequence < 1) throw unavailable();
    const object = await this.read(`${prefix}entries/${String(sequence).padStart(16, '0')}`);
    if (!object) throw unavailable();
    const value = this.validate(JSON.parse(object.text) as BillingRetentionEntry);
    if (value.sequence !== sequence) throw unavailable();
    return value;
  }

  async request(requestId: string): Promise<BillingRetentionEntry | null> {
    if (!uuid.test(requestId)) throw unavailable();
    const object = await this.read(`${prefix}requests/${requestId}`);
    if (!object) return null;
    const value = this.validate(JSON.parse(object.text) as BillingRetentionEntry);
    if (value.requestId !== requestId) throw unavailable();
    const entry = await this.entry(value.sequence);
    if (JSON.stringify(entry) !== JSON.stringify(value)) throw unavailable();
    return value;
  }

  async canceled(entry: BillingRetentionEntry): Promise<boolean> {
    const value = await this.read(`${prefix}canceled/${entry.requestId}`, 256);
    if (!value) return false;
    if (value.text !== JSON.stringify({ sequence: entry.sequence, factsHash: entry.factsHash })) throw unavailable();
    return true;
  }

  async cancel(entry: BillingRetentionEntry): Promise<void> {
    await this.bucket.put(`${prefix}canceled/${entry.requestId}`,
      JSON.stringify({ sequence: entry.sequence, factsHash: entry.factsHash }),
      { onlyIf: { etagDoesNotMatch: '*' } });
    if (!await this.canceled(entry)) throw unavailable();
  }

  async completed(entry: BillingRetentionEntry): Promise<number | null> {
    const object = await this.read(`${prefix}completed/${entry.requestId}`, 512);
    if (!object) return null;
    const value = JSON.parse(object.text) as { sequence: number; receiptHash: string; completedAtMs: number };
    if (Object.keys(value).sort().join(',') !== 'completedAtMs,receiptHash,sequence'
      || value.sequence !== entry.sequence || value.receiptHash !== entry.receiptHash
      || !Number.isSafeInteger(value.completedAtMs) || value.completedAtMs < entry.requestedAtMs) throw unavailable();
    return value.completedAtMs;
  }

  async complete(entry: BillingRetentionEntry, completedAtMs: number): Promise<void> {
    if (!Number.isSafeInteger(completedAtMs) || completedAtMs < entry.requestedAtMs) throw unavailable();
    await this.bucket.put(`${prefix}completed/${entry.requestId}`,
      JSON.stringify({ sequence: entry.sequence, receiptHash: entry.receiptHash, completedAtMs }),
      { onlyIf: { etagDoesNotMatch: '*' } });
    if (await this.completed(entry) === null) throw unavailable();
  }

  /** Publish one immutable, no-raw-Apple-ID receipt before D1 is changed.
   * A crash between the entry and control writes is resumed by advancing the
   * already durable entry; it is never overwritten by a competing request.
   */
  async append(input: Omit<BillingRetentionEntry, 'version' | 'sequence'>, expectedControl?:number): Promise<BillingRetentionEntry> {
    const control = await this.control();
    if(expectedControl!==undefined && control.sequence!==expectedControl) throw new ApiError(409,'billing_retention_busy','Retry the same deletion request.');
    const previous = await this.request(input.requestId);
    if (previous && (previous.billingAccountId !== input.billingAccountId
      || previous.receiptHash !== input.receiptHash || previous.reason !== input.reason)) {
      throw new ApiError(409, 'billing_retention_request_conflict', 'The deletion request ID was already used.');
    }
    if (previous && previous.sequence <= control.sequence) return previous;
    const candidate = previous ?? this.validate({ version: 1, sequence: control.sequence + 1, ...input });
    if (candidate.sequence !== control.sequence + 1) throw unavailable();
    const key = `${prefix}entries/${String(candidate.sequence).padStart(16, '0')}`;
    await this.bucket.put(key, JSON.stringify(candidate), { onlyIf: { etagDoesNotMatch: '*' } });
    const actual = await this.entry(candidate.sequence);
    const requestKey = `${prefix}requests/${actual.requestId}`;
    await this.bucket.put(requestKey, JSON.stringify(actual), { onlyIf: { etagDoesNotMatch: '*' } });
    if (JSON.stringify(await this.request(actual.requestId)) !== JSON.stringify(actual)) throw unavailable();
    await this.bucket.put(`${prefix}control`, JSON.stringify({ version: 1, deployment: this.deployment, sequence: actual.sequence }),
      { onlyIf: { etagMatches: control.etag } });
    const published = await this.control();
    if (published.sequence < actual.sequence) throw unavailable();
    if (JSON.stringify(actual) !== JSON.stringify(candidate)) {
      throw new ApiError(409, 'billing_retention_busy', 'Retry the same deletion request.');
    }
    return actual;
  }
}

export function billingRetentionJournal(env: BillingRetentionEnv): BillingRetentionJournal {
  if (env.BILLING_TRANSACTION_RETENTION_REQUIRED !== 'YES' || !env.MEDIA) throw unavailable();
  return new BillingRetentionJournal(env.MEDIA, env.ENVIRONMENT);
}

export async function requireBillingRetentionSnapshot(env: BillingRetentionEnv): Promise<void> {
  if (env.BILLING_TRANSACTION_RETENTION_REQUIRED !== 'YES') return;
  const control = await billingRetentionJournal(env).control();
  const local = await env.DB.prepare('SELECT applied_sequence FROM billing_retention_checkpoint WHERE singleton=1')
    .first<{ applied_sequence: number }>().catch(() => null);
  if (!local || local.applied_sequence !== control.sequence) {
    throw new ApiError(503, 'billing_retention_recovery_required', 'Billing recovery is in progress.');
  }
}
