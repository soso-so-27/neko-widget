import { describe, expect, it } from 'vitest';
import { route } from '../src/index';
import { familyInvitationProof } from '../src/family-notebook-admission';
import { familyRosterBytes, verifyFamilyRoster, type FamilyCryptoMember, type VerifiedFamilyCryptoRoster } from '../src/family-notebook-crypto';
import { groupDeviceAuthorization, groupFields } from '../src/group-protocol';
import { base64urlDecode, base64urlEncode, randomBase64url, sha256Base64url } from '../src/encoding';
import { errorResponse } from '../src/errors';
import type { Env } from '../src/env';
import { plusOwner, pauseOwner, settings } from './group-billing-fixture';
import { cipher, db, key, ok, person, send, sign, signed, type Person, type Reply } from './group-fixture';

const enabled: Env = { ...settings, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES', FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'YES' };
const root = '/v3/family-notebooks';
async function invoke(p: Person, path: string, body?: unknown, env = enabled): Promise<Reply> {
  const request = await signed(p, path, body);
  let response: Response;
  try {
    response = await route(request, env);
  } catch (error) { response = errorResponse(error); }
  return { status: response.status, data: await response.json() as Reply['data'] };
}
async function create(p: Person) {
  await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run();
  const id = crypto.randomUUID(); ok(await invoke(p, root, { operationId: crypto.randomUUID(), familyId: id })); return id;
}
async function member(p: Person, family: string): Promise<FamilyCryptoMember> {
  const device = { id: p.deviceId, signingPublicKey: p.signing.publicKey, hpkePublicKey: p.hpke, personAuthorization: '' };
  device.personAuthorization = await sign(p.identity.privateKey, groupDeviceAuthorization(family, p.id, device));
  return { personId: p.id, identityPublicKey: p.identity.publicKey, devices: [device] };
}
function body(payload: unknown, generation: number, epoch: number, operationId = crypto.randomUUID()) {
  return { operationId, expectedGeneration: generation, expectedEpoch: epoch, payload };
}
async function register(p: Person, family: string, generation = 1, epoch = 0) {
  const m = await member(p, family);
  ok(await invoke(p, `${root}/${family}/crypto/devices`, body({ personAuthorization: m.devices[0]!.personAuthorization }, generation, epoch)));
  return m;
}
async function packet(p: Person, family: string, members: FamilyCryptoMember[], previous?: VerifiedFamilyCryptoRoster) {
  const roster = { familyId: family.toUpperCase(), epoch: (previous?.packet.roster.epoch ?? 0) + 1,
    previousHash: previous?.hash ?? 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', keyCommitment: randomBase64url(32), members };
  const packet = { roster, signerDeviceId: p.deviceId,
    signature: await sign(p.signing.privateKey, groupFields(['FNB1.ROSTER.SIGN', familyRosterBytes(roster), p.deviceId])) };
  return verifyFamilyRoster(packet, previous);
}
async function initialize(p: Person, family: string) {
  const m = await register(p, family), r = await packet(p, family, [m]);
  ok(await invoke(p, `${root}/${family}/crypto/rosters`, body(r.packet, 1, 0))); return { m, r };
}
async function admit(p: Person, newcomer: Person, family: string, generation = 1) {
  const proof = await key(), invitationId = crypto.randomUUID();
  ok(await invoke(p, `${root}/${family}/invitations`, { operationId: invitationId, expectedGeneration: generation, proofPublicKey: proof.publicKey, encryptedPreview: cipher() }));
  const joinId = crypto.randomUUID();
  ok(await invoke(newcomer, `${root}/${family}/invitations/${invitationId}/join`, {
    operationId: joinId, expectedGeneration: generation, encryptedDisplayName: cipher(),
    proofSignature: await sign(proof.privateKey, familyInvitationProof(family, invitationId, newcomer.id, newcomer.deviceId, 'join', joinId)),
  }));
  ok(await invoke(p, `${root}/${family}/requests/${joinId}/approve`, { operationId: crypto.randomUUID(), expectedGeneration: generation }));
}
async function operation(p: Person, r: VerifiedFamilyCryptoRoster, size = 48) {
  const packet = { familyId: r.packet.roster.familyId, keyEpoch: r.packet.roster.epoch, rosterHash: r.hash,
    operationId: crypto.randomUUID(), personId: p.id, deviceId: p.deviceId,
    ciphertext: size <= 65536 ? randomBase64url(size) : base64urlEncode(new Uint8Array(size).fill(7)), signature: '' };
  const aad = groupFields(['FNB1.OPERATION', packet.familyId.toLowerCase(), String(packet.keyEpoch), base64urlDecode(r.hash, 32),
    packet.operationId, p.id, p.deviceId, String(size)]);
  packet.signature = await sign(p.signing.privateKey, groupFields(['FNB1.OPERATION.SIGN', aad, base64urlDecode(await sha256Base64url(base64urlDecode(packet.ciphertext)), 32)]));
  return packet;
}
async function envelope(p: Person, recipient: Person, current: VerifiedFamilyCryptoRoster, source = current) {
  const e = { familyId: current.packet.roster.familyId, keyEpoch: source.packet.roster.epoch, keyRosterHash: source.hash,
    recipientRosterHash: current.hash, recipientDeviceId: recipient.deviceId, signerDeviceId: p.deviceId,
    encapsulatedKey: randomBase64url(32), ciphertext: cipher(), signature: '' };
  const info = groupFields(['FNB1.KEY', e.familyId.toLowerCase(), String(e.keyEpoch), base64urlDecode(source.hash, 32), base64urlDecode(current.hash, 32), recipient.deviceId]);
  e.signature = await sign(p.signing.privateKey, groupFields(['FNB1.KEY.SIGN', info, base64urlDecode(e.encapsulatedKey, 32), base64urlDecode(e.ciphertext, 48), p.deviceId]));
  return e;
}
function beforeCommit(action: () => Promise<void>): Env {
  let pending = true;
  return { ...enabled, DB: new Proxy(db, { get(target, property) {
    if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
      if (pending) { pending = false; await action(); } return target.batch(statements);
    };
    const value = Reflect.get(target, property); return typeof value === 'function' ? value.bind(target) : value;
  } }) };
}

describe('family encrypted history transaction boundary', () => {
  it('keeps public routes off, requires membership and an explicit family certificate', async () => {
    const a = await plusOwner(), stranger = await person(), f = await create(a);
    expect((await send(await signed(a, `${root}/${f}/crypto/state`), { ...enabled, FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'NO' })).status).toBe(404);
    expect((await invoke(stranger, `${root}/${f}/crypto/state`)).status).toBe(404);
    const wrong = await member(a, crypto.randomUUID());
    expect((await invoke(a, `${root}/${f}/crypto/devices`, body({ personAuthorization: wrong.devices[0]!.personAuthorization }, 1, 0))).data.error.code).toBe('invalid_family_proof');
    expect((await invoke(a, `${root}/${f}/crypto/state`, undefined, { ...enabled, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'NO' })).status).toBe(503);
    await initialize(a, f);
    expect(ok(await invoke(a, `${root}/${f}/crypto/state`))).toMatchObject({ ready: true, currentEpoch: 1, people: [a.id] });
  });

  it('rejects an unadmitted identity and missing devices atomically when installing a roster', async () => {
    const a = await plusOwner(), b = await person(), f = await create(a), ma = await register(a, f), mb = await member(b, f);
    const bad = await packet(a, f, [ma, mb]);
    expect((await invoke(a, `${root}/${f}/crypto/rosters`, body(bad.packet, 1, 0))).data.error.code).toBe('family_notebook_crypto_stale');
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_rosters WHERE family_id=?').bind(f).first())?.n).toBe(0);
    const r = await packet(a, f, [ma]); ok(await invoke(a, `${root}/${f}/crypto/rosters`, body(r.packet, 1, 0)));
    await admit(a, b, f); await register(b, f, 2, 1);
    const omitted = await packet(a, f, [ma], r);
    expect((await invoke(a, `${root}/${f}/crypto/rosters`, body(omitted.packet, 2, 1))).status).toBe(409);
    expect(ok(await invoke(a, `${root}/${f}/crypto/state`))).toMatchObject({ ready: false, currentEpoch: 1 });
  });

  it('preserves exact ACKs after rotation and gives new members all old packets and their own history keys', async () => {
    const a = await plusOwner(), b = await person(), f = await create(a), { m, r } = await initialize(a, f);
    const op = await operation(a, r), request = body(op, 1, 1, op.operationId), path = `${root}/${f}/crypto/operations`;
    const receipt = ok(await invoke(a, path, request));
    expect(ok(await invoke(a, path, request))).toEqual(receipt);
    expect((await invoke(a, path, { ...request, expectedGeneration: 2 })).data.error.code).toBe('idempotency_conflict');
    await admit(a, b, f); const mb = await register(b, f, 2, 1);
    const stale = await operation(a, r);
    expect((await invoke(a, path, body(stale, 2, 1, stale.operationId))).data.error.code).toBe('family_notebook_crypto_stale');
    const r2 = await packet(a, f, [m, mb], r); ok(await invoke(a, `${root}/${f}/crypto/rosters`, body(r2.packet, 2, 1)));
    const e = await envelope(a, b, r2, r); ok(await invoke(a, `${root}/${f}/crypto/keys`, body(e, 2, 2)));
    expect(ok(await invoke(b, `${root}/${f}/crypto/keys/1`)).envelopes).toEqual([e]);
    expect(ok(await invoke(a, `${root}/${f}/crypto/keys/1`)).envelopes).toEqual([]);
    expect(ok(await invoke(b, `${root}/${f}/crypto/rosters/1`)).roster).toEqual(r.packet);
    expect(ok(await invoke(b, `${path}/0`)).operations).toEqual([{ sequence: 1, packet: op }]);
    expect(ok(await invoke(a, path, request))).toEqual(receipt);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_operations WHERE family_id=?').bind(f).first())?.n).toBe(1);
  });

  it('retains history but denies departed people; remaining members rotate without payer private keys', async () => {
    const a = await plusOwner(), b = await person(), f = await create(a), { m, r } = await initialize(a, f);
    const op = await operation(a, r), request = body(op, 1, 1, op.operationId), path = `${root}/${f}/crypto/operations`;
    const receipt = ok(await invoke(a, path, request));
    await admit(a, b, f); const mb = await register(b, f, 2, 1), r2 = await packet(a, f, [m, mb], r);
    ok(await invoke(a, `${root}/${f}/crypto/rosters`, body(r2.packet, 2, 1)));
    ok(await invoke(a, `${root}/${f}/leave`, { operationId: crypto.randomUUID(), expectedGeneration: 2 }));
    expect((await invoke(a, `${path}/0`)).status).toBe(404);
    expect(ok(await invoke(a, path, request))).toEqual(receipt);
    expect(ok(await invoke(b, `${path}/0`)).operations).toHaveLength(1);
    const r3 = await packet(b, f, [mb], r2); ok(await invoke(b, `${root}/${f}/crypto/rosters`, body(r3.packet, 3, 2)));
    const e = await envelope(b, a, r3, r);
    expect((await invoke(b, `${root}/${f}/crypto/keys`, body(e, 3, 3))).data.error.code).toBe('invalid_family_proof');
    const newOp = await operation(b, r3);
    expect((await invoke(b, path, body(newOp, 3, 3, newOp.operationId))).data.error.code).toBe('family_notebook_paused');
  });

  it('rechecks Plus and departure at commit and never ACKs a rejected edit', async () => {
    const a = await plusOwner(), f = await create(a), { r } = await initialize(a, f), op = await operation(a, r);
    const request = body(op, 1, 1, op.operationId), path = `${root}/${f}/crypto/operations`;
    expect((await invoke(a, path, request, beforeCommit(() => pauseOwner(a)))).data.error.code).toBe('family_notebook_paused');
    expect(ok(await invoke(a, `${path}/0`)).operations).toEqual([]);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_receipts WHERE operation_id=?').bind(op.operationId).first())?.n).toBe(0);
    // Restore authority only in the synthetic billing fixture, then retry the
    // exact old bytes. Pausing never consumes the pending logical operation.
    await a.verified.refresh({ revocationDateMs: null, revocationReason: null }, 1);
    ok(await invoke(a, path, request));
    const env = beforeCommit(async () => { ok(await invoke(a, `${root}/${f}/leave`, { operationId: crypto.randomUUID(), expectedGeneration: 1 })); });
    expect((await invoke(a, `${path}/0`, undefined, env)).status).toBe(404);
  });

  it('rejects ciphertext/author substitution and resolves concurrent roster CAS with one winner', async () => {
    const a = await plusOwner(), f = await create(a), { m, r } = await initialize(a, f), op = await operation(a, r);
    expect((await invoke(a, `${root}/${f}/crypto/operations`, body({ ...op, ciphertext: cipher() }, 1, 1, op.operationId))).data.error.code).toBe('invalid_family_proof');
    const r2a = await packet(a, f, [m], r), r2b = await packet(a, f, [m], r);
    const replies = await Promise.all([r2a, r2b].map(v => invoke(a, `${root}/${f}/crypto/rosters`, body(v.packet, 1, 1))));
    expect(replies.map(r => r.status).sort()).toEqual([200, 409]);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_rosters WHERE family_id=?').bind(f).first())?.n).toBe(2);
  });

  it('paginates every immutable edit without losing history or returning another family', async () => {
    const a = await plusOwner(), f = await create(a), { r } = await initialize(a, f), ids = [];
    for (let i = 0; i < 65; i++) {
      const op = await operation(a, r); ids.push(op.operationId);
      ok(await invoke(a, `${root}/${f}/crypto/operations`, body(op, 1, 1, op.operationId)));
    }
    const first = ok(await invoke(a, `${root}/${f}/crypto/operations/0`));
    expect(first).toMatchObject({ nextCursor: 64, headCursor: 65 });
    const second = ok(await invoke(a, `${root}/${f}/crypto/operations/64`));
    expect(second).toMatchObject({ nextCursor: 65, headCursor: 65 });
    expect([...first.operations, ...second.operations].map((o: { packet: { operationId: string } }) => o.packet.operationId)).toEqual(ids);
  });

  it('bounds ciphertext and page bytes, including one maximum-sized signed edit', async () => {
    const a = await plusOwner(), f = await create(a), { r } = await initialize(a, f), path = `${root}/${f}/crypto/operations`;
    const big = await operation(a, r, 1_048_576);
    ok(await invoke(a, path, body(big, 1, 1, big.operationId)));
    const next = await operation(a, r, 65536); ok(await invoke(a, path, body(next, 1, 1, next.operationId)));
    const third = await operation(a, r, 65536); ok(await invoke(a, path, body(third, 1, 1, third.operationId)));
    const first = ok(await invoke(a, `${path}/0`));
    expect(first.operations.length).toBeLessThan(3);
    expect(JSON.stringify(first).length).toBeLessThan(1_501_000);
    const second = ok(await invoke(a, `${path}/${first.nextCursor}`));
    expect([...first.operations, ...second.operations].map((o: { packet: { operationId: string } }) => o.packet.operationId))
      .toEqual([big.operationId, next.operationId, third.operationId]);
    const oversized = await operation(a, r, 1_048_577);
    expect((await invoke(a, path, body(oversized, 1, 1, oversized.operationId))).data.error.code).toBe('invalid_family_proof');
  });

  it('rechecks another device revocation at commit and lets recipients choose a valid key from separate signers', async () => {
    const a = await plusOwner(), b = await person(), f = await create(a), { m, r } = await initialize(a, f);
    await admit(a, b, f); const mb = await register(b, f, 2, 1), r2 = await packet(a, f, [m, mb], r);
    ok(await invoke(a, `${root}/${f}/crypto/rosters`, body(r2.packet, 2, 1)));
    const ea = await envelope(a, b, r2, r), eb = await envelope(b, b, r2, r), path = `${root}/${f}/crypto/keys`;
    ok(await invoke(a, path, body(ea, 2, 2))); ok(await invoke(b, path, body(eb, 2, 2)));
    expect(ok(await invoke(b, `${path}/1`)).envelopes).toHaveLength(2);
    // A signer can replace only their own candidate; a bad HPKE ciphertext
    // cannot occupy the only slot and prevent another member supplying a key.
    ok(await invoke(b, path, body(await envelope(b, b, r2, r), 2, 2)));
    expect(ok(await invoke(b, `${path}/1`)).envelopes).toHaveLength(2);
    const env = beforeCommit(async () => { await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(a.deviceId).run(); });
    expect((await invoke(b, path, body(await envelope(b, b, r2, r), 2, 2), env)).data.error.code).toBe('family_notebook_crypto_stale');
  });
});
