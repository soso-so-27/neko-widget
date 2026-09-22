import { ServiceError, type KeyCustody, type MembershipAuthority, type PhotoValidator } from './contracts';
import { encodePhoto } from './documents';

// Private service bindings only; clients never supply provider URLs. Real KMS,
// verified billing identity linkage and a JPEG decoder remain activation gates.
async function invoke(binding: Fetcher, path: string, body: unknown, maximum = 40 * 1024 * 1024) {
  const response = await binding.fetch(`https://preservation-internal${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    redirect: 'error', signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok || !response.body) throw new ServiceError('DEPENDENCY_UNAVAILABLE', 503);
  const reader = response.body.getReader();
  const parts: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > maximum) { await reader.cancel(); throw new ServiceError('DEPENDENCY_UNAVAILABLE', 503); }
      parts.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.length; }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as Record<string, unknown>;
  } catch { throw new ServiceError('DEPENDENCY_UNAVAILABLE', 503); }
  finally { reader.releaseLock(); }
}
export function boundKeyCustody(binding: Fetcher): KeyCustody {
  const operate = async (method: 'seal' | 'open', value: Uint8Array,
    context: Parameters<KeyCustody['seal']>[1]): Promise<Uint8Array> => {
    const response = await invoke(binding, `/keys/${method}`, { bytes: encodePhoto(value), context });
    if (typeof response.bytes !== 'string' || response.bytes.length > 40 * 1024 * 1024) throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503);
    try {
      const raw = atob(response.bytes);
      if (!raw.length || btoa(raw) !== response.bytes || raw.length > 30 * 1024 * 1024) throw new Error();
      return Uint8Array.from(raw, (char) => char.charCodeAt(0));
    } catch { throw new ServiceError('KEY_CUSTODY_UNAVAILABLE', 503); }
  };
  return { seal: (value, context) => operate('seal', value, context), open: (value, context) => operate('open', value, context) };
}
export function boundMembership(binding: Fetcher): MembershipAuthority {
  return { async status(ownerId) {
    const value = await invoke(binding, '/membership/verified-status', { ownerId }, 4096);
    if (!['active', 'grace', 'expired', 'unknown'].includes(value.status as string)) return 'unknown';
    return value.status as 'active' | 'grace' | 'expired' | 'unknown';
  } };
}
export function boundPhotoValidator(binding: Fetcher): PhotoValidator {
  return { async validateJPEG(bytes) {
    const value = await invoke(binding, '/images/validate-jpeg', { photoBase64: encodePhoto(bytes) }, 4096);
    return value.valid === true && value.mediaType === 'image/jpeg' && value.frames === 1;
  } };
}
