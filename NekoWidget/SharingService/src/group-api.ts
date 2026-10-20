import { ApiError } from './errors';
import type { Env } from './env';
import { authenticateGroupRequest,groupId } from './group-auth';
import { createGroupIdentityChallenge,registerGroupIdentity } from './group-identities';
import { createGroupJoinChallenge,createGroupJoinRequest,getGroupJoinStatus,resolveGroupJoinRequest } from './group-joins';
import { leaveGroupWindow,transitionGroupMembership } from './group-members';
import { getGroupKey,listGroupJoinRequests,listGroupMembers,listGroupRosters } from './group-reads';
import { createGroupInvitation,createGroupWindow,getGroupWindow,listGroupWindows,revokeGroupInvitation } from './group-windows';
import { parseJsonBody,requireEmptyBody } from './http';

export async function groupAPI(request:Request,env:Env):Promise<Response> {
  try { return await dispatchGroup(request,env); }
  catch(error) {
    if(error instanceof ApiError) {
      if(error.code==='stale_revision' && error.status===400) throw new ApiError(409,error.code,error.message);
      throw error;
    }
    // Only fixed public codes leave this boundary. SQL/constraint details,
    // ciphertext, names, request bodies and signatures are never logged.
    const message=error instanceof Error?error.message:'';
    const codes:[string,number,string][]=[
      ['group_total_window_limit',409,'total_window_limit'],['group_owned_window_limit',409,'owned_window_limit'],
      ['group_member_limit',409,'member_limit'],['group_device_limit',409,'device_limit'],
      ['group_stale_revision_or_epoch',409,'stale_revision'],['group_request_not_pending',409,'request_not_pending'],
      ['group_invitation_expired_or_revoked',410,'invitation_expired'],['group_challenge_expired_or_used',410,'challenge_expired'],
      ['group_pending_request_limit',429,'rate_limited'],['group_invalid_join_request',410,'invitation_revoked'],
      ['group_invalid_authentication',401,'invalid_authentication'],['group_not_member_or_owner',404,'not_found'],
      ['group_owner_required',403,'owner_required'],['group_request_nonces.device_id',401,'replay'],
      ['group_mutations.actor_device_id',409,'idempotency_conflict'],['group_one_pending_request',409,'request_not_pending'],
      ['group_join_requests.invitation_id',409,'request_not_pending'],
      ['group_rosters.space_id',409,'stale_revision'],['group_epoch_transitions.id',409,'idempotency_conflict'],
    ];
    for(const [marker,status,code] of codes) if(message.includes(marker)) throw new ApiError(status,code,'The group operation could not be completed.');
    throw error;
  }
}
async function dispatchGroup(request:Request,env:Env):Promise<Response> {
  const path=new URL(request.url).pathname;
  if(request.method==='POST' && path==='/v3/group-identities/challenges') return createGroupIdentityChallenge(request,env);
  if(request.method==='POST' && path==='/v3/group-identities') return registerGroupIdentity(request,env);
  if(!path.startsWith('/v3/group-windows')) throw new ApiError(404,'not_found','The endpoint was not found.');
  const {actor,body:bytes}=await authenticateGroupRequest(request,env);
  if(request.method==='GET') requireEmptyBody(bytes);
  else if(request.method!=='POST') throw new ApiError(405,'method_not_allowed','The method is not supported.');
  const body=request.method==='POST'?parseJsonBody(request,bytes):undefined;
  if(path==='/v3/group-windows' && body) return createGroupWindow(env,actor,body);
  if(path==='/v3/group-windows/list' && body) return listGroupWindows(env,actor,body);
  const match=path.match(/^\/v3\/group-windows\/([A-Za-z0-9_-]{1,128})(?:\/(.*))?$/u);
  if(!match) throw new ApiError(404,'not_found','The endpoint was not found.');
  const windowId=groupId(match[1]!),suffix=match[2]??'';
  if(suffix==='' && request.method==='GET') return getGroupWindow(env,actor,windowId);
  const key=suffix.match(/^keys\/([1-9][0-9]{0,14})$/u);
  if(key && request.method==='GET') return getGroupKey(env,actor,windowId,Number(key[1]));
  if(!body) throw new ApiError(404,'not_found','The endpoint was not found.');
  if(suffix==='invitations') return createGroupInvitation(env,actor,windowId,body);
  const revoke=suffix.match(/^invitations\/([A-Za-z0-9_-]{1,128})\/revoke$/u);
  if(revoke) return revokeGroupInvitation(env,actor,windowId,revoke[1]!,body);
  if(suffix==='invitation-challenges') return createGroupJoinChallenge(env,actor,windowId,body);
  if(suffix==='join-requests') return createGroupJoinRequest(env,actor,windowId,body);
  if(suffix==='join-status') return getGroupJoinStatus(env,actor,windowId,body);
  if(suffix==='join-requests/list') return listGroupJoinRequests(env,actor,windowId,body);
  if(suffix==='members/list') return listGroupMembers(env,actor,windowId,body);
  if(suffix==='rosters/list') return listGroupRosters(env,actor,windowId,body);
  if(suffix==='leave') return leaveGroupWindow(env,actor,windowId,body);
  if(suffix==='rotate') return transitionGroupMembership(env,actor,windowId,'rotate',windowId,body);
  if(suffix==='devices/admit') return transitionGroupMembership(env,actor,windowId,'addDevice',typeof body.targetId==='string'?body.targetId:'',body);
  const member=suffix.match(/^members\/([A-Za-z0-9_-]{1,128})\/remove$/u);
  if(member) return transitionGroupMembership(env,actor,windowId,'remove',member[1]!,body);
  const device=suffix.match(/^devices\/([A-Za-z0-9_-]{1,128})\/remove$/u);
  if(device) return transitionGroupMembership(env,actor,windowId,'removeDevice',device[1]!,body);
  const join=suffix.match(/^join-requests\/([A-Za-z0-9_-]{1,128})\/(approve|reject|cancel)$/u);
  if(join) {
    if(join[2]==='approve') return transitionGroupMembership(env,actor,windowId,'admit',join[1]!,body);
    return resolveGroupJoinRequest(env,actor,windowId,join[1]!,body,join[2]==='reject'?'rejected':'cancelled');
  }
  throw new ApiError(404,'not_found','The endpoint was not found.');
}
