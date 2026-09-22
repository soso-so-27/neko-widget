import { ServiceError, type ArchiveDocument } from './contracts';
export const MAX_PHOTO_BYTES = 20 * 1024 * 1024;
const segmenter = new Intl.Segmenter('ja', { granularity: 'grapheme' });
const countWithin = (value: string, maximum: number) => {
  let count = 0;
  for (const _ of segmenter.segment(value)) if (++count > maximum) return false;
  return true;
};
const fail = (): never => { throw new ServiceError('INVALID_RECORD'); };
function date(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== 'string') return fail();
  const parsed = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/.exec(value);
  if (!parsed) return fail();
  const year = Number(parsed[1]), month = Number(parsed[2]), day = Number(parsed[3]);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > (days[month - 1] ?? 0)
    || Number(parsed[4]) > 23 || Number(parsed[5]) > 59 || Number(parsed[6]) > 59) return fail();
  const result = new Date(value);
  if (!Number.isFinite(result.getTime()) || result.getTime() >= 253_402_300_800_000) return fail();
  return result.toISOString();
}
export function validateDocument(input: unknown): ArchiveDocument {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return fail();
  const value = input as Record<string, unknown>;
  const keys = ['formatVersion', 'text', 'capturedAt', 'writtenAt', 'updatedAt', 'catNames', 'photoFile'];
  if (Object.keys(value).some((key) => !keys.includes(key)) || value.formatVersion !== 1
    || typeof value.text !== 'string' || !Array.isArray(value.catNames) || value.catNames.length > 100
    || ![null, 'photo.jpg'].includes(value.photoFile as null | string)) return fail();
  const text = value.text.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, '');
  if (new TextEncoder().encode(text).length > 65_536 || !countWithin(text, 500)) return fail();
  const catNames = [...value.catNames];
  if (catNames.some((name) => typeof name !== 'string' || !name || new TextEncoder().encode(name).length > 800
    || !countWithin(name, 200))) return fail();
  if (!text && value.photoFile === null) return fail();
  return { formatVersion: 1, text, capturedAt: date(value.capturedAt), writtenAt: date(value.writtenAt),
    updatedAt: date(value.updatedAt), catNames: catNames as string[], photoFile: value.photoFile as 'photo.jpg' | null };
}
export function decodePhoto(value: unknown): Uint8Array | null {
  if (value === null) return null;
  if (typeof value !== 'string' || value.length < 4 || value.length > Math.ceil(MAX_PHOTO_BYTES / 3) * 4
    || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return fail();
  let binary: string;
  try { binary = atob(value); } catch { return fail(); }
  if (binary.length > MAX_PHOTO_BYTES || btoa(binary) !== value) return fail();
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
export function encodePhoto(bytes: Uint8Array | null): string | null {
  if (bytes === null) return null;
  let binary = '';
  for (let at = 0; at < bytes.length; at += 8192) binary += String.fromCharCode(...bytes.subarray(at, at + 8192));
  return btoa(binary);
}
export const recordId = (value: string): string => {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) throw new ServiceError('INVALID_RECORD_ID');
  return value;
};
