import { DurableAuth } from './auth';
import { type MembershipAuthority, ServiceError, randomToken } from './contracts';
import { type BillingLinkAuthority, type LinkChallenge, LINK_TTL_MS, LINK_SIGNING_PATH,
  linkTranscript, uuidV4, validAudience, validateChallenge, validateProof } from './billing-link-protocol';

interface Row { challenge_id: string; owner_id: string; billing_account_id: string; audience: string; issued_at: number; expires_at: number; }
export class MembershipLinks implements MembershipAuthority {
  constructor(private readonly d: { db: D1Database; auth: DurableAuth; authority: BillingLinkAuthority;
    audience: string; now: () => number }) {
    if (!validAudience(d.audience)) throw new ServiceError('MEMBERSHIP_NOT_CONFIGURED', 503);
  }
  private clock() {
    const now = this.d.now();
    if (!Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(now + LINK_TTL_MS)) {
      throw new ServiceError('MEMBERSHIP_UNAVAILABLE', 503);
    }
    return now;
  }
  async issue(token: string, billingAccountId: unknown) {
    if (typeof billingAccountId !== 'string' || !uuidV4.test(billingAccountId)) throw new ServiceError('INVALID_REQUEST');
    const session = await this.d.auth.requireSession(token);
    const now = this.clock();
    const challenge: LinkChallenge = { version: 1, purpose: 'preservation-membership-link', audience: this.d.audience,
      challengeId: randomToken(), ownerId: session.ownerId, billingAccountId, issuedAt: now, expiresAt: now + LINK_TTL_MS };
    // One outstanding challenge per session; a new request supersedes the old.
    // A client-supplied billing ID is a target, not proof and not a membership grant.
    const results = await this.d.db.batch([
      this.d.db.prepare('DELETE FROM pa_membership_challenges WHERE session_hash = ?').bind(session.sessionHash),
      this.d.db.prepare(`INSERT INTO pa_membership_challenges
        (challenge_id, owner_id, session_hash, billing_account_id, audience, issued_at, expires_at)
        SELECT ?, s.owner_id, s.session_hash, ?, ?, ?, ? FROM pa_sessions s JOIN pa_owners o ON o.owner_id=s.owner_id
        WHERE s.session_hash=? AND s.expires_at>? AND o.disabled=0 AND s.owner_epoch=o.epoch`)
        .bind(challenge.challengeId, billingAccountId, challenge.audience, now, challenge.expiresAt, session.sessionHash, now),
    ]);
    if (results[1]?.meta.changes !== 1) throw new ServiceError('SESSION_INVALID', 401);
    return { challenge, signingPath: LINK_SIGNING_PATH, signingBody: linkTranscript(challenge) };
  }
  async complete(token: string, challengeId: unknown, inputProof: unknown) {
    if (typeof challengeId !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(challengeId)) throw new ServiceError('INVALID_REQUEST');
    const proof = validateProof(inputProof);
    const session = await this.d.auth.requireSession(token);
    // Destructive take is transactionally fenced by the still-valid session.
    // Network failure after this point requires a fresh challenge/signature.
    const row = await this.d.db.prepare(`DELETE FROM pa_membership_challenges WHERE challenge_id=?
      AND session_hash=? AND expires_at>? AND EXISTS
      (SELECT 1 FROM pa_sessions s JOIN pa_owners o ON o.owner_id=s.owner_id WHERE s.session_hash=?
       AND s.expires_at>? AND o.disabled=0 AND s.owner_epoch=o.epoch)
      RETURNING challenge_id, owner_id, billing_account_id, audience, issued_at, expires_at`)
      .bind(challengeId, session.sessionHash, this.clock(), session.sessionHash, this.clock()).first<Row>();
    if (!row) throw new ServiceError('LINK_CHALLENGE_INVALID', 401);
    const challenge = validateChallenge({ version: 1, purpose: 'preservation-membership-link', audience: row.audience,
      challengeId: row.challenge_id, ownerId: row.owner_id, billingAccountId: row.billing_account_id,
      issuedAt: row.issued_at, expiresAt: row.expires_at }, this.d.audience, this.clock());
    await this.d.authority.verify(challenge, proof);
    const now = this.clock();
    validateChallenge(challenge, this.d.audience, now);
    // Separate services cannot share a transaction. The authority consumes the
    // billing nonce; this DB rechecks preservation identity after that await.
    const results = await this.d.db.batch([
      this.d.db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
        SELECT s.owner_id,?,? FROM pa_sessions s JOIN pa_owners o ON o.owner_id=s.owner_id
        WHERE s.session_hash=? AND s.owner_id=? AND s.expires_at>? AND o.disabled=0 AND s.owner_epoch=o.epoch
        ON CONFLICT DO NOTHING`).bind(challenge.billingAccountId, now, session.sessionHash, challenge.ownerId, now),
      this.d.db.prepare(`SELECT l.billing_account_id FROM pa_membership_links l
        JOIN pa_sessions s ON s.owner_id=l.owner_id JOIN pa_owners o ON o.owner_id=l.owner_id
        WHERE s.session_hash=? AND s.expires_at>? AND o.disabled=0 AND s.owner_epoch=o.epoch`)
        .bind(session.sessionHash, now),
    ]);
    const link = results[1]?.results[0] as { billing_account_id: string } | undefined;
    if (!link) { await this.d.auth.requireSession(token); throw new ServiceError('MEMBERSHIP_LINK_CONFLICT', 409); }
    if (link.billing_account_id !== challenge.billingAccountId) throw new ServiceError('MEMBERSHIP_LINK_CONFLICT', 409);
    return { linked: true as const };
  }
  async status(ownerId: string) {
    const link = await this.d.db.prepare(`SELECT l.billing_account_id FROM pa_membership_links l
      JOIN pa_owners o ON o.owner_id=l.owner_id WHERE l.owner_id=? AND o.disabled=0`)
      .bind(ownerId).first<{ billing_account_id: string }>();
    return link ? this.d.authority.status(link.billing_account_id) : 'unknown';
  }
  /** Retention must pause, rather than guess expiry, when billing is unavailable. */
  async statusForRetention(ownerId: string) {
    const link = await this.d.db.prepare(`SELECT l.billing_account_id FROM pa_membership_links l
      JOIN pa_owners o ON o.owner_id=l.owner_id WHERE l.owner_id=? AND o.disabled=0`)
      .bind(ownerId).first<{ billing_account_id: string }>();
    if (!link) return { linked: false as const, status: 'unknown' as const };
    try { return { linked: true as const, status: await this.d.authority.status(link.billing_account_id) }; }
    catch { return { linked: true as const, status: 'unknown' as const }; }
  }
  async forSession(token: string) {
    const session = await this.d.auth.requireSession(token);
    const link = await this.d.db.prepare('SELECT billing_account_id FROM pa_membership_links WHERE owner_id=?')
      .bind(session.ownerId).first<{ billing_account_id: string }>();
    const status = link ? await this.status(session.ownerId) : 'unknown';
    await this.d.auth.requireSession(token);
    return { linked: link !== null, status };
  }
}
