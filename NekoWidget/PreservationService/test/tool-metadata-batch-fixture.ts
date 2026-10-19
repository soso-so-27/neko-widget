import {env} from 'cloudflare:workers';
import {expect,it} from 'vitest';
import {DurableAuth} from '../src/auth';
import {ArchiveStore} from '../src/storage';
import {OwnerRecoveryCopy} from '../src/owner-recovery-copy';
import {RecordRecoveryCopy} from '../src/record-recovery-copy';
import {S3RecoveryCopy} from '../src/s3-recovery-copy';
import {RecoveryWriteLease} from '../src/recovery-write-lease';
import {envelopeKeyCustody} from '../src/key-custody';
import {randomToken,sha256,type ArchiveDocument} from '../src/contracts';
import {syntheticKeyAuthority} from './key-fixture';

export const {DB:db,ARCHIVE:bucket}=env as unknown as {DB:D1Database;ARCHIVE:R2Bucket};
export const encoder=new TextEncoder();
export const base:ArchiveDocument={formatVersion:3,text:'synthetic',capturedAt:null,writtenAt:null,updatedAt:null,catNames:[],photoFile:null};
export async function fixture(){
  await db.prepare('UPDATE pa_recovery_write_policy SET delete_intent_required=0,owner_snapshot_required=0 WHERE singleton=1').run();
  const authority=await syntheticKeyAuthority(),wrapper=authority.make(),count={wrap:0,unwrap:0,GET:0,PUT:0,HEAD:0};
  const keys=envelopeKeyCustody({enabled:true,wrapper:{wrap:(...args)=>{count.wrap++;return wrapper.wrap(...args);},
    unwrap:(...args)=>{count.unwrap++;return wrapper.unwrap(...args);}}});
  const secret=randomToken(),objects=new Map<string,{body:Uint8Array;checksum:string;version:string}>();
  let time=Date.now();
  const now=()=>time;
  const s3=new S3RecoveryCopy({enabled:'YES',region:'ap-northeast-1',bucket:'synthetic-recovery',expectedAccountId:'123456789012',accessKeyId:'synthetic',secretAccessKey:'synthetic'},
    async(url,init)=>{
      const request=new URL(String(url)),key=decodeURIComponent(request.pathname.slice(1)),method=init!.method as 'GET'|'PUT'|'HEAD';
      count[method]++;
      if(method==='PUT'){
        if(objects.has(key))return new Response(null,{status:412});
        const body=new Uint8Array(init!.body as ArrayBuffer),checksum=new Headers(init!.headers).get('x-amz-checksum-sha256')!;
        expect(await sha256(body)).toBe([...Uint8Array.from(atob(checksum),c=>c.charCodeAt(0))].map(n=>n.toString(16).padStart(2,'0')).join(''));
        objects.set(key,{body:body.slice(),checksum,version:crypto.randomUUID()});
      }
      const object=objects.get(key);
      if(!object)return new Response(null,{status:404});
      if(request.searchParams.has('versionId'))expect(request.searchParams.get('versionId')).toBe(object.version);
      return new Response(method==='GET'?object.body.slice():null,{headers:{'x-amz-version-id':object.version,
        'x-amz-checksum-sha256':object.checksum,'x-amz-checksum-type':'FULL_OBJECT','content-length':String(object.body.length)}});
    },new RecoveryWriteLease(db,now));
  const ownerCopy=()=>new OwnerRecoveryCopy(keys,s3,secret,{pagedWrites:true,compressWrites:true});
  const auth=new DurableAuth({db,keys,identityIndexSecret:secret,now});
  const session=await auth.establish({issuer:'https://appleid.apple.com',subject:crypto.randomUUID(),refreshToken:randomToken()});
  await ownerCopy().copyCurrent(db,session.ownerId,now());
  await db.prepare('UPDATE pa_recovery_write_policy SET delete_intent_required=1,owner_snapshot_required=1 WHERE singleton=1').run();
  const options={db,bucket,keys,auth,now,membership:{status:async()=>'active' as const},photos:{validateJPEG:async()=>true},
    quotaBytes:128*1024*1024,maximumRecords:100_000,recovery:new RecordRecoveryCopy(keys,s3),ownerRecovery:ownerCopy(),requireRecovery:true,requireOwnerRecovery:true};
  const archive=()=>new ArchiveStore({...options,ownerRecovery:ownerCopy()});
  const snapshot=crypto.randomUUID();
  const part=async(id:string,path:string,raw:string,kind:'index'|'json'='json')=>{
    const document={...base,toolBackup:{snapshotId:kind==='index'?id:snapshot,kind,path,part:0,count:1,sha256:await sha256(raw),payload:btoa(raw)}};
    const body=encoder.encode(JSON.stringify({document,photoBase64:null,expectedRevision:null,consentVersion:'managed-preservation-v1'}));
    return {id,document,body,descriptor:{recordId:id,bodySHA256:await sha256(body)}};
  };
  const a=await part(crypto.randomUUID(),'CareHandoff/plan.json','{}');
  const b=await part(crypto.randomUUID(),'PhotoMemoryNotes/state.json','[]');
  const indexRaw=JSON.stringify({version:3,snapshotID:snapshot,createdAt:1,files:[
    {path:a.document.toolBackup.path,bytes:2,sha256:await sha256('{}'),records:[a.id]},
    {path:b.document.toolBackup.path,bytes:2,sha256:await sha256('[]'),records:[b.id]}]});
  const index=await part(snapshot,'index.json',indexRaw,'index');
  const parts=[a,b,index],batchId=crypto.randomUUID(),manifest={batchId,items:parts.map(part=>part.descriptor)};
  return {archive,auth,ownerCopy,session,parts,batchId,manifest,objects,count,options,authority,now,advance:()=>{time+=16*60_000;}};
}
export async function finish(f:Awaited<ReturnType<typeof fixture>>){
  let pending=0;
  for(let i=0;i<100;i++){
    const result=await f.archive().finishMetadataBatch(f.session.token,f.batchId);
    if(result.status==='parts-ready')return pending;
    expect(result.status).toBe('pending');pending++;
  }
  throw Error('bounded fixture did not complete');
}
