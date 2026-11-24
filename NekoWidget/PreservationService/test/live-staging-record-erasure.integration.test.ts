import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { handleKeyWrapperRequest } from '../src/aws-kms-key-wrapper';
import { randomToken } from '../src/contracts';
import { identityIndexKey, indexedOwnerIdentity } from '../src/identity-index';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { boundKeyWrapper } from '../src/providers';
import worker from '../src/record-deletion-worker';
import { RecordRecoveryCopy } from '../src/record-recovery-copy';
import { S3RecoveryCopy, type RecoveryVersion } from '../src/s3-recovery-copy';
import { ArchiveStore } from '../src/storage';

type Bindings = {
  DB: D1Database;
  ARCHIVE: R2Bucket;
  NEKO_PROBE_OWNER_ID: string;
  NEKO_PROBE_AWS_ACCESS_KEY_ID: string;
  NEKO_PROBE_AWS_SECRET_ACCESS_KEY: string;
  NEKO_PROBE_ERASER_KEY_ID: string;
  NEKO_PROBE_ERASER_SECRET: string;
};
const bindings = env as unknown as Bindings;
const region = 'ap-northeast-1';
const account = '164892691568';
const bucket = 'neko-preservation-staging-recovery-164892691568';
const keyArn = 'arn:aws:kms:ap-northeast-1:164892691568:key/339319dc-388b-4bd7-adb8-29d37d836d72';
const photo = '/9j/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAIDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AAA//2Q==';
const fillerCount = 2500;

