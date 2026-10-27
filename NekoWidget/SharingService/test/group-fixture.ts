import { env } from 'cloudflare:workers';
import { expect } from 'vitest';
import type { Env } from '../src/env';
import { errorResponse } from '../src/errors';
import { route } from '../src/index';
import { base64urlDecode,base64urlEncode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupIdentityTranscript } from '../src/group-identities';
import { groupJoinTranscript } from '../src/group-joins';
import { groupDeviceAuthorization,groupFields,groupRosterBytes,type GroupRoster,type GroupRosterMember,type SignedGroupRoster,type GroupKeyEnvelope } from '../src/group-protocol';

export const testEnv={...env as unknown as Env,GROUP_RUNTIME_ENABLED:'YES',BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES',
  BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED:'YES',BILLING_STORE_ENVIRONMENT:'Sandbox',ENVIRONMENT:'local',BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'NO'};
export const db=testEnv.DB;
export async function key() {
  const pair=await crypto.subtle.generateKey({name:'Ed25519'},true,['sign','verify']) as CryptoKeyPair;
  return {privateKey:pair.privateKey,publicKey:base64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey)))};
}
export async function sign(key:CryptoKey,message:Uint8Array):Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign('Ed25519',key,message.slice().buffer)));
}
// Test-only response record; requests still pass through the actual HTTP router,
// WebCrypto signature verification, runtime gates and local D1 transactions.
export type Reply={status:number;data:Record<string,any>};
export async function send(request:Request,settings:Env=testEnv):Promise<Reply> {
  let response:Response;
  try { response=await route(request,settings); } catch(error) { response=errorResponse(error); }
  return {status:response.status,data:await response.json() as Record<string,any>};
}
export async function post(path:string,body:unknown):Promise<Reply> {
  return send(new Request(`https://group.invalid${path}`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}));
}
export async function person(root?:Awaited<ReturnType<typeof key>>,expectedStatus=201) {
  const identity=root??await key(),signing=await key(),hpke=randomBase64url(32);
  const challenge=await post('/v3/group-identities/challenges',{purpose:'register',signingPublicKey:signing.publicKey,hpkePublicKey:hpke});
  expect(challenge.status).toBe(201);
  const operationId=crypto.randomUUID(),transcript=groupIdentityTranscript({operationId,challengeId:challenge.data.challengeId,
    challenge:challenge.data.challenge,expiresAt:challenge.data.expiresAt,personPublicKey:identity.publicKey,
    signingPublicKey:signing.publicKey,hpkePublicKey:hpke});
  const body={operationId,challengeId:challenge.data.challengeId,personPublicKey:identity.publicKey,signingPublicKey:signing.publicKey,
    hpkePublicKey:hpke,personSignature:await sign(identity.privateKey,transcript),deviceSignature:await sign(signing.privateKey,transcript)};
  const result=await post('/v3/group-identities',body);
  expect({status:result.status,error:result.data.error?.code}).toEqual({status:expectedStatus,error:expectedStatus===201?undefined:'device_limit'});
  return {identity,signing,hpke,id:result.data.personId as string,deviceId:result.data.deviceId as string,registration:body};
}
export type Person=Awaited<ReturnType<typeof person>>;
export async function signed(p:Person,path:string,body?:unknown,nonce=randomBase64url(16),verb?:string) {
  const method=verb??(body===undefined?'GET':'POST'),raw=body===undefined?new Uint8Array():body instanceof Uint8Array?body:new TextEncoder().encode(JSON.stringify(body));
  const timestamp=String(Math.floor(Date.now()/1000)),hash=base64urlDecode(await sha256Base64url(raw),32);
  return new Request(`https://group.invalid${path}`,{method,headers:{'content-type':body instanceof Uint8Array?'application/octet-stream':'application/json','neko-protocol-version':'3',
    'neko-device-id':p.deviceId,'neko-timestamp':timestamp,'neko-nonce':nonce,
    'neko-signature':await sign(p.signing.privateKey,groupFields(['NW3.REQUEST','3',p.deviceId,timestamp,nonce,method,path,hash]))},
    ...(body===undefined?{}:{body:raw.slice().buffer})});
}
export async function call(p:Person,path:string,body?:unknown) { return send(await signed(p,path,body)); }
export function ok(result:Reply,status=200) { expect({status:result.status,error:result.data.error?.code}).toEqual({status,error:undefined});return result.data; }
export async function member(p:Person,windowId:string,role:'owner'|'member'='member',participantId=randomBase64url(16)):Promise<GroupRosterMember> {
  const device={id:p.deviceId,signingPublicKey:p.signing.publicKey,hpkePublicKey:p.hpke,personAuthorization:''};
  device.personAuthorization=await sign(p.identity.privateKey,groupDeviceAuthorization(windowId,p.id,device));
  return {participantId,personId:p.id,identityPublicKey:p.identity.publicKey,role,devices:[device]};
}
export function cipher() { return randomBase64url(48); }
export async function packet(owner:Person,roster:GroupRoster) {
  const bytes=groupRosterBytes(roster),hash=await sha256Base64url(bytes);
  const signed:SignedGroupRoster={roster,signerDeviceId:owner.deviceId,
    signature:await sign(owner.signing.privateKey,groupFields(['NW3.ROSTER.SIGN',bytes,owner.deviceId]))};
  const envelopes:GroupKeyEnvelope[]=[];
  for(const d of roster.members.flatMap(m=>m.devices)) {
    const enc=randomBase64url(32),ct=randomBase64url(48);
    const info=groupFields(['NW3.KEY',roster.windowId,String(roster.keyEpoch),base64urlDecode(hash,32),d.id]);
    envelopes.push({windowId:roster.windowId,keyEpoch:roster.keyEpoch,rosterHash:hash,deviceId:d.id,encapsulatedKey:enc,ciphertext:ct,
      signerDeviceId:owner.deviceId,signature:await sign(owner.signing.privateKey,groupFields(['NW3.KEY.SIGN',info,base64urlDecode(enc),base64urlDecode(ct),owner.deviceId]))});
  }
  return {packet:signed,envelopes,encryptedName:cipher(),encryptedMemberNames:Object.fromEntries(roster.members.map(m=>[m.participantId,cipher()])),hash};
}
export async function create(owner:Person,status=201,errorCode='owned_window_limit') {
  const windowId=randomBase64url(16),roster:GroupRoster={windowId,revision:1,keyEpoch:1,previousHash:base64urlEncode(new Uint8Array(32)),
    ownerPersonId:owner.id,members:[await member(owner,windowId,'owner')]};
  const data=await packet(owner,roster),{hash,...wire}=data,operationId=crypto.randomUUID();
  const response=await call(owner,'/v3/group-windows',{operationId,...wire});
  if(status===201) ok(response,201);
  else expect({status:response.status,code:response.data.error?.code}).toEqual({status,code:errorCode});
  return {windowId,roster,hash};
}
export async function invitation(owner:Person,w:Awaited<ReturnType<typeof create>>) {
  const proof=await key(),data=ok(await call(owner,`/v3/group-windows/${w.windowId}/invitations`,{
    operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,proofPublicKey:proof.publicKey}),201);
  return {proof,id:data.invitationId as string};
}
export async function apply(p:Person,w:Awaited<ReturnType<typeof create>>,invite:Awaited<ReturnType<typeof invitation>>) {
  const root=`/v3/group-windows/${w.windowId}`,challenge=ok(await call(p,`${root}/invitation-challenges`,{invitationId:invite.id}),201);
  const m=await member(p,w.windowId),operationId=crypto.randomUUID(),encryptedDisplayName=cipher(),personAuthorization=m.devices[0]!.personAuthorization;
  const transcript=groupJoinTranscript({windowId:w.windowId,invitationId:invite.id,challengeId:challenge.challengeId,challenge:challenge.challenge,
    expiresAt:challenge.expiresAt,operationId,personId:p.id,deviceId:p.deviceId,encryptedNameHash:await sha256Base64url(base64urlDecode(encryptedDisplayName)),personAuthorization});
  const response=await call(p,`${root}/join-requests`,{operationId,invitationId:invite.id,challengeId:challenge.challengeId,personId:p.id,
    candidateDeviceId:p.deviceId,encryptedDisplayName,personAuthorization,inviteProof:await sign(invite.proof.privateKey,transcript),deviceSignature:await sign(p.signing.privateKey,transcript)});
  return {response,member:m,id:response.data.requestId as string};
}
export async function transition(owner:Person,w:Awaited<ReturnType<typeof create>>,kind:'admit'|'remove'|'rotate'|'addDevice',targetId:string,members:GroupRosterMember[],extra={}) {
  const roster:GroupRoster={...w.roster,revision:w.roster.revision+1,keyEpoch:w.roster.keyEpoch+1,previousHash:w.hash,members};
  const data=await packet(owner,roster),{hash,...wire}=data;
  const body={operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,kind,targetId,...wire,...extra};
  const path=kind==='admit'?`join-requests/${targetId}/approve`:kind==='remove'?`members/${targetId}/remove`:kind==='rotate'?'rotate':'devices/admit';
  const response=await call(owner,`/v3/group-windows/${w.windowId}/${path}`,body);
  return {response,body,next:{windowId:w.windowId,roster,hash}};
}

