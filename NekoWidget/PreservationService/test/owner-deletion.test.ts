import { env } from 'cloudflare:workers';
import { describe, expect, it, vi } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken, sha256, type KeyCustody } from '../src/contracts';
import { OwnerDeletionJournal } from '../src/owner-deletion-journal';
import { OwnerDeletionExecutor, OwnerDeletionRequests } from '../src/owner-deletion';
import { inspectOwnerD1Residue } from '../src/owner-d1-residue';
import type { S3RecoveryCopy, RecoveryVersion } from '../src/s3-recovery-copy';
import { route } from '../src/index';
import { RecoveryWriteLease } from '../src/recovery-write-lease';
import { OwnerQuarantineRestore } from '../src/owner-quarantine-restore';

const { DB: db, ARCHIVE: bucket } = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const now = () => 100_000;
const keys: KeyCustody = {
  async seal(bytes) { return bytes.slice(); },
  async open(bytes) { return bytes.slice(); },
};

async function fixture(enabled = true) {
  await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=0 WHERE singleton=1').run();
  await bucket.put('__owner_deletion/v1/format.json', '{"version":1}');
  const journal = new OwnerDeletionJournal(bucket);
  const auth = new DurableAuth({ db, keys, identityIndexSecret: 'd'.repeat(64), now, ownerDeletion: journal });
  const identity = { issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: 'synthetic-only' };
  const session = await auth.establish(identity);
  const receipt = randomToken();
  const requests = new OwnerDeletionRequests({ db, journal, auth, now });
  const versions: RecoveryVersion[] = [];
  const recovery = { async listOwnerVersionsPage(ownerId: string) {
    return { versions: versions.filter(v => v.key.startsWith(`recovery/v1/${ownerId}/`)), nextCursor: null };
  } } as S3RecoveryCopy;
  const revokeRefreshToken = vi.fn(async (_token: string) => {});
  const deleteVersion = vi.fn(async (ownerId: string, item: RecoveryVersion) => {
    expect(item.key).toMatch(new RegExp(`^recovery/v1/${ownerId}/`));
    const index = versions.findIndex(v => v.key === item.key && v.versionId === item.versionId);
    if (index >= 0) versions.splice(index, 1);
  });
  const executor = new OwnerDeletionExecutor({ enabled, db, bucket, journal, now,
    recovery, keys, revokeRefreshToken, versionPurge: { requestExactVersionDeletion: deleteVersion } });
  return { journal, auth, identity, session, receipt, requests, versions, executor, revokeRefreshToken, deleteVersion };
}

async function finish(executor: OwnerDeletionExecutor, ownerId: string) {
  for (let attempt = 0; attempt < 60; attempt++) {
    if (await executor.step(ownerId) === 'completed') return;
  }
  throw new Error('deletion did not finish');
}

