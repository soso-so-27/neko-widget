import { randomBase64url } from '../src/encoding';
import { drainFamilyNotifications } from '../src/family-notebook-push';
import { describe, expect, it, beforeEach } from 'vitest';
import { route } from '../src/index';
import { familyInvitationProof } from '../src/family-notebook-admission';
import { familyNotebookPayer } from '../src/family-notebook-payer';
import { groupDeviceAuthorization } from '../src/group-protocol';
import { base64urlEncode } from '../src/encoding';
import { errorResponse } from '../src/errors';
import type { Env } from '../src/env';
import { plusOwner, pauseOwner, settings } from './group-billing-fixture';
import { cipher, create, db, ok, person, send, sign, signed, type Person, type Reply } from './group-fixture';

const enabled: Env = { ...settings, FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES', FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'YES' };
const root = '/v3/family-notebooks';
async function invoke(request: Request, env: Env = enabled): Promise<Reply> {
  let response: Response;
  try { response = await route(request, env); } catch (error) { response = errorResponse(error); }
  return { status: response.status, data: await response.json() as Reply['data'] };
}
async function call(p: Person, path: string, body: unknown, env = enabled) { return invoke(await signed(p, path, body), env); }
async function openGate() { await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run(); }
async function family(p: Person) {
  await openGate();
  const familyId = crypto.randomUUID(), body = { operationId: crypto.randomUUID(), familyId };
  const receipt = ok(await call(p, root, body));
  return { id: familyId, body, receipt };
}
async function invitation(p: Person, f: string, generation = 1) {
  const keys = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const body = { operationId: crypto.randomUUID(), expectedGeneration: generation,
    proofPublicKey: base64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey))), encryptedPreview: cipher() };
  ok(await call(p, `${root}/${f}/invitations`, body));
  return { id: body.operationId, keys, body };
}
async function proof(p: Person, f: string, i: Awaited<ReturnType<typeof invitation>>, action: 'preview' | 'join', operationId: string) {
  return sign(i.keys.privateKey, familyInvitationProof(f, i.id, p.id, p.deviceId, action, operationId));
}
async function join(p: Person, f: string, i: Awaited<ReturnType<typeof invitation>>, generation = 1) {
  const operationId = crypto.randomUUID(), body = { operationId, expectedGeneration: generation,
    proofSignature: await proof(p, f, i, 'join', operationId), encryptedDisplayName: cipher() };
  const reply = await call(p, `${root}/${f}/invitations/${i.id}/join`, body);
  return { id: operationId, body, reply };
}
async function approve(p: Person, f: string, j: string, generation = 1, env = enabled) {
  return call(p, `${root}/${f}/requests/${j}/approve`, { operationId: crypto.randomUUID(), expectedGeneration: generation }, env);
}
async function leave(p: Person, f: string, generation: number) {
  const request = await signed(p, `${root}/${f}/leave`, { operationId: crypto.randomUUID(), expectedGeneration: generation });
  return familyNotebookPayer(request, enabled, f, 'leave');
}
function beforeCommit(action: () => Promise<void>): Env {
  let pending = true;
  return { ...enabled, DB: new Proxy(db, { get(target, property) {
    if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
      if (pending) { pending = false; await action(); }
      return target.batch(statements);
    };
    const value = Reflect.get(target, property);
    return typeof value === 'function' ? value.bind(target) : value;
  } }) };
}


