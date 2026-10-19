import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken, sha256 } from '../src/contracts';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { RetentionLedger } from '../src/retention-ledger';
import type { RecoveryObject, S3RecoveryCopy } from '../src/s3-recovery-copy';
import { syntheticKeyAuthority } from './key-fixture';

const db = (env as unknown as { DB: D1Database }).DB;

it('keeps real encrypted owner history while fresh scheduled ACKs verify it and reject key revocation', async () => {
  let now = Date.UTC(2026, 9, 19);
  const authority = await syntheticKeyAuthority(), wrapper = authority.make();
  let opens = 0, wraps = 0;
  const keys = envelopeKeyCustody({ enabled: true, wrapper: {
    wrap: async (...args) => { wraps++; return wrapper.wrap(...args); },
    unwrap: async (...args) => { opens++; return wrapper.unwrap(...args); },
  } });
  const secret = randomToken(), objects = new Map<string, Uint8Array>();
  let puts = 0, gets = 0;
  const s3 = {
    async putVersioned(key: string, value: Uint8Array): Promise<RecoveryObject> {
      puts++; objects.set(key, value.slice());
      return { key, versionId: 'synthetic-v1', sha256: await sha256(value), bytes: value.length };
    },
    async getVerified(ref: RecoveryObject) {
      gets++; const value = objects.get(ref.key);
      if (!value || ref.versionId !== 'synthetic-v1' || value.length !== ref.bytes || await sha256(value) !== ref.sha256) throw Error('bad exact version');
      return value.slice();
    },
  } as S3RecoveryCopy;
  const copy = new OwnerRecoveryCopy(keys, s3, secret, { pagedWrites: true, compressWrites: true });
  const auth = new DurableAuth({ db, keys, identityIndexSecret: secret, now: () => now });
  const session = await auth.establish({ issuer: 'https://appleid.apple.com', subject: crypto.randomUUID(), refreshToken: randomToken() });
  const owner = session.ownerId, billing = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(owner).run();
  await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)').bind(owner, billing, now).run();
  const ledger = new RetentionLedger(db, () => now, copy);
  await ledger.observe(owner, 'active');
  const versions = () => db.prepare('SELECT generation,object_key,version_id,sha256,bytes FROM pa_owner_recovery_versions WHERE owner_id=? ORDER BY generation').bind(owner).all<{
    generation: number; object_key: string; version_id: string; sha256: string; bytes: number;
  }>();
  const before = (await versions()).results, oldBytes = new Map(objects);
  const counts = { puts, gets, opens, wraps }; let checks = 0;
  for (const elapsed of [3_600_001, 3_600_001, 86_400_000]) {
    now += elapsed;
    expect(await ledger.refreshBatch(async id => { expect(id).toBe(billing); checks++; return 'active'; })).toBe(1);
    expect((await versions()).results).toEqual(before);
    expect(puts).toBe(counts.puts); expect(wraps).toBe(counts.wraps);
  }
  expect(checks).toBe(3); expect(opens).toBeGreaterThan(counts.opens); expect(gets).toBeGreaterThan(counts.gets);
  for (const [key, value] of oldBytes) expect(objects.get(key)).toEqual(value);
  const old = before.at(-1)!;
  expect((await copy.read(owner, { key: old.object_key, versionId: old.version_id, sha256: old.sha256, bytes: old.bytes })).retention?.status).toBe('active');
  // A real change still needs its independently encrypted new owner header.
  now++;
  await ledger.refreshBatch(async () => 'grace');
  expect((await versions()).results).toHaveLength(before.length + 1);
  expect(puts).toBeGreaterThan(counts.puts);
  const changedPuts = puts;
  authority.remove('synthetic/v1'); now += 3_600_001;
  await expect(ledger.refreshBatch(async () => 'grace')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
  expect(puts).toBe(changedPuts);
  for (const [key, value] of oldBytes) expect(objects.get(key)).toEqual(value);
});
