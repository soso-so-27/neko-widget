import { describe, expect, it } from 'vitest';
import { route } from '../src/index';
import { familyNotebookPayer } from '../src/family-notebook-payer';
import { errorResponse } from '../src/errors';
import type { Env } from '../src/env';
import { connection, billing, gates, pauseOwner, plusOwner, settings } from './group-billing-fixture';
import { create, db, ok, person, send, signed, type Person, type Reply } from './group-fixture';

const enabled: Env = { ...settings, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES', FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'YES' };
type Operation = 'leave' | 'claim';
function path(id: string, operation?: Operation) {
  return `/v3/family-notebooks/${id}` + (operation === 'leave' ? '/leave' : operation === 'claim' ? '/payer/claim' : '/payer');
}
async function call(p: Person, id: string, operation?: Operation, generation = 1,
  operationId = crypto.randomUUID(), env: Env = enabled): Promise<Reply> {
  const request = await signed(p, path(id, operation), operation ? { operationId, expectedGeneration: generation } : undefined);
  let response: Response;
  try { response = await route(request, env); }
  catch (error) { response = errorResponse(error); }
  return { status: response.status, data: await response.json() as Reply['data'] };
}
// No production family admission exists. Synthetic admitted members are seeded
// ONLY here; identity registration and billing connection still use their real
// signed HTTP handlers, and payer changes use actual D1 constraints/triggers.
async function family(members: readonly Person[], payer: Person | null, nominee: Person | null = null,
  terminal?: Person) {
  await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run();
  const id = crypto.randomUUID();
  await db.batch([
    db.prepare(`INSERT INTO family_notebook_spaces VALUES (?,1,'active',?,?,?,unixepoch(),unixepoch())`)
      .bind(id, payer?.id ?? null, payer ? null : 1, nominee?.id ?? null),
    ...members.map(p => db.prepare('INSERT INTO family_notebook_members VALUES (?,?,?,?,?)')
      .bind(id, p.id, p === terminal ? 'removed' : 'active', 1, p === terminal ? 1 : null)),
  ]);
  return id;
}
async function state(id: string) {
  return db.prepare('SELECT * FROM family_notebook_spaces WHERE id=?').bind(id).first();
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

describe('family notebook payer: authenticated, atomic, not publicly connected', () => {
  it('defaults OFF and has no public route even with the explicit future gate enabled', async () => {
    expect(await db.prepare('SELECT enabled FROM family_notebook_runtime_gate WHERE singleton=1').first()).toEqual({ enabled: 0 });
    const p = await person(), id = crypto.randomUUID();
    expect((await call(p, id)).data.error.code).toBe('family_notebook_disabled');
    const f = await family([p], p);
    expect((await call(p, f, undefined, 1, crypto.randomUUID(), { ...enabled, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'NO' })).status).toBe(503);
    expect((await send(await signed(p, path(f)), { ...enabled, FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'NO' })).status).toBe(404);
  });

  it('retains the family and other members when the payer leaves, then lets an already-Plus member claim', async () => {
    const payer = await plusOwner(), remaining = await plusOwner(), free = await person();
    const photoWindow = await create(payer);
    const photoBefore = await db.prepare('SELECT * FROM group_windows WHERE space_id=?').bind(photoWindow.windowId).first();
    const f = await family([payer, remaining, free], payer), op = crypto.randomUUID();
    expect(ok(await call(payer, f, 'leave', 1, op))).toMatchObject({ operation: 'leave', appliedGeneration: 2 });
    expect(ok(await call(remaining, f))).toMatchObject({ sharingStatus: 'paused', pauseReason: 'no_payer',
      payerPersonId: null, role: 'member', canClaimPayer: true, canRemoveMember: false, canDissolve: false });
    expect(ok(await call(free, f))).toMatchObject({ canClaimPayer: false });
    expect((await call(payer, f)).status).toBe(404);
    expect((await call(payer, f, 'claim', 2)).status).toBe(404);
    // A lost departure response is recoverable without restoring membership.
    expect(ok(await call(payer, f, 'leave', 1, op))).toEqual({ schemaVersion: 1, operationId: op, familyId: f,
      operation: 'leave', appliedGeneration: 2 });
    ok(await call(remaining, f, 'claim', 2));
    expect(ok(await call(remaining, f))).toMatchObject({ generation: 3, sharingStatus: 'active', pauseReason: null,
      payerPersonId: remaining.id, role: 'payer', canRemoveMember: true, canDissolve: true, canClaimPayer: false });
    expect(ok(await call(free, f))).toMatchObject({ role: 'member', canRemoveMember: false, canDissolve: false });
    expect(await db.prepare('SELECT state FROM family_notebook_members WHERE family_id=? ORDER BY state').bind(f).all())
      .toMatchObject({ results: [{ state: 'active' }, { state: 'active' }, { state: 'left' }] });
    expect(await db.prepare('SELECT * FROM group_windows WHERE space_id=?').bind(photoWindow.windowId).first()).toEqual(photoBefore);
  });

  it('commits exactly one of two simultaneous Plus claims and leaves both subscriptions unchanged', async () => {
    const a = await plusOwner(), b = await plusOwner('FAMILY_SHARED'), f = await family([a, b], null);
    const before = await db.prepare('SELECT * FROM billing_effective_entitlement_current WHERE billing_account_id IN (?,?) ORDER BY billing_account_id')
      .bind(a.account.id, b.account.id).all();
    const operations = [crypto.randomUUID(), crypto.randomUUID()];
    const results = await Promise.all([call(a, f, 'claim', 1, operations[0]), call(b, f, 'claim', 1, operations[1])]);
    expect(results.map(r => r.status).sort()).toEqual([200, 409]);
    const winnerIndex = results[0]!.status === 200 ? 0 : 1, winner = winnerIndex === 0 ? a : b, loser = winnerIndex === 0 ? b : a;
    expect((await state(f))?.payer_person_id).toBe(winner.id);
    expect(ok(await call(loser, f))).toMatchObject({ role: 'member', canClaimPayer: false, canRemoveMember: false, canDissolve: false });
    expect(ok(await call(winner, f, 'claim', 1, operations[winnerIndex]))).toEqual(results[winnerIndex]!.data);
    expect((await call(winner, f, 'claim', 2, operations[winnerIndex])).data.error.code).toBe('idempotency_conflict');
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_payer_events WHERE family_id=?').bind(f).first())?.n).toBe(1);
    expect((await db.prepare('SELECT * FROM billing_effective_entitlement_current WHERE billing_account_id IN (?,?) ORDER BY billing_account_id')
      .bind(a.account.id, b.account.id).all()).results).toEqual(before.results);
  });

  it('rejects another family, removed members, an invalid signature and request replay', async () => {
    const a = await plusOwner(), removed = await plusOwner(), outsider = await plusOwner(), f = await family([a, removed], null, null, removed);
    expect((await call(outsider, f, 'claim')).status).toBe(404);
    expect((await call(removed, f, 'claim')).status).toBe(404);
    const request = await signed(a, path(f));
    const copy = () => new Request(request.url, { headers: new Headers(request.headers) });
    await expect(familyNotebookPayer(copy(), enabled, crypto.randomUUID())).rejects.toMatchObject({ status: 404 });
    const headers = new Headers(request.headers); headers.set('neko-signature', 'invalid');
    const forged = new Request(request.url, { headers });
    await expect(familyNotebookPayer(forged, enabled, f)).rejects.toMatchObject({ status: 401 });
    await familyNotebookPayer(copy(), enabled, f);
    await expect(familyNotebookPayer(copy(), enabled, f)).rejects.toMatchObject({ status: 401, code: 'replay' });
    expect((await state(f))?.generation).toBe(1);
  });

  it('requires current verified Plus, not just a connection, expired authority, the wrong environment or a local flag', async () => {
    const p = await person(), account = await billing(); await gates();
    ok(await send((await connection(p, account)).request, settings));
    const f = await family([p], null);
    expect((await call(p, f, 'claim')).data.error.code).toBe('plus_entitlement_required');
    const plus = await plusOwner(), paid = await family([plus], null);
    for (const env of [{ ...enabled, BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: 'NO' },
      { ...enabled, BILLING_STORE_ENVIRONMENT: 'Production' }, { ...enabled, ENVIRONMENT: 'production' }]) {
      expect((await call(plus, paid, 'claim', 1, crypto.randomUUID(), env)).status).not.toBe(200);
    }
    await plus.verified.refresh({ expiresDateMs: Date.now() - 1 });
    expect((await call(plus, paid, 'claim')).data.error.code).toBe('plus_entitlement_required');
    await plus.verified.refresh({}, 1, Date.now() - 48 * 3600_000);
    expect((await call(plus, paid, 'claim')).data.error.code).toBe('plus_entitlement_required');
    expect((await state(paid))?.generation).toBe(1);
  });

  it('rechecks device revocation, paid authority and the runtime gate inside the committing transaction', async () => {
    for (const race of ['device', 'plus', 'gate'] as const) {
      const p = await plusOwner(), f = await family([p], null);
      const env = beforeCommit(async () => {
        if (race === 'device') await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(p.deviceId).run();
        if (race === 'plus') await pauseOwner(p);
        if (race === 'gate') await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=0,generation=generation+1 WHERE singleton=1').run();
      });
      const response = await call(p, f, 'claim', 1, crypto.randomUUID(), env);
      expect(response.status).not.toBe(200);
      expect(response.data.error.code).not.toBe('family_notebook_unavailable');
      expect((await state(f))?.payer_person_id).toBeNull();
      expect((await state(f))?.generation).toBe(1);
      expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_payer_events WHERE family_id=?').bind(f).first())?.n).toBe(0);
    }
  });

  it('rejects a claim when membership changes after the initial read, and does not overwrite a current payer', async () => {
    const p = await plusOwner(), other = await person(), f = await family([p, other], null);
    const env = beforeCommit(async () => { ok(await call(p, f, 'leave')); });
    expect((await call(p, f, 'claim', 1, crypto.randomUUID(), env)).status).toBe(404);
    expect((await state(f))?.generation).toBe(2);
    const current = await plusOwner(), challenger = await plusOwner(), active = await family([current, challenger], current);
    await pauseOwner(current);
    expect(ok(await call(challenger, active))).toMatchObject({ sharingStatus: 'paused', pauseReason: 'payer_plus_unverified', canClaimPayer: false });
    expect((await call(challenger, active, 'claim')).data.error.code).toBe('family_notebook_claim_unavailable');
    expect((await state(active))?.payer_person_id).toBe(current.id);
  });

  it('keeps explicit nominations separate and refuses direct payer rewrites without an exact event', async () => {
    const p = await plusOwner(), nominee = await plusOwner(), f = await family([p, nominee], p, nominee);
    ok(await call(p, f, 'leave'));
    expect(ok(await call(nominee, f))).toMatchObject({ sharingStatus: 'paused', pauseReason: 'no_payer',
      nominationPending: true, canClaimPayer: false, canRemoveMember: false });
    expect((await call(nominee, f, 'claim', 2)).data.error.code).toBe('family_notebook_claim_unavailable');
    await expect(db.prepare('UPDATE family_notebook_spaces SET payer_person_id=?,payer_absent_since_generation=NULL,generation=3 WHERE id=?')
      .bind(nominee.id, f).run()).rejects.toThrow('family_notebook_payer_audit_required');
    expect((await state(f))?.nominated_person_id).toBe(nominee.id);
    expect((await state(f))?.payer_person_id).toBeNull();
    await expect(db.prepare('DELETE FROM family_notebook_members WHERE family_id=?').bind(f).run()).rejects.toThrow('family_notebook_members_retained');
  });

  it('refuses a stale state response if the payer changes between the read and authorization commit', async () => {
    const p = await plusOwner(), member = await plusOwner(), f = await family([p, member], p);
    const env = beforeCommit(async () => { ok(await call(p, f, 'leave')); });
    expect((await call(member, f, undefined, 1, crypto.randomUUID(), env)).data.error.code).toBe('family_notebook_stale_generation');
    expect(ok(await call(member, f))).toMatchObject({ generation: 2, role: 'member', pauseReason: 'no_payer', canDissolve: false });
  });

  it('refreshes verified entitlement in the same transaction as the state response', async () => {
    const p = await plusOwner(), member = await person(), f = await family([p, member], p);
    const env = beforeCommit(async () => { await pauseOwner(p); });
    expect(ok(await call(member, f, undefined, 1, crypto.randomUUID(), env))).toMatchObject({
      generation: 1, sharingStatus: 'paused', pauseReason: 'payer_plus_unverified', canClaimPayer: false });
  });
});
