import { AwsV4Signer } from 'aws4fetch';
import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const uuidPattern = new RegExp(`^${uuid}$`, 'u');
const keyPattern = new RegExp(`^purge/v1/(${uuid})/(${uuid})/(prepared|aborted|erasing|completed)$`, 'u');
const regionPattern = /^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u;
const bucketPattern = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/u;
const versionPattern = /^[\x21-\x7e]{1,1024}$/u;
const hexPattern = /^[0-9a-f]{64}$/u;
const maxBytes = 4096;
const maxListBytes = 4 * 1024 * 1024;
const unavailable = () => new ServiceError('PURGE_INTENT_UNAVAILABLE', 503);
type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export interface S3PurgeIntentConfig {
  enabled?: string;
  region?: string;
  bucket?: string;
  expectedAccountId?: string;
  accessKeyId?: string;
  secretAccessKey?: string;
  sessionToken?: string;
}

/** This is an identifier-only record, never a photo, note, email address or
 * recipient. `prepared` must precede the D1 fence, `aborted` must precede a
 * pre-deletion thaw, `erasing` must precede the first physical delete, and
 * `completed` must follow independent re-listing.
 * This transport does not enforce those transitions or authorize deletion.
 */
export type PurgeIntentEvent = {
  version: 1;
  ownerId: string;
  intentId: string;
  stage: 'prepared' | 'aborted' | 'erasing' | 'completed';
  ownerEpoch: number;
  inventoryGeneration: number;
  retentionEpisode: number;
  retentionRevision: number;
  dueAt: number;
  recordedAt: number;
  manifestSha256: string | null;
};
export type PurgeIntentReference = {
  key: string;
  versionId: string;
  sha256: string;
  bytes: number;
};
export type PurgeIntentVersion = { key: string; versionId: string;
  deleteMarker: boolean; bytes: number | null };
export type PurgeIntentCursor = { keyMarker: string; versionIdMarker?: string };
export type PurgeIntentVersionPage = { versions: PurgeIntentVersion[];
  nextCursor: PurgeIntentCursor | null };

const objectField = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw unavailable();
  return value as Record<string, unknown>;
};
const stringField = (value: unknown): string => {
  if (typeof value !== 'string') throw unavailable();
  return value;
};
const values = (value: unknown): unknown[] => value === undefined ? []
  : Array.isArray(value) ? value : [value];
const decodedKey = (value: unknown): string => {
  const key = decodeURIComponent(stringField(value));
  if (!keyPattern.test(key)) throw unavailable();
  return key;
};

function valid(event: PurgeIntentEvent): boolean {
  return event.version === 1 && uuidPattern.test(event.ownerId)
    && uuidPattern.test(event.intentId)
    && ['prepared', 'aborted', 'erasing', 'completed'].includes(event.stage)
    && Number.isSafeInteger(event.ownerEpoch) && event.ownerEpoch >= 0
    && Number.isSafeInteger(event.inventoryGeneration) && event.inventoryGeneration >= 0
    && Number.isSafeInteger(event.retentionEpisode) && event.retentionEpisode > 0
    && Number.isSafeInteger(event.retentionRevision) && event.retentionRevision > 0
    && Number.isSafeInteger(event.dueAt) && event.dueAt > 0
    && Number.isSafeInteger(event.recordedAt) && event.recordedAt >= event.dueAt
    && (event.stage === 'prepared' || event.stage === 'aborted' ? event.manifestSha256 === null
      : typeof event.manifestSha256 === 'string' && hexPattern.test(event.manifestSha256));
}

function encoded(event: PurgeIntentEvent): Uint8Array {
  if (!valid(event)) throw unavailable();
  // Fixed field order gives retries the same bytes and checksum.
  const bytes = new TextEncoder().encode(JSON.stringify({ version: event.version,
    ownerId: event.ownerId, intentId: event.intentId, stage: event.stage,
    ownerEpoch: event.ownerEpoch, inventoryGeneration: event.inventoryGeneration,
    retentionEpisode: event.retentionEpisode, retentionRevision: event.retentionRevision,
    dueAt: event.dueAt, recordedAt: event.recordedAt, manifestSha256: event.manifestSha256 }));
  if (bytes.length === 0 || bytes.length > maxBytes) throw unavailable();
  return bytes;
}

