import { expect, it } from 'vitest';
import golden from './fixtures/tool-v4-golden.json';
import { parseToolIndex, validateDocument } from '../src/documents';
import { isCompleteToolRoot, parseToolNode, summarizeToolNode, toolNodeReferences, validateToolNodePaths } from '../src/tool-index-v4';
import type { ToolBackupPart } from '../src/contracts';

const part = (value: unknown): ToolBackupPart => ({ snapshotId: golden.snapshotID, kind: 'index', path: 'index.json',
  part: 0, count: 1, sha256: '0'.repeat(64), payload: btoa(JSON.stringify(value)) });
const child = { prefix: '8', snapshotID: 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', sha256: '0'.repeat(64),
  fileCount: 2, nodeCount: 1, toolMask: 32, manifestMask: 32 };
const branch = { version: 4, snapshotID: golden.snapshotID, uploadSnapshotID:golden.snapshotID, createdAt: 1, prefix: '', children: [child] };

it('assigns only new bits to care and notebook manifests without changing the old fixture',()=>{
  for(const [tool,bit] of [['CatCare',256],['FamilyNotebook',512]] as const){
    const files=[{...golden.files[0]!,path:tool+'/state.json'}];
    const node=parseToolNode(part({...golden,prefix:'',files}));
    if(node.version!==4)throw Error('wrong version');
    expect(summarizeToolNode(node)).toEqual({fileCount:1,nodeCount:1,toolMask:bit,manifestMask:bit});
    expect(isCompleteToolRoot(node)).toBe(true);
  }
});

it('decodes a shared golden leaf and computes fixed tool bits, direct refs and prefix membership', async () => {
  const node = parseToolNode(part(golden));
  expect(node).toEqual(golden);
  if (node.version !== 4) throw Error('wrong version');
  expect(summarizeToolNode(node)).toEqual({ fileCount: 2, nodeCount: 1, toolMask: 32, manifestMask: 32 });
  expect(toolNodeReferences(node)).toEqual(golden.files.flatMap(file => file.records));
  await validateToolNodePaths(node);
  expect(isCompleteToolRoot(node)).toBe(false);
  expect(isCompleteToolRoot(parseToolNode(part({ ...golden, prefix: '' })))).toBe(true);
  const root = parseToolNode(part(branch));
  if (root.version !== 4) throw Error('wrong version');
  expect(summarizeToolNode(root)).toEqual({ fileCount: 2, nodeCount: 2, toolMask: 32, manifestMask: 32 });
});

it('keeps fragment paths out of all legacy indexes but allows bounded raw transport documents', () => {
  for (const version of [1,2,3]) expect(() => parseToolIndex(part({ ...golden, version }))).toThrow('INVALID_RECORD');
  const document = { formatVersion: 3, text: '', capturedAt: null, writtenAt: null, updatedAt: null, catNames: [], photoFile: null,
    toolBackup: { ...part(golden), kind: 'json', path: golden.files[1]!.path, payload: btoa('\xff\x00') } };
  expect(validateDocument(document)).toEqual(document);
  for (const path of ['PhotoMemoryNotes/../state.json', 'PhotoMemoryNotes/other.json', 'Other/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.json']) {
    expect(() => validateDocument({ ...document, toolBackup: { ...document.toolBackup, path } })).toThrow();
  }
});

