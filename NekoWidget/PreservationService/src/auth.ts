import {
  type AuthDependencies, type Challenge, type Session, type VerifiedIdentity,
  ServiceError, contactEmailValid, randomToken, sha256,
} from './contracts';
import type { ExpiryReviewCandidate, NoticeReviewCandidate } from './retention-ledger';
import { identityIndexKey, indexedNoticeEmail, indexedOwnerIdentity } from './identity-index';

const CHALLENGE_MS = 5 * 60_000;
const SESSION_MS = 15 * 60_000;
const opaquePattern = /^[A-Za-z0-9_-]{43}$/u;
const encoder = new TextEncoder();
interface OwnerRow { owner_id: string; epoch: number; disabled: number; }
interface ChallengeRow { nonce: string; created_at: number; expires_at: number; }
interface SessionRow { owner_id: string; session_hash: string; expires_at: number; }
interface ContactRow { sealed_email: unknown; source: 'apple'; updated_at: number; }
const unavailable = (): ServiceError => new ServiceError('auth_unavailable', 503);
const denied = (): ServiceError => new ServiceError('unauthorized', 401);
const safeError = (error: unknown): ServiceError => error instanceof ServiceError ? error : unavailable();

export class DurableAuth {
  private readonly indexKey: Promise<CryptoKey>;

  constructor(private readonly dependencies: AuthDependencies) {
    this.indexKey = identityIndexKey(dependencies.identityIndexSecret);
  }

