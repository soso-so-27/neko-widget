import { WorkerEntrypoint } from 'cloudflare:workers';
import { AwsV4Signer } from 'aws4fetch';
import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';

/** A private service-binding target. Never attach a public route to this entrypoint. */
export interface KeyWrapperEnv {
  PRESERVATION_KMS_ENABLED?: string;
  KMS_REGION?: string;
  KMS_KEY_ARN?: string;
  KMS_ACCESS_KEY_ID?: string;
  KMS_SECRET_ACCESS_KEY?: string;
  KMS_SESSION_TOKEN?: string;
  KEY_WRAPPER_CALLER_SECRET?: string;
}

type KMSFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
const responseHeaders = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
const failure = (status: number) => Response.json({ error: { code: status === 400 ? 'INVALID_REQUEST' : 'KEY_CUSTODY_UNAVAILABLE' } },
  { status, headers: responseHeaders });
const tokenPattern = /^[A-Za-z0-9_-]{43,128}$/u;
const contextPattern = /^[0-9a-f]{64}$/u;
const arnPattern = /^arn:aws:kms:([a-z0-9-]+):[0-9]{12}:key\/([A-Za-z0-9-]+)$/u;
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)); // at most one 4 KiB wrapped key

function decode(value: unknown, maximum: number): Uint8Array {
  if (typeof value !== 'string' || !value.length || value.length > Math.ceil(maximum / 3) * 4) throw new Error();
  const raw = atob(value);
  if (!raw.length || raw.length > maximum || btoa(raw) !== value) throw new Error();
  return Uint8Array.from(raw, character => character.charCodeAt(0));
}

function exactObject(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).sort().join(',') !== [...keys].sort().join(',')) throw new Error();
  return value as Record<string, unknown>;
}

async function authenticated(request: Request, secret: string): Promise<boolean> {
  const supplied = request.headers.get('x-neko-preservation-key-token');
  if (!tokenPattern.test(secret) || !supplied || !tokenPattern.test(supplied)) return false;
  const encode = new TextEncoder();
  const [expected, actual] = await Promise.all([
    crypto.subtle.digest('SHA-256', encode.encode(secret)),
    crypto.subtle.digest('SHA-256', encode.encode(supplied)),
  ]);
  const first = new Uint8Array(expected); const second = new Uint8Array(actual);
  let different = 0;
  for (let index = 0; index < first.length; index++) different |= first[index]! ^ second[index]!;
  return different === 0;
}

function configured(env: KeyWrapperEnv): { region: string; keyArn: string; access: string; secret: string; session: string | undefined } {
  const region = env.KMS_REGION ?? '';
  const keyArn = env.KMS_KEY_ARN ?? '';
  const match = arnPattern.exec(keyArn);
  if (env.PRESERVATION_KMS_ENABLED !== 'YES' || !match || match[1] !== region
      || !/^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u.test(region)
      || !env.KMS_ACCESS_KEY_ID || !env.KMS_SECRET_ACCESS_KEY
      || !tokenPattern.test(env.KEY_WRAPPER_CALLER_SECRET ?? '')) throw new Error();
  return { region, keyArn, access: env.KMS_ACCESS_KEY_ID, secret: env.KMS_SECRET_ACCESS_KEY,
    session: env.KMS_SESSION_TOKEN };
}

