import { authenticateGroupRequest, groupId, groupNonceStatements, type GroupActor } from './group-auth';
import { base64urlDecode, verifyEd25519 } from './encoding';
import { groupFields } from './group-protocol';
import { gate, safeFailure, storeEnvironment } from './family-notebook-payer';
import { ApiError, jsonResponse } from './errors';
import { parseJsonBody } from './http';
import { binaryField, exactKeys, integerField, stringField, uuidField } from './validation';
import type { Env } from './env';

// Admission is deliberately not installed in the public router yet. Encrypted
// history/key delivery and the production app adapter must be connected before
// exposing a family that somebody could mistake for a working shared notebook.
type Operation = 'create' | 'invite' | 'revoke' | 'join' | 'approve' | 'reject';
interface Event {
  actor_person_id: string; request_hash: string; family_id: string; operation: Operation;
  resulting_generation: number; invitation_id: string | null; join_id: string | null; recorded_at: number;
}
interface Invitation {
  proof_public_key: string; encrypted_preview: string; generation: number;
  creator_person_id: string; creator_device_id: string; expires_at: number;
}
export function familyInvitationProof(familyId: string, invitationId: string, personId: string,
  deviceId: string, action: 'preview' | 'join', operationId: string): Uint8Array {
  return groupFields(['NW.FAMILY-NOTEBOOK.INVITATION.1', familyId, invitationId, personId, deviceId, action, operationId]);
}
function ciphertext(body: Record<string, unknown>, field: string): string {
  const value = stringField(body, field), length = base64urlDecode(value).byteLength;
  if (length < 29 || length > 8192) throw new ApiError(400, 'invalid_field', 'The encrypted field has an invalid size.');
  return value;
}
function receipt(operationId: string, event: Event): Response {
  return jsonResponse({ schemaVersion: 1, operationId, familyId: event.family_id, operation: event.operation,
    appliedGeneration: event.resulting_generation, invitationId: event.invitation_id, joinRequestId: event.join_id,
    expiresAt: ['invite', 'join'].includes(event.operation) ? event.recorded_at + 86400 : null });
}
function invitationQuery(env: Env, familyId: string, invitationId: string): D1PreparedStatement {
  return env.DB.prepare(`SELECT i.proof_public_key,i.encrypted_preview,f.generation,
      i.creator_person_id,i.creator_device_id,i.expires_at
    FROM family_notebook_invitations i JOIN family_notebook_spaces f ON f.id=i.family_id
      JOIN family_notebook_members m ON m.family_id=f.id AND m.person_id=i.creator_person_id
      JOIN group_person_devices d ON d.id=i.creator_device_id
      JOIN group_people p ON p.id=i.creator_person_id
    WHERE i.id=? AND f.id=? AND f.state='active' AND i.state='active' AND i.expires_at>unixepoch()
      AND m.state='active' AND d.state='active' AND p.state='active'`).bind(invitationId, familyId);
}
async function proveInvitation(env: Env, actor: GroupActor, familyId: string, invitationId: string,
  action: 'preview' | 'join', operationId: string, signature: string): Promise<Invitation> {
  const invitation = await invitationQuery(env, familyId, invitationId).first<Invitation>();
  if (!invitation) throw new ApiError(410, 'family_notebook_invitation_unavailable', 'This invitation is unavailable.');
  if (!await verifyEd25519(invitation.proof_public_key, signature,
    familyInvitationProof(familyId, invitationId, actor.personId, actor.deviceId, action, operationId))) {
    throw new ApiError(401, 'invalid_proof', 'The invitation proof is invalid.');
  }
  return invitation;
}

