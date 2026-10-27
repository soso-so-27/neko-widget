import { authenticateBillingSignedRequest } from './billing-auth';
import { billingEffectiveEntitlementRuntimeEnabled,type Env } from './env';
import { ApiError,jsonResponse } from './errors';
import { groupMutationStatement,groupNonceStatements,type GroupActor } from './group-auth';
import { exactKeys,uuidField,type JsonRecord } from './validation';

export interface GroupDeliveryPolicy {
  deliveryStatus:'active'|'paused';
  deliveryReason:'owner_plus'|'owner_plus_required';
  ownerParticipantId:string;
}
// Apple introductory-offer transactions qualify through the same verified
// subscription authority. No local day counter, room-age trial or extra grace.
// An absent/misconfigured upper gate is NOT paid access.
function storeEnvironment(env:Env):'Production'|'Sandbox'|null {
  if(!billingEffectiveEntitlementRuntimeEnabled(env))return null;
  if(env.BILLING_STORE_ENVIRONMENT==='Production')return 'Production';
  if(env.BILLING_STORE_ENVIRONMENT==='Sandbox' && ['local','staging'].includes(env.ENVIRONMENT))return 'Sandbox';
  return null;
}
export function groupCreationPolicyStatements(env:Env,windowId:string,personId:string,operationId:string):D1PreparedStatement[] {
  return [env.DB.prepare('INSERT INTO group_creation_policy_checks VALUES (?,?,?,?)').bind(operationId,windowId,personId,storeEnvironment(env)),
    env.DB.prepare('DELETE FROM group_creation_policy_checks WHERE id=?').bind(operationId)];
}
export function groupDeliveryPolicyStatements(env:Env,windowId:string):D1PreparedStatement[] {
  const id=crypto.randomUUID();
  return [env.DB.prepare('INSERT INTO group_delivery_policy_checks VALUES (?,?,?)').bind(id,windowId,storeEnvironment(env)),
    env.DB.prepare('DELETE FROM group_delivery_policy_checks WHERE id=?').bind(id)];
}
export async function groupDeliveryPolicies(env:Env,windowIds:readonly string[]):Promise<Map<string,GroupDeliveryPolicy>> {
  if(windowIds.length===0)return new Map();
  const rows=await env.DB.prepare(`SELECT w.space_id,w.owner_participant_id,
      (CASE WHEN EXISTS (
        SELECT 1 FROM group_verified_plus_people p WHERE p.person_id=w.owner_person_id AND p.environment=?)
        THEN 'owner_plus' ELSE 'owner_plus_required' END) AS reason
      FROM group_window_owner_policy w WHERE w.space_id IN (${windowIds.map(()=>'?').join(',')})`)
    .bind(storeEnvironment(env),...windowIds).all<{space_id:string;owner_participant_id:string;reason:GroupDeliveryPolicy['deliveryReason']}>();
  return new Map(rows.results.map(r=>[r.space_id,{deliveryStatus:r.reason==='owner_plus_required'?'paused':'active',
    deliveryReason:r.reason,ownerParticipantId:r.owner_participant_id}]));
}

export async function connectGroupBilling(request:Request,env:Env,actor:GroupActor,bytes:Uint8Array,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','billingAccountId','personId','deviceId']);
  const operationId=uuidField(body,'operationId'),accountId=uuidField(body,'billingAccountId');
  if(body.personId!==actor.personId || body.deviceId!==actor.deviceId)
    throw new ApiError(401,'invalid_billing_authentication','Membership identity does not match.');
  // Billing control is separate from group control; connecting a key changes
  // no purchase, entitlement, Apple identity or transaction.
  if(!storeEnvironment(env))throw new ApiError(503,'billing_runtime_disabled','Membership verification is unavailable.');
  const gate=await env.DB.prepare('SELECT effective_entitlement_enabled FROM billing_runtime_gate WHERE singleton=1').first<{effective_entitlement_enabled:number}>();
  if(gate?.effective_entitlement_enabled!==1)throw new ApiError(503,'billing_runtime_disabled','Membership verification is unavailable.');
  const account=await authenticateBillingSignedRequest(request,env,bytes);
  if(account.billingAccountId!==accountId)throw new ApiError(401,'invalid_billing_authentication','Membership authentication failed.');
  const prior=await env.DB.prepare('SELECT request_hash,response_json FROM group_mutations WHERE actor_device_id=? AND operation_id=? AND expires_at>?')
    .bind(actor.deviceId,operationId,actor.now).first<{request_hash:string;response_json:string}>();
  if(prior && prior.request_hash!==actor.requestHash)throw new ApiError(409,'idempotency_conflict','The operation has different content.');
  const existing=await env.DB.prepare('SELECT person_id,billing_account_id FROM group_billing_connections WHERE person_id=? OR billing_account_id=?')
    .bind(actor.personId,accountId).all<{person_id:string;billing_account_id:string}>();
  if(existing.results.some(r=>r.person_id!==actor.personId || r.billing_account_id!==accountId))
    throw new ApiError(409,'billing_connection_conflict','This membership is already connected to another identity.');
  const response=prior?JSON.parse(prior.response_json) as unknown:{operationId,personId:actor.personId,state:'connected',serverNow:actor.now};
  // Consume BOTH nonces and recheck BOTH active keys in the same transaction.
  // ON CONFLICT cannot silently attach a different person: the unique account
  // index and the immutable connection trigger preserve the binding.
  const check=crypto.randomUUID();
  await env.DB.batch([...groupNonceStatements(env,actor),
    env.DB.prepare('DELETE FROM billing_request_nonces WHERE billing_key_id=? AND expires_at<=?').bind(account.billingKeyId,account.now),
    env.DB.prepare('INSERT INTO billing_request_nonces VALUES (?,?,?,?)').bind(account.billingKeyId,account.nonce,account.now,account.now+601),
    env.DB.prepare(`INSERT INTO group_billing_connections
      SELECT ?,?,?,?,? WHERE EXISTS (SELECT 1 FROM billing_account_keys WHERE id=? AND billing_account_id=? AND state='active')
      ON CONFLICT(person_id) DO NOTHING`).bind(actor.personId,accountId,actor.deviceId,account.billingKeyId,actor.now,account.billingKeyId,accountId),
    env.DB.prepare(`INSERT INTO group_billing_connection_checks VALUES (?,?,?,?)`).bind(check,actor.personId,accountId,account.billingKeyId),
    env.DB.prepare('DELETE FROM group_billing_connection_checks WHERE id=?').bind(check),
    ...(prior?[]:[groupMutationStatement(env,actor,operationId,response)])]);
  return jsonResponse(response);
}
