import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore } from '../src/storage';
import { randomToken, sha256, type ArchiveDocument, type KeyCustody, type ToolBackupPart } from '../src/contracts';
import { parseToolNode, summarizeToolNode, type ToolNode } from '../src/tool-index-v4';
import type { ToolIndexFile } from '../src/documents';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const base: ArchiveDocument = { formatVersion: 1, text: 'synthetic', capturedAt: null, writtenAt: null, updatedAt: null,
  catNames: [], photoFile: null };
const request = (document: ArchiveDocument, expectedRevision: number | null = null) => ({
  expectedRevision, consentVersion: 'managed-preservation-v1', document, photoBase64: null });

async function fixture() {
  await binding.DB.prepare('UPDATE pa_recovery_write_policy SET delete_intent_required=0,owner_snapshot_required=0 WHERE singleton=1').run();
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt','decrypt']);
  const keys: KeyCustody = {
    async seal(value, context) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const data = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value as BufferSource);
      const result = new Uint8Array(12 + data.byteLength); result.set(iv); result.set(new Uint8Array(data),12); return result;
    },
    async open(value, context) {
      return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: value.slice(0,12),
        additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value.slice(12)));
    },
  };
  const now = () => 1_790_035_200_000;
  const auth = new DurableAuth({ db: binding.DB, keys, identityIndexSecret: randomToken(), now });
  const session = await auth.establish({ issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() });
  const options = { db: binding.DB, bucket: binding.ARCHIVE, keys, auth, now,
    membership: { status: async () => 'active' as const }, photos: { validateJPEG: async () => true },
    quotaBytes: 32 * 1024 * 1024, maximumRecords: 1000 };
  const archive = new ArchiveStore(options);
  const putPart = async (id: string, toolBackup: ToolBackupPart, store = archive) =>
    store.put(session.token, id, request({ ...base, formatVersion: 3, toolBackup }));
  const nodePart = async (node: { snapshotID: string }) => {
    const raw = JSON.stringify(node);
    return { snapshotId: node.snapshotID, kind: 'index' as const, path: 'index.json', part: 0, count: 1,
      sha256: await sha256(raw), payload: btoa(raw) };
  };
  const putNode = async <T extends { snapshotID: string }>(node: T, store = archive) => {
    const part = await nodePart(node); await putPart(node.snapshotID, part, store); return part;
  };
  const piece = async (snapshotID: string, path: string, raw = '{}'): Promise<ToolIndexFile> => {
    const id = crypto.randomUUID(), hash = await sha256(Uint8Array.from(raw,c=>c.charCodeAt(0)));
    await putPart(id,{ snapshotId: snapshotID, kind: 'json', path, part: 0, count: 1, sha256: hash, payload: btoa(raw) });
    return { path, bytes: raw.length, sha256: hash, records: [id] };
  };
  const head = async (id: string, node: { snapshotID: string }, expected: number | null = null, store = archive) => {
    const part = await nodePart(node);
    return store.put(session.token,id,request({ ...base,
      text: JSON.stringify({ kind: 'app-records-v1', snapshotID: node.snapshotID, indexHash: part.sha256 }) },expected));
  };
  return { options, archive, session, putPart, nodePart, putNode, piece, head };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;
const leaf = (snapshotID: string, prefix: string, files: ToolIndexFile[], uploadSnapshotID=snapshotID): ToolNode =>
  ({ version: 4, snapshotID, uploadSnapshotID, createdAt: 1, prefix, files });
const branch = (snapshotID:string,children:NonNullable<ToolNode['children']>,createdAt=1):ToolNode =>
  ({version:4,snapshotID,uploadSnapshotID:snapshotID,createdAt,prefix:'',children});
