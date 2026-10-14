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

