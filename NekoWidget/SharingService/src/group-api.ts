import { ApiError } from './errors';
import type { Env } from './env';
import { authenticateGroupRequest,groupId } from './group-auth';
import { createGroupIdentityChallenge,registerGroupIdentity } from './group-identities';
import { createGroupJoinChallenge,createGroupJoinRequest,getGroupJoinStatus,resolveGroupJoinRequest } from './group-joins';
import { leaveGroupWindow,transitionGroupMembership } from './group-members';
import { getGroupKey,listGroupJoinRequests,listGroupMembers,listGroupRosters } from './group-reads';
import { createGroupInvitation,createGroupWindow,getGroupWindow,listGroupWindows,revokeGroupInvitation } from './group-windows';
import { parseJsonBody,requireEmptyBody } from './http';
import { connectGroupBilling } from './group-owner-plus';
import { acknowledgeGroupPhoto,commitGroupPhoto,getGroupPhoto,GROUP_MAX_CIPHERTEXT,listGroupPhotos,reserveGroupPhoto,uploadGroupPhoto } from './group-media';
import { listGroupHearts,recordGroupHeart,setGroupBlock } from './group-hearts';
import { groupReportAPI,isGroupReportPath } from './group-reports';
import { registerGroupPush } from './group-push';
import { manageGroupWindow } from './group-management';

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
      ['group_owner_plus_required',403,'owner_plus_required'],['group_window_paused',403,'window_paused'],
      ['group_billing_connection_invalid',401,'invalid_billing_authentication'],
      ['group_billing_connections.',409,'billing_connection_conflict'],['billing_request_nonces.',401,'replayed_billing_request'],
      ['group_photo_daily_limit',409,'daily_limit'],['group_heart_daily_limit',409,'daily_limit'],
      ['group_stale_epoch_or_membership',409,'stale_epoch'],['group_reservation_expired_or_stale',409,'reservation_expired'],
      ['group_reservation_expired',410,'reservation_expired'],
      ['group_delivery_unavailable',410,'delivery_expired'],['group_moments.space_id',409,'idempotency_conflict'],
      ['group_rosters.space_id',409,'stale_revision'],['group_epoch_transitions.id',409,'idempotency_conflict'],
      ['group_report_gate_closed',503,'report_ingestion_runtime_disabled'],['group_report_not_authorized',403,'report_not_authorized'],
      ['group_report_not_delivered',404,'reportable_moment_not_found'],['group_report_already_reported',409,'already_reported'],
      ['group_report_daily_limit',429,'report_daily_quota_exceeded'],['group_report_key_required',409,'moderation_key_required'],
      ['group_reports.moment_id',409,'already_reported'],['group_report_invalid_',409,'report_conflict'],
      ['group_push_gate_closed',503,'group_push_disabled'],
      ['group_name_stale_revision',409,'stale_name_revision'],
    ];
    for(const [marker,status,code] of codes) if(message.includes(marker)) throw new ApiError(status,code,'The group operation could not be completed.');
    throw error;
  }
}
async function dispatchGroup(request:Request,env:Env):Promise<Response> {
  const path=new URL(request.url).pathname;
  if(isGroupReportPath(path))return groupReportAPI(request,env);
  if(request.method==='POST' && path==='/v3/group-identities/challenges') return createGroupIdentityChallenge(request,env);
  if(request.method==='POST' && path==='/v3/group-identities') return registerGroupIdentity(request,env);
  if(!path.startsWith('/v3/group-windows')) throw new ApiError(404,'not_found','The endpoint was not found.');
  const upload=request.method==='PUT' && /^\/v3\/group-windows\/[A-Za-z0-9_-]{22}\/moments\/[A-Za-z0-9_-]{22}\/ciphertext$/u.test(path);
  const {actor,body:bytes}=await authenticateGroupRequest(request,env,upload?GROUP_MAX_CIPHERTEXT:128*1024);
  if(request.method==='GET') requireEmptyBody(bytes);
  else if(request.method!=='POST' && !upload) throw new ApiError(405,'method_not_allowed','The method is not supported.');
  const body=request.method==='POST'?parseJsonBody(request,bytes):undefined;
  if(path==='/v3/group-windows/billing-connection' && body)return connectGroupBilling(request,env,actor,bytes,body);
  if(path==='/v3/group-windows' && body) return createGroupWindow(env,actor,body);
  if(path==='/v3/group-windows/list' && body) return listGroupWindows(env,actor,body);
  const match=path.match(/^\/v3\/group-windows\/([A-Za-z0-9_-]{1,128})(?:\/(.*))?$/u);
  if(!match) throw new ApiError(404,'not_found','The endpoint was not found.');
  const windowId=groupId(match[1]!),suffix=match[2]??'';
  if(suffix==='' && request.method==='GET') return getGroupWindow(env,actor,windowId);
  const photo=suffix.match(/^moments\/([A-Za-z0-9_-]{22})(?:\/(ciphertext|commit|ack|hearts|hearts\/list))?$/u);
  if(photo && upload) {
    if(request.headers.get('content-type')!=='application/octet-stream')throw new ApiError(415,'invalid_content_type','The photo must be encrypted bytes.');
    return uploadGroupPhoto(env,actor,windowId,photo[1]!,bytes);
  }
  if(photo && request.method==='GET' && (!photo[2] || photo[2]==='ciphertext'))return getGroupPhoto(env,actor,windowId,photo[1]!,photo[2]==='ciphertext');
  const key=suffix.match(/^keys\/([1-9][0-9]{0,14})$/u);
  if(key && request.method==='GET') return getGroupKey(env,actor,windowId,Number(key[1]));
  if(!body) throw new ApiError(404,'not_found','The endpoint was not found.');
  if(suffix==='name')return manageGroupWindow(env,actor,windowId,body);
  if(suffix==='close')return manageGroupWindow(env,actor,windowId,body,true);
  if(suffix==='push-subscription')return registerGroupPush(env,actor,windowId,body);
  if(suffix==='push-subscription/remove')return registerGroupPush(env,actor,windowId,body,true);
  if(suffix==='moments/reserve')return reserveGroupPhoto(env,actor,windowId,body);
  if(suffix==='moments/list')return listGroupPhotos(env,actor,windowId,body);
  if(photo && photo[2]==='commit')return commitGroupPhoto(env,actor,windowId,photo[1]!,body);
  if(photo && photo[2]==='ack')return acknowledgeGroupPhoto(env,actor,windowId,photo[1]!,body);
  if(photo && photo[2]==='hearts') {
    if(env.REACTION_RUNTIME_ENABLED!=='YES')throw new ApiError(503,'reactions_disabled','Hearts are unavailable.');
    return recordGroupHeart(env,actor,windowId,photo[1]!,body);
  }
  if(photo && photo[2]==='hearts/list')return listGroupHearts(env,actor,windowId,photo[1]!,body);
  const block=suffix.match(/^blocks\/([A-Za-z0-9_-]{22})$/u);
  if(block)return setGroupBlock(env,actor,windowId,block[1]!,body);
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