async function checksum(bytes: Uint8Array): Promise<{ hex: string; base64: string }> {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource));
  return { hex: Array.from(hash, byte => byte.toString(16).padStart(2, '0')).join(''),
    base64: btoa(String.fromCharCode(...hash)) };
}

function version(response: Response): string {
  const value = response.headers.get('x-amz-version-id') ?? '';
  if (!versionPattern.test(value) || value === 'null') throw unavailable();
  return value;
}

/** Append-only S3 transport with read-back. Give this writer Put/Get/Head on
 * `purge/v1/*`, but never DeleteObjectVersion. The physical purge role must
 * not be able to delete this prefix, and the public Worker has no binding to
 * this class. Even a verified 200 is only storage evidence, not a purge gate.
 */
export class S3PurgeIntentStore {
  private readonly c: Required<Pick<S3PurgeIntentConfig,
    'region' | 'bucket' | 'expectedAccountId' | 'accessKeyId' | 'secretAccessKey'>>
    & Pick<S3PurgeIntentConfig, 'sessionToken'>;

  constructor(config: S3PurgeIntentConfig, private readonly fetcher: Fetcher = fetch) {
    if (config.enabled !== 'YES' || !regionPattern.test(config.region ?? '')
      || !bucketPattern.test(config.bucket ?? '')
      || !/^[0-9]{12}$/u.test(config.expectedAccountId ?? '')
      || !config.accessKeyId || !config.secretAccessKey) throw unavailable();
    this.c = { region: config.region!, bucket: config.bucket!,
      expectedAccountId: config.expectedAccountId!, accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      ...(config.sessionToken ? { sessionToken: config.sessionToken } : {}) };
  }

  private async request(method: 'PUT' | 'HEAD' | 'GET', key: string,
    headers: Record<string, string>, body?: Uint8Array, versionId?: string): Promise<Response> {
    if (!keyPattern.test(key) || (versionId !== undefined
      && (!versionPattern.test(versionId) || versionId === 'null'))) throw unavailable();
    const path = key.split('/').map(encodeURIComponent).join('/');
    const query = versionId === undefined ? '' : `?versionId=${encodeURIComponent(versionId)}`;
    const url = `https://${this.c.bucket}.s3.${this.c.region}.amazonaws.com/${path}${query}`;
    const signer = new AwsV4Signer({ url, method, service: 's3', region: this.c.region,
      accessKeyId: this.c.accessKeyId, secretAccessKey: this.c.secretAccessKey,
      ...(this.c.sessionToken ? { sessionToken: this.c.sessionToken } : {}), allHeaders: true,
      headers: { 'x-amz-expected-bucket-owner': this.c.expectedAccountId, ...headers },
      ...(body ? { body: body as BodyInit } : {}) });
    const signed = await signer.sign();
    return this.fetcher(signed.url, { method: signed.method, headers: signed.headers,
      body: signed.body ?? null, redirect: 'manual', signal: AbortSignal.timeout(30_000) });
  }

  private async head(key: string, digest: { hex: string; base64: string },
    size: number, expectedVersion?: string): Promise<PurgeIntentReference> {
    const reply = await this.request('HEAD', key, { 'x-amz-checksum-mode': 'ENABLED' },
      undefined, expectedVersion);
    if (reply.status !== 200 || reply.headers.get('x-amz-checksum-sha256') !== digest.base64
      || reply.headers.get('x-amz-checksum-type') !== 'FULL_OBJECT'
      || reply.headers.get('content-length') !== String(size)) throw unavailable();
    const versionId = version(reply);
    if (expectedVersion && versionId !== expectedVersion) throw unavailable();
    return { key, versionId, sha256: digest.hex, bytes: size };
  }

  async putOnce(event: PurgeIntentEvent): Promise<PurgeIntentReference> {
    const bytes = encoded(event);
    const key = `purge/v1/${event.ownerId}/${event.intentId}/${event.stage}`;
    const digest = await checksum(bytes);
    try {
      const reply = await this.request('PUT', key, {
        'content-type': 'application/json', 'if-none-match': '*',
        'x-amz-checksum-sha256': digest.base64,
      }, bytes);
      if (reply.status !== 200 && reply.status !== 412) throw unavailable();
      if (reply.status === 200 && reply.headers.get('x-amz-checksum-sha256') !== digest.base64) {
        throw unavailable();
      }
      const committedVersion = reply.status === 200 ? version(reply) : undefined;
      const reference = await this.head(key, digest, bytes.length, committedVersion);
      const opened = await this.readExact(reference);
      if (new TextDecoder().decode(encoded(opened)) !== new TextDecoder().decode(bytes)) {
        throw unavailable();
      }
      return reference;
    } catch { throw unavailable(); }
  }

