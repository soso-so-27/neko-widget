import { type AuthDependencies, type DeviceBinding, type DeviceGrant, type IdentityVerifier,
  type SessionCredential, type VerifiedIdentity, randomToken, ServiceError, sha256 } from './contracts';
import { deviceBinding, verifyDeviceProof } from './device-proof';
import { identityIndexKey, indexedOwnerIdentity } from './identity-index';

const ACCESS_MS = 15 * 60_000;
const CHALLENGE_MS = 5 * 60_000;
const DAY_MS = 24 * 60 * 60_000;
const IDLE_MS = 30 * DAY_MS;
const APPLE = 'https://appleid.apple.com';
const opaque = /^[A-Za-z0-9_-]{43}$/u;
const grantPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const denied = () => new ServiceError('unauthorized', 401);
const unavailable = () => new ServiceError('auth_unavailable', 503);
const safe = (error: unknown) => error instanceof ServiceError ? error : unavailable();
type Purpose = 'renew' | 'revoke';
interface GrantRow { grant_id: string; owner_id: string; owner_epoch: number; device_binding: string;
  idle_expires_at: number; identity_key: string; }
interface CheckRow { updated_at: number; credential_hash: string;
  credential_updated_at: number; verified_at: number; attempt_after: number; lease_id: string | null; }
interface ChallengeRow { challenge_id: string; nonce: string; expires_at: number; }
export interface DeviceSessionRequest { grantId: string; challengeId: string; deviceProof: string; origin: string; }
const liveOwner = `EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=g.owner_id
  AND o.epoch=g.owner_epoch AND o.disabled=0
  AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d WHERE d.owner_id=o.owner_id))`;
const recovered = `((SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=0
  OR EXISTS(SELECT 1 FROM pa_owner_recovery_generations r JOIN pa_owner_recovery_versions v
    ON v.owner_id=r.owner_id AND v.generation=r.generation WHERE r.owner_id=g.owner_id))`;
const blob = (value: unknown): Uint8Array => {
  const bytes = value instanceof Uint8Array ? value : value instanceof ArrayBuffer ? new Uint8Array(value)
    : Array.isArray(value) && value.every(n => Number.isInteger(n) && n >= 0 && n <= 255) ? Uint8Array.from(value) : null;
  if (!bytes || !bytes.length || bytes.length > 131_072) throw unavailable();
  return bytes;
};

/** Device possession renews only a short access token. The grant is not a
 * bearer credential, never appears in an owner recovery image, and never
 * changes membership, storage consent, owner identity or record data. */
export class DeviceSessions {
  constructor(private readonly d: AuthDependencies) {}

  private now(): number {
    const now = this.d.now();
    if (!Number.isSafeInteger(now) || now < 0 || now > 8_640_000_000_000_000 - IDLE_MS) throw unavailable();
    return now;
  }

  async initialGrant(identity: VerifiedIdentity, ownerId: string, epoch: number, now: number,
    sealed: Uint8Array): Promise<{ grant?: DeviceGrant; statements: D1PreparedStatement[] }> {
    if (identity.issuer !== APPLE) {
      if (identity.deviceBinding) throw denied();
      return { statements: [] };
    }
    const statements = [this.d.db.prepare(`INSERT INTO pa_device_identity_checks
      (owner_id,owner_epoch,credential_hash,credential_updated_at,verified_at,attempt_after,lease_id)
      SELECT c.owner_id,c.owner_epoch,?,c.updated_at,?,?,NULL FROM pa_identity_credentials c
      JOIN pa_owners o ON o.owner_id=c.owner_id WHERE c.owner_id=? AND c.owner_epoch=?
        AND c.sealed_credentials=? AND o.epoch=c.owner_epoch AND o.disabled=0
        AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d WHERE d.owner_id=o.owner_id)
      ON CONFLICT(owner_id) DO UPDATE SET owner_epoch=excluded.owner_epoch,
        credential_hash=excluded.credential_hash,credential_updated_at=excluded.credential_updated_at,
        verified_at=excluded.verified_at,attempt_after=excluded.attempt_after,lease_id=NULL`)
      .bind(await sha256(sealed), now, now + DAY_MS, ownerId, epoch, sealed.slice().buffer)];
    if (!identity.deviceBinding) return { statements };
    const bound = await deviceBinding(identity.deviceBinding.publicKey, identity.deviceBinding.origin);
    if (bound.thumbprint !== identity.deviceBinding.thumbprint) throw denied();
    const grantId = crypto.randomUUID();
    statements.push(this.d.db.prepare(`INSERT INTO pa_device_session_grants
      (grant_id,owner_id,owner_epoch,device_binding,created_at,idle_expires_at)
      SELECT ?,o.owner_id,o.epoch,?,?,? FROM pa_owners o JOIN pa_device_identity_checks c
        ON c.owner_id=o.owner_id AND c.owner_epoch=o.epoch
      WHERE o.owner_id=? AND o.epoch=? AND o.disabled=0 AND c.credential_hash=?
        AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d WHERE d.owner_id=o.owner_id)`)
      .bind(grantId, JSON.stringify(bound), now, now + IDLE_MS, ownerId, epoch, await sha256(sealed)));
    return { grant: { grantId, idleExpiresAt: new Date(now + IDLE_MS).toISOString(), appleUserID: identity.subject }, statements };
  }