async function setupPush() {
 const owner=await plusOwner(),guest=await person(),f=await family(owner),i=await invitation(owner,f.id),j=await join(guest,f.id,i);ok(j.reply);
 const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
 const raw=new Uint8Array(await crypto.subtle.exportKey('pkcs8',keys.privateKey));
 const config:Env={...enabled,FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:'YES',APNS_RUNTIME_ENABLED:'YES',
 APNS_PROVIDER_CREDENTIAL_JSON:JSON.stringify({keyId:'A1B2C3D4E5',teamId:'Z9Y8X7W6V5',bundleId:'jp.nekowidget.app',environment:'production',privateKey:`-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...raw))}\n-----END PRIVATE KEY-----`}),
 APNS_TOKEN_KEYRING_JSON:JSON.stringify({current:'test',keys:{test:randomBase64url(32)}})};
 const register=(p:Person,token=randomBase64url(32))=>call(p,`${root}/${f.id}/push-subscription`,{operationId:crypto.randomUUID(),token,environment:'production'},config);
 const remove=(p:Person)=>call(p,`${root}/${f.id}/push-subscription/remove`,{operationId:crypto.randomUUID()},config);
 return {owner,guest,f,i,j,config,register,remove,now:Math.floor(Date.now()/1000)+241};
}
beforeEach(async()=>{await db.prepare("UPDATE family_push_subscriptions SET expires_at=0,token_ciphertext='',token_nonce='',token_digest=''").run();await db.prepare('UPDATE personal_staging_runtime_gate SET media_enabled=1,apns_enabled=1,generation=generation+1 WHERE singleton=1').run();});
describe('family admission notifications',()=>{
 it('sends only the two fixed messages with late registration and deduplication',async()=>{
 const f=await setupPush();ok(await f.register(f.owner));const bodies:any[]=[];
 const transport:typeof fetch=async(_url,init)=>{bodies.push(JSON.parse(init!.body as string));return new Response(null,{status:200});};
 expect((await drainFamilyNotifications(f.config,undefined,transport)).accepted).toBe(0);
 expect((await drainFamilyNotifications(f.config,f.now,transport)).accepted).toBe(1);
 expect(bodies[0].aps.alert.body).toBe('家族の手帳に、参加を待っている人がいます。');
 expect((await drainFamilyNotifications(f.config,f.now,transport)).accepted).toBe(0);
 ok(await approve(f.owner,f.f.id,f.j.id));ok(await f.register(f.guest));
 expect((await drainFamilyNotifications(f.config,f.now,transport)).accepted).toBe(1);
 expect(bodies[1].aps.alert.body).toBe('家族の手帳に参加できました。');
 expect(bodies[1].neko).toEqual({v:3,kind:'family_join_approved',familyId:f.f.id});
 expect(JSON.stringify(bodies)).not.toContain('encrypted');expect(JSON.stringify(bodies)).not.toContain(f.guest.id);
 });
 it('rejects outsiders and does not give pending applicants membership',async()=>{
 const f=await setupPush(),outsider=await person(),token=randomBase64url(32);expect((await f.register(outsider)).status).toBe(404);ok(await f.register(f.guest,token));
 expect(await db.prepare('SELECT 1 FROM family_notebook_members WHERE family_id=? AND person_id=?').bind(f.f.id,f.guest.id).first()).toBeNull();
 const row=await db.prepare('SELECT * FROM family_push_subscriptions WHERE device_id=?').bind(f.guest.deviceId).first();expect(JSON.stringify(row)).not.toContain(token);
 });
 it.each(['familyGate','apnsGate','remove','revokeDevice','reject'] as const)('fences %s before sending',async(kind)=>{
 const f=await setupPush();ok(await f.register(f.owner));let sends=0;
 const beforeSend=async()=>{
 if(kind==='familyGate')await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=0 WHERE singleton=1').run();
 if(kind==='apnsGate')await db.prepare('UPDATE personal_staging_runtime_gate SET apns_enabled=0,generation=generation+1 WHERE singleton=1').run();
 if(kind==='remove')ok(await f.remove(f.owner));
 if(kind==='revokeDevice')await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(f.owner.deviceId).run();
 if(kind==='reject')ok(await call(f.owner,`${root}/${f.f.id}/requests/${f.j.id}/reject`,{operationId:crypto.randomUUID(),expectedGeneration:1},f.config));
 };
 await drainFamilyNotifications(f.config,f.now,async()=>{sends++;return new Response(null,{status:200});},{beforeSend});expect(sends).toBe(0);
 });
 it('leases once under concurrent drains and shares provider backoff',async()=>{
 const f=await setupPush();ok(await f.register(f.owner));let sends=0;const transport:typeof fetch=async()=>{sends++;return new Response(null,{status:503});};
 await Promise.all([drainFamilyNotifications(f.config,f.now,transport),drainFamilyNotifications(f.config,f.now,transport)]);expect(sends).toBe(1);
 await drainFamilyNotifications(f.config,f.now+1,transport);expect(sends).toBe(1);
 });
 it('allows opt-out when the send gate is disabled',async()=>{
 const f=await setupPush();ok(await f.register(f.guest));ok(await call(f.guest,`${root}/${f.f.id}/push-subscription/remove`,{operationId:crypto.randomUUID()},{...f.config,FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:'NO'}));
 expect(await db.prepare('SELECT token_ciphertext,token_digest,expires_at FROM family_push_subscriptions WHERE device_id=?').bind(f.guest.deviceId).first()).toEqual({token_ciphertext:'',token_digest:'',expires_at:0});
 });
 it('requires exact opt-in before any new schema access',async()=>{
 const dbNoAccess=new Proxy(db,{get(){throw Error('unexpected database access');}});
 for(const value of [undefined,'NO','yes'])expect((await drainFamilyNotifications({...enabled,DB:dbNoAccess,FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:value} as Env)).leased).toBe(0);
 });
});

