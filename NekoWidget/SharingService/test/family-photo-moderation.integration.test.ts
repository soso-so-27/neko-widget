import {describe,it,expect,beforeEach} from 'vitest';
import {env} from 'cloudflare:workers';
import {reset,applyD1Migrations,type D1Migration} from 'cloudflare:test';
import {fixture as operatorFixture} from './fixtures/moderation-operator';
import {db,person,signed,testEnv,send,ok} from './group-fixture';
import {base64urlEncode,sha256Base64url,randomBase64url} from '../src/encoding';
import {routeFamilyPhotoOperator,type FamilyPhotoOperatorEnvironment} from '../src/family-photo-moderation-operator';
import {familyPhotoStopped} from '../src/family-photo-report-operations';
import {acceptIdentityFence} from '../src/group-identity-fence';
import {prepareReportManifest,installReportManifest,sealIdentityReportAcceptance,runIdentityReportErasure} from '../src/group-identity-report-erasure';
const settings={...testEnv,FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES',FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED:'YES',
 GROUP_REPORT_RUNTIME_ENABLED:'YES',GROUP_MODERATION_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES'};
beforeEach(async()=>{
 await reset();await applyD1Migrations(db,(env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS);
 await db.prepare(`UPDATE personal_staging_runtime_gate SET generation=generation+1,media_enabled=1,
 apns_enabled=1,report_ingestion_enabled=1,updated_at=unixepoch() WHERE singleton=1 AND generation=0`).run();
});
async function fixture(){
 const reporter=await person(),author=await person(),family=crypto.randomUUID(),asset=crypto.randomUUID();
 await db.prepare('INSERT INTO family_photo_report_deliveries VALUES (?,?,?,?,?,unixepoch()+604800)')
 .bind(family,asset,reporter.id,reporter.deviceId,author.id).run();
 const bytes=new Uint8Array(100).fill(7),body={schemaVersion:1,operationId:crypto.randomUUID(),assetId:asset,
 reasonCode:'privacy',moderationKeyId:'moderation-v2',ciphertext:base64urlEncode(bytes),
 ciphertextSHA256:await sha256Base64url(bytes),consentedAt:Math.floor(Date.now()/1000)};
 const path=`/v3/family-notebooks/${family}/representative-photos/reports`;
 const report=ok(await send(await signed(reporter,path,body),settings));
 const operator=await operatorFixture();
 await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
 SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
 COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
 FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
 WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(operator.operatorId,operator.operatorId).run();
 const local:FamilyPhotoOperatorEnvironment={...operator.local,db,familyPhoto:{runtimeEnabled:'YES',
 caseHmacKey:new Uint8Array(32).fill(3),reviewEvidence:async input=>{
 await input.audit('started');await input.readCurrentSource();await input.audit('disclosure_ready');
 await input.readCurrentSource();return new Uint8Array([255,216,255,217]);}}};
 const dispatch=(path:string,body?:string)=>routeFamilyPhotoOperator(operator.request(path,'POST',body),local);
 let counter=0;
 async function issue(path:string){const r=await dispatch(path);expect(r.status,await r.clone().text()).toBe(202);return r.json() as Promise<{challenge:string;assertionPath:string}>;}
 async function prove(c:{challenge:string;assertionPath:string}){return dispatch(c.assertionPath,await operator.assertion(c.challenge,{counter:++counter}));}
 return {family,asset,report,body,path,reporter,author,dispatch,issue,prove,local};
}
describe('family photo reports and operator boundary',()=>{
 it('closes replies before authentication when the representative photo report gates close', async () => {
  const path = 'https://group.invalid/v3/family-notebooks/report-replies';
  const expectClosed = async (gates: typeof settings) => {
   const response = await send(new Request(path), gates);
   expect(response.status).toBe(503);
   expect(response.data).toMatchObject({error:{code:'family_photo_replies_disabled'}});
  };
  for (const gate of ['FAMILY_NOTEBOOK_API_RUNTIME_ENABLED', 'FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED',
    'GROUP_REPORT_RUNTIME_ENABLED', 'GROUP_MODERATION_RUNTIME_ENABLED', 'REPORT_INGESTION_RUNTIME_ENABLED']) {
   await expectClosed({...settings,[gate]:'NO'});
  }
  await db.prepare('UPDATE personal_staging_runtime_gate SET generation=generation+1,report_ingestion_enabled=0,updated_at=unixepoch() WHERE singleton=1').run();
  await expectClosed(settings);
 });
 it('lists only the reporting person’s retained replies, independent of membership', async () => {
  const f = await fixture(), path = '/v3/family-notebooks/report-replies';
  const reading = {...settings, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'NO'};
  const read = async (p = f.reporter) => send(await signed(p, path), reading);
  const record = {receiptNumber:f.report.reportId, receivedAt:f.report.committedAt, status:'received'};
  // Receipt remains available to the same person on a registered replacement
  // device. The synthetic report is deliberately outside any family membership.
  expect(ok(await read())).toEqual({schemaVersion:1, replies:[record]});
  expect(ok(await read(await person(f.reporter.identity))).replies).toEqual([record]);
  expect(ok(await read(f.author)).replies).toEqual([]);
  expect(ok(await read(await person())).replies).toEqual([]);
  const unsigned = await send(new Request('https://group.invalid'+path), reading);
  expect(unsigned.status).toBe(401);
  const prefix = '/operator/family-photo/v1';
  const queue = await f.prove(await f.issue(prefix+'/queue'));
  const {cases} = await queue.json() as {cases:{caseReference:string}[]};
  const current = prefix+'/cases/'+cases[0]!.caseReference;
  const opened = await f.prove(await f.issue(current+'/read'));
  expect((await f.prove(await f.issue(current+'/photo/'+opened.headers.get('X-Moderation-Read-Receipt')))).status).toBe(200);
  expect(ok(await read()).replies).toEqual([{...record,status:'photo_stopped'}]);
  expect((await f.prove(await f.issue(current+'/release'))).status).toBe(200);
  expect(ok(await read()).replies).toEqual([{...record,status:'reviewed'}]);
  await db.prepare('UPDATE family_photo_report_records SET retention_until=unixepoch() WHERE report_id=?').bind(f.report.reportId).run();
  expect(ok(await read()).replies).toEqual([]);
 });
 it('includes only eligible family evidence in the existing sealed identity erasure',async()=>{
 const f=await fixture(),now=Math.floor(Date.now()/1000),subject=f.author.id;
 const object=await db.prepare('SELECT object_key FROM family_photo_reports WHERE report_id=?').bind(f.report.reportId).first<string>('object_key');
 const requestId=crypto.randomUUID(),snapshot=await prepareReportManifest(settings,{requestId,acceptedAt:now},subject);
 expect(snapshot.entries).toHaveLength(1);
 const fence={...await acceptIdentityFence(settings.MEDIA!,subject,requestId,randomBase64url(32),randomBase64url(32),now),nonce:crypto.randomUUID()};
 await installReportManifest(settings,fence,subject,snapshot);
 await db.prepare('INSERT INTO group_identity_deletion_acceptance(request_id,subject_id,nonce,request_hash,accepted_at) VALUES(?,?,?,?,?)')
 .bind(requestId,subject,fence.nonce,fence.requestHash,fence.acceptedAt).run();
 await sealIdentityReportAcceptance(settings,fence,subject,fence.requestHash,snapshot);
 await runIdentityReportErasure(settings,fence,subject);
 expect(await db.prepare('SELECT 1 FROM family_photo_reports WHERE report_id=?').bind(f.report.reportId).first()).toBeNull();
 expect(await db.prepare('SELECT 1 FROM family_photo_report_records WHERE report_id=?').bind(f.report.reportId).first()).toBeNull();
 expect(await settings.MODERATION_MEDIA!.head(object!)).toBeNull();
 });
 it('accepts exact retries without extending the deadline and rejects an undelivered target',async()=>{
 const f=await fixture();
 expect(ok(await send(await signed(f.reporter,f.path,f.body),settings))).toEqual(f.report);
 expect((await send(await signed(f.reporter,f.path,{...f.body,operationId:crypto.randomUUID(),assetId:crypto.randomUUID()}),settings)).status).toBe(404);
 });
 it('requires verified review for a stop and explicit verified release, with replay protection',async()=>{
 const f=await fixture(),prefix='/operator/family-photo/v1';
 const q=await f.prove(await f.issue(prefix+'/queue'));expect(q.status,await q.clone().text()).toBe(200);
 const data=await q.json() as {cases:{caseReference:string}[]},ref=data.cases[0]!.caseReference;
 expect((await f.dispatch(`${prefix}/cases/${ref}/photo/${crypto.randomUUID()}`)).status).toBe(409);
 const read=await f.prove(await f.issue(`${prefix}/cases/${ref}/read`));expect(read.status,await read.clone().text()).toBe(200);
 const receipt=read.headers.get('X-Moderation-Read-Receipt')!;
 const stop=await f.issue(`${prefix}/cases/${ref}/photo/${receipt}`);
 expect((await f.prove(stop)).status).toBe(200);expect(await familyPhotoStopped(db,f.family,f.asset)).toBe(true);
 expect((await f.prove(stop)).status).toBe(409);
 expect((await f.dispatch(`${prefix}/cases/${ref}/no_action/${receipt}`)).status).toBe(409);
 const release=await f.issue(`${prefix}/cases/${ref}/release`);
 expect((await f.prove(release)).status).toBe(200);expect(await familyPhotoStopped(db,f.family,f.asset)).toBe(false);
 });
 it('rejects intake when any reviewed upper gate is OFF',async()=>{
 const f=await fixture();
 for(const gate of ['FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED','GROUP_REPORT_RUNTIME_ENABLED','GROUP_MODERATION_RUNTIME_ENABLED','REPORT_INGESTION_RUNTIME_ENABLED']){
 expect((await send(await signed(f.reporter,f.path,f.body),{...settings,[gate]:'NO'})).status).toBe(503);
 }
 });
});
