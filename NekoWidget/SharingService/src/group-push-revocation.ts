import type {Env} from './env';

/** Call inside the authorized membership/preference transaction. Keep the
 * generation tombstone so re-registration cannot revive old queued messages. */
export function groupPushRevocationStatements(env:Env,windowId:string,scope?:{participantId:string}|{deviceId:string}):D1PreparedStatement[]{
 const suffix=scope===undefined?'': 'participantId' in scope
  ?' AND device_id IN (SELECT d.id FROM group_person_devices d JOIN group_members m ON m.person_id=d.person_id WHERE m.space_id=? AND m.participant_id=?)'
  :' AND device_id=?';
 const values=scope===undefined?[windowId]:'participantId' in scope?[windowId,windowId,scope.participantId]:[windowId,scope.deviceId];
 return ['group_push_subscriptions','group_join_push_subscriptions'].map(table=>env.DB.prepare(
  `UPDATE ${table} SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest='' WHERE space_id=?${suffix}`
 ).bind(...values));
}
