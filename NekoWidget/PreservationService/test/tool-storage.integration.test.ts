import { env } from 'cloudflare:workers';
import type { D1Migration } from 'cloudflare:test';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { ArchiveStore, cleanupArchive } from '../src/storage';
import { encodePhoto } from '../src/documents';
import { randomToken, sha256, ServiceError, type ArchiveDocument, type KeyCustody } from '../src/contracts';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import type { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { type RecoveryObject, S3RecoveryCopy } from '../src/s3-recovery-copy';
import worker, { route, type Services, type Env } from '../src/index';
import { PilotControl } from '../src/pilot-control';
import { IntakeControl } from '../src/intake-control';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const photo = new Uint8Array([255, 216, 255, 217]); // Synthetic, injected validator; not a real JPEG test.
const document: ArchiveDocument = { formatVersion: 1, text: 'ひざで寝た日', capturedAt: '2023-03-02T05:00:00.000Z',
  writtenAt: null, updatedAt: null, catNames: ['むぎ', 'そら'], photoFile: 'photo.jpg' };

async function fixture(overrides: { quotaBytes?: number; maximumRecords?: number } = {}) {
  await binding.DB.prepare(`UPDATE pa_recovery_write_policy SET delete_intent_required=0
    WHERE singleton=1`).run();
  let now = 1_790_035_200_000;
  let state: 'active' | 'expired' | 'unknown' | 'grace' = 'active';
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const keys: KeyCustody = {
    async seal(value, context) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value as BufferSource);
      const output = new Uint8Array(12 + cipher.byteLength); output.set(iv); output.set(new Uint8Array(cipher), 12); return output;
    },
    async open(value, context) {
      return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: value.slice(0, 12),
        additionalData: new TextEncoder().encode(JSON.stringify(context)) }, key, value.slice(12)));
    },
  };
  const authOptions = { db: binding.DB, keys, identityIndexSecret: randomToken(), now: () => now };
  const auth = new DurableAuth(authOptions);
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() };
  const session = await auth.establish(identity);
  const options = { db: binding.DB, bucket: binding.ARCHIVE, keys, auth, now: () => now,
    membership: { status: async () => state }, photos: { validateJPEG: async () => true },
    quotaBytes: overrides.quotaBytes ?? 100_000, maximumRecords: overrides.maximumRecords ?? 100 };
  const archive = new ArchiveStore(options);
  const request = (patch: Record<string, unknown> = {}) => ({ expectedRevision: null, consentVersion: 'managed-preservation-v1',
    document, photoBase64: encodePhoto(photo), ...patch });
  return { auth, authOptions, identity, session, archive, options, request,
    setState(value: typeof state) { state = value; }, setNow(value: number) { now = value; } };
}

it('preserves immutable tool pieces across retries, owner isolation and expired membership reads', async () => {
  const f = await fixture(), other = await fixture(), id = crypto.randomUUID();
  const payload = btoa('{"cats":[],"contact":"private"}');
  const tool = { snapshotId: crypto.randomUUID(), kind: 'json' as const, path: 'CareHandoff/plan.json',
    part: 0, count: 1, sha256: await sha256(atob(payload)), payload };
  const next = { ...document, formatVersion: 3, photoFile: null, toolBackup: tool };
  const request = f.request({ document: next, photoBase64: null });
  expect(await f.archive.put(f.session.token, id, request)).toEqual({ recordId: id, revision: 1 });
  expect(await f.archive.put(f.session.token, id, request)).toEqual({ recordId: id, revision: 1 });
  expect((await f.archive.read(f.session.token, id)).document.toolBackup).toEqual(tool);
  await expect(f.archive.put(f.session.token, id, { ...request, expectedRevision: 1 })).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await expect(f.archive.put(f.session.token, id, f.request({ expectedRevision: 1, photoBase64: null,
    document: { ...document, photoFile: null } }))).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await expect(f.archive.read(other.session.token, id)).rejects.toThrow();
  await expect(f.archive.put(f.session.token, crypto.randomUUID(), { ...request,
    document: { ...next, toolBackup: { ...tool, sha256: '0'.repeat(64) } } })).rejects.toMatchObject({ code: 'INVALID_RECORD' });
  f.setState('expired');
  expect((await f.archive.read(f.session.token, id)).document.toolBackup).toEqual(tool);
});