describe('explicit owner-requested deletion', () => {
  it('requires explicit confirmation and derives ownership from a session, not a submitted ID', async () => {
    const f = await fixture();
    const services = { auth: f.auth, ownerDeletion: f.requests } as Parameters<typeof route>[1];
    const request = (body: unknown) => new Request('https://local/v1/account-deletion', {
      method: 'POST', headers: { authorization: `Bearer ${f.session.token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    await expect(route(request({ confirmation: 'delete-service-account', receipt: f.receipt, ownerId: crypto.randomUUID() }), services))
      .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
    await expect(route(request({ receipt: f.receipt }), services)).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
    expect(await f.journal.request(f.session.ownerId)).toBeNull();
    const result = await route(request({ confirmation: 'delete-service-account', receipt: f.receipt }), services);
    expect(result.status).toBe(202);
    await expect(f.auth.requireSession(f.session.token)).rejects.toThrow();
    expect(await f.requests.status(f.session.ownerId, f.receipt)).toEqual({ state: 'processing' });
    await expect(f.requests.status(f.session.ownerId, randomToken())).rejects.toMatchObject({ code: 'OWNER_DELETION_NOT_FOUND' });
  });

  it('blocks old login/session state when a request survived a D1 rollback, before any deletion', async () => {
    const f = await fixture();
    await f.journal.prepare({ version: 1, ownerId: f.session.ownerId, requestId: crypto.randomUUID(),
      receiptHash: await sha256(f.receipt), ownerEpoch: 1, requestedAt: now() });
    // D1 is still the old active image, as in a lost response/rollback.
    await expect(f.auth.requireSession(f.session.token)).rejects.toMatchObject({ code: 'OWNER_DELETION_PENDING' });
    await expect(f.auth.establish(f.identity)).rejects.toMatchObject({ code: 'OWNER_DELETION_PENDING' });
    expect(f.revokeRefreshToken).not.toHaveBeenCalled();
    const write = vi.fn(async () => {});
    await expect(new RecoveryWriteLease(db, now, f.journal).withOwnerWrite(f.session.ownerId, write))
      .rejects.toMatchObject({ code: 'OWNER_DELETION_PENDING' });
    expect(write).not.toHaveBeenCalled();
    const restore = new OwnerQuarantineRestore({} as never, {} as never, db, bucket,
      {} as never, f.journal);
    await expect(restore.restore(f.session.ownerId, now())).rejects.toMatchObject({ code: 'OWNER_DELETION_PENDING' });
  });

  it('erases all cloud versions and D1 content, resumes after interruption, leaves the other owner intact', async () => {
    const f = await fixture();
    const other = await f.auth.establish({ ...f.identity, subject: crypto.randomUUID() });
    const photo = `personal/${f.session.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
    const otherPhoto = `personal/${other.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
    await bucket.put(photo, 'encrypted-photo');
    await bucket.put(otherPhoto, 'other-encrypted-photo');
    const key = `recovery/v1/${f.session.ownerId}/photo/${crypto.randomUUID()}`;
    f.versions.push({ key, versionId: 'old', deleteMarker: false, bytes: 4 },
      { key, versionId: 'current', deleteMarker: false, bytes: 8 },
      { key, versionId: 'marker', deleteMarker: true, bytes: null },
      { key: `recovery/v1/${other.ownerId}/photo/${crypto.randomUUID()}`, versionId: 'other', deleteMarker: false, bytes: 6 });
    await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
      .bind(f.session.ownerId, crypto.randomUUID(), now()).run();
    await db.prepare(`INSERT INTO pa_owner_recovery_versions(owner_id,generation,
      object_key,version_id,sha256,bytes,confirmed_at)
      SELECT owner_id,generation,'recovery/v1/'||owner_id||'/owner/'||?,
        'synthetic-snapshot',?,1,? FROM pa_owner_recovery_generations`)
      .bind(crypto.randomUUID(), 'a'.repeat(64), now()).run();
    await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=1 WHERE singleton=1').run();
    await f.requests.request(f.session.token, f.receipt);
    await f.executor.step(f.session.ownerId);
    expect(f.revokeRefreshToken).toHaveBeenCalledOnce();
    expect(await f.requests.status(f.session.ownerId, f.receipt)).toEqual({ state: 'processing' });
    // The same durable request restarts without a new login or new confirmation.
    await finish(f.executor, f.session.ownerId);
    expect(f.revokeRefreshToken).toHaveBeenCalledOnce();
    expect(f.deleteVersion).toHaveBeenCalledTimes(3);
    expect(await bucket.head(photo)).toBeNull();
    expect(await bucket.head(otherPhoto)).not.toBeNull();
    expect(f.versions).toHaveLength(1);
    expect(await f.auth.requireSession(other.token)).toMatchObject({ ownerId: other.ownerId });
    const residue = await inspectOwnerD1Residue(db, f.session.ownerId);
    expect(residue.contentTotal).toBe(0);
    expect(residue.purgeWorkTotal).toBe(0);
    expect(await f.requests.status(f.session.ownerId, f.receipt)).toEqual({ state: 'completed' });
    await expect(f.journal.assertNotRequested(f.session.ownerId)).rejects.toThrow();
  });

  it('retains credentials and cloud data when Apple revocation fails, then resumes', async () => {
    const f = await fixture();
    await f.requests.request(f.session.token, f.receipt);
    f.revokeRefreshToken.mockRejectedValueOnce(new Error('synthetic Apple outage'));
    await expect(f.executor.step(f.session.ownerId)).rejects.toThrow();
    expect(await db.prepare('SELECT 1 FROM pa_identity_credentials WHERE owner_id=?').bind(f.session.ownerId).first()).not.toBeNull();
    expect(f.deleteVersion).not.toHaveBeenCalled();
    expect(await f.requests.status(f.session.ownerId, f.receipt)).toEqual({ state: 'processing' });
    await finish(f.executor, f.session.ownerId);
  });

  it('does not discard an old uncertain write lease to make deletion finish', async () => {
    const f = await fixture();
    await db.prepare('INSERT INTO pa_recovery_write_leases(write_id,owner_id,started_at) VALUES(?,?,1)')
      .bind(crypto.randomUUID(), f.session.ownerId).run();
    await f.requests.request(f.session.token, f.receipt);
    expect(await f.executor.step(f.session.ownerId)).toBe('waiting');
    expect(f.revokeRefreshToken).not.toHaveBeenCalled();
    expect(f.deleteVersion).not.toHaveBeenCalled();
  });

  it('does not claim completion when a successful S3 DELETE leaves a listed version', async () => {
    const f = await fixture();
    f.versions.push({ key: `recovery/v1/${f.session.ownerId}/owner/${crypto.randomUUID()}`,
      versionId: 'still-present', bytes: 3, deleteMarker: false });
    f.deleteVersion.mockImplementation(async () => {});
    await f.requests.request(f.session.token, f.receipt);
    await f.executor.step(f.session.ownerId);
    await f.executor.step(f.session.ownerId);
    expect(await f.requests.status(f.session.ownerId, f.receipt)).toEqual({ state: 'processing' });
    expect(await db.prepare('SELECT 1 FROM pa_identity_credentials WHERE owner_id=?').bind(f.session.ownerId).first()).not.toBeNull();
  });

  it('fails closed if the external journal has been lost', async () => {
    const f = await fixture();
    await bucket.delete('__owner_deletion/v1/format.json');
    await expect(f.auth.requireSession(f.session.token)).rejects.toMatchObject({ code: 'OWNER_DELETION_UNAVAILABLE' });
    expect(f.deleteVersion).not.toHaveBeenCalled();
  });

  it('keeps the executor disabled without its explicit enable switch', async () => {
    const f = await fixture(false);
    await f.requests.request(f.session.token, f.receipt);
    await expect(f.executor.step(f.session.ownerId)).rejects.toMatchObject({ code: 'OWNER_DELETION_DISABLED' });
    expect(f.revokeRefreshToken).not.toHaveBeenCalled();
    expect(f.deleteVersion).not.toHaveBeenCalled();
  });

  it('stops on a newly appeared version rather than expanding the sealed deletion plan', async () => {
    const f = await fixture();
    await bucket.put(`personal/${f.session.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`, 'ciphertext');
    await f.requests.request(f.session.token, f.receipt);
    await f.executor.step(f.session.ownerId);
    f.versions.push({ key: `recovery/v1/${f.session.ownerId}/photo/${crypto.randomUUID()}`,
      versionId: 'unplanned', bytes: 1, deleteMarker: false });
    await expect(f.executor.step(f.session.ownerId)).rejects.toMatchObject({ code: 'OWNER_DELETION_UNAVAILABLE' });
    expect(f.deleteVersion).not.toHaveBeenCalled();
    expect(await f.requests.status(f.session.ownerId, f.receipt)).toEqual({ state: 'processing' });
  });
});
