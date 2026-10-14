import { ServiceError } from './contracts';
import { inventoryOwnerCloudStorage, type OwnerCloudInventory } from './owner-cloud-inventory';
import type { RecoveryObject, S3RecoveryCopy } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const photoPattern = new RegExp(`^personal/(${uuid})/${recordUuid}/${uuid}$`, 'u');
const recoveryPattern = new RegExp(`^recovery/v1/(${uuid})/(photo|record|manifest|owner)/${uuid}$`, 'u');
const versionPattern = /^[\x21-\x7e]{1,1024}$/u;
const unavailable = () => new ServiceError('OWNER_STORAGE_USAGE_UNAVAILABLE', 503);
const maximumItems = 100_000;

type Usage = { objects: number; bytes: number };
type RecoveryKind = 'photo' | 'record' | 'manifest' | 'owner' | 'unknown';
type RecoveryUsage = Usage & { deleteMarkers: number };
export type OwnerStorageReferences = {
  ownerId: string;
  recordPhotoKeys: string[];
  pendingPhotoKeys: string[];
  recoveryObjects: RecoveryObject[];
};
export type OwnerStorageUsage = {
  ownerId: string;
  consistency: 'advisory-nonatomic';
  inventoryCoverage: 'provided-objects-only';
  recoveryVerified: false;
  deletionAuthorized: false;
  r2: Usage;
  s3: RecoveryUsage & { byKind: Record<RecoveryKind, RecoveryUsage> };
  // Caller-supplied references may omit D1 or recovery history. A match checks
  // listed key/version/size, NOT ciphertext, authenticity, freshness or closure.
  references: null | {
    scope: 'supplied-only';
    r2: { recordOnly: Usage; pendingOnly: Usage; recordAndPending: Usage;
      unmatched: Usage; missingRecordKeys: number; missingPendingKeys: number };
    s3: { listedReference: Usage; unmatched: Usage; sizeMismatch: Usage;
      notListedReferences: number; deleteMarkerReferences: number };
  };
};
const usage = (): Usage => ({ objects: 0, bytes: 0 });
const recoveryUsage = (): RecoveryUsage => ({ ...usage(), deleteMarkers: 0 });
function add(target: Usage, bytes: number): void {
  if (!Number.isSafeInteger(bytes) || bytes < 0 || !Number.isSafeInteger(target.bytes + bytes)) throw unavailable();
  target.objects++; target.bytes += bytes;
}
function validVersion(value: string): boolean {
  return typeof value === 'string' && versionPattern.test(value) && value !== 'null';
}
function photoKey(key: string, ownerId: string): boolean {
  return typeof key === 'string' && photoPattern.exec(key)?.[1] === ownerId;
}
function referenceSets(ownerId: string, references?: OwnerStorageReferences) {
  if (!references) return null;
  if (references.ownerId !== ownerId
    || !Array.isArray(references.recordPhotoKeys) || !Array.isArray(references.pendingPhotoKeys)
    || !Array.isArray(references.recoveryObjects)
    || [references.recordPhotoKeys, references.pendingPhotoKeys, references.recoveryObjects]
      .some(items => items.length > maximumItems)) throw unavailable();
  const record = new Set(references.recordPhotoKeys);
  const pending = new Set(references.pendingPhotoKeys);
  for (const key of [...record, ...pending]) if (!photoKey(key, ownerId)) throw unavailable();
  const recovery = new Map<string, RecoveryObject>();
  for (const ref of references.recoveryObjects) {
    if (!ref || typeof ref.key !== 'string' || recoveryPattern.exec(ref.key)?.[1] !== ownerId
      || !validVersion(ref.versionId) || !Number.isSafeInteger(ref.bytes) || ref.bytes < 1
      || ref.bytes > 32 * 1024 * 1024 || typeof ref.sha256 !== 'string'
      || !/^[0-9a-f]{64}$/u.test(ref.sha256)) throw unavailable();
    const identity = `${ref.key}\0${ref.versionId}`;
    const prior = recovery.get(identity);
    // Shared photo references are normal; contradictory evidence is not.
    if (prior && (prior.bytes !== ref.bytes || prior.sha256 !== ref.sha256)) throw unavailable();
    recovery.set(identity, ref);
  }
  return { record, pending, recovery };
}

/** Physical byte accounting, including ALL versions, with optional reference
 * observations. Unmatched means unresolved, never orphaned or safe to delete.
 * S3 LIST has no content verification or latest-version evidence here. Current
 * record refs alone omit the historical chain needed by the recovery reader.
 * Counts exclude billing request costs, delete-marker overhead and other owners.
 */