it('publishes an index only with every owner-local immutable piece present and the inventory unchanged', async () => {
  const f = await fixture(), id = crypto.randomUUID(), snapshotId = crypto.randomUUID();
  const data = '{}', hash = await sha256(data);
  const tool = { snapshotId, kind: 'json', path: 'CareHandoff/plan.json', part: 0, count: 1, sha256: hash, payload: btoa(data) };
  const pieceDocument = { ...document, formatVersion: 3, photoFile: null, toolBackup: tool };
  const payload = btoa(JSON.stringify({ version: 1, snapshotID: snapshotId.toUpperCase(), createdAt: 1,
    files: [{ path: tool.path, bytes: 2, sha256: hash, records: [id.toUpperCase()] }] }));
  const indexDocument = { ...pieceDocument, toolBackup: { ...tool, kind: 'index', path: 'index.json', payload, sha256: await sha256(atob(payload)) } };
  const indexRequest = f.request({ document: indexDocument, photoBase64: null });
  await expect(f.archive.put(f.session.token, snapshotId, indexRequest)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  await f.archive.put(f.session.token, id, f.request({ document: pieceDocument, photoBase64: null }));
  const raced = new ArchiveStore({ ...f.options, membership: { status: async () => {
    // Independent authorized mutation between reference check and index commit.
    await binding.DB.prepare('UPDATE pa_records SET revision=revision+1 WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, id).run();
    return 'active';
  } } });
  await expect(raced.put(f.session.token, snapshotId, indexRequest)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, snapshotId).first()).toBeNull();
  // Use a fresh immutable piece after the deliberately raced test row.
  const id2 = crypto.randomUUID();
  await f.archive.put(f.session.token, id2, f.request({ document: pieceDocument, photoBase64: null }));
  const completePayload = btoa(JSON.stringify({ version: 1, snapshotID: snapshotId, createdAt: 1,
    files: [{ path: tool.path, bytes: 2, sha256: hash, records: [id2] }] }));
  const complete = f.request({ photoBase64: null, document: { ...indexDocument,
    toolBackup: { ...indexDocument.toolBackup, payload: completePayload, sha256: await sha256(atob(completePayload)) } } });
  expect(await f.archive.put(f.session.token, snapshotId, complete)).toEqual({ recordId: snapshotId, revision: 1 });
  expect(await f.archive.put(f.session.token, snapshotId, complete)).toEqual({ recordId: snapshotId, revision: 1 });
});

async function snapshot(f: Awaited<ReturnType<typeof fixture>>, reuse?: { id: string; origin: string }) {
  const id = crypto.randomUUID(), photoID = reuse?.id ?? crypto.randomUUID(), jsonID = crypto.randomUUID();
  const path = `CareHandoff/${photoID}.jpg`, photoHash = await sha256(photo), json = '{}';
  const put = async (recordID: string, tool: unknown, jpeg: Uint8Array | null = null) => f.archive.put(f.session.token, recordID,
    f.request({ document: { ...document, formatVersion: 3, photoFile: jpeg ? 'photo.jpg' : null, toolBackup: tool }, photoBase64: encodePhoto(jpeg) }));
  if (!reuse) await put(photoID, { snapshotId: id, kind: 'photo', path, part: 0, count: 1, sha256: photoHash, payload: '' }, photo);
  await put(jsonID, { snapshotId: id, kind: 'json', path: 'CareHandoff/plan.json', part: 0, count: 1, sha256: await sha256(json), payload: btoa(json) });
  const index = { version: reuse ? 2 : 1, snapshotID: id, createdAt: 1, files: [
    { path: 'CareHandoff/plan.json', bytes: 2, sha256: await sha256(json), records: [jsonID] },
    { path, bytes: photo.length, sha256: photoHash, records: [photoID], ...(reuse ? { sourceSnapshotID: reuse.origin } : {}) },
  ] };
  const publish = async (value = index) => {
    const payload = btoa(JSON.stringify(value));
    return put(id, { snapshotId: id, kind: 'index', path: 'index.json', part: 0, count: 1, sha256: await sha256(atob(payload)), payload });
  };
  return { id, photoID, jsonID, index, publish };
}

it('bounds concurrent metadata unwraps at the configured 200-record snapshot boundary', async () => {
  const f = await fixture({ maximumRecords: 200, quotaBytes: 2_000_000 });
  const snapshotId = crypto.randomUUID(), hash = await sha256(photo);
  const files = [];
  const manifestId = crypto.randomUUID(), manifestHash = await sha256('{}');
  await f.archive.put(f.session.token, manifestId, f.request({ photoBase64: null,
    document: { ...document, formatVersion: 3, photoFile: null, toolBackup: { snapshotId,
      kind: 'json', path: 'CareHandoff/plan.json', part: 0, count: 1, sha256: manifestHash, payload: btoa('{}') } } }));
  files.push({ path: 'CareHandoff/plan.json', bytes: 2, sha256: manifestHash, records: [manifestId] });
  for (let n = 0; n < 198; n++) {
    const id = crypto.randomUUID(), path = `CareHandoff/${id}.jpg`;
    await f.archive.put(f.session.token, id, f.request({ document: { ...document, formatVersion: 3,
      toolBackup: { snapshotId, kind: 'photo', path, part: 0, count: 1, sha256: hash, payload: '' } } }));
    files.push({ path, bytes: photo.length, sha256: hash, records: [id] });
  }
  let active = 0, peak = 0, opened = 0;
  const keys: KeyCustody = { ...f.options.keys, async open(value, context) {
    if (context.purpose !== 'record' || !context.recordId?.endsWith('/document')) return f.options.keys.open(value, context);
    active++; opened++; peak = Math.max(peak, active);
    try {
      // A serial implementation would spend 99.5 seconds here alone, beyond
      // the app's 60-second request. This is synthetic latency, not AWS timing.
      await new Promise(resolve => setTimeout(resolve, 500));
      return await f.options.keys.open(value, context);
    } finally { active--; }
  } };
  const archive = new ArchiveStore({ ...f.options, keys });
  const payload = btoa(JSON.stringify({ version: 2, snapshotID: snapshotId, createdAt: 1, files }));
  const start = Date.now();
  expect(await archive.put(f.session.token, snapshotId, f.request({ photoBase64: null,
    document: { ...document, formatVersion: 3, photoFile: null,
      toolBackup: { snapshotId, kind: 'index', path: 'index.json', part: 0, count: 1,
        sha256: await sha256(atob(payload)), payload } } }))).toEqual({ recordId: snapshotId, revision: 1 });
  expect(opened).toBe(199); expect(active).toBe(0);
  expect(peak).toBeGreaterThan(1); expect(peak).toBeLessThanOrEqual(8);
  expect(Date.now() - start).toBeLessThan(35_000);
  expect(await binding.DB.prepare('SELECT count(*) AS n FROM pa_tool_snapshot_references WHERE owner_id=?')
    .bind(f.session.ownerId).first()).toEqual({ n: 199 });
  // A missing transport folder must not scan/decrypt this whole owner merely
  // to fence its abandoned snapshot. Cleanup uses the same eight-way bound.
  opened = 0; peak = 0;
  await archive.abandonToolSnapshot(f.session.token, crypto.randomUUID());
  expect(opened).toBe(0);
  await f.archive.remove(f.session.token, snapshotId, 1);
  const cleanupStart = Date.now();
  const page = await archive.toolCleanupCandidates(f.session.token);
  expect(page.items).toHaveLength(50); expect(page.hasMore).toBe(true);
  expect(page.nextCursor).toBe(page.items.at(-1)!.recordId);
  expect(opened).toBe(199); expect(peak).toBeGreaterThan(1); expect(peak).toBeLessThanOrEqual(8);
  expect(Date.now() - cleanupStart).toBeLessThan(35_000);
}, 45_000);

it('reuses one photo across snapshots and protects both legacy and shared dependencies during deletion', async () => {
  const f = await fixture();
  const a = await snapshot(f); await a.publish();
  const b = await snapshot(f, { id: a.photoID, origin: a.id }); await b.publish();
  const inventory = await binding.ARCHIVE.list({ prefix: `personal/${f.session.ownerId}/` });
  expect(inventory.objects).toHaveLength(1); // No second ciphertext or photo upload.
  await expect(f.archive.remove(f.session.token, a.photoID, 1)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
  await f.archive.remove(f.session.token, b.id, 1);
  expect(await binding.DB.prepare('SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id=?')
    .bind(f.session.ownerId, a.photoID).first()).toBeNull();
  await expect(f.archive.remove(f.session.token, a.photoID, 1, true)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
  expect((await f.archive.read(f.session.token, a.photoID)).document.toolBackup?.sha256).toBe(await sha256(photo));
  const c = await snapshot(f, { id: a.photoID, origin: a.id }); await c.publish();
  await f.archive.remove(f.session.token, a.id, 1);
  await expect(f.archive.remove(f.session.token, a.photoID, 1, true)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
  // Reuse still works after the original index is gone: origin is the photo's tag.
  const d = await snapshot(f, { id: a.photoID, origin: a.id }); await d.publish();
  await f.archive.remove(f.session.token, c.id, 1); await f.archive.remove(f.session.token, d.id, 1);
  expect(await binding.DB.prepare('SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id=?')
    .bind(f.session.ownerId, a.photoID).first()).not.toBeNull();
  await f.archive.remove(f.session.token, a.photoID, 1, true);
  await expect(f.archive.read(f.session.token, a.photoID)).rejects.toMatchObject({ code: 'RECORD_NOT_FOUND' });
});

it('durably claims a legacy source index parts when its index is retired', async () => {
  const f = await fixture(), a = await snapshot(f); await a.publish();
  await f.archive.remove(f.session.token, a.id, 1);
  for (const id of [a.photoID,a.jsonID]) {
    expect(await binding.DB.prepare('SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id=?')
      .bind(f.session.ownerId,id).first()).not.toBeNull();
  }
});

it('rejects incorrect shared photo identity, hash, size and other-owner references', async () => {
  const f = await fixture(), other = await fixture();
  const a = await snapshot(f); await a.publish();
  const b = await snapshot(f, { id: a.photoID, origin: a.id });
  for (const patch of [{ sourceSnapshotID: crypto.randomUUID() }, { sha256: '0'.repeat(64) }, { bytes: photo.length + 1 }]) {
    const bad = { ...b.index, files: [b.index.files[0]!, { ...b.index.files[1]!, ...patch }] };
    await expect(b.publish(bad)).rejects.toMatchObject({ code: 'INVALID_RECORD' });
  }
  const foreign = await snapshot(other, { id: a.photoID, origin: a.id });
  await expect(foreign.publish()).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_tool_snapshot_references WHERE owner_id=?').bind(other.session.ownerId).first()).toBeNull();
});

it('claims deletion before external recovery work and prevents a new index after an uncertain delete', async () => {
  const f = await fixture(), a = await snapshot(f); await a.publish();
  await f.archive.remove(f.session.token, a.id, 1);
  // This fixture deliberately models a pre-recovery legacy row so the next
  // readback reaches the injected external copy failure.
  await binding.DB.prepare(`INSERT INTO pa_record_legacy_baseline
    SELECT owner_id,record_id,revision,initial_operation,initial_fingerprint,photo_key,photo_bytes,quota_bytes,deleted
    FROM pa_records WHERE owner_id=? AND record_id=?`).bind(f.session.ownerId, a.photoID).run();
  let sawClaim = false;
  const recovery = { copy: async () => {
    sawClaim = !!await binding.DB.prepare('SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id=?')
      .bind(f.session.ownerId, a.photoID).first();
    throw new ServiceError('RECOVERY_PENDING', 503);
  } } as unknown as RecordRecoveryCopy;
  const deleting = new ArchiveStore({ ...f.options, recovery });
  await expect(deleting.remove(f.session.token, a.photoID, 1, true)).rejects.toThrow();
  expect(sawClaim).toBe(true);
  const b = await snapshot(f, { id: a.photoID, origin: a.id });
  await expect(b.publish()).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect((await f.archive.list(f.session.token, '', 50)).items.find(item => item.recordId === a.photoID))
    .toMatchObject({ toolPhotoReusable: false });
  await f.archive.remove(f.session.token, a.photoID, 1, true); // Explicit retry finishes the same deletion.
});

it('rejects a commit when a deletion claim appears after reference validation', async () => {
  const f = await fixture(), a = await snapshot(f); await a.publish();
  const b = await snapshot(f, { id: a.photoID, origin: a.id });
  const original = f.options.keys.seal.bind(f.options.keys);
  let raced = false;
  f.options.keys.seal = async (bytes, context) => {
    if (!raced && context.recordId === `${b.id}/document`) {
      raced = true;
      await binding.DB.prepare('INSERT INTO pa_tool_part_delete_claims(owner_id,part_id) VALUES(?,?)')
        .bind(f.session.ownerId, a.photoID).run();
    }
    return original(bytes, context);
  };
  await expect(b.publish()).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(f.session.ownerId, b.id).first()).toBeNull();
});


it('keeps an automatic head and immutable JSON references atomic across devices, cleanup and retries', async () => {
  const f = await fixture({ maximumRecords: 5, quotaBytes: 1_000_000 });
  const a = await snapshot(f);
  const initial = { ...a.index, version: 3 };
  await a.publish(initial);
  const headID = crypto.randomUUID();
  const headDocument = async (index: typeof initial) => ({ ...document, formatVersion: 1,
    photoFile: null, text: JSON.stringify({ kind: 'app-records-v1', snapshotID: index.snapshotID,
      indexHash: await sha256(JSON.stringify(index)) }) });
  const putHead = async (index: typeof initial, expectedRevision: number | null) => f.archive.put(f.session.token, headID,
    f.request({ expectedRevision, photoBase64: null, document: await headDocument(index) }));
  await putHead(initial, null);
  await expect(f.archive.remove(f.session.token, a.id, 1)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
  await expect(f.archive.remove(f.session.token, headID, 1)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
  let previous = initial;
  for (let revision = 1; revision <= 20; revision++) {
    const next = { ...initial, snapshotID: crypto.randomUUID(), files: initial.files.map(file => ({ ...file, sourceSnapshotID: initial.snapshotID })) };
    const payload = btoa(JSON.stringify(next));
    await f.archive.put(f.session.token, next.snapshotID, f.request({ photoBase64: null,
      document: { ...document, formatVersion: 3, photoFile: null, toolBackup: { snapshotId: next.snapshotID,
        kind: 'index', path: 'index.json', part: 0, count: 1, sha256: await sha256(atob(payload)), payload } } }));
    expect(await putHead(next, revision)).toEqual({ recordId: headID, revision: revision + 1 });
    // Device B cannot overwrite the accepted head with the stale revision.
    await expect(putHead(previous, revision)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
    await f.archive.remove(f.session.token, previous.snapshotID, 1);
    // Lost-response rebasing must never publish the deleted prior index.
    await expect(putHead(previous, revision + 1)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
    await expect(f.archive.remove(f.session.token, a.jsonID, 1, true)).rejects.toMatchObject({ code: 'TOOL_PART_REFERENCED' });
    expect(await binding.DB.prepare('SELECT count(*) AS n FROM pa_records WHERE owner_id=? AND deleted=0')
      .bind(f.session.ownerId).first()).toEqual({ n: 4 });
    previous = next;
  }
  expect(await binding.DB.prepare('SELECT part_id,source_revision FROM pa_tool_snapshot_references WHERE owner_id=? AND snapshot_id=?')
    .bind(f.session.ownerId, headID).first()).toEqual({ part_id: previous.snapshotID, source_revision: 21 });
  const other = await fixture();
  await expect(other.archive.put(other.session.token, crypto.randomUUID(), other.request({ photoBase64: null,
    document: await headDocument(previous) }))).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
}, 30_000);

it('reuses only exact authenticated v3 index proofs and still fences every live dependency',async()=>{
  const f=await fixture({quotaBytes:1_000_000});const a=await snapshot(f);
  await a.publish({...a.index,version:3});
  const reused={...a.index,version:3,snapshotID:crypto.randomUUID(),previousIndexID:a.id,
    files:a.index.files.map(file=>({...file,sourceSnapshotID:a.id}))};
  const request=async(index:typeof reused)=>{
    const payload=btoa(JSON.stringify(index));return f.request({photoBase64:null,document:{...document,
      formatVersion:3,photoFile:null,toolBackup:{snapshotId:index.snapshotID,kind:'index',path:'index.json',
        part:0,count:1,sha256:await sha256(atob(payload)),payload}}});
  };
  const keys={...f.options.keys,open:async(...args:Parameters<KeyCustody['open']>)=>{
    if ([a.photoID,a.jsonID].some(id=>args[1].recordId===id+'/document')) throw Error('unchanged piece must not be unwrapped');
    return f.options.keys.open(...args);
  }};
  expect(await new ArchiveStore({...f.options,keys}).put(f.session.token,reused.snapshotID,await request(reused)))
    .toEqual({recordId:reused.snapshotID,revision:1});
  const forged={...reused,snapshotID:crypto.randomUUID(),files:reused.files.map((file,i)=>i===0?{...file,sha256:'f'.repeat(64)}:file)};
  await expect(f.archive.put(f.session.token,forged.snapshotID,await request(forged))).rejects.toMatchObject({code:'INVALID_RECORD'});
  const other=await fixture();
  const foreign={...reused,snapshotID:crypto.randomUUID()};
  await expect(other.archive.put(other.session.token,foreign.snapshotID,await request(foreign)))
    .rejects.toMatchObject({code:'REVISION_CONFLICT'});
  // An absent hint is merely a missed optimization: immutable pieces must be
  // fully verified again, so old-server/device retries remain compatible.
  await f.archive.remove(f.session.token,a.id,1);
  const fallback={...reused,snapshotID:crypto.randomUUID()};
  expect(await f.archive.put(f.session.token,fallback.snapshotID,await request(fallback))).toMatchObject({revision:1});
  const racedIndex={...reused,snapshotID:crypto.randomUUID(),previousIndexID:reused.snapshotID};
  const raced=new ArchiveStore({...f.options,keys:{...f.options.keys,seal:async(value,context)=>{
    if(context.recordId===racedIndex.snapshotID+'/document') await binding.DB.prepare(
      'UPDATE pa_records SET revision=revision+1 WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,a.photoID).run();
    return f.options.keys.seal(value,context);
  }}});
  await expect(raced.put(f.session.token,racedIndex.snapshotID,await request(racedIndex))).rejects.toMatchObject({code:'REVISION_CONFLICT'});
});

it('retains server cleanup intent after an index and the sending device are lost', async () => {
  const f = await fixture(), other = await fixture();
  const a = await snapshot(f); await a.publish({ ...a.index, version: 3 });
  await f.archive.remove(f.session.token, a.id, 1);
  // A fresh device needs no old index or local GC receipt to find its parts.
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x => x.recordId).sort())
    .toEqual([a.jsonID, a.photoID].sort());
  expect(await other.archive.toolCleanupCandidates(other.session.token)).toEqual({ items: [], hasMore: false, nextCursor: null });
  for (const id of [a.jsonID, a.photoID]) await f.archive.remove(f.session.token, id, 1, true);
  expect(await f.archive.toolCleanupCandidates(f.session.token)).toEqual({ items: [], hasMore: false, nextCursor: null });
});

it('fences abandoned partial and complete transfers, including a late in-flight part', async () => {
  const f = await fixture();
  const a = await snapshot(f); await a.publish({ ...a.index, version: 3 });
  const headID = crypto.randomUUID(), indexHash = await sha256(JSON.stringify({ ...a.index, version: 3 }));
  await f.archive.put(f.session.token, headID, f.request({ photoBase64: null, document: { ...document,
    formatVersion: 1, photoFile: null, text: JSON.stringify({ kind: 'app-records-v1', snapshotID: a.id, indexHash }) } }));
  await expect(f.archive.abandonToolSnapshot(f.session.token, a.id)).rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  const pending = crypto.randomUUID();
  const raced = new ArchiveStore({ ...f.options, photos: { validateJPEG: async () => {
    await f.archive.abandonToolSnapshot(f.session.token, pending); return true;
  } } });
  const part = { snapshotId: pending, kind: 'photo', path: `CareHandoff/${crypto.randomUUID()}.jpg`, part: 0, count: 1,
    sha256: await sha256(photo), payload: '' };
  const id = crypto.randomUUID();
  await expect(raced.put(f.session.token, id, f.request({ document: { ...document, formatVersion: 3, toolBackup: part } })))
    .rejects.toMatchObject({ code: 'REVISION_CONFLICT' });
  expect(await binding.DB.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?')
    .bind(f.session.ownerId, id).first()).toBeNull();
  await expect(f.archive.put(f.session.token, id, f.request({ document: { ...document, formatVersion: 3, toolBackup: part } })))
    .rejects.toMatchObject({ code: 'TOOL_SNAPSHOT_ABANDONED' });
  const b = await snapshot(f); await b.publish({ ...b.index, version: 3 });
  await f.archive.abandonToolSnapshot(f.session.token, b.id);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items).toEqual([{ recordId: b.id, kind: 'index' }]);
  await f.archive.remove(f.session.token, b.id, 1);
  expect((await f.archive.toolCleanupCandidates(f.session.token)).items.map(x => x.recordId).sort()).toEqual([b.jsonID, b.photoID].sort());
}, 15_000);
