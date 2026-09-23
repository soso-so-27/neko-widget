import { ServiceError, type KeyCustody } from './contracts';
import { S3RecoveryCopy, type RecoveryObject } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const ownerKeyPattern = new RegExp(`^recovery/v1/(${uuid})/owner/${uuid}$`, 'u');
const hex = /^[0-9a-f]{64}$/u;
const unavailable = () => new ServiceError('OWNER_RECOVERY_UNAVAILABLE', 503);
const safeInteger = (value: unknown, minimum = 0): value is number =>
  Number.isSafeInteger(value) && (value as number) >= minimum;

export interface OwnerRecoveryImage {
  ownerId: string;
  /** A monotonic D1 generation assigned to every owner-state mutation. */
  generation: number;
  identityKey: string;
  epoch: number;
  disabled: boolean;
  purgeFenceId: string | null;
  createdAt: number;
  credential: { ownerEpoch: number; sealedCredentials: Uint8Array; updatedAt: number };
  contact: { sealedEmail: Uint8Array; emailTag: string | null;
    verifiedAt: number; updatedAt: number } | null;
  billing: { accountId: string; createdAt: number } | null;
  retention: { revision: number; episode: number; status: 'active' | 'grace' | 'expired' | 'unknown';
    checkedAt: number; expiredAt: number | null; dueAt: number | null; pausedAt: number | null;
    noticeNotBeforeAt: number; finalNoticeDeliveredAt: number | null;
    finalNoticeReceipt: string | null } | null;
}

type EncodedImage = Omit<OwnerRecoveryImage, 'credential' | 'contact'> & {
  version: 1;
  credential: { ownerEpoch: number; sealedCredentialsBase64: string; updatedAt: number };
  contact: { sealedEmailBase64: string; emailTag: string | null;
    verifiedAt: number; updatedAt: number } | null;
};
interface OwnerRow {
  owner_id: string; generation: number; identity_key: string; epoch: number; disabled: number;
  purge_fence_id: string | null; created_at: number; credential_epoch: number;
  sealed_credentials: unknown; credential_updated_at: number; sealed_email: unknown;
  email_tag: string | null; contact_source: string | null; verified_at: number | null;
  contact_updated_at: number | null; billing_account_id: string | null;
  billing_created_at: number | null; retention_revision: number | null;
  episode: number | null; verified_status: string | null;
  checked_at: number | null; expired_at: number | null; due_at: number | null;
  paused_at: number | null; notice_not_before_at: number | null;
  final_notice_delivered_at: number | null; final_notice_receipt: string | null;
}
interface RefRow { object_key: string; version_id: string; sha256: string; bytes: number }

function blob(value: unknown, maximum: number): Uint8Array {
  const bytes = value instanceof ArrayBuffer ? new Uint8Array(value)
    : value instanceof Uint8Array ? value
    : Array.isArray(value) && value.every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255)
      ? Uint8Array.from(value) : null;
  if (!bytes || !bytes.length || bytes.length > maximum) throw unavailable();
  return bytes.slice();
}

function encoded(bytes: Uint8Array, maximum: number): string {
  if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > maximum) throw unavailable();
  let raw = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    raw += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(raw);
}
function decoded(value: unknown, maximum: number): Uint8Array {
  if (typeof value !== 'string' || value.length > Math.ceil(maximum / 3) * 4) throw unavailable();
  try {
    const raw = atob(value);
    if (!raw.length || raw.length > maximum || btoa(raw) !== value) throw unavailable();
    return Uint8Array.from(raw, char => char.charCodeAt(0));
  } catch { throw unavailable(); }
}
function exact(value: unknown, keys: string): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join(',') === keys;
}
function valid(image: OwnerRecoveryImage): void {
  if (!ownerPattern.test(image.ownerId) || !safeInteger(image.generation, 1)
    || typeof image.identityKey !== 'string' || !hex.test(image.identityKey)
    || !safeInteger(image.epoch)
    || typeof image.disabled !== 'boolean'
    || (image.purgeFenceId !== null && !ownerPattern.test(image.purgeFenceId))
    || !safeInteger(image.createdAt, 1)
    || !image.credential || typeof image.credential !== 'object'
    || !safeInteger(image.credential?.ownerEpoch)
    || image.credential.ownerEpoch > image.epoch
    || !safeInteger(image.credential.updatedAt, image.createdAt)) throw unavailable();
  encoded(image.credential.sealedCredentials, 131_072);
  if (!image.disabled && image.credential.ownerEpoch !== image.epoch) throw unavailable();
  if (image.purgeFenceId !== null && !image.disabled) throw unavailable();
  if (image.contact !== null) {
    if (!image.contact || typeof image.contact !== 'object') throw unavailable();
    encoded(image.contact.sealedEmail, 8192);
    if (image.contact.emailTag !== null && !hex.test(image.contact.emailTag)) throw unavailable();
    if (!safeInteger(image.contact.verifiedAt, image.createdAt)
      || !safeInteger(image.contact.updatedAt, image.contact.verifiedAt)) throw unavailable();
  }
  if (image.billing !== null && (!image.billing || typeof image.billing !== 'object'
    || typeof image.billing.accountId !== 'string' || !ownerPattern.test(image.billing.accountId)
    || !safeInteger(image.billing.createdAt, image.createdAt))) throw unavailable();
  if (image.retention !== null) {
    const r = image.retention;
    if (!r || typeof r !== 'object' || !safeInteger(r.revision, 1) || !safeInteger(r.episode)
      || !['active', 'grace', 'expired', 'unknown'].includes(r.status)
      || !safeInteger(r.checkedAt) || !safeInteger(r.noticeNotBeforeAt)
      || (r.expiredAt !== null && !safeInteger(r.expiredAt))
      || (r.dueAt !== null && !safeInteger(r.dueAt, 1))
      || (r.pausedAt !== null && !safeInteger(r.pausedAt))
      || (r.finalNoticeDeliveredAt !== null && !safeInteger(r.finalNoticeDeliveredAt))
      || (r.finalNoticeReceipt !== null && (typeof r.finalNoticeReceipt !== 'string'
        || !/^[A-Za-z0-9._:-]{16,256}$/u.test(r.finalNoticeReceipt)))
      || ((r.finalNoticeDeliveredAt === null) !== (r.finalNoticeReceipt === null))
      || ((r.expiredAt === null) !== (r.dueAt === null))
      || (r.dueAt !== null && r.expiredAt !== null && r.dueAt <= r.expiredAt)) throw unavailable();
  }
}

