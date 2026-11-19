import {ApiError} from './errors';
import {asObject,exactKeys,integerField,stringField,type JsonRecord} from './validation';
import type {Env} from './env';
import {trialDenied} from './owner-two-device-trial';
export const FAMILY_WRITE_PROTOCOL_VERSION=1;
export function familyPhotoSlotId(body:JsonRecord):string {
  const slot=stringField(body,'slotId');
  // The iPhone derives a version-8 photo slot. Keep existing version-4 slots
  // addressable, and store both formats in their canonical lowercase form.
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[48][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(slot))
    throw new ApiError(400,'invalid_field','slotId must be a UUIDv4 or UUIDv8.');
  return slot.toLowerCase();
}
export function parseFamilyWriteContract(value:unknown):number {
  const contract=asObject(value);
  if(contract.version!==FAMILY_WRITE_PROTOCOL_VERSION) throw new ApiError(409,'photo_protocol_upgrade_required','Update the app to write this notebook.');
  exactKeys(contract,['version','effects']);
  if(!Array.isArray(contract.effects)||contract.effects.length>1)
    throw new ApiError(409,'photo_protocol_upgrade_required','This operation requires a supported effect handler.');
  for(const effect of contract.effects){const e=asObject(effect);exactKeys(e,['kind','slotId']);if(!['retireCat','clearPhoto'].includes(String(e.kind)))throw new ApiError(409,'photo_protocol_upgrade_required','Unsupported effect.');familyPhotoSlotId(e);}
  return integerField(contract,'version',1,1);
}
export async function familyWriteCapability(env:Env,family:string){
  const row=await env.DB.prepare('SELECT required_version FROM family_notebook_write_policy WHERE family_id=?').bind(family).first<{required_version:number}>();
  return {supportedVersion:FAMILY_WRITE_PROTOCOL_VERSION,requiredVersion:row?.required_version??0};
}
export function familyWriteCheck(env:Env,family:string,version:number):D1PreparedStatement[]{
  const id=crypto.randomUUID();
  return [env.DB.prepare('INSERT INTO family_notebook_write_checks(id,family_id,version) VALUES (?,?,?)').bind(id,family,version),
    env.DB.prepare('DELETE FROM family_notebook_write_checks WHERE id=?').bind(id)];
}

export function familyWriteEffects(env:Env,family:string,value:unknown):D1PreparedStatement[]{
 const contract=asObject(value);parseFamilyWriteContract(value);
 return (contract.effects as unknown[]).flatMap(item=>{
  if(env.ownerTrial?.phase==='RECOVERY') throw trialDenied();
  const e=asObject(item),slot=familyPhotoSlotId(e);
  return [env.DB.prepare("UPDATE family_representative_assets SET state='retired',expires_at=unixepoch() WHERE family_id=? AND slot_id=? AND state IN ('active','reserved','uploaded')").bind(family,slot),
   env.DB.prepare("UPDATE family_representative_slots SET state=?,asset_id=NULL,revision=revision+1 WHERE family_id=? AND slot_id=?").bind(e.kind==='retireCat'?'retired':'active',family,slot)];
 });
}
