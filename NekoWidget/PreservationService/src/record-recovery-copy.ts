import { ServiceError, type KeyCustody } from './contracts';
import { type RecoveryObject, S3RecoveryCopy } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const idPattern = new RegExp(`^${uuid}$`, 'u');
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const recordIdPattern = new RegExp(`^${recordUuid}$`, 'u');
const photoKeyPattern = new RegExp(`^personal/(${uuid})/(${recordUuid})/(${uuid})$`, 'u');
const recoveryKeyPattern = new RegExp(`^recovery/v1/(${uuid})/(photo|record|manifest)/(${uuid})$`, 'u');
const hex = /^[0-9a-f]{64}$/u;
const unavailable = () => new ServiceError('RECOVERY_RECORD_UNAVAILABLE', 503);
const maxMetadataBytes = 512 * 1024;
const maxPhotoCiphertextBytes = 30 * 1024 * 1024;

export interface StoredRecordImage {
  ownerId: string;
  recordId: string;
  revision: number;
  initialFingerprint: string;
  initialOperation: string;
  metadata: Uint8Array | null;
  photoKey: string | null;
  photoBytes: number;
  quotaBytes: number;
  deleted: boolean;
  photoCiphertext: Uint8Array | null;
}

export interface CopiedRecordImage {
  record: RecoveryObject;
  photo: RecoveryObject | null;
}

interface RecordPayload {
  version: 1;
  ownerId: string;
  recordId: string;
  revision: number;
  initialFingerprint: string;
  initialOperation: string;
  metadataBase64: string | null;
  photoKey: string | null;
  photoBytes: number;
  quotaBytes: number;
  deleted: boolean;
  photoCopy: RecoveryObject | null;
}

function encoded(bytes: Uint8Array): string {
  if (bytes.length > maxMetadataBytes) throw unavailable();
  let raw = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    raw += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(raw);
}
function decoded(value: string): Uint8Array {
  try {
    if (value.length > Math.ceil(maxMetadataBytes / 3) * 4) throw unavailable();
    const raw = atob(value);
    if (!raw.length || raw.length > maxMetadataBytes || btoa(raw) !== value) throw unavailable();
    return Uint8Array.from(raw, char => char.charCodeAt(0));
  } catch { throw unavailable(); }
}
function validCopy(copy: RecoveryObject, ownerId: string, kind: 'photo' | 'record' | 'manifest'): boolean {
  const match = recoveryKeyPattern.exec(copy.key);
  return match?.[1] === ownerId && match[2] === kind && hex.test(copy.sha256)
    && Number.isSafeInteger(copy.bytes) && copy.bytes > 0
    && typeof copy.versionId === 'string' && copy.versionId.length > 0 && copy.versionId !== 'null';
}
export interface CommittedRecordImage extends CopiedRecordImage {
  marker: RecoveryObject;
}
export interface DiscoveredRecordCommit extends CommittedRecordImage {
  kind: 'commit';
  recordId: string;
  revision: number;
}
interface CommitPayload {
  version: 1;
  kind: 'commit';
  ownerId: string;
  recordId: string;
  revision: number;
  recordCopy: RecoveryObject;
  photoCopy: RecoveryObject | null;
}
interface DeleteIntentPayload {
  version: 1;
  kind: 'delete-intent';
  ownerId: string;
  recordId: string;
  expectedRevision: number;
  revision: number;
  recordCopy: RecoveryObject;
}
export interface DiscoveredDeleteIntent {
  kind: 'delete-intent';
  marker: RecoveryObject;
  recordId: string;
  expectedRevision: number;
  revision: number;
  record: RecoveryObject;
}
export type DiscoveredRecordManifest = DiscoveredRecordCommit | DiscoveredDeleteIntent;
function sameCopy(left: RecoveryObject | null, right: RecoveryObject | null): boolean {
  return left === null || right === null ? left === right
    : left.key === right.key && left.versionId === right.versionId
      && left.sha256 === right.sha256 && left.bytes === right.bytes;
}
function validImage(image: StoredRecordImage): void {
  if (!idPattern.test(image.ownerId) || !recordIdPattern.test(image.recordId)
    || !Number.isSafeInteger(image.revision) || image.revision < 1
    || !hex.test(image.initialFingerprint) || !idPattern.test(image.initialOperation)
    || !Number.isSafeInteger(image.photoBytes) || image.photoBytes < 0
    || !Number.isSafeInteger(image.quotaBytes) || image.quotaBytes < 0
    || typeof image.deleted !== 'boolean') throw unavailable();
  if (image.deleted) {
    if (image.metadata !== null || image.photoKey !== null || image.photoCiphertext !== null
      || image.photoBytes !== 0 || image.quotaBytes !== 0) throw unavailable();
    return;
  }
  if (!(image.metadata instanceof Uint8Array) || !image.metadata.length
    || image.metadata.length > maxMetadataBytes) throw unavailable();
  if (image.photoKey === null) {
    if (image.photoCiphertext !== null || image.photoBytes !== 0
      || image.quotaBytes !== image.metadata.length) throw unavailable();
    return;
  }
  const match = photoKeyPattern.exec(image.photoKey);
  if (match?.[1] !== image.ownerId || match[2] !== image.recordId
    || !(image.photoCiphertext instanceof Uint8Array)
    || image.photoCiphertext.length < 1 || image.photoCiphertext.length > maxPhotoCiphertextBytes
    || image.photoBytes < 1
    || image.quotaBytes !== image.metadata.length + image.photoCiphertext.length) throw unavailable();
}

