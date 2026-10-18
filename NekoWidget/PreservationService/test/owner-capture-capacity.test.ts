import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { randomToken, sha256 } from '../src/contracts';
import { DurableAuth } from '../src/auth';
import { envelopeKeyCustody } from '../src/key-custody';
import { syntheticKeyAuthority } from './key-fixture';
import type { RecoveryObject, S3RecoveryCopy } from '../src/s3-recovery-copy';

const db = (env as unknown as { DB: D1Database }).DB;
// capture reads only local D1. No key authority, S3 or real account is used.
const copy = () => new OwnerRecoveryCopy(null as never, null as never, randomToken());

async function history(count: number) {
  const owner = crypto.randomUUID();
  await db.batch([
    db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,100)')
      .bind(owner, crypto.randomUUID().replaceAll('-', '').repeat(2)),
    db.prepare(`INSERT INTO pa_identity_credentials(owner_id,owner_epoch,sealed_credentials,updated_at)
      VALUES(?,0,X'4e4b4d3101',100)`).bind(owner),
    db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(owner),
    db.prepare(`WITH RECURSIVE ids(n) AS (SELECT 1 WHERE ?>0 UNION ALL SELECT n+1 FROM ids WHERE n<?)
      INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,deleted)
      SELECT ?,printf('00000000-0000-4000-8000-%012x',n),1,'synthetic','synthetic',1 FROM ids`)
      .bind(count, count, owner),
    db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,
      record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
      SELECT owner_id,record_id,1,'recovery/v1/'||owner_id||'/record/'||record_id,
        'synthetic-version',?,100,100 FROM pa_records WHERE owner_id=?`).bind('e'.repeat(64), owner),
    db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,
      marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
      SELECT owner_id,record_id,1,'recovery/v1/'||owner_id||'/manifest/'||record_id,
        'synthetic-version',?,100,100 FROM pa_records WHERE owner_id=?`).bind('f'.repeat(64), owner),
  ]);
  return owner;
}

it('captures long-lived history without putting the entire inventory into one D1 value', async () => {
  const owner = await history(12_000);
  const captured = await copy().capture(db, owner);
  expect(captured.records).toHaveLength(12_000);
  expect(captured.inventoryGeneration).toBe(12_000);
  expect(captured.records.every(record => record.deleted)).toBe(true);
  expect(captured.records[0]!.recordId).toBe('00000000-0000-4000-8000-000000000001');
  expect(captured.records.at(-1)!.recordId).toBe('00000000-0000-4000-8000-000000002ee0');
}, 30_000);

it.each([0, 255, 256, 257])('captures %i records including an empty inventory and exact page boundaries', async count => {
  const owner = await history(count);
  if (count === 0) await db.prepare('DELETE FROM pa_inventory WHERE owner_id=?').bind(owner).run();
  expect((await copy().capture(db, owner)).records).toHaveLength(count);
});

// Preserve the real SQL and migrations, interleaving the competing operation
// after a page has been read. This exercises separate D1 transactions.
function afterPage(action: (page: D1Result<Record<string, unknown>>) => Promise<void>): D1Database {
  let applied = false;
  return new Proxy(db, { get(target, key) {
    if (key !== 'prepare') return Reflect.get(target, key);
    return (sql: string) => {
      const wrap = (statement: D1PreparedStatement): D1PreparedStatement => new Proxy(statement, { get(stmt, method) {
        if (method === 'bind') return (...args: unknown[]) => wrap(stmt.bind(...args));
        if (method === 'all' && sql.includes('ORDER BY items.record_id')) return async () => {
          const page = await stmt.all<Record<string, unknown>>();
          if (!applied) { applied = true; await action(page); }
          return page;
        };
        const value = Reflect.get(stmt, method);
        return typeof value === 'function' ? value.bind(stmt) : value;
      } });
      return wrap(target.prepare(sql));
    };
  } });
}

