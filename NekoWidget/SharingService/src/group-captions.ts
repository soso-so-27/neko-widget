import type { Env } from './env';
import type { GroupActor } from './group-auth';
import { base64urlDecode,verifyEd25519 } from './encoding';
import { groupFields } from './group-protocol';
import { asObject,binaryField,exactKeys,integerField,type JsonRecord } from './validation';
import { ApiError } from './errors';

export interface GroupCaptionDescriptor {ciphertextSize:number;ciphertextSHA256:string;senderSignature:string}
export function groupCaptionTranscript(input:{windowId:string;clientMomentId:string;keyEpoch:number;rosterHash:string;
  participantId:string;deviceId:string;photoHash:string;size:number;hash:string}):Uint8Array {
  const aad=groupFields(['NW3.CAPTION',input.windowId,input.clientMomentId,String(input.keyEpoch),
    base64urlDecode(input.rosterHash,32),input.participantId,input.deviceId,base64urlDecode(input.photoHash,32),String(input.size)]);
  return groupFields(['NW3.CAPTION.SIGN',aad,base64urlDecode(input.hash,32)]);
}
export async function parseGroupCaption(actor:GroupActor,windowId:string,participantId:string,body:JsonRecord,rosterHash:string):Promise<GroupCaptionDescriptor|null> {
  if(body.caption===undefined)return null;
  const caption=asObject(body.caption);exactKeys(caption,['ciphertextSize','ciphertextSHA256','senderSignature']);
  const size=integerField(caption,'ciphertextSize',29,4124),hash=binaryField(caption,'ciphertextSHA256',32),signature=binaryField(caption,'senderSignature',64);
  const transcript=groupCaptionTranscript({windowId,clientMomentId:body.clientMomentId as string,keyEpoch:body.keyEpoch as number,
    rosterHash,participantId,deviceId:actor.deviceId,photoHash:body.ciphertextSHA256 as string,size,hash});
  if(!await verifyEd25519(actor.signingPublicKey,signature,transcript))throw new ApiError(400,'invalid_signature','The caption signature is invalid.');
  return {ciphertextSize:size,ciphertextSHA256:hash,senderSignature:signature};
}
export function groupCaption(env:Env,momentId:string):Promise<GroupCaptionDescriptor|null> {
  return env.DB.prepare('SELECT ciphertext_size AS ciphertextSize,ciphertext_sha256 AS ciphertextSHA256,sender_signature AS senderSignature FROM group_photo_captions WHERE moment_id=?')
    .bind(momentId).first<GroupCaptionDescriptor>();
}