  private async noticeEmailTag(ownerId: string, email: string): Promise<string> {
    // An owner-bound tag cannot correlate two accounts that share an address.
    return indexedNoticeEmail(await this.indexKey, ownerId, email);
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
      const identityKey = await indexedOwnerIdentity(await this.indexKey,
        identity.issuer, identity.subject);
      const db = this.dependencies.db;
      await db.prepare(
        `INSERT INTO pa_owners(owner_id, identity_key, epoch, disabled, created_at)
         VALUES (?, ?, 0, 0, ?) ON CONFLICT(identity_key) DO NOTHING`,
      ).bind(crypto.randomUUID(), identityKey, this.now()).run();
      const owner = await db.prepare(
        'SELECT owner_id, epoch, disabled FROM pa_owners WHERE identity_key = ?',
      ).bind(identityKey).first<OwnerRow>();
      if (!owner || owner.disabled !== 0) throw denied();

      const contactEmail = identity.issuer === 'https://appleid.apple.com' ? identity.verifiedEmail : undefined;
      if (contactEmail !== undefined && !contactEmailValid(contactEmail)) throw denied();
      const contactTag = contactEmail ? await this.noticeEmailTag(owner.owner_id, contactEmail) : undefined;

      const plaintext = encoder.encode(JSON.stringify({
        issuer: identity.issuer, subject: identity.subject, refreshToken: identity.refreshToken,
      }));
      let sealed: Uint8Array;
      try {
        sealed = await this.dependencies.keys.seal(plaintext, { ownerId: owner.owner_id, purpose: 'identity' });
        if (!(sealed instanceof Uint8Array) || sealed.byteLength === 0 || sealed.byteLength > 131_072) throw new Error();
      } catch { throw new ServiceError('identity_key_unavailable', 503); }
      finally { plaintext.fill(0); }

      let sealedContact: Uint8Array | undefined;
      if (contactEmail) {
        const contactBytes = encoder.encode(JSON.stringify({ version: 1, email: contactEmail }));
        try {
          sealedContact = await this.dependencies.keys.seal(contactBytes, { ownerId: owner.owner_id, purpose: 'contact' });
          if (!(sealedContact instanceof Uint8Array) || !sealedContact.byteLength || sealedContact.byteLength > 8192) throw new Error();
        } catch { throw new ServiceError('identity_key_unavailable', 503); }
        finally { contactBytes.fill(0); }
      }

      const token = randomToken();
      const sessionHash = await sha256(token);
      const now = this.now();
      // A revocation during KMS work must win. Both writes are fenced in the same D1 transaction.
      const statements = [
        db.prepare(
          `INSERT INTO pa_identity_credentials(owner_id, owner_epoch, sealed_credentials, updated_at)
           SELECT owner_id, epoch, ?, ? FROM pa_owners WHERE owner_id = ? AND epoch = ? AND disabled = 0
           ON CONFLICT(owner_id) DO UPDATE SET owner_epoch = excluded.owner_epoch,
             sealed_credentials = excluded.sealed_credentials, updated_at = excluded.updated_at`,
        ).bind(sealed.slice().buffer, now, owner.owner_id, owner.epoch),
        ...(sealedContact ? [db.prepare(
          `INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,verified_at,updated_at,email_tag)
           SELECT owner_id,?,'apple',?,?,? FROM pa_owners WHERE owner_id=? AND epoch=? AND disabled=0
           ON CONFLICT(owner_id) DO UPDATE SET sealed_email=excluded.sealed_email,
             source=excluded.source,verified_at=excluded.verified_at,
             updated_at=MAX(pa_notice_contacts.updated_at+1,excluded.updated_at),
             email_tag=excluded.email_tag
           WHERE pa_notice_contacts.email_tag IS NOT excluded.email_tag`,
        ).bind(sealedContact.slice().buffer, now, now, contactTag, owner.owner_id, owner.epoch)] : []),
        db.prepare(
          `INSERT INTO pa_sessions(session_hash, owner_id, owner_epoch, created_at, expires_at)
           SELECT ?, owner_id, epoch, ?, ? FROM pa_owners
            WHERE owner_id = ? AND epoch = ? AND disabled = 0
              AND EXISTS (SELECT 1 FROM pa_identity_credentials AS credential
                           WHERE credential.owner_id = pa_owners.owner_id
                             AND credential.owner_epoch = pa_owners.epoch)`,
        ).bind(sessionHash, now, now + SESSION_MS, owner.owner_id, owner.epoch),
      ];
      const results = await db.batch(statements);
      if (results.at(-1)?.meta.changes !== 1) throw denied();
      if (this.dependencies.requireOwnerRecovery && !this.dependencies.ownerRecovery) throw unavailable();
      await this.dependencies.ownerRecovery?.copyCurrent(db, owner.owner_id, now);
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

  /** Read for the signed-in owner only. An Apple claim is not a delivery receipt. */
  async noticeContact(token: string): Promise<{ email: string | null; source: 'apple' | null }> {
    const session = await this.requireSession(token);
    try {
      const row = await this.dependencies.db.prepare(`SELECT c.sealed_email,c.source,c.updated_at FROM pa_notice_contacts c
        JOIN pa_sessions s ON s.owner_id=c.owner_id JOIN pa_owners o ON o.owner_id=c.owner_id
        WHERE s.session_hash=? AND s.owner_id=? AND s.expires_at>? AND o.disabled=0 AND o.epoch=s.owner_epoch`)
        .bind(session.sessionHash, session.ownerId, this.now()).first<ContactRow>();
      const email = row ? await this.openNoticeContact(row, session.ownerId) : null;
      const current = await this.requireSession(token);
      if (current.ownerId !== session.ownerId || current.sessionHash !== session.sessionHash) throw denied();
      return { email, source: row ? 'apple' : null };
    } catch (error) { throw safeError(error); }
  }

  /** Internal scheduled-notice path, never routed from an owner parameter. The
   * retention episode, unchanged deadline, and enabled owner must still match.
   * A newer same-status billing observation may advance the revision.
   */
  async verifiedNoticeContactForCandidate(candidate: NoticeReviewCandidate): Promise<{ email: string; updatedAt: number } | null> {
    try {
      if (!candidate || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(candidate.ownerId)
          || !Number.isSafeInteger(candidate.episode) || candidate.episode < 1
          || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
          || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0) throw unavailable();
      const now = this.now();
      const row = await this.dependencies.db.prepare(`SELECT c.sealed_email,c.source,c.updated_at
        FROM pa_notice_contacts c JOIN pa_owners o ON o.owner_id=c.owner_id
        JOIN pa_retention r ON r.owner_id=c.owner_id
        JOIN pa_membership_links l ON l.owner_id=c.owner_id
        WHERE c.owner_id=? AND o.disabled=0 AND r.episode=? AND r.revision>=? AND r.due_at=?
          AND r.verified_status='expired' AND r.paused_at IS NULL
          AND r.final_notice_delivered_at IS NULL AND r.checked_at>=? AND r.checked_at<=?
          AND r.due_at<=? AND r.notice_not_before_at<=?`)
        .bind(candidate.ownerId, candidate.episode, candidate.revision, candidate.dueAt,
          Math.max(0, now - 24 * 60 * 60 * 1000), now, now + 60 * 24 * 60 * 60 * 1000, now).first<ContactRow>();
      if (!row) return null;
      if (!Number.isSafeInteger(row.updated_at) || row.updated_at < 0 || row.updated_at > now) throw unavailable();
      const sealed = this.noticeContactBytes(row);
      const email = await this.openNoticeContact(row, candidate.ownerId);
      // A revocation, renewal, or email replacement during key access wins.
      // The eventual delivery event and deletion path must fence again.
      const stillCurrent = await this.dependencies.db.prepare(`SELECT 1 AS present
        FROM pa_notice_contacts c JOIN pa_owners o ON o.owner_id=c.owner_id
        JOIN pa_retention r ON r.owner_id=c.owner_id
        JOIN pa_membership_links l ON l.owner_id=c.owner_id
        WHERE c.owner_id=? AND c.updated_at=? AND c.sealed_email=? AND o.disabled=0
          AND r.episode=? AND r.revision>=? AND r.due_at=? AND r.verified_status='expired'
          AND r.paused_at IS NULL AND r.final_notice_delivered_at IS NULL`)
        .bind(candidate.ownerId, row.updated_at, sealed.slice().buffer, candidate.episode,
          candidate.revision, candidate.dueAt).first<{ present: number }>();
      return stillCurrent ? { email, updatedAt: row.updated_at } : null;
    } catch (error) { throw safeError(error); }
  }

  /** Internal expiry review only. The current encrypted Apple contact must
   * still belong to the exact delivered-notice ledger version after KMS I/O.
   * This does not authorize deletion or expose an owner lookup over HTTP.
   */
  async verifiedNoticeContactForExpiry(candidate: ExpiryReviewCandidate): Promise<{ email: string; updatedAt: number } | null> {
    try {
      if (!candidate || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(candidate.ownerId)
        || !Number.isSafeInteger(candidate.episode) || candidate.episode < 1
        || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
        || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0
        || !Number.isSafeInteger(candidate.deliveredAt) || candidate.deliveredAt <= 0
        || typeof candidate.deliveryEventId !== 'string' || candidate.deliveryEventId.length < 16
        || candidate.deliveryEventId.length > 256) throw unavailable();
      const now = this.now();
      const grace = 30 * 24 * 60 * 60 * 1000;
      const row = await this.dependencies.db.prepare(`SELECT c.sealed_email,c.source,c.updated_at
        FROM pa_notice_contacts c JOIN pa_owners o ON o.owner_id=c.owner_id
        JOIN pa_retention r ON r.owner_id=c.owner_id
        JOIN pa_membership_links l ON l.owner_id=c.owner_id
        WHERE c.owner_id=? AND c.source='apple' AND o.disabled=0
          AND r.episode=? AND r.revision=? AND r.due_at=?
          AND r.final_notice_delivered_at=? AND r.final_notice_receipt=?
          AND r.verified_status='expired' AND r.paused_at IS NULL
          AND r.checked_at>=? AND r.checked_at<=? AND r.due_at<=? AND r.final_notice_delivered_at<=?`)
        .bind(candidate.ownerId, candidate.episode, candidate.revision, candidate.dueAt,
          candidate.deliveredAt, candidate.deliveryEventId, Math.max(0, now - 24 * 60 * 60 * 1000),
          now, now, Math.max(0, now - grace)).first<ContactRow>();
      if (!row) return null;
      if (!Number.isSafeInteger(row.updated_at) || row.updated_at < 0 || row.updated_at > now) throw unavailable();
      const sealed = this.noticeContactBytes(row);
      const email = await this.openNoticeContact(row, candidate.ownerId);
      const stillCurrent = await this.dependencies.db.prepare(`SELECT 1 AS present
        FROM pa_notice_contacts c JOIN pa_owners o ON o.owner_id=c.owner_id
        JOIN pa_retention r ON r.owner_id=c.owner_id
        JOIN pa_membership_links l ON l.owner_id=c.owner_id
        WHERE c.owner_id=? AND c.updated_at=? AND c.sealed_email=? AND c.source='apple'
          AND o.disabled=0 AND r.episode=? AND r.revision=? AND r.due_at=?
          AND r.final_notice_delivered_at=? AND r.final_notice_receipt=?
          AND r.verified_status='expired' AND r.paused_at IS NULL
          AND r.checked_at>=? AND r.checked_at<=? AND r.due_at<=? AND r.final_notice_delivered_at<=?`)
        .bind(candidate.ownerId, row.updated_at, sealed.slice().buffer, candidate.episode,
          candidate.revision, candidate.dueAt, candidate.deliveredAt, candidate.deliveryEventId,
          Math.max(0, now - 24 * 60 * 60 * 1000), now, now, Math.max(0, now - grace))
        .first<{ present: number }>();
      return stillCurrent ? { email, updatedAt: row.updated_at } : null;
    } catch (error) { throw safeError(error); }
  }

  private noticeContactBytes(row: ContactRow): Uint8Array {
    const sealed = row.sealed_email instanceof ArrayBuffer ? new Uint8Array(row.sealed_email)
      : row.sealed_email instanceof Uint8Array ? row.sealed_email
      : Array.isArray(row.sealed_email) && row.sealed_email.every(byte =>
        Number.isInteger(byte) && byte >= 0 && byte <= 255) ? Uint8Array.from(row.sealed_email) : null;
    if (row.source !== 'apple' || !sealed || sealed.byteLength < 1 || sealed.byteLength > 8192) throw unavailable();
    return sealed;
  }

  private async openNoticeContact(row: ContactRow, ownerId: string): Promise<string> {
    const sealed = this.noticeContactBytes(row);
    const opened = await this.dependencies.keys.open(sealed, { ownerId, purpose: 'contact' });
    let value: unknown;
    try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(opened)); }
    finally { opened.fill(0); }
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
        Object.keys(value).sort().join(',') !== 'email,version' ||
        (value as { version?: unknown }).version !== 1) throw unavailable();
    const candidate = (value as { email?: unknown }).email;
    if (!contactEmailValid(candidate)) throw unavailable();
    return candidate;
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
      // A D1-only revocation could be lost and an older independent snapshot
      // would then re-enable the owner. The production path needs a durable
      // pre-revocation marker before this operation can be used.
      if (this.dependencies.requireOwnerRecovery) {
        throw new ServiceError('OWNER_REVOCATION_NOT_CONFIGURED', 503);
      }
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