it('rejects an inventory change before its commit marker advances owner generation', async () => {
  const owner = await history(257);
  const before = await db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?').bind(owner).first();
  const racing = afterPage(async () => {
    await db.prepare('UPDATE pa_records SET initial_fingerprint=? WHERE owner_id=? AND record_id=?')
      .bind('concurrent', owner, '00000000-0000-4000-8000-000000000001').run();
  });
  await expect(copy().capture(racing, owner)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  expect(await db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?').bind(owner).first()).toEqual(before);
});

it('rejects owner state changes after the last nonempty page', async () => {
  const owner = await history(255);
  const racing = afterPage(async () => {
    await db.prepare('UPDATE pa_owners SET epoch=epoch+1,disabled=1 WHERE owner_id=?').bind(owner).run();
  });
  await expect(copy().capture(racing, owner)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
});

it.each(['missing', 'duplicate', 'reversed'] as const)('rejects a %s page rather than acknowledging a partial inventory', async fault => {
  const owner = await history(257);
  const faulty = afterPage(async page => {
    if (fault === 'missing') page.results.pop();
    if (fault === 'duplicate') page.results[1] = page.results[0]!;
    if (fault === 'reversed') page.results.reverse();
  });
  await expect(copy().capture(faulty, owner)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
});

it('rejects an existing record without a marker for its current revision', async () => {
  const owner = await history(257);
  await db.prepare('UPDATE pa_records SET revision=2 WHERE owner_id=? AND record_id=?')
    .bind(owner, '00000000-0000-4000-8000-000000000101').run();
  await expect(copy().capture(db, owner)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
});

it('rejects a commit marker arriving between pages even without another inventory change', async () => {
  const owner = await history(257), record = '00000000-0000-4000-8000-000000000101';
  await db.prepare('UPDATE pa_records SET revision=2 WHERE owner_id=? AND record_id=?').bind(owner, record).run();
  await db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,
    record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
    VALUES(?,?,2,?,'synthetic-version',?,100,100)`)
    .bind(owner, record, `recovery/v1/${owner}/record/${crypto.randomUUID()}`, 'e'.repeat(64)).run();
  const inventory = await db.prepare('SELECT generation FROM pa_inventory WHERE owner_id=?').bind(owner).first();
  const racing = afterPage(async () => {
    await db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,
      marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
      VALUES(?,?,2,?,'synthetic-version',?,100,100)`)
      .bind(owner, record, `recovery/v1/${owner}/manifest/${crypto.randomUUID()}`, 'f'.repeat(64)).run();
  });
  await expect(copy().capture(racing, owner)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  expect(await db.prepare('SELECT generation FROM pa_inventory WHERE owner_id=?').bind(owner).first()).toEqual(inventory);
});

it('captures the existing maximum history and rejects an oversized history before paging it', async () => {
  const owner = await history(100_000);
  expect((await copy().capture(db, owner)).records).toHaveLength(100_000);
  await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,deleted)
    VALUES(?,?,1,'synthetic','synthetic',1)`).bind(owner, crypto.randomUUID()).run();
  let readPage = false;
  await expect(copy().capture(afterPage(async () => { readPage = true; }), owner))
    .rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
  expect(readPage).toBe(false);
}, 60_000);

it.each(['new-copy', 'existing-copy', 'before-insert'] as const)(
  'does not acknowledge %s if inventory changes before a record commit marker arrives', async timing => {
    const keys = envelopeKeyCustody({ enabled: true, wrapper: (await syntheticKeyAuthority()).bridge() });
    const objects = new Map<string, Uint8Array>();
    const s3 = {
      async putVersioned(key: string, bytes: Uint8Array) {
        objects.set(key, bytes.slice());
        return { key, versionId: 'synthetic-v1', sha256: await sha256(bytes), bytes: bytes.length };
      },
      async getVerified(ref: RecoveryObject) {
        const bytes = objects.get(ref.key)!;
        expect(ref.versionId).toBe('synthetic-v1');
        expect(bytes.length).toBe(ref.bytes);
        expect(await sha256(bytes)).toBe(ref.sha256);
        return bytes.slice();
      },
    } as S3RecoveryCopy;
    const identityIndexSecret = randomToken();
    const recovery = new OwnerRecoveryCopy(keys, s3, identityIndexSecret, { compressWrites: true, pagedWrites: true });
    const now = 1_790_035_200_000;
    const auth = new DurableAuth({ db, keys, identityIndexSecret, now: () => now });
    const session = await auth.establish({ issuer: 'https://appleid.apple.com',
      subject: crypto.randomUUID(), refreshToken: randomToken() });
    await db.prepare('INSERT OR IGNORE INTO pa_inventory(owner_id) VALUES(?)').bind(session.ownerId).run();
    if (timing === 'existing-copy') await recovery.copyCurrent(db, session.ownerId, now);
    const initial = await recovery.capture(db, session.ownerId);
    const mutate = async () => {
      await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
        initial_operation,metadata,deleted) VALUES(?,?,1,?,?,NULL,1)`)
        .bind(session.ownerId, crypto.randomUUID(), 'd'.repeat(64), crypto.randomUUID()).run();
    };
    if (timing === 'before-insert') {
      const original = recovery.copy.bind(recovery);
      recovery.copy = async (...args) => { const ref = await original(...args); await mutate(); return ref; };
    } else {
      const original = recovery.read.bind(recovery);
      recovery.read = async (...args) => { const value = await original(...args); await mutate(); return value; };
    }
    await expect(recovery.copyCurrent(db, session.ownerId, now)).rejects.toMatchObject({ code: 'OWNER_RECOVERY_UNAVAILABLE' });
    const generations = await db.prepare(`SELECT g.generation,i.generation AS inventory_generation
      FROM pa_owner_recovery_generations g JOIN pa_inventory i ON i.owner_id=g.owner_id WHERE g.owner_id=?`)
      .bind(session.ownerId).first<{ generation: number; inventory_generation: number }>();
    expect(generations?.generation).toBe(initial.generation);
    expect(generations?.inventory_generation).toBe(initial.inventoryGeneration + 1);
    if (timing === 'before-insert') {
      expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_recovery_versions WHERE owner_id=?')
        .bind(session.ownerId).first('n')).toBe(0);
    }
  });
