import { expect, it } from 'vitest';
import { parseToolIndex, validateDocument } from '../src/documents';
import type { ToolBackupPart } from '../src/contracts';
const part = { snapshotId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', kind: 'json',
  path: 'CareHandoff/plan.json', part: 0, count: 1, sha256: '0'.repeat(64), payload: btoa('{}') };
const doc = { formatVersion: 3, text: 'ツールの保存', capturedAt: null, writtenAt: null, updatedAt: null,
  catNames: [], photoFile: null, toolBackup: part };
it('round trips tool pieces without dropping private tool fields or changing legacy shape', () => {
  expect(validateDocument(doc)).toEqual(doc);
  const legacy = { ...doc, formatVersion: 1 }; delete (legacy as Partial<typeof doc>).toolBackup;
  expect(validateDocument(legacy)).toEqual(legacy);
  expect(validateDocument({ ...doc, toolBackup: { ...part, kind: 'index', path: 'index.json' } }).toolBackup?.kind).toBe('index');
  expect(validateDocument({ ...doc, photoFile: 'photo.jpg', toolBackup: { ...part, kind: 'photo',
    path: 'VeterinaryVisits/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jpg', payload: '' } }).photoFile).toBe('photo.jpg');
});
it('rejects schema confusion, extra fields, unsafe paths, noncanonical data and unbounded pieces', () => {
  for (const formatVersion of [1, 2, 4]) expect(() => validateDocument({ ...doc, formatVersion })).toThrow();
  expect(() => validateDocument({ ...doc, toolBackup: undefined })).toThrow();
  expect(() => validateDocument({ ...doc, weight: { grams: 4000, measuredOn: null, catName: null } })).toThrow();
  for (const path of ['../plan.json', 'CareHandoff/../plan.json', '/CareHandoff/plan.json', 'PhotoLibrary/a.jpg', 'CareHandoff\\plan.json'])
    expect(() => validateDocument({ ...doc, toolBackup: { ...part, path } })).toThrow();
  for (const patch of [{ extra: true }, { count: 0 }, { count: 257 }, { part: -1 }, { part: 1 }, { part: 0.5 },
    { snapshotId: 'wrong-owner' }, { payload: 'Zh==' }, { payload: 'a'.repeat(65540) }, { sha256: 'x'.repeat(64) },
    { kind: 'photo' }, { kind: 'index', path: 'index.json', part: 1, count: 2 }])
    expect(() => validateDocument({ ...doc, toolBackup: { ...part, ...patch } })).toThrow();
});

const manifest = { path: 'CareHandoff/plan.json', bytes: 2, sha256: '0'.repeat(64),
  records: ['bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'] };
const photo = { path: 'CareHandoff/cccccccc-cccc-cccc-cccc-cccccccccccc.jpg', bytes: 3,
  sha256: '1'.repeat(64), records: ['cccccccc-cccc-cccc-cccc-cccccccccccc'] };
function indexPart(files: unknown[], version = 1): ToolBackupPart {
  return { ...part, kind: 'index', path: 'index.json', payload: btoa(JSON.stringify({
    version, snapshotID: part.snapshotId.toUpperCase(), createdAt: 1, files,
  })) } as ToolBackupPart;
}
it('accepts native v1 and v2 file contracts and preserves direct original photo references', () => {
  const v1 = parseToolIndex(indexPart([manifest, photo]));
  expect(v1.version).toBe(1);
  const reused = { ...photo, sourceSnapshotID: 'dddddddd-dddd-dddd-dddd-dddddddddddd' };
  expect(parseToolIndex(indexPart([manifest, reused], 2)).files).toEqual([manifest, reused]);
  expect(() => parseToolIndex(indexPart([manifest, reused]))).toThrow('INVALID_RECORD');
});
it('v3 reuses immutable JSON while older index contracts reject that reference', () => {
  const shared = { ...manifest, sourceSnapshotID: 'dddddddd-dddd-dddd-dddd-dddddddddddd' };
  expect(parseToolIndex(indexPart([shared], 3)).files).toEqual([shared]);
  for (const version of [1, 2]) expect(() => parseToolIndex(indexPart([shared], version))).toThrow('INVALID_RECORD');
  for (const path of ['PhotoMemoryNotes/state.json', 'CatIdentity/state.json']) {
    expect(parseToolIndex(indexPart([{ ...manifest, path }], 3)).files[0]?.path).toBe(path);
  }
});
it('rejects an index missing its tool manifest or using paths native restoration cannot read', () => {
  for (const files of [
    [photo],
    [{ ...manifest, path: 'CareHandoff/other.json' }],
    [{ ...manifest, path: 'VeterinaryVisits/plan.json' }],
    [manifest, { ...photo, path: 'CareHandoff/not-a-uuid.jpg' }],
    [manifest, { ...photo, path: 'ShowcasePhotos/cccccccc-cccc-cccc-cccc-cccccccccccc.jpg' }],
  ]) for (const version of [1, 2]) {
    expect(() => parseToolIndex(indexPart(files, version))).toThrow('INVALID_RECORD');
  }
});