export function summarizeOwnerStorageUsage(inventory: OwnerCloudInventory,
  references?: OwnerStorageReferences): OwnerStorageUsage {
  try {
    if (!inventory || !ownerPattern.test(inventory.ownerId)
      || !Array.isArray(inventory.r2Objects) || !Array.isArray(inventory.s3Versions)
      || inventory.r2Objects.length > maximumItems || inventory.s3Versions.length > maximumItems) throw unavailable();
    const ownerId = inventory.ownerId;
    const refs = referenceSets(ownerId, references);
    const result: OwnerStorageUsage = {
      ownerId, consistency: 'advisory-nonatomic', inventoryCoverage: 'provided-objects-only',
      recoveryVerified: false, deletionAuthorized: false,
      r2: usage(), s3: { ...recoveryUsage(), byKind: {
        photo: recoveryUsage(), record: recoveryUsage(), manifest: recoveryUsage(),
        owner: recoveryUsage(), unknown: recoveryUsage(),
      } },
      references: refs ? {
        scope: 'supplied-only',
        r2: { recordOnly: usage(), pendingOnly: usage(), recordAndPending: usage(),
          unmatched: usage(), missingRecordKeys: 0, missingPendingKeys: 0 },
        s3: { listedReference: usage(), unmatched: usage(), sizeMismatch: usage(),
          notListedReferences: 0, deleteMarkerReferences: 0 },
      } : null,
    };
    const r2Seen = new Set<string>();
    for (const item of inventory.r2Objects) {
      if (!item || !photoKey(item.key, ownerId) || r2Seen.has(item.key)
        || typeof item.version !== 'string' || !item.version || item.version.length > 1024
        || !Number.isSafeInteger(item.bytes) || item.bytes < 1 || item.bytes > 30 * 1024 * 1024) throw unavailable();
      r2Seen.add(item.key); add(result.r2, item.bytes);
      if (refs && result.references) {
        const inRecord = refs.record.has(item.key), inPending = refs.pending.has(item.key);
        const group = inRecord ? (inPending ? 'recordAndPending' : 'recordOnly')
          : (inPending ? 'pendingOnly' : 'unmatched');
        add(result.references.r2[group], item.bytes);
      }
    }
    const s3Seen = new Set<string>();
    for (const item of inventory.s3Versions) {
      if (!item || typeof item.key !== 'string' || item.key.length > 2048
        || !item.key.startsWith(`recovery/v1/${ownerId}/`) || /[\x00-\x1f\x7f]/u.test(item.key)
        || !validVersion(item.versionId) || typeof item.deleteMarker !== 'boolean') throw unavailable();
      const identity = `${item.key}\0${item.versionId}`;
      if (s3Seen.has(identity)) throw unavailable();
      s3Seen.add(identity);
      const kind = (recoveryPattern.exec(item.key)?.[2] ?? 'unknown') as RecoveryKind;
      const group = result.s3.byKind[kind];
      const reference = refs?.recovery.get(identity);
      if (item.deleteMarker) {
        if (item.bytes !== null) throw unavailable();
        result.s3.deleteMarkers++; group.deleteMarkers++;
        if (reference && result.references) result.references.s3.deleteMarkerReferences++;
      } else {
        if (item.bytes === null) throw unavailable();
        add(result.s3, item.bytes); add(group, item.bytes);
        if (result.references) add(result.references.s3[reference
          ? (reference.bytes === item.bytes ? 'listedReference' : 'sizeMismatch') : 'unmatched'], item.bytes);
      }
    }
    if (result.r2.bytes !== inventory.r2Bytes || result.s3.bytes !== inventory.s3VersionBytes
      || result.s3.deleteMarkers !== inventory.s3DeleteMarkers) throw unavailable();
    if (refs && result.references) {
      result.references.r2.missingRecordKeys = [...refs.record].filter(key => !r2Seen.has(key)).length;
      result.references.r2.missingPendingKeys = [...refs.pending].filter(key => !r2Seen.has(key)).length;
      result.references.s3.notListedReferences = [...refs.recovery.keys()].filter(key => !s3Seen.has(key)).length;
    }
    return result;
  } catch { throw unavailable(); }
}

/** LIST-only adapter. Does not fence active owners or read photos/decrypt data,
 * expose a route, enable a schedule, or grant deletion permissions. Concurrent
 * writes can make the observation incomplete; even an exact match is advisory.
 * The existing collector rejects keys outside its known schema. A zero unknown
 * count never proves that no other key/schema/owner exists in either account.
 */
export async function inspectOwnerStorageUsage(bucket: R2Bucket,
  s3: Pick<S3RecoveryCopy, 'listOwnerVersionsPage'>, ownerId: string,
  references?: OwnerStorageReferences): Promise<OwnerStorageUsage> {
  if (!ownerPattern.test(ownerId)) throw unavailable();
  referenceSets(ownerId, references); // Reject cross-owner evidence before I/O.
  return summarizeOwnerStorageUsage(await inventoryOwnerCloudStorage(bucket, s3, ownerId), references);
}
