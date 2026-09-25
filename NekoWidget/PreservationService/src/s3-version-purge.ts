import { AwsV4Signer } from 'aws4fetch';
import { ServiceError } from './contracts';
import type { RecoveryVersion } from './s3-recovery-copy';

const ownerPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const objectPattern = /^recovery\/v1\/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\/(?:photo|record|manifest|owner)\/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const regionPattern = /^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u;
const bucketPattern = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/u;
const versionPattern = /^[\x21-\x7e]{1,1024}$/u;
const unavailable = () => new ServiceError('RECOVERY_VERSION_PURGE_UNAVAILABLE', 503);

export interface S3VersionPurgeConfig {
  enabled?: string;
  region?: string;
  bucket?: string;
  expectedAccountId?: string;
  accessKeyId?: string;
  secretAccessKey?: string;
  sessionToken?: string;
}

/** Separate credentials and disabled by default. The public archive Worker
 * must never receive this binding. A 204 is only a submitted delete request;
 * the durable deletion ledger must re-list all owner versions to prove absence.
 */
export class S3VersionPurge {
  private readonly c: Required<Pick<S3VersionPurgeConfig,
    'region' | 'bucket' | 'expectedAccountId' | 'accessKeyId' | 'secretAccessKey'>>
    & Pick<S3VersionPurgeConfig, 'sessionToken'>;

  constructor(config: S3VersionPurgeConfig,
    private readonly fetcher: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> = fetch) {
    if (config.enabled !== 'YES' || !regionPattern.test(config.region ?? '')
      || !bucketPattern.test(config.bucket ?? '')
      || !/^[0-9]{12}$/u.test(config.expectedAccountId ?? '')
      || !config.accessKeyId || !config.secretAccessKey) throw unavailable();
    this.c = { region: config.region!, bucket: config.bucket!,
      expectedAccountId: config.expectedAccountId!, accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      ...(config.sessionToken ? { sessionToken: config.sessionToken } : {}) };
  }

  /** Requests permanent deletion of exactly one listed version. It cannot
   * erase a key without versionId, bypass Object Lock, or claim completion.
   * Only a future separately authorized purge executor may call this after
   * freezing an independently backed deletion manifest and fresh checks.
   */
  async requestExactVersionDeletion(ownerId: string, item: RecoveryVersion): Promise<void> {
    if (!ownerPattern.test(ownerId) || !objectPattern.test(item.key)
      || !item.key.startsWith(`recovery/v1/${ownerId}/`)
      || !versionPattern.test(item.versionId) || item.versionId === 'null'
      || typeof item.deleteMarker !== 'boolean'
      || (item.deleteMarker ? item.bytes !== null
        : !Number.isSafeInteger(item.bytes) || item.bytes === null || item.bytes < 0)) {
      throw unavailable();
    }
    const path = item.key.split('/').map(encodeURIComponent).join('/');
    const url = `https://${this.c.bucket}.s3.${this.c.region}.amazonaws.com/${path}`
      + `?versionId=${encodeURIComponent(item.versionId)}`;
    try {
      const signer = new AwsV4Signer({ url, method: 'DELETE', service: 's3', region: this.c.region,
        accessKeyId: this.c.accessKeyId, secretAccessKey: this.c.secretAccessKey,
        ...(this.c.sessionToken ? { sessionToken: this.c.sessionToken } : {}), allHeaders: true,
        headers: { 'x-amz-expected-bucket-owner': this.c.expectedAccountId } });
      const signed = await signer.sign();
      const reply = await this.fetcher(signed.url, { method: 'DELETE', headers: signed.headers,
        redirect: 'manual', signal: AbortSignal.timeout(30_000) });
      const marker = reply.headers.get('x-amz-delete-marker');
      if (reply.status !== 204 || reply.headers.get('x-amz-version-id') !== item.versionId
        || (item.deleteMarker ? marker !== 'true' : marker === 'true')) throw unavailable();
    } catch { throw unavailable(); }
  }
}
