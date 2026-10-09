import { env } from 'cloudflare:workers';
import { expect } from 'vitest';
import { fixture } from './moderation-operator';
import { routeLocalModerationOwner, type LocalModerationOwnerEnvironment } from '../../src/moderation-owner-local';
import { routeLocalModerationResolution } from '../../src/moderation-resolution-local';

export const resolutionDB=(env as unknown as {DB:D1Database}).DB;
export async function resolutionFixture(existingReportId?: string) {
 const f=await fixture(existingReportId),db=resolutionDB;
 await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
 SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
  COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
 FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
 WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(f.operatorId,f.operatorId).run();
 const local:LocalModerationOwnerEnvironment={...f.local,reviewEvidence:async input=>{
  await input.audit('started');await input.readCurrentSource();await input.audit('disclosure_ready');await input.readCurrentSource();
  return new Uint8Array([255,216,255,217]);
 }};
 let counter=0;
 const path=(reference=f.caseReference)=>`/operator/resolution/v1/cases/${reference}/1`;
 async function read(reference=f.caseReference) {
  const response=await routeLocalModerationOwner(f.request(`/operator/owner/v1/cases/${reference}/1/content-read`,'POST'),local);
  expect(response.status,await response.clone().text()).toBe(202);
  const issued=await response.json() as {assertionPath:string;challenge:string};
  const opened=await routeLocalModerationOwner(f.request(issued.assertionPath,'POST',await f.assertion(issued.challenge,{counter:++counter})),local);
  expect(opened.status,opened.status===200?'':await opened.clone().text()).toBe(200);
  await opened.arrayBuffer();
  return opened.headers.get('X-Moderation-Read-Receipt')!;
 }
 async function issue(operation:string,identity:string,revision:number,reference=f.caseReference) {
  const response=await routeLocalModerationResolution(f.request(`${path(reference)}/${operation}/${identity}/${revision}`,'POST'),local);
  expect(response.status,await response.clone().text()).toBe(202);
  return response.json() as Promise<{assertionPath:string;challenge:string;challengeId:string}>;
 }
 async function prove(issued:Awaited<ReturnType<typeof issue>>,invalidSignature=false) {
  return routeLocalModerationResolution(f.request(issued.assertionPath,'POST',await f.assertion(issued.challenge,{counter:++counter,invalidSignature})),local);
 }
 async function act(operation:'hide'|'release'|'no_action',identity:string,revision:number,reference=f.caseReference) {
  const response=await prove(await issue(operation,identity,revision,reference));
  expect(response.status,await response.clone().text()).toBe(200);
  return response.json() as Promise<{eventId:string;revision:number;reply:string}>;
 }
 return {...f,local,path,read,issue,prove,act};
}
