import { readStage } from './read-failure-diagnostic';
import { isIdentityDeletionPath, protectedGroupRead, requireCurrentIdentity } from './group-identity-service';
import { base64urlDecode, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";
import { groupFields } from "./group-protocol";
import { enforceRateLimit, readBody, transientNetworkKey } from "./http";
import {checkTrialActor} from './owner-two-device-trial';

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

type Credential = Omit<GroupActor, 'nonce' | 'now' | 'requestHash'> & { deviceState: 'active' | 'revoked' };
// A missing credential still takes the signature verification path. This
// public test key never authorizes a request, even if verification succeeds.
const dummySigningKey = '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo';
const authenticationFailed = (revoked = false) => new ApiError(401, 'invalid_authentication',
  'Group authentication failed.', revoked ? { reason: 'device_revoked' } : undefined);

function expiredNonces(db: D1Database, deviceId: string, now: number): D1PreparedStatement {
  return db.prepare('DELETE FROM group_request_nonces WHERE rowid IN (SELECT rowid FROM group_request_nonces WHERE device_id=? AND expires_at<? LIMIT 100)')
    .bind(deviceId, now);
}

async function claimRevokedNonce(env: Env, credential: Credential, nonce: string, now: number): Promise<boolean> {
  return protectedGroupRead(env, async () => {
    // Older schemas still reject a revoked device with the original 401.
    if (!await env.DB.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='group_recovery_device_removals'").first()) return false;
    // Recheck the verified credentials and explicit removal at the point the
    // nonce is claimed. A concurrent retry has no claim and gets plain 401.
    const [, claimed] = await env.DB.batch([
      expiredNonces(env.DB, credential.deviceId, now),
      env.DB.prepare(`INSERT INTO group_request_nonces(device_id,nonce,expires_at)
        SELECT d.id,?,? FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
        WHERE d.id=? AND p.id=? AND d.signing_public_key=? AND p.identity_public_key=?
          AND d.state='revoked' AND p.state='active'
          AND EXISTS (SELECT 1 FROM group_recovery_device_removals r WHERE r.device_id=d.id AND r.person_id=p.id)
        ON CONFLICT(device_id,nonce) DO NOTHING RETURNING nonce`)
        .bind(nonce, now + 601, credential.deviceId, credential.personId, credential.signingPublicKey, credential.identityPublicKey),
    ]);
    if (claimed?.results.length !== 1) return false;
    await requireCurrentIdentity(env, credential.personId);
    return true;
  });
}

export function groupId(value: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/u.test(value)) throw new ApiError(404,"not_found","The group record was not found.");
  return value;
}
export async function authenticateGroupRequest(request: Request, env: Env,maximumBody=128*1024,reportWindowId?:string): Promise<{actor:GroupActor;body:Uint8Array}> {
  readStage(request, 'rate_limit');
  await enforceRateLimit(env,env.MEMBER_RATE_LIMITER,transientNetworkKey(request,"group-member"));
  readStage(request, 'body');
  const body = await readBody(request,maximumBody);
  const now = Math.floor(Date.now()/1000);
  const deviceId = request.headers.get("neko-device-id") ?? "";
  const timestamp = request.headers.get("neko-timestamp") ?? "";
  const nonce = request.headers.get("neko-nonce") ?? "";
  const signature = request.headers.get("neko-signature") ?? "";
  readStage(request, 'auth_headers');
  if (request.headers.get("neko-protocol-version") !== "3" || !/^[A-Za-z0-9_-]{1,128}$/u.test(deviceId)
      || !Number.isSafeInteger(Number(timestamp)) || String(Number(timestamp)) !== timestamp
      || Math.abs(now-Number(timestamp)) > 300) throw authenticationFailed();
  readStage(request, 'auth_encoding');
  try { base64urlDecode(nonce,16); base64urlDecode(signature,64); }
  catch { throw authenticationFailed(); }
  const pathname = new URL(request.url).pathname;
  const identityDeletion = isIdentityDeletionPath(pathname);
  const mayReportRevocation = reportWindowId === undefined && !identityDeletion;
  // Ordinary traffic must work before the additive report migration exists.
  // Only the report router may opt into scoped, expiring report-only access.
  readStage(request, 'auth_key_lookup');
  const activeCredential = "d.state='active' AND p.state='active'";
  const credentialPredicate = reportWindowId !== undefined
    ? `(${activeCredential} OR EXISTS (SELECT 1 FROM group_report_access a WHERE a.device_id=d.id AND a.space_id=? AND a.expires_at>unixepoch()))`
    : mayReportRevocation ? "p.state='active'" : activeCredential;
  const credentialQuery = env.DB.prepare(`SELECT d.id AS deviceId,d.person_id AS personId,d.signing_public_key AS signingPublicKey,
      d.hpke_public_key AS hpkePublicKey,p.identity_public_key AS identityPublicKey,d.state AS deviceState
      FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
      WHERE d.id=? AND ${credentialPredicate}`);
  const row=await (reportWindowId===undefined?credentialQuery.bind(deviceId):credentialQuery.bind(deviceId,reportWindowId))
    .first<Credential>();
  const bodyHash = base64urlDecode(await sha256Base64url(body), 32);
  const message = groupFields(["NW3.REQUEST","3",deviceId,timestamp,nonce,request.method,pathname,bodyHash]);
  readStage(request, 'auth_signature');
  const verified = await verifyEd25519(row?.signingPublicKey ?? dummySigningKey, signature, message);
  if (!row || !verified) throw authenticationFailed();
  checkTrialActor(env,row.personId,row.deviceId);
  readStage(request, 'auth_identity');
  if (!identityDeletion) await requireCurrentIdentity(env,row.personId);
  readStage(request, 'auth_device_rate_limit');
  await enforceRateLimit(env,env.MEMBER_RATE_LIMITER,`group-device:${deviceId}`);
  if (mayReportRevocation && row.deviceState === 'revoked') {
    readStage(request, 'auth_nonce_claim');
    throw authenticationFailed(await claimRevokedNonce(env, row, nonce, now));
  }
  // Claim after signature validation, before any handler reads or side effects.
  // A rejected/rolled-back handler must not make these signed bytes reusable.
  readStage(request, 'auth_nonce_cleanup');
  await expiredNonces(env.DB, deviceId, now).run();
  readStage(request, 'auth_nonce_claim');
  const claimed = await env.DB.prepare("INSERT INTO group_request_nonces VALUES (?,?,?) ON CONFLICT(device_id,nonce) DO NOTHING RETURNING nonce")
    .bind(deviceId,nonce,now+601).first();
  if (!claimed) throw new ApiError(401,"replay","Group authentication failed.");
  const requestHash = await sha256Base64url(groupFields(["NW3.OPERATION",request.method,pathname,bodyHash]));
  const { deviceState, ...credential } = row;
  return {actor:{...credential,nonce,now,requestHash},body};
}
export interface GroupScope { windowId: string; owner?: boolean; expectedRevision?: number }
export function groupAuthorizationStatements(env: Env, actor: GroupActor, scope?: GroupScope): D1PreparedStatement[] {
  const checkId = crypto.randomUUID();
  return [env.DB.prepare("INSERT INTO group_authorization_checks VALUES (?,?,?,?,?)")
    .bind(checkId,actor.deviceId,scope?.windowId ?? null,scope?.owner === true ? 1 : 0,scope?.expectedRevision ?? null),
    env.DB.prepare("DELETE FROM group_authorization_checks WHERE id=?").bind(checkId)];
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
  await env.DB.batch(groupAuthorizationStatements(env,actor,currentScope));
  return JSON.parse(previous.response_json) as unknown;
}
export function groupMutationStatement(env: Env, actor: GroupActor, operationId: string, response: unknown): D1PreparedStatement {
  return env.DB.prepare("INSERT INTO group_mutations VALUES (?,?,?,?,?)").bind(actor.deviceId,operationId,actor.requestHash,JSON.stringify(response),actor.now+172800);
}