it.runIf(!!bindings.NEKO_PROBE_ERASER_KEY_ID)('erases one staging record among more than 2500 owner versions', async () => {
  const ownerId = bindings.NEKO_PROBE_OWNER_ID;
  expect(ownerId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  const credentials = {
    accessKeyId: bindings.NEKO_PROBE_AWS_ACCESS_KEY_ID,
    secretAccessKey: bindings.NEKO_PROBE_AWS_SECRET_ACCESS_KEY,
  };
  const s3 = new S3RecoveryCopy({ enabled: 'YES', region, bucket, expectedAccountId: account, ...credentials });
  const ownerVersions = async () => {
    const refs: RecoveryVersion[] = [];
    let cursor;
    do {
      const page = await s3.listOwnerVersionsPage(ownerId, cursor);
      refs.push(...page.versions);
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    return refs;
  };
  expect(await ownerVersions()).toHaveLength(0);

  const r2Prefix = 'personal/' + ownerId + '/';
  expect((await bindings.ARCHIVE.list({ prefix: r2Prefix, limit: 1 })).objects).toHaveLength(0);
  try {
    const indexSecret = randomToken();
    const callerSecret = randomToken();
    const kms = { PRESERVATION_KMS_ENABLED: 'YES', KMS_REGION: region, KMS_KEY_ARN: keyArn,
      KMS_ACCESS_KEY_ID: credentials.accessKeyId, KMS_SECRET_ACCESS_KEY: credentials.secretAccessKey,
      KEY_WRAPPER_CALLER_SECRET: callerSecret,
    };
    const wrapper = { fetch: (input: RequestInfo | URL, init?: RequestInit) =>
      handleKeyWrapperRequest(new Request(input, init), kms) } as Fetcher;
    const keys = envelopeKeyCustody({ enabled: true, wrapper: boundKeyWrapper(wrapper, callerSecret) });
    const owners = new OwnerRecoveryCopy(keys, s3, indexSecret);
    const records = new RecordRecoveryCopy(keys, s3);
    const issuer = 'https://appleid.apple.com';
    const subject = 'synthetic-' + ownerId;
    const identity = await indexedOwnerIdentity(await identityIndexKey(indexSecret), issuer, subject);
    const db = bindings.DB;
    await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,created_at) VALUES(?,?,0,0,?)')
      .bind(ownerId, identity, Date.now()).run();
    const auth = new DurableAuth({ db, keys, identityIndexSecret: indexSecret, now: Date.now,
      ownerRecovery: owners, requireOwnerRecovery: true });
    const session = await auth.establish({ issuer, subject, refreshToken: randomToken() });
    expect(session.ownerId).toBe(ownerId);
    await db.prepare('UPDATE pa_recovery_write_policy SET delete_intent_required=1,owner_snapshot_required=1 WHERE singleton=1').run();
    const store = new ArchiveStore({ db, bucket: bindings.ARCHIVE, keys, auth, now: Date.now,
      quotaBytes: 1_000_000, maximumRecords: 5, membership: { status: async () => 'active' },
      photos: { validateJPEG: async () => true }, recovery: records, ownerRecovery: owners,
      requireRecovery: true, requireOwnerRecovery: true });
    const deleted = crypto.randomUUID(), kept = crypto.randomUUID();
    const document = { formatVersion: 1 as const, text: 'synthetic record', capturedAt: null,
      writtenAt: null, updatedAt: null, catNames: [], photoFile: 'photo.jpg' as const };
    for (const id of [deleted, kept]) {
      expect(await store.put(session.token, id, {
        expectedRevision: null, consentVersion: 'managed-preservation-v1', document, photoBase64: photo,
      })).toEqual({ recordId: id, revision: 1 });
    }
    const target = await db.prepare('SELECT record_object_key,record_version_id,photo_object_key,photo_version_id '
      + 'FROM pa_record_recovery_versions WHERE owner_id=? AND record_id=? AND revision=1')
      .bind(ownerId, deleted).first<{ record_object_key: string; record_version_id: string;
        photo_object_key: string; photo_version_id: string }>();
    expect(target?.record_version_id).toBeTruthy();
    expect(target?.photo_version_id).toBeTruthy();
    expect(await store.remove(session.token, deleted, 1)).toEqual({ recordId: deleted, revision: 2 });

    const opaque = new TextEncoder().encode('synthetic unrelated staging payload');
    // Seed unrelated objects in the same owner prefix, outside either target key.
    for (let offset = 0; offset < fillerCount; offset += 6) {
      await Promise.all(Array.from({length: Math.min(6, fillerCount - offset)}, (_, index) => {
        const kind = (index + offset) % 2 === 0 ? 'record' : 'photo';
        return s3.putVersioned('recovery/v1/' + ownerId + '/' + kind + '/' + crypto.randomUUID(), opaque);
      }));
    }
    const before = await ownerVersions();
    expect(before.length).toBeGreaterThanOrEqual(fillerCount + 2);
    const identityOf = (row: RecoveryVersion) => JSON.stringify([row.key, row.versionId, row.bytes, row.deleteMarker]);
    const targets = before.filter(item => (item.key === target!.record_object_key && item.versionId === target!.record_version_id)
      || (item.key === target!.photo_object_key && item.versionId === target!.photo_version_id));
    expect(targets).toHaveLength(2);

    const workerEnv = {
      DB: db, ARCHIVE: bindings.ARCHIVE, KEY_WRAPPER: wrapper, KEY_WRAPPER_CALLER_SECRET: callerSecret,
      IDENTITY_INDEX_SECRET: indexSecret, RECORD_PHYSICAL_DELETION_ENABLED: 'YES',
      RECOVERY_COPY_ENABLED: 'YES', RECOVERY_S3_REGION: region, RECOVERY_S3_BUCKET: bucket,
      RECOVERY_S3_ACCOUNT_ID: account, RECOVERY_S3_ACCESS_KEY_ID: credentials.accessKeyId,
      RECOVERY_S3_SECRET_ACCESS_KEY: credentials.secretAccessKey,
      ERASER_S3_ACCESS_KEY_ID: bindings.NEKO_PROBE_ERASER_KEY_ID,
      ERASER_S3_SECRET_ACCESS_KEY: bindings.NEKO_PROBE_ERASER_SECRET,
    };
    const durationsMs: number[] = [];
    const queued = async () => db.prepare('SELECT count(*) FROM pa_record_physical_delete_queue WHERE owner_id=? AND record_id=?')
      .bind(ownerId, deleted).first<number>('count(*)');
    for (let run = 0; run < 3 && await queued(); run++) {
      if (run) await db.prepare('UPDATE pa_record_physical_delete_queue SET next_attempt_at=0 WHERE owner_id=? AND record_id=?')
        .bind(ownerId, deleted).run();
      const start = performance.now();
      await worker.scheduled({ scheduledTime: Date.now(), cron: '*/5 * * * *' } as ScheduledEvent, workerEnv);
      durationsMs.push(Math.round(performance.now() - start));
    }
    expect(await queued()).toBe(0);
    expect(Math.max(...durationsMs)).toBeLessThan(60_000);
    const after = await ownerVersions();
    const deletedSet = new Set(targets.map(identityOf));
    expect(new Set(after.map(identityOf))).toEqual(new Set(before.map(identityOf).filter(ref => !deletedSet.has(ref))));
    expect((await bindings.ARCHIVE.list({ prefix: 'personal/' + ownerId + '/' + deleted + '/' })).objects).toHaveLength(0);
    expect(await store.read(session.token, kept)).toMatchObject({ document, photoBase64: photo });
    console.log(JSON.stringify({ ownerVersionsBefore: before.length, ownerVersionsAfter: after.length,
      targetVersionsRemoved: targets.length, durationsMs }));
  } finally {
    const leftovers = await bindings.ARCHIVE.list({ prefix: r2Prefix, limit: 4 });
    if (leftovers.truncated || leftovers.objects.some(item => !item.key.startsWith(r2Prefix))) {
      throw new Error('Unverified synthetic R2 cleanup scope');
    }
    for (const item of leftovers.objects) await bindings.ARCHIVE.delete(item.key);
    expect((await bindings.ARCHIVE.list({ prefix: r2Prefix, limit: 1 })).objects).toHaveLength(0);
  }
}, 360_000);
