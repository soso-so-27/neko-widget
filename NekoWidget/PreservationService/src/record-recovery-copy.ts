import { ServiceError, type KeyCustody } from './contracts';
import { type RecoveryObject, S3RecoveryCopy } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const idPattern = new RegExp(`^${uuid}$`, 'u');
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const recordIdPattern = new RegExp(`^${recordUuid}$`, 'u');
const photoKeyPattern = new RegExp(`^personal/(${uuid})/(${recordUuid})/(${uuid})$`, 'u');
const recoveryKeyPattern = new RegExp(`^recovery/v1/(${uuid})/(photo|record)/(${uuid})$`, 'u');
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
function validCopy(copy: RecoveryObject, ownerId: string, kind: 'photo' | 'record'): boolean {
  const match = recoveryKeyPattern.exec(copy.key);
  return match?.[1] === ownerId && match[2] === kind && hex.test(copy.sha256)
    && Number.isSafeInteger(copy.bytes) && copy.bytes > 0
    && typeof copy.versionId === 'string' && copy.versionId.length > 0 && copy.versionId !== 'null';
}
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

  async copy(image: StoredRecordImage): Promise<CopiedRecordImage> {
    validImage(image);
    try {
      const photo = image.photoCiphertext === null ? null : await this.s3.putVersioned(
        `recovery/v1/${image.ownerId}/photo/${crypto.randomUUID()}`, image.photoCiphertext);
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
}
