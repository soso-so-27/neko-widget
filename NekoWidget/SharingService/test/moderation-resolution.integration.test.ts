import {env} from 'cloudflare:workers';
import {applyD1Migrations,reset,type D1Migration} from 'cloudflare:test';
import {beforeEach,describe,expect,it} from 'vitest';
import {resolutionFixture,resolutionDB as db} from './fixtures/moderation-resolution';
import {routeLocalModerationResolution} from '../src/moderation-resolution-local';
import {routeLocalModerationOwner} from '../src/moderation-owner-local';
import {routeLocalModerationOperatorTriage} from '../src/moderation-operator-triage-local';
import {deriveModerationOperatorCaseReference} from '../src/moderation-operator-case-reference';
import {base64urlEncode} from '../src/encoding';
beforeEach(async()=>{await reset();await applyD1Migrations(db,(env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS)});
const count=async(table:string)=>(await db.prepare(`SELECT COUNT(*) n FROM ${table}`).first<{n:number}>())!.n;
describe('case-bound signed reversible moderation',()=>{
 it('admits a scope across the challenge issue clock boundary without extending its expiry',async()=>{
  const f=await resolutionFixture(undefined,'scope'),receipt=await f.read();
  const issued=await f.issue('hide',receipt,0);
  const row=await db.prepare(`SELECT unixepoch()-issued_at AS elapsed,expires_at-issued_at AS lifetime
   FROM moderation_resolution_current_challenges WHERE challenge_id=?`).bind(issued.challengeId).first<{elapsed:number;lifetime:number}>();
  expect(row?.elapsed).toBeGreaterThanOrEqual(1);
  expect(row?.lifetime).toBeLessThanOrEqual(300);
  expect(await count('moderation_resolution_events')).toBe(0);
 });
 it('combines two independent cases and releasing one never releases the other',async()=>{
  const f=await resolutionFixture();
  const row=(await db.prepare('SELECT * FROM moment_reports WHERE id=?').bind(f.reportId).first())!;
  const id=base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
  const reporter=base64urlEncode(crypto.getRandomValues(new Uint8Array(16))),device=base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
  await db.prepare(`INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES (?,?,'member','active',unixepoch(),unixepoch())`).bind(reporter,row.space_id).run();
  await db.prepare(`INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at)
    SELECT ?,?,agreement_public_key,signing_public_key,'active',unixepoch(),unixepoch() FROM moment_devices WHERE id=?`).bind(device,reporter,row.reporter_device_id).run();
  await db.prepare(`INSERT INTO moment_deliveries(moment_id,recipient_participant_id,state,created_at,access_expires_at)
    SELECT moment_id,?,'pending',created_at,access_expires_at FROM moment_deliveries WHERE moment_id=? AND recipient_participant_id=?`)
    .bind(reporter,row.moment_id,row.reporter_participant_id).run();
  const reference=(await deriveModerationOperatorCaseReference({reportId:id,caseReferenceHmacKeyVersion:1},crypto.getRandomValues(new Uint8Array(32)))).caseReferenceHmac;
  const copy={...row,id,reporter_participant_id:reporter,reporter_device_id:device,object_key:`reports/${id}`,state:'reserved',uploaded_at:null,committed_at:null,content_expires_at:null,closed_at:null,
   dedupe_key:base64urlEncode(crypto.getRandomValues(new Uint8Array(32)))};
  await db.prepare(`INSERT INTO moment_reports (${Object.keys(copy).join(',')}) VALUES (${Object.keys(copy).map(()=>'?').join(',')})`).bind(...Object.values(copy)).run();
  await db.prepare(`UPDATE moment_reports SET state='uploaded',uploaded_at=unixepoch() WHERE id=?`).bind(id).run();
  await db.prepare(`INSERT INTO moment_report_commit_events VALUES(?,?,?,unixepoch(),unixepoch()+604800)`)
   .bind(crypto.randomUUID(),id,reporter).run();
  await db.prepare(`INSERT INTO moderation_operator_versioned_case_references VALUES(?,?,1,1,'NW.MODERATION-OPERATOR.CASE-REFERENCE',unixepoch())`).bind(id,reference).run();
  const a=await f.act('hide',await f.read(),0);
  const b=await f.act('hide',await f.read(reference),1,reference);
  await f.act('release',a.eventId,2);
  expect(await db.prepare('SELECT revision,hidden FROM moderation_moment_states').first()).toEqual({revision:3,hidden:1});
  await f.act('release',b.eventId,3,reference);
  expect(await db.prepare('SELECT revision,hidden FROM moderation_moment_states').first()).toEqual({revision:4,hidden:0});
 });
 it('hides and releases without changing delivery lifetime, then closes with an exact reporter reply',async()=>{
  const f=await resolutionFixture(),receipt=await f.read();
  const before=await db.prepare('SELECT * FROM moment_deliveries').all();
  const hidden=await f.act('hide',receipt,0);
  expect(await db.prepare('SELECT revision,hidden FROM moderation_moment_states').first()).toEqual({revision:1,hidden:1});
  expect((await db.prepare('SELECT * FROM moment_deliveries').all()).results).toEqual(before.results);
  const released=await f.act('release',hidden.eventId,1);
  expect(released.reply).toBe('available_in_app');
  expect(await db.prepare('SELECT revision,hidden FROM moderation_moment_states').first()).toEqual({revision:2,hidden:0});
  await f.act('no_action',receipt,2);
  const queue=await routeLocalModerationOperatorTriage(f.request('/operator/v1/cases/read','POST'),f.local);
  expect(await queue.json()).toMatchObject({cases:[]});
  expect(await count('moderation_resolution_replies')).toBe(3);
  expect(await db.prepare(`SELECT COUNT(*) n FROM moderation_resolution_replies reply JOIN moment_reports r ON r.id=reply.report_id
    WHERE reply.recipient_participant_id<>r.reporter_participant_id`).first()).toEqual({n:0});
  expect(await count('moderation_resolution_reply_receipts')).toBe(0);
 });
 it.each(['event','reply'] as const)('burns a bad signature, refuses replay, stale concurrent revisions and old credential counters across the %s clock boundary',async boundary=>{
  const f=await resolutionFixture(undefined,boundary),receipt=await f.read(),bad=await f.issue('hide',receipt,0);
  expect((await f.prove(bad,true)).status).toBeGreaterThanOrEqual(400);
  expect((await f.prove(bad)).status).toBeGreaterThanOrEqual(400);
  expect(await count('moderation_resolution_events')).toBe(0);
  const a=await f.issue('hide',receipt,0),b=await f.issue('no_action',receipt,0);
  expect((await f.prove(a)).status,JSON.stringify(f.databaseFailures)).toBe(200);
  const elapsed=await db.prepare(`SELECT e.recorded_at-consumed.consumed_at AS event_seconds,reply.created_at-e.recorded_at AS reply_seconds
   FROM moderation_resolution_events e JOIN moderation_resolution_consumptions consumed USING(challenge_id)
   JOIN moderation_resolution_replies reply ON reply.event_id=e.event_id`).first<{event_seconds:number;reply_seconds:number}>();
  expect(elapsed![boundary==='event'?'event_seconds':'reply_seconds']).toBeGreaterThanOrEqual(1);
  expect((await f.prove(b)).status).toBe(409);
  const start=await routeLocalModerationOperatorTriage(f.request(f.operationPath,'POST'),f.local);
  expect(start.status).toBe(202);
  const legacy=await start.json() as {challenge:string;assertionPath:string};
  expect((await routeLocalModerationOperatorTriage(f.request(legacy.assertionPath,'POST',await f.assertion(legacy.challenge,{counter:1})),f.local)).status).toBeGreaterThanOrEqual(400);
  expect(await count('moderation_resolution_events')).toBe(1);
 });
 it('blocks legacy no-action while its case is hidden',async()=>{
  const f=await resolutionFixture(),receipt=await f.read();await f.act('hide',receipt,0);
  const r=await routeLocalModerationOwner(f.request(`/operator/owner/v1/cases/${f.caseReference}/1/decisions/no-action/${receipt}`,'POST'),f.local);
  if(r.status===202){const i=await r.json() as {challenge:string;assertionPath:string};expect((await routeLocalModerationOwner(f.request(i.assertionPath,'POST',await f.assertion(i.challenge,{counter:10})),f.local)).status).toBeGreaterThanOrEqual(400)}
  else expect(r.status).toBe(409);
  expect(await count('moderation_owner_decisions')).toBe(0);
 });
 it('releases after report expiry without reviving that report or sending a reply',async()=>{
  const f=await resolutionFixture(),receipt=await f.read(),h=await f.act('hide',receipt,0);
  await db.prepare(`UPDATE moment_reports SET state='expired',closed_at=unixepoch() WHERE id=?`).bind(f.reportId).run();
  const queue=await routeLocalModerationOperatorTriage(f.request('/operator/v1/cases/read','POST'),f.local);
  expect(await queue.json()).toMatchObject({cases:[{restrictionActive:1,evidenceAvailable:0}]});
  const result=await f.act('release',h.eventId,1);
  expect(result.reply).toBe('not_created_source_unavailable');
  expect(await count('moderation_resolution_replies')).toBe(0);
  expect(await db.prepare('SELECT state FROM moment_reports').first()).toEqual({state:'expired'});
 });
 it('never restores expired moment access and permits ordinary parent cleanup',async()=>{
  const f=await resolutionFixture(),receipt=await f.read(),h=await f.act('hide',receipt,0);
  await db.prepare(`UPDATE moments SET state='expired',closed_at=unixepoch()`).run();
  expect((await routeLocalModerationResolution(f.request(`${f.path()}/release/${h.eventId}/1`,'POST'),f.local)).status).toBe(409);
  await db.prepare('DELETE FROM moment_spaces').run();
  expect(await count('moderation_resolution_targets')).toBe(0);
  expect(await count('moderation_resolution_scopes')).toBe(0);
  expect(await count('moderation_resolution_events')).toBe(1);
 });
 it('pins a case to its original moment and suppresses replies after the report source changes',async()=>{
  const f=await resolutionFixture(),receipt=await f.read(),h=await f.act('hide',receipt,0);
  const original=(await db.prepare('SELECT * FROM moments').first())!;
  const next=base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
  const copy={...original,id:next,client_moment_id:crypto.randomUUID(),object_key:`moments/${next}`};
  await db.prepare(`INSERT INTO moments (${Object.keys(copy).join(',')}) VALUES (${Object.keys(copy).map(()=>'?').join(',')})`).bind(...Object.values(copy)).run();
  await db.prepare('UPDATE moment_reports SET moment_id=? WHERE id=?').bind(next,f.reportId).run();
  expect(await count('moderation_resolution_replies')).toBe(0);
  const release=await f.act('release',h.eventId,1);
  expect(release.reply).toBe('not_created_source_unavailable');
  const newReceipt=await f.read();
  expect((await routeLocalModerationResolution(f.request(`${f.path()}/hide/${newReceipt}/2`,'POST'),f.local)).status).toBe(409);
  expect(await db.prepare('SELECT moment_id,revision,hidden FROM moderation_moment_states').first()).toEqual({moment_id:original.id,revision:2,hidden:0});
  const wrongVersion=await routeLocalModerationResolution(f.request(f.path().replace('/1','/2')+'/state','POST'),f.local);
  expect(await wrongVersion.json()).toMatchObject({targetAvailable:false,restrictionEventId:null,operation:null});
 });
 it('does not grant runtime or owner permissions by creating schema',async()=>{
  const f=await resolutionFixture();
  for(const local of [{...f.local,runtimeEnabled:'NO'},{...f.local,environment:'production'}])
   expect((await routeLocalModerationResolution(f.request(f.path()+'/state','POST'),local)).status).toBe(503);
  expect(await count('moderation_resolution_events')).toBe(0);
 });
});
