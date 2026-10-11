import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFile} from 'node:fs/promises';
import {randomBytes,createHash} from 'node:crypto';
import path from 'node:path';
import {statSync} from 'node:fs';
import {createLocalOwnerReviewHost} from './moderation-owner-review-host.mjs';
import {readBoundedRegularFile} from './moderation-report-lib.mjs';
import {validateExistingRestrictedFile} from './moderation-staging-keygen-lib.mjs';
const fail=()=>{throw Error('owner_review_unavailable')};
export async function verifyWindowsKeyCustody(config,signal){
 if(process.platform!=='win32'||!/^[0-9a-f]{64}$/u.test(config.publicKeySHA256)||!path.isAbsolute(config.brokerRecordFile)
  ||!/^neko-owner-key-check-[0-9a-f-]{36}$/u.test(config.pipeName)||signal?.aborted)fail();
 const recordBytes=await readFile(config.brokerRecordFile);if(recordBytes.length>4096)fail();const record=JSON.parse(recordBytes);
 const client=path.join(import.meta.dirname,'moderation-owner-key-check-client-windows.ps1');
 if(record.pipeName!==config.pipeName||record.publicKeySHA256!==config.publicKeySHA256||path.resolve(record.keyDirectory)!==path.resolve(config.keyDirectory)
  ||createHash('sha256').update(await readFile(client)).digest('hex')!==record.clientScriptSHA256)fail();
 const nonce=randomBytes(32).toString('hex'),expiresAtMs=Date.now()+20000;
 const {stdout}=await promisify(execFile)(path.join(process.env.SystemRoot??'C:/Windows','System32/WindowsPowerShell/v1.0/powershell.exe'),
  ['-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',client,'-BrokerRecord',config.brokerRecordFile,'-Nonce',nonce,'-ExpiresAtMs',String(expiresAtMs)],
  {timeout:20000,windowsHide:true,maxBuffer:4096,signal});
 const proof=JSON.parse(stdout);
 if(signal?.aborted||Object.keys(proof).sort().join(',')!=='custodyVerified,files,keyDirectory,nonce,publicKeySHA256,verifiedAtMs'
  ||proof.nonce!==nonce||proof.custodyVerified!==true||proof.publicKeySHA256!==config.publicKeySHA256
  ||!Number.isSafeInteger(proof.verifiedAtMs)||proof.verifiedAtMs>Date.now()||Date.now()-proof.verifiedAtMs>3000||Date.now()>=expiresAtMs
  ||path.resolve(proof.keyDirectory)!==path.resolve(config.keyDirectory)
  ||!Array.isArray(proof.files)||proof.files.length!==3||new Set(proof.files.map(f=>f.name)).size!==3
  ||proof.files.some(f=>Object.keys(f).sort().join(',')!=='inode,name,size,volume'||!/^moderation-v2\.(private\.raw|public\.base64url|public\.sha256)$/u.test(f.name)
   ||!/^\d+$/u.test(f.inode)||!/^\d+$/u.test(f.volume)||!Number.isSafeInteger(f.size)))fail();
 return proof;
}
/** Only fixed trusted startup code supplies this R2 binding and custody config.
 * The caller's owner handler owns fresh authorization, current source and audit.
 * No ordinary media bucket, disk plaintext, HTTP key route or dynamic key path. */
export function createOwnerR2Transport({bucket,keyDirectory,publicKeySHA256,pipeName,brokerRecordFile,assertScope}){
 if(!bucket||typeof bucket.get!=='function'||typeof assertScope!=='function'||!path.isAbsolute(keyDirectory)||!/^[0-9a-f]{64}$/u.test(publicKeySHA256))fail();
 return async input=>{
  const owned=[];
  try{
   const host=createLocalOwnerReviewHost({
    async readCiphertext(source,signal){
     await assertScope();if(signal.aborted)fail();
     // Source object keys come ONLY from the current authorized D1 snapshot.
     if(source.metadata.moderationKeyId!=='moderation-v2'||source.metadata.ciphertextSize>1048576)fail();
     const object=await bucket.get(source.objectKey);if(signal.aborted){await object?.body?.cancel().catch(()=>{});fail()}if(!object||object.size!==source.metadata.ciphertextSize)fail();
     const reader=object.body.getReader(),buffer=Buffer.alloc(object.size);owned.push(buffer);let offset=0;
     const cancel=()=>{void reader.cancel().catch(()=>{})};signal.addEventListener('abort',cancel,{once:true});
     try{while(true){if(signal.aborted)fail();const chunk=await reader.read();if(signal.aborted)fail();if(chunk.done)break;
      if(offset+chunk.value.length>buffer.length)fail();buffer.set(chunk.value,offset);offset+=chunk.value.length;}
      if(offset!==buffer.length)fail();
     }finally{signal.removeEventListener('abort',cancel);await reader.cancel().catch(()=>{})}
     await assertScope();if(signal.aborted)fail();return buffer;
    },
    async readReviewedKey(id,signal){
     if(id!=='moderation-v2')fail();await assertScope();
     const before=await verifyWindowsKeyCustody({pipeName,publicKeySHA256,keyDirectory,brokerRecordFile},signal);
     const identities=[],read=(name,size)=>{
      const file=path.join(keyDirectory,name),identity=validateExistingRestrictedFile(file,{expectedFilename:name,expectedBytes:size});identities.push(identity);
      if(!before.files.some(f=>f.name===name&&BigInt(f.inode)===identity.inode&&f.size===size))fail();
      const bytes=readBoundedRegularFile(file,size,'owner review key',{requireOwnerOnly:true});owned.push(bytes);return bytes;
     };
     const privateKeyBytes=read(id+'.private.raw',32),companionPublicKeyBytes=read(id+'.public.base64url',43);
     // Validate the current ACL/storage again after reading. The broker neither
     // reads nor transports private keys; its proofs are nonce-bound, uncached.
     const proofAfter=await verifyWindowsKeyCustody({pipeName,publicKeySHA256,keyDirectory,brokerRecordFile},signal);
     for(const identity of identities){const after=statSync(identity.path,{bigint:true});if(after.dev!==identity.device||after.ino!==identity.inode||after.nlink!==1n
      ||!proofAfter.files.some(f=>f.name===path.basename(identity.path)&&BigInt(f.inode)===identity.inode&&f.size===identity.bytes))fail()}
     await assertScope();return {privateKeyBytes,companionPublicKeyBytes,reviewedKeyId:id,expectedPublicKeySHA256:publicKeySHA256};
    },
   });
   return await host(input);
  }catch{fail()}finally{for(const bytes of owned)bytes.fill(0)}
 };
}