/** One immutable encrypted revision, including tombstones. The caller must
 * separately commit the returned S3 version references with the D1 revision.
 * This component does not claim that an owner manifest or restore is complete.
 */
export class RecordRecoveryCopy {
  constructor(private readonly keys: KeyCustody, private readonly s3: S3RecoveryCopy) {}

  async copy(image: StoredRecordImage, reusedPhoto?: RecoveryObject): Promise<CopiedRecordImage> {
    validImage(image);
    try {
      if (reusedPhoto && (image.photoCiphertext === null
        || !validCopy(reusedPhoto, image.ownerId, 'photo'))) throw unavailable();
      let photo: RecoveryObject | null = null;
      if (image.photoCiphertext !== null) {
        if (reusedPhoto) {
          const earlier = await this.s3.getVerified(reusedPhoto);
          if (earlier.length !== image.photoCiphertext.length
            || earlier.some((byte, index) => byte !== image.photoCiphertext![index])) {
            throw unavailable();
          }
          photo = reusedPhoto;
        } else {
          photo = await this.s3.putVersioned(
            `recovery/v1/${image.ownerId}/photo/${crypto.randomUUID()}`, image.photoCiphertext);
        }
      }
      const payload: RecordPayload = { version: 1, ownerId: image.ownerId, recordId: image.recordId,
        revision: image.revision, initialFingerprint: image.initialFingerprint,
        initialOperation: image.initialOperation,
        metadataBase64: image.metadata === null ? null : encoded(image.metadata),
        photoKey: image.photoKey, photoBytes: image.photoBytes, quotaBytes: image.quotaBytes,
        deleted: image.deleted, photoCopy: photo };
      const sealed = await this.keys.seal(new TextEncoder().encode(JSON.stringify(payload)),
        { ownerId: image.ownerId, purpose: 'record', recordId: `${image.recordId}/document` });
      const record = await this.s3.putVersioned(
        `recovery/v1/${image.ownerId}/record/${crypto.randomUUID()}`, sealed);
      return { record, photo };
    } catch { throw unavailable(); }
  }

