import {
  type AuthDependencies, type Challenge, type Session, type VerifiedIdentity,
  ServiceError, randomToken, sha256,
} from './contracts';

const CHALLENGE_MS = 5 * 60_000;
const SESSION_MS = 15 * 60_000;
const opaquePattern = /^[A-Za-z0-9_-]{43}$/u;
const encoder = new TextEncoder();
interface OwnerRow { owner_id: string; epoch: number; disabled: number; }
interface ChallengeRow { nonce: string; created_at: number; expires_at: number; }
interface SessionRow { owner_id: string; session_hash: string; expires_at: number; }
const unavailable = (): ServiceError => new ServiceError('auth_unavailable', 503);
const denied = (): ServiceError => new ServiceError('unauthorized', 401);
const safeError = (error: unknown): ServiceError => error instanceof ServiceError ? error : unavailable();

function indexSecret(value: string): Uint8Array {
  try {
    if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43,4096}$/u.test(value)) throw new Error();
    const decoded = atob(value.replaceAll('-', '+').replaceAll('_', '/'));
    const canonical = btoa(decoded).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
    if (decoded.length < 32 || canonical !== value) throw new Error();
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  } catch { throw new ServiceError('auth_configuration_invalid', 503); }
}

export class DurableAuth {
  private readonly indexKey: Promise<CryptoKey>;

