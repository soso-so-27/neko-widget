import { ApiError } from './errors';
import { base64urlDecode,sha256Base64url } from './encoding';
import { groupFields } from './group-protocol';

const prefix='group-identity-deletions/v1/';
const hash=(tag:string,value:string)=>sha256Base64url(groupFields(['NW3.DELETION.V1',tag,value]));
export interface Claim {personDigest:string;requestId:string;receiptDigest:string;requestHash:string;acceptedAt:number}
const notFound=()=>new ApiError(404,'not_found','The deletion request was not found.');
const conflict=()=>new ApiError(409,'idempotency_conflict','The request has different content.');
const unavailable=()=>new ApiError(503,'unavailable','The deletion could not be verified.');
const validId=(id:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id);
async function readClaim(store:R2Bucket,key:string):Promise<Claim|null> {
  const obj=await store.get(key); if (!obj) return null;
  if(obj.size<1 || obj.size>1024)throw unavailable();
  let c:unknown;try {c=await obj.json();} catch {throw unavailable();}
  if (!c || typeof c!=='object')throw unavailable();
  const v=c as Claim;
  if (Object.keys(v).sort().join(',')!=='acceptedAt,personDigest,receiptDigest,requestHash,requestId' || typeof v.requestId!=='string' || !validId(v.requestId) || !Number.isSafeInteger(v.acceptedAt) || v.acceptedAt<=0
      || typeof v.personDigest!=='string' || typeof v.receiptDigest!=='string' || typeof v.requestHash!=='string' || !/^[A-Za-z0-9_-]{43}$/.test(v.requestHash) || !/^[A-Za-z0-9_-]{43}$/.test(v.personDigest) || !/^[A-Za-z0-9_-]{43}$/.test(v.receiptDigest))throw unavailable();
  return v;
}
async function first(store:R2Bucket,key:string,claim:Claim) {
  const created=await store.put(key,JSON.stringify(claim),{onlyIf:{etagDoesNotMatch:'*'}});
  if(created)return claim;
  const saved=await readClaim(store,key);
  if(!saved)throw unavailable();
  if(saved.requestId!==claim.requestId || saved.personDigest!==claim.personDigest || saved.receiptDigest!==claim.receiptDigest || saved.requestHash!==claim.requestHash) throw conflict();
  return saved;
}
// An authenticated request may claim the locator before the per-person fence.
// It is safe to retry that exact write after a disconnect. No completed state
// is emitted by this component: the closure and restore barrier must supply it.
export async function acceptIdentityFence(store:R2Bucket,personId:string,id:string,receipt:string,requestHash:string,now:number) {
  if(!validId(id)||!Number.isSafeInteger(now)||now<=0)throw new ApiError(400,'invalid_request','Invalid deletion request.');
  base64urlDecode(receipt,32);base64urlDecode(requestHash,32);
  const [personDigest,receiptDigest]=await Promise.all([hash('person',personId),hash('receipt',receipt)]);
  const claim={requestId:id,personDigest,receiptDigest,requestHash,acceptedAt:now};
  return persistIdentityClaim(store,claim);
}
export async function prepareIdentityClaim(store:R2Bucket,personId:string,id:string,receipt:string,requestHash:string,now:number):Promise<Claim>{
  const [personDigest,receiptDigest]=await Promise.all([hash('person',personId),hash('receipt',receipt)]);
  const proposed={requestId:id,personDigest,receiptDigest,requestHash,acceptedAt:now};
  for(const key of [prefix+'requests/'+id,prefix+'people/'+personDigest]) {
    const old=await readClaim(store,key);if(!old)continue;
    if(old.requestId!==id || old.personDigest!==personDigest||old.receiptDigest!==receiptDigest || old.requestHash!==requestHash)throw conflict();
    proposed.acceptedAt=old.acceptedAt;
  }
  return proposed;
}
export async function matchesAuthenticatedClaim(claim:Claim,personId:string,id:string,at:number){
 const digest=/^[A-Za-z0-9_-]{43}$/;
 return claim && Object.keys(claim).sort().join(',')==='acceptedAt,personDigest,receiptDigest,requestHash,requestId'
   && claim.personDigest===await hash('person',personId) && claim.requestId===id && claim.acceptedAt===at
   && typeof claim.receiptDigest==='string' && digest.test(claim.receiptDigest)
   && typeof claim.requestHash==='string' && digest.test(claim.requestHash);
}
export async function persistIdentityClaim(store:R2Bucket,claim:Claim){
  const saved=await first(store,prefix+'requests/'+claim.requestId,claim);
  return first(store,prefix+'people/'+claim.personDigest,saved);
}
export async function readPersonIdentityFence(store:R2Bucket,personId:string) {
  const digest=await hash('person',personId),c=await readClaim(store,prefix+'people/'+digest);
  if(c && c.personDigest!==digest)throw unavailable();
  return c;
}
export async function personIsFenced(store:R2Bucket,personId:string) {
  return (await readPersonIdentityFence(store,personId))!==null;
}
export async function lookupIdentityFence(store:R2Bucket,id:string,receipt:string) {
  if(!validId(id))throw notFound();
  try {base64urlDecode(receipt,32);} catch {throw notFound();}
  const claim=await readClaim(store,prefix+'requests/'+id);
  if(!claim || claim.requestId!==id || claim.receiptDigest!==await hash('receipt',receipt))throw notFound();
  // The authenticated claim already exists. Recover a lost second write on GET
  // using only that original claim, without renewing its acceptance time.
  const fence=await first(store,prefix+'people/'+claim.personDigest,claim);
  return {protocolVersion:3,requestId:id,state:'processing' as const,acceptedAt:fence.acceptedAt,completedAt:null};
}
