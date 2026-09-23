import { ServiceError } from './contracts';
import { OwnerRecoveryCopy, type OwnerRecoveryImage } from './owner-recovery-copy';
import { RecordRecoveryCopy } from './record-recovery-copy';
import { S3RecoveryCopy, type RecoveryObject, type RecoveryVersionCursor } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const unavailable = () => new ServiceError('OWNER_ARCHIVE_RECOVERY_UNAVAILABLE', 503);

function sameReference(left: RecoveryObject, right: RecoveryObject): boolean {
  return left.key === right.key && left.versionId === right.versionId
    && left.sha256 === right.sha256 && left.bytes === right.bytes;
}

export type OwnerArchiveCandidate =
  | { status: 'missing' | 'disabled' | 'quarantined' }
  | { status: 'ready-for-quarantine'; owner: OwnerRecoveryImage; verifiedRecords: number };

/** Read-only, D1-independent consistency check for a disabled restore image.
 * A returned candidate is never authority to activate an account or serve its
 * photos: an independent owner-deletion ledger, source write fence, Apple
 * reauthentication, billing verification and a separate D1/R2 restore remain.
 */
export class OwnerArchiveRecovery {
  constructor(private readonly s3: S3RecoveryCopy,
    private readonly owners: OwnerRecoveryCopy,
    private readonly records: RecordRecoveryCopy) {}

  async assembleQuarantineCandidate(ownerId: string, now: number): Promise<OwnerArchiveCandidate> {
    if (!ownerPattern.test(ownerId) || !Number.isSafeInteger(now) || now < 1) throw unavailable();
    const ownerCopies: RecoveryObject[] = [];
    const manifestCopies: RecoveryObject[] = [];
    const seenVersions = new Set<string>();
    const seenCursors = new Set<string>();
    let cursor: RecoveryVersionCursor | undefined;
    do {
      const page = await this.s3.listOwnerVersionsPage(ownerId, cursor);
      for (const version of page.versions) {
        const identity = `${version.key}\0${version.versionId}`;
        if (version.deleteMarker || seenVersions.has(identity)
          || !version.key.startsWith(`recovery/v1/${ownerId}/`)) throw unavailable();
        seenVersions.add(identity);
        if (version.key.includes('/owner/')) {
          ownerCopies.push(await this.s3.referenceForListedVersion(version));
        } else if (version.key.includes('/manifest/')) {
          manifestCopies.push(await this.s3.referenceForListedVersion(version));
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
    if (!ownerCopies.length) return manifestCopies.length ? { status: 'quarantined' }
      : { status: 'missing' };
    const selected = await this.owners.selectRecoveredOwner(ownerId, ownerCopies, now);
    if (selected.status !== 'reauth-required') return selected;
    const expected = new Map(selected.image.records.map(item => [item.recordId, item]));
    const byRecord = new Map<string, RecoveryObject[]>();
    const foundExpectedCommits = new Set<string>();
    for (const marker of manifestCopies) {
      const item = await this.records.inspectManifest(ownerId, marker);
      if (!expected.has(item.recordId)) return { status: 'quarantined' };
      const expectedRecord = expected.get(item.recordId)!;
      if (item.kind === 'commit' && item.revision === expectedRecord.revision
        && sameReference(item.marker, expectedRecord.marker)) {
        foundExpectedCommits.add(item.recordId);
      }
      const group = byRecord.get(item.recordId) ?? [];
      group.push(marker);
      byRecord.set(item.recordId, group);
    }
    for (const [recordId, item] of expected) {
      const group = byRecord.get(recordId);
      if (!group || !foundExpectedCommits.has(recordId)) return { status: 'quarantined' };
      const selectedRecord = await this.records.selectRecoveredRecord(ownerId, recordId, group);
      if (selectedRecord.status !== 'ready' || selectedRecord.image.revision !== item.revision
        || selectedRecord.image.deleted !== item.deleted) return { status: 'quarantined' };
      // The record reader returns plaintext metadata and photo ciphertext.
      // This pass verifies them, then discards both; no album data is served.
      selectedRecord.image.metadata?.fill(0);
      selectedRecord.image.photoCiphertext?.fill(0);
    }
    return { status: 'ready-for-quarantine', owner: selected.image,
      verifiedRecords: expected.size };
  }
}
