import type {Env} from './env';
import {ApiError} from './errors';
export interface FamilyPhotoDeletion {assetId:string;familyId:string;objectKey:string}
const uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const keyPattern=new RegExp(`^family-representative/v1/${uuid}/${uuid}(?:/[A-Za-z0-9_-]{32})?$`);
async function installed(db:D1Database){return !!await db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='family_representative_assets'").first();}
export async function familyIdentityPhotos(env:Pick<Env,'DB'>,person:string):Promise<FamilyPhotoDeletion[]> {
 if(!await installed(env.DB))return [];
 const rows=(await env.DB.prepare(`SELECT asset_id AS assetId,family_id AS familyId,object_key AS objectKey FROM family_representative_assets WHERE person_id=? ORDER BY asset_id`).bind(person).all<FamilyPhotoDeletion>()).results;
 for(const row of rows)if(!keyPattern.test(row.objectKey)||!(row.objectKey===`family-representative/v1/${row.familyId}/${row.assetId}`||row.objectKey.startsWith(`family-representative/v1/${row.familyId}/${row.assetId}/`)))throw new ApiError(503,'unavailable','The deletion target could not be verified.');
 return rows;
}
/** Called only by the existing fenced identity-deletion coordinator. The caller
 * captures these keys in its independent journal before accepting deletion. */
export async function eraseFamilyIdentityPhotos(env:Env,person:string):Promise<boolean> {
 const rows=(await familyIdentityPhotos(env,person)).slice(0,8);if(!rows.length)return false;
 if(!env.MEDIA)throw new ApiError(503,'unavailable','The deletion could not be verified.');
 for(const row of rows){
  // A concurrent replacement by another author must retain its current pointer.
  await env.DB.batch([
   env.DB.prepare("UPDATE family_representative_assets SET state='retired',expires_at=MIN(expires_at,unixepoch()) WHERE asset_id=? AND person_id=?").bind(row.assetId,person),
   env.DB.prepare('UPDATE family_representative_slots SET asset_id=NULL WHERE family_id=? AND asset_id=?').bind(row.familyId,row.assetId),
  ]);
  await env.MEDIA.delete(row.objectKey);
  if(await env.MEDIA.head(row.objectKey))throw new ApiError(503,'unavailable','The deletion could not be verified.');
  await env.DB.prepare('DELETE FROM family_representative_assets WHERE asset_id=? AND person_id=? AND object_key=?').bind(row.assetId,person,row.objectKey).run();
 }
 return (await familyIdentityPhotos(env,person)).length>0;
}
