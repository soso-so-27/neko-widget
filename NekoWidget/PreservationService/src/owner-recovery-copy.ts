import { ServiceError, contactEmailValid, type KeyCustody } from './contracts';
import { identityIndexKey, indexedNoticeEmail, indexedOwnerIdentity } from './identity-index';
import { S3RecoveryCopy, type RecoveryObject } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const ownerKeyPattern = new RegExp(`^recovery/v1/(${uuid})/owner/${uuid}$`, 'u');
const recordPattern = new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', 'u');
const markerKeyPattern = new RegExp(`^recovery/v1/(${uuid})/manifest/${uuid}$`, 'u');
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
  /** Current D1 record inventory, including tombstones. A missing commit
   * marker makes the whole owner image ineligible for acknowledgement. */
  inventoryGeneration: number;
  records: { recordId: string; revision: number; deleted: boolean; marker: RecoveryObject }[];
  retention: { revision: number; episode: number; status: 'active' | 'grace' | 'expired' | 'unknown';
    checkedAt: number; expiredAt: number | null; dueAt: number | null; pausedAt: number | null;
    noticeNotBeforeAt: number; finalNoticeDeliveredAt: number | null;
    finalNoticeReceipt: string | null } | null;
}

type EncodedImage = Omit<OwnerRecoveryImage, 'credential' | 'contact'> & {
  version: 2;
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
  inventory_generation: number; records_json: string;
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
  if (!safeInteger(image.inventoryGeneration) || !Array.isArray(image.records)
    || image.records.length > 100_000 || image.inventoryGeneration < image.records.length) throw unavailable();
  let previousId = '';
  for (const record of image.records) {
    if (!exact(record, 'deleted,marker,recordId,revision')
      || !recordPattern.test(record.recordId) || record.recordId <= previousId
      || !safeInteger(record.revision, 1) || typeof record.deleted !== 'boolean'
      || !exact(record.marker, 'bytes,key,sha256,versionId')
      || markerKeyPattern.exec(record.marker.key)?.[1] !== image.ownerId
      || typeof record.marker.versionId !== 'string' || !record.marker.versionId
      || record.marker.versionId === 'null' || !hex.test(record.marker.sha256)
      || !safeInteger(record.marker.bytes, 1)) throw unavailable();
    previousId = record.recordId;
  }
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
  private readonly indexKey: Promise<CryptoKey>;

  constructor(private readonly keys: KeyCustody, private readonly s3: S3RecoveryCopy,
    identityIndexSecret: string) {
    this.indexKey = identityIndexKey(identityIndexSecret);
  }

  /** The outer recovery envelope alone cannot prove that the sealed Apple
   * credential and owner-bound contact actually belong to this owner.
   */
  private async verifyInnerIdentity(image: OwnerRecoveryImage): Promise<void> {
    const credential = await this.keys.open(image.credential.sealedCredentials,
      { ownerId: image.ownerId, purpose: 'identity' });
    try {
      const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(credential));
      if (!exact(value, 'issuer,refreshToken,subject')
        || typeof value.issuer !== 'string' || !value.issuer.trim() || value.issuer.length > 2048
        || typeof value.subject !== 'string' || !value.subject.trim() || value.subject.length > 1024
        || typeof value.refreshToken !== 'string' || !value.refreshToken
        || value.refreshToken.length > 16_384
        || await indexedOwnerIdentity(await this.indexKey, value.issuer, value.subject)
          !== image.identityKey) throw unavailable();
    } finally { credential.fill(0); }
    if (image.contact === null) return;
    const contact = await this.keys.open(image.contact.sealedEmail,
      { ownerId: image.ownerId, purpose: 'contact' });
    try {
      const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(contact));
      if (!exact(value, 'email,version') || value.version !== 1 || !contactEmailValid(value.email)
        || (image.contact.emailTag !== null
          && await indexedNoticeEmail(await this.indexKey, image.ownerId, value.email)
            !== image.contact.emailTag)) throw unavailable();
    } finally { contact.fill(0); }
  }

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
        r.final_notice_delivered_at,r.final_notice_receipt,
        coalesce((SELECT i.generation FROM pa_inventory i WHERE i.owner_id=o.owner_id),0)
          AS inventory_generation,
        (SELECT json_group_array(json_object('recordId',items.record_id,
          'revision',items.revision,'deleted',items.deleted,
          'marker',CASE WHEN items.marker_object_key IS NULL THEN NULL ELSE json_object(
            'key',items.marker_object_key,'versionId',items.marker_version_id,
            'sha256',items.marker_sha256,'bytes',items.marker_bytes) END))
          FROM (SELECT pr.record_id,pr.revision,pr.deleted,cm.marker_object_key,
            cm.marker_version_id,cm.marker_sha256,cm.marker_bytes
            FROM pa_records pr LEFT JOIN pa_record_commit_markers cm
              ON cm.owner_id=pr.owner_id AND cm.record_id=pr.record_id
                AND cm.revision=pr.revision
            WHERE pr.owner_id=o.owner_id ORDER BY pr.record_id) items) AS records_json
        FROM pa_owners o JOIN pa_owner_recovery_generations g ON g.owner_id=o.owner_id
        JOIN pa_identity_credentials c ON c.owner_id=o.owner_id
        LEFT JOIN pa_notice_contacts n ON n.owner_id=o.owner_id
        LEFT JOIN pa_membership_links l ON l.owner_id=o.owner_id
        LEFT JOIN pa_retention r ON r.owner_id=o.owner_id
        WHERE o.owner_id=?`).bind(ownerId).first<OwnerRow>();
      if (!row || (row.disabled !== 0 && row.disabled !== 1)
        || (row.sealed_email !== null && row.contact_source !== 'apple')) throw unavailable();
      const parsed: unknown = JSON.parse(row.records_json);
      if (!Array.isArray(parsed)) throw unavailable();
      const records = parsed.map((item: unknown) => {
        if (!exact(item, 'deleted,marker,recordId,revision')
          || (item.deleted !== 0 && item.deleted !== 1)) throw unavailable();
        return { recordId: item.recordId, revision: item.revision,
          deleted: item.deleted === 1, marker: item.marker };
      }).sort((a, b) => String(a.recordId).localeCompare(String(b.recordId))) as OwnerRecoveryImage['records'];
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
        inventoryGeneration: row.inventory_generation, records,
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
      await this.verifyInnerIdentity(image);
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

  /** A bounded, round-robin retry for a D1 mutation that committed while S3
   * failed. Failed owners remain unacknowledged and cannot starve later rows.
   */
  async repairBatch(db: D1Database, now: number, limit = 20): Promise<{ processed: number; failed: number }> {
    if (!safeInteger(now, 1) || !Number.isInteger(limit) || limit < 1 || limit > 100) throw unavailable();
    try {
      const cursor = await db.prepare(`SELECT last_owner_id FROM pa_owner_recovery_repair_cursor
        WHERE singleton=1`).first<{ last_owner_id: string }>();
      if (!cursor || (cursor.last_owner_id !== '' && !ownerPattern.test(cursor.last_owner_id))) {
        throw unavailable();
      }
      const pending = `NOT EXISTS(SELECT 1 FROM pa_owner_recovery_versions v
        WHERE v.owner_id=g.owner_id AND v.generation=g.generation)`;
      const after = await db.prepare(`SELECT g.owner_id FROM pa_owner_recovery_generations g
        WHERE ${pending} AND g.owner_id>? ORDER BY g.owner_id LIMIT ?`)
        .bind(cursor.last_owner_id, limit).all<{ owner_id: string }>();
      const rows = after.results.length ? after.results
        : (await db.prepare(`SELECT g.owner_id FROM pa_owner_recovery_generations g
          WHERE ${pending} ORDER BY g.owner_id LIMIT ?`)
          .bind(limit).all<{ owner_id: string }>()).results;
      let failed = 0;
      for (const row of rows) {
        if (!ownerPattern.test(row.owner_id)) throw unavailable();
        try {
          await this.copyCurrent(db, row.owner_id, now);
          await db.prepare('DELETE FROM pa_owner_recovery_repair_failures WHERE owner_id=?')
            .bind(row.owner_id).run();
        } catch (error) {
          failed++;
          const code = error instanceof ServiceError ? error.code : 'OWNER_RECOVERY_UNAVAILABLE';
          await db.prepare(`INSERT INTO pa_owner_recovery_repair_failures
            (owner_id,error_code,attempts,last_attempt_at) VALUES(?,?,1,?)
            ON CONFLICT(owner_id) DO UPDATE SET error_code=excluded.error_code,
            attempts=attempts+1,last_attempt_at=excluded.last_attempt_at`)
            .bind(row.owner_id, code, now).run();
        }
      }
      if (rows.length) {
        await db.prepare(`UPDATE pa_owner_recovery_repair_cursor SET last_owner_id=? WHERE singleton=1`)
          .bind(rows.at(-1)!.owner_id).run();
      }
      return { processed: rows.length, failed };
    } catch { throw unavailable(); }
  }

  /** Local ledger coverage only. A zero gap is not proof of live S3 versions,
   * key custody, deleted-owner replay, or a successful separate restore.
   */
  async ledgerCoverage(db: D1Database): Promise<{ total: number; confirmed: number; pending: number }> {
    try {
      const row = await db.prepare(`SELECT count(*) AS total,
        coalesce(sum(CASE WHEN v.owner_id IS NOT NULL THEN 1 ELSE 0 END),0) AS confirmed
        FROM pa_owner_recovery_generations g LEFT JOIN pa_owner_recovery_versions v
          ON v.owner_id=g.owner_id AND v.generation=g.generation`)
        .first<{ total: number; confirmed: number }>();
      if (!row || !safeInteger(row.total) || !safeInteger(row.confirmed)
        || row.confirmed > row.total) throw unavailable();
      return { total: row.total, confirmed: row.confirmed, pending: row.total - row.confirmed };
    } catch { throw unavailable(); }
  }

  /** Selects a D1-independent owner candidate in a disabled quarantine.
   * Contact and deletion-notice evidence can be stale even in the latest S3
   * version (D1 may have committed a newer generation before S3 failed).
   * Activation needs fresh Apple reauthentication, billing verification,
   * durable revocation/deletion replay and complete record validation.
   */
  async selectRecoveredOwner(ownerId: string, references: RecoveryObject[], now: number): Promise<
    { status: 'reauth-required'; image: OwnerRecoveryImage } |
    { status: 'disabled' } |
    { status: 'missing' | 'quarantined' }> {
    if (!ownerPattern.test(ownerId) || !Array.isArray(references) || references.length > 100_000
      || !safeInteger(now, 1)) {
      throw unavailable();
    }
    if (!references.length) return { status: 'missing' };
    const images = await Promise.all(references.map(reference => this.read(ownerId, reference)));
    const generations = new Map<number, OwnerRecoveryImage>();
    for (const item of images) {
      const previous = generations.get(item.generation);
      if (previous && JSON.stringify(previous) !== JSON.stringify(item)) {
        return { status: 'quarantined' };
      }
      generations.set(item.generation, item);
    }
    const ordered = [...generations.values()].sort((a, b) => a.generation - b.generation);
    const first = ordered[0]!;
    let knownBilling: string | null = null;
    let lastEpoch = first.epoch;
    let lastInventory = first.inventoryGeneration;
    let priorRecords = new Map<string, OwnerRecoveryImage['records'][number]>();
    for (const item of ordered) {
      if (item.identityKey !== first.identityKey || item.createdAt !== first.createdAt
        || item.epoch < lastEpoch || item.inventoryGeneration < lastInventory
        || (knownBilling !== null && item.billing?.accountId !== knownBilling)) {
        return { status: 'quarantined' };
      }
      const currentRecords = new Map(item.records.map(record => [record.recordId, record]));
      for (const [recordId, prior] of priorRecords) {
        const current = currentRecords.get(recordId);
        if (!current || current.revision < prior.revision
          || (current.revision === prior.revision
            && (current.deleted !== prior.deleted || current.marker.key !== prior.marker.key
              || current.marker.versionId !== prior.marker.versionId
              || current.marker.sha256 !== prior.marker.sha256
              || current.marker.bytes !== prior.marker.bytes))
          || (prior.deleted && !current.deleted)) return { status: 'quarantined' };
      }
      priorRecords = currentRecords;
      lastEpoch = item.epoch;
      lastInventory = item.inventoryGeneration;
      if (item.billing !== null) knownBilling = item.billing.accountId;
    }
    const latest = ordered.at(-1)!;
    if (latest.disabled || latest.purgeFenceId !== null) return { status: 'disabled' };
    try { await this.verifyInnerIdentity(latest); }
    catch { return { status: 'quarantined' }; }
    if (latest.retention?.revision === Number.MAX_SAFE_INTEGER) return { status: 'quarantined' };
    const retention = latest.retention === null ? null : latest.retention.expiredAt === null
      ? { ...latest.retention, revision: latest.retention.revision + 1,
          status: 'unknown' as const, checkedAt: 0, pausedAt: null,
          noticeNotBeforeAt: 0, finalNoticeDeliveredAt: null, finalNoticeReceipt: null }
      : { ...latest.retention, revision: latest.retention.revision + 1,
          status: 'unknown' as const, checkedAt: 0,
          pausedAt: Math.max(now, latest.retention.expiredAt),
          noticeNotBeforeAt: Math.max(now, latest.retention.expiredAt,
            latest.retention.noticeNotBeforeAt),
          finalNoticeDeliveredAt: null, finalNoticeReceipt: null };
    const staged: OwnerRecoveryImage = { ...latest, disabled: true, purgeFenceId: null,
      contact: null, retention };
    valid(staged);
    return { status: 'reauth-required', image: staged };
  }

  /** Complete, versioned S3 owner-prefix walk; no D1 dependency. The result
   * is still only a restore candidate, not evidence that no newer D1 state or
   * external deletion intent exists.
   */
  async discoverOwnerFromS3(ownerId: string, now: number): ReturnType<OwnerRecoveryCopy['selectRecoveredOwner']> {
    if (!ownerPattern.test(ownerId)) throw unavailable();
    const references: RecoveryObject[] = [];
    const seenVersions = new Set<string>();
    const seenCursors = new Set<string>();
    let cursor: { keyMarker: string; versionIdMarker?: string } | undefined;
    do {
      const page = await this.s3.listOwnerVersionsPage(ownerId, cursor);
      for (const version of page.versions) {
        const identity = `${version.key}\0${version.versionId}`;
        if (version.deleteMarker || seenVersions.has(identity)) throw unavailable();
        seenVersions.add(identity);
        if (ownerKeyPattern.exec(version.key)?.[1] === ownerId) {
          references.push(await this.s3.referenceForListedVersion(version));
        }
      }
      if (seenVersions.size > 100_000) throw unavailable();
      cursor = page.nextCursor ?? undefined;
      if (cursor) {
        const identity = `${cursor.keyMarker}\0${cursor.versionIdMarker ?? ''}`;
        if (seenCursors.has(identity)) throw unavailable();
        seenCursors.add(identity);
      }
    } while (cursor);
    return this.selectRecoveredOwner(ownerId, references, now);
  }

  async copy(image: OwnerRecoveryImage): Promise<RecoveryObject> {
    valid(image);
    const payload: EncodedImage = { ...image, version: 2,
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
      if (!exact(payload, 'billing,contact,createdAt,credential,disabled,epoch,generation,identityKey,inventoryGeneration,ownerId,purgeFenceId,records,retention,version')
        || payload.version !== 2 || payload.ownerId !== ownerId
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
