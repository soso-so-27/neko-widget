import type { Env } from './env';
import { ApiError, jsonResponse } from './errors';
import { base64urlDecode, randomBase64url, sha256Base64url, verifyEd25519 } from './encoding';
import { groupFields } from './group-protocol';
import { enforceRateLimit, parseJsonBody, readBody, transientNetworkKey } from './http';
import { binaryField, exactKeys, uuidField } from './validation';
import { protectedGroupRead, requireCurrentIdentity } from './group-identity-service';
import { groupRecoveryPendingAPI } from './group-recovery-pending';
import { removeRecoveryDevice } from './group-recovery-devices';
import { freshRecovery } from './group-recovery-fresh';
import { recipientRecoveryKeys } from './group-recovery-key-recipient';
import {checkTrialRecovery} from './owner-two-device-trial';

export interface RecoveryChallenge {
  id: string; person_id: string; identity_public_key: string; operation_id: string;
  purpose: 'catalog' | 'status' | 'register'; environment: 'production' | 'staging';
  nonce: string; issued_at: number; expires_at: number; consumed_at: number | null;
}
export function recoveryCatalogTranscript(c: RecoveryChallenge): Uint8Array {
  return groupFields(['NW3.RECOVERY.CATALOG.V1', c.environment, c.purpose, c.id,
    c.person_id, base64urlDecode(c.identity_public_key, 32), c.operation_id,
    base64urlDecode(c.nonce, 32), String(c.issued_at), String(c.expires_at)]);
}
const denied = () => new ApiError(401, 'recovery_authentication_failed', 'Recovery authentication failed.');

/** Root-owned membership discovery. Does not create an identity or issue a device.
 * Names stay encrypted. A missing/failed read is never converted to zero. */
