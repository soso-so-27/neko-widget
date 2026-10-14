import { ServiceError, type ArchiveDocument, type ToolBackupPart } from './contracts';
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
  const keys = ['formatVersion', 'text', 'capturedAt', 'writtenAt', 'updatedAt', 'catNames', 'photoFile', 'weight', 'toolBackup'];
  if (Object.keys(value).some((key) => !keys.includes(key)) || ![1, 2, 3].includes(value.formatVersion as number)
    || typeof value.text !== 'string' || !Array.isArray(value.catNames) || value.catNames.length > 100
    || ![null, 'photo.jpg'].includes(value.photoFile as null | string)) return fail();
  const text = value.text.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, '');
  if (new TextEncoder().encode(text).length > 65_536 || !countWithin(text, 500)) return fail();
  const catNames = [...value.catNames];
  if (catNames.some((name) => typeof name !== 'string' || !name || new TextEncoder().encode(name).length > 800
    || !countWithin(name, 200))) return fail();
  let weight: ArchiveDocument['weight'];
  if (value.weight !== undefined) {
    if (value.formatVersion !== 2 || !value.weight || typeof value.weight !== 'object' || Array.isArray(value.weight)) return fail();
    const item = value.weight as Record<string, unknown>;
    if (Object.keys(item).some(key => !['grams', 'measuredOn', 'catName'].includes(key))
      || !Number.isInteger(item.grams) || (item.grams as number) < 1 || (item.grams as number) > 100_000
      || !(item.catName === null || (typeof item.catName === 'string' && !!item.catName && !item.catName.includes('\0')
        && countWithin(item.catName, 200) && new TextEncoder().encode(item.catName).length <= 800))) return fail();
    if (item.measuredOn !== null) {
      if (typeof item.measuredOn !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(item.measuredOn)) return fail();
      date(item.measuredOn + 'T00:00:00Z'); // validates the civil day, without timezone conversion
    }
    weight = { grams: item.grams as number, measuredOn: item.measuredOn as string | null, catName: item.catName as string | null };
  }
  const toolBackup = value.toolBackup === undefined ? undefined : validateToolBackup(value.toolBackup);
  if ((value.formatVersion === 3) !== !!toolBackup || (toolBackup && (weight !== undefined
    || (value.photoFile !== null) !== (toolBackup.kind === 'photo')))) return fail();
  if (!text && value.photoFile === null && !weight && !toolBackup) return fail();
  return { formatVersion: value.formatVersion as 1 | 2 | 3, text, capturedAt: date(value.capturedAt), writtenAt: date(value.writtenAt),
    updatedAt: date(value.updatedAt), catNames: catNames as string[], photoFile: value.photoFile as 'photo.jpg' | null,
    ...(weight ? { weight } : {}), ...(toolBackup ? { toolBackup } : {}) };
}
function validateToolBackup(input: unknown): ToolBackupPart {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return fail();
  const v = input as Record<string, unknown>;
  if (Object.keys(v).length !== 7 || Object.keys(v).some(k => !['snapshotId', 'kind', 'path', 'part', 'count', 'sha256', 'payload'].includes(k))) return fail();
  if (typeof v.snapshotId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v.snapshotId)
    || !['index', 'json', 'photo'].includes(v.kind as string)
    || !Number.isInteger(v.part) || !Number.isInteger(v.count) || (v.part as number) < 0
    || (v.count as number) < 1 || (v.count as number) > 256 || (v.part as number) >= (v.count as number)
    || typeof v.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(v.sha256)
    || typeof v.payload !== 'string' || v.payload.length > (v.kind === 'index' ? 349528 : 65536) || typeof v.path !== 'string') return fail();
  if (v.kind === 'index') {
    if (v.path !== 'index.json' || v.part !== 0 || v.count !== 1 || !v.payload) return fail();
  } else if (!/^(CareHandoff|EvacuationPreparation|VeterinaryVisits|ShowcasePhotos|LostCatDrafts|CatPreparedness)\/[A-Za-z0-9-]+\.(json|jpg)$/.test(v.path)) return fail();
  if (v.kind === 'photo') {
    if (!v.path.endsWith('.jpg') || v.part !== 0 || v.count !== 1 || v.payload !== '') return fail();
  } else {
    if (!v.path.endsWith('.json') || !v.payload || v.payload.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(v.payload)) return fail();
    try { if (btoa(atob(v.payload)) !== v.payload) return fail(); } catch { return fail(); }
  }
  return v as unknown as ToolBackupPart;
}
/** The small completion record references immutable owner-local records. The
 * native restore additionally checks every piece's path, hash and snapshot ID. */
