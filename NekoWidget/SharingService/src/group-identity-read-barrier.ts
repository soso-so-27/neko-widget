import { ApiError } from './errors';

// Group data must not be served from an older D1 snapshot.
// Compare an independently provisioned, append-only journal tip with the
// checkpoint written atomically with the corresponding D1 erasure. A valid
// matching sequence alone is insufficient (forked/restored data).
const invalid = () => new ApiError(503, 'deletion_recovery_required', 'Group data is temporarily unavailable.');
interface Tip {sequence:number;requestId:string}
function isTip(x:unknown):x is Tip {
  if (!x || typeof x!=='object') return false;
  const t=x as Tip;
  return Object.keys(t).sort().join(',')==='requestId,sequence' && Number.isSafeInteger(t.sequence)
    && t.sequence>=0 && (t.sequence===0 ? t.requestId==='' :
      typeof t.requestId==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(t.requestId));
}
async function checkpoint(db:D1Database,store:R2Bucket) {
  const [control,applied]=await Promise.all([
    store.get('group-identity-deletions/v1/control'),
    db.prepare('SELECT sequence,request_id AS requestId FROM group_identity_deletion_checkpoint WHERE singleton=1').first<Tip>(),
  ]);
  if(!control || control.size<1 || control.size>256 || !isTip(applied))throw invalid();
  const tip=await control.json();
  if(!isTip(tip)||tip.sequence!==applied.sequence || tip.requestId!==applied.requestId)throw invalid();
  return control.etag;
}
// Do not stream the result until the second check passes. A concurrent
// change to either store, a missing migration or corrupt journal fails closed.
export async function checkedDeletionRead<T>(db:D1Database,store:R2Bucket,load:()=>Promise<T>):Promise<T> {
  const verify=async()=>{try {return await checkpoint(db,store);} catch {throw invalid();}};
  const before=await verify();
  const value=await load();
  if(await verify()!==before)throw invalid();
  return value;
}
