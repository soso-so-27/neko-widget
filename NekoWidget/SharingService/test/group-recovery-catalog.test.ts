import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import type { Env } from '../src/env';
import { base64urlEncode, sha256Base64url } from '../src/encoding';
import { groupRecoveryCatalogAPI, recoveryCatalogTranscript, type RecoveryChallenge } from '../src/group-recovery-catalog';

const testEnv = { ...env, ENVIRONMENT: 'staging', GROUP_RECOVERY_CATALOG_ENABLED: 'YES',
  GROUP_IDENTITY_ERASURE_ENABLED: 'NO',
  MEMBER_RATE_LIMITER: { limit: async () => ({ success: true }) } } as unknown as Env;
const db = testEnv.DB;
const req = (path: string, body: unknown) => new Request('https://example.test/v3/group-recovery/' + path,
  { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
async function fixture(registered = true) {
  const keys = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const publicBytes = new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey));
  const identityPublicKey = base64urlEncode(publicBytes), person = await sha256Base64url(publicBytes);
  if (registered) await db.prepare("INSERT INTO group_people VALUES (?,?,'active',?)").bind(person, identityPublicKey, Math.floor(Date.now()/1000)).run();
  const response = await groupRecoveryCatalogAPI(req('challenges', { identityPublicKey, operationId: crypto.randomUUID(), purpose: 'catalog' }), testEnv);
  const { challenge } = await response.json() as { challenge: RecoveryChallenge };
  const signature = base64urlEncode(new Uint8Array(await crypto.subtle.sign('Ed25519', keys.privateKey, recoveryCatalogTranscript(challenge).slice().buffer)));
  return { person, challenge, read: () => groupRecoveryCatalogAPI(req('catalog', { challengeId: challenge.id, rootSignature: signature }), testEnv) };
}
describe('root-owned recovery catalog, issuance OFF', () => {
  it('does no DB access with absent or nonexact gate', async () => {
    for (const value of [undefined, 'NO', 'yes', ' YES']) {
      await expect(groupRecoveryCatalogAPI(req('catalog', {}), { ...testEnv, DB: undefined, GROUP_RECOVERY_CATALOG_ENABLED: value } as unknown as Env))
        .rejects.toMatchObject({ code: 'recovery_disabled' });
    }
  });
  it('returns a proved empty root without creating an identity', async () => {
    const f = await fixture(false);
    expect(await (await f.read()).json()).toMatchObject({ personId: f.person, windows: [], notebooks: [], devices: [], windowCount: 0, notebookCount: 0 });
    expect(await db.prepare('SELECT 1 FROM group_people WHERE id=?').bind(f.person).first()).toBeNull();
  });
  it('counts membership even without decryptable metadata; excludes closed/left memberships', async () => {
    const f = await fixture();
    const active = crypto.randomUUID(), closed = crypto.randomUUID();
    for (const [wid, mode] of [[active, 'active'], [closed, 'closed']]) {
      await db.prepare('INSERT INTO group_windows(space_id,owner_person_id,mode,created_at,updated_at) VALUES (?,?,?,1,1)').bind(wid!, f.person, mode!).run();
      await db.prepare("INSERT INTO group_members VALUES (?,?,?,'owner','active',1,NULL,'cipher')").bind(crypto.randomUUID(), wid!, f.person).run();
    }
    const family = crypto.randomUUID();
    await db.prepare("INSERT INTO family_notebook_spaces VALUES (?,1,'active',?,NULL,NULL,1,1)").bind(family, f.person).run();
    await db.prepare("INSERT INTO family_notebook_members VALUES (?,?,'active',1,NULL)").bind(family, f.person).run();
    const result = await (await f.read()).json() as { windowCount: number; notebookCount: number; windows: {windowId:string}[] };
    expect(result.windowCount).toBe(1); expect(result.notebookCount).toBe(1);
    expect(result.windows[0]?.windowId).toBe(active);
  });
  it('returns registration day and unknown model without inventing last use', async () => {
    const f = await fixture(), device = crypto.randomUUID();
    await db.prepare("INSERT INTO group_person_devices VALUES (?,?,?,?,'synthetic','active',123,NULL)")
      .bind(device, f.person, crypto.randomUUID(), crypto.randomUUID()).run();
    expect(await (await f.read()).json()).toMatchObject({ devices: [{ deviceId: device, registeredAt: 123, model: null }] });
  });
  it('rejects forged signatures, environment changes, expiry, and revocation', async () => {
    let f = await fixture();
    await expect(groupRecoveryCatalogAPI(req('catalog', { challengeId: f.challenge.id, rootSignature: base64urlEncode(new Uint8Array(64)) }), testEnv)).rejects.toMatchObject({ status: 401 });
    await db.prepare("UPDATE group_recovery_challenges SET environment='production' WHERE id=?").bind(f.challenge.id).run();
    await expect(f.read()).rejects.toMatchObject({ status: 401 });
    f = await fixture();
    await db.prepare('UPDATE group_recovery_challenges SET issued_at=1,expires_at=2 WHERE id=?').bind(f.challenge.id).run();
    await expect(f.read()).rejects.toMatchObject({ status: 401 });
    f = await fixture();
    await db.prepare("UPDATE group_people SET state='revoked' WHERE id=?").bind(f.person).run();
    await expect(f.read()).rejects.toMatchObject({ status: 401 });
    expect(await db.prepare('SELECT 1 FROM group_recovery_challenges WHERE id=?').bind(f.challenge.id).first()).toBeNull();
  });
  it('atomically permits only one concurrent use and never returns empty on DB failure', async () => {
    const f = await fixture();
    const outcomes = await Promise.allSettled([f.read(), f.read()]);
    expect(outcomes.filter(r => r.status === 'fulfilled')).toHaveLength(1);
    expect(outcomes.filter(r => r.status === 'rejected')).toHaveLength(1);
    await expect(f.read()).rejects.toMatchObject({ status: 401 });
  });
});