describe('family device registration notifications',()=>{
 async function registerCertificate(p:Person,f:Awaited<ReturnType<typeof setupPush>>,signer=p,operationId=crypto.randomUUID(),config=f.config) {
  const device={id:p.deviceId,signingPublicKey:p.signing.publicKey,hpkePublicKey:p.hpke,personAuthorization:''};
  const personAuthorization=await sign(signer.identity.privateKey,groupDeviceAuthorization(f.f.id,p.id,device));
  return call(p,`${root}/${f.f.id}/crypto/devices`,{operationId,expectedGeneration:2,expectedEpoch:0,
    payload:{personAuthorization}},config);
 }
 it('sends only the recovery device wake-up to A and B in the selected staging notebook',async()=>{
  const f=await setupPush(),foreign=await setupPush();
  ok(await approve(f.owner,f.f.id,f.j.id));
  ok(await approve(foreign.owner,foreign.f.id,foreign.j.id));
  const recovery=await person(f.owner.identity), unlisted=await person(f.owner.identity);
  const outsideAdded=await person(foreign.owner.identity);
  for(const p of [f.owner,f.guest,unlisted]) ok(await registerCertificate(p,f));
  // Separate tokens make the exact physical recipients observable in the fake provider.
  for(const [p,byte] of [[f.owner,1],[f.guest,2],[unlisted,3],[recovery,4]] as const)
    ok(await f.register(p,base64urlEncode(new Uint8Array(32).fill(byte))));
  ok(await registerCertificate(foreign.owner,foreign));ok(await foreign.register(foreign.owner));
  ok(await registerCertificate(outsideAdded,foreign));
  const queuedOutside=await db.prepare(`INSERT INTO family_notification_deliveries
    (event_id,device_id,token_digest,subscription_generation,state,available_at)
    SELECT event_id,device_id,token_digest,subscription_generation,'pending',available_at
    FROM family_notification_candidates WHERE space_id=? AND kind='device_registered'`).bind(foreign.f.id).run();
  expect(queuedOutside.meta.changes).toBe(1);

  const config:Env={...f.config,ENVIRONMENT:'staging',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})},
    ownerTrial:{phase:'RECOVERY',family:f.f.id,
    phaseUntilMs:Date.now()+120_000,expiresAtMs:Date.now()+3_600_000,proofHash:randomBase64url(32),window:randomBase64url(16),
    aPerson:f.owner.id,aDevice:f.owner.deviceId,bPerson:f.guest.id,bDevice:f.guest.deviceId,recoveryDevice:recovery.deviceId}};
  const attempt=await registerCertificate(recovery,f,recovery,crypto.randomUUID(),config);
  ok(attempt);
  const sent:string[]=[];
  const transport:typeof fetch=async(url,init)=>{
    expect(new Headers(init?.headers).get('apns-push-type')).toBe('background');
    expect(JSON.parse(init!.body as string)).toEqual({aps:{'content-available':1},neko:{v:3,kind:'family_device_registered'}});
    sent.push(String(url).split('/').at(-1)!);
    return new Response(null,{status:200});
  };
  expect((await drainFamilyNotifications(config,f.now,transport)).accepted).toBe(2);
  expect(sent.sort()).toEqual(['01'.repeat(32),'02'.repeat(32)]);
  expect((await db.prepare(`SELECT state,attempts FROM family_notification_deliveries WHERE device_id=?`)
    .bind(foreign.owner.deviceId).first())).toEqual({state:'pending',attempts:0});
  expect((await drainFamilyNotifications(config,f.now,transport)).accepted).toBe(0);
 });
 it('wakes only opted-in existing notebook devices, once, with an empty background update',async()=>{
  const f=await setupPush();ok(await approve(f.owner,f.f.id,f.j.id));
  const added=await person(f.owner.identity),unlinked=await person(f.owner.identity),stranger=await plusOwner();
  const foreign=await family(stranger);
  for(const p of [f.owner,f.guest])ok(await registerCertificate(p,f));
  const tOwner=new Uint8Array(32).fill(1),tGuest=new Uint8Array(32).fill(2);
  for(const [p,t] of [[f.owner,base64urlEncode(tOwner)],[f.guest,base64urlEncode(tGuest)],
    [added,randomBase64url(32)],[unlinked,randomBase64url(32)]] as const) ok(await f.register(p,t));
  ok(await call(stranger,`${root}/${foreign.id}/push-subscription`,{operationId:crypto.randomUUID(),token:randomBase64url(32),environment:'production'},f.config));

  expect((await registerCertificate(added,f,f.guest)).data.error.code).toBe('invalid_family_proof');
  const op=crypto.randomUUID();
  ok(await registerCertificate(added,f,added,op));
  ok(await registerCertificate(added,f,added,op));
  ok(await registerCertificate(added,f));
  expect((await db.prepare('SELECT recipient_device_id FROM family_device_notification_events WHERE family_id=?').bind(f.f.id).all()).results
    .map(x=>x.recipient_device_id).sort()).toEqual([f.owner.deviceId,f.guest.deviceId].sort());
  const sent:string[]=[];
  const transport:typeof fetch=async(url,init)=>{
   const headers=new Headers(init?.headers);
   if(headers.get('apns-push-type')==='background') {
    expect(headers.get('apns-priority')).toBe('5');
    expect(JSON.parse(init!.body as string)).toEqual({aps:{'content-available':1},neko:{v:3,kind:'family_device_registered'}});
    sent.push(String(url).split('/').at(-1)!);
   }
   return new Response(null,{status:200});
  };
  await Promise.all([drainFamilyNotifications(f.config,f.now,transport),drainFamilyNotifications(f.config,f.now,transport)]);
  await drainFamilyNotifications(f.config,f.now,transport);
  expect(sent.sort()).toEqual(['01'.repeat(tOwner.length),'02'.repeat(tGuest.length)]);
 });
 it('drops a wake-up when the newly registered device is revoked before dispatch',async()=>{
  const f=await setupPush();ok(await approve(f.owner,f.f.id,f.j.id));
  ok(await registerCertificate(f.owner,f));ok(await f.register(f.owner));
  const added=await person(f.owner.identity);ok(await registerCertificate(added,f));
  let sends=0;
  await drainFamilyNotifications(f.config,f.now,async(_url,init)=>{
   if(new Headers(init?.headers).get('apns-push-type')==='background')sends++;
   return new Response(null,{status:200});
  },{beforeSend:async row=>{
   if(row.event_id.includes(':device_registered:')) await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(added.deviceId).run();
  }});
  expect(sends).toBe(0);
 });
});

