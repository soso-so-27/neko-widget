const fields = ['version', 'bootstrapClientRequestId', 'initialPublicKeySHA256', 'startsAtMs', 'expiresAtMs'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
/** Pure public enrollment policy validation shared by runtime and operation CLI. */
export function parseOwnerAdmission(text, now = Date.now(), allowExpired = false) {
  const fail = () => { throw new Error('Owner Sandbox admission is unavailable or invalid'); };
  if (typeof text !== 'string' || text.length > 512) fail();
  let value;
  try { value = JSON.parse(text); } catch { fail(); }
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).length !== fields.length || fields.some(key => !Object.hasOwn(value, key))
      || value.version !== 1 || typeof value.bootstrapClientRequestId !== 'string' || !uuid.test(value.bootstrapClientRequestId)
      || typeof value.initialPublicKeySHA256 !== 'string' || !/^[0-9a-f]{64}$/u.test(value.initialPublicKeySHA256)
      || !Number.isSafeInteger(now) || now < 0
      || !Number.isSafeInteger(value.startsAtMs) || value.startsAtMs < 0
      || !Number.isSafeInteger(value.expiresAtMs)
      || value.expiresAtMs <= value.startsAtMs || value.expiresAtMs - value.startsAtMs > 86400000
      || (!allowExpired && (now < value.startsAtMs || now >= value.expiresAtMs))) fail();
  return Object.freeze(value);
}
