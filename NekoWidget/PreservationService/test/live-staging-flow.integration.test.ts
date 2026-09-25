import { env } from 'cloudflare:workers';
import { applyD1Migrations, type D1Migration } from 'cloudflare:test';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken } from '../src/contracts';
import { indexedOwnerIdentity, identityIndexKey } from '../src/identity-index';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerArchiveRecovery } from '../src/owner-archive-recovery';
import { OwnerQuarantineRestore } from '../src/owner-quarantine-restore';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { boundKeyWrapper } from '../src/providers';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import { S3RecoveryCopy } from '../src/s3-recovery-copy';
import { ArchiveStore } from '../src/storage';
import { handleKeyWrapperRequest } from '../src/aws-kms-key-wrapper';

type Bindings = { DB: D1Database; ARCHIVE: R2Bucket;
  RESTORE_DB: D1Database; TEST_MIGRATIONS: D1Migration[];
  NEKO_PROBE_OWNER_ID: string;
  NEKO_PROBE_AWS_ACCESS_KEY_ID: string; NEKO_PROBE_AWS_SECRET_ACCESS_KEY: string };
const bindings = env as unknown as Bindings;
const region = 'ap-northeast-1';
const account = '164892691568';
const bucket = 'neko-preservation-staging-recovery-164892691568';
const keyArn = 'arn:aws:kms:ap-northeast-1:164892691568:key/339319dc-388b-4bd7-adb8-29d37d836d72';
const callerSecret = 's'.repeat(43);
const photo = '/9j/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAIDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AAA//2Q==';

it('binds a local D1 and the real staging R2 without writing either', async () => {
  expect((await bindings.DB.prepare('SELECT 1 AS ready').first<{ ready: number }>())?.ready).toBe(1);
  const listed = await bindings.ARCHIVE.list({ prefix: 'probes/', limit: 1 });
  expect(listed.objects).toHaveLength(0);
  expect(listed.truncated).toBe(false);
});

