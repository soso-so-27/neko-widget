import {ServiceError} from './contracts';
import {canonicalJSON,type TreeRef,type TreeDiffFrame} from './immutable-record-tree';
import type {OwnerRecoveryImage,OwnerRecoveryCopy} from './owner-recovery-copy';
import type {RecordRecoveryCopy,DiscoveredRecordManifest,DiscoveredRecordCommit} from './record-recovery-copy';
import type {S3RecoveryCopy,RecoveryObject,RecoveryVersionCursor} from './s3-recovery-copy';
import {parseAppRecordHead,type AppRecordHead} from './documents';
import {parseToolNode} from './tool-index-v4';

const unavailable=()=>new ServiceError('OWNER_QUARANTINE_RESTORE_UNAVAILABLE',503);
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
class Quarantined extends Error {}
type Expected={record_id:string;revision:number;deleted:number;marker_key:string;marker_version:string;marker_hash:string;marker_bytes:number};
type Snapshot={generation:number;reference_json:string;header_json:string;tree_json:string|null;root_hash:string;record_count:number};
type Job={owner_id:string;nonce:string;revision:number;phase:string;state_json:string;listed_count:number;expected_count:number};
interface State {
 cursor?:RecoveryVersionCursor|undefined;previousGeneration?:number;currentGeneration?:number;frames?:TreeDiffFrame[]|undefined;legacyOffset?:number|undefined;
 knownBilling?:string|undefined;afterRecord?:string;record?:{id:string;revision:number;wasDeleted:boolean;historyAfter?:number;fingerprint?:string;operation?:string}|undefined;
 afterIndex?:string;afterHead?:string;restored?:number;photos?:number;history?:number;usedBytes?:number;
}
export interface OfflineRecoverySafety {
 /** Operator-owned read-only attestations, rechecked at every quantum. */
 assertSourceFenced(ownerId:string):Promise<void>;
 assertTargetOffline(ownerId:string):Promise<void>;
}
interface Dependencies {
 db:D1Database;s3:S3RecoveryCopy;owners:OwnerRecoveryCopy;records:RecordRecoveryCopy;safety:OfflineRecoverySafety;
 noPurge(owner:string):Promise<void>;empty(owner:string,allowJournal?:boolean):Promise<void>;
 photo(key:string,body:Uint8Array,resume:boolean):Promise<void>;
 tool(owner:string,index:string|null,head?:{id:string;revision:number;head:AppRecordHead}):Promise<void>;
}
const pack=(value:unknown)=>JSON.stringify(value,(_key,item)=>{
 if(!(item instanceof Uint8Array))return item;
 let text='';for(let at=0;at<item.length;at+=8192)text+=String.fromCharCode(...item.subarray(at,at+8192));
 return {sealedBytes:btoa(text)};
});
const comparable=(value:unknown)=>canonicalJSON(JSON.parse(pack(value)));
const unpack=(value:string):OwnerRecoveryImage=>JSON.parse(value,(_key,item)=>item && typeof item==='object' && Object.keys(item).join(',')==='sealedBytes'
 ?Uint8Array.from(atob(item.sealedBytes),c=>c.charCodeAt(0)):item) as OwnerRecoveryImage;
const ref=(row:Expected):RecoveryObject=>({key:row.marker_key,versionId:row.marker_version,sha256:row.marker_hash,bytes:row.marker_bytes});
const copyIdentity=(m:DiscoveredRecordManifest)=>canonicalJSON(m.kind==='commit'
 ?{kind:m.kind,recordId:m.recordId,revision:m.revision,record:m.record,photo:m.photo}
 :{kind:m.kind,recordId:m.recordId,revision:m.revision,expectedRevision:m.expectedRevision,record:m.record});

/** Offline-only recovery journal. No public HTTP handler or activation path.
 * Every call does a finite quantum and persists a CAS checkpoint. Unverified
 * images remain inaccessible, and transient failures never masquerade as done. */