  constructor(private readonly dependencies: AuthDependencies) {
    const raw = indexSecret(dependencies.identityIndexSecret);
    this.indexKey = crypto.subtle.importKey('raw', raw as BufferSource,
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    raw.fill(0);
  }

  private now(): number {
    const value = this.dependencies.now();
    if (!Number.isSafeInteger(value) || value < 0 || value > 8_640_000_000_000_000 - SESSION_MS) {
      throw unavailable();
    }
    return value;
  }

  async issueChallenge(): Promise<{ challengeId: string; challengeProof: string; nonce: string; expiresAt: string }> {
    try {
      const now = this.now();
      const challengeId = randomToken();
      const challengeProof = randomToken();
      const nonce = randomToken();
      await this.dependencies.db.prepare(
        `INSERT INTO pa_auth_challenges(challenge_id, proof_hash, nonce, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?)`,
      ).bind(challengeId, await sha256(challengeProof), nonce, now, now + CHALLENGE_MS).run();
      return { challengeId, challengeProof, nonce, expiresAt: new Date(now + CHALLENGE_MS).toISOString() };
    } catch (error) { throw safeError(error); }
  }

  async takeChallenge(input: { challengeId: string; challengeProof: string }): Promise<Challenge> {
    try {
      if (!opaquePattern.test(input.challengeId) || !opaquePattern.test(input.challengeProof)) throw denied();
      const row = await this.dependencies.db.prepare(
        `DELETE FROM pa_auth_challenges
          WHERE challenge_id = ? AND proof_hash = ? AND expires_at > ?
          RETURNING nonce, created_at, expires_at`,
      ).bind(input.challengeId, await sha256(input.challengeProof), this.now()).first<ChallengeRow>();
      if (!row) throw denied();
      return { nonce: row.nonce, createdAt: row.created_at, expiresAt: row.expires_at };
    } catch (error) { throw safeError(error); }
  }

  async establish(identity: VerifiedIdentity): Promise<{ token: string; ownerId: string; expiresAt: string }> {
    try {
      if (typeof identity.issuer !== 'string' || !identity.issuer.trim() || identity.issuer.length > 2048
          || typeof identity.subject !== 'string' || !identity.subject.trim() || identity.subject.length > 1024
          || typeof identity.refreshToken !== 'string' || !identity.refreshToken || identity.refreshToken.length > 16_384) {
        throw denied();
      }
      // Only the trusted verifier supplies identity. No email, device or billing ID is a lookup key.
      const identityBytes = encoder.encode(`neko-preservation-identity-v1\0${JSON.stringify([identity.issuer, identity.subject])}`);
      const digest = new Uint8Array(await crypto.subtle.sign('HMAC', await this.indexKey, identityBytes));
      const identityKey = [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
      const db = this.dependencies.db;
      await db.prepare(
        `INSERT INTO pa_owners(owner_id, identity_key, epoch, disabled, created_at)
         VALUES (?, ?, 0, 0, ?) ON CONFLICT(identity_key) DO NOTHING`,
      ).bind(crypto.randomUUID(), identityKey, this.now()).run();
      const owner = await db.prepare(
        'SELECT owner_id, epoch, disabled FROM pa_owners WHERE identity_key = ?',
      ).bind(identityKey).first<OwnerRow>();
      if (!owner || owner.disabled !== 0) throw denied();

      const plaintext = encoder.encode(JSON.stringify({
        issuer: identity.issuer, subject: identity.subject, refreshToken: identity.refreshToken,
      }));
      let sealed: Uint8Array;
      try {
        sealed = await this.dependencies.keys.seal(plaintext, { ownerId: owner.owner_id, purpose: 'identity' });
        if (!(sealed instanceof Uint8Array) || sealed.byteLength === 0 || sealed.byteLength > 131_072) throw new Error();
      } catch { throw new ServiceError('identity_key_unavailable', 503); }
      finally { plaintext.fill(0); }

      const token = randomToken();
      const sessionHash = await sha256(token);
      const now = this.now();
      // A revocation during KMS work must win. Both writes are fenced in the same D1 transaction.
      const results = await db.batch([
        db.prepare(
          `INSERT INTO pa_identity_credentials(owner_id, owner_epoch, sealed_credentials, updated_at)
           SELECT owner_id, epoch, ?, ? FROM pa_owners WHERE owner_id = ? AND epoch = ? AND disabled = 0
           ON CONFLICT(owner_id) DO UPDATE SET owner_epoch = excluded.owner_epoch,
             sealed_credentials = excluded.sealed_credentials, updated_at = excluded.updated_at`,
        ).bind(sealed.slice().buffer, now, owner.owner_id, owner.epoch),
        db.prepare(
          `INSERT INTO pa_sessions(session_hash, owner_id, owner_epoch, created_at, expires_at)
           SELECT ?, owner_id, epoch, ?, ? FROM pa_owners
            WHERE owner_id = ? AND epoch = ? AND disabled = 0
              AND EXISTS (SELECT 1 FROM pa_identity_credentials AS credential
                           WHERE credential.owner_id = pa_owners.owner_id
                             AND credential.owner_epoch = pa_owners.epoch)`,
        ).bind(sessionHash, now, now + SESSION_MS, owner.owner_id, owner.epoch),
      ]);
      if (results[1]?.meta.changes !== 1) throw denied();
      return { token, ownerId: owner.owner_id, expiresAt: new Date(now + SESSION_MS).toISOString() };
    } catch (error) { throw safeError(error); }
  }

  async requireSession(token: string): Promise<Session> {
    try {
      if (typeof token !== 'string' || !opaquePattern.test(token)) throw denied();
      const row = await this.dependencies.db.prepare(
        `SELECT session.owner_id, session.session_hash, session.expires_at FROM pa_sessions AS session
         JOIN pa_owners AS owner ON owner.owner_id = session.owner_id
          WHERE session.session_hash = ? AND session.expires_at > ?
            AND owner.disabled = 0 AND owner.epoch = session.owner_epoch`,
      ).bind(await sha256(token), this.now()).first<SessionRow>();
      if (!row) throw denied();
      return { ownerId: row.owner_id, sessionHash: row.session_hash, expiresAt: row.expires_at };
    } catch (error) { throw safeError(error); }
  }

  async revokeSession(token: string): Promise<void> {
    try {
      if (typeof token !== 'string' || !opaquePattern.test(token)) throw denied();
      await this.dependencies.db.prepare('DELETE FROM pa_sessions WHERE session_hash = ?')
        .bind(await sha256(token)).run();
    } catch (error) { throw safeError(error); }
  }

  // Internal trusted operation; not authorization for a client-supplied owner ID.
  async revokeOwner(ownerId: string): Promise<void> {
    try {
      await this.dependencies.db.prepare(
        'UPDATE pa_owners SET epoch = epoch + 1, disabled = 1 WHERE owner_id = ? AND disabled = 0',
      ).bind(ownerId).run();
      // Owner/identity and archive rows remain. Neither login nor cleanup re-enables the owner.
    } catch (error) { throw safeError(error); }
  }

  // Caller schedules maintenance. At most 2 * limit rows per call; no archive/owner deletion.
  async cleanup(limit = 100): Promise<number> {
    try {
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) throw new ServiceError('invalid_cleanup_limit');
      const now = this.now();
      const db = this.dependencies.db;
      const results = await db.batch([
        db.prepare(`DELETE FROM pa_auth_challenges WHERE challenge_id IN
          (SELECT challenge_id FROM pa_auth_challenges WHERE expires_at <= ? ORDER BY expires_at, challenge_id LIMIT ?)`)
          .bind(now, limit),
        db.prepare(`DELETE FROM pa_sessions WHERE session_hash IN
          (SELECT session_hash FROM pa_sessions WHERE expires_at <= ? ORDER BY expires_at, session_hash LIMIT ?)`)
          .bind(now, limit),
      ]);
      return results.reduce((sum, result) => sum + result.meta.changes, 0);
    } catch (error) { throw safeError(error); }
  }
}