/** This protects an owner-state image independently of D1. It does not
 * capture D1, assign a generation, prove that every generation was copied,
 * or authorize a restore/deletion. Callers must add those gates separately.
 */
export class OwnerRecoveryCopy {
  constructor(private readonly keys: KeyCustody, private readonly s3: S3RecoveryCopy) {}

  /** One SQL statement reads a consistent owner row across all source tables.
   * Temporary sessions are deliberately not part of a restore image. A
   * restored owner must sign in again, and old notice evidence is not treated
   * as deletion authority without the independent delivery ledger.
   */
  async capture(db: D1Database, ownerId: string): Promise<OwnerRecoveryImage> {
    if (!ownerPattern.test(ownerId)) throw unavailable();
    try {
      const row = await db.prepare(`SELECT o.owner_id,g.generation,o.identity_key,o.epoch,o.disabled,
        o.purge_fence_id,o.created_at,c.owner_epoch AS credential_epoch,
        c.sealed_credentials,c.updated_at AS credential_updated_at,
        n.sealed_email,n.email_tag,n.source AS contact_source,n.verified_at,
        n.updated_at AS contact_updated_at,l.billing_account_id,l.created_at AS billing_created_at,
        r.revision AS retention_revision,r.episode,r.verified_status,r.checked_at,
        r.expired_at,r.due_at,r.paused_at,r.notice_not_before_at,
        r.final_notice_delivered_at,r.final_notice_receipt
        FROM pa_owners o JOIN pa_owner_recovery_generations g ON g.owner_id=o.owner_id
        JOIN pa_identity_credentials c ON c.owner_id=o.owner_id
        LEFT JOIN pa_notice_contacts n ON n.owner_id=o.owner_id
        LEFT JOIN pa_membership_links l ON l.owner_id=o.owner_id
        LEFT JOIN pa_retention r ON r.owner_id=o.owner_id
        WHERE o.owner_id=?`).bind(ownerId).first<OwnerRow>();
      if (!row || (row.disabled !== 0 && row.disabled !== 1)
        || (row.sealed_email !== null && row.contact_source !== 'apple')) throw unavailable();
      const image: OwnerRecoveryImage = { ownerId, generation: row.generation,
        identityKey: row.identity_key, epoch: row.epoch, disabled: row.disabled === 1,
        purgeFenceId: row.purge_fence_id, createdAt: row.created_at,
        credential: { ownerEpoch: row.credential_epoch,
          sealedCredentials: blob(row.sealed_credentials, 131_072),
          updatedAt: row.credential_updated_at },
        contact: row.sealed_email === null ? null : {
          sealedEmail: blob(row.sealed_email, 8192), emailTag: row.email_tag,
          verifiedAt: row.verified_at!, updatedAt: row.contact_updated_at! },
        billing: row.billing_account_id === null ? null : {
          accountId: row.billing_account_id, createdAt: row.billing_created_at! },
        retention: row.retention_revision === null ? null : {
          revision: row.retention_revision, episode: row.episode!,
          status: row.verified_status as NonNullable<OwnerRecoveryImage['retention']>['status'],
          checkedAt: row.checked_at!, expiredAt: row.expired_at, dueAt: row.due_at,
          pausedAt: row.paused_at, noticeNotBeforeAt: row.notice_not_before_at!,
          finalNoticeDeliveredAt: row.final_notice_delivered_at,
          finalNoticeReceipt: row.final_notice_receipt },
      };
      valid(image);
      return image;
    } catch { throw unavailable(); }
  }

