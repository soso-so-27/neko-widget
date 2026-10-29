import { authenticateGroupRequest, groupId, groupNonceStatements, type GroupActor } from './group-auth';
import { gate, safeFailure, storeEnvironment } from './family-notebook-payer';
import { familyUUID } from './family-notebook-crypto';
import { ApiError, jsonResponse } from './errors';
import { parseJsonBody, requireEmptyBody } from './http';
import { exactKeys, integerField, stringField, uuidField } from './validation';
import type { Env } from './env';

type Action = 'remove' | 'dissolve' | 'nominate' | 'accept' | 'cancel';
interface State {
  generation: number; payer_person_id: string | null; nominated_person_id: string | null;
  nomination_id: string | null; nominee_person_id: string | null; nominee_active: number; member_plus: number;
}
interface Receipt {
  actor_person_id: string; family_id: string; request_hash: string; action: Action;
  target_person_id: string | null; nomination_id: string | null; resulting_generation: number;
}
function query(env: Env, actor: GroupActor, family: string): D1PreparedStatement {
  return env.DB.prepare(`SELECT f.generation,f.payer_person_id,f.nominated_person_id,h.nomination_id,h.nominee_person_id,
    EXISTS(SELECT 1 FROM family_notebook_members n JOIN group_people p ON p.id=n.person_id AND p.state='active'
      WHERE n.family_id=f.id AND n.person_id=h.nominee_person_id AND n.state='active') AS nominee_active,
    EXISTS(SELECT 1 FROM group_verified_plus_people WHERE person_id=m.person_id AND environment=?) AS member_plus
    FROM family_notebook_spaces f JOIN family_notebook_members m ON m.family_id=f.id
    LEFT JOIN family_notebook_handover_current h ON h.family_id=f.id
    WHERE f.id=? AND f.state='active' AND m.person_id=? AND m.state='active'`)
    .bind(storeEnvironment(env), family, actor.personId);
}
function response(operationId: string, receipt: Receipt): Response {
  return jsonResponse({ schemaVersion: 1, familyId: receipt.family_id, operationId, action: receipt.action,
    targetPersonId: receipt.target_person_id, nominationId: receipt.nomination_id, appliedGeneration: receipt.resulting_generation });
}
// Internal handler until production membership/admission is connected. No
// route, gate, deployment, subscription purchase or refund is added here.
export async function familyNotebookGovernance(request: Request, env: Env): Promise<Response> {
  try {
    await gate(env);
    const url = new URL(request.url);
    const match = /^\/v3\/family-notebooks\/([0-9a-f-]+)\/(payer\/(handover|nominate|accept|cancel)|dissolve|members\/([A-Za-z0-9_-]+)\/remove)$/u.exec(url.pathname);
    if (!match || url.search) throw new ApiError(404, 'not_found', 'Unknown family operation.');
    const family = familyUUID(match[1]), read = match[3] === 'handover';
    if (request.method !== (read ? 'GET' : 'POST')) throw new ApiError(405, 'method_not_allowed', 'Unsupported family operation.');
    const { actor, body: bytes } = await authenticateGroupRequest(request, env, 4096);
    if (read) {
      requireEmptyBody(bytes);
      const state = await query(env, actor, family).first<State>();
      if (!state) throw new ApiError(404, 'not_found', 'The family was not found.');
      const checkId = crypto.randomUUID();
      const batch = await env.DB.batch<State>([...groupNonceStatements(env, actor),
        env.DB.prepare('INSERT INTO family_notebook_access_checks VALUES (?,?,?,?,?)').bind(checkId, family, actor.personId, actor.deviceId, state.generation),
        env.DB.prepare('DELETE FROM family_notebook_access_checks WHERE id=?').bind(checkId), query(env, actor, family)]);
      const current = batch.at(-1)?.results[0];
      if (!current) throw new ApiError(503, 'family_notebook_unavailable', 'The family state could not be confirmed.');
      const payer = current.payer_person_id === actor.personId;
      const nominated = current.nominee_person_id === actor.personId;
      const consistent = current.nominated_person_id === current.nominee_person_id
        && ((current.nomination_id === null) === (current.nominee_person_id === null));
      return jsonResponse({ schemaVersion: 1, familyId: family, generation: current.generation, payerPersonId: current.payer_person_id,
        nominationId: current.nomination_id, nomineePersonId: current.nominee_person_id,
        canNominate: consistent && payer && current.nomination_id === null,
        canAccept: consistent && nominated && current.nominee_active === 1 && current.member_plus === 1,
        canCancel: consistent && current.nomination_id !== null && (payer || nominated),
        nominationState: consistent ? 'confirmed' : 'unavailable' });
    }
    const action: Action = match[4] ? 'remove' : match[2] === 'dissolve' ? 'dissolve' : match[3] as Action;
    const body = parseJsonBody(request, bytes);
    exactKeys(body, ['operationId', 'expectedGeneration', ...(action === 'nominate' ? ['personId'] : ['accept', 'cancel'].includes(action) ? ['nominationId'] : [])]);
    const operationId = uuidField(body, 'operationId'), generation = integerField(body, 'expectedGeneration', 1, 1_000_000_000);
    const prior = await env.DB.prepare(`SELECT actor_person_id,family_id,request_hash,action,target_person_id,nomination_id,resulting_generation
      FROM family_notebook_governance_events WHERE actor_device_id=? AND operation_id=?`).bind(actor.deviceId, operationId).first<Receipt>();
    if (prior) {
      if (prior.actor_person_id !== actor.personId || prior.family_id !== family || prior.action !== action || prior.request_hash !== actor.requestHash) {
        throw new ApiError(409, 'idempotency_conflict', 'This operation has different content.');
      }
      await env.DB.batch(groupNonceStatements(env, actor)); return response(operationId, prior);
    }
    let target = action === 'remove' ? groupId(match[4]!) : action === 'nominate' ? groupId(stringField(body, 'personId')) : null;
    const nominationId = action === 'nominate' ? operationId : ['accept', 'cancel'].includes(action) ? uuidField(body, 'nominationId') : null;
    if (action === 'accept' || action === 'cancel') {
      const current = await query(env, actor, family).first<State>();
      if (!current || current.nomination_id !== nominationId || current.nominee_person_id !== current.nominated_person_id) {
        throw new ApiError(409, 'family_notebook_nomination_changed', 'Reload the current nomination.');
      }
      target = current.nominee_person_id;
      if (action === 'accept' && !storeEnvironment(env)) throw new ApiError(503, 'family_notebook_unavailable', 'Plus could not be confirmed.');
    }
    await env.DB.batch([...groupNonceStatements(env, actor),
      env.DB.prepare(`INSERT INTO family_notebook_governance_events
        (actor_device_id,operation_id,actor_person_id,family_id,request_hash,action,target_person_id,nomination_id,
          expected_generation,resulting_generation,store_environment) VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
        .bind(actor.deviceId, operationId, actor.personId, family, actor.requestHash, action, target, nominationId, generation, generation + 1, storeEnvironment(env))]);
    return response(operationId, { actor_person_id: actor.personId, family_id: family, request_hash: actor.requestHash, action,
      target_person_id: target, nomination_id: nominationId, resulting_generation: generation + 1 });
  } catch (error) { safeFailure(error); }
}
