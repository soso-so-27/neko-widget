import { AwsV4Signer } from 'aws4fetch';
import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';
import { purgeManifestChunkBytes, purgeManifestChunkDigest,
  purgeManifestRootDigest, buildOwnerPurgeManifest, type PurgeManifest,
  type PurgeManifestChunk } from './owner-purge-manifest';
import type { OwnerCloudInventory } from './owner-cloud-inventory';
import type { PrimaryInventory } from './owner-primary-reconciliation';
import type { PurgeFence } from './owner-purge-fence';
import type { OwnerPhoto } from './owner-photo-inventory';
import type { RecoveryVersion } from './s3-recovery-copy';
import type { S3PurgeIntentConfig } from './s3-purge-intent';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const keyPattern = new RegExp(`^purge-plan/v1/(${uuid})/(${uuid})/(?:header|chunk/[0-9]{6})$`, 'u');
const uuidPattern = new RegExp(`^${uuid}$`, 'u');
const hex = /^[0-9a-f]{64}$/u;
const versionPattern = /^[\x21-\x7e]{1,1024}$/u;
const regionPattern = /^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u;
const bucketPattern = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/u;
const maxBytes = 512 * 1024;
const maxListBytes = 4 * 1024 * 1024;
const unavailable = () => new ServiceError('PURGE_MANIFEST_COPY_UNAVAILABLE', 503);
type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export type PurgeManifestCopyReference = {
  key: string; versionId: string; sha256: string; bytes: number;
};
export type PurgeManifestCopyVersion = { key: string; versionId: string;
  deleteMarker: boolean; bytes: number | null };
export type PurgeManifestCopyCursor = { keyMarker: string; versionIdMarker?: string };
export type PurgeManifestCopyPage = { versions: PurgeManifestCopyVersion[];
  nextCursor: PurgeManifestCopyCursor | null };

const field = (value: unknown): string => {
  if (typeof value !== 'string') throw unavailable();
  return value;
};
const object = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw unavailable();
  return value as Record<string, unknown>;
};
const rows = (value: unknown): unknown[] => value === undefined ? []
  : Array.isArray(value) ? value : [value];

const checksum = async (bytes: Uint8Array): Promise<{ hex: string; base64: string }> => {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource));
  return { hex: [...digest].map(byte => byte.toString(16).padStart(2, '0')).join(''),
    base64: btoa(String.fromCharCode(...digest)) };
};
const version = (reply: Response): string => {
  const id = reply.headers.get('x-amz-version-id') ?? '';
  if (!versionPattern.test(id) || id === 'null') throw unavailable();
  return id;
};
const headerBytes = (m: PurgeManifest): Uint8Array => new TextEncoder().encode(JSON.stringify({
  version: 1, ownerId: m.ownerId, intentId: m.intentId, ownerEpoch: m.ownerEpoch,
  inventoryGeneration: m.inventoryGeneration, recordDigest: m.recordDigest,
  records: m.records, r2Count: m.r2Count, s3Count: m.s3Count,
  r2Bytes: m.r2Bytes, s3Bytes: m.s3Bytes, sha256: m.sha256,
  chunks: m.chunks.map(({ ordinal, kind, sha256, bytes, items }) =>
    ({ ordinal, kind, sha256, bytes, itemCount: items.length })),
}));

/** External, versioned copy of a proposed deletion plan. These methods only
 * write/read evidence; they cannot authorize or perform deletion. Give this
 * role Put/Get/Head but never DeleteObjectVersion on purge-plan/v1/*.
 */
export class S3PurgeManifestStore {
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