it('rejects ambiguous schemas, duplicate paths/IDs, extra fields and malformed bounds', () => {
  const f = golden.files[0]!;
  for (const patch of [
    { unknown: 1 }, { uploadSnapshotID:undefined }, { uploadSnapshotID:'bad' },
    { prefix:'',uploadSnapshotID:child.snapshotID },
    { children: [child] }, { files: [] }, { files: null }, { prefix: 'A' }, { prefix: 'a'.repeat(65) },
    { previousIndexID: golden.snapshotID }, { previousIndexID: 'bad' }, { createdAt: null },
    { files: [f,f] }, { files: [f,{ ...golden.files[1]!, records: f.records }] },
    { files: [{ ...f, extra: 1 }] }, { files: [{ ...f, bytes: 0 }] }, { files: [{ ...f, bytes: 8*1024*1024+1 }] },
    { files: [{ ...f, bytes: 1.5 }] }, { files: [{ ...f, sha256: 'F'.repeat(64) }] },
    { files: [{ ...f, records: [golden.snapshotID] }] }, { files: [{ ...f, sourceSnapshotID: 'bad' }] },
  ]) expect(() => parseToolNode(part({ ...golden, ...patch }))).toThrow('INVALID_RECORD');
  const oversize = { ...golden, createdAt: 1, files: [f], previousIndexID: 'f'.repeat(131072) };
  expect(() => parseToolNode(part(oversize))).toThrow('INVALID_RECORD');
});

it('bounds tree fanout, depth, file count, node count and summaries before any fetch', () => {
  for (const children of [[], [child, child], [{ ...child, extra: 1 }], [{ ...child, prefix: '80' }],
    [{ ...child, prefix: 'A' }], [{ ...child, fileCount: 100001 }], [{ ...child, nodeCount: 8192 }],
    [{ ...child, nodeCount: 0 }], [{ ...child, toolMask: 0 }], [{ ...child, manifestMask: 256 }],
    [{ ...child, toolMask: 1, manifestMask: 2 }], [{ ...child, snapshotID: golden.snapshotID }],
    [{ ...child, fileCount: 60000 }, { ...child, prefix: '9', snapshotID: 'ffffffff-ffff-ffff-ffff-ffffffffffff', fileCount: 60000 }],
  ]) expect(() => parseToolNode(part({ ...branch, children }))).toThrow('INVALID_RECORD');
  expect(() => parseToolNode(part({ ...branch, prefix: '8'.repeat(64), children: [{ ...child, prefix: '8'.repeat(65) }] }))).toThrow();
  const max = parseToolNode(part({ ...branch, children: [{ ...child, fileCount: 100000, nodeCount: 8191 }] }));
  expect(max.version).toBe(4); // Child facts are subsequently authenticated by storage.
});

it('rejects a leaf in the wrong radix partition and incomplete roots', async () => {
  const node = parseToolNode(part({ ...golden, prefix: '9' }));
  if (node.version !== 4) throw Error('wrong version');
  await expect(validateToolNodePaths(node)).rejects.toMatchObject({ code: 'INVALID_RECORD' });
  expect(isCompleteToolRoot(parseToolNode(part({ ...golden, prefix: '', files: [golden.files[1]] })))).toBe(false);
});

it('bounds leaf file and direct-record counts independently', () => {
  const uuid = (i: number) => `00000000-0000-0000-0000-${String(i).padStart(12,'0')}`;
  const files = Array.from({ length: 128 }, (_, i) => ({ path: `PhotoMemoryNotes/${uuid(i)}.json`, bytes: 49153,
    sha256: '0'.repeat(64), records: [uuid(1000+i*2),uuid(1001+i*2)] }));
  expect(parseToolNode(part({ ...golden, prefix: '', files })).version).toBe(4);
  expect(() => parseToolNode(part({ ...golden, prefix: '', files: [...files, { ...files[0], path: `PhotoMemoryNotes/${uuid(999)}.json` }] }))).toThrow();
  files[0] = { ...files[0]!, bytes: 98305, records: [...files[0]!.records,uuid(9999)] };
  expect(() => parseToolNode(part({ ...golden, prefix: '', files }))).toThrow();
});

it('enforces the decoded 128 KiB node bound rather than the larger legacy envelope', () => {
  const raw = JSON.stringify(golden), exact = raw+' '.repeat(128*1024-raw.length);
  expect(parseToolNode({ ...part(golden),payload:btoa(exact) })).toEqual(golden);
  expect(() => parseToolNode({ ...part(golden),payload:btoa(exact+' ') })).toThrow('INVALID_RECORD');
});