  /** The caller must also inspect the owner prefix for extra versions and
   * delete markers before treating any one event as authoritative. */
  async readExact(reference: PurgeIntentReference): Promise<PurgeIntentEvent> {
    if (!keyPattern.test(reference.key) || !versionPattern.test(reference.versionId)
      || reference.versionId === 'null' || !hexPattern.test(reference.sha256)
      || !Number.isSafeInteger(reference.bytes) || reference.bytes < 1
      || reference.bytes > maxBytes) throw unavailable();
    try {
      const reply = await this.request('GET', reference.key, {}, undefined, reference.versionId);
      if (reply.status !== 200 || version(reply) !== reference.versionId || !reply.body) {
        throw unavailable();
      }
      const bytes = await readBoundedBody(reply.body, maxBytes, unavailable);
      if (bytes.length !== reference.bytes || (await checksum(bytes)).hex !== reference.sha256) {
        throw unavailable();
      }
      const body = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      const value: unknown = JSON.parse(body);
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw unavailable();
      const fields = Object.keys(value).sort().join(',');
      if (fields !== 'dueAt,intentId,inventoryGeneration,manifestSha256,ownerEpoch,ownerId,recordedAt,retentionEpisode,retentionRevision,stage,version') {
        throw unavailable();
      }
      const event = value as PurgeIntentEvent;
      if (!valid(event) || `purge/v1/${event.ownerId}/${event.intentId}/${event.stage}` !== reference.key
        || new TextDecoder().decode(encoded(event)) !== body) throw unavailable();
      return event;
    } catch { throw unavailable(); }
  }

  async referenceForListedVersion(item: PurgeIntentVersion): Promise<PurgeIntentReference> {
    if (item.deleteMarker || !keyPattern.test(item.key)
      || !versionPattern.test(item.versionId) || item.versionId === 'null'
      || !Number.isSafeInteger(item.bytes) || item.bytes === null
      || item.bytes < 1 || item.bytes > maxBytes) throw unavailable();
    try {
      const reply = await this.request('HEAD', item.key, { 'x-amz-checksum-mode': 'ENABLED' },
        undefined, item.versionId);
      const supplied = reply.headers.get('x-amz-checksum-sha256') ?? '';
      if (!/^[A-Za-z0-9+/]{43}=$/u.test(supplied)) throw unavailable();
      const decoded = atob(supplied);
      if (reply.status !== 200 || version(reply) !== item.versionId
        || reply.headers.get('content-length') !== String(item.bytes)
        || reply.headers.get('x-amz-checksum-type') !== 'FULL_OBJECT'
        || decoded.length !== 32 || btoa(decoded) !== supplied) throw unavailable();
      return { key: item.key, versionId: item.versionId, bytes: item.bytes,
        sha256: Array.from(decoded, char => char.charCodeAt(0).toString(16).padStart(2, '0')).join('') };
    } catch { throw unavailable(); }
  }

