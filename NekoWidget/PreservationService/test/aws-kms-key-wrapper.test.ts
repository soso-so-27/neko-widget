import { describe, expect, it } from 'vitest';
import { handleKeyWrapperRequest, type KeyWrapperEnv } from '../src/aws-kms-key-wrapper';

const keyArn = 'arn:aws:kms:ap-northeast-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab';
const contextSHA256 = 'a'.repeat(64);
const token = 's'.repeat(43);
const raw = Uint8Array.from({ length: 32 }, (_, index) => index);
const encode = (value: Uint8Array) => btoa(String.fromCharCode(...value));
const env: KeyWrapperEnv = { PRESERVATION_KMS_ENABLED: 'YES', KMS_REGION: 'ap-northeast-1',
  KMS_KEY_ARN: keyArn, KMS_ACCESS_KEY_ID: 'AKIA1234567890EXAMPLE',
  KMS_SECRET_ACCESS_KEY: 'test-secret-not-for-real-aws-1234567890', KEY_WRAPPER_CALLER_SECRET: token };
const request = (path: string, body: unknown, caller = token) => new Request(`https://preservation-internal${path}`,
  { method: 'POST', headers: { 'content-type': 'application/json', 'x-neko-preservation-key-token': caller },
    body: JSON.stringify(body) });
const kmsResponse = (body: unknown, status = 200) => Response.json(body, { status,
  headers: { 'content-type': 'application/x-amz-json-1.1' } });

describe('private AWS KMS data-key wrapper', () => {
  it('signs only small data-key operations with the bound context and unwraps the same key', async () => {
    const actions: string[] = [];
    const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toBe('https://kms.ap-northeast-1.amazonaws.com/');
      const headers = new Headers(init?.headers);
      expect(headers.get('authorization')).toContain('/ap-northeast-1/kms/aws4_request');
      expect(headers.get('content-type')).toBe('application/x-amz-json-1.1');
      const action = headers.get('x-amz-target');
      const body = JSON.parse(String(init?.body));
      expect(body.KeyId).toBe(keyArn);
      expect(body.EncryptionContext).toEqual({ 'neko-preservation-context-sha256': contextSHA256 });
      actions.push(String(action));
      if (action === 'TrentService.Encrypt') {
        expect(body.Plaintext).toBe(encode(raw));
        return kmsResponse({ KeyId: keyArn, EncryptionAlgorithm: 'SYMMETRIC_DEFAULT', CiphertextBlob: encode(raw) });
      }
      expect(action).toBe('TrentService.Decrypt');
      expect(body.CiphertextBlob).toBe(encode(raw));
      return kmsResponse({ KeyId: keyArn, EncryptionAlgorithm: 'SYMMETRIC_DEFAULT', Plaintext: encode(raw) });
    };
    const wrapped = await handleKeyWrapperRequest(request('/keys/wrap',
      { version: 1, key: encode(raw), contextSHA256 }), env, fetcher);
    expect(wrapped.status).toBe(200);
    const payload = await wrapped.json() as { version: number; keyId: string; wrappedKey: string };
    expect(payload).toEqual({ version: 1, keyId: keyArn, wrappedKey: encode(raw) });
    const opened = await handleKeyWrapperRequest(request('/keys/unwrap',
      { version: 1, keyId: payload.keyId, wrappedKey: payload.wrappedKey, contextSHA256 }), env, fetcher);
    expect(opened.status).toBe(200);
    expect(await opened.json()).toEqual({ version: 1, key: encode(raw) });
    expect(actions).toEqual(['TrentService.Encrypt', 'TrentService.Decrypt']);
  });

  it('fails closed before KMS for unknown caller, malformed key, and arbitrary KMS key ID', async () => {
    let calls = 0;
    const fetcher = async () => { calls++; return kmsResponse({}); };
    expect((await handleKeyWrapperRequest(request('/keys/wrap',
      { version: 1, key: encode(raw), contextSHA256 }, 'x'.repeat(43)), env, fetcher)).status).toBe(503);
    expect((await handleKeyWrapperRequest(request('/keys/wrap',
      { version: 1, key: encode(raw.slice(0, 31)), contextSHA256 }), env, fetcher)).status).toBe(400);
    expect((await handleKeyWrapperRequest(request('/keys/unwrap', { version: 1, keyId: 'attacker-key',
      wrappedKey: encode(raw), contextSHA256 }), env, fetcher)).status).toBe(400);
    expect(calls).toBe(0);
  });

  it('never returns a key when KMS is disabled, fails, or returns a different key', async () => {
    const input = request('/keys/wrap', { version: 1, key: encode(raw), contextSHA256 });
    expect((await handleKeyWrapperRequest(input, { ...env, PRESERVATION_KMS_ENABLED: 'NO' },
      async () => kmsResponse({}))).status).toBe(503);
    expect((await handleKeyWrapperRequest(request('/keys/wrap', { version: 1, key: encode(raw), contextSHA256 }),
      env, async () => kmsResponse({ error: 'disabled' }, 400))).status).toBe(503);
    expect((await handleKeyWrapperRequest(request('/keys/wrap', { version: 1, key: encode(raw), contextSHA256 }),
      env, async () => kmsResponse({ KeyId: 'wrong', EncryptionAlgorithm: 'SYMMETRIC_DEFAULT',
        CiphertextBlob: encode(raw) }))).status).toBe(503);
  });
});
