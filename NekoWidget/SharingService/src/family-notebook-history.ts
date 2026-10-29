import { authenticateGroupRequest, groupNonceStatements, type GroupActor } from './group-auth';
import { base64urlDecode, verifyEd25519 } from './encoding';
import { groupDeviceAuthorization } from './group-protocol';
import { familyUUID, verifyFamilyRoster, verifyFamilyEnvelope, verifyFamilyOperation, type VerifiedFamilyCryptoRoster } from './family-notebook-crypto';
import { gate, safeFailure, storeEnvironment } from './family-notebook-payer';
import { ApiError, jsonResponse } from './errors';
import { parseJsonBody, requireEmptyBody } from './http';
import { asObject, binaryField, exactKeys, integerField, uuidField } from './validation';
import type { Env } from './env';

// Deliberately not in the public router. The native service/consent and key
// delivery lifecycle must be connected before this becomes externally usable.
type Action = 'device' | 'roster' | 'key' | 'operation';
interface Receipt { actor_person_id: string; family_id: string; action: Action; request_hash: string; result: string }
interface State { generation: number; epoch: number; packet: string | null; roster_hash: string | null }
function unavailable(code = 'family_notebook_crypto_stale'): never {
  throw new ApiError(409, code, 'Reload the current family state.');
}
async function state(env: Env, actor: GroupActor, family: string): Promise<State> {
  const row = await env.DB.prepare(`SELECT f.generation,COALESCE(h.epoch,0) AS epoch,r.packet,r.roster_hash
    FROM family_notebook_spaces f JOIN family_notebook_members m ON m.family_id=f.id
    LEFT JOIN family_notebook_crypto_heads h ON h.family_id=f.id
    LEFT JOIN family_notebook_crypto_rosters r ON r.family_id=h.family_id AND r.epoch=h.epoch
    WHERE f.id=? AND f.state='active' AND m.person_id=? AND m.state='active'`)
    .bind(family, actor.personId).first<State>();
  if (!row) throw new ApiError(404, 'not_found', 'The family was not found.');
  return row;
}
function checks(env: Env, actor: GroupActor, family: string, generation: number, epoch: number | null,
  mode: 'read' | 'ready' | Action): D1PreparedStatement[] {
  const id = crypto.randomUUID();
  return [env.DB.prepare('INSERT INTO family_notebook_crypto_checks VALUES (?,?,?,?,?,?,?,?)')
    .bind(id, family, actor.personId, actor.deviceId, generation, epoch, mode, storeEnvironment(env)),
    env.DB.prepare('DELETE FROM family_notebook_crypto_checks WHERE id=?').bind(id)];
}
async function roster(env: Env, family: string, epoch: number): Promise<VerifiedFamilyCryptoRoster> {
  const row = await env.DB.prepare('SELECT packet,roster_hash FROM family_notebook_crypto_rosters WHERE family_id=? AND epoch=?')
    .bind(family, epoch).first<{ packet: string; roster_hash: string }>();
  if (!row) unavailable();
  // Only packets verified at their atomic append are stored here; immutable
  // per-family epochs and CAS ensure they are on one chain. Clients also verify.
  const value = await verifyFamilyRoster(JSON.parse(row.packet));
  if (value.hash !== row.roster_hash || familyUUID(value.packet.roster.familyId) !== family || value.packet.roster.epoch !== epoch) unavailable();
  return value;
}
export async function familyNotebookHistory(request: Request, env: Env): Promise<Response> {
  try {
    await gate(env);
    const path = new URL(request.url);
    const match = /^\/v3\/family-notebooks\/([0-9a-f-]+)\/crypto\/(state|devices|rosters|keys|operations)(?:\/(\d+))?$/u.exec(path.pathname);
    if (!match || path.search || !['GET', 'POST'].includes(request.method)) throw new ApiError(404, 'not_found', 'Unknown family operation.');
    const family = familyUUID(match[1]), route = match[2]!, number = match[3] === undefined ? undefined : Number(match[3]);
    if (number !== undefined && (!Number.isSafeInteger(number) || number < 0 || number > 1_000_000_000 || String(number) !== match[3])) unavailable();
    const { actor, body: bytes } = await authenticateGroupRequest(request, env, 1_500_000);
    if (request.method === 'GET') {
      requireEmptyBody(bytes);
      return await read(env, actor, family, route, number);
    }
    if (number !== undefined || route === 'state') throw new ApiError(405, 'method_not_allowed', 'Unsupported family operation.');
    const action: Action = route === 'devices' ? 'device' : route === 'rosters' ? 'roster' : route === 'keys' ? 'key' : 'operation';
    const body = parseJsonBody(request, bytes); exactKeys(body, ['operationId', 'expectedGeneration', 'expectedEpoch', 'payload']);
    const operationId = uuidField(body, 'operationId'), generation = integerField(body, 'expectedGeneration', 1, 1_000_000_000);
    const epoch = integerField(body, 'expectedEpoch', 0, 1_000_000_000);
    const previous = await env.DB.prepare('SELECT actor_person_id,family_id,action,request_hash,result FROM family_notebook_crypto_receipts WHERE actor_device_id=? AND operation_id=?')
      .bind(actor.deviceId, operationId).first<Receipt>();
    if (previous) {
      if (previous.actor_person_id !== actor.personId || previous.family_id !== family || previous.action !== action || previous.request_hash !== actor.requestHash) {
        throw new ApiError(409, 'idempotency_conflict', 'This operation has different content.');
      }
      await env.DB.batch(groupNonceStatements(env, actor));
      return jsonResponse(JSON.parse(previous.result));
    }
    const current = await state(env, actor, family);
    if (generation !== current.generation || epoch !== current.epoch) unavailable();
    const statements: D1PreparedStatement[] = [...groupNonceStatements(env, actor), ...checks(env, actor, family, generation, epoch, action)];
    const payload = asObject(body.payload);
    let appliedEpoch = epoch;
    if (action === 'device') {
      exactKeys(payload, ['personAuthorization']);
      const authorization = binaryField(payload, 'personAuthorization', 64);
      const device = { id: actor.deviceId, signingPublicKey: actor.signingPublicKey, hpkePublicKey: actor.hpkePublicKey, personAuthorization: authorization };
      if (!await verifyEd25519(actor.identityPublicKey, authorization, groupDeviceAuthorization(family, actor.personId, device))) {
        throw new ApiError(400, 'invalid_family_proof', 'The device authorization could not be verified.');
      }
      // Roots/device keys are the existing authenticated identity, not client
      // claims. This explicit family certificate is independent of photo rooms.
      statements.push(env.DB.prepare(`INSERT INTO family_notebook_crypto_devices VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(family_id,device_id) DO NOTHING`).bind(family, actor.deviceId, actor.personId, actor.identityPublicKey,
        actor.signingPublicKey, actor.hpkePublicKey, authorization));
    } else if (action === 'roster') {
      const prior = epoch === 0 ? undefined : await roster(env, family, epoch);
      const verified = await verifyFamilyRoster(payload, prior), r = verified.packet.roster;
      if (familyUUID(r.familyId) !== family || r.epoch !== epoch + 1 || verified.packet.signerDeviceId !== actor.deviceId) unavailable();
      if (epoch === 0) {
        const creator = await env.DB.prepare("SELECT actor_person_id FROM family_notebook_admission_events WHERE family_id=? AND operation='create'")
          .bind(family).first<{ actor_person_id: string }>();
        if (creator?.actor_person_id !== actor.personId) throw new ApiError(403, 'family_notebook_not_allowed', 'Only the creator can initialize encryption.');
      }
      appliedEpoch = r.epoch;
      statements.push(env.DB.prepare('INSERT INTO family_notebook_crypto_rosters VALUES (?,?,?,?)').bind(family, r.epoch, verified.hash, JSON.stringify(payload)),
        env.DB.prepare('INSERT INTO family_notebook_crypto_heads VALUES (?,?) ON CONFLICT(family_id) DO UPDATE SET epoch=excluded.epoch').bind(family, r.epoch),
        ...checks(env, actor, family, generation, r.epoch, 'ready'));
    } else if (action === 'key') {
      const sourceEpoch = integerField(payload, 'keyEpoch', 1, epoch);
      const verified = await verifyFamilyEnvelope(payload, await roster(env, family, epoch), await roster(env, family, sourceEpoch));
      if (verified.signerDeviceId !== actor.deviceId) throw new ApiError(403, 'family_notebook_not_allowed', 'Only the signer may send this key.');
      statements.push(env.DB.prepare(`INSERT INTO family_notebook_crypto_envelopes VALUES (?,?,?,?,?,?)
        ON CONFLICT(family_id,current_epoch,key_epoch,recipient_device_id,signer_device_id) DO UPDATE SET packet=excluded.packet`)
        .bind(family, epoch, sourceEpoch, verified.recipientDeviceId, actor.deviceId, JSON.stringify(payload)));
    } else {
      const verified = await verifyFamilyOperation(payload, await roster(env, family, epoch));
      if (verified.deviceId !== actor.deviceId || verified.personId !== actor.personId || familyUUID(verified.operationId) !== operationId) {
        throw new ApiError(403, 'family_notebook_not_allowed', 'Only the author may send this operation.');
      }
      // One logical operation ID for the family prevents a second device from
      // replacing an ACKed operation, including after a new roster is created.
      statements.push(env.DB.prepare(`INSERT INTO family_notebook_crypto_operations
        SELECT ?,COALESCE(MAX(sequence),0)+1,?,?,?,?,? FROM family_notebook_crypto_operations WHERE family_id=?`)
        .bind(family, operationId, epoch, actor.personId, actor.deviceId, JSON.stringify(payload), family));
    }
    const result = { schemaVersion: 1, familyId: family, operationId, action, appliedEpoch, requestHash: actor.requestHash };
    statements.push(env.DB.prepare('INSERT INTO family_notebook_crypto_receipts VALUES (?,?,?,?,?,?,?)')
      .bind(actor.deviceId, operationId, actor.personId, family, action, actor.requestHash, JSON.stringify(result)));
    await env.DB.batch(statements);
    return jsonResponse(result);
  } catch (error) { safeFailure(error); }
}