  /** Capture, independently verify S3, then bind the exact object version to
   * the still-current D1 generation. A racing owner mutation fails closed.
   * The caller must not acknowledge its mutation before this returns.
   */
  async copyCurrent(db: D1Database, ownerId: string, now: number): Promise<RecoveryObject> {
    if (!safeInteger(now, 1)) throw unavailable();
    const image = await this.capture(db, ownerId);
    try {
      const current = async (): Promise<RecoveryObject | null> => {
        const row = await db.prepare(`SELECT v.object_key,v.version_id,v.sha256,v.bytes
          FROM pa_owner_recovery_versions v JOIN pa_owner_recovery_generations g
            ON g.owner_id=v.owner_id AND g.generation=v.generation
          WHERE v.owner_id=? AND v.generation=?`).bind(ownerId, image.generation).first<RefRow>();
        return row ? { key: row.object_key, versionId: row.version_id,
          sha256: row.sha256, bytes: row.bytes } : null;
      };
      let reference = await current();
      if (!reference) {
        const written = await this.copy(image);
        await db.prepare(`INSERT INTO pa_owner_recovery_versions(owner_id,generation,object_key,
          version_id,sha256,bytes,confirmed_at)
          SELECT ?,g.generation,?,?,?,?,? FROM pa_owner_recovery_generations g
          WHERE g.owner_id=? AND g.generation=?
          ON CONFLICT(owner_id,generation) DO NOTHING`)
          .bind(ownerId, written.key, written.versionId, written.sha256, written.bytes,
            now, ownerId, image.generation).run();
        reference = await current();
      }
      if (!reference) throw unavailable();
      const restored = await this.read(ownerId, reference);
      if (JSON.stringify(restored) !== JSON.stringify(image)) throw unavailable();
      return reference;
    } catch { throw unavailable(); }
  }

  async copy(image: OwnerRecoveryImage): Promise<RecoveryObject> {
    valid(image);
    const payload: EncodedImage = { ...image, version: 1,
      credential: { ownerEpoch: image.credential.ownerEpoch,
        sealedCredentialsBase64: encoded(image.credential.sealedCredentials, 131_072),
        updatedAt: image.credential.updatedAt },
      contact: image.contact === null ? null : {
        sealedEmailBase64: encoded(image.contact.sealedEmail, 8192),
        emailTag: image.contact.emailTag, verifiedAt: image.contact.verifiedAt,
        updatedAt: image.contact.updatedAt },
    };
    try {
      const sealed = await this.keys.seal(new TextEncoder().encode(JSON.stringify(payload)),
        { ownerId: image.ownerId, purpose: 'recovery' });
      return await this.s3.putVersioned(
        `recovery/v1/${image.ownerId}/owner/${crypto.randomUUID()}`, sealed);
    } catch { throw unavailable(); }
  }

  async read(ownerId: string, reference: RecoveryObject): Promise<OwnerRecoveryImage> {
    if (!ownerPattern.test(ownerId) || ownerKeyPattern.exec(reference.key)?.[1] !== ownerId
      || !hex.test(reference.sha256) || !safeInteger(reference.bytes, 1)
      || typeof reference.versionId !== 'string' || !reference.versionId
      || reference.versionId === 'null') throw unavailable();
    try {
      const sealed = await this.s3.getVerified(reference);
      const opened = await this.keys.open(sealed, { ownerId, purpose: 'recovery' });
      const payload: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(opened));
      if (!exact(payload, 'billing,contact,createdAt,credential,disabled,epoch,generation,identityKey,ownerId,purgeFenceId,retention,version')
        || payload.version !== 1 || payload.ownerId !== ownerId
        || !exact(payload.credential, 'ownerEpoch,sealedCredentialsBase64,updatedAt')
        || (payload.contact !== null && !exact(payload.contact,
          'emailTag,sealedEmailBase64,updatedAt,verifiedAt'))
        || (payload.billing !== null && !exact(payload.billing, 'accountId,createdAt'))
        || (payload.retention !== null && !exact(payload.retention,
          'checkedAt,dueAt,episode,expiredAt,finalNoticeDeliveredAt,finalNoticeReceipt,noticeNotBeforeAt,pausedAt,revision,status'))) {
        throw unavailable();
      }
      const credential = payload.credential;
      const contact = payload.contact;
      const { version: _version, ...ownerFields } = payload;
      const image = { ...ownerFields,
        credential: { ownerEpoch: credential.ownerEpoch,
          sealedCredentials: decoded(credential.sealedCredentialsBase64, 131_072),
          updatedAt: credential.updatedAt },
        contact: contact === null ? null : { sealedEmail: decoded(contact.sealedEmailBase64, 8192),
          emailTag: contact.emailTag, verifiedAt: contact.verifiedAt, updatedAt: contact.updatedAt },
      } as OwnerRecoveryImage;
      valid(image);
      return image;
    } catch { throw unavailable(); }
  }
}
