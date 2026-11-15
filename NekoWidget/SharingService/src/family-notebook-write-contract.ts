import {ApiError} from './errors';
import {asObject,exactKeys,integerField,uuidField} from './validation';
import type {Env} from './env';
export const FAMILY_WRITE_PROTOCOL_VERSION=1;
export function parseFamilyWriteContract(value:unknown):number {
  const contract=asObject(value);
  if(contract.version!==FAMILY_WRITE_PROTOCOL_VERSION) throw new ApiError(409,'photo_protocol_upgrade_required','Update the app to write this notebook.');
  exactKeys(contract,['version','effects']);
  if(!Array.isArray(contract.effects)||contract.effects.length>1)
    throw new ApiError(409,'photo_protocol_upgrade_required','This operation requires a supported effect handler.');
  for(const effect of contract.effects){const e=asObject(effect);exactKeys(e,['kind','slotId']);if(!['retireCat','clearPhoto'].includes(String(e.kind)))throw new ApiError(409,'photo_protocol_upgrade_required','Unsupported effect.');uuidField(e,'slotId');}
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
  const e=asObject(item),slot=uuidField(e,'slotId');
  return [env.DB.prepare("UPDATE family_representative_assets SET state='retired',expires_at=unixepoch() WHERE family_id=? AND slot_id=? AND state IN ('active','reserved','uploaded')").bind(family,slot),
   env.DB.prepare("UPDATE family_representative_slots SET state=?,asset_id=NULL,revision=revision+1 WHERE family_id=? AND slot_id=?").bind(e.kind==='retireCat'?'retired':'active',family,slot)];
 });
}