export class OfflineOwnerRecovery {
 constructor(private readonly d:Dependencies){}
 private async transact(job:Job,state:State,phase:string,
   make:(guard:string,args:unknown[])=>D1PreparedStatement[]=()=>[],listed=0):Promise<void>{
   const op=crypto.randomUUID(),guard=`EXISTS(SELECT 1 FROM pa_offline_recovery_jobs WHERE owner_id=? AND nonce=? AND revision=? AND lease_token=?)
    AND NOT EXISTS(SELECT 1 FROM pa_owners WHERE disabled<>1)
    AND NOT EXISTS(SELECT 1 FROM pa_sessions) AND NOT EXISTS(SELECT 1 FROM pa_device_session_grants)
    AND NOT EXISTS(SELECT 1 FROM pa_notice_contacts)
    AND EXISTS(SELECT 1 FROM pa_recovery_write_policy WHERE singleton=1 AND delete_intent_required=0 AND owner_snapshot_required=0)`;
   const args=[job.owner_id,job.nonce,job.revision+1,op];
   const middle=make(guard,args);
   if(middle.length>96 || JSON.stringify(state).length>524288)throw unavailable();
   const result=await this.d.db.batch([
    this.d.db.prepare('UPDATE pa_offline_recovery_jobs SET revision=revision+1,lease_token=? WHERE owner_id=? AND nonce=? AND revision=?')
     .bind(op,job.owner_id,job.nonce,job.revision),...middle,
    this.d.db.prepare(`UPDATE pa_offline_recovery_jobs SET state_json=?,phase=?,listed_count=listed_count+? WHERE ${guard}`)
     .bind(JSON.stringify(state),phase,listed,...args),
   ]);
   if(result[0]?.meta.changes!==1 || result.at(-1)?.meta.changes!==1)throw unavailable();
 }
 private async snapshot(owner:string,generation:number){
   const row=await this.d.db.prepare('SELECT * FROM pa_offline_recovery_owners WHERE owner_id=? AND generation=?')
    .bind(owner,generation).first<Snapshot>();if(!row)throw unavailable();return row;
 }
 private async assertSafe(owner:string){
   await this.d.safety.assertSourceFenced(owner);await this.d.safety.assertTargetOffline(owner);await this.d.noPurge(owner);
 }
 async step(owner:string,now:number):Promise<{status:'pending';phase:string;versions:number;records:number}|
   {status:'quarantined'|'disabled'|'missing'}|{status:'staged-disabled';ownerId:string;records:number;photos:number}>{
   if(!uuid.test(owner) || !Number.isSafeInteger(now) || now<1)throw unavailable();
   await this.assertSafe(owner);
   let job=await this.d.db.prepare('SELECT * FROM pa_offline_recovery_jobs WHERE owner_id=?').bind(owner).first<Job>();
   if(!job){
    await this.d.empty(owner);
    await this.d.db.prepare('INSERT INTO pa_offline_recovery_jobs(owner_id,nonce) VALUES(?,?)').bind(owner,crypto.randomUUID()).run();
    job=(await this.d.db.prepare('SELECT * FROM pa_offline_recovery_jobs WHERE owner_id=?').bind(owner).first<Job>())!;
   }
   const state=JSON.parse(job.state_json) as State;
   try {
    if(job.phase==='listing')await this.list(job,state,false);
    else if(job.phase==='inspect')await this.inspect(job,state);
    else if(job.phase==='owners')await this.owners(job,state);
    else if(job.phase==='initialize')await this.initialize(job,state,now);
    else if(job.phase==='records')await this.record(job,state,now);
    else if(job.phase==='tools')await this.tools(job,state);
    else if(job.phase==='heads')await this.heads(job,state);
    else if(job.phase==='relist')await this.list(job,state,true);
    else if(job.phase==='verify'){await this.finalTarget(owner,job,state);await this.transact(job,state,'complete');}
    else if(!['complete','quarantined','disabled','missing'].includes(job.phase))throw unavailable();
   }catch(error){
    if(!(error instanceof Quarantined))throw error;
    const current=await this.d.db.prepare('SELECT * FROM pa_offline_recovery_jobs WHERE owner_id=?').bind(owner).first<Job>();
    if(current)await this.transact(current,JSON.parse(current.state_json),'quarantined');
   }
   await this.assertSafe(owner);
   const current=await this.d.db.prepare('SELECT * FROM pa_offline_recovery_jobs WHERE owner_id=?').bind(owner).first<Job>();
   if(!current)throw unavailable();
   if(['quarantined','disabled','missing'].includes(current.phase))return {status:current.phase as 'quarantined'|'disabled'|'missing'};
   if(current.phase==='complete'){
    const finished=JSON.parse(current.state_json) as State;await this.finalTarget(owner,current,finished);
    return {status:'staged-disabled',ownerId:owner,records:finished.restored??0,photos:finished.photos??0};
   }
   return {status:'pending',phase:current.phase,versions:current.listed_count,records:current.expected_count};
 }
 private async list(job:Job,state:State,again:boolean){
   const page=await this.d.s3.listOwnerVersionsPage(job.owner_id,state.cursor);
   if(page.versions.length>1000 || (!page.versions.length && page.nextCursor))throw unavailable();
   const seen=new Set<string>();
   for(const v of page.versions){
    const id=v.key+'\0'+v.versionId;
    if(v.deleteMarker || !v.key.startsWith(`recovery/v1/${job.owner_id}/`) || !Number.isSafeInteger(v.bytes) || v.bytes!<0 || seen.has(id))throw new Quarantined();
    seen.add(id);
   }
   if(!again && job.listed_count+page.versions.length>10_000_000)throw unavailable();
   if(page.nextCursor && canonicalJSON(page.nextCursor)===canonicalJSON(state.cursor??null))throw new Quarantined();
   if(again){
    for(let at=0;at<page.versions.length;at+=20){
     const chunk=page.versions.slice(at,at+20),rows=(await this.d.db.prepare(`SELECT object_key,version_id,bytes,seen_again
      FROM pa_offline_recovery_objects WHERE owner_id=? AND (object_key,version_id) IN(VALUES ${chunk.map(()=>'(?,?)').join(',')})`)
      .bind(job.owner_id,...chunk.flatMap(v=>[v.key,v.versionId])).all<{object_key:string;version_id:string;bytes:number;seen_again:number}>()).results;
     if(rows.length!==chunk.length || rows.some(r=>r.seen_again!==0 || r.bytes!==chunk.find(v=>v.key===r.object_key && v.versionId===r.version_id)?.bytes))throw new Quarantined();
    }
   }
   const next={...state,cursor:page.nextCursor??undefined};
   await this.transact(job,next,page.nextCursor?job.phase:again?'verify':'inspect',(guard,args)=>{
    const sql:D1PreparedStatement[]=[];
    for(let at=0;at<page.versions.length;at+=20){
     const chunk=page.versions.slice(at,at+20);
     if(again)sql.push(this.d.db.prepare(`UPDATE pa_offline_recovery_objects SET seen_again=1 WHERE owner_id=?
      AND (object_key,version_id) IN(VALUES ${chunk.map(()=>'(?,?)').join(',')}) AND ${guard}`)
      .bind(job.owner_id,...chunk.flatMap(v=>[v.key,v.versionId]),...args));
     else sql.push(this.d.db.prepare(`INSERT INTO pa_offline_recovery_objects(owner_id,object_key,version_id,bytes,kind)
      SELECT ?,column1,column2,column3,column4 FROM(VALUES ${chunk.map(()=>'(?,?,?,?)').join(',')}) WHERE ${guard}`)
      .bind(job.owner_id,...chunk.flatMap(v=>[v.key,v.versionId,v.bytes,v.key.includes('/owner/')?'owner':v.key.includes('/manifest/')?'manifest':'other']),...args));
    }return sql;
   },again?0:page.versions.length);
 }
 private async inspect(job:Job,state:State){
   const rows=(await this.d.db.prepare(`SELECT object_key,version_id,bytes,kind FROM pa_offline_recovery_objects
    WHERE owner_id=? AND inspected=0 AND kind<>'other' ORDER BY object_key,version_id LIMIT 8`).bind(job.owner_id)
    .all<{object_key:string;version_id:string;bytes:number;kind:string}>()).results;
   if(!rows.length){await this.transact(job,{},'owners');return;}
   const prepared:{row:typeof rows[number];ref:RecoveryObject;owner?:{header:OwnerRecoveryImage;tree:TreeRef|null;count:number;hash:string};manifest?:DiscoveredRecordManifest}[]=[];
   for(const row of rows){
    const reference=await this.d.s3.referenceForListedVersion({key:row.object_key,versionId:row.version_id,bytes:row.bytes,deleteMarker:false});
    if(row.kind==='owner'){
     const view=await this.d.owners.inspectRecoveryHeader(job.owner_id,reference);
     const hash=view.tree?.hash??await this.d.owners.recoveryLogicalHash(job.owner_id,view.legacyRecords!);
     const count=view.tree?.count??view.legacyRecords!.length;
     const prior=await this.d.db.prepare('SELECT header_json,root_hash,record_count FROM pa_offline_recovery_owners WHERE owner_id=? AND generation=?')
      .bind(job.owner_id,view.header.generation).first<{header_json:string;root_hash:string;record_count:number}>();
     if(prior && (comparable(unpack(prior.header_json))!==comparable(view.header) || prior.root_hash!==hash || prior.record_count!==count))throw new Quarantined();
     prepared.push({row,ref:reference,owner:{header:view.header,tree:view.tree,count,hash}});
    }else{
     const manifest=await this.d.records.inspectManifest(job.owner_id,reference);
     const prior=await this.d.db.prepare('SELECT payload_json FROM pa_offline_recovery_revisions WHERE owner_id=? AND record_id=? AND revision=? AND kind=?')
      .bind(job.owner_id,manifest.recordId,manifest.revision,manifest.kind).first<string>('payload_json');
     if(prior && copyIdentity(JSON.parse(prior))!==copyIdentity(manifest))throw new Quarantined();
     prepared.push({row,ref:reference,manifest});
    }
   }
   // Conflicting duplicate revisions/generations may share the same quantum.
   const identities=new Map<string,string>();
   for(const p of prepared){const id=p.owner?'o'+p.owner.header.generation:'r'+p.manifest!.recordId+'/'+p.manifest!.revision+'/'+p.manifest!.kind;
    const value=p.owner?comparable({header:p.owner.header,hash:p.owner.hash,count:p.owner.count}):copyIdentity(p.manifest!);
    if(identities.has(id) && identities.get(id)!==value)throw new Quarantined();identities.set(id,value);}
   await this.transact(job,state,'inspect',(guard,args)=>prepared.flatMap(p=>{
    const sql=[this.d.db.prepare(`UPDATE pa_offline_recovery_objects SET reference_json=?,inspected=1 WHERE owner_id=? AND object_key=? AND version_id=? AND ${guard}`)
     .bind(JSON.stringify(p.ref),job.owner_id,p.row.object_key,p.row.version_id,...args)];
    if(p.owner){const v=p.owner;sql.push(this.d.db.prepare(`INSERT OR IGNORE INTO pa_offline_recovery_owners
      SELECT ?,?,?,?,?,?,? WHERE ${guard}`).bind(job.owner_id,v.header.generation,JSON.stringify(p.ref),pack(v.header),v.tree?JSON.stringify(v.tree):null,v.hash,v.count,...args));}
    else{const m=p.manifest!;sql.push(this.d.db.prepare(`INSERT OR IGNORE INTO pa_offline_recovery_revisions SELECT ?,?,?,?,? WHERE ${guard}`)
     .bind(job.owner_id,m.recordId,m.revision,m.kind,JSON.stringify(m),...args));}return sql;
   }));
 }
 private async owners(job:Job,state:State){
   const snapshot=state.currentGeneration?await this.snapshot(job.owner_id,state.currentGeneration):await this.d.db.prepare(
    'SELECT * FROM pa_offline_recovery_owners WHERE owner_id=? AND generation>? ORDER BY generation LIMIT 1')
    .bind(job.owner_id,state.previousGeneration??0).first<Snapshot>();
   if(!snapshot){
    if(!state.previousGeneration){
     const manifests=await this.d.db.prepare('SELECT 1 FROM pa_offline_recovery_revisions WHERE owner_id=? LIMIT 1').bind(job.owner_id).first();
     await this.transact(job,state,manifests?'quarantined':'missing');return;
    }
    const unknown=await this.d.db.prepare(`SELECT 1 FROM pa_offline_recovery_revisions r LEFT JOIN pa_offline_recovery_expected e
      ON e.owner_id=r.owner_id AND e.record_id=r.record_id WHERE r.owner_id=? AND e.record_id IS NULL LIMIT 1`).bind(job.owner_id).first();
    if(unknown)throw new Quarantined();await this.transact(job,state,'initialize');return;
   }
   const header=unpack(snapshot.header_json),previous=state.previousGeneration?await this.snapshot(job.owner_id,state.previousGeneration):null;
   const prior=previous?unpack(previous.header_json):null;
   if(prior && (header.identityKey!==prior.identityKey || header.createdAt!==prior.createdAt || header.epoch<prior.epoch
    || header.inventoryGeneration<prior.inventoryGeneration || (state.knownBilling && header.billing?.accountId!==state.knownBilling)))throw new Quarantined();
   if(state.currentGeneration && (state.frames?.length===0 || state.legacyOffset===snapshot.record_count)){
    if(job.expected_count!==snapshot.record_count)throw new Quarantined();
    await this.transact(job,{previousGeneration:snapshot.generation,knownBilling:header.billing?.accountId??state.knownBilling},'owners');return;
   }
   let values:OwnerRecoveryImage['records'],frames:TreeDiffFrame[]|undefined,legacyOffset:number|undefined;
   if(snapshot.tree_json){
    const result=await this.d.owners.recoveryDifference(job.owner_id,previous?.tree_json?JSON.parse(previous.tree_json):null,
     JSON.parse(snapshot.tree_json),state.frames);values=result.entries.map(v=>{
      const value=v.value as OwnerRecoveryImage['records'][number];
      if(value.recordId.replaceAll('-','')!==v.key)throw new Quarantined();return value;
     });frames=result.pending;
   }else{
    const view=await this.d.owners.inspectRecoveryHeader(job.owner_id,JSON.parse(snapshot.reference_json));
    const offset=state.legacyOffset??0;values=view.legacyRecords!.slice(offset,offset+200);legacyOffset=offset+values.length;
   }
   this.d.owners.validateRecoveryEntries(header,values);
   await this.transact(job,{...state,currentGeneration:snapshot.generation,frames,legacyOffset},'owners',(guard,args)=>{
    const sql:D1PreparedStatement[]=[];
    for(let at=0;at<values.length;at+=10){const chunk=values.slice(at,at+10);
     sql.push(this.d.db.prepare(`INSERT INTO pa_offline_recovery_expected(owner_id,record_id,revision,deleted,marker_key,marker_version,marker_hash,marker_bytes)
      SELECT ?,column1,column2,column3,column4,column5,column6,column7 FROM(VALUES ${chunk.map(()=>'(?,?,?,?,?,?,?)').join(',')}) WHERE ${guard}
      ON CONFLICT(owner_id,record_id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,marker_key=excluded.marker_key,
        marker_version=excluded.marker_version,marker_hash=excluded.marker_hash,marker_bytes=excluded.marker_bytes`)
      .bind(job.owner_id,...chunk.flatMap(v=>[v.recordId,v.revision,v.deleted?1:0,v.marker.key,v.marker.versionId,v.marker.sha256,v.marker.bytes]),...args));
    }return sql;
   });
 }
 // The remaining phases below stage bytes only after the complete source
 // inventory and every owner generation have been authenticated.
 private async initialize(job:Job,state:State,now:number){
   if(!state.previousGeneration)throw unavailable();
   const owner=unpack((await this.snapshot(job.owner_id,state.previousGeneration)).header_json);
   if(owner.disabled || owner.purgeFenceId!==null){await this.transact(job,state,'disabled');return;}
   if(owner.retention?.revision===Number.MAX_SAFE_INTEGER)throw new Quarantined();
   const r=owner.retention===null?null:{...owner.retention,revision:owner.retention.revision+1,status:'unknown',checkedAt:0,
    pausedAt:owner.retention.expiredAt===null?null:Math.max(now,owner.retention.expiredAt),
    noticeNotBeforeAt:owner.retention.expiredAt===null?0:Math.max(now,owner.retention.expiredAt,owner.retention.noticeNotBeforeAt)};
   await this.d.empty(job.owner_id,true);await this.assertSafe(job.owner_id);
   await this.transact(job,{...state,afterRecord:'',restored:0,photos:0,history:0,usedBytes:0},'records',(guard,args)=>[
    this.d.db.prepare(`DELETE FROM pa_auth_challenges WHERE ${guard}`).bind(...args),
    this.d.db.prepare(`DELETE FROM pa_device_session_challenges WHERE ${guard}`).bind(...args),
    this.d.db.prepare(`DELETE FROM pa_device_identity_checks WHERE ${guard}`).bind(...args),
    this.d.db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,created_at,purge_fence_id)
      SELECT ?,?,?,1,?,NULL WHERE ${guard} AND NOT EXISTS(SELECT 1 FROM pa_owners)`)
      .bind(job.owner_id,owner.identityKey,owner.epoch,owner.createdAt,...args),
    this.d.db.prepare(`INSERT INTO pa_identity_credentials(owner_id,owner_epoch,sealed_credentials,updated_at)
      SELECT ?,?,?,? WHERE ${guard}`).bind(job.owner_id,owner.credential.ownerEpoch,owner.credential.sealedCredentials.slice().buffer,owner.credential.updatedAt,...args),
    this.d.db.prepare(`INSERT INTO pa_inventory(owner_id) SELECT ? WHERE ${guard}`).bind(job.owner_id,...args),
    ...(owner.billing?[this.d.db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
      SELECT ?,?,? WHERE ${guard}`).bind(job.owner_id,owner.billing.accountId,owner.billing.createdAt,...args)]:[]),
    ...(r?[this.d.db.prepare(`INSERT INTO pa_retention(owner_id,revision,episode,verified_status,checked_at,expired_at,due_at,paused_at,
      notice_not_before_at,final_notice_delivered_at,final_notice_receipt) SELECT ?,?,?,?,?,?,?,?,?,NULL,NULL WHERE ${guard}`)
      .bind(job.owner_id,r.revision,r.episode,r.status,r.checkedAt,r.expiredAt,r.dueAt,r.pausedAt,r.noticeNotBeforeAt,...args)]:[]),
   ]);
 }
 private async currentCommit(owner:string,expected:Expected,revision:number):Promise<DiscoveredRecordCommit>{
   const payload=await this.d.db.prepare(`SELECT payload_json FROM pa_offline_recovery_revisions
    WHERE owner_id=? AND record_id=? AND revision=? AND kind='commit'`).bind(owner,expected.record_id,revision).first<string>('payload_json');
   if(!payload)throw new Quarantined();let commit=JSON.parse(payload) as DiscoveredRecordCommit;
   if(revision===expected.revision){
    const marker=ref(expected),listed=await this.d.db.prepare(`SELECT reference_json FROM pa_offline_recovery_objects
     WHERE owner_id=? AND object_key=? AND version_id=? AND inspected=1`).bind(owner,marker.key,marker.versionId).first<string>('reference_json');
    if(!listed || canonicalJSON(JSON.parse(listed))!==canonicalJSON(marker))throw new Quarantined();
    if(canonicalJSON(commit.marker)!==canonicalJSON(marker)){
     const exact=await this.d.records.inspectCommit(owner,marker);
     if(copyIdentity(exact)!==copyIdentity(commit))throw new Quarantined();commit=exact;
    }
   }return commit;
 }
 private async record(job:Job,state:State,now:number){
   const current=state.record;
   const expected=await this.d.db.prepare(`SELECT * FROM pa_offline_recovery_expected WHERE owner_id=? AND record_id${current?'=':'>'}?
    ORDER BY record_id LIMIT 1`).bind(job.owner_id,current?.id??state.afterRecord??'').first<Expected>();
   if(!expected){if(current)throw unavailable();await this.transact(job,{...state,afterIndex:''},'tools');return;}
   if(!current){
    const coverage=await this.d.db.prepare(`SELECT count(*) AS n,min(revision) AS lo,max(revision) AS hi FROM pa_offline_recovery_revisions
      WHERE owner_id=? AND record_id=? AND kind='commit'`).bind(job.owner_id,expected.record_id).first<{n:number;lo:number;hi:number}>();
    const unresolved=await this.d.db.prepare(`SELECT 1 FROM pa_offline_recovery_revisions i LEFT JOIN pa_offline_recovery_revisions c
      ON c.owner_id=i.owner_id AND c.record_id=i.record_id AND c.revision=i.revision AND c.kind='commit'
      WHERE i.owner_id=? AND i.record_id=? AND i.kind='delete-intent' AND c.revision IS NULL LIMIT 1`).bind(job.owner_id,expected.record_id).first();
    if(!coverage || coverage.n!==expected.revision || coverage.lo!==1 || coverage.hi!==expected.revision || unresolved)throw new Quarantined();
   }
   const progress=current??{id:expected.record_id,revision:1,wasDeleted:false};
   if(progress.historyAfter!==undefined){
    const rows=(await this.d.db.prepare(`SELECT revision,payload_json FROM pa_offline_recovery_revisions
      WHERE owner_id=? AND record_id=? AND kind='commit' AND revision>? ORDER BY revision LIMIT 20`)
      .bind(job.owner_id,expected.record_id,progress.historyAfter).all<{revision:number;payload_json:string}>()).results;
    if(!rows.length){
     if(progress.historyAfter!==expected.revision)throw unavailable();
     await this.transact(job,{...state,record:undefined,afterRecord:expected.record_id},'records');return;
    }
    const commits=rows.map(row=>JSON.parse(row.payload_json) as DiscoveredRecordCommit);
    // Only the latest marker must be the exact alias authenticated by the owner.
    if(commits.at(-1)!.revision===expected.revision)commits[commits.length-1]=await this.currentCommit(job.owner_id,expected,expected.revision);
    const intents=(await this.d.db.prepare(`SELECT payload_json FROM pa_offline_recovery_revisions WHERE owner_id=? AND record_id=?
      AND kind='delete-intent' AND revision>? AND revision<=? ORDER BY revision`).bind(job.owner_id,expected.record_id,
       progress.historyAfter,commits.at(-1)!.revision).all<{payload_json:string}>()).results.map(row=>JSON.parse(row.payload_json) as DiscoveredRecordManifest);
    if(intents.length>20)throw unavailable();
    for(const intent of intents){const commit=commits.find(c=>c.revision===intent.revision);
     if(!commit || canonicalJSON(commit.record)!==canonicalJSON(intent.record))throw new Quarantined();}
    await this.transact(job,{...state,record:{...progress,historyAfter:commits.at(-1)!.revision},history:(state.history??0)+commits.length},'records',(guard,args)=>[
     ...commits.flatMap(c=>[
      this.d.db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,record_object_key,record_version_id,record_sha256,record_bytes,
        photo_object_key,photo_version_id,photo_sha256,photo_bytes,committed_at) SELECT ?,?,?,?,?,?,?,?,?,?,?,? WHERE ${guard}`)
       .bind(job.owner_id,expected.record_id,c.revision,c.record.key,c.record.versionId,c.record.sha256,c.record.bytes,
        c.photo?.key??null,c.photo?.versionId??null,c.photo?.sha256??null,c.photo?.bytes??null,now,...args),
      this.d.db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,revision,marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
        SELECT ?,?,?,?,?,?,?,? WHERE ${guard}`).bind(job.owner_id,expected.record_id,c.revision,c.marker.key,c.marker.versionId,c.marker.sha256,c.marker.bytes,now,...args),
     ]),...intents.map(c=>this.d.db.prepare(`INSERT INTO pa_record_delete_intents(owner_id,record_id,target_revision,record_object_key,
       intent_object_key,intent_version_id,intent_sha256,intent_bytes,created_at) SELECT ?,?,?,?,?,?,?,?,? WHERE ${guard}`)
       .bind(job.owner_id,expected.record_id,c.revision,c.record.key,c.marker.key,c.marker.versionId,c.marker.sha256,c.marker.bytes,now,...args)),
    ]);return;
   }
   if(progress.wasDeleted)throw new Quarantined();
   const commit=await this.currentCommit(job.owner_id,expected,progress.revision),image=await this.d.records.readCommitted(job.owner_id,expected.record_id,commit);
   try{
    for(const reference of [commit.record,...(commit.photo?[commit.photo]:[])]){
     const listed=await this.d.db.prepare(`SELECT 1 FROM pa_offline_recovery_objects WHERE owner_id=? AND object_key=? AND version_id=? AND bytes=?`)
      .bind(job.owner_id,reference.key,reference.versionId,reference.bytes).first();
     if(!listed)throw new Quarantined();
    }
    if(image.revision!==progress.revision || (progress.fingerprint && (progress.fingerprint!==image.initialFingerprint || progress.operation!==image.initialOperation)))throw new Quarantined();
    if(progress.revision<expected.revision){
     await this.transact(job,{...state,record:{...progress,revision:progress.revision+1,wasDeleted:image.deleted,
      fingerprint:image.initialFingerprint,operation:image.initialOperation}},'records');return;
    }
    if(image.deleted!==(expected.deleted===1))throw new Quarantined();
    const metadata=await this.d.records.readMetadata(image),head=metadata?parseAppRecordHead(metadata.document):null,tag=metadata?.document.toolBackup;
    if(tag && (image.revision!==1 || (tag.kind==='index' && tag.snapshotId!==expected.record_id)))throw new Quarantined();
    const node=tag?.kind==='index'?parseToolNode(tag):null;
    if(image.photoKey!==null){if(!image.photoCiphertext)throw unavailable();await this.d.photo(image.photoKey,image.photoCiphertext,true);}
    const bytes=(state.usedBytes??0)+image.quotaBytes;if(!Number.isSafeInteger(bytes))throw unavailable();
    await this.transact(job,{...state,record:{...progress,historyAfter:0},restored:(state.restored??0)+1,
      photos:(state.photos??0)+(image.photoKey?1:0),usedBytes:bytes},'records',(guard,args)=>[
     this.d.db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,metadata,photo_key,photo_bytes,quota_bytes,deleted)
       SELECT ?,?,?,?,?,?,?,?,?,? WHERE ${guard}`).bind(job.owner_id,expected.record_id,image.revision,image.initialFingerprint,image.initialOperation,
       image.metadata?.slice().buffer??null,image.photoKey,image.photoBytes,image.quotaBytes,image.deleted?1:0,...args),
     ...(tag?[this.d.db.prepare(`INSERT INTO pa_tool_record_sources(owner_id,record_id,snapshot_id,kind,upload_snapshot_id)
       SELECT ?,?,?,?,? WHERE ${guard}`).bind(job.owner_id,expected.record_id,tag.snapshotId,tag.kind,node?.version===4?node.uploadSnapshotID.toLowerCase():null,...args)]:[]),
     ...(head?[this.d.db.prepare(`INSERT INTO pa_offline_recovery_heads SELECT ?,?,?,? WHERE ${guard}`)
       .bind(job.owner_id,expected.record_id,image.revision,JSON.stringify(head),...args)]:[]),
    ]);
   }finally{image.metadata?.fill(0);image.photoCiphertext?.fill(0);}
 }
 private async tools(job:Job,state:State){
   const id=await this.d.db.prepare(`SELECT record_id FROM pa_tool_record_sources WHERE owner_id=? AND kind='index'
     AND record_id>? ORDER BY record_id LIMIT 1`).bind(job.owner_id,state.afterIndex??'').first<string>('record_id');
   if(!id){await this.transact(job,{...state,afterHead:''},'heads');return;}
   await this.d.tool(job.owner_id,id);await this.transact(job,{...state,afterIndex:id},'tools');
 }
 private async heads(job:Job,state:State){
   const head=await this.d.db.prepare(`SELECT record_id,revision,head_json FROM pa_offline_recovery_heads WHERE owner_id=?
     AND record_id>? ORDER BY record_id LIMIT 1`).bind(job.owner_id,state.afterHead??'').first<{record_id:string;revision:number;head_json:string}>();
   if(!head){await this.transact(job,{...state,cursor:undefined},'relist');return;}
   await this.d.tool(job.owner_id,null,{id:head.record_id,revision:head.revision,head:JSON.parse(head.head_json)});
   await this.transact(job,{...state,afterHead:head.record_id},'heads');
 }
 private async finalTarget(owner:string,job:Job,state:State){
   const row=await this.d.db.prepare(`SELECT o.disabled,d.record_count,d.pending_ack,d.accounting_valid,i.used_bytes,
     (SELECT count(*) FROM pa_records WHERE owner_id=o.owner_id AND photo_key IS NOT NULL) AS photos,
     (SELECT count(*) FROM pa_record_recovery_versions WHERE owner_id=o.owner_id) AS history,
     (SELECT count(*) FROM pa_offline_recovery_objects WHERE owner_id=o.owner_id AND seen_again=1) AS listed,
     (SELECT count(*) FROM pa_sessions) AS sessions,(SELECT count(*) FROM pa_notice_contacts) AS contacts,
     (SELECT count(*) FROM pa_device_session_grants) AS grants,(SELECT count(*) FROM pa_owners) AS owners,
     (SELECT delete_intent_required+owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1) AS policy
     FROM pa_owners o JOIN pa_owner_record_counters d USING(owner_id) JOIN pa_inventory i USING(owner_id) WHERE o.owner_id=?`)
    .bind(owner).first<{disabled:number;record_count:number;pending_ack:number;accounting_valid:number;used_bytes:number;photos:number;history:number;listed:number;
      sessions:number;contacts:number;grants:number;owners:number;policy:number}>();
   if(!row || row.disabled!==1 || row.record_count!==job.expected_count || row.record_count!==state.restored
     || row.pending_ack!==0 || row.accounting_valid!==1 || row.used_bytes!==state.usedBytes || row.photos!==state.photos || row.history!==state.history
     || row.listed!==job.listed_count || row.sessions!==0 || row.contacts!==0 || row.grants!==0 || row.owners!==1 || row.policy!==0)throw unavailable();
   await this.assertSafe(owner);
 }
}