async function descriptor(f: Fixture, node: ToolNode) {
  return { prefix: node.prefix, snapshotID: node.snapshotID, sha256: (await f.nodePart(node)).sha256, ...summarizeToolNode(node) };
}
async function tree(f: Fixture, reuse?: { file: ToolIndexFile; snapshotID: string }) {
  const aID = crypto.randomUUID(), bID = crypto.randomUUID(), rootID=crypto.randomUUID();
  const piece = async(path:string,raw='{}')=>({...await f.piece(rootID,path,raw),sourceSnapshotID:rootID});
  const a = leaf(aID,'8',[
    await piece('PhotoMemoryNotes/state.json'),
    // Deliberately not UTF-8 JSON: v4 transports byte fragments opaquely.
    await piece('PhotoMemoryNotes/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.json','\xff\x00'),
  ],rootID);
  const b = leaf(bID,'e',[reuse ? { ...reuse.file, sourceSnapshotID: reuse.snapshotID } : await piece('CareHandoff/plan.json')],rootID);
  if (reuse) b.previousIndexID = reuse.snapshotID;
  await f.putNode(a); await f.putNode(b);
  const root = branch(rootID,[await descriptor(f,a),await descriptor(f,b)]);
  return { a,b,root };
}

it('migrates v3 to v4, keeps the old list readable, rejects downgrade and retires only unshared descendants', async () => {
  const f = await fixture(), oldID = crypto.randomUUID(), headID = crypto.randomUUID();
  const oldFile = await f.piece(oldID,'CareHandoff/plan.json');
  const old = { version: 3, snapshotID: oldID, createdAt: 1, files: [oldFile] };
  await f.putNode(old); await f.head(headID,old);
  const t = await tree(f,{ file: oldFile, snapshotID: oldID });
  await f.putNode(t.root); await f.putNode(t.root); await f.head(headID,t.root,1);
  await expect(f.head(headID,old,2)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  for (const id of [t.root.snapshotID,t.a.snapshotID,t.b.snapshotID,oldFile.records[0]!]) {
    await expect(f.archive.remove(f.session.token,id,1)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
  }
  await f.archive.remove(f.session.token,oldID,1);
  expect((await f.archive.read(f.session.token,oldFile.records[0]!)).revision).toBe(1);
  let cursor = '', emptyPages = 0, seen = 0;
  do {
    const page = await f.archive.list(f.session.token,cursor,1);
    if (!page.items.length) emptyPages++;
    for (const item of page.items) {
      expect(item.document.toolBackup?.path ?? '').not.toMatch(/\/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\.json$/u);
      seen++;
    }
    if (!page.nextCursor) break;
    expect(page.nextCursor > cursor).toBe(true); cursor = page.nextCursor;
  } while (true);
  expect(emptyPages).toBe(1); expect(seen).toBe(6);
  const replacement = branch(crypto.randomUUID(),[await descriptor(f,t.b)],2);
  await f.putNode(replacement); await f.head(headID,replacement,2);
  await f.archive.remove(f.session.token,t.root.snapshotID,1);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items).toEqual([{ recordId: t.a.snapshotID, kind: 'index' }]);
  await f.archive.remove(f.session.token,t.a.snapshotID,1);
  const clean = (await f.archive.toolCleanupCandidates(f.session.token)).items;
  expect(clean.map(x=>x.recordId).sort()).toEqual(t.a.files!.flatMap(x=>x.records).sort());
  for (const item of clean) await f.archive.remove(f.session.token,item.recordId,1,true);
  expect((await f.archive.read(f.session.token,t.b.snapshotID)).revision).toBe(1);
  expect((await f.archive.read(f.session.token,oldFile.records[0]!)).revision).toBe(1);
  expect((await f.archive.read(f.session.token,headID)).revision).toBe(3);
});

it('authenticates child owner, immutable revision, real hash and exact declared summaries', async () => {
  const f = await fixture(), other = await fixture(), t = await tree(f);
  const c = t.root.children![0]!;
  for (const patch of [{ snapshotID: crypto.randomUUID() }, { sha256: '0'.repeat(64) }, { fileCount: 1 },
    { nodeCount: 2 }, { toolMask: 33 }, { manifestMask: 0 }, { prefix: '9' }]) {
    const bad = branch(crypto.randomUUID(),[{ ...c,...patch }]);
    await expect(f.putNode(bad)).rejects.toMatchObject({ code: patch.snapshotID ? 'REVISION_CONFLICT' : 'INVALID_RECORD' });
  }
  await expect(other.putNode(t.root)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await binding.DB.prepare('UPDATE pa_records SET revision=2 WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,t.a.snapshotID).run();
  await expect(f.putNode(t.root)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
});

it('fences deletion claims before validation and during final node and head publication', async () => {
  const f = await fixture(), t = await tree(f);
  const seal = f.options.keys.seal.bind(f.options.keys);
  let raced = false;
  const racing = new ArchiveStore({ ...f.options, keys: { ...f.options.keys, async seal(value,context) {
    if (!raced && context.recordId === t.root.snapshotID+'/document') {
      raced = true;
      await binding.DB.prepare('INSERT INTO pa_tool_part_delete_claims(owner_id,part_id) VALUES(?,?)').bind(f.session.ownerId,t.a.snapshotID).run();
    }
    return seal(value,context);
  } } });
  await expect(f.putNode(t.root,racing)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await expect(f.putNode(t.root)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,t.root.snapshotID).first()).toBeNull();
  const root = branch(crypto.randomUUID(),[await descriptor(f,t.b)]);
  await f.putNode(root);
  const headID = crypto.randomUUID();
  const headRace = new ArchiveStore({ ...f.options, keys: { ...f.options.keys, async seal(value,context) {
    if (context.recordId === headID+'/document') await binding.DB.prepare(
      'INSERT INTO pa_tool_part_delete_claims(owner_id,part_id) VALUES(?,?)').bind(f.session.ownerId,root.snapshotID).run();
    return seal(value,context);
  } } });
  await expect(f.head(headID,root,null,headRace)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,headID).first()).toBeNull();
});

it('refuses partial roots and authenticates fragment bytes, source, owner and radix paths', async () => {
  const f = await fixture(), other = await fixture(), id = crypto.randomUUID();
  const fragment = await f.piece(id,'PhotoMemoryNotes/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.json','\xff\x00');
  const incomplete = leaf(id,'',[fragment]); await f.putNode(incomplete);
  await expect(f.head(crypto.randomUUID(),incomplete)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  for (const patch of [{ sha256: '0'.repeat(64) }, { bytes: 3 }, { sourceSnapshotID: crypto.randomUUID() }]) {
    const bad = leaf(crypto.randomUUID(),'',[{ ...fragment,sourceSnapshotID:id,...patch }]);
    await expect(f.putNode(bad)).rejects.toMatchObject({ code: 'INVALID_RECORD' });
  }
  const reuse = leaf(crypto.randomUUID(),'8',[{ ...fragment,sourceSnapshotID:id }]);
  await expect(other.putNode(reuse)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await expect(f.putNode({ ...reuse,prefix:'9' })).rejects.toMatchObject({ code: 'INVALID_RECORD' });
  await f.putNode(reuse);
  await expect(f.head(crypto.randomUUID(),reuse)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await f.archive.remove(f.session.token,incomplete.snapshotID,1);
  await expect(f.archive.remove(f.session.token,fragment.records[0]!,1,true)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
});

it('reuses authenticated exact v4 leaf tuples without reopening unchanged pieces and fences their races', async () => {
  const f = await fixture(), t = await tree(f);
  const next = leaf(crypto.randomUUID(),'8',t.a.files!);
  next.previousIndexID = t.a.snapshotID;
  const ids = new Set(t.a.files!.flatMap(file=>file.records).map(id=>id+'/document'));
  const keys: KeyCustody = { ...f.options.keys, async open(value,context) {
    if (context.recordId && ids.has(context.recordId)) throw Error('unchanged piece reopened');
    return f.options.keys.open(value,context);
  } };
  await f.putNode(next,new ArchiveStore({ ...f.options,keys }));
  const forged = { ...next,snapshotID:crypto.randomUUID(),files:next.files!.map((file,i)=>i===0?{ ...file,sha256:'0'.repeat(64) }:file) };
  await expect(f.putNode(forged)).rejects.toMatchObject({ code:'INVALID_RECORD' });
  const raced = { ...next,snapshotID:crypto.randomUUID() };
  const racing = new ArchiveStore({ ...f.options,keys:{ ...f.options.keys,async seal(value,context) {
    if (context.recordId===raced.snapshotID+'/document') await binding.DB.prepare(
      'INSERT INTO pa_tool_part_delete_claims(owner_id,part_id) VALUES(?,?)').bind(f.session.ownerId,next.files![0]!.records[0]!).run();
    return f.options.keys.seal(value,context);
  } } });
  await expect(f.putNode(raced,racing)).rejects.toMatchObject({ code:'REVISION_CONFLICT' });
});

it('commits all 256 leaf references atomically within bounded D1 parameter and statement batches', async () => {
  const f = await fixture(), id = crypto.randomUUID(), files: ToolIndexFile[] = [];
  const raw = 'x'.repeat(49152), fullHash = await sha256(raw+'y');
  const largeHash = await sha256(raw), smallHash = await sha256('y');
  for (let i = 0; i < 128; i++) {
    const path = `PhotoMemoryNotes/${crypto.randomUUID()}.json`, records = [crypto.randomUUID(),crypto.randomUUID()];
    for (const [offset,recordID] of records.entries()) await f.putPart(recordID,{
      snapshotId:id,kind:'json',path,part:offset,count:2,sha256:offset===0?largeHash:smallHash,payload:btoa(offset===0?raw:'y'),
    });
    files.push({ path,bytes:49153,sha256:fullHash,records });
  }
  await f.putNode(leaf(id,'',files));
  expect(await binding.DB.prepare('SELECT count(*) AS n FROM pa_tool_snapshot_references WHERE owner_id=? AND snapshot_id=?')
    .bind(f.session.ownerId,id).first()).toEqual({ n:256 });
  await expect(f.archive.remove(f.session.token,files[127]!.records[1]!,1,true)).rejects.toMatchObject({ code:'TOOL_PART_REFERENCED' });
  await f.archive.remove(f.session.token,id,1);
  expect(await binding.DB.prepare('SELECT count(*) AS n FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id<>?')
    .bind(f.session.ownerId,id).first()).toEqual({ n:256 });
},30_000);

it('abandons a staged v4 tree without weakening published-head protection or losing recursive cleanup intent', async () => {
  const f = await fixture(), t = await tree(f); await f.putNode(t.root);
  await f.archive.abandonToolSnapshot(f.session.token,t.root.snapshotID);
  await expect(f.head(crypto.randomUUID(),t.root)).rejects.toMatchObject({ code:'REVISION_CONFLICT' });
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items).toEqual([{ recordId:t.root.snapshotID,kind:'index' }]);
  await f.archive.remove(f.session.token,t.root.snapshotID,1);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x=>x.recordId).sort()).toEqual([t.a.snapshotID,t.b.snapshotID].sort());
  await f.archive.remove(f.session.token,t.a.snapshotID,1); await f.archive.remove(f.session.token,t.b.snapshotID,1);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x=>x.recordId).sort()).toEqual(
    [...t.a.files!,...t.b.files!].flatMap(x=>x.records).sort());
});

it('abandons before root upload, blocks late and idempotent node writes, and preserves a published shared child', async () => {
  const f=await fixture(), accepted=await tree(f), headID=crypto.randomUUID();
  await f.putNode(accepted.root); await f.head(headID,accepted.root);
  await expect(f.archive.abandonToolSnapshot(f.session.token,accepted.root.snapshotID))
    .rejects.toMatchObject({code:'REVISION_CONFLICT'});
  const pending=crypto.randomUUID(), childID=crypto.randomUUID();
  const file={...await f.piece(pending,'PhotoMemoryNotes/state.json'),sourceSnapshotID:pending};
  const child=leaf(childID,'8',[file],pending); await f.putNode(child);
  const loose=await f.piece(pending,'PhotoMemoryNotes/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.json');
  const root=branch(pending,[await descriptor(f,child),await descriptor(f,accepted.b)]);
  await f.archive.abandonToolSnapshot(f.session.token,pending);
  await f.archive.abandonToolSnapshot(f.session.token,pending);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x=>x.recordId).sort())
    .toEqual([childID,loose.records[0]!].sort());
  await expect(f.putNode(child)).rejects.toMatchObject({code:'TOOL_SNAPSHOT_ABANDONED'});
  await expect(f.putNode(leaf(crypto.randomUUID(),'8',[file],pending)))
    .rejects.toMatchObject({code:'TOOL_SNAPSHOT_ABANDONED'});
  await expect(f.putNode(root)).rejects.toMatchObject({code:'TOOL_SNAPSHOT_ABANDONED'});
  await f.archive.remove(f.session.token,childID,1);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x=>x.recordId).sort())
    .toEqual([file.records[0]!,loose.records[0]!].sort());
  for(const id of [file.records[0]!,loose.records[0]!]) await f.archive.remove(f.session.token,id,1,true);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items).toEqual([]);
  for(const id of [headID,accepted.root.snapshotID,accepted.b.snapshotID,...accepted.b.files![0]!.records])
    expect((await f.archive.read(f.session.token,id)).revision).toBe(1);
});

