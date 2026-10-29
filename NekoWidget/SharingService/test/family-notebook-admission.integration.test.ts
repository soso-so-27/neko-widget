import { describe, expect, it } from 'vitest';
import { route } from '../src/index';
import { familyInvitationProof } from '../src/family-notebook-admission';
import { familyNotebookPayer } from '../src/family-notebook-payer';
import { base64urlEncode } from '../src/encoding';
import { errorResponse } from '../src/errors';
import type { Env } from '../src/env';
import { plusOwner, pauseOwner, settings } from './group-billing-fixture';
import { cipher, create, db, ok, person, send, sign, signed, type Person, type Reply } from './group-fixture';

const enabled: Env = { ...settings, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES', FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'YES' };
const root = '/v3/family-notebooks';
async function invoke(request: Request, env: Env = enabled): Promise<Reply> {
  let response: Response;
  try { response = await route(request, env); } catch (error) { response = errorResponse(error); }
  return { status: response.status, data: await response.json() as Reply['data'] };
}
async function call(p: Person, path: string, body: unknown, env = enabled) { return invoke(await signed(p, path, body), env); }
async function openGate() { await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run(); }
async function family(p: Person) {
  await openGate();
  const familyId = crypto.randomUUID(), body = { operationId: crypto.randomUUID(), familyId };
  const receipt = ok(await call(p, root, body));
  return { id: familyId, body, receipt };
}
async function invitation(p: Person, f: string, generation = 1) {
  const keys = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const body = { operationId: crypto.randomUUID(), expectedGeneration: generation,
    proofPublicKey: base64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey))), encryptedPreview: cipher() };
  ok(await call(p, `${root}/${f}/invitations`, body));
  return { id: body.operationId, keys, body };
}
async function proof(p: Person, f: string, i: Awaited<ReturnType<typeof invitation>>, action: 'preview' | 'join', operationId: string) {
  return sign(i.keys.privateKey, familyInvitationProof(f, i.id, p.id, p.deviceId, action, operationId));
}
async function join(p: Person, f: string, i: Awaited<ReturnType<typeof invitation>>, generation = 1) {
  const operationId = crypto.randomUUID(), body = { operationId, expectedGeneration: generation,
    proofSignature: await proof(p, f, i, 'join', operationId), encryptedDisplayName: cipher() };
  const reply = await call(p, `${root}/${f}/invitations/${i.id}/join`, body);
  return { id: operationId, body, reply };
}
async function approve(p: Person, f: string, j: string, generation = 1, env = enabled) {
  return call(p, `${root}/${f}/requests/${j}/approve`, { operationId: crypto.randomUUID(), expectedGeneration: generation }, env);
}
async function leave(p: Person, f: string, generation: number) {
  const request = await signed(p, `${root}/${f}/leave`, { operationId: crypto.randomUUID(), expectedGeneration: generation });
  return familyNotebookPayer(request, enabled, f, 'leave');
}
function beforeCommit(action: () => Promise<void>): Env {
  let pending = true;
  return { ...enabled, DB: new Proxy(db, { get(target, property) {
    if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
      if (pending) { pending = false; await action(); }
      return target.batch(statements);
    };
    const value = Reflect.get(target, property);
    return typeof value === 'function' ? value.bind(target) : value;
  } }) };
}

