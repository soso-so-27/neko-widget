import { AwsV4Signer } from 'aws4fetch';
import { ServiceError } from './contracts';
import type { S3PurgeIntentConfig } from './s3-purge-intent';
import type { PurgeManifestCopyVersion } from './s3-purge-manifest';
import type { PurgeIntentVersion } from './s3-purge-intent';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const planKey = new RegExp(`^purge-plan/v1/(${uuid})/(${uuid})/(?:header|chunk/[0-9]{6})$`, 'u');
const eventKey = new RegExp(`^purge/v1/(${uuid})/(${uuid})/(?:prepared|aborted|erasing|completed)$`, 'u');
const regionPattern = /^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u;
const bucketPattern = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/u;
const versionPattern = /^[\x21-\x7e]{1,1024}$/u;
const unavailable = () => new ServiceError('PURGE_EVIDENCE_DELETE_UNAVAILABLE', 503);

type Config = S3PurgeIntentConfig;
type Item = Pick<PurgeManifestCopyVersion | PurgeIntentVersion,
  'key' | 'versionId' | 'deleteMarker' | 'bytes'>;

/** A separate cleanup role. Never give these credentials to the archive
 * Worker or the recovery-version purge role. This only submits an exact
 * version deletion; an age-gated controller must prove completion, walk all
 * versions and re-list the prefix before declaring evidence cleaned.
 */
export class S3PurgeEvidenceDelete {
  private readonly c: Required<Pick<Config,
    'region' | 'bucket' | 'expectedAccountId' | 'accessKeyId' | 'secretAccessKey'>>
    & Pick<Config, 'sessionToken'>;

  constructor(config: Config,
    private readonly fetcher: (input: RequestInfo | URL, init?: RequestInit)
      => Promise<Response> = fetch) {
    if (config.enabled !== 'YES' || !regionPattern.test(config.region ?? '')
      || !bucketPattern.test(config.bucket ?? '')
      || !/^[0-9]{12}$/u.test(config.expectedAccountId ?? '')
      || !config.accessKeyId || !config.secretAccessKey) throw unavailable();
    this.c = { region: config.region!, bucket: config.bucket!,
      expectedAccountId: config.expectedAccountId!, accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      ...(config.sessionToken ? { sessionToken: config.sessionToken } : {}) };
  }

  private async request(ownerId: string, intentId: string,
    item: Item, kind: 'plan' | 'event'): Promise<void> {
    const match = (kind === 'plan' ? planKey : eventKey).exec(item.key);
    if (!ownerPattern.test(ownerId) || !ownerPattern.test(intentId)
      || match?.[1] !== ownerId || match[2] !== intentId
      || !versionPattern.test(item.versionId) || item.versionId === 'null'
      || typeof item.deleteMarker !== 'boolean'
      || (item.deleteMarker ? item.bytes !== null
        : !Number.isSafeInteger(item.bytes) || item.bytes === null || item.bytes < 1)) {
      throw unavailable();
    }
    const path = item.key.split('/').map(encodeURIComponent).join('/');
    const url = `https://${this.c.bucket}.s3.${this.c.region}.amazonaws.com/${path}`
      + `?versionId=${encodeURIComponent(item.versionId)}`;
    try {
      const signer = new AwsV4Signer({ url, method: 'DELETE', service: 's3',
        region: this.c.region, accessKeyId: this.c.accessKeyId,
        secretAccessKey: this.c.secretAccessKey,
        ...(this.c.sessionToken ? { sessionToken: this.c.sessionToken } : {}),
        allHeaders: true,
        headers: { 'x-amz-expected-bucket-owner': this.c.expectedAccountId } });
      const signed = await signer.sign();
      const reply = await this.fetcher(signed.url, { method: 'DELETE',
        headers: signed.headers, redirect: 'manual', signal: AbortSignal.timeout(30_000) });
      const marker = reply.headers.get('x-amz-delete-marker');
      if (reply.status !== 204 || reply.headers.get('x-amz-version-id') !== item.versionId
        || (item.deleteMarker ? marker !== 'true' : marker === 'true')) throw unavailable();
    } catch { throw unavailable(); }
  }

  requestPlanVersionDeletion(ownerId: string, intentId: string,
    item: PurgeManifestCopyVersion): Promise<void> {
    return this.request(ownerId, intentId, item, 'plan');
  }

  requestEventVersionDeletion(ownerId: string, intentId: string,
    item: PurgeIntentVersion): Promise<void> {
    return this.request(ownerId, intentId, item, 'event');
  }
}