  private async grant(grantId: string, origin: string, purpose: Purpose): Promise<GrantRow> {
    if (!grantPattern.test(grantId)) throw denied();
    const row = await this.d.db.prepare(`SELECT g.*,o.identity_key FROM pa_device_session_grants g
      JOIN pa_owners o ON o.owner_id=g.owner_id WHERE g.grant_id=? AND g.revoked_at IS NULL
        AND (?='revoke' OR g.idle_expires_at>?) AND ${liveOwner}`)
      .bind(grantId, purpose, this.now()).first<GrantRow>();
    if (!row || (JSON.parse(row.device_binding) as DeviceBinding).origin !== origin) throw denied();
    await this.d.ownerDeletion?.assertNotRequested(row.owner_id);
    return row;
  }

  async issueChallenge(grantId: string, purpose: Purpose, origin: string): Promise<{
    challengeId: string; nonce: string; expiresAt: string;
  }> {
    try {
      if (purpose !== 'renew' && purpose !== 'revoke') throw denied();
      const grant = await this.grant(grantId, origin, purpose);
      const now = this.now();
      // At most two challenge rows per device. A public grant ID cannot consume
      // or replace an unexpired challenge by requesting another nonce.
      await this.d.db.prepare(`INSERT INTO pa_device_session_challenges
        (challenge_id,owner_id,grant_id,purpose,nonce,created_at,expires_at)
        SELECT ?,g.owner_id,g.grant_id,?,?,?,? FROM pa_device_session_grants g
        WHERE g.grant_id=? AND g.owner_epoch=? AND g.revoked_at IS NULL AND ${liveOwner}
        ON CONFLICT(grant_id,purpose) DO UPDATE SET challenge_id=excluded.challenge_id,
          nonce=excluded.nonce,created_at=excluded.created_at,expires_at=excluded.expires_at,consumed_by=NULL
        WHERE pa_device_session_challenges.expires_at<=excluded.created_at
          OR pa_device_session_challenges.consumed_by IS NOT NULL`)
        .bind(randomToken(), purpose, randomToken(), now, now + CHALLENGE_MS, grantId, grant.owner_epoch).run();
      const row = await this.d.db.prepare(`SELECT challenge_id,nonce,expires_at FROM pa_device_session_challenges
        WHERE grant_id=? AND purpose=? AND expires_at>? AND consumed_by IS NULL`)
        .bind(grantId, purpose, now).first<ChallengeRow>();
      if (!row) throw denied();
      return { challengeId: row.challenge_id, nonce: row.nonce, expiresAt: new Date(row.expires_at).toISOString() };
    } catch (error) { throw safe(error); }
  }

  private async proof(input: DeviceSessionRequest, purpose: Purpose): Promise<GrantRow> {
    if (!opaque.test(input.challengeId)) throw denied();
    const grant = await this.grant(input.grantId, input.origin, purpose);
    const row = await this.d.db.prepare(`SELECT challenge_id,nonce,expires_at FROM pa_device_session_challenges
      WHERE challenge_id=? AND grant_id=? AND purpose=? AND expires_at>? AND consumed_by IS NULL`)
      .bind(input.challengeId, input.grantId, purpose, this.now()).first<ChallengeRow>();
    if (!row) throw denied();
    await verifyDeviceProof(input.deviceProof, JSON.parse(grant.device_binding) as DeviceBinding, {
      challengeId: input.challengeId, subject: input.grantId, nonce: row.nonce, now: this.now(), origin: input.origin,
      path: purpose === 'renew' ? '/v1/auth/session-renewals' : '/v1/auth/session-revocations',
    });
    return grant;
  }