it('fences an abandonment between validation and final node insertion and during an existing retry', async () => {
  const f=await fixture(), pending=crypto.randomUUID(), childID=crypto.randomUUID();
  const file={...await f.piece(pending,'PhotoMemoryNotes/state.json'),sourceSnapshotID:pending};
  const node=leaf(childID,'8',[file],pending);
  let raced=false;
  const store=new ArchiveStore({...f.options,keys:{...f.options.keys,async seal(value,context){
    if(!raced && context.recordId===childID+'/document') {
      raced=true; await f.archive.abandonToolSnapshot(f.session.token,pending);
    }
    return f.options.keys.seal(value,context);
  }}});
  await expect(f.putNode(node,store)).rejects.toMatchObject({code:'REVISION_CONFLICT'});
  expect(await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId,childID).first()).toBeNull();
  const t=await tree(f); let retried=false;
  const retry=new ArchiveStore({...f.options,keys:{...f.options.keys,async open(value,context){
    if(!retried && context.recordId===t.a.snapshotID+'/document') {
      retried=true; await f.archive.abandonToolSnapshot(f.session.token,t.root.snapshotID);
    }
    return f.options.keys.open(value,context);
  }}});
  await expect(f.putNode(t.a,retry)).rejects.toMatchObject({code:'TOOL_SNAPSHOT_ABANDONED'});
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x=>x.recordId).sort())
    .toEqual([file.records[0]!,t.a.snapshotID,t.b.snapshotID].sort());
});

