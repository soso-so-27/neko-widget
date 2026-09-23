import { AwsV4Signer } from 'aws4fetch';
import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';

/** Opaque, already-encrypted recovery objects. Versioning is not WORM:
 * an administrator, deletion role or lifecycle rule can still erase versions.
 * A restore manifest, owner/credential state and deletion ledger are needed.
 */
export interface S3RecoveryConfig {
  enabled?: string;
  region?: string;
  bucket?: string;
  expectedAccountId?: string;
  accessKeyId?: string;
  secretAccessKey?: string;
  sessionToken?: string;
}
type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
type BoundConfig = { region: string; bucket: string; accountId: string; access: string;
  secret: string; session?: string };
export type RecoveryObject = { key: string; sha256: string; bytes: number; versionId: string };

const maxObjectBytes = 32 * 1024 * 1024;
const regionPattern = /^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u;
const bucketPattern = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/u;
const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const recoveryKeyPattern = new RegExp(`^recovery/v1/${uuid}/(?:photo|record|manifest)/${uuid}$`, 'u');
const hexPattern = /^[0-9a-f]{64}$/u;
const versionPattern = /^[\x21-\x7e]{1,1024}$/u;
const unavailable = () => new ServiceError('RECOVERY_COPY_UNAVAILABLE', 503);
const b64 = (value: Uint8Array) => btoa(String.fromCharCode(...value));

function configured(config: S3RecoveryConfig): BoundConfig {
  if (config.enabled !== 'YES' || !regionPattern.test(config.region ?? '')
    || !bucketPattern.test(config.bucket ?? '') || !/^[0-9]{12}$/u.test(config.expectedAccountId ?? '')
    || !config.accessKeyId || !config.secretAccessKey) throw unavailable();
  return { region: config.region!, bucket: config.bucket!, accountId: config.expectedAccountId!,
    access: config.accessKeyId, secret: config.secretAccessKey,
    ...(config.sessionToken ? { session: config.sessionToken } : {}) };
}
function objectUrl(config: BoundConfig, key: string, versionId?: string): string {
  if (!recoveryKeyPattern.test(key)) throw unavailable();
  const path = key.split('/').map(encodeURIComponent).join('/');
  const query = versionId === undefined ? '' : `?versionId=${encodeURIComponent(versionId)}`;
  return `https://${config.bucket}.s3.${config.region}.amazonaws.com/${path}${query}`;
}
async function checksum(value: Uint8Array): Promise<{ hex: string; base64: string }> {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', value as BufferSource));
  return { hex: [...bytes].map(byte => byte.toString(16).padStart(2, '0')).join(''), base64: b64(bytes) };
}
function version(response: Response): string {
  const value = response.headers.get('x-amz-version-id') ?? '';
  if (!versionPattern.test(value) || value === 'null') throw unavailable();
  return value;
}

/** Requires a versioned, private S3 bucket. S3 validates the supplied SHA-256
 * checksum; HEAD confirms the committed version and checksum before success.
 * Writer IAM must not have DeleteObjectVersion; bucket lifecycle and purge-role
 * separation require independent verification before enabling this as backup.
 */
export class S3RecoveryCopy {
  private readonly config: BoundConfig;
  constructor(config: S3RecoveryConfig, private readonly fetcher: Fetcher = fetch) {
    this.config = configured(config);
  }

  private async request(method: 'PUT' | 'HEAD' | 'GET', key: string,
    headers: Record<string, string>, body?: Uint8Array, versionId?: string): Promise<Response> {
    const url = objectUrl(this.config, key, versionId);
    const signer = new AwsV4Signer({ url, method, service: 's3', region: this.config.region,
      accessKeyId: this.config.access, secretAccessKey: this.config.secret,
      ...(this.config.session ? { sessionToken: this.config.session } : {}),
      allHeaders: true, headers: { 'x-amz-expected-bucket-owner': this.config.accountId, ...headers },
      ...(body ? { body: body as BodyInit } : {}) });
    const signed = await signer.sign();
    return this.fetcher(signed.url, { method: signed.method, headers: signed.headers,
      body: signed.body ?? null, redirect: 'manual', signal: AbortSignal.timeout(30_000) });
  }

  private async head(key: string, expected: { hex: string; base64: string }, size: number,
    committedVersion?: string): Promise<RecoveryObject> {
    const reply = await this.request('HEAD', key, { 'x-amz-checksum-mode': 'ENABLED' },
      undefined, committedVersion);
    if (reply.status !== 200 || reply.headers.get('x-amz-checksum-sha256') !== expected.base64
      || reply.headers.get('x-amz-checksum-type') !== 'FULL_OBJECT'
      || reply.headers.get('content-length') !== String(size)) throw unavailable();
    const versionId = version(reply);
    if (committedVersion && versionId !== committedVersion) throw unavailable();
    return { key, sha256: expected.hex, bytes: size, versionId };
  }

  async putVersioned(key: string, ciphertext: Uint8Array): Promise<RecoveryObject> {
    if (!recoveryKeyPattern.test(key) || ciphertext.length < 1 || ciphertext.length > maxObjectBytes) {
      throw unavailable();
    }
    const expected = await checksum(ciphertext);
    try {
      const reply = await this.request('PUT', key, {
        'content-type': 'application/octet-stream', 'if-none-match': '*',
        'x-amz-checksum-sha256': expected.base64,
      }, ciphertext);
      if (reply.status !== 200 && reply.status !== 412) throw unavailable();
      if (reply.status === 200 && reply.headers.get('x-amz-checksum-sha256') !== expected.base64) {
        throw unavailable();
      }
      const committedVersion = reply.status === 200 ? version(reply) : undefined;
      // A retry may find an identical current version. A different object at
      // the same key is never accepted as success.
      return await this.head(key, expected, ciphertext.length, committedVersion);
    } catch { throw unavailable(); }
  }

  async getVerified(item: RecoveryObject): Promise<Uint8Array> {
    if (!hexPattern.test(item.sha256) || !Number.isSafeInteger(item.bytes) || item.bytes < 1
      || item.bytes > maxObjectBytes || !versionPattern.test(item.versionId) || item.versionId === 'null') {
      throw unavailable();
    }
    try {
      const reply = await this.request('GET', item.key, {}, undefined, item.versionId);
      if (reply.status !== 200 || !reply.body || version(reply) !== item.versionId) throw unavailable();
      const data = await readBoundedBody(reply.body, maxObjectBytes, unavailable);
      if (data.length !== item.bytes || (await checksum(data)).hex !== item.sha256) throw unavailable();
      return data;
    } catch { throw unavailable(); }
  }
}
