import { ServiceError, sha256, type Session } from './contracts';
import { validateDocument, parseAppRecordHead } from './documents';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const record=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const hex=/^[0-9a-f]{64}$/u;
const bad=()=>new ServiceError('INVALID_TOOL_METADATA_BATCH');
const conflict=()=>new ServiceError('TOOL_METADATA_BATCH_CHANGED',409);
type Item={recordId:string;bodySHA256:string;fingerprint?:string};
type Row={owner_id:string;batch_id:string;batch_nonce:string;manifest_json:string;state:'open'|'ready'};
interface Auth {
  requireSession(token:string):Promise<Session>;
  requireToolMetadataBatchSession(token:string,batchId:string):Promise<Session>;
}
function items(value:unknown,stored=false):Item[] {
  if(!Array.isArray(value)||!value.length||value.length>16)throw bad();
  const ids=new Set<string>();
  for(const item of value){
    if(!item || typeof item!=='object' || Array.isArray(item)
      || Object.keys(item).some(key=>!['recordId','bodySHA256',...(stored?['fingerprint']:[])].includes(key))
      || !record.test(item.recordId) || !hex.test(item.bodySHA256) || ids.has(item.recordId)
      || (item.fingerprint!==undefined && !hex.test(item.fingerprint)))throw bad();
    ids.add(item.recordId);
  }
  return value as Item[];
}
const manifest=(list:Item[])=>JSON.stringify(list.map(({recordId,bodySHA256})=>({recordId,bodySHA256})));

/** A fixed metadata-only manifest. The per-part receipt is explicitly NOT a
 * logical save. Only the existing final head CAS makes a snapshot current. */