  private async identityCurrent(grant: GrantRow, verifier: IdentityVerifier): Promise<void> {
    const db = this.d.db;
    const now = this.now();
    const current = await db.prepare(`SELECT c.updated_at,k.* FROM pa_identity_credentials c
      JOIN pa_device_identity_checks k ON k.owner_id=c.owner_id AND k.owner_epoch=c.owner_epoch
        AND k.credential_updated_at=c.updated_at
      WHERE c.owner_id=? AND c.owner_epoch=?`).bind(grant.owner_id, grant.owner_epoch).first<CheckRow>();
    if (!current || current.verified_at > now) throw unavailable();
    if (current.verified_at > now - DAY_MS && current.lease_id === null) return;
    if (!verifier.verifyRefreshIdentity || current.attempt_after > now) throw unavailable();
    const lease = randomToken();
    // Strictly at most one remote validation attempt per owner per 24 hours,
    // including timeouts. A transient outage preserves credentials but stops
    // renewal until the next allowed attempt or explicit Apple sign-in.
    const claimed = await db.prepare(`UPDATE pa_device_identity_checks SET lease_id=?,attempt_after=?
      WHERE owner_id=? AND owner_epoch=? AND credential_hash=? AND credential_updated_at=?
        AND attempt_after<=? AND verified_at<=? AND EXISTS(SELECT 1 FROM pa_device_session_grants g
          WHERE g.grant_id=? AND g.revoked_at IS NULL AND g.idle_expires_at>? AND ${liveOwner})`)
      .bind(lease, now + DAY_MS, grant.owner_id, grant.owner_epoch, current.credential_hash,
        current.updated_at, now, now - DAY_MS, grant.grant_id, now).run();
    if (claimed.meta.changes !== 1) throw unavailable();
    try {
      const row = await db.prepare(`SELECT sealed_credentials FROM pa_identity_credentials
        WHERE owner_id=? AND owner_epoch=? AND updated_at=?`)
        .bind(grant.owner_id, grant.owner_epoch, current.updated_at).first<{ sealed_credentials: unknown }>();
      if (!row) throw unavailable();
      const sealed = blob(row.sealed_credentials);
      if (await sha256(sealed) !== current.credential_hash) throw unavailable();
      const opened = await this.d.keys.open(sealed, { ownerId: grant.owner_id, purpose: 'identity' });
      let identity: VerifiedIdentity;
      try { identity = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(opened)) as VerifiedIdentity; }
      finally { opened.fill(0); }
      if (!identity || Object.keys(identity).sort().join(',') !== 'issuer,refreshToken,subject'
        || identity.issuer !== APPLE || typeof identity.subject !== 'string' || !identity.subject
        || identity.subject.length > 255 || typeof identity.refreshToken !== 'string'
        || !identity.refreshToken || identity.refreshToken.length > 16_384
        || await indexedOwnerIdentity(await identityIndexKey(this.d.identityIndexSecret), identity.issuer,
          identity.subject) !== grant.identity_key) throw denied();
      const verified = await verifier.verifyRefreshIdentity(identity);
      if (verified.issuer !== identity.issuer || verified.subject !== identity.subject
        || typeof verified.refreshToken !== 'string' || !verified.refreshToken
        || verified.refreshToken.length > 16_384) throw denied();
      await this.d.ownerDeletion?.assertNotRequested(grant.owner_id);
      let replacement = sealed;
      const rotated = verified.refreshToken !== identity.refreshToken;
      if (rotated) {
        const bytes = new TextEncoder().encode(JSON.stringify({ issuer: identity.issuer,
          subject: identity.subject, refreshToken: verified.refreshToken }));
        try { replacement = blob(await this.d.keys.seal(bytes, { ownerId: grant.owner_id, purpose: 'identity' })); }
        finally { bytes.fill(0); }
      }
      const completed = this.now();
      const updated = rotated ? Math.max(current.updated_at + 1, completed) : current.updated_at;
      const guard = `EXISTS(SELECT 1 FROM pa_device_identity_checks k WHERE k.owner_id=?
        AND k.owner_epoch=? AND k.lease_id=? AND k.credential_hash=?)
        AND EXISTS(SELECT 1 FROM pa_device_session_grants g WHERE g.grant_id=?
          AND g.revoked_at IS NULL AND g.idle_expires_at>? AND ${liveOwner})`;
      const statements: D1PreparedStatement[] = [];
      if (rotated) statements.push(db.prepare(`UPDATE pa_identity_credentials SET sealed_credentials=?,updated_at=?
        WHERE owner_id=? AND owner_epoch=? AND sealed_credentials=? AND updated_at=? AND ${guard} RETURNING owner_id`)
        .bind(replacement.slice().buffer, updated, grant.owner_id, grant.owner_epoch, sealed.slice().buffer,
          current.updated_at, grant.owner_id, grant.owner_epoch, lease, current.credential_hash, grant.grant_id, completed));
      statements.push(db.prepare(`UPDATE pa_device_identity_checks SET credential_hash=?,credential_updated_at=?,
        verified_at=?,lease_id=NULL WHERE owner_id=? AND owner_epoch=? AND lease_id=? AND credential_hash=?
        AND EXISTS(SELECT 1 FROM pa_identity_credentials c WHERE c.owner_id=? AND c.owner_epoch=?
          AND c.sealed_credentials=? AND c.updated_at=?)
        AND EXISTS(SELECT 1 FROM pa_device_session_grants g WHERE g.grant_id=? AND g.revoked_at IS NULL
          AND g.idle_expires_at>? AND ${liveOwner}) RETURNING owner_id`)
        .bind(await sha256(replacement), updated, completed, grant.owner_id, grant.owner_epoch, lease,
          current.credential_hash, grant.owner_id, grant.owner_epoch, replacement.slice().buffer, updated,
          grant.grant_id, completed));
      const results = await db.batch(statements);
      if (results.some(result => result.results.length !== 1)) throw unavailable();
      if (rotated) {
        if (this.d.requireOwnerRecovery && !this.d.ownerRecovery) throw unavailable();
        await this.d.ownerRecovery?.copyCurrent(db, grant.owner_id, completed);
      }
    } catch (error) {
      if (error instanceof ServiceError && error.code === 'APPLE_AUTHORIZATION_REJECTED') {
        // A late failure must not revoke a newer explicit Apple sign-in.
        await db.prepare(`UPDATE pa_device_session_grants SET revoked_at=? WHERE owner_id=?
          AND owner_epoch=? AND revoked_at IS NULL AND EXISTS(SELECT 1 FROM pa_device_identity_checks k
            JOIN pa_identity_credentials c ON c.owner_id=k.owner_id AND c.updated_at=k.credential_updated_at
            WHERE k.owner_id=? AND k.owner_epoch=? AND k.lease_id=? AND k.credential_hash=?)`)
          .bind(this.now(), grant.owner_id, grant.owner_epoch, grant.owner_id, grant.owner_epoch,
            lease, current.credential_hash).run();
      }
      throw error;
    }
  }

  async renew(input: DeviceSessionRequest, verifier: IdentityVerifier): Promise<SessionCredential> {
    try {
      const grant = await this.proof(input, 'renew');
      // A verified device may advance one bounded inventory repair before
      // access renewal. It receives no token until the existing covered-owner
      // SQL guard succeeds; unknown/deleted/revoked authority still stops here.
      const repair=await this.d.ownerRecovery?.recoverStagedMetadata?.(this.d.db,grant.owner_id,this.now());
      if(repair?.status==='pending')throw unavailable();
      await this.identityCurrent(grant, verifier);
      // The external deletion receipt is checked again after provider/key I/O.
      await this.d.ownerDeletion?.assertNotRequested(grant.owner_id);
      const now = this.now();
      const token = randomToken();
      const hash = await sha256(token);
      const batch = await this.d.db.batch([
        this.d.db.prepare(`UPDATE pa_device_session_challenges SET consumed_by=? WHERE challenge_id=?
          AND grant_id=? AND purpose='renew' AND consumed_by IS NULL AND expires_at>?
          AND EXISTS(SELECT 1 FROM pa_device_session_grants g JOIN pa_device_identity_checks k
            ON k.owner_id=g.owner_id AND k.owner_epoch=g.owner_epoch
            JOIN pa_identity_credentials c ON c.owner_id=k.owner_id AND c.owner_epoch=k.owner_epoch
              AND c.updated_at=k.credential_updated_at
            WHERE g.grant_id=? AND g.revoked_at IS NULL AND g.idle_expires_at>?
              AND k.verified_at>? AND k.verified_at<=? AND k.lease_id IS NULL AND ${liveOwner} AND ${recovered})`)
          .bind(hash, input.challengeId, input.grantId, now, input.grantId, now, now - DAY_MS, now),
        this.d.db.prepare(`INSERT INTO pa_sessions(session_hash,owner_id,owner_epoch,created_at,expires_at,device_grant_id)
          SELECT ?,g.owner_id,g.owner_epoch,?,?,g.grant_id FROM pa_device_session_grants g
          JOIN pa_device_session_challenges c ON c.grant_id=g.grant_id
          WHERE c.challenge_id=? AND c.consumed_by=? AND g.revoked_at IS NULL AND ${liveOwner}`)
          .bind(hash, now, now + ACCESS_MS, input.challengeId, hash),
        this.d.db.prepare(`UPDATE pa_device_session_grants SET idle_expires_at=? WHERE grant_id=?
          AND EXISTS(SELECT 1 FROM pa_sessions s WHERE s.session_hash=? AND s.device_grant_id=grant_id)`)
          .bind(now + IDLE_MS, input.grantId, hash),
      ]);
      if (batch.some(result => result.meta.changes !== 1)) {
        // A current owner snapshot or identity check may be temporarily pending.
        // Preserve a valid device credential without issuing access. Recheck the
        // proof so consumed, expired or revoked authority still fails as before.
        await this.proof(input, 'renew');
        throw unavailable();
      }
      return { token, ownerId: grant.owner_id, expiresAt: new Date(now + ACCESS_MS).toISOString(),
        deviceGrant: { grantId: input.grantId, idleExpiresAt: new Date(now + IDLE_MS).toISOString() } };
    } catch (error) { throw safe(error); }
  }

  async revoke(input: DeviceSessionRequest): Promise<void> {
    try {
      await this.proof(input, 'revoke');
      const marker = randomToken();
      const now = this.now();
      const batch = await this.d.db.batch([
        this.d.db.prepare(`UPDATE pa_device_session_challenges SET consumed_by=? WHERE challenge_id=?
          AND grant_id=? AND purpose='revoke' AND consumed_by IS NULL AND expires_at>?
          AND EXISTS(SELECT 1 FROM pa_device_session_grants g WHERE g.grant_id=?
            AND g.revoked_at IS NULL AND ${liveOwner})`)
          .bind(marker, input.challengeId, input.grantId, now, input.grantId),
        this.d.db.prepare(`UPDATE pa_device_session_grants SET revoked_at=? WHERE grant_id=? AND revoked_at IS NULL
          AND EXISTS(SELECT 1 FROM pa_device_session_challenges c WHERE c.challenge_id=? AND c.consumed_by=?) RETURNING grant_id`)
          .bind(now, input.grantId, input.challengeId, marker),
      ]);
      if (batch[0]?.meta.changes !== 1 || batch[1]?.results.length !== 1) throw denied();
    } catch (error) { throw safe(error); }
  }
}

