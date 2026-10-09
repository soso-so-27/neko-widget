import { env } from 'cloudflare:workers';
import { expect } from 'vitest';
import { fixture } from './moderation-operator';
import { routeLocalModerationOwner, type LocalModerationOwnerEnvironment } from '../../src/moderation-owner-local';
import { routeLocalModerationResolution } from '../../src/moderation-resolution-local';

export const resolutionDB=(env as unknown as {DB:D1Database}).DB;
export async function resolutionFixture(existingReportId?: string, crossCommitSecond?: 'scope'|'event'|'reply') {
 const f=await fixture(existingReportId),db=resolutionDB;
 const databaseFailures:string[]=[];
 let observedOperation:'issue'|'prove'|undefined;
 const observedDB=new Proxy(db,{get(target,key){
  if(key==='batch')return async(statements:D1PreparedStatement[])=>{
   // Keep the real atomic transaction and constraints. A read-only SQL workload
   // forces a clock boundary before the event or reply, independently of request time.
   if((observedOperation==='issue'&&crossCommitSecond==='scope'&&statements.length===5)
    ||(observedOperation==='prove'&&(crossCommitSecond==='event'||crossCommitSecond==='reply')&&statements.length===6)){
    const index=crossCommitSecond==='scope'?3:crossCommitSecond==='event'?4:5;
    statements=[...statements.slice(0,index),target.prepare('WITH RECURSIVE wait(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM wait WHERE n<16000000) SELECT sum(n) FROM wait'),...statements.slice(index)];
   }
   try{return await target.batch(statements)}catch(error){databaseFailures.push(String(error));throw error}
  };
  const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
 }});
 await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
 SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
  COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
 FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
 WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(f.operatorId,f.operatorId).run();
 const local:LocalModerationOwnerEnvironment={...f.local,db:observedDB,reviewEvidence:async input=>{
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
  observedOperation='issue';
  const response=await routeLocalModerationResolution(f.request(`${path(reference)}/${operation}/${identity}/${revision}`,'POST'),local);
  observedOperation=undefined;
  expect(response.status,await response.clone().text()).toBe(202);
  return response.json() as Promise<{assertionPath:string;challenge:string;challengeId:string}>;
 }
 async function prove(issued:Awaited<ReturnType<typeof issue>>,invalidSignature=false) {
  observedOperation='prove';
  try{return await routeLocalModerationResolution(f.request(issued.assertionPath,'POST',await f.assertion(issued.challenge,{counter:++counter,invalidSignature})),local)}
  finally{observedOperation=undefined}
 }
 async function act(operation:'hide'|'release'|'no_action',identity:string,revision:number,reference=f.caseReference) {
  const response=await prove(await issue(operation,identity,revision,reference));
  expect(response.status,await response.clone().text()).toBe(200);
  return response.json() as Promise<{eventId:string;revision:number;reply:string}>;
 }
 return {...f,local,path,read,issue,prove,act,databaseFailures};
}