export function toolIndexRecordIDs(part: ToolBackupPart): string[] {
  if (part.kind !== 'index') return [];
  let index: { version?: unknown; snapshotID?: unknown; createdAt?: unknown; files?: unknown };
  try { index = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(part.payload), c => c.charCodeAt(0)))); }
  catch { return fail(); }
  if (!index || index.version !== 1 || typeof index.snapshotID !== 'string' || index.snapshotID.toLowerCase() !== part.snapshotId
    || typeof index.createdAt !== 'number' || !Number.isFinite(index.createdAt)
    || !Array.isArray(index.files) || !index.files.length || index.files.length > 999) return fail();
  const ids = new Set<string>([part.snapshotId]), paths = new Set<string>();
  for (const file of index.files) {
    if (!file || typeof file !== 'object' || typeof file.path !== 'string' || paths.has(file.path)
      || !/^(CareHandoff|EvacuationPreparation|VeterinaryVisits|ShowcasePhotos|LostCatDrafts|CatPreparedness)\/[A-Za-z0-9-]+\.(json|jpg)$/.test(file.path)
      || !Number.isInteger(file.bytes) || file.bytes <= 0 || file.bytes > (file.path.endsWith('.jpg') ? 20 : 8) * 1024 * 1024
      || typeof file.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(file.sha256) || !Array.isArray(file.records)
      || file.records.length !== (file.path.endsWith('.jpg') ? 1 : Math.ceil(file.bytes / 49152))) return fail();
    paths.add(file.path);
    for (const id of file.records) {
      if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id) || ids.has(id.toLowerCase())) return fail();
      ids.add(id.toLowerCase());
    }
  }
  if (ids.size > 1000) return fail();
  ids.delete(part.snapshotId);
  return [...ids];
}
export function decodePhoto(value: unknown): Uint8Array | null {
  if (value === null) return null;
  if (typeof value !== 'string' || value.length < 4 || value.length > Math.ceil(MAX_PHOTO_BYTES / 3) * 4
    || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return fail();
  const length = value.length / 4 * 3 - (value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0);
  if (length > MAX_PHOTO_BYTES) return fail();
  const result = new Uint8Array(length);
  let offset = 0;
  // Uint8Array.from(string, mapper) first materializes an iterable-sized list.
  // Decode aligned base64 blocks into the final bytes, keeping canonical checks.
  for (let at = 0; at < value.length; at += 8192) {
    const chunk = value.slice(at, at + 8192);
    let binary: string;
    try { binary = atob(chunk); } catch { return fail(); }
    if (btoa(binary) !== chunk) return fail();
    for (let index = 0; index < binary.length; index++) result[offset++] = binary.charCodeAt(index);
  }
  if (offset !== length) return fail();
  return result;
}
export function encodePhoto(bytes: Uint8Array | null): string | null {
  if (bytes === null) return null;
  // Multiples of three preserve base64 boundaries without a full-photo binary
  // string in addition to the input and final encoded string.
  const parts: string[] = [];
  for (let at = 0; at < bytes.length; at += 8190) {
    parts.push(btoa(String.fromCharCode(...bytes.subarray(at, at + 8190))));
  }
  return parts.join('');
}
export const recordId = (value: string): string => {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) throw new ServiceError('INVALID_RECORD_ID');
  return value;
};