async function kmsCall(env: KeyWrapperEnv, action: 'Encrypt' | 'Decrypt', payload: object,
  fetcher: KMSFetch): Promise<Record<string, unknown>> {
  const config = configured(env);
  const body = JSON.stringify(payload);
  const signer = new AwsV4Signer({ url: `https://kms.${config.region}.amazonaws.com/`,
    method: 'POST', body, service: 'kms', region: config.region,
    accessKeyId: config.access, secretAccessKey: config.secret,
    ...(config.session ? { sessionToken: config.session } : {}),
    allHeaders: true, headers: { 'content-type': 'application/x-amz-json-1.1',
      'x-amz-target': `TrentService.${action}` } });
  const signed = await signer.sign();
  const reply = await fetcher(signed.url, { method: signed.method, headers: signed.headers,
    body: signed.body ?? null, redirect: 'manual', signal: AbortSignal.timeout(8000) });
  if (reply.status !== 200 || !reply.body
      || reply.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/x-amz-json-1.1') {
    throw new Error();
  }
  const bytes = await readBoundedBody(reply.body, 8192,
    () => new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503));
  const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
  const result = value as Record<string, unknown>;
  const allowed = action === 'Encrypt' ? ['CiphertextBlob', 'KeyId', 'EncryptionAlgorithm', 'KeyMaterialId']
    : ['Plaintext', 'KeyId', 'EncryptionAlgorithm', 'KeyMaterialId'];
  if (Object.keys(result).some(key => !allowed.includes(key))) throw new Error();
  return result;
}

/** Exported separately for synthetic signed-request tests; no actual AWS access in CI. */
export async function handleKeyWrapperRequest(request: Request, env: KeyWrapperEnv,
  fetcher: KMSFetch = fetch): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== 'POST' || url.protocol !== 'https:' || url.host !== 'preservation-internal'
      || url.search || !['/keys/wrap', '/keys/unwrap'].includes(url.pathname)) return failure(404);
  if (!await authenticated(request, env.KEY_WRAPPER_CALLER_SECRET ?? '')) return failure(503);
  if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json'
      || !request.body) return failure(400);
  let input: Record<string, unknown>;
  try {
    const bytes = await readBoundedBody(request.body, 8192,
      () => new ServiceError('INVALID_REQUEST'), request.signal);
    input = exactObject(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)),
      url.pathname === '/keys/wrap' ? ['version', 'key', 'contextSHA256']
        : ['version', 'keyId', 'wrappedKey', 'contextSHA256']);
    if (input.version !== 1 || typeof input.contextSHA256 !== 'string'
        || !contextPattern.test(input.contextSHA256)) throw new Error();
  } catch { return failure(400); }
  let raw: Uint8Array | undefined;
  try {
    const config = configured(env);
    const context = { 'neko-preservation-context-sha256': input.contextSHA256 as string };
    if (url.pathname === '/keys/wrap') {
      raw = decode(input.key, 32);
      if (raw.length !== 32) return failure(400);
      const result = await kmsCall(env, 'Encrypt', { KeyId: config.keyArn,
        Plaintext: base64(raw), EncryptionContext: context }, fetcher);
      if (result.KeyId !== config.keyArn || result.EncryptionAlgorithm !== 'SYMMETRIC_DEFAULT') throw new Error();
      const wrapped = decode(result.CiphertextBlob, 4096);
      return Response.json({ version: 1, keyId: config.keyArn, wrappedKey: base64(wrapped) },
        { headers: responseHeaders });
    }
    // No client-supplied key choice. Automatic KMS key rotation preserves the ARN.
    if (input.keyId !== config.keyArn) return failure(400);
    const wrapped = decode(input.wrappedKey, 4096);
    const result = await kmsCall(env, 'Decrypt', { KeyId: config.keyArn,
      CiphertextBlob: base64(wrapped), EncryptionContext: context }, fetcher);
    if (result.KeyId !== config.keyArn || result.EncryptionAlgorithm !== 'SYMMETRIC_DEFAULT') throw new Error();
    raw = decode(result.Plaintext, 32);
    if (raw.length !== 32) throw new Error();
    return Response.json({ version: 1, key: base64(raw) }, { headers: responseHeaders });
  } catch { return failure(503); }
  finally { raw?.fill(0); }
}

/** Named service binding entrypoint only. The default Worker route is always closed. */
export class PreservationKeyWrapper extends WorkerEntrypoint<KeyWrapperEnv> {
  override async fetch(request: Request): Promise<Response> {
    return handleKeyWrapperRequest(request, this.env);
  }
}
export default { fetch: async (): Promise<Response> => failure(404) };
