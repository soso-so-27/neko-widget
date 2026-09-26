import { expect, it } from 'vitest';
import { buildOwnerPurgeManifest } from '../src/owner-purge-manifest';
import { S3PurgeManifestStore } from '../src/s3-purge-manifest';
import type { PurgeFence } from '../src/owner-purge-fence';

it('writes and reconstructs one synthetic versioned deletion plan', async () => {
  const ownerId = process.env.NEKO_PROBE_OWNER_ID!;
  const intentId = process.env.NEKO_PROBE_RECORD_ID!;
  const region = process.env.NEKO_PROBE_AWS_REGION;
  const bucket = process.env.NEKO_PROBE_S3_BUCKET;
  const expectedAccountId = process.env.NEKO_PROBE_AWS_ACCOUNT_ID;
  const accessKeyId = process.env.NEKO_PROBE_AWS_ACCESS_KEY_ID;
  const secretAccessKey = process.env.NEKO_PROBE_AWS_SECRET_ACCESS_KEY;
  if (!ownerId || !intentId || !region || !bucket || !expectedAccountId
    || !accessKeyId || !secretAccessKey) {
    throw Error('Synthetic short-lived AWS credentials are required');
  }
  const store = new S3PurgeManifestStore({ enabled: 'YES', region, bucket,
    expectedAccountId, accessKeyId, secretAccessKey });
  const photoKey = `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
  const plan = await buildOwnerPurgeManifest({ ownerId, fenceId: intentId,
    ownerEpoch: 2, inventoryGeneration: 4 } as PurgeFence,
  { ownerId, epoch: 2, generation: 4, records: 1, photos: 1,
    photoKeys: [photoKey], recordDigest: 'a'.repeat(64) },
  { ownerId, r2Objects: [{ key: photoKey, version: 'synthetic-r2-v1', bytes: 8 }],
    r2Bytes: 8, s3Versions: [], s3VersionBytes: 0, s3DeleteMarkers: 0 });
  const chunk = await store.putChunk(plan, 0);
  expect(await store.putChunk(plan, 0)).toEqual(chunk);
  const header = await store.putHeader(plan);
  expect(await store.putHeader(plan)).toEqual(header);
  await store.verifyPublished(plan);
  expect(await store.loadPublished(ownerId, intentId, plan.sha256)).toEqual(plan);
  await expect(store.loadPublished(ownerId, intentId, 'f'.repeat(64)))
    .rejects.toMatchObject({ code: 'PURGE_MANIFEST_COPY_UNAVAILABLE' });
});