it('coalesces requests for payer and inviter but never for an unrelated family',async()=>{
 const f=await setupPush();ok(await approve(f.owner,f.f.id,f.j.id));ok(await f.register(f.guest));let sent:any[]=[];
 const transport:typeof fetch=async(_u,init)=>{sent.push(JSON.parse(init!.body as string));return new Response(null,{status:200});};
 await drainFamilyNotifications(f.config,f.now,transport);sent=[];ok(await f.register(f.owner));
 const a=await person(),b=await person();ok((await join(a,f.f.id,await invitation(f.guest,f.f.id,2),2)).reply);
 ok((await join(b,f.f.id,await invitation(f.owner,f.f.id,2),2)).reply);
 expect((await drainFamilyNotifications(f.config,f.now,transport)).accepted).toBe(2);
 expect(sent.every(x=>x.neko.kind==='family_join_requested')).toBe(true);
 expect((await drainFamilyNotifications(f.config,f.now,transport)).accepted).toBe(0);
});
it('revokes the old identity when a physical token is re-registered to another family',async()=>{
 const a=await setupPush(),token=randomBase64url(32);ok(await a.register(a.owner,token));
 const b=await setupPush();const config={...b.config,APNS_TOKEN_KEYRING_JSON:a.config.APNS_TOKEN_KEYRING_JSON!};
 ok(await call(b.owner,`${root}/${b.f.id}/push-subscription`,{operationId:crypto.randomUUID(),token,environment:'production'},config));
 expect(await db.prepare('SELECT token_ciphertext,token_digest,expires_at FROM family_push_subscriptions WHERE device_id=?').bind(a.owner.deviceId).first()).toEqual({token_ciphertext:'',token_digest:'',expires_at:0});
});
