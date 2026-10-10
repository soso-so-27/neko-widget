import path from 'node:path';
import {createLocalOwnerReviewHost} from './moderation-owner-review-host.mjs';
import {moderationReviewSourceBinding} from './moderation-bound-review-lib.mjs';
import {readBoundedRegularFile} from './moderation-report-lib.mjs';
import {validateExistingRestrictedFile} from './moderation-staging-keygen-lib.mjs';
import {SYNTHETIC_CANONICAL_JPEG} from './moderation-staging-drill-lib.mjs';

const unavailable=()=>{throw Error('owner_review_unavailable');};
const exact=(value,keys)=>{if(!value||Object.getPrototypeOf(value)!==Object.prototype||Object.keys(value).length!==keys.length||keys.some(k=>!Object.hasOwn(value,k)))unavailable();};
const digest=value=>typeof value==='string'&&/^[0-9a-f]{64}$/u.test(value);

/** Trusted local administration supplies an exact allowlist. Browser values
 * never choose files, keys, transport or permissions. Authorization, one-use
 * claims and current source checks remain in the existing owner handler. */
export function validateOwnerFileTransport(value) {
  exact(value,['schemaVersion','kind','entries']);
  if(value.schemaVersion!==1||value.kind!=='synthetic-local'||!Array.isArray(value.entries)||value.entries.length!==1)unavailable();
  for(const e of value.entries){
    exact(e,['caseReferenceHmac','caseReferenceHmacKeyVersion','sourceSHA256','ciphertextFile','ciphertextSize','moderationKeyId','keyDirectory','expectedPublicKeySHA256']);
    if(!digest(e.caseReferenceHmac)||e.caseReferenceHmacKeyVersion!==1||!digest(e.sourceSHA256)||!digest(e.expectedPublicKeySHA256)
      ||e.moderationKeyId!=='moderation-v2'||!Number.isSafeInteger(e.ciphertextSize)||e.ciphertextSize<29||e.ciphertextSize>1048576
      ||!path.isAbsolute(e.ciphertextFile)||!path.isAbsolute(e.keyDirectory))unavailable();
  }
  return structuredClone(value);
}

export function createOwnerFileTransport(value) {
  const config=validateOwnerFileTransport(value);
  const entry=Object.freeze(config.entries[0]);
  return async input=>{
    const owned=[];
    try{
      const binding=moderationReviewSourceBinding(input.source,{caseReferenceHmac:entry.caseReferenceHmac,caseReferenceHmacKeyVersion:entry.caseReferenceHmacKeyVersion});
      if(binding.sourceSHA256!==entry.sourceSHA256||binding.source.metadata.moderationKeyId!==entry.moderationKeyId||binding.source.metadata.ciphertextSize!==entry.ciphertextSize)unavailable();
      const active=()=>{if(input.signal?.aborted)unavailable();};
      const host=createLocalOwnerReviewHost({
        async readCiphertext(){
          active();validateExistingRestrictedFile(entry.ciphertextFile,{expectedFilename:'synthetic-report.ciphertext',expectedBytes:entry.ciphertextSize});
          const bytes=readBoundedRegularFile(entry.ciphertextFile,entry.ciphertextSize,'ciphertext',{requireOwnerOnly:true});owned.push(bytes);active();return bytes;
        },
        async readReviewedKey(id){
          active();if(id!==entry.moderationKeyId)unavailable();
          // This transport is synthetic-only. It cannot release arbitrary
          // decrypted content; the fixed harmless JPEG is checked below.
          const read=(name,size)=>{const file=path.join(entry.keyDirectory,name);validateExistingRestrictedFile(file,{expectedFilename:name,expectedBytes:size});const bytes=readBoundedRegularFile(file,size,'review key',{requireOwnerOnly:true});owned.push(bytes);return bytes;};
          const privateKeyBytes=read(id+'.private.raw',32),companionPublicKeyBytes=read(id+'.public.base64url',43);active();
          return {privateKeyBytes,companionPublicKeyBytes,reviewedKeyId:id,expectedPublicKeySHA256:entry.expectedPublicKeySHA256};
        },
      });
      const jpeg=await host(input);
      if(!Buffer.from(jpeg).equals(SYNTHETIC_CANONICAL_JPEG)){jpeg.fill(0);unavailable();}
      return jpeg;
    }catch{unavailable();}finally{for(const bytes of owned)bytes.fill(0);}
  };
}