  /** Read only the exact, checksum-verified S3 versions. A restore caller must
   * still reconcile revisions, tombstones, owner credentials and billing state.
   */
  async read(ownerId: string, recordId: string, copied: CopiedRecordImage): Promise<StoredRecordImage> {
    if (!idPattern.test(ownerId) || !recordIdPattern.test(recordId)
      || !validCopy(copied.record, ownerId, 'record')
      || (copied.photo !== null && !validCopy(copied.photo, ownerId, 'photo'))) throw unavailable();
    try {
      const sealed = await this.s3.getVerified(copied.record);
      const opened = await this.keys.open(sealed,
        { ownerId, purpose: 'record', recordId: `${recordId}/document` });
      const payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(opened)) as RecordPayload;
      if (!payload || Object.keys(payload).sort().join(',') !==
        'deleted,initialFingerprint,initialOperation,metadataBase64,ownerId,photoBytes,photoCopy,photoKey,quotaBytes,recordId,revision,version'
        || payload.version !== 1 || payload.ownerId !== ownerId || payload.recordId !== recordId
        || !sameCopy(payload.photoCopy, copied.photo)) throw unavailable();
      const photoCiphertext = copied.photo === null ? null : await this.s3.getVerified(copied.photo);
      const image: StoredRecordImage = { ownerId, recordId, revision: payload.revision,
        initialFingerprint: payload.initialFingerprint, initialOperation: payload.initialOperation,
        metadata: payload.metadataBase64 === null ? null : decoded(payload.metadataBase64),
        photoKey: payload.photoKey, photoBytes: payload.photoBytes,
        quotaBytes: payload.quotaBytes, deleted: payload.deleted, photoCiphertext };
      validImage(image);
      return image;
    } catch { throw unavailable(); }
  }

  /** Written only after the D1 CAS has committed. An orphan prepared copy has
   * no marker and cannot be chosen as a recovered revision. The API must wait
   * for this versioned, verified marker before acknowledging the mutation.
   */
  async commit(ownerId: string, recordId: string, revision: number,
    copied: CopiedRecordImage): Promise<RecoveryObject> {
    if (!Number.isSafeInteger(revision) || revision < 1) throw unavailable();
    const image = await this.read(ownerId, recordId, copied);
    if (image.revision !== revision) throw unavailable();
    const payload: CommitPayload = { version: 1, kind: 'commit', ownerId, recordId, revision,
      recordCopy: copied.record, photoCopy: copied.photo };
    try {
      const sealed = await this.keys.seal(new TextEncoder().encode(JSON.stringify(payload)),
        { ownerId, purpose: 'recovery' });
      return await this.s3.putVersioned(
        `recovery/v1/${ownerId}/manifest/${crypto.randomUUID()}`, sealed);
    } catch { throw unavailable(); }
  }

  /** A durable privacy fence written before the D1 deletion CAS. If the CAS
   * or post-CAS commit marker is lost, recovery must quarantine this record
   * rather than revive an older photo. A losing CAS can leave a conservative
   * intent; only a committed revision at the target revision resolves it.
   */
  async prepareDelete(ownerId: string, recordId: string, expectedRevision: number,
    copied: CopiedRecordImage): Promise<RecoveryObject> {
    if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 1
      || expectedRevision >= Number.MAX_SAFE_INTEGER || copied.photo !== null) throw unavailable();
    const image = await this.read(ownerId, recordId, copied);
    if (!image.deleted || image.revision !== expectedRevision + 1) throw unavailable();
    const payload: DeleteIntentPayload = { version: 1, kind: 'delete-intent', ownerId,
      recordId, expectedRevision, revision: image.revision, recordCopy: copied.record };
    try {
      const sealed = await this.keys.seal(new TextEncoder().encode(JSON.stringify(payload)),
        { ownerId, purpose: 'recovery' });
      return await this.s3.putVersioned(
        `recovery/v1/${ownerId}/manifest/${crypto.randomUUID()}`, sealed);
    } catch { throw unavailable(); }
  }

  /** The record ID is inside an owner-bound envelope so it can be discovered
   * from an S3 owner-prefix inventory even after losing the entire D1 DB.
   */
  async inspectManifest(ownerId: string, marker: RecoveryObject): Promise<DiscoveredRecordManifest> {
    if (!idPattern.test(ownerId) || !validCopy(marker, ownerId, 'manifest')) throw unavailable();
    try {
      const sealed = await this.s3.getVerified(marker);
      const opened = await this.keys.open(sealed, { ownerId, purpose: 'recovery' });
      const payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(opened)) as
        CommitPayload | DeleteIntentPayload;
      if (!payload || payload.version !== 1 || payload.ownerId !== ownerId
        || !recordIdPattern.test(payload.recordId)
        || !Number.isSafeInteger(payload.revision) || payload.revision < 1
        || !validCopy(payload.recordCopy, ownerId, 'record')) throw unavailable();
      if (payload.kind === 'delete-intent') {
        if (Object.keys(payload).sort().join(',') !==
          'expectedRevision,kind,ownerId,recordCopy,recordId,revision,version'
          || !Number.isSafeInteger(payload.expectedRevision) || payload.expectedRevision < 1
          || payload.revision !== payload.expectedRevision + 1) throw unavailable();
        const image = await this.read(ownerId, payload.recordId,
          { record: payload.recordCopy, photo: null });
        if (!image.deleted || image.revision !== payload.revision) throw unavailable();
        return { kind: 'delete-intent', marker, recordId: payload.recordId,
          expectedRevision: payload.expectedRevision, revision: payload.revision,
          record: payload.recordCopy };
      }
      if (payload.kind !== 'commit' || Object.keys(payload).sort().join(',') !==
        'kind,ownerId,photoCopy,recordCopy,recordId,revision,version'
        || (payload.photoCopy !== null && !validCopy(payload.photoCopy, ownerId, 'photo'))) {
        throw unavailable();
      }
      return { kind: 'commit', marker, recordId: payload.recordId, revision: payload.revision,
        record: payload.recordCopy, photo: payload.photoCopy };
    } catch { throw unavailable(); }
  }

  async inspectCommit(ownerId: string, marker: RecoveryObject): Promise<DiscoveredRecordCommit> {
    const manifest = await this.inspectManifest(ownerId, marker);
    if (manifest.kind !== 'commit') throw unavailable();
    return manifest;
  }

  /** Requires a complete owner manifest inventory obtained independently of
   * D1. Missing/corrupt markers must fail the entire restore, not be skipped.
   */
  async selectRecoveredRecord(ownerId: string, recordId: string,
    markers: RecoveryObject[]): Promise<{ status: 'ready'; image: StoredRecordImage } |
      { status: 'quarantined' }> {
    if (!idPattern.test(ownerId) || !recordIdPattern.test(recordId)) throw unavailable();
    const inspected: DiscoveredRecordManifest[] = [];
    for (const marker of markers) inspected.push(await this.inspectManifest(ownerId, marker));
    const related = inspected.filter(item => item.recordId === recordId);
    const commits = related.filter((item): item is DiscoveredRecordCommit => item.kind === 'commit');
    const intents = related.filter((item): item is DiscoveredDeleteIntent => item.kind === 'delete-intent');
    const byRevision = new Map<number, DiscoveredRecordCommit>();
    for (const commit of commits) {
      const prior = byRevision.get(commit.revision);
      if (prior && (!sameCopy(prior.record, commit.record)
        || !sameCopy(prior.photo, commit.photo))) return { status: 'quarantined' };
      byRevision.set(commit.revision, commit);
    }
    // A delete intent is resolved only by a committed revision at precisely
    // its target. A later unrelated revision cannot silently erase the fence.
    if (!commits.length || intents.some(intent => !byRevision.has(intent.revision))) {
      return { status: 'quarantined' };
    }
    const ordered = [...byRevision.values()].sort((a, b) => a.revision - b.revision);
    if (ordered[0]?.revision !== 1) return { status: 'quarantined' };
    for (let index = 1; index < ordered.length; index++) {
      if (ordered[index]!.revision !== ordered[index - 1]!.revision + 1) {
        return { status: 'quarantined' };
      }
    }
    let latest: StoredRecordImage | null = null;
    for (const commit of ordered) {
      if (latest?.deleted) return { status: 'quarantined' };
      const next = await this.readCommitted(ownerId, recordId, commit);
      latest?.metadata?.fill(0);
      latest?.photoCiphertext?.fill(0);
      latest = next;
    }
    return { status: 'ready', image: latest! };
  }

  /** Complete, D1-independent owner-prefix inventory. This still does not
   * restore owner identity, credentials, billing or deletion policy.
   */
  async recoverRecordFromS3(ownerId: string, recordId: string) {
    if (!idPattern.test(ownerId) || !recordIdPattern.test(recordId)) throw unavailable();
    const manifests: RecoveryObject[] = [];
    let cursor: { keyMarker: string; versionIdMarker?: string } | undefined;
    const seenCursors = new Set<string>();
    do {
      const page = await this.s3.listOwnerVersionsPage(ownerId, cursor);
      for (const version of page.versions) {
        // A delete marker on any recovery copy is unexpected for an active
        // owner and cannot be interpreted as an empty or healthy backup.
        if (version.deleteMarker) throw unavailable();
        if (version.key.includes('/manifest/')) {
          manifests.push(await this.s3.referenceForListedVersion(version));
        }
      }
      cursor = page.nextCursor ?? undefined;
      if (cursor) {
        const identity = `${cursor.keyMarker}\0${cursor.versionIdMarker ?? ''}`;
        if (seenCursors.has(identity)) throw unavailable();
        seenCursors.add(identity);
      }
      if (manifests.length > 100_000) throw unavailable();
    } while (cursor);
    return this.selectRecoveredRecord(ownerId, recordId, manifests);
  }

  /** A D1-independent recovery candidate. The caller must still replay the
   * owner's deleted-owner ledger and reconcile every committed revision.
   */
  async readCommitted(ownerId: string, recordId: string,
    committed: CommittedRecordImage): Promise<StoredRecordImage> {
    if (!idPattern.test(ownerId) || !recordIdPattern.test(recordId)) throw unavailable();
    try {
      const discovered = await this.inspectCommit(ownerId, committed.marker);
      if (discovered.recordId !== recordId
        || !sameCopy(discovered.record, committed.record)
        || !sameCopy(discovered.photo, committed.photo)) throw unavailable();
      const image = await this.read(ownerId, recordId, committed);
      if (image.revision !== discovered.revision) throw unavailable();
      return image;
    } catch { throw unavailable(); }
  }
}