  /** Read-only discovery after D1 loss. The caller must follow every cursor,
   * reject unexpected duplicates/delete markers, HEAD+GET each exact version,
   * and reconcile the complete event sequence before any owner restore.
   */
  async listOwnerVersionsPage(ownerId: string,
    cursor?: PurgeIntentCursor): Promise<PurgeIntentVersionPage> {
    if (!uuidPattern.test(ownerId)) throw unavailable();
    const prefix = `purge/v1/${ownerId}/`;
    if (cursor && (!keyPattern.test(cursor.keyMarker)
      || !cursor.keyMarker.startsWith(prefix)
      || (cursor.versionIdMarker !== undefined
        && (!versionPattern.test(cursor.versionIdMarker) || cursor.versionIdMarker === 'null')))) {
      throw unavailable();
    }
    const params = new URLSearchParams({ prefix, 'max-keys': '1000', 'encoding-type': 'url' });
    params.set('versions', '');
    if (cursor) {
      params.set('key-marker', cursor.keyMarker);
      if (cursor.versionIdMarker) params.set('version-id-marker', cursor.versionIdMarker);
    }
    const url = `https://${this.c.bucket}.s3.${this.c.region}.amazonaws.com/?${params}`;
    try {
      const signer = new AwsV4Signer({ url, method: 'GET', service: 's3', region: this.c.region,
        accessKeyId: this.c.accessKeyId, secretAccessKey: this.c.secretAccessKey,
        ...(this.c.sessionToken ? { sessionToken: this.c.sessionToken } : {}), allHeaders: true,
        headers: { 'x-amz-expected-bucket-owner': this.c.expectedAccountId } });
      const signed = await signer.sign();
      const response = await this.fetcher(signed.url, { method: 'GET', headers: signed.headers,
        redirect: 'manual', signal: AbortSignal.timeout(30_000) });
      if (response.status !== 200) throw unavailable();
      const xml = new TextDecoder('utf-8', { fatal: true }).decode(
        await readBoundedBody(response.body, maxListBytes, unavailable));
      if (/<!DOCTYPE|<!ENTITY/iu.test(xml) || XMLValidator.validate(xml) !== true) throw unavailable();
      const root = objectField(new XMLParser({ parseTagValue: false }).parse(xml).ListVersionsResult);
      if (stringField(root.Name) !== this.c.bucket
        || decodeURIComponent(stringField(root.Prefix)) !== prefix
        || root.EncodingType !== 'url' || root.MaxKeys !== '1000'
        || (cursor !== undefined && (root.KeyMarker === undefined || root.VersionIdMarker === undefined))
        || (root.KeyMarker !== undefined && decodeURIComponent(stringField(root.KeyMarker))
          !== (cursor?.keyMarker ?? ''))
        || (root.VersionIdMarker !== undefined && stringField(root.VersionIdMarker)
          !== (cursor?.versionIdMarker ?? ''))
        || values(root.CommonPrefixes).length !== 0) throw unavailable();
      const truncated = stringField(root.IsTruncated);
      if (truncated !== 'true' && truncated !== 'false') throw unavailable();
      const versions: PurgeIntentVersion[] = [];
      const seen = new Set<string>();
      for (const [kind, rows] of [['Version', values(root.Version)],
        ['DeleteMarker', values(root.DeleteMarker)]] as const) {
        for (const item of rows) {
          const row = objectField(item);
          const key = decodedKey(row.Key);
          const versionId = stringField(row.VersionId);
          if (!key.startsWith(prefix) || !versionPattern.test(versionId) || versionId === 'null'
            || seen.has(`${key}\0${versionId}`)) throw unavailable();
          seen.add(`${key}\0${versionId}`);
          const size = kind === 'Version' ? Number(stringField(row.Size)) : null;
          if (kind === 'Version' && (!/^\d+$/u.test(stringField(row.Size))
            || !Number.isSafeInteger(size) || size! < 1 || size! > maxBytes)) throw unavailable();
          versions.push({ key, versionId, deleteMarker: kind === 'DeleteMarker', bytes: size });
        }
      }
      if (versions.length > 1000) throw unavailable();
      if (truncated === 'false') {
        if ((root.NextKeyMarker !== undefined && root.NextKeyMarker !== '')
          || (root.NextVersionIdMarker !== undefined && root.NextVersionIdMarker !== '')) {
          throw unavailable();
        }
        return { versions, nextCursor: null };
      }
      if (versions.length === 0) throw unavailable();
      const keyMarker = decodedKey(root.NextKeyMarker);
      const versionIdMarker = root.NextVersionIdMarker === undefined || root.NextVersionIdMarker === ''
        ? undefined : stringField(root.NextVersionIdMarker);
      if (!keyMarker.startsWith(prefix) || (versionIdMarker !== undefined
        && (!versionPattern.test(versionIdMarker) || versionIdMarker === 'null'))
        || (versions.some(item => item.key === keyMarker) && versionIdMarker === undefined)
        || (cursor?.keyMarker === keyMarker && cursor.versionIdMarker === versionIdMarker)) {
        throw unavailable();
      }
      return { versions, nextCursor: { keyMarker,
        ...(versionIdMarker === undefined ? {} : { versionIdMarker }) } };
    } catch { throw unavailable(); }
  }
}
