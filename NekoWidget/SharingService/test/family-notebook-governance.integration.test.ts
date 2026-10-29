import { describe, expect, it } from 'vitest';
import { familyNotebookGovernance } from '../src/family-notebook-governance';
import { familyNotebookAdmission, familyInvitationProof } from '../src/family-notebook-admission';
import { familyNotebookPayer } from '../src/family-notebook-payer';
import { familyNotebookHistory } from '../src/family-notebook-history';
import { familyNotebookDirectory } from '../src/family-notebook-directory';
import { errorResponse } from '../src/errors';
import type { Env } from '../src/env';
import { plusOwner, pauseOwner, settings } from './group-billing-fixture';
import { cipher, db, key, ok, person, send, sign, signed, type Person, type Reply } from './group-fixture';

const enabled: Env = { ...settings, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES' };
const root = '/v3/family-notebooks';
async function invoke(p: Person, path: string, body?: unknown, env = enabled): Promise<Reply> {
  const request = await signed(p, path, body); let response: Response;
  try {
    const family = path.split('/')[3]!;
    response = body === undefined && /\/(me|members|requests|invitations)$/u.test(path) ? await familyNotebookDirectory(request, env)
      : path.endsWith('/leave') ? await familyNotebookPayer(request, env, family, 'leave')
      : path.endsWith('/payer/claim') ? await familyNotebookPayer(request, env, family, 'claim')
      : path.endsWith('/payer') ? await familyNotebookPayer(request, env, family)
      : path.includes('/crypto/') ? await familyNotebookHistory(request, env)
      : path === root || path.includes('/invitations') || path.includes('/requests/') ? await familyNotebookAdmission(request, env)
      : await familyNotebookGovernance(request, env);
  } catch (error) { response = errorResponse(error); }
  return { status: response.status, data: await response.json() as Reply['data'] };
}
function body(generation: number, extra: object = {}) { return { operationId: crypto.randomUUID(), expectedGeneration: generation, ...extra }; }
async function create(p: Person) {
  await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run();
  const id = crypto.randomUUID(); ok(await invoke(p, root, { operationId: crypto.randomUUID(), familyId: id })); return id;
}
async function admit(a: Person, b: Person, f: string, generation = 1, approve = true) {
  const k = await key(), invitation = body(generation, { proofPublicKey: k.publicKey, encryptedPreview: cipher() });
  ok(await invoke(a, `${root}/${f}/invitations`, invitation));
  const join = body(generation);
  ok(await invoke(b, `${root}/${f}/invitations/${invitation.operationId}/join`, { ...join, encryptedDisplayName: cipher(),
    proofSignature: await sign(k.privateKey, familyInvitationProof(f, invitation.operationId, b.id, b.deviceId, 'join', join.operationId)) }));
  if (approve) ok(await invoke(a, `${root}/${f}/requests/${join.operationId}/approve`, body(generation)));
  return { requestId: join.operationId, invitationId: invitation.operationId };
}
async function nominate(a: Person, b: Person, f: string, generation: number) {
  const request = body(generation, { personId: b.id });
  ok(await invoke(a, `${root}/${f}/payer/nominate`, request)); return request.operationId;
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

describe('explicit family handover and retained management', () => {
  it('discovers only the authenticated family and scopes pending requests to their inviter or payer', async () => {
    const a = await plusOwner(), b = await person(), c = await person(), f = await create(a);
    await admit(a, c, f); const waiting = await admit(a, b, f, 2, false);
    expect(ok(await invoke(b, `${root}/me`))).toMatchObject({ personId: b.id, family: null,
      pendingRequests: [{ familyId: f, requestId: waiting.requestId }] });
    expect(ok(await invoke(c, `${root}/me`))).toMatchObject({ personId: c.id, family: { familyId: f, role: 'member' }, pendingRequests: [] });
    expect((await invoke(b, `${root}/${f}/members`)).status).toBe(404);
    expect(ok(await invoke(c, `${root}/${f}/requests`)).requests).toEqual([]);
    expect(ok(await invoke(c, `${root}/${f}/invitations`)).invitations).toEqual([]);
    expect(ok(await invoke(a, `${root}/${f}/requests`)).requests).toMatchObject([{ requestId: waiting.requestId, personId: b.id }]);
    ok(await invoke(a, `${root}/${f}/requests/${waiting.requestId}/approve`, body(2)));
    expect(ok(await invoke(b, `${root}/${f}/members`)).members).toHaveLength(3);
    const env = beforeCommit(async () => { ok(await invoke(b, `${root}/${f}/leave`, body(3))); });
    expect((await invoke(b, `${root}/${f}/members`, undefined, env)).status).toBe(404);
    expect(ok(await invoke(b, `${root}/me`)).family).toBe(null);
  });

  it('keeps routes off and requires the actual payer to nominate an admitted different person', async () => {
    const a = await plusOwner(), b = await person(), stranger = await person(), f = await create(a); await admit(a, b, f);
    expect((await send(await signed(a, `${root}/${f}/payer/handover`), enabled)).status).toBe(404);
    expect((await invoke(b, `${root}/${f}/payer/nominate`, body(2, { personId: a.id }))).data.error.code).toBe('family_notebook_not_allowed');
    expect((await invoke(a, `${root}/${f}/payer/nominate`, body(2, { personId: stranger.id }))).status).toBe(403);
    expect((await invoke(a, `${root}/${f}/payer/nominate`, body(2, { personId: a.id }))).status).toBe(403);
    expect(ok(await invoke(a, `${root}/${f}/payer/handover`))).toMatchObject({ payerPersonId: a.id, canNominate: true, canAccept: false, canCancel: false });
    expect((await invoke(a, `${root}/${f}/payer/handover`, undefined, { ...enabled, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'NO' })).status).toBe(503);
  });

  it('requires recipient acceptance and verified Plus; nomination alone changes no payer or subscription', async () => {
    const a = await plusOwner(), b = await plusOwner(), f = await create(a); await admit(a, b, f); await pauseOwner(b);
    const nominationId = await nominate(a, b, f, 2), accept = body(3, { nominationId });
    expect(ok(await invoke(a, `${root}/${f}/payer`))).toMatchObject({ payerPersonId: a.id, sharingStatus: 'active' });
    expect(ok(await invoke(b, `${root}/${f}/payer/handover`))).toMatchObject({ nominationId, canAccept: false, canCancel: true });
    expect((await invoke(a, `${root}/${f}/payer/accept`, accept)).status).toBe(409);
    expect((await invoke(b, `${root}/${f}/payer/accept`, accept)).data.error.code).toBe('plus_entitlement_required');
    await b.verified.refresh({}, 1);
    expect(ok(await invoke(b, `${root}/${f}/payer/handover`)).canAccept).toBe(true);
    const receipt = ok(await invoke(b, `${root}/${f}/payer/accept`, accept));
    expect(ok(await invoke(b, `${root}/${f}/payer/accept`, accept))).toEqual(receipt);
    expect(ok(await invoke(b, `${root}/${f}/payer`))).toMatchObject({ role: 'payer', canDissolve: true, payerPersonId: b.id });
    expect(ok(await invoke(a, `${root}/${f}/payer`))).toMatchObject({ role: 'member', canDissolve: false, sharingStatus: 'active' });
    expect((await db.prepare("SELECT COUNT(*) n FROM group_verified_plus_people WHERE person_id IN (?,?) AND environment='Sandbox'").bind(a.id, b.id).first())?.n).toBe(2);
  });

  it('retains the nomination when the payer leaves and blocks vacant-payer claims until acceptance', async () => {
    const a = await plusOwner(), b = await plusOwner(), c = await plusOwner(), f = await create(a);
    await admit(a, b, f); await admit(a, c, f, 2);
    const nominationId = await nominate(a, b, f, 3);
    ok(await invoke(a, `${root}/${f}/leave`, body(4)));
    expect(ok(await invoke(b, `${root}/${f}/payer`))).toMatchObject({ sharingStatus: 'paused', nominationPending: true, canClaimPayer: false });
    expect((await invoke(c, `${root}/${f}/payer/claim`, body(5))).data.error.code).toBe('family_notebook_claim_unavailable');
    ok(await invoke(b, `${root}/${f}/payer/accept`, body(5, { nominationId })));
    expect(ok(await invoke(c, `${root}/${f}/payer`))).toMatchObject({ payerPersonId: b.id, role: 'member', sharingStatus: 'active' });
    expect((await db.prepare('SELECT state FROM family_notebook_members WHERE family_id=? AND person_id=?').bind(f, a.id).first())?.state).toBe('left');
  });

  it('invalidates a departed recipient and lets the recipient decline without buying Plus or leaving', async () => {
    const a = await plusOwner(), b = await person(), c = await plusOwner(), f = await create(a);
    await admit(a, b, f); await admit(a, c, f, 2);
    const nominationId = await nominate(a, b, f, 3);
    ok(await invoke(a, `${root}/${f}/leave`, body(4)));
    ok(await invoke(b, `${root}/${f}/payer/cancel`, body(5, { nominationId })));
    expect(ok(await invoke(c, `${root}/${f}/payer`))).toMatchObject({ nominationPending: false, canClaimPayer: true });
    ok(await invoke(c, `${root}/${f}/payer/claim`, body(6)));
    await nominate(c, b, f, 7); ok(await invoke(b, `${root}/${f}/leave`, body(8)));
    expect(ok(await invoke(c, `${root}/${f}/payer/handover`))).toMatchObject({ nominationId: null, nomineePersonId: null, canNominate: true });
  });

  it('rejects old acceptance after cancel/re-nominate and atomically chooses accept versus cancellation', async () => {
    const a = await plusOwner(), b = await plusOwner(), f = await create(a); await admit(a, b, f);
    const first = await nominate(a, b, f, 2);
    ok(await invoke(a, `${root}/${f}/payer/cancel`, body(3, { nominationId: first })));
    const second = await nominate(a, b, f, 4);
    expect((await invoke(b, `${root}/${f}/payer/accept`, body(5, { nominationId: first }))).data.error.code).toBe('family_notebook_nomination_changed');
    const replies = await Promise.all([invoke(b, `${root}/${f}/payer/accept`, body(5, { nominationId: second })),
      invoke(a, `${root}/${f}/payer/cancel`, body(5, { nominationId: second }))]);
    expect(replies.map(r => r.status).sort()).toEqual([200, 409]);
    expect((await db.prepare('SELECT generation FROM family_notebook_spaces WHERE id=?').bind(f).first())?.generation).toBe(6);
  });

  it('rechecks recipient Plus and membership when acceptance commits', async () => {
    const a = await plusOwner(), b = await plusOwner(), f = await create(a); await admit(a, b, f);
    const nominationId = await nominate(a, b, f, 2), request = body(3, { nominationId });
    expect((await invoke(b, `${root}/${f}/payer/accept`, request, beforeCommit(() => pauseOwner(b)))).data.error.code).toBe('plus_entitlement_required');
    expect(ok(await invoke(a, `${root}/${f}/payer/handover`)).nominationId).toBe(nominationId);
    await b.verified.refresh({}, 1);
    const env = beforeCommit(async () => { ok(await invoke(b, `${root}/${f}/leave`, body(3))); });
    expect((await invoke(b, `${root}/${f}/payer/accept`, request, env)).status).toBe(404);
    expect(ok(await invoke(a, `${root}/${f}/payer/handover`)).nominationId).toBe(null);
  });

  it('retains members/history and durable receipts on removal and dissolution, even during a Plus pause', async () => {
    const a = await plusOwner(), b = await person(), f = await create(a); await admit(a, b, f);
    // Opaque synthetic history rows solely for deletion-retention checks.
    await db.batch([db.prepare('INSERT INTO family_notebook_crypto_rosters VALUES (?,1,?,?)').bind(f, cipher(), '{}'),
      db.prepare('INSERT INTO family_notebook_crypto_operations VALUES (?,1,?,1,?,?,?)').bind(f, crypto.randomUUID(), a.id, a.deviceId, '{"synthetic":true}')]);
    await nominate(a, b, f, 2); await pauseOwner(a);
    expect((await invoke(b, `${root}/${f}/members/${a.id}/remove`, body(3))).status).toBe(403);
    const remove = body(3); ok(await invoke(a, `${root}/${f}/members/${b.id}/remove`, remove));
    expect(ok(await invoke(a, `${root}/${f}/payer/handover`)).nominationId).toBe(null);
    expect((await invoke(b, `${root}/${f}/crypto/operations/0`)).status).toBe(404);
    const dissolve = body(4), receipt = ok(await invoke(a, `${root}/${f}/dissolve`, dissolve));
    expect(ok(await invoke(a, `${root}/${f}/dissolve`, dissolve))).toEqual(receipt);
    expect(ok(await invoke(a, `${root}/${f}/members/${b.id}/remove`, remove)).action).toBe('remove');
    expect((await invoke(a, `${root}/${f}/payer`)).status).toBe(404);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_members WHERE family_id=?').bind(f).first())?.n).toBe(2);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_operations WHERE family_id=?').bind(f).first())?.n).toBe(1);
    expect((await db.prepare('SELECT state FROM family_notebook_spaces WHERE id=?').bind(f).first())?.state).toBe('closed');
  });
});