export class ToolMetadataBatches {
  constructor(private readonly db:D1Database,private readonly auth:Auth,private readonly now:()=>number){}
  async begin(token:string,input:unknown){
    if(!input||typeof input!=='object'||Array.isArray(input))throw bad();
    const request=input as Record<string,unknown>;
    if(Object.keys(request).sort().join(',')!=='batchId,items'||!uuid.test(String(request.batchId)))throw bad();
    const batchId=String(request.batchId),list=items(request.items),json=manifest(list);
    // An interrupted same manifest is resumable, but cannot bootstrap a new
    // manifest through the continuation authorization.
    let session:Session;
    try{session=await this.auth.requireSession(token);}
    catch(error){
      session=await this.auth.requireToolMetadataBatchSession(token,batchId);
      const prior=await this.row(session,batchId);
      if(manifest(items(JSON.parse(prior.manifest_json),true))!==json)throw conflict();
      return {batchId,status:prior.state==='ready'?'parts-ready':'open'};
    }
    const prior=await this.db.prepare('SELECT * FROM pa_tool_metadata_batches WHERE owner_id=?').bind(session.ownerId).first<Row>();
    if(prior?.batch_id===batchId){
      if(manifest(items(JSON.parse(prior.manifest_json),true))!==json)throw conflict();
    }else{
      const result=await this.db.prepare(`INSERT INTO pa_tool_metadata_batches(owner_id,batch_id,batch_nonce,owner_epoch,manifest_json,state,created_at)
        SELECT o.owner_id,?,?,o.epoch,?,'open',? FROM pa_owners o JOIN pa_sessions s ON s.owner_id=o.owner_id
        WHERE s.session_hash=? AND s.expires_at>? AND s.owner_epoch=o.epoch AND o.disabled=0 AND o.purge_fence_id IS NULL
          AND EXISTS(SELECT 1 FROM pa_owner_recovery_generations g JOIN pa_owner_recovery_versions v
            ON v.owner_id=g.owner_id AND v.generation=g.generation WHERE g.owner_id=o.owner_id)
          AND (s.device_grant_id IS NULL OR EXISTS(SELECT 1 FROM pa_device_session_grants d WHERE d.grant_id=s.device_grant_id
            AND d.owner_id=o.owner_id AND d.owner_epoch=o.epoch AND d.revoked_at IS NULL AND d.idle_expires_at>?))
        ON CONFLICT(owner_id) DO UPDATE SET batch_id=excluded.batch_id,batch_nonce=excluded.batch_nonce,owner_epoch=excluded.owner_epoch,
          manifest_json=excluded.manifest_json,state='open',created_at=excluded.created_at RETURNING batch_id`)
        .bind(batchId,crypto.randomUUID(),json,this.now(),session.sessionHash,this.now(),this.now()).all();
      if(result.results.length!==1)throw conflict();
    }
    await this.auth.requireToolMetadataBatchSession(token,batchId);
    return {batchId,status:prior?.batch_id===batchId && prior.state==='ready'?'parts-ready':'open'};
  }
  private async row(session:Session,batchId:string):Promise<Row>{
    const row=await this.db.prepare('SELECT * FROM pa_tool_metadata_batches WHERE owner_id=? AND batch_id=?')
      .bind(session.ownerId,batchId).first<Row>();
    if(!row || row.owner_id!==session.ownerId || !uuid.test(row.batch_nonce))throw conflict();return row;
  }
  async stage(token:string,batchId:string,id:string,raw:Uint8Array,
    write:(input:unknown,authorize:()=>Promise<Session>,batchNonce:string)=>Promise<{recordId:string;revision:number}>){
    const session=await this.auth.requireToolMetadataBatchSession(token,batchId),row=await this.row(session,batchId);
    const list=items(JSON.parse(row.manifest_json),true),offset=list.findIndex(item=>item.recordId===id);
    if(offset<0 || raw.length>512*1024 || await sha256(raw)!==list[offset]!.bodySHA256)throw bad();
    const input=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw)) as Record<string,unknown>;
    if(!input||typeof input!=='object'||Array.isArray(input)
      || Object.keys(input).sort().join(',')!=='consentVersion,document,expectedRevision,photoBase64'
      || input.expectedRevision!==null || input.photoBase64!==null || input.consentVersion!=='managed-preservation-v1')throw bad();
    const document=validateDocument(input.document),part=document.toolBackup;
    if(document.formatVersion!==3 || document.photoFile!==null || !part || !['index','json'].includes(part.kind)
      || parseAppRecordHead(document)!==null)throw bad();
    const authorize=async()=>{
      const current=await this.auth.requireToolMetadataBatchSession(token,batchId);
      if(current.ownerId!==session.ownerId)throw conflict();return current;
    };
    const scopedAuthorize=async()=>{
      const current=await authorize();
      if((await this.row(current,batchId)).batch_nonce!==row.batch_nonce)throw conflict();
      return current;
    };
    const result=await write(input,scopedAuthorize,row.batch_nonce);
    if(result.recordId!==id||result.revision!==1)throw conflict();
    await scopedAuthorize();
    const fingerprint=await sha256(JSON.stringify({document,photoSHA256:null}));
    const updated=await this.db.prepare(`UPDATE pa_tool_metadata_batches SET manifest_json=json_set(manifest_json,?,?)
      WHERE owner_id=? AND batch_id=? AND batch_nonce=? AND json_extract(manifest_json,?)=?
        AND EXISTS(SELECT 1 FROM pa_records r JOIN pa_record_commit_markers m
          ON m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision
          WHERE r.owner_id=? AND r.record_id=? AND r.revision=1 AND r.deleted=0 AND r.initial_fingerprint=?)
      RETURNING batch_id`).bind(`$[${offset}].fingerprint`,fingerprint,session.ownerId,batchId,row.batch_nonce,
        `$[${offset}].bodySHA256`,list[offset]!.bodySHA256,session.ownerId,id,fingerprint).all();
    if(updated.results.length!==1)throw conflict();
    return {batchId,recordId:id,revision:1,status:'part-staged'};
  }
  async finish(token:string,batchId:string,copy: (ownerId:string)=>Promise<boolean>){
    const session=await this.auth.requireToolMetadataBatchSession(token,batchId),row=await this.row(session,batchId);
    const list=items(JSON.parse(row.manifest_json),true);
    if(list.some(item=>!item.fingerprint))throw new ServiceError('TOOL_METADATA_BATCH_INCOMPLETE',409);
    for(const item of list){
      const exists=await this.db.prepare(`SELECT 1 FROM pa_records r JOIN pa_record_commit_markers m
        ON m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision
        WHERE r.owner_id=? AND r.record_id=? AND r.revision=1 AND r.deleted=0 AND r.initial_fingerprint=?`)
        .bind(session.ownerId,item.recordId,item.fingerprint).first();
      if(!exists)throw conflict();
    }
    if(!await copy(session.ownerId))return {batchId,status:'pending'};
    await this.auth.requireSession(token);
    const result=await this.db.prepare(`UPDATE pa_tool_metadata_batches SET state='ready'
      WHERE owner_id=? AND batch_id=? AND batch_nonce=? AND manifest_json=? RETURNING batch_id`)
      .bind(session.ownerId,batchId,row.batch_nonce,row.manifest_json).all();
    if(result.results.length!==1)throw conflict();
    return {batchId,status:'parts-ready'};
  }
  /** Repair the actual committed inventory when local transport staging was
   * lost. Missing manifest parts remain missing; this never marks parts-ready
   * or changes the logical head, membership, quotas or deletion authority. */
  async recover(token:string,batchId:string,copy:(ownerId:string)=>Promise<boolean>){
    const session=await this.auth.requireToolMetadataBatchSession(token,batchId),row=await this.row(session,batchId);
    const ready=await copy(session.ownerId);
    const current=await this.auth.requireToolMetadataBatchSession(token,batchId);
    if((await this.row(current,batchId)).batch_nonce!==row.batch_nonce)throw conflict();
    if(ready)await this.auth.requireSession(token);
    return {status:ready?'inventory-ready':'pending'};
  }
}