async function read(env: Env, actor: GroupActor, family: string, route: string, number?: number): Promise<Response> {
  const current = await state(env, actor, family);
  const statements = [...groupNonceStatements(env, actor), ...checks(env, actor, family, current.generation, current.epoch, 'read')];
  const base = { schemaVersion: 1, familyId: family, generation: current.generation, currentEpoch: current.epoch };
  if (route === 'state' && number === undefined) {
    statements.push(env.DB.prepare(`SELECT c.person_id,c.device_id,c.identity_public_key,c.signing_public_key,c.hpke_public_key,c.person_authorization
      FROM family_notebook_crypto_live_devices c WHERE family_id=? ORDER BY person_id,device_id`).bind(family),
      env.DB.prepare(`SELECT m.person_id FROM family_notebook_members m JOIN group_people p ON p.id=m.person_id AND p.state='active'
        WHERE m.family_id=? AND m.state='active' ORDER BY m.person_id`).bind(family),
      env.DB.prepare('SELECT epoch FROM family_notebook_crypto_ready WHERE family_id=?').bind(family));
    const batch = await env.DB.batch<Record<string, unknown>>(statements);
    return jsonResponse({ ...base, roster: current.packet ? JSON.parse(current.packet) : null,
      devices: batch.at(-3)!.results, people: batch.at(-2)!.results.map(r => r.person_id), ready: batch.at(-1)!.results.length === 1 });
  }
  if (route === 'rosters' && number !== undefined && number > 0 && number <= current.epoch) {
    statements.push(env.DB.prepare('SELECT packet FROM family_notebook_crypto_rosters WHERE family_id=? AND epoch=?').bind(family, number));
    const batch = await env.DB.batch<{ packet: string }>(statements), row = batch.at(-1)!.results[0];
    if (!row) unavailable();
    return jsonResponse({ ...base, roster: JSON.parse(row.packet) });
  }
  if (route === 'keys' && number !== undefined && number > 0 && number <= current.epoch) {
    statements.push(env.DB.prepare(`SELECT packet FROM family_notebook_crypto_envelopes WHERE family_id=? AND current_epoch=?
      AND key_epoch=? AND recipient_device_id=? ORDER BY signer_device_id LIMIT 192`).bind(family, current.epoch, number, actor.deviceId));
    const batch = await env.DB.batch<{ packet: string }>(statements);
    return jsonResponse({ ...base, envelopes: batch.at(-1)!.results.map(r => JSON.parse(r.packet)) });
  }
  if (route === 'operations' && number !== undefined) {
    // Bound both records and bytes; do not download the whole diary to make a
    // page. Sizes use the (ASCII) encrypted wire packet, not personal plaintext.
    const sizes = await env.DB.prepare('SELECT sequence,length(packet) AS size FROM family_notebook_crypto_operations WHERE family_id=? AND sequence>? ORDER BY sequence LIMIT 64')
      .bind(family, number).all<{ sequence: number; size: number }>();
    let end = number, size = 0;
    for (const row of sizes.results) { if (end > number && size + row.size > 1_500_000) break; end = row.sequence; size += row.size; }
    statements.push(env.DB.prepare('SELECT sequence,packet FROM family_notebook_crypto_operations WHERE family_id=? AND sequence>? AND sequence<=? ORDER BY sequence')
      .bind(family, number, end), env.DB.prepare('SELECT COALESCE(MAX(sequence),0) AS sequence FROM family_notebook_crypto_operations WHERE family_id=?').bind(family));
    const batch = await env.DB.batch<{ sequence: number; packet: string }>(statements);
    const head = batch.at(-1)?.results[0]; if (!head) unavailable();
    return jsonResponse({ ...base, nextCursor: end, headCursor: head.sequence,
      operations: batch.at(-2)!.results.map(r => ({ sequence: r.sequence, packet: JSON.parse(r.packet) })) });
  }
  throw new ApiError(404, 'not_found', 'Unknown family history request.');
}
