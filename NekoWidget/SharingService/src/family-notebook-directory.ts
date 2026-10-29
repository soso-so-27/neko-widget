import { authenticateGroupRequest, groupNonceStatements, type GroupActor } from './group-auth';
import { gate, safeFailure } from './family-notebook-payer';
import { familyUUID } from './family-notebook-crypto';
import { ApiError, jsonResponse } from './errors';
import { requireEmptyBody } from './http';
import type { Env } from './env';

// Discovery for the real native service. Neither a local prototype nor photo
// room membership is included. All returned names remain encrypted.
export async function familyNotebookDirectory(request: Request, env: Env): Promise<Response> {
  try {
    await gate(env);
    const url = new URL(request.url), root = '/v3/family-notebooks';
    const match = /^\/v3\/family-notebooks\/([0-9a-f-]+)\/(members|requests|invitations)$/u.exec(url.pathname);
    if (url.search || request.method !== 'GET' || (url.pathname !== root + '/me' && !match)) {
      throw new ApiError(404, 'not_found', 'Unknown family directory.');
    }
    const { actor, body } = await authenticateGroupRequest(request, env, 0); requireEmptyBody(body);
    if (!match) return await ownFamilies(env, actor);
    const family = familyUUID(match[1]), kind = match[2];
    const membership = await env.DB.prepare(`SELECT f.generation FROM family_notebook_spaces f
      JOIN family_notebook_members m ON m.family_id=f.id WHERE f.id=? AND f.state='active' AND m.person_id=? AND m.state='active'`)
      .bind(family, actor.personId).first<{ generation: number }>();
    if (!membership) throw new ApiError(404, 'not_found', 'The family was not found.');
    const check = crypto.randomUUID();
    const statements = [...groupNonceStatements(env, actor),
      env.DB.prepare('INSERT INTO family_notebook_access_checks VALUES (?,?,?,?,?)').bind(check, family, actor.personId, actor.deviceId, membership.generation),
      env.DB.prepare('DELETE FROM family_notebook_access_checks WHERE id=?').bind(check)];
    if (kind === 'members') {
      statements.push(env.DB.prepare(`SELECT m.person_id AS personId,m.state,m.admitted_generation AS admittedGeneration,
        m.left_generation AS leftGeneration,p.identity_public_key AS identityPublicKey,
        (CASE WHEN f.payer_person_id=m.person_id THEN 'payer' ELSE 'member' END) AS role
        FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id JOIN group_people p ON p.id=m.person_id
        WHERE m.family_id=? AND m.state='active' ORDER BY m.person_id LIMIT 64`).bind(family));
    } else if (kind === 'requests') {
      statements.push(env.DB.prepare(`SELECT j.id AS requestId,j.person_id AS personId,j.device_id AS deviceId,
        j.invitation_id AS invitationId,j.encrypted_display_name AS encryptedDisplayName,j.expires_at AS expiresAt,
        p.identity_public_key AS identityPublicKey,d.signing_public_key AS signingPublicKey,d.hpke_public_key AS hpkePublicKey
        FROM family_notebook_join_requests j JOIN family_notebook_invitations i ON i.id=j.invitation_id
        JOIN family_notebook_spaces f ON f.id=j.family_id
        JOIN group_people p ON p.id=j.person_id AND p.state='active'
        JOIN group_person_devices d ON d.id=j.device_id AND d.state='active'
        WHERE j.family_id=? AND j.state='pending' AND j.expires_at>unixepoch()
          AND (i.creator_person_id=? OR f.payer_person_id=?) ORDER BY j.created_at,j.id LIMIT 64`).bind(family, actor.personId, actor.personId));
    } else {
      statements.push(env.DB.prepare(`SELECT i.id AS invitationId,i.creator_person_id AS inviterPersonId,
        i.creator_device_id AS inviterDeviceId,i.state,i.expires_at AS expiresAt,i.encrypted_preview AS encryptedPreview
        FROM family_notebook_invitations i JOIN family_notebook_spaces f ON f.id=i.family_id
        WHERE i.family_id=? AND (i.creator_person_id=? OR f.payer_person_id=?)
          AND i.expires_at>unixepoch() ORDER BY i.created_at DESC,i.id LIMIT 64`).bind(family, actor.personId, actor.personId));
    }
    const batch = await env.DB.batch(statements);
    return jsonResponse({ schemaVersion: 1, familyId: family, generation: membership.generation, [kind!]: batch.at(-1)!.results });
  } catch (error) { safeFailure(error); }
}

async function ownFamilies(env: Env, actor: GroupActor): Promise<Response> {
  const batch = await env.DB.batch<Record<string, unknown>>([...groupNonceStatements(env, actor),
    env.DB.prepare('SELECT enabled FROM family_notebook_runtime_gate WHERE singleton=1'),
    env.DB.prepare(`SELECT f.id AS familyId,f.generation,(CASE WHEN f.payer_person_id=m.person_id THEN 'payer' ELSE 'member' END) AS role
      FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
      WHERE m.person_id=? AND m.state='active' AND f.state='active' LIMIT 2`).bind(actor.personId),
    env.DB.prepare(`SELECT j.family_id AS familyId,j.id AS requestId,j.invitation_id AS invitationId,j.expires_at AS expiresAt
      FROM family_notebook_join_requests j JOIN family_notebook_spaces f ON f.id=j.family_id AND f.state='active'
      WHERE j.person_id=? AND j.state='pending' AND j.expires_at>unixepoch() ORDER BY j.created_at DESC,j.id LIMIT 64`).bind(actor.personId)]);
  if (batch.at(-3)?.results[0]?.enabled !== 1) throw new ApiError(503, 'family_notebook_disabled', 'Family notebooks are unavailable.');
  const families = batch.at(-2)!.results;
  if (families.length > 1) throw new ApiError(503, 'family_notebook_unavailable', 'The current family could not be confirmed.');
  return jsonResponse({ schemaVersion: 1, personId: actor.personId, family: families[0] ?? null, pendingRequests: batch.at(-1)!.results });
}