/** Real signed HTTP boundary used by local integration tests, not a public route. */
export async function familyNotebookAdmission(request: Request, env: Env): Promise<Response> {
  try {
    await gate(env);
    if (request.method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Unsupported family operation.');
    const path = new URL(request.url).pathname;
    const match = path.match(/^\/v3\/family-notebooks(?:\/([A-Za-z0-9_-]{1,128})(?:\/(invitations|requests)(?:\/([A-Za-z0-9_-]{1,128})\/(preview|join|revoke|approve|reject))?)?)?$/u);
    if (!match) throw new ApiError(404, 'not_found', 'The family endpoint was not found.');
    const { actor, body: bytes } = await authenticateGroupRequest(request, env, 24 * 1024);
    const body = parseJsonBody(request, bytes);
    const operationId = uuidField(body, 'operationId');
    const familyId = match[1] ? groupId(match[1]) : uuidField(body, 'familyId');
    const operation = path === '/v3/family-notebooks' ? 'create'
      : match[2] === 'invitations' && !match[3] ? 'invite'
      : match[2] === 'invitations' && ['preview', 'join', 'revoke'].includes(match[4] ?? '') ? match[4]
      : match[2] === 'requests' && ['approve', 'reject'].includes(match[4] ?? '') ? match[4] : undefined;
    if (!operation) throw new ApiError(404, 'not_found', 'The family endpoint was not found.');
    const invitationId = operation === 'invite' ? operationId : match[2] === 'invitations' && match[3] ? groupId(match[3]) : null;
    const joinId = operation === 'join' ? operationId : match[2] === 'requests' && match[3] ? groupId(match[3]) : null;
    const fields = ['operationId', ...(operation === 'create' ? ['familyId'] : operation === 'preview' ? [] : ['expectedGeneration'])];
    if (operation === 'invite') fields.push('proofPublicKey', 'encryptedPreview');
    if (operation === 'join') fields.push('proofSignature', 'encryptedDisplayName');
    if (operation === 'preview') fields.push('proofSignature');
    exactKeys(body, fields);
    if (operation === 'preview') {
      const invitation = await proveInvitation(env, actor, familyId, invitationId!, 'preview', operationId, binaryField(body, 'proofSignature', 64));
      const check = crypto.randomUUID();
      const batch = await env.DB.batch<Invitation>([...groupNonceStatements(env, actor),
        env.DB.prepare('INSERT INTO family_notebook_invitation_checks VALUES (?,?,?,?)').bind(check, familyId, invitationId, invitation.generation),
        env.DB.prepare('DELETE FROM family_notebook_invitation_checks WHERE id=?').bind(check), invitationQuery(env, familyId, invitationId!)]);
      const current = batch.at(-1)?.results[0];
      if (!current) throw new ApiError(410, 'family_notebook_invitation_unavailable', 'This invitation is unavailable.');
      return jsonResponse({ schemaVersion: 1, familyId, invitationId, generation: current.generation,
        inviterPersonId: current.creator_person_id, inviterDeviceId: current.creator_device_id,
        encryptedPreview: current.encrypted_preview, expiresAt: current.expires_at });
    }
    const generation = operation === 'create' ? 0 : integerField(body, 'expectedGeneration', 1, 1_000_000_000);
    const prior = await env.DB.prepare(`SELECT actor_person_id,request_hash,family_id,operation,
      resulting_generation,invitation_id,join_id,recorded_at FROM family_notebook_admission_events
      WHERE actor_device_id=? AND operation_id=?`).bind(actor.deviceId, operationId).first<Event>();
    if (prior) {
      if (prior.actor_person_id !== actor.personId || prior.request_hash !== actor.requestHash || prior.family_id !== familyId || prior.operation !== operation) {
        throw new ApiError(409, 'idempotency_conflict', 'This operation has different content.');
      }
      // Only one's own historical receipt. It never restores membership or
      // grants access to a used invitation or to another person's notebook.
      await env.DB.batch(groupNonceStatements(env, actor));
      return receipt(operationId, prior);
    }
    const environment = storeEnvironment(env);
    if (!environment && !['revoke', 'reject'].includes(operation)) {
      throw new ApiError(503, 'billing_runtime_disabled', 'Membership verification is unavailable.');
    }
    let proofKey: string | null = null, cipher: string | null = null;
    if (operation === 'invite') { proofKey = binaryField(body, 'proofPublicKey', 32); cipher = ciphertext(body, 'encryptedPreview'); }
    if (operation === 'join') {
      await proveInvitation(env, actor, familyId, invitationId!, 'join', operationId, binaryField(body, 'proofSignature', 64));
      cipher = ciphertext(body, 'encryptedDisplayName');
    }
    const configured = operation === 'approve' ? env.FAMILY_NOTEBOOK_MAX_MEMBERS ?? '6' : '6';
    if (!/^[1-9][0-9]?$/u.test(configured) || Number(configured) < 2 || Number(configured) > 64) {
      throw new ApiError(503, 'family_notebook_unavailable', 'Family configuration is unavailable.');
    }
    const resultingGeneration = generation + (operation === 'create' || operation === 'approve' ? 1 : 0);
    await env.DB.batch([...groupNonceStatements(env, actor),
      env.DB.prepare(`INSERT INTO family_notebook_admission_events
        (actor_device_id,operation_id,actor_person_id,request_hash,family_id,operation,expected_generation,
          resulting_generation,invitation_id,join_id,proof_public_key,ciphertext,store_environment,maximum_members)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(actor.deviceId, operationId, actor.personId, actor.requestHash,
          familyId, operation, generation, resultingGeneration, invitationId, joinId, proofKey, cipher, environment, Number(configured))]);
    const committed = await env.DB.prepare(`SELECT actor_person_id,request_hash,family_id,operation,
      resulting_generation,invitation_id,join_id,recorded_at FROM family_notebook_admission_events
      WHERE actor_device_id=? AND operation_id=?`).bind(actor.deviceId, operationId).first<Event>();
    if (!committed) throw new ApiError(503, 'family_notebook_unavailable', 'The operation result could not be confirmed.');
    return receipt(operationId, committed);
  } catch (error) { return safeFailure(error); }
}