it('claims 36500 unfinished parts in one bounded set transaction without loading a part inventory',async()=>{
  const f=await fixture(), pending=crypto.randomUUID(), count=36_500, db=binding.DB;
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(f.session.ownerId).run();
  await db.prepare(`WITH RECURSIVE ids(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n<?)
    INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,metadata)
    SELECT ?,lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4000-8000-'||lower(hex(randomblob(6))),
      1,'synthetic','synthetic',X'01' FROM ids`).bind(count,f.session.ownerId).run();
  await db.prepare(`INSERT INTO pa_tool_record_sources(owner_id,record_id,snapshot_id,kind)
    SELECT owner_id,record_id,?,'json' FROM pa_records WHERE owner_id=?`).bind(pending,f.session.ownerId).run();
  const batchSizes:number[]=[];
  const measured=new Proxy(db,{get(target,key){
    if(key==='batch') return async(statements:D1PreparedStatement[])=>{
      batchSizes.push(statements.length);return target.batch(statements);
    };
    if(key==='prepare') return(sql:string)=>{
      expect(sql).not.toMatch(/^\s*SELECT[\s\S]*FROM pa_tool_record_sources/u);
      return target.prepare(sql);
    };
    const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
  await new ArchiveStore({...f.options,db:measured}).abandonToolSnapshot(f.session.token,pending);
  expect(batchSizes).toEqual([2]);
  expect(await db.prepare('SELECT count(*) AS n FROM pa_tool_part_delete_claims WHERE owner_id=?')
    .bind(f.session.ownerId).first()).toEqual({n:count});
},30_000);