it('saves a synthetic photo and stages its S3 recovery in offline quarantine', async () => {
  const ownerId = bindings.NEKO_PROBE_OWNER_ID;
  expect(ownerId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u);
  expect(bindings.NEKO_PROBE_AWS_ACCESS_KEY_ID).toBeTruthy();
  expect(bindings.NEKO_PROBE_AWS_SECRET_ACCESS_KEY).toBeTruthy();
  const indexSecret = randomToken();
  const subject = `synthetic-${ownerId}`;
  const issuer = 'https://appleid.apple.com';
  const indexKey = await identityIndexKey(indexSecret);
  const identityKey = await indexedOwnerIdentity(indexKey, issuer, subject);
  const now = Date.now();
  const kmsEnv = { PRESERVATION_KMS_ENABLED: 'YES', KMS_REGION: region, KMS_KEY_ARN: keyArn,
    KMS_ACCESS_KEY_ID: bindings.NEKO_PROBE_AWS_ACCESS_KEY_ID,
    KMS_SECRET_ACCESS_KEY: bindings.NEKO_PROBE_AWS_SECRET_ACCESS_KEY,
    KEY_WRAPPER_CALLER_SECRET: callerSecret };
  const privateBinding = { fetch: (input: RequestInfo | URL, init?: RequestInit) =>
    handleKeyWrapperRequest(new Request(input, init), kmsEnv) } as Fetcher;
  const keys = envelopeKeyCustody({ enabled: true, wrapper: boundKeyWrapper(privateBinding, callerSecret) });
  const s3 = new S3RecoveryCopy({ enabled: 'YES', region, bucket, expectedAccountId: account,
    accessKeyId: bindings.NEKO_PROBE_AWS_ACCESS_KEY_ID,
    secretAccessKey: bindings.NEKO_PROBE_AWS_SECRET_ACCESS_KEY });
  const ownerRecovery = new OwnerRecoveryCopy(keys, s3, indexSecret);
  const recordRecovery = new RecordRecoveryCopy(keys, s3);
  try {
    await bindings.DB.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,created_at)
      VALUES(?,?,0,0,?)`).bind(ownerId, identityKey, now).run();
    const auth = new DurableAuth({ db: bindings.DB, keys, identityIndexSecret: indexSecret,
      now: () => now, ownerRecovery, requireOwnerRecovery: true });
    const session = await auth.establish({ issuer, subject, refreshToken: randomToken() });
    expect(session.ownerId).toBe(ownerId);
    await bindings.DB.prepare(`UPDATE pa_recovery_write_policy SET
      delete_intent_required=1,owner_snapshot_required=1 WHERE singleton=1`).run();
    const archive = new ArchiveStore({ db: bindings.DB, bucket: bindings.ARCHIVE, keys,
      auth, now: () => now, quotaBytes: 1_000_000, maximumRecords: 10,
      membership: { status: async () => 'active' }, photos: { validateJPEG: async () => true },
      recovery: recordRecovery, ownerRecovery, requireRecovery: true, requireOwnerRecovery: true });
    const recordId = crypto.randomUUID();
    const document = { formatVersion: 1 as const, text: '合成の猫写真', capturedAt: null,
      writtenAt: null, updatedAt: null, catNames: [], photoFile: 'photo.jpg' as const };
    expect(await archive.put(session.token, recordId, {
      expectedRevision: null, consentVersion: 'managed-preservation-v1', document,
      photoBase64: photo,
    })).toEqual({ recordId, revision: 1 });
    const read = await archive.read(session.token, recordId);
    expect(read.document).toEqual(document);
    expect(read.photoBase64).toBe(photo);
    const candidate = await new OwnerArchiveRecovery(s3, ownerRecovery, recordRecovery)
      .assembleQuarantineCandidate(ownerId, now + 1);
    expect(candidate.status).toBe('ready-for-quarantine');
    if (candidate.status !== 'ready-for-quarantine') throw new Error('owner not recoverable');
    expect(candidate.verifiedRecords).toBe(1);
    expect(candidate.owner.records[0]).toMatchObject({ recordId, revision: 1, deleted: false });
    const originalRow = await bindings.DB.prepare(`SELECT photo_key FROM pa_records
      WHERE owner_id=? AND record_id=?`).bind(ownerId, recordId)
      .first<{ photo_key: string }>();
    const photoKey = originalRow?.photo_key;
    expect(photoKey).toBeTruthy();
    const originalPhoto = await bindings.ARCHIVE.get(photoKey!);
    expect(originalPhoto).not.toBeNull();
    const originalCiphertext = new Uint8Array(await originalPhoto!.arrayBuffer());
    await bindings.ARCHIVE.delete(photoKey!);
    expect(await bindings.ARCHIVE.head(photoKey!)).toBeNull();
    await applyD1Migrations(bindings.RESTORE_DB, bindings.TEST_MIGRATIONS);
    const staged = await new OwnerQuarantineRestore(
      new OwnerArchiveRecovery(s3, ownerRecovery, recordRecovery), recordRecovery,
      bindings.RESTORE_DB, bindings.ARCHIVE).restore(ownerId, now + 2);
    expect(staged).toEqual({ status: 'staged-disabled', ownerId, records: 1, photos: 1 });
    const restored = await bindings.RESTORE_DB.prepare(`SELECT o.disabled,r.photo_key
      FROM pa_owners o JOIN pa_records r ON r.owner_id=o.owner_id
      WHERE o.owner_id=? AND r.record_id=?`).bind(ownerId, recordId)
      .first<{ disabled: number; photo_key: string }>();
    expect(restored?.disabled).toBe(1);
    expect(restored?.photo_key).toBe(photoKey);
    const restoredPhoto = await bindings.ARCHIVE.get(restored!.photo_key);
    expect(restoredPhoto).not.toBeNull();
    expect(new Uint8Array(await restoredPhoto!.arrayBuffer())).toEqual(originalCiphertext);
  } finally {
    let cursor: string | undefined;
    do {
      const listed = await bindings.ARCHIVE.list({ prefix: `personal/${ownerId}/`, limit: 1000,
        ...(cursor ? { cursor } : {}) });
      for (const object of listed.objects) await bindings.ARCHIVE.delete(object.key);
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
    const remaining = await bindings.ARCHIVE.list({ prefix: `personal/${ownerId}/`, limit: 1 });
    expect(remaining.objects).toHaveLength(0);
  }
});
