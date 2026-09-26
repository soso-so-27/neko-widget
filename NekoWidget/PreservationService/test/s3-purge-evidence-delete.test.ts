import { expect, it } from 'vitest';
import { S3PurgeEvidenceDelete } from '../src/s3-purge-evidence-delete';

const owner = '00000000-0000-4000-8000-000000000001';
const intent = '00000000-0000-4000-8000-000000000002';
const config = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-evidence', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE',
  secretAccessKey: 'synthetic-secret-never-for-real-aws' };
const plan = { key: `purge-plan/v1/${owner}/${intent}/header`,
  versionId: 'plan-v1', deleteMarker: false, bytes: 100 };
const event = { key: `purge/v1/${owner}/${intent}/completed`,
  versionId: 'event-v1', deleteMarker: false, bytes: 100 };

it('signs only exact-version deletes in the requested evidence prefix', async () => {
  const seen: string[] = [];
  const purge = new S3PurgeEvidenceDelete(config, async (input, init) => {
    const url = new URL(String(input));
    const headers = new Headers(init?.headers);
    seen.push(url.pathname);
    expect(url.searchParams.has('versionId')).toBe(true);
    expect(init?.method).toBe('DELETE');
    expect(headers.get('x-amz-expected-bucket-owner')).toBe(config.expectedAccountId);
    expect(headers.get('authorization')).toContain('/ap-northeast-1/s3/aws4_request');
    return new Response(null, { status: 204,
      headers: { 'x-amz-version-id': url.searchParams.get('versionId')! } });
  });
  await purge.requestPlanVersionDeletion(owner, intent, plan);
  await purge.requestEventVersionDeletion(owner, intent, event);
  expect(seen).toEqual([`/${plan.key}`, `/${event.key}`]);
});

it('never accepts cross-intent, cross-prefix or key-only cleanup', async () => {
  expect(() => new S3PurgeEvidenceDelete({ ...config, enabled: 'NO' }))
    .toThrowError();
  let requests = 0;
  const purge = new S3PurgeEvidenceDelete(config, async () => {
    requests++; throw Error('must not request');
  });
  await expect(purge.requestPlanVersionDeletion(owner, crypto.randomUUID(), plan))
    .rejects.toMatchObject({ code: 'PURGE_EVIDENCE_DELETE_UNAVAILABLE' });
  await expect(purge.requestPlanVersionDeletion(owner, intent,
    { ...plan, versionId: '' })).rejects
    .toMatchObject({ code: 'PURGE_EVIDENCE_DELETE_UNAVAILABLE' });
  await expect(purge.requestEventVersionDeletion(owner, intent,
    { ...event, key: plan.key })).rejects
    .toMatchObject({ code: 'PURGE_EVIDENCE_DELETE_UNAVAILABLE' });
  await expect(purge.requestEventVersionDeletion(owner, intent,
    { ...event, versionId: 'null' })).rejects
    .toMatchObject({ code: 'PURGE_EVIDENCE_DELETE_UNAVAILABLE' });
  expect(requests).toBe(0);
});

it('does not treat a rejected or mismatched S3 response as deletion proof', async () => {
  const cases: [number, string][] = [[403, 'plan-v1'], [204, 'wrong']];
  for (const [status, returnedVersion] of cases) {
    const purge = new S3PurgeEvidenceDelete(config, async () =>
      new Response(null, { status,
        headers: { 'x-amz-version-id': returnedVersion } }));
    await expect(purge.requestPlanVersionDeletion(owner, intent, plan)).rejects
      .toMatchObject({ code: 'PURGE_EVIDENCE_DELETE_UNAVAILABLE' });
  }
});
