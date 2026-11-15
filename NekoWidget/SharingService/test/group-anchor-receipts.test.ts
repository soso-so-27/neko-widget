import { describe, expect, it } from 'vitest';
import { anchorReceiptTranscript } from '../src/group-anchor-receipts';
import { plusOwner } from './group-billing-fixture';
import { create, db, person, sign, signed, send, testEnv, key } from './group-fixture';
import { base64urlDecode, randomBase64url, sha256Base64url } from '../src/encoding';

const settings = { ...testEnv, ENVIRONMENT: 'staging', GROUP_RECOVERY_CATALOG_ENABLED: 'NO',
  MEMBER_RATE_LIMITER: { limit: async () => ({ success: true }) } };
async function fixture() {
  const p = await plusOwner(), w = await create(p);
  const input = { environment: 'staging', personId: p.id, ownerPersonId: p.id,
    ownerPublicKey: p.identity.publicKey, rootSignature: await sign(p.identity.privateKey,
      anchorReceiptTranscript('staging', p.id, w.windowId, p.id, p.identity.publicKey)) };
  const path = `/v3/group-windows/${w.windowId}/anchor-receipt`;
  return { p, w, input, path, put: async (body = input) => send(await signed(p, path, body), settings) };
}
describe('personal root-signed trust anchor receipts', () => {
  it('stores one immutable receipt with recovery OFF and retries without duplicate rows', async () => {
    const f = await fixture();
    for (let i = 0; i < 2; i++) expect((await f.put()).data).toEqual({ state: 'stored', windowId: f.w.windowId });
    expect((await db.prepare('SELECT * FROM group_anchor_receipts WHERE person_id=?').bind(f.p.id).all()).results).toHaveLength(1);
    expect((await db.prepare('SELECT revision,key_epoch FROM group_windows WHERE space_id=?').bind(f.w.windowId).first())).toEqual({ revision: 1, key_epoch: 1 });
  });
  it('rejects forged root signature, wrong environment/person and unregistered member', async () => {
    const f = await fixture();
    for (const body of [{ ...f.input, rootSignature: randomBase64url(64) },
      { ...f.input, environment: 'production' }, { ...f.input, personId: 'other' }])
      expect((await f.put(body)).status).toBe(401);
    const outsider = await person();
    expect((await send(await signed(outsider, f.path, f.input), settings)).status).toBe(401);
    expect((await db.prepare('SELECT 1 FROM group_anchor_receipts WHERE person_id=?').bind(f.p.id).first())).toBeNull();
  });
  it('never replaces a different correctly signed anchor, including concurrent submissions', async () => {
    const f = await fixture(), other = await key(), otherID = await sha256Base64url(base64urlDecode(other.publicKey, 32));
    const changed = { ...f.input, ownerPersonId: otherID, ownerPublicKey: other.publicKey,
      rootSignature: await sign(f.p.identity.privateKey, anchorReceiptTranscript('staging', f.p.id, f.w.windowId, otherID, other.publicKey)) };
    const results = await Promise.all([f.put(), f.put(changed)]);
    expect(results.map(r => r.status).sort()).toEqual([200, 409]);
    const before = await db.prepare('SELECT * FROM group_anchor_receipts WHERE person_id=?').bind(f.p.id).first();
    const winner = results[0]!.status === 200 ? f.input : changed;
    expect((await f.put(winner)).status).toBe(200);
    expect(await db.prepare('SELECT * FROM group_anchor_receipts WHERE person_id=?').bind(f.p.id).first()).toEqual(before);
  });
  it('revocation removes receipts and prevents replay', async () => {
    const f = await fixture(); expect((await f.put()).status).toBe(200);
    await db.prepare("UPDATE group_people SET state='revoked' WHERE id=?").bind(f.p.id).run();
    expect(await db.prepare('SELECT 1 FROM group_anchor_receipts WHERE person_id=?').bind(f.p.id).first()).toBeNull();
    expect((await f.put()).status).toBe(401);
  });
});