export async function groupRecoveryCatalogAPI(request: Request, env: Env): Promise<Response> {
  if (env.GROUP_RECOVERY_CATALOG_ENABLED !== 'YES')
    throw new ApiError(503, 'recovery_disabled', 'Recovery is unavailable.');
  if (env.ENVIRONMENT !== 'production' && env.ENVIRONMENT !== 'staging') throw denied();
  const url = new URL(request.url);
  if (request.method !== 'POST' || url.search) throw new ApiError(400, 'invalid_request', 'Invalid recovery request.');
  await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, transientNetworkKey(request, 'group-recovery'));
  const fresh=url.pathname.match(/^\/v3\/group-recovery\/operations\/([0-9a-f-]{36})\/fresh$/u);
  const body = parseJsonBody(request, await readBody(request, fresh ? 32_768 : 4096));
  const now = Math.floor(Date.now() / 1000);
  if (url.pathname === '/v3/group-recovery/challenges') {
    exactKeys(body, ['identityPublicKey', 'operationId', 'purpose']);
    const key = binaryField(body, 'identityPublicKey', 32), operation = uuidField(body, 'operationId');
    if (!['catalog','status','register'].includes(String(body.purpose))) throw new ApiError(400, 'invalid_purpose', 'Invalid recovery purpose.');
    const purpose = body.purpose as RecoveryChallenge['purpose'];
    const person = await sha256Base64url(base64urlDecode(key, 32));
    checkTrialRecovery(env,person);
    await enforceRateLimit(env, env.MEMBER_RATE_LIMITER, `group-recovery-root:${person}`);
    const challenge: RecoveryChallenge = { id: crypto.randomUUID(), person_id: person, identity_public_key: key,
      operation_id: operation, purpose, environment: env.ENVIRONMENT,
      nonce: randomBase64url(32), issued_at: now, expires_at: now + 300, consumed_at: null };
    await env.DB.batch([
      env.DB.prepare('DELETE FROM group_recovery_challenges WHERE id IN (SELECT id FROM group_recovery_challenges WHERE expires_at<=? LIMIT 100)').bind(now),
      env.DB.prepare(`INSERT INTO group_recovery_challenges
        (id,person_id,identity_public_key,operation_id,purpose,environment,nonce,issued_at,expires_at)
        VALUES (?,?,?,?,?,?,?,?,?)`).bind(challenge.id, person, key, operation, purpose, env.ENVIRONMENT, challenge.nonce, now, now + 300),
    ]);
    // This response does not disclose whether the root is registered.
    return jsonResponse({ challenge }, 201);
  }
  if (url.pathname === '/v3/group-recovery/devices/remove') return removeRecoveryDevice(env, body, now);
  if (fresh) return freshRecovery(env,body,fresh[1]!,now);
  const keys=url.pathname.match(/^\/v3\/group-recovery\/operations\/([0-9a-f-]{36})\/(key-offers|key-receipts)$/u);
  if(keys)return recipientRecoveryKeys(env,body,keys[1]!,keys[2]==='key-receipts',now);
  if (url.pathname.startsWith('/v3/group-recovery/operations/')) return groupRecoveryPendingAPI(env, body, url.pathname, now);
  if (url.pathname !== '/v3/group-recovery/catalog') throw new ApiError(404, 'not_found', 'Endpoint unavailable.');
  exactKeys(body, ['challengeId', 'rootSignature']);
  const id = uuidField(body, 'challengeId'), signature = binaryField(body, 'rootSignature', 64);
  const c = await env.DB.prepare('SELECT * FROM group_recovery_challenges WHERE id=?').bind(id).first<RecoveryChallenge>();
  if (!c || c.environment !== env.ENVIRONMENT || c.purpose !== 'catalog' || c.consumed_at !== null
      || now < c.issued_at || now >= c.expires_at
      || !await verifyEd25519(c.identity_public_key, signature, recoveryCatalogTranscript(c))) throw denied();
  checkTrialRecovery(env,c.person_id);
  await requireCurrentIdentity(env, c.person_id);
  return protectedGroupRead(env, async () => {
    const claim = crypto.randomUUID();
    const trial=env.ownerTrial;
    try {
      const rows = await env.DB.batch([
        env.DB.prepare(`UPDATE group_recovery_challenges SET consumed_at=?,consumed_by=?
          WHERE id=? AND consumed_at IS NULL AND expires_at>?`).bind(now, claim, c.id, now),
        env.DB.prepare('INSERT INTO group_recovery_read_checks VALUES (?,?,?,?)').bind(claim, c.person_id, c.id, now),
        env.DB.prepare(`SELECT w.space_id AS windowId,m.participant_id AS participantId,
          m.display_name_ciphertext AS encryptedDisplayName,n.encrypted_name AS encryptedName,
          n.key_epoch AS nameKeyEpoch,n.roster_revision AS nameRosterRevision
          FROM group_members m JOIN group_windows w ON w.space_id=m.space_id
          JOIN group_people p ON p.id=m.person_id
          LEFT JOIN group_window_metadata n ON n.space_id=w.space_id
          WHERE m.person_id=? AND m.state='active' AND w.mode='active' AND p.state='active'
            AND (? IS NULL OR w.space_id=?)
          ORDER BY w.space_id`).bind(c.person_id,trial?.window??null,trial?.window??null),
        env.DB.prepare(`SELECT f.id AS familyId FROM family_notebook_members m
          JOIN family_notebook_spaces f ON f.id=m.family_id JOIN group_people p ON p.id=m.person_id
          WHERE m.person_id=? AND m.state='active' AND f.state='active' AND p.state='active' AND ?=0
          ORDER BY f.id`).bind(c.person_id,trial?1:0),
        env.DB.prepare(`SELECT d.id AS deviceId,l.model,d.created_at AS registeredAt
          FROM group_person_devices d LEFT JOIN group_recovery_device_labels l ON l.device_id=d.id
          JOIN group_people p ON p.id=d.person_id
          WHERE d.person_id=? AND d.state='active' AND p.state='active'
            AND (? IS NULL OR d.id IN (?,?))
          UNION SELECT r.device_id AS deviceId,MIN(r.model) AS model,MIN(r.created_at) AS registeredAt
          FROM group_recovery_pending r JOIN group_people p ON p.id=r.person_id AND p.state='active'
          WHERE r.person_id=? AND NOT EXISTS(SELECT 1 FROM group_person_devices d WHERE d.id=r.device_id AND d.state='active')
            AND (? IS NULL OR (r.window_id=? AND r.device_id=?))
          GROUP BY r.device_id ORDER BY deviceId`).bind(c.person_id,trial?.window??null,trial?.aDevice??null,
            trial?.recoveryDevice??null,c.person_id,trial?.window??null,trial?.window??null,trial?.recoveryDevice??null),
        env.DB.prepare('DELETE FROM group_recovery_read_checks WHERE id=?').bind(claim),
      ]);
      return jsonResponse({ personId: c.person_id, windows: rows[2]!.results, notebooks: rows[3]!.results,
        windowCount: rows[2]!.results.length, notebookCount: rows[3]!.results.length,
        devices: rows[4]!.results, serverNow: now });
    } catch (error) {
      const message = error instanceof Error ? error.message : '';
      if (message.includes('group_recovery_challenge_invalid') || message.includes('group_recovery_identity_unavailable')) throw denied();
      throw error;
    }
  });
}
