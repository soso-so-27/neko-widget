import { base64urlDecode, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";
import { groupFields } from "./group-protocol";
import { enforceRateLimit, readBody, transientNetworkKey } from "./http";

export interface GroupActor {
  deviceId: string;
  personId: string;
  signingPublicKey: string;
  hpkePublicKey: string;
  identityPublicKey: string;
  nonce: string;
  now: number;
  requestHash: string;
}
export function groupId(value: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/u.test(value)) throw new ApiError(404,"not_found","The group record was not found.");
  return value;
}
export async function authenticateGroupRequest(request: Request, env: Env,maximumBody=128*1024): Promise<{actor:GroupActor;body:Uint8Array}> {
  await enforceRateLimit(env,env.MEMBER_RATE_LIMITER,transientNetworkKey(request,"group-member"));
  const body = await readBody(request,maximumBody);
  const now = Math.floor(Date.now()/1000);
  const deviceId = request.headers.get("neko-device-id") ?? "";
  const timestamp = request.headers.get("neko-timestamp") ?? "";
  const nonce = request.headers.get("neko-nonce") ?? "";
  const signature = request.headers.get("neko-signature") ?? "";
  if (request.headers.get("neko-protocol-version") !== "3" || !/^[A-Za-z0-9_-]{1,128}$/u.test(deviceId)
      || !Number.isSafeInteger(Number(timestamp)) || String(Number(timestamp)) !== timestamp
      || Math.abs(now-Number(timestamp)) > 300) throw new ApiError(401,"invalid_authentication","Group authentication failed.");
  try { base64urlDecode(nonce,16); base64urlDecode(signature,64); }
  catch { throw new ApiError(401,"invalid_authentication","Group authentication failed."); }
  const row = await env.DB.prepare(`SELECT d.id AS deviceId,d.person_id AS personId,d.signing_public_key AS signingPublicKey,
      d.hpke_public_key AS hpkePublicKey,p.identity_public_key AS identityPublicKey
      FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
      WHERE d.id=? AND d.state='active' AND p.state='active'`).bind(deviceId).first<Omit<GroupActor,"nonce"|"now"|"requestHash">>();
  if (!row) throw new ApiError(401,"invalid_authentication","Group authentication failed.");
  const bodyHash = await sha256Base64url(body);
  const pathname = new URL(request.url).pathname;
  const requestHash = await sha256Base64url(groupFields(["NW3.OPERATION",request.method,pathname,base64urlDecode(bodyHash,32)]));
  const message = groupFields(["NW3.REQUEST","3",deviceId,timestamp,nonce,request.method,pathname,base64urlDecode(bodyHash,32)]);
  if (!await verifyEd25519(row.signingPublicKey,signature,message)) throw new ApiError(401,"invalid_authentication","Group authentication failed.");
  await enforceRateLimit(env,env.MEMBER_RATE_LIMITER,`group-device:${deviceId}`);
  const previous = await env.DB.prepare("SELECT 1 AS present FROM group_request_nonces WHERE device_id=? AND nonce=?")
    .bind(deviceId,nonce).first();
  if (previous) throw new ApiError(401,"replay","Group authentication failed.");
  return {actor:{...row,nonce,now,requestHash},body};
}
export interface GroupScope { windowId: string; owner?: boolean; expectedRevision?: number }
export function groupAuthorizationStatements(env: Env, actor: GroupActor, scope?: GroupScope): D1PreparedStatement[] {
  const checkId = crypto.randomUUID();
  return [env.DB.prepare("INSERT INTO group_authorization_checks VALUES (?,?,?,?,?)")
    .bind(checkId,actor.deviceId,scope?.windowId ?? null,scope?.owner === true ? 1 : 0,scope?.expectedRevision ?? null),
    env.DB.prepare("DELETE FROM group_authorization_checks WHERE id=?").bind(checkId)];
}
export function groupNonceStatements(env: Env, actor: GroupActor, scope?: GroupScope): D1PreparedStatement[] {
  return [...groupAuthorizationStatements(env,actor,scope),
    env.DB.prepare("DELETE FROM group_request_nonces WHERE rowid IN (SELECT rowid FROM group_request_nonces WHERE device_id=? AND expires_at<? LIMIT 100)")
    .bind(actor.deviceId,actor.now),
    env.DB.prepare("INSERT INTO group_request_nonces VALUES (?,?,?)").bind(actor.deviceId,actor.nonce,actor.now+601)];
}
export async function requireGroupMember(env: Env, actor: GroupActor, windowId: string, owner = false): Promise<{participantId:string;revision:number;keyEpoch:number;rotationRequired:number}> {
  const row = await env.DB.prepare(`SELECT m.participant_id AS participantId,w.revision,w.key_epoch AS keyEpoch,w.rotation_required AS rotationRequired,m.role
    FROM group_windows w JOIN group_members m ON m.space_id=w.space_id
    JOIN group_window_devices d ON d.space_id=w.space_id AND d.participant_id=m.participant_id
    WHERE w.space_id=? AND w.mode='active' AND m.person_id=? AND m.state='active' AND d.device_id=? AND d.state='active'`)
    .bind(groupId(windowId),actor.personId,actor.deviceId).first<{participantId:string;revision:number;keyEpoch:number;rotationRequired:number;role:string}>();
  if (!row) throw new ApiError(404,"not_found","The group record was not found.");
  if (owner && row.role !== "owner") throw new ApiError(403,"owner_required","The group owner must approve this action.");
  return row;
}
export async function storedGroupMutation(env: Env, actor: GroupActor, operationId: string, scope?: GroupScope): Promise<unknown|null> {
  const previous = await env.DB.prepare("SELECT request_hash,response_json FROM group_mutations WHERE actor_device_id=? AND operation_id=? AND expires_at>?")
    .bind(actor.deviceId,operationId,actor.now).first<{request_hash:string;response_json:string}>();
  if (!previous) return null;
  if (previous.request_hash !== actor.requestHash) throw new ApiError(409,"idempotency_conflict","The operation has different content.");
  const currentScope = scope ? {windowId:scope.windowId,owner:scope.owner === true} : undefined;
  await env.DB.batch(groupNonceStatements(env,actor,currentScope));
  return JSON.parse(previous.response_json) as unknown;
}
export function groupMutationStatement(env: Env, actor: GroupActor, operationId: string, response: unknown): D1PreparedStatement {
  return env.DB.prepare("INSERT INTO group_mutations VALUES (?,?,?,?,?)").bind(actor.deviceId,operationId,actor.requestHash,JSON.stringify(response),actor.now+172800);
}
