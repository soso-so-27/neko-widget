import { base64urlDecode,sha256Base64url,verifyEd25519 } from './encoding';
import { ApiError,jsonResponse } from './errors';
import type { Env } from './env';
import { groupMutationStatement,groupNonceStatements,requireGroupMember,storedGroupMutation,type GroupActor } from './group-auth';
import { groupFields,loadStoredGroupRoster } from './group-protocol';
import { groupCipher,groupExpected } from './group-windows';
import { binaryField,exactKeys,integerField,uuidField,type JsonRecord } from './validation';

export function groupRenameTranscript(input:{windowId:string;revision:number;keyEpoch:number;rosterHash:string;nameRevision:number;operationId:string;ciphertextSHA256:string}):Uint8Array {
  return groupFields(['NW3.WINDOW-NAME',input.windowId,String(input.revision),String(input.keyEpoch),base64urlDecode(input.rosterHash,32),
    String(input.nameRevision),input.operationId,base64urlDecode(input.ciphertextSHA256,32)]);
}
export function groupCloseTranscript(input:{windowId:string;revision:number;keyEpoch:number;rosterHash:string;operationId:string}):Uint8Array {
  return groupFields(['NW3.WINDOW-CLOSE',input.windowId,String(input.revision),String(input.keyEpoch),base64urlDecode(input.rosterHash,32),input.operationId]);
}
export async function manageGroupWindow(env:Env,actor:GroupActor,windowId:string,body:JsonRecord,close=false):Promise<Response> {
  if(env.GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED!=='YES')throw new ApiError(503,'group_management_disabled','Window management is unavailable.');
  try {
    exactKeys(body,close?['operationId','expectedRevision','keyEpoch','ownerSignature']:
      ['operationId','expectedRevision','keyEpoch','expectedNameRevision','encryptedName','ownerSignature']);
    const operationId=uuidField(body,'operationId'),revision=groupExpected(body),keyEpoch=integerField(body,'keyEpoch',1,Number.MAX_SAFE_INTEGER);
    // A close retry must work after this device's membership has been revoked.
    // Stored mutations are keyed by the authenticated device and signed bytes.
    const prior=await storedGroupMutation(env,actor,operationId,close?undefined:{windowId,owner:true});
    if(prior!==null)return jsonResponse(prior);
    const access=await requireGroupMember(env,actor,windowId,true),roster=await loadStoredGroupRoster(env.DB,windowId);
    if(access.revision!==revision || access.keyEpoch!==keyEpoch)throw new ApiError(409,'stale_revision','Read the current window before making changes.');
    const signature=binaryField(body,'ownerSignature',64),scope={windowId,owner:true,expectedRevision:revision};
    const input={windowId,revision,keyEpoch,rosterHash:roster.hash,operationId};
    const statements=[...groupNonceStatements(env,actor,scope)];
    let receipt:Record<string,unknown>;
    if(close) {
      if(!await verifyEd25519(actor.signingPublicKey,signature,groupCloseTranscript(input)))throw new ApiError(400,'invalid_proof','The owner proof is invalid.');
      receipt={operationId,windowId,revision,keyEpoch,state:'closed',serverNow:actor.now};
      statements.push(
        // The terminal mode is written first. Membership triggers then permit
        // the owner to leave and preserve only the bounded report-only grants.
        env.DB.prepare("UPDATE group_windows SET mode='closed',updated_at=? WHERE space_id=? AND mode='active'").bind(actor.now,windowId),
        env.DB.prepare("UPDATE group_invitations SET revoked_at=COALESCE(revoked_at,?) WHERE space_id=?").bind(actor.now,windowId),
        env.DB.prepare("UPDATE group_join_requests SET state='cancelled' WHERE space_id=? AND state='pending'").bind(windowId),
        env.DB.prepare("UPDATE group_members SET state='left',left_revision=? WHERE space_id=? AND state='active'").bind(revision+1,windowId),
        env.DB.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=? WHERE space_id=? AND state='active'").bind(revision+1,windowId),
        env.DB.prepare("UPDATE group_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='' WHERE space_id=?").bind(windowId),
        env.DB.prepare('INSERT INTO group_window_closures VALUES (?,?,?,?,?,?,?)').bind(windowId,actor.deviceId,operationId,revision,keyEpoch,signature,actor.now));
    } else {
      if(access.rotationRequired)throw new ApiError(409,'stale_epoch','Rotate the membership keys before renaming.');
      const expected=integerField(body,'expectedNameRevision',0,Number.MAX_SAFE_INTEGER-1),encryptedName=groupCipher(body,'encryptedName');
      const nameRevision=expected+1,hash=await sha256Base64url(base64urlDecode(encryptedName));
      if(!await verifyEd25519(actor.signingPublicKey,signature,groupRenameTranscript({...input,nameRevision,ciphertextSHA256:hash})))
        throw new ApiError(400,'invalid_proof','The owner proof is invalid.');
      receipt={operationId,windowId,revision,keyEpoch,nameRevision,serverNow:actor.now};
      statements.push(env.DB.prepare(`INSERT INTO group_window_names VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(space_id) DO UPDATE SET name_revision=excluded.name_revision,roster_revision=excluded.roster_revision,key_epoch=excluded.key_epoch,
          roster_hash=excluded.roster_hash,encrypted_name=excluded.encrypted_name,signer_device_id=excluded.signer_device_id,
          operation_id=excluded.operation_id,signature=excluded.signature,updated_at=excluded.updated_at`)
        .bind(windowId,nameRevision,revision,keyEpoch,roster.hash,encryptedName,actor.deviceId,operationId,signature,actor.now),
        env.DB.prepare('UPDATE group_window_metadata SET encrypted_name=? WHERE space_id=? AND key_epoch=? AND roster_revision=?')
          .bind(encryptedName,windowId,keyEpoch,revision));
    }
    statements.push(groupMutationStatement(env,actor,operationId,receipt));
    try { await env.DB.batch(statements); }
    catch(error) {
      const raced=await storedGroupMutation(env,actor,operationId,close?undefined:{windowId,owner:true});if(raced!==null)return jsonResponse(raced);
      throw error;
    }
    return jsonResponse(receipt);
  } catch(error) {
    await env.DB.prepare('INSERT OR IGNORE INTO group_request_nonces VALUES (?,?,?)').bind(actor.deviceId,actor.nonce,actor.now+601).run();
    throw error;
  }
}
