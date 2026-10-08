import { ServiceError } from './contracts';
import type { ArchiveStore } from './storage';

const utf8 = new TextEncoder();
const CHUNK_BYTES = 1024 * 1024;
const alphabet = new TextEncoder().encode('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/');
export const MAX_RECORD_FRAME_BYTES = 29 * 1024 * 1024;

/** Same JSON record, bounded transport chunks. Do not create a second,
 * photo-sized byte buffer or widen its ASCII base64 with Japanese metadata.
 * A frame is not usable until its whole JSON value has arrived and validated.
 */
export class RecordFrame {
  readonly byteLength: number;
  private head: Uint8Array;
  private photo: Uint8Array | null;
  private tail: Uint8Array;
  private headAt = 0;
  private photoAt = 0;
  private tailAt = 0;
  constructor(record: Awaited<ReturnType<ArchiveStore['readBinary']>>, ndjson = false) {
    const unavailable = () => new ServiceError('ARCHIVE_PHOTO_UNAVAILABLE', 503);
    const { photo, ...metadata } = record;
    if (photo !== null && (!(photo instanceof Uint8Array) || photo.length > 20 * 1024 * 1024)) throw unavailable();
    const value = ndjson ? { type: 'record', ...metadata } : metadata;
    this.photo = photo;
    this.head = utf8.encode(photo === null
      ? JSON.stringify({ ...value, photoBase64: null }) + (ndjson ? '\n' : '')
      : JSON.stringify(value).slice(0, -1) + ',"photoBase64":"');
    this.tail = utf8.encode(photo === null ? '' : '"}' + (ndjson ? '\n' : ''));
    this.byteLength = this.head.length + Math.ceil((photo?.length ?? 0) / 3) * 4 + this.tail.length;
    if (this.byteLength > MAX_RECORD_FRAME_BYTES) { this.clear(); throw unavailable(); }
  }
  get done() { return this.headAt === this.head.length && this.photo === null && this.tailAt === this.tail.length; }
  next(): Uint8Array | null {
    const remaining = this.head.length - this.headAt
      + (this.photo === null ? 0 : Math.ceil((this.photo.length - this.photoAt) / 3) * 4) + this.tail.length - this.tailAt;
    if (remaining === 0) { this.clear(); return null; }
    const result = new Uint8Array(Math.min(CHUNK_BYTES, remaining)); let at = 0;
    const head = this.head.subarray(this.headAt, this.headAt + result.length);
    result.set(head); this.headAt += head.length; at += head.length;
    if (this.photo !== null) {
      while (this.photoAt < this.photo.length && at + 4 <= result.length) {
        const remainingPhoto = this.photo.length - this.photoAt;
        const a = this.photo[this.photoAt++]!, b = this.photo[this.photoAt++] ?? 0, c = this.photo[this.photoAt++] ?? 0;
        result[at++] = alphabet[a >> 2]!;
        result[at++] = alphabet[((a & 3) << 4) | (b >> 4)]!;
        result[at++] = remainingPhoto > 1 ? alphabet[((b & 15) << 2) | (c >> 6)]! : 61;
        result[at++] = remainingPhoto > 2 ? alphabet[c & 63]! : 61;
        this.photoAt = Math.min(this.photoAt, this.photo.length);
      }
      if (this.photoAt === this.photo.length) this.photo = null;
    }
    if (this.photo === null) {
      const tail = this.tail.subarray(this.tailAt, this.tailAt + result.length - at);
      result.set(tail, at); this.tailAt += tail.length; at += tail.length;
    }
    return result.subarray(0, at);
  }
  clear() {
    this.photo = null; this.head = new Uint8Array(); this.tail = new Uint8Array();
    this.headAt = 0; this.photoAt = 0; this.tailAt = 0;
  }
}

export function recordResponse(record: Awaited<ReturnType<ArchiveStore['readBinary']>>,
  validate: () => Promise<void>, signal: AbortSignal): Response {
  const frame = new RecordFrame(record); let stopped = false;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        await validate();
        if (stopped || signal.aborted) throw new ServiceError('SESSION_INVALID', 401);
        const bytes = frame.next();
        if (bytes) controller.enqueue(bytes);
        if (!bytes || frame.done) { stopped = true; frame.clear(); controller.close(); }
      } catch (error) { frame.clear(); if (!stopped) { stopped = true; controller.error(error); } }
    },
    cancel() { stopped = true; frame.clear(); },
  }, { highWaterMark: 0 });
  return new Response(body, { headers: { 'content-type': 'application/json', 'cache-control': 'no-store',
    'x-content-type-options': 'nosniff' } });
}