describe('independent family admission, not publicly enabled', () => {
  it('requires the separate exact API opt-in before any family DB access', async () => {
    const p = await person();
    const noDB = new Proxy(db, { get() { throw new Error('closed API must not access D1'); } });
    for (const flag of [undefined, 'NO', 'yes', 'true']) {
      const config: Env = { ...enabled, DB: noDB };
      if (flag === undefined) delete config.FAMILY_NOTEBOOK_API_RUNTIME_ENABLED;
      else config.FAMILY_NOTEBOOK_API_RUNTIME_ENABLED = flag;
      const reply = await send(await signed(p, root + '/me'), config);
      expect(reply.status).toBe(404);
    }
    expect((await send(await signed(p, root + '/me'), {
      ...enabled, DB: noDB, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'NO',
    })).data.error.code).toBe('family_notebook_disabled');
    expect((await send(await signed(p, root + '/me'), enabled)).data.error.code).toBe('family_notebook_disabled');
    await openGate();
    expect(ok(await send(await signed(p, root + '/me'), enabled))).toMatchObject({ personId: p.id, family: null, pendingRequests: [] });
    expect((await send(await signed(p, root + '/me', {}), enabled)).status).toBe(404);
    expect((await send(await signed(p, root + '/unknown'), enabled)).status).toBe(404);
    await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=0,generation=generation+1 WHERE singleton=1').run();
  });

  it('stays OFF/unrouted and requires verified Plus, never photo-window membership', async () => {
    const p = await plusOwner(), body = { operationId: crypto.randomUUID(), familyId: crypto.randomUUID() };
    expect((await call(p, root, body)).data.error.code).toBe('family_notebook_disabled');
    await openGate();
    const free = await person();
    expect((await call(free, root, body)).data.error.code).toBe('plus_entitlement_required');
    const photo = await create(p);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_members WHERE person_id=?').bind(p.id).first())?.n).toBe(0);
    expect((await send(await signed(p, root, body), { ...enabled, FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'NO' })).status).toBe(404);
    expect(photo.windowId).toBeTruthy();
  });

  it('retains exact creation receipts and enforces one active family inside the transaction', async () => {
    const p = await plusOwner(), f = await family(p);
    expect(ok(await call(p, root, f.body))).toEqual(f.receipt);
    expect((await call(p, root, { ...f.body, familyId: crypto.randomUUID() })).data.error.code).toBe('idempotency_conflict');
    expect((await call(p, root, { operationId: crypto.randomUUID(), familyId: crypto.randomUUID() })).data.error.code).toBe('family_notebook_already_in_family');
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_spaces WHERE id=?').bind(f.id).first())?.n).toBe(1);
  });

  it('requires capability possession and separates preview from joining and member admission', async () => {
    const p = await plusOwner(), newcomer = await person(), outsider = await person(), f = await family(p), i = await invitation(p, f.id);
    const operationId = crypto.randomUUID(), proofSignature = await proof(newcomer, f.id, i, 'preview', operationId);
    const previewPath = `${root}/${f.id}/invitations/${i.id}/preview`, previewBody = { operationId, proofSignature };
    const preview = ok(await call(newcomer, previewPath, previewBody));
    expect(preview).toMatchObject({ familyId: f.id, invitationId: i.id, inviterPersonId: p.id, encryptedPreview: i.body.encryptedPreview });
    expect(JSON.stringify(preview)).not.toContain('proof_public_key');
    expect((await call(outsider, previewPath, previewBody)).data.error.code).toBe('invalid_proof');
    expect((await call(newcomer, `${root}/${f.id}/invitations/${i.id}/join`, { ...previewBody, expectedGeneration: 1, encryptedDisplayName: cipher() })).data.error.code).toBe('invalid_proof');
    const j = await join(newcomer, f.id, i); ok(j.reply);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_members WHERE person_id=?').bind(newcomer.id).first())?.n).toBe(0);
    expect(ok(await call(newcomer, `${root}/${f.id}/invitations/${i.id}/join`, j.body))).toEqual(j.reply.data);
    expect((await approve(outsider, f.id, j.id)).status).not.toBe(200);
    ok(await approve(p, f.id, j.id));
    expect(await db.prepare('SELECT state,admitted_generation FROM family_notebook_members WHERE person_id=?').bind(newcomer.id).first())
      .toEqual({ state: 'active', admitted_generation: 2 });
    // Admission stores no notebook content, no personal cat IDs, no plaintext
    // name/date and no room key. Encryption/history delivery is a later boundary.
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_admission_events WHERE family_id=?').bind(f.id).first())?.n).toBe(4);
  });

  it('lets an admitted free member invite and approve, without changing who pays', async () => {
    const p = await plusOwner(), member = await person(), next = await person(), f = await family(p), i = await invitation(p, f.id);
    const first = await join(member, f.id, i); ok(first.reply); ok(await approve(p, f.id, first.id));
    const second = await invitation(member, f.id, 2), j = await join(next, f.id, second, 2); ok(j.reply);
    ok(await approve(member, f.id, j.id, 2));
    expect(await db.prepare('SELECT payer_person_id,generation FROM family_notebook_spaces WHERE id=?').bind(f.id).first())
      .toEqual({ payer_person_id: p.id, generation: 3 });
  });

  it('rejects an expired invitation and rechecks inviter revocation during preview', async () => {
    const p = await plusOwner(), newcomer = await person(), f = await family(p), expired = await invitation(p, f.id);
    await db.prepare('UPDATE family_notebook_invitations SET expires_at=unixepoch()-1 WHERE id=?').bind(expired.id).run();
    expect((await join(newcomer, f.id, expired)).reply.data.error.code).toBe('family_notebook_invitation_unavailable');
    const i = await invitation(p, f.id), operationId = crypto.randomUUID();
    const body = { operationId, proofSignature: await proof(newcomer, f.id, i, 'preview', operationId) };
    const env = beforeCommit(async () => { await db.prepare("UPDATE group_people SET state='revoked' WHERE id=?").bind(p.id).run(); });
    expect((await call(newcomer, `${root}/${f.id}/invitations/${i.id}/preview`, body, env)).data.error.code)
      .toBe('family_notebook_invitation_unavailable');
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_join_requests WHERE family_id=?').bind(f.id).first())?.n).toBe(0);
  });

  it('revokes used invitations and cancels pending requests, including a revoke/approve race', async () => {
    const p = await plusOwner(), newcomer = await person(), f = await family(p), i = await invitation(p, f.id), j = await join(newcomer, f.id, i); ok(j.reply);
    const env = beforeCommit(async () => { ok(await call(p, `${root}/${f.id}/invitations/${i.id}/revoke`, { operationId: crypto.randomUUID(), expectedGeneration: 1 })); });
    expect((await approve(p, f.id, j.id, 1, env)).data.error.code).toBe('family_notebook_request_not_pending');
    expect(await db.prepare('SELECT state FROM family_notebook_join_requests WHERE id=?').bind(j.id).first()).toEqual({ state: 'cancelled' });
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_members WHERE person_id=?').bind(newcomer.id).first())?.n).toBe(0);
  });

  it('invalidates a departed inviter while retaining their old operation receipt and notebook membership history', async () => {
    const p = await plusOwner(), newcomer = await person(), f = await family(p), i = await invitation(p, f.id), j = await join(newcomer, f.id, i); ok(j.reply);
    expect((await leave(p, f.id, 1)).status).toBe(200);
    expect(await db.prepare('SELECT state FROM family_notebook_join_requests WHERE id=?').bind(j.id).first()).toEqual({ state: 'cancelled' });
    expect(await db.prepare('SELECT state FROM family_notebook_invitations WHERE id=?').bind(i.id).first()).toEqual({ state: 'revoked' });
    expect(ok(await call(p, `${root}/${f.id}/invitations`, i.body))).toMatchObject({ operation: 'invite', invitationId: i.id });
    expect(await db.prepare('SELECT state FROM family_notebook_members WHERE person_id=?').bind(p.id).first()).toEqual({ state: 'left' });
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_spaces WHERE id=?').bind(f.id).first())?.n).toBe(1);
  });

  it('rechecks payer Plus at COMMIT, keeps pending data, and permits revocation while paused', async () => {
    const p = await plusOwner(), newcomer = await person(), f = await family(p), i = await invitation(p, f.id), j = await join(newcomer, f.id, i); ok(j.reply);
    const env = beforeCommit(async () => { await pauseOwner(p); });
    expect((await approve(p, f.id, j.id, 1, env)).data.error.code).toBe('family_notebook_paused');
    expect(await db.prepare('SELECT state FROM family_notebook_join_requests WHERE id=?').bind(j.id).first()).toEqual({ state: 'pending' });
    ok(await call(p, `${root}/${f.id}/invitations/${i.id}/revoke`, { operationId: crypto.randomUUID(), expectedGeneration: 1 }));
  });

  it('admits a person to only one of two families under concurrent approvals', async () => {
    const a = await plusOwner(), b = await plusOwner(), newcomer = await person(), fa = await family(a), fb = await family(b);
    const ia = await invitation(a, fa.id), ib = await invitation(b, fb.id), ja = await join(newcomer, fa.id, ia), jb = await join(newcomer, fb.id, ib);
    ok(ja.reply); ok(jb.reply);
    const results = await Promise.all([approve(a, fa.id, ja.id), approve(b, fb.id, jb.id)]);
    expect(results.map(r => r.status).sort()).toEqual([200, 409]);
    expect((await db.prepare("SELECT COUNT(*) n FROM family_notebook_members WHERE person_id=? AND state='active'").bind(newcomer.id).first())?.n).toBe(1);
  });

  it('supports explicit re-admission after self-departure and enforces the configured member bound without eviction', async () => {
    const p = await plusOwner(), newcomer = await person(), extra = await person(), f = await family(p), i = await invitation(p, f.id), j = await join(newcomer, f.id, i);
    ok(j.reply); ok(await approve(p, f.id, j.id)); expect((await leave(newcomer, f.id, 2)).status).toBe(200);
    const back = await invitation(p, f.id, 3), rejoin = await join(newcomer, f.id, back, 3); ok(rejoin.reply); ok(await approve(p, f.id, rejoin.id, 3));
    expect(await db.prepare('SELECT state,admitted_generation,left_generation FROM family_notebook_members WHERE person_id=?').bind(newcomer.id).first())
      .toEqual({ state: 'active', admitted_generation: 4, left_generation: null });
    const more = await invitation(p, f.id, 4), overflow = await join(extra, f.id, more, 4); ok(overflow.reply);
    expect((await approve(p, f.id, overflow.id, 4, { ...enabled, FAMILY_NOTEBOOK_MAX_MEMBERS: '2' })).data.error.code).toBe('family_notebook_member_limit');
    expect((await db.prepare("SELECT COUNT(*) n FROM family_notebook_members WHERE family_id=? AND state='active'").bind(f.id).first())?.n).toBe(2);
  });
});
