import type { Env } from './env';
import { ApiError, jsonResponse } from './errors';
import { base64urlDecode, sha256Base64url, verifyEd25519 } from './encoding';
import { groupFields } from './group-protocol';
import { groupAuthorizationStatements, requireGroupMember, type GroupActor } from './group-auth';
import { binaryField, exactKeys } from './validation';

export function anchorReceiptTranscript(environment: string, person: string, window: string,
  owner: string, ownerKey: string): Uint8Array {
  return groupFields(['NW3.ANCHOR.RECEIPT.V1', environment, person, window, owner,
    base64urlDecode(ownerKey, 32)]);
}

/** Existing-device upload, independent of the OFF recovery/issuance gate.
 * No relay-selected anchor, overwrite, device issuance, or roster mutation. */
export async function storeAnchorReceipt(env: Env, actor: GroupActor, window: string,
  body: Record<string, unknown>): Promise<Response> {
  exactKeys(body, ['environment', 'personId', 'ownerPersonId', 'ownerPublicKey', 'rootSignature']);
  if ((env.ENVIRONMENT !== 'production' && env.ENVIRONMENT !== 'staging')
      || body.environment !== env.ENVIRONMENT || body.personId !== actor.personId)
    throw new ApiError(401, 'invalid_anchor_receipt', 'Invalid anchor receipt.');
  const ownerKey = binaryField(body, 'ownerPublicKey', 32), signature = binaryField(body, 'rootSignature', 64);
  const owner = await sha256Base64url(base64urlDecode(ownerKey, 32));
  if (body.ownerPersonId !== owner || !await verifyEd25519(actor.identityPublicKey, signature,
      anchorReceiptTranscript(env.ENVIRONMENT, actor.personId, window, owner, ownerKey)))
    throw new ApiError(401, 'invalid_anchor_receipt', 'Invalid anchor receipt.');
  await requireGroupMember(env, actor, window);
  // Authorization is rechecked in the same transaction as the insert, including
  // device/person revocation and membership. The client pin remains authority.
  const rows = await env.DB.batch([
    ...groupAuthorizationStatements(env, actor, { windowId: window }),
    env.DB.prepare(`INSERT INTO group_anchor_receipts VALUES (?,?,?,?,?,?)
      ON CONFLICT(person_id,space_id,environment) DO NOTHING`)
      .bind(actor.personId, window, env.ENVIRONMENT, owner, ownerKey, signature),
    env.DB.prepare(`SELECT owner_person_id,owner_public_key,root_signature FROM group_anchor_receipts
      WHERE person_id=? AND space_id=? AND environment=?`).bind(actor.personId, window, env.ENVIRONMENT),
  ]);
  const saved = rows[3]!.results[0] as { owner_person_id: string; owner_public_key: string; root_signature: string } | undefined;
  let savedValid = false;
  if (saved) {
    try {
      savedValid = saved.owner_person_id === await sha256Base64url(base64urlDecode(saved.owner_public_key, 32))
        && await verifyEd25519(actor.identityPublicKey, saved.root_signature,
          anchorReceiptTranscript(env.ENVIRONMENT, actor.personId, window, saved.owner_person_id, saved.owner_public_key));
    } catch { /* A corrupt stored proof never establishes trust. */ }
  }
  if (!saved || !savedValid || saved.owner_person_id !== owner || saved.owner_public_key !== ownerKey)
    throw new ApiError(409, 'anchor_receipt_conflict', 'The existing anchor is different.');
  return jsonResponse({ state: 'stored', windowId: window });
}
