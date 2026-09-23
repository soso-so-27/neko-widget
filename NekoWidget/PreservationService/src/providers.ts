import { ServiceError, sha256, type PhotoValidator } from './contracts';
import { type BillingLinkAuthority, type MembershipStatus, linkTranscript } from './billing-link-protocol';
import { encodePhoto } from './documents';
import { type KeyWrappingAuthority } from './key-custody';
import { readBoundedBody } from './bounded-body';

// Private service bindings only; clients never supply provider URLs. Live KMS,
// verified billing identity linkage and JPEG service wiring remain activation gates.
async function invoke(binding: Fetcher, path: string, body: unknown, maximum = 40 * 1024 * 1024,
  callerSecret?: string) {
  const response = await binding.fetch(`https://preservation-internal${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json',
      ...(callerSecret ? { 'x-neko-preservation-key-token': callerSecret } : {}) }, body: JSON.stringify(body),
    // Workers supports manual/follow, not Request's browser-only error mode.
    // Never follow a provider redirect (response.ok below rejects every 3xx).
    redirect: 'manual', signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok || !response.body) throw new ServiceError('DEPENDENCY_UNAVAILABLE', 503);
  try {
    const bytes = await readBoundedBody(response.body, maximum, () => new ServiceError('DEPENDENCY_UNAVAILABLE', 503));
    const parsed: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
    return parsed as Record<string, unknown>;
  } catch { throw new ServiceError('DEPENDENCY_UNAVAILABLE', 503); }
}
export function boundKeyWrapper(binding: Fetcher, callerSecret: string): KeyWrappingAuthority {
  if (!/^[A-Za-z0-9_-]{43,128}$/u.test(callerSecret)) {
    throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
  }
  const decode = (value: unknown, maximum: number) => {
    try {
      if (typeof value !== 'string' || value.length > Math.ceil(maximum / 3) * 4) throw new Error();
      const raw = atob(value);
      if (!raw.length || btoa(raw) !== value || raw.length > maximum) throw new Error();
      return Uint8Array.from(raw, (char) => char.charCodeAt(0));
    } catch { throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503); }
  };
  const context = (value: string) => {
    if (!/^[0-9a-f]{64}$/u.test(value)) throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
  };
  return {
    async wrap(key, contextSHA256) {
      context(contextSHA256);
      if (!(key instanceof Uint8Array) || key.length !== 32) throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
      const value = await invoke(binding, '/keys/wrap', { version: 1, key: encodePhoto(key), contextSHA256 }, 8192,
        callerSecret);
      if (Object.keys(value).sort().join(',') !== 'keyId,version,wrappedKey' || value.version !== 1
          || typeof value.keyId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/u.test(value.keyId)) {
        throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
      }
      return { keyId: value.keyId, wrappedKey: decode(value.wrappedKey, 4096) };
    },
    async unwrap(keyId, wrappedKey, contextSHA256) {
      context(contextSHA256);
      if (!/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/u.test(keyId) || !(wrappedKey instanceof Uint8Array)
          || !wrappedKey.length || wrappedKey.length > 4096) throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
      const value = await invoke(binding, '/keys/unwrap', { version: 1, keyId, wrappedKey: encodePhoto(wrappedKey), contextSHA256 }, 256,
        callerSecret);
      if (Object.keys(value).sort().join(',') !== 'key,version' || value.version !== 1) throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
      const key = decode(value.key, 32);
      if (key.length !== 32) { key.fill(0); throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503); }
      return key;
    },
  };
}
export function boundBillingAuthority(binding: Fetcher): BillingLinkAuthority {
  return {
    async verify(challenge, proof) {
      const value = await invoke(binding, '/membership/verify-link', { challenge, proof }, 4096);
      if (Object.keys(value).sort().join(',') !== 'billingAccountId,challengeSHA256,version'
          || value.version !== 1 || value.billingAccountId !== challenge.billingAccountId
          || value.challengeSHA256 !== await sha256(linkTranscript(challenge))) {
        throw new ServiceError('BILLING_PROOF_UNCONFIRMED', 503);
      }
    },
    async status(billingAccountId) {
      const value = await invoke(binding, '/membership/verified-status', { billingAccountId }, 4096);
      if (Object.keys(value).sort().join(',') !== 'billingAccountId,status,version'
          || value.version !== 1 || value.billingAccountId !== billingAccountId
          || !['active', 'grace', 'expired', 'unknown'].includes(value.status as string)) {
        throw new ServiceError('MEMBERSHIP_UNCONFIRMED', 503);
      }
      return value.status as MembershipStatus;
    },
  };
}
export function boundPhotoValidator(binding: Fetcher): PhotoValidator {
  return { async validateJPEG(bytes) {
    const value = await invoke(binding, '/images/validate-jpeg', { photoBase64: encodePhoto(bytes) }, 4096);
    return value.valid === true && value.mediaType === 'image/jpeg' && value.frames === 1;
  } };
}
