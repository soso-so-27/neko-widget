import { base64urlDecode, randomBase64url, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { groupFields } from "./group-protocol";
import { enforceRateLimit, parseJsonBody, readBody, transientNetworkKey } from "./http";
import { binaryField, exactKeys, uuidField } from "./validation";

export function groupIdentityTranscript(input: {operationId:string;challengeId:string;challenge:string;expiresAt:number;
  personPublicKey:string;signingPublicKey:string;hpkePublicKey:string}): Uint8Array {
  return groupFields(["NW3.IDENTITY","3",input.operationId,input.challengeId,input.challenge,String(input.expiresAt),
    base64urlDecode(input.personPublicKey,32),base64urlDecode(input.signingPublicKey,32),base64urlDecode(input.hpkePublicKey,32)]);
}
export async function groupDeviceKeyHash(signingPublicKey:string,hpkePublicKey:string): Promise<string> {
  return sha256Base64url(groupFields([base64urlDecode(signingPublicKey,32),base64urlDecode(hpkePublicKey,32)]));
}

export async function createGroupIdentityChallenge(request:Request,env:Env):Promise<Response> {
  await enforceRateLimit(env,env.CREATE_RATE_LIMITER,transientNetworkKey(request,"group-identity-challenge"));
  const body=parseJsonBody(request,await readBody(request,4096));
  exactKeys(body,["purpose","signingPublicKey","hpkePublicKey"]);
  if(body.purpose!=="register") throw new ApiError(400,"invalid_field","The challenge purpose is invalid.");
  const signingPublicKey=binaryField(body,"signingPublicKey",32),hpkePublicKey=binaryField(body,"hpkePublicKey",32);
  const challengeId=crypto.randomUUID(),challenge=randomBase64url(32),now=Math.floor(Date.now()/1000),expiresAt=now+300;
  await env.DB.prepare("INSERT INTO group_challenges VALUES (?,'register',NULL,?,?,?,NULL)")
    .bind(challengeId,await groupDeviceKeyHash(signingPublicKey,hpkePublicKey),challenge,expiresAt).run();
  return jsonResponse({challengeId,challenge,expiresAt,serverNow:now},201);
}

export async function registerGroupIdentity(request:Request,env:Env):Promise<Response> {
  await enforceRateLimit(env,env.CREATE_RATE_LIMITER,transientNetworkKey(request,"group-identity-register"));
  const bytes=await readBody(request,8192),body=parseJsonBody(request,bytes);
  exactKeys(body,["operationId","challengeId","personPublicKey","signingPublicKey","hpkePublicKey","personSignature","deviceSignature"]);
  const operationId=uuidField(body,"operationId"),challengeId=uuidField(body,"challengeId");
  const personPublicKey=binaryField(body,"personPublicKey",32),signingPublicKey=binaryField(body,"signingPublicKey",32),hpkePublicKey=binaryField(body,"hpkePublicKey",32);
  const personSignature=binaryField(body,"personSignature",64),deviceSignature=binaryField(body,"deviceSignature",64);
  const now=Math.floor(Date.now()/1000);
  const challenge=await env.DB.prepare("SELECT random_challenge,device_key_hash,expires_at,consumed_at FROM group_challenges WHERE id=? AND purpose='register'")
    .bind(challengeId).first<{random_challenge:string;device_key_hash:string;expires_at:number;consumed_at:number|null}>();
  if(!challenge || challenge.device_key_hash!==await groupDeviceKeyHash(signingPublicKey,hpkePublicKey))
    throw new ApiError(401,"invalid_proof","The device registration proof is invalid.");
  const transcript=groupIdentityTranscript({operationId,challengeId,challenge:challenge.random_challenge,expiresAt:challenge.expires_at,
    personPublicKey,signingPublicKey,hpkePublicKey});
  if(!await verifyEd25519(personPublicKey,personSignature,transcript) || !await verifyEd25519(signingPublicKey,deviceSignature,transcript))
    throw new ApiError(401,"invalid_proof","The device registration proof is invalid.");
  const personId=await sha256Base64url(base64urlDecode(personPublicKey,32));
  const deviceId=await groupDeviceKeyHash(signingPublicKey,hpkePublicKey),requestHash=await sha256Base64url(bytes);
  const prior=await env.DB.prepare(`SELECT r.request_hash,d.person_id,d.state,p.state AS person_state FROM group_identity_registrations r
      JOIN group_person_devices d ON d.id=r.device_id JOIN group_people p ON p.id=d.person_id
      WHERE r.device_id=? AND r.operation_id=?`).bind(deviceId,operationId)
    .first<{request_hash:string;person_id:string;state:string;person_state:string}>();
  if(prior) {
    if(prior.request_hash!==requestHash || prior.person_id!==personId) throw new ApiError(409,"idempotency_conflict","The operation has different content.");
    if(prior.state!=="active" || prior.person_state!=="active") throw new ApiError(401,"invalid_authentication","The registration is no longer active.");
    return jsonResponse({personId,deviceId,state:"registered",serverNow:now});
  }
  const existing=await env.DB.prepare("SELECT person_id,state FROM group_person_devices WHERE id=?").bind(deviceId)
    .first<{person_id:string;state:string}>();
  if(existing && (existing.person_id!==personId || existing.state!=="active"))
    throw new ApiError(401,"invalid_proof","The device registration proof is invalid.");
  if(challenge.expires_at<=now || challenge.consumed_at!==null) throw new ApiError(410,"challenge_expired","The registration challenge has expired.");
  // Root ownership is checked above. No account, email, Apple Account, or
  // payment token is inferred from the public key's display name.
  await env.DB.batch([
    env.DB.prepare("UPDATE group_challenges SET consumed_at=? WHERE id=?").bind(now,challengeId),
    env.DB.prepare("INSERT INTO group_people VALUES (?,?,'active',?) ON CONFLICT(id) DO NOTHING").bind(personId,personPublicKey,now),
    env.DB.prepare("INSERT INTO group_person_devices SELECT ?,?,?,?,?,'active',?,NULL WHERE NOT EXISTS (SELECT 1 FROM group_person_devices WHERE id=?)")
      .bind(deviceId,personId,signingPublicKey,hpkePublicKey,JSON.stringify({personSignature,deviceSignature,transcriptHash:await sha256Base64url(transcript)}),now,deviceId),
    env.DB.prepare("INSERT INTO group_identity_registrations VALUES (?,?,?,?)").bind(deviceId,operationId,requestHash,now),
    env.DB.prepare("INSERT INTO group_authorization_checks VALUES (?,?,NULL,0,NULL)").bind(operationId,deviceId),
    env.DB.prepare("DELETE FROM group_authorization_checks WHERE id=?").bind(operationId),
  ]);
  return jsonResponse({personId,deviceId,state:"registered",serverNow:now},201);
}
