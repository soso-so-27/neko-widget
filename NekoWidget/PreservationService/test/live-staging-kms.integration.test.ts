import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { handleKeyWrapperRequest, type KeyWrapperEnv } from '../src/aws-kms-key-wrapper';

const raw = Uint8Array.from({ length: 32 }, (_, index) => index);
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const contextSHA256 = 'a'.repeat(64);
const request = (path: string, body: unknown) => new Request(`https://preservation-internal${path}`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    'x-neko-preservation-key-token': 's'.repeat(43),
  },
  body: JSON.stringify(body),
});
const observeKms = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const action = new Headers(init?.headers).get('x-amz-target') ?? 'unknown';
  let response: Response;
  try { response = await fetch(input, init); }
  catch (error) {
    console.log('KMS_FETCH_EXCEPTION', action, error instanceof Error ? error.name : 'unknown');
    throw error;
  }
  if (response.status !== 200) {
    const body = await response.clone().json().catch(() => ({})) as Record<string, unknown>;
    console.log('KMS_ERROR', action, response.status,
      typeof body.__type === 'string' ? body.__type : 'unknown');
  }
  return response;
};

describe('live staging KMS with a synthetic data key only', () => {
  it('wraps and unwraps through the production key wrapper', async () => {
    const config = env as unknown as KeyWrapperEnv;
    const wrapped = await handleKeyWrapperRequest(request('/keys/wrap', {
      version: 1, key: base64(raw), contextSHA256,
    }), config, observeKms);
    expect(wrapped.status).toBe(200);
    const result = await wrapped.json() as { version: number; keyId: string; wrappedKey: string };
    expect(result.version).toBe(1);
    expect(result.keyId).toBe(config.KMS_KEY_ARN);
    expect(result.wrappedKey).toBeTruthy();
    const opened = await handleKeyWrapperRequest(request('/keys/unwrap', {
      version: 1, keyId: result.keyId, wrappedKey: result.wrappedKey, contextSHA256,
    }), config, observeKms);
    expect(opened.status).toBe(200);
    expect(await opened.json()).toEqual({ version: 1, key: base64(raw) });
  });
});
