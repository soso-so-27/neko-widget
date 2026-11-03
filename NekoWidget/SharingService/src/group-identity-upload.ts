import {ApiError} from './errors';
import type {Env} from './env';

// With A1 enabled, uploaded bytes must replace a particular reservation.
// An upload that resumes after erasure cannot recreate the object using an
// old ETag, even if the request terminates before its final D1 check.
export async function putGroupUpload(env:Env,bucket:R2Bucket,key:string,data:Uint8Array,opts:R2PutOptions,
  authorize:()=>Promise<void>):Promise<R2Object|null> {
  if(env.GROUP_IDENTITY_ERASURE_ENABLED!=='YES')
    return bucket.put(key,data,{...opts,onlyIf:{etagDoesNotMatch:'*'}});
  let observed=await bucket.head(key);
  if(!observed){
    observed=await bucket.put(key,crypto.randomUUID(),{onlyIf:{etagDoesNotMatch:'*'},customMetadata:{scope:'neko-upload-reservation-v1'}});
    if(!observed)observed=await bucket.head(key);
  }
  if(!observed)throw new ApiError(503,'unavailable','The upload is unavailable.');
  if(observed.customMetadata?.scope!=='neko-upload-reservation-v1')return null;
  // Reauthorize AFTER creating the non-content placeholder. Closures remove
  // only their own reservation keys. Never overwrite a real ciphertext here.
  await authorize();
  return bucket.put(key,data,{...opts,onlyIf:{etagMatches:observed.etag}});
}