/** Invoked only by the existing bounded cleanup switch. No archive, consent,
 * recovery image or owner identity is removed. Child rows precede grants. */
export function deviceSessionCleanupStatements(db: D1Database, now: number, limit: number): D1PreparedStatement[] {
  return [
    db.prepare(`DELETE FROM pa_device_session_challenges WHERE challenge_id IN
      (SELECT c.challenge_id FROM pa_device_session_challenges c JOIN pa_device_session_grants g
        ON g.grant_id=c.grant_id WHERE c.expires_at<=? OR g.revoked_at IS NOT NULL
          OR g.idle_expires_at<=? ORDER BY c.expires_at,c.challenge_id LIMIT ?)`).bind(now, now, limit),
    db.prepare(`DELETE FROM pa_device_session_grants WHERE grant_id IN
      (SELECT g.grant_id FROM pa_device_session_grants g WHERE (g.idle_expires_at<=? OR g.revoked_at IS NOT NULL)
        AND NOT EXISTS(SELECT 1 FROM pa_sessions s WHERE s.device_grant_id=g.grant_id)
        AND NOT EXISTS(SELECT 1 FROM pa_device_session_challenges c WHERE c.grant_id=g.grant_id)
        ORDER BY g.idle_expires_at,g.grant_id LIMIT ?)`).bind(now, limit),
    db.prepare(`DELETE FROM pa_device_identity_checks WHERE owner_id IN
      (SELECT k.owner_id FROM pa_device_identity_checks k WHERE NOT EXISTS
        (SELECT 1 FROM pa_device_session_grants g WHERE g.owner_id=k.owner_id)
        ORDER BY k.owner_id LIMIT ?)`).bind(limit),
  ];
}
