// Offline integration contract, aligned with PersonalArchiveContext and the
// native single-record exporter. This is not a JPEG decoder or a ZIP writer.
export class RecordContractError extends Error {
  constructor(code) { super(code); this.name = 'RecordContractError'; this.code = code; }
}
const fail = (code) => { throw new RecordContractError(code); };
const segmenter = new Intl.Segmenter('ja', { granularity: 'grapheme' });
const withinCharacters = (value, maximum) => {
  let count = 0;
  for (const _ of segmenter.segment(value)) if (++count > maximum) return false;
  return true;
};
export const MAX_PHOTO_BYTES = 20 * 1024 * 1024;

export function validateNote(note) {
  if (typeof note !== 'string' || Buffer.byteLength(note, 'utf8') > 65_536
    || !withinCharacters(note, 500)) fail('INVALID_NOTE');
  return note;
}

export function normalizeNote(note) {
  if (typeof note !== 'string') fail('INVALID_NOTE');
  // Explicit Unicode whitespace instead of JS trim (which misses NEL U+0085).
  // Native round-trip verification across Foundation/ICU versions is still required.
  return validateNote(note.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, ''));
}

export function nullableDate(value) {
  if (value === null) return null;
  if (typeof value !== 'string') fail('INVALID_METADATA');
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!parts) fail('INVALID_METADATA');
  const [, year, month, day, hour, minute, second, , zone] = parts;
  const leap = +year % 4 === 0 && (+year % 100 !== 0 || +year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (+year < 1 || +month < 1 || +month > 12 || +day < 1 || +day > days[+month - 1]
    || +hour > 23 || +minute > 59 || +second > 59
    || (zone !== 'Z' && (+zone.slice(1, 3) > 23 || +zone.slice(4) > 59))) fail('INVALID_METADATA');
  const time = Date.parse(value);
  if (!Number.isFinite(time) || time < -62_135_596_800_000 || time >= 253_402_300_800_000) fail('INVALID_METADATA');
  return new Date(time).toISOString();
}

export function validateMetadata(metadata) {
  if (!metadata || !Array.isArray(metadata.catNames) || metadata.catNames.length > 100
    || [...metadata.catNames].some((name) => typeof name !== 'string' || !name.length
      || Buffer.byteLength(name, 'utf8') > 800 || !withinCharacters(name, 200))) fail('INVALID_METADATA');
  // Explicit allowlist. Do not export owner IDs, PhotoKit IDs, locations or keys.
  return { capturedAt: nullableDate(metadata.capturedAt), writtenAt: nullableDate(metadata.writtenAt),
    updatedAt: nullableDate(metadata.updatedAt), catNames: [...metadata.catNames] };
}

function validatePhotoBytes(photoBytes) {
  if (photoBytes === null) return null;
  if (!(photoBytes instanceof Uint8Array) || photoBytes.byteLength < 1
    || photoBytes.byteLength > MAX_PHOTO_BYTES) fail('INVALID_PHOTO_BYTES');
  // Synthetic bytes remain allowed in this isolated prototype. Production must
  // decode/validate JPEG, as the native exporter does, before accepting uploads.
  return photoBytes;
}

export function copyPhotoBytes(photoBytes) {
  const bytes = validatePhotoBytes(photoBytes);
  return bytes === null ? null : Buffer.from(bytes);
}

export function nativeArchiveDocument({ note, metadata, photoBytes }) {
  const text = validateNote(note);
  if (!normalizeNote(text) && photoBytes === null) fail('EMPTY_RECORD');
  const bytes = validatePhotoBytes(photoBytes);
  return { formatVersion: 1, text, ...validateMetadata(metadata), photoFile: bytes === null ? null : 'photo.jpg' };
}