  private async request(method: 'PUT' | 'GET' | 'HEAD', key: string,
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

  private async putOnce(key: string, bytes: Uint8Array): Promise<PurgeManifestCopyReference> {
    if (!keyPattern.test(key) || bytes.length < 1 || bytes.length > maxBytes) throw unavailable();
    const hash = await checksum(bytes);
    try {
      const reply = await this.request('PUT', key, { 'content-type': 'application/json',
        'if-none-match': '*', 'x-amz-checksum-sha256': hash.base64 }, bytes);
      if (reply.status !== 200 && reply.status !== 412) throw unavailable();
      if (reply.status === 200 && reply.headers.get('x-amz-checksum-sha256') !== hash.base64) {
        throw unavailable();
      }
      const committedVersion = reply.status === 200 ? version(reply) : undefined;
      const head = await this.request('HEAD', key, { 'x-amz-checksum-mode': 'ENABLED' },
        undefined, committedVersion);
      if (head.status !== 200 || head.headers.get('x-amz-checksum-sha256') !== hash.base64
        || head.headers.get('x-amz-checksum-type') !== 'FULL_OBJECT'
        || head.headers.get('content-length') !== String(bytes.length)
        || (committedVersion !== undefined && version(head) !== committedVersion)) throw unavailable();
      const reference = { key, versionId: version(head), sha256: hash.hex, bytes: bytes.length };
      const opened = await this.readExact(reference);
      if (opened.length !== bytes.length || opened.some((value, i) => value !== bytes[i])) {
        throw unavailable();
      }
      return reference;
    } catch { throw unavailable(); }
  }

  async putChunk(manifest: PurgeManifest, index: number): Promise<PurgeManifestCopyReference> {
    if (manifest?.version !== 1 || !uuidPattern.test(manifest.ownerId)
      || !uuidPattern.test(manifest.intentId) || !Array.isArray(manifest.chunks)
      || !Number.isSafeInteger(index) || index < 0 || index >= manifest.chunks.length
      || index >= 1564) throw unavailable();
    const chunk = manifest.chunks[index]!;
    if (chunk.ordinal !== index || !['r2', 's3'].includes(chunk.kind)
      || !Array.isArray(chunk.items) || chunk.items.length < 1 || chunk.items.length > 128
      || !hex.test(chunk.sha256)) throw unavailable();
    const bytes = purgeManifestChunkBytes(manifest.ownerId, manifest.intentId, chunk);
    if (bytes.length !== chunk.bytes || bytes.length > maxBytes
      || await purgeManifestChunkDigest(bytes) !== chunk.sha256) throw unavailable();
    return this.putOnce(`purge-plan/v1/${manifest.ownerId}/${manifest.intentId}/chunk/${String(index).padStart(6, '0')}`, bytes);
  }

  async putHeader(manifest: PurgeManifest): Promise<PurgeManifestCopyReference> {
    if (manifest?.version !== 1 || !uuidPattern.test(manifest.ownerId)
      || !uuidPattern.test(manifest.intentId) || !hex.test(manifest.sha256)
      || !Array.isArray(manifest.chunks) || manifest.chunks.length > 1564
      || await purgeManifestRootDigest(manifest) !== manifest.sha256) throw unavailable();
    const bytes = headerBytes(manifest);
    return this.putOnce(`purge-plan/v1/${manifest.ownerId}/${manifest.intentId}/header`, bytes);
  }

  /** Exact-version read-back. On D1 restore, the caller must also list every
   * version under this intent and reject duplicates/delete markers before
   * trusting the plan. This method alone is not that proof.
   */
  async readExact(reference: PurgeManifestCopyReference): Promise<Uint8Array> {
    if (!keyPattern.test(reference.key) || !versionPattern.test(reference.versionId)
      || reference.versionId === 'null' || !hex.test(reference.sha256)
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
      return bytes;
    } catch { throw unavailable(); }
  }

  private async readListed(item: PurgeManifestCopyVersion): Promise<Uint8Array> {
    if (!keyPattern.test(item.key) || item.deleteMarker || item.bytes === null
      || !Number.isSafeInteger(item.bytes) || item.bytes < 1 || item.bytes > maxBytes
      || !versionPattern.test(item.versionId) || item.versionId === 'null') throw unavailable();
    const reply = await this.request('GET', item.key, {}, undefined, item.versionId);
    if (reply.status !== 200 || version(reply) !== item.versionId || !reply.body) {
      throw unavailable();
    }
    const bytes = await readBoundedBody(reply.body, maxBytes, unavailable);
    if (bytes.length !== item.bytes) throw unavailable();
    return bytes;
  }

  /** Discover all versions of an owner plan. The caller must follow every
   * cursor and reject duplicates, markers, and unexpected keys before using
   * any S3 copy as a post-Time-Travel erasure checkpoint.
   */
  async listOwnerVersionsPage(ownerId: string, intentId: string,
    cursor?: PurgeManifestCopyCursor): Promise<PurgeManifestCopyPage> {
    if (!uuidPattern.test(ownerId) || !uuidPattern.test(intentId)) throw unavailable();
    const prefix = `purge-plan/v1/${ownerId}/${intentId}/`;
    if (cursor && (!keyPattern.test(cursor.keyMarker)
      || !cursor.keyMarker.startsWith(prefix)
      || (cursor.versionIdMarker !== undefined
        && (!versionPattern.test(cursor.versionIdMarker)
          || cursor.versionIdMarker === 'null')))) throw unavailable();
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
      if (response.status !== 200 || !response.body) throw unavailable();
      const xml = new TextDecoder('utf-8', { fatal: true }).decode(
        await readBoundedBody(response.body, maxListBytes, unavailable));
      if (/<!DOCTYPE|<!ENTITY/iu.test(xml) || XMLValidator.validate(xml) !== true) throw unavailable();
      const root = object(new XMLParser({ parseTagValue: false }).parse(xml).ListVersionsResult);
      if (field(root.Name) !== this.c.bucket
        || decodeURIComponent(field(root.Prefix)) !== prefix
        || root.EncodingType !== 'url' || root.MaxKeys !== '1000'
        || (cursor !== undefined && (root.KeyMarker === undefined
          || root.VersionIdMarker === undefined))
        || (root.KeyMarker !== undefined
          && decodeURIComponent(field(root.KeyMarker)) !== (cursor?.keyMarker ?? ''))
        || (root.VersionIdMarker !== undefined
          && field(root.VersionIdMarker) !== (cursor?.versionIdMarker ?? ''))
        || rows(root.CommonPrefixes).length !== 0) throw unavailable();
      const truncated = field(root.IsTruncated);
      if (truncated !== 'true' && truncated !== 'false') throw unavailable();
      const versions: PurgeManifestCopyVersion[] = [];
      const seen = new Set<string>();
      for (const [kind, entries] of [['Version', rows(root.Version)],
        ['DeleteMarker', rows(root.DeleteMarker)]] as const) {
        for (const entry of entries) {
          const row = object(entry);
          const key = decodeURIComponent(field(row.Key));
          const versionId = field(row.VersionId);
          if (!keyPattern.test(key) || !key.startsWith(prefix)
            || !versionPattern.test(versionId) || versionId === 'null'
            || seen.has(`${key}\0${versionId}`)) throw unavailable();
          seen.add(`${key}\0${versionId}`);
          const size = kind === 'Version' ? Number(field(row.Size)) : null;
          if (kind === 'Version' && (!/^\d+$/u.test(field(row.Size))
            || !Number.isSafeInteger(size) || size! < 1 || size! > maxBytes)) {
            throw unavailable();
          }
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
      const keyMarker = decodeURIComponent(field(root.NextKeyMarker));
      const versionIdMarker = root.NextVersionIdMarker === undefined
        || root.NextVersionIdMarker === '' ? undefined : field(root.NextVersionIdMarker);
      if (!keyPattern.test(keyMarker) || !keyMarker.startsWith(prefix)
        || (versionIdMarker !== undefined && (!versionPattern.test(versionIdMarker)
          || versionIdMarker === 'null'))
        || (versions.some(item => item.key === keyMarker) && versionIdMarker === undefined)
        || (cursor?.keyMarker === keyMarker && cursor.versionIdMarker === versionIdMarker)) {
        throw unavailable();
      }
      return { versions, nextCursor: { keyMarker,
        ...(versionIdMarker === undefined ? {} : { versionIdMarker }) } };
    } catch { throw unavailable(); }
  }

  /** Full external audit for an already built plan. This is intentionally
   * not a per-request Worker operation: a large owner exceeds the Free
   * subrequest budget and must be audited in bounded durable work units.
   */
  async verifyPublished(manifest: PurgeManifest): Promise<void> {
    try {
      if (manifest?.version !== 1 || !uuidPattern.test(manifest.ownerId)
        || !uuidPattern.test(manifest.intentId) || !hex.test(manifest.sha256)
        || !Array.isArray(manifest.chunks) || manifest.chunks.length > 1564
        || await purgeManifestRootDigest(manifest) !== manifest.sha256) {
        throw unavailable();
      }
      const expected = new Map<string, Uint8Array>();
      for (let i = 0; i < manifest.chunks.length; i++) {
        const chunk = manifest.chunks[i]!;
        const bytes = purgeManifestChunkBytes(manifest.ownerId, manifest.intentId, chunk);
        if (chunk.ordinal !== i || bytes.length !== chunk.bytes
          || bytes.length < 1 || bytes.length > maxBytes
          || await purgeManifestChunkDigest(bytes) !== chunk.sha256) throw unavailable();
        expected.set(`purge-plan/v1/${manifest.ownerId}/${manifest.intentId}/chunk/${String(i).padStart(6, '0')}`, bytes);
      }
      const header = headerBytes(manifest);
      if (header.length < 1 || header.length > maxBytes) throw unavailable();
      expected.set(`purge-plan/v1/${manifest.ownerId}/${manifest.intentId}/header`, header);
      const seenKeys = new Set<string>();
      const seenCursors = new Set<string>();
      let cursor: PurgeManifestCopyCursor | undefined;
      do {
        const page = await this.listOwnerVersionsPage(manifest.ownerId, manifest.intentId, cursor);
        for (const item of page.versions) {
          const bytes = expected.get(item.key);
          if (!bytes || item.deleteMarker || item.bytes !== bytes.length
            || seenKeys.has(item.key)) throw unavailable();
          seenKeys.add(item.key);
          const hash = await checksum(bytes);
          const opened = await this.readExact({ key: item.key, versionId: item.versionId,
            sha256: hash.hex, bytes: bytes.length });
          if (opened.length !== bytes.length || opened.some((value, i) => value !== bytes[i])) {
            throw unavailable();
          }
        }
        cursor = page.nextCursor ?? undefined;
        if (cursor) {
          const token = `${cursor.keyMarker}\0${cursor.versionIdMarker ?? ''}`;
          if (seenCursors.has(token)) throw unavailable();
          seenCursors.add(token);
        }
      } while (cursor);
      if (seenKeys.size !== expected.size) throw unavailable();
    } catch { throw unavailable(); }
  }

  /** Rebuild the entire canonical plan from versioned S3 alone after a D1
   * rollback. The expected root must come from the independently replayed
   * erasing event. This never authorizes deletion by itself.
   */
  async loadPublished(ownerId: string, intentId: string,
    expectedRoot: string): Promise<PurgeManifest> {
    try {
      if (!uuidPattern.test(ownerId) || !uuidPattern.test(intentId)
        || !hex.test(expectedRoot)) throw unavailable();
      const listed = new Map<string, PurgeManifestCopyVersion>();
      const cursors = new Set<string>();
      let cursor: PurgeManifestCopyCursor | undefined;
      do {
        const page = await this.listOwnerVersionsPage(ownerId, intentId, cursor);
        for (const item of page.versions) {
          if (item.deleteMarker || listed.has(item.key) || listed.size >= 1565) {
            throw unavailable();
          }
          listed.set(item.key, item);
        }
        cursor = page.nextCursor ?? undefined;
        if (cursor) {
          const token = `${cursor.keyMarker}\0${cursor.versionIdMarker ?? ''}`;
          if (cursors.has(token)) throw unavailable();
          cursors.add(token);
        }
      } while (cursor);
      const headerKey = `purge-plan/v1/${ownerId}/${intentId}/header`;
      const listedHeader = listed.get(headerKey);
      if (!listedHeader) throw unavailable();
      const rawHeader = await this.readListed(listedHeader);
      const header = object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(rawHeader)));
      if (Object.keys(header).sort().join(',') !==
        'chunks,intentId,inventoryGeneration,ownerEpoch,ownerId,r2Bytes,r2Count,recordDigest,records,s3Bytes,s3Count,sha256,version'
        || header.version !== 1 || header.ownerId !== ownerId
        || header.intentId !== intentId || header.sha256 !== expectedRoot
        || !Array.isArray(header.chunks) || header.chunks.length > 1564
        || listed.size !== header.chunks.length + 1) throw unavailable();
      const chunks: PurgeManifestChunk[] = [];
      for (let i = 0; i < header.chunks.length; i++) {
        const descriptor = object(header.chunks[i]);
        if (Object.keys(descriptor).sort().join(',') !==
          'bytes,itemCount,kind,ordinal,sha256'
          || descriptor.ordinal !== i || !['r2', 's3'].includes(String(descriptor.kind))
          || !hex.test(String(descriptor.sha256))
          || !Number.isSafeInteger(descriptor.bytes) || Number(descriptor.bytes) < 1
          || Number(descriptor.bytes) > maxBytes
          || !Number.isSafeInteger(descriptor.itemCount)
          || Number(descriptor.itemCount) < 1 || Number(descriptor.itemCount) > 128) {
          throw unavailable();
        }
        const key = `purge-plan/v1/${ownerId}/${intentId}/chunk/${String(i).padStart(6, '0')}`;
        const item = listed.get(key);
        if (!item || item.bytes !== descriptor.bytes) throw unavailable();
        const raw = await this.readListed(item);
        if ((await checksum(raw)).hex !== descriptor.sha256) throw unavailable();
        const chunk = object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw)));
        if (Object.keys(chunk).sort().join(',') !== 'intentId,items,kind,ordinal,ownerId,version'
          || chunk.version !== 1 || chunk.ownerId !== ownerId || chunk.intentId !== intentId
          || chunk.ordinal !== i || chunk.kind !== descriptor.kind
          || !Array.isArray(chunk.items) || chunk.items.length !== descriptor.itemCount) {
          throw unavailable();
        }
        chunks.push({ ordinal: i, kind: descriptor.kind as 'r2' | 's3',
          sha256: descriptor.sha256 as string, bytes: descriptor.bytes as number,
          items: chunk.items as (OwnerPhoto | RecoveryVersion)[] });
      }
      const candidate = { version: 1, ownerId, intentId,
        ownerEpoch: header.ownerEpoch as number,
        inventoryGeneration: header.inventoryGeneration as number,
        recordDigest: header.recordDigest as string,
        records: header.records as number, r2Count: header.r2Count as number,
        s3Count: header.s3Count as number, r2Bytes: header.r2Bytes as number,
        s3Bytes: header.s3Bytes as number, chunks, sha256: expectedRoot } as PurgeManifest;
      if (new TextDecoder().decode(headerBytes(candidate)) !== new TextDecoder().decode(rawHeader)) {
        throw unavailable();
      }
      const r2 = chunks.filter(chunk => chunk.kind === 'r2')
        .flatMap(chunk => chunk.items as OwnerPhoto[]);
      const s3 = chunks.filter(chunk => chunk.kind === 's3')
        .flatMap(chunk => chunk.items as RecoveryVersion[]);
      const primary: PrimaryInventory = { ownerId, epoch: candidate.ownerEpoch,
        generation: candidate.inventoryGeneration, records: candidate.records,
        photos: r2.length, photoKeys: r2.map(item => item.key),
        recordDigest: candidate.recordDigest };
      const cloud: OwnerCloudInventory = { ownerId, r2Objects: r2,
        r2Bytes: r2.reduce((sum, item) => sum + item.bytes, 0), s3Versions: s3,
        s3VersionBytes: s3.reduce((sum, item) => sum + (item.bytes ?? 0), 0),
        s3DeleteMarkers: s3.filter(item => item.deleteMarker).length };
      const rebuilt = await buildOwnerPurgeManifest({ ownerId, fenceId: intentId,
        ownerEpoch: candidate.ownerEpoch,
        inventoryGeneration: candidate.inventoryGeneration } as PurgeFence, primary, cloud);
      if (rebuilt.sha256 !== expectedRoot || rebuilt.chunks.length !== chunks.length
        || new TextDecoder().decode(headerBytes(rebuilt)) !== new TextDecoder().decode(rawHeader)) {
        throw unavailable();
      }
      return rebuilt;
    } catch { throw unavailable(); }
  }
}
