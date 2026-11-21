import { ServiceError } from './contracts';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from './owner-recovery-copy';
import { RecordRecoveryCopy, type DiscoveredRecordManifest } from './record-recovery-copy';
import { S3RecoveryCopy, type RecoveryObject, type RecoveryVersion, type RecoveryVersionCursor } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const unavailable = () => new ServiceError('OWNER_ARCHIVE_RECOVERY_UNAVAILABLE', 503);

function sameReference(left: RecoveryObject, right: RecoveryObject): boolean {
  return left.key === right.key && left.versionId === right.versionId
    && left.sha256 === right.sha256 && left.bytes === right.bytes;
}

export type OwnerArchiveCandidate =
  | { status: 'missing' | 'disabled' | 'quarantined' }
  | { status: 'ready-for-quarantine'; owner: OwnerRecoveryImage; verifiedRecords: number;
      recordMarkers: { recordId: string; markers: RecoveryObject[] }[];
      erasureEvidence?: { pages: RecoveryObject[]; manifests: DiscoveredRecordManifest[] } };

/** Read-only, D1-independent consistency check for a disabled restore image.
 * A returned candidate is never authority to activate an account or serve its
 * photos: an independent owner-deletion ledger, source write fence, Apple
 * reauthentication, billing verification and a separate D1/R2 restore remain.
 */
export class OwnerArchiveRecovery {
  constructor(private readonly s3: S3RecoveryCopy,
    private readonly owners: OwnerRecoveryCopy,
    private readonly records: RecordRecoveryCopy) {}

  /** Internal offline runner dependencies; no HTTP route exposes this API. */
  offlineInputs(){return {s3:this.s3,owners:this.owners};}

  async assembleQuarantineCandidate(ownerId: string, now: number,
    erasureInventory?: readonly RecoveryVersion[]): Promise<OwnerArchiveCandidate> {
    if (!ownerPattern.test(ownerId) || !Number.isSafeInteger(now) || now < 1) throw unavailable();
    const ownerCopies: RecoveryObject[] = [];
    const manifestCopies: RecoveryObject[] = [];
    const seenVersions = new Set<string>();
    const seenCursors = new Set<string>();
    const pending: RecoveryVersion[] = [];
    const inspectVersions = (versions: readonly RecoveryVersion[]) => {
      for (const version of versions) {
        const identity = `${version.key}\0${version.versionId}`;
        if (version.deleteMarker || seenVersions.has(identity)
          || !version.key.startsWith(`recovery/v1/${ownerId}/`)) throw unavailable();
        seenVersions.add(identity);
        if (/^recovery\/v1\/[^/]+\/(?:owner|manifest)\//u.test(version.key)) pending.push(version);
      }
      if (seenVersions.size > 100_000) throw unavailable();
    };
    let cursor: RecoveryVersionCursor | undefined;
    if (erasureInventory) inspectVersions(erasureInventory);
    else {
      do {
        const page = await this.s3.listOwnerVersionsPage(ownerId, cursor);
        inspectVersions(page.versions);
        cursor = page.nextCursor ?? undefined;
        if (cursor) {
          const identity = `${cursor.keyMarker}\0${cursor.versionIdMarker ?? ''}`;
          if (seenCursors.has(identity)) throw unavailable();
          seenCursors.add(identity);
        }
      } while (cursor);
    }
    for (let offset = 0; offset < pending.length; offset += 6) {
      const inspected = await Promise.allSettled(pending.slice(offset, offset + 6)
        .map(item => this.s3.referenceForListedVersion(item)));
      for (const result of inspected) {
        if (result.status === 'rejected') throw result.reason;
        (result.value.key.split('/')[3] === 'owner' ? ownerCopies : manifestCopies).push(result.value);
      }
    }
    if (!ownerCopies.length) return manifestCopies.length ? { status: 'quarantined' }
      : { status: 'missing' };
    const pages = new Map<string, RecoveryObject>();
    const selected = await this.owners.selectRecoveredOwner(ownerId, ownerCopies, now,
      erasureInventory ? ref => {
        const id = `${ref.key}\0${ref.versionId}`;
        const prior = pages.get(id);
        if (prior && !sameReference(ref, prior)) throw unavailable();
        pages.set(id, ref);
      } : undefined);
    if (selected.status !== 'reauth-required') return selected;
    const expected = new Map(selected.image.records.map(item => [item.recordId, item]));
    const histories = new Map<string, DiscoveredRecordManifest[]>();
    const foundExpectedCommits = new Set<string>();
    for (let offset = 0; offset < manifestCopies.length; offset += 6) {
      const inspected = await Promise.allSettled(manifestCopies.slice(offset, offset + 6)
        .map(marker => this.records.inspectManifest(ownerId, marker)));
      for (const result of inspected) {
        if (result.status === 'rejected') throw result.reason;
        const item = result.value, marker = item.marker;
        if (!expected.has(item.recordId)) return { status: 'quarantined' };
        const expectedRecord = expected.get(item.recordId)!;
        if (item.kind === 'commit' && item.revision === expectedRecord.revision
          && sameReference(item.marker, expectedRecord.marker)) {
          foundExpectedCommits.add(item.recordId);
        }
        const history = histories.get(item.recordId) ?? [];
        history.push(item);
        histories.set(item.recordId, history);
      }
    }
    for (const [recordId, item] of expected) {
      const group = histories.get(recordId);
      if (!group || !foundExpectedCommits.has(recordId)) return { status: 'quarantined' };
      const selectedRecord = await this.records.readInspectedHistory(ownerId, recordId, group);
      if (selectedRecord.status !== 'ready' || selectedRecord.image.revision !== item.revision
        || selectedRecord.image.deleted !== item.deleted) return { status: 'quarantined' };
      // The record reader returns plaintext metadata and photo ciphertext.
      // This pass verifies them, then discards both; no album data is served.
      selectedRecord.image.metadata?.fill(0);
      selectedRecord.image.photoCiphertext?.fill(0);
    }
    return { status: 'ready-for-quarantine', owner: selected.image,
      verifiedRecords: expected.size, recordMarkers: selected.image.records.map(item => ({
        recordId: item.recordId, markers: histories.get(item.recordId)!.map(value => value.marker),
      })), ...(erasureInventory ? { erasureEvidence: { pages: [...pages.values()], manifests: [...histories.values()].flat() } } : {}) };
  }
}
