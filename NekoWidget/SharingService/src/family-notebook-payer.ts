import { authenticateGroupRequest, groupId, groupNonceStatements, type GroupActor } from './group-auth';
import { billingEffectiveEntitlementRuntimeEnabled, type Env } from './env';
import { ApiError, jsonResponse } from './errors';
import { parseJsonBody, requireEmptyBody } from './http';
import { exactKeys, integerField, uuidField } from './validation';

// The independent family router also requires FAMILY_NOTEBOOK_API_RUNTIME_ENABLED.
// This transaction gate alone never exposes an HTTP route. Photo-window
// membership must never be treated as family consent.
type Operation = 'leave' | 'claim';
interface FamilyRow {
  generation: number;
  payer_person_id: string | null;
  payer_absent_since_generation: number | null;
  nominated_person_id: string | null;
  admitted_generation: number;
  payer_plus: number;
  member_plus: number;
}
interface Receipt {
  actor_person_id: string;
  family_id: string;
  request_hash: string;
  operation: Operation;
  resulting_generation: number;
}
export interface FamilyNotebookPayerState {
  schemaVersion: 1;
  familyId: string;
  generation: number;
  sharingStatus: 'active' | 'paused';
  pauseReason: 'no_payer' | 'payer_plus_unverified' | null;
  payerPersonId: string | null;
  role: 'payer' | 'member';
  nominationPending: boolean;
  canClaimPayer: boolean;
  canRemoveMember: boolean;
  canDissolve: boolean;
}

export function storeEnvironment(env: Env): 'Production' | 'Sandbox' | null {
  if (!billingEffectiveEntitlementRuntimeEnabled(env)) return null;
  if (env.BILLING_STORE_ENVIRONMENT === 'Production') return 'Production';
  if (env.BILLING_STORE_ENVIRONMENT === 'Sandbox' && ['local', 'staging'].includes(env.ENVIRONMENT)) return 'Sandbox';
  return null;
}
export async function gate(env: Env): Promise<void> {
  if (env.FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED !== 'YES') {
    throw new ApiError(503, 'family_notebook_disabled', 'Family notebooks are unavailable.');
  }
  const row = await env.DB.prepare('SELECT enabled FROM family_notebook_runtime_gate WHERE singleton=1').first<{ enabled: number }>();
  if (row?.enabled !== 1) throw new ApiError(503, 'family_notebook_disabled', 'Family notebooks are unavailable.');
}
export function safeFailure(error: unknown): never {
  if (error instanceof ApiError) throw error;
  const message = error instanceof Error ? error.message : '';
  const codes: [string, number, string][] = [
    ['family_notebook_disabled', 503, 'family_notebook_disabled'],
    ['family_notebook_invalid_authentication', 401, 'invalid_authentication'],
    ['group_invalid_authentication', 401, 'invalid_authentication'],
    ['family_notebook_not_member', 404, 'not_found'],
    ['family_notebook_stale_generation', 409, 'family_notebook_stale_generation'],
    ['family_notebook_claim_unavailable', 409, 'family_notebook_claim_unavailable'],
    ['family_notebook_plus_required', 403, 'plus_entitlement_required'],
    ['family_notebook_already_in_family', 409, 'family_notebook_already_in_family'],
    ['family_notebook_invitation_unavailable', 410, 'family_notebook_invitation_unavailable'],
    ['family_notebook_request_not_pending', 409, 'family_notebook_request_not_pending'],
    ['family_notebook_not_allowed', 403, 'family_notebook_not_allowed'],
    ['family_notebook_member_limit', 409, 'family_notebook_member_limit'],
    ['family_notebook_rate_limited', 429, 'rate_limited'],
    ['family_notebook_paused', 403, 'family_notebook_paused'],
    ['family_notebook_crypto_stale', 409, 'family_notebook_crypto_stale'],
    ['family_notebook_nomination_changed', 409, 'family_notebook_nomination_changed'],
    ['group_request_nonces.device_id', 401, 'replay'],
  ];
  for (const [marker, status, code] of codes) {
    if (message.includes(marker)) throw new ApiError(status, code, 'The family operation could not be completed.');
  }
  // Storage/network failures are unknown outcomes, never proof of departure
  // or authority to become payer. No SQL, body, signature or billing ID leaks.
  throw new ApiError(503, 'family_notebook_unavailable', 'The family state could not be confirmed.');
}
function selectFamily(env: Env, actor: GroupActor, familyId: string): D1PreparedStatement {
  const environment = storeEnvironment(env);
  return env.DB.prepare(`SELECT f.generation,f.payer_person_id,f.payer_absent_since_generation,
      f.nominated_person_id,m.admitted_generation,
      EXISTS(SELECT 1 FROM group_verified_plus_people WHERE person_id=f.payer_person_id AND environment=?) AS payer_plus,
      EXISTS(SELECT 1 FROM group_verified_plus_people WHERE person_id=m.person_id AND environment=?) AS member_plus
    FROM family_notebook_spaces f JOIN family_notebook_members m ON m.family_id=f.id
    WHERE f.id=? AND f.state='active' AND m.person_id=? AND m.state='active'`)
    .bind(environment, environment, familyId, actor.personId);
}
async function load(env: Env, actor: GroupActor, familyId: string): Promise<FamilyRow> {
  const row = await selectFamily(env, actor, familyId).first<FamilyRow>();
  if (!row) throw new ApiError(404, 'not_found', 'The family was not found.');
  return row;
}
function presentation(actor: GroupActor, familyId: string, row: FamilyRow): FamilyNotebookPayerState {
  const noPayer = row.payer_person_id === null;
  const payer = row.payer_person_id === actor.personId;
  // An unverifiable/expired payer keeps their role. Never reinterpret a
  // billing outage as a vacant payer slot or tell another member to take it.
  const reason = noPayer ? 'no_payer' : row.payer_plus === 1 ? null : 'payer_plus_unverified';
  return {
    schemaVersion: 1, familyId, generation: row.generation,
    sharingStatus: reason === null ? 'active' : 'paused', pauseReason: reason,
    payerPersonId: row.payer_person_id, role: payer ? 'payer' : 'member',
    nominationPending: row.nominated_person_id !== null,
    canClaimPayer: noPayer && row.nominated_person_id === null && row.member_plus === 1
      && row.payer_absent_since_generation !== null && row.admitted_generation <= row.payer_absent_since_generation,
    canRemoveMember: payer, canDissolve: payer,
  };
}
function receiptResponse(operationId: string, row: Receipt): Response {
  // This is a historical operation receipt, not a cached grant of payer
  // authority. The app must refresh current state for role/permissions.
  return jsonResponse({ schemaVersion: 1, operationId, familyId: row.family_id,
    operation: row.operation, appliedGeneration: row.resulting_generation });
}

