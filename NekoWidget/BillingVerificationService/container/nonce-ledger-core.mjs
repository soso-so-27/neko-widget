export const NONCE_RETENTION_MS = 601000;
export const MAX_LIVE_NONCES = 10000;
export function initializeNonceLedger(storage) {
  storage.sql.exec('CREATE TABLE IF NOT EXISTS claims (digest TEXT PRIMARY KEY, expires_ms INTEGER NOT NULL)');
  storage.sql.exec('CREATE INDEX IF NOT EXISTS claims_expiry ON claims(expires_ms)');
  storage.sql.exec('CREATE TABLE IF NOT EXISTS clock (id INTEGER PRIMARY KEY CHECK(id=1), last_ms INTEGER NOT NULL)');
  const clock = storage.sql.exec('SELECT last_ms FROM clock WHERE id=1').toArray();
  if (!clock.length) {
    if (storage.sql.exec('SELECT COUNT(*) AS n FROM claims').one().n !== 0) throw new Error('Nonce state unavailable');
    storage.sql.exec('INSERT INTO clock (id,last_ms) VALUES(1,0)');
  }
}
export function canonicalDigest(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(value)) return false;
  try {
    const bytes = atob(value.replaceAll('-', '+').replaceAll('_', '/') + '=');
    return bytes.length === 32 && btoa(bytes).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '') === value;
  } catch { return false; }
}
export function expireNonceLedger(storage, now) {
  const last = storage.sql.exec('SELECT last_ms FROM clock WHERE id=1').one().last_ms;
  if (!Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(last) || now < last)
    throw new Error('Nonce clock unavailable');
  storage.sql.exec('DELETE FROM claims WHERE expires_ms <= ?', now);
  storage.sql.exec('UPDATE clock SET last_ms=? WHERE id=1', now);
}
export function claimDurableNonce(storage, digest, now) {
  if (!canonicalDigest(digest)) throw new Error('Invalid nonce digest');
  return storage.transactionSync(() => {
    expireNonceLedger(storage, now);
    if (storage.sql.exec('SELECT digest FROM claims WHERE digest=?', digest).toArray().length) return 'replayed';
    if (storage.sql.exec('SELECT COUNT(*) AS n FROM claims').one().n >= MAX_LIVE_NONCES)
      throw new Error('Nonce capacity unavailable');
    storage.sql.exec('INSERT INTO claims(digest,expires_ms) VALUES(?,?)', digest, now + NONCE_RETENTION_MS);
    return 'claimed';
  });
}