/** Authenticated handler behind the separate family API and transaction gates. */
export async function familyNotebookPayer(request: Request, env: Env, familyValue: string,
  operation?: Operation): Promise<Response> {
  try {
    await gate(env);
    const familyId = groupId(familyValue);
    const path = `/v3/family-notebooks/${familyId}` + (operation === 'leave' ? '/leave' : operation === 'claim' ? '/payer/claim' : '/payer');
    if (new URL(request.url).pathname !== path) throw new ApiError(404, 'not_found', 'The family was not found.');
    if (operation === undefined ? request.method !== 'GET' : request.method !== 'POST') {
      throw new ApiError(405, 'method_not_allowed', 'Unsupported family operation.');
    }
    const { actor, body: bytes } = await authenticateGroupRequest(request, env, 2048);
    if (operation === undefined) {
      requireEmptyBody(bytes);
      const row = await load(env, actor, familyId);
      const checkId = crypto.randomUUID();
      const result = await env.DB.batch<FamilyRow>([...groupNonceStatements(env, actor),
        env.DB.prepare('INSERT INTO family_notebook_access_checks VALUES (?,?,?,?,?)').bind(checkId, familyId, actor.personId, actor.deviceId, row.generation),
        env.DB.prepare('DELETE FROM family_notebook_access_checks WHERE id=?').bind(checkId),
        selectFamily(env, actor, familyId)]);
      const current = result.at(-1)?.results[0];
      if (!current) throw new ApiError(503, 'family_notebook_unavailable', 'The family state could not be confirmed.');
      return jsonResponse(presentation(actor, familyId, current));
    }
    const body = parseJsonBody(request, bytes);
    exactKeys(body, ['operationId', 'expectedGeneration']);
    const operationId = uuidField(body, 'operationId');
    const generation = integerField(body, 'expectedGeneration', 1, 1_000_000_000);
    const existing = await env.DB.prepare(`SELECT actor_person_id,family_id,request_hash,operation,resulting_generation
      FROM family_notebook_payer_events WHERE actor_device_id=? AND operation_id=?`)
      .bind(actor.deviceId, operationId).first<Receipt>();
    if (existing) {
      if (existing.actor_person_id !== actor.personId || existing.family_id !== familyId
        || existing.request_hash !== actor.requestHash || existing.operation !== operation) {
        throw new ApiError(409, 'idempotency_conflict', 'This operation has different content.');
      }
      // A departed member can recover only their own receipt, with fresh
      // active-device authentication; no family metadata or role is returned.
      await env.DB.batch(groupNonceStatements(env, actor));
      return receiptResponse(operationId, existing);
    }
    await load(env, actor, familyId);
    const environment = storeEnvironment(env);
    if (operation === 'claim' && environment === null) {
      throw new ApiError(503, 'billing_runtime_disabled', 'Membership verification is unavailable.');
    }
    await env.DB.batch([...groupNonceStatements(env, actor),
      env.DB.prepare(`INSERT INTO family_notebook_payer_events
        (actor_device_id,operation_id,request_hash,actor_person_id,family_id,operation,
         expected_generation,resulting_generation,store_environment)
        VALUES (?,?,?,?,?,?,?,?,?)`).bind(actor.deviceId, operationId, actor.requestHash, actor.personId,
        familyId, operation, generation, generation + 1, environment)]);
    return receiptResponse(operationId, { actor_person_id: actor.personId, family_id: familyId,
      request_hash: actor.requestHash, operation, resulting_generation: generation + 1 });
  } catch (error) { return safeFailure(error); }
}
