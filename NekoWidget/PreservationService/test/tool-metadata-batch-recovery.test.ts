import { env } from 'cloudflare:workers';
import { applyD1Migrations, reset, type D1Migration } from 'cloudflare:test';
import { beforeEach, afterEach, expect, it, vi } from 'vitest';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';
import { route, type Services } from '../src/index';
import { OwnerRequestLimiter } from '../src/owner-request-limiter';
import { DeviceSessions } from '../src/device-sessions';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { deviceBinding } from '../src/device-proof';
import { ServiceError, randomToken, sha256, type IdentityVerifier } from '../src/contracts';
import { fixture, db } from './tool-metadata-batch-fixture';

const migrations=(env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS;
beforeEach(async()=>{await reset();await applyD1Migrations(db,migrations);});
afterEach(()=>vi.restoreAllMocks());
type F=Awaited<ReturnType<typeof fixture>>;
const service=(f:F)=>({auth:f.auth,archive:f.archive(),ownerRequestLimiter:new OwnerRequestLimiter(db)} as Services);
const request=(f:F)=>new Request('https://preservation.test/v1/tool-metadata-batches/recovery',{
  method:'POST',headers:{authorization:`Bearer ${f.session.token}`}});
const count=async(table:string,owner:string)=>(await db.prepare(`SELECT count(*) n FROM ${table} WHERE owner_id=?`).bind(owner).first<{n:number}>())!.n;
const provider=(f:F)=>Object.values(f.count).reduce((a,b)=>a+b,0);
async function partial(f:F){await f.archive().beginMetadataBatch(f.session.token,f.manifest);const p=f.parts[0]!;
  await f.archive().stageMetadataBatch(f.session.token,f.batchId,p.id,p.body);}
async function device(f:F){
  const origin='https://preservation.test',pair=await generateKeyPair('ES256',{extractable:true}),jwk=await exportJWK(pair.publicKey);
  const binding=await deviceBinding(jwk,origin);
  const devices=new DeviceSessions({db,keys:f.options.keys,now:f.now,identityIndexSecret:randomToken(),ownerRecovery:f.ownerCopy()});
  const credentials=await db.prepare('SELECT sealed_credentials,owner_epoch FROM pa_identity_credentials WHERE owner_id=?')
    .bind(f.session.ownerId).first<{sealed_credentials:number[];owner_epoch:number}>();
  const initial=await devices.initialGrant({issuer:'https://appleid.apple.com',subject:'synthetic',refreshToken:'synthetic',deviceBinding:binding},
    f.session.ownerId,credentials!.owner_epoch,f.now(),new Uint8Array(credentials!.sealed_credentials));
  await db.batch(initial.statements);const grantId=initial.grant!.grantId;
  expect(await count('pa_device_session_grants',f.session.ownerId)).toBe(1);
  return {origin,pair,jwk,devices,grantId};
}
async function noLogicalSave(f:F){
  expect(await count('pa_records',f.session.ownerId)).toBe(1);
  expect(await db.prepare('SELECT state FROM pa_tool_metadata_batches WHERE owner_id=?').bind(f.session.ownerId).first()).toEqual({state:'open'});
  await expect(f.archive().finishMetadataBatch(f.session.token,f.batchId)).rejects.toMatchObject({code:'TOOL_METADATA_BATCH_INCOMPLETE'});
  expect(await db.prepare('SELECT record_id FROM pa_records WHERE owner_id=?').bind(f.session.ownerId).first()).toEqual({record_id:f.parts[0]!.id});
}

it('repairs only committed inventory without a local manifest and restores ordinary auth without completing parts or head',async()=>{
  const f=await fixture(),other=await fixture(); await partial(f);
  const s=service(f),original={...f.count};
  await expect(route(request(other),service(other))).rejects.toMatchObject({code:'TOOL_METADATA_BATCH_NOT_FOUND',status:404});
  expect(f.count).toEqual(original);
  await expect(f.auth.requireSession(f.session.token)).rejects.toThrow();
  let completed=false,pending=0,maxProviders=0;
  for(let i=0;i<20;i++){
    const before=provider(f);const result=await (await route(request(f),s)).json() as {status:string};
    maxProviders=Math.max(maxProviders,provider(f)-before);
    if(result.status==='inventory-ready'){completed=true;break;}
    expect(result.status).toBe('pending');pending++;
    await expect(f.auth.requireSession(f.session.token)).rejects.toThrow();
  }
  expect(completed).toBe(true);expect(pending).toBeGreaterThan(1);expect(maxProviders).toBeLessThanOrEqual(26);
  await f.auth.requireSession(f.session.token);await noLogicalSave(f);
  expect(await count('pa_records',other.session.ownerId)).toBe(0);
  console.info('recovery-route-local',JSON.stringify({pending,maxProviders}));
},60_000);

it.each(['expired','revoked','disabled','deletion'] as const)('rejects %s authority before recovery provider work',async(reason)=>{
  const f=await fixture();await partial(f);
  if(reason==='expired')f.advance();
  if(reason==='disabled')await db.prepare('UPDATE pa_recovery_write_policy SET owner_snapshot_required=0 WHERE singleton=1').run();
  if(reason==='disabled')await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(f.session.ownerId).run();
  if(reason==='revoked'){
    const {grantId}=await device(f);
    await db.prepare('UPDATE pa_sessions SET device_grant_id=? WHERE session_hash=?').bind(grantId,await sha256(f.session.token)).run();
    await db.prepare('UPDATE pa_device_session_grants SET revoked_at=? WHERE grant_id=?').bind(f.now(),grantId).run();
  }
  if(reason==='deletion'){
    // Same external deletion dependency used by production auth, with a fixed denied receipt.
    const dependencies=(f.auth as unknown as {dependencies:{ownerDeletion?:unknown}}).dependencies;
    dependencies.ownerDeletion={assertNotRequested:async()=>{throw new ServiceError('OWNER_DELETION_PENDING',403);}};
  }
  const before={...f.count};await expect(route(request(f),service(f))).rejects.toThrow();expect(f.count).toEqual(before);
},60_000);

it('advances scheduled repair one bounded quantum and records pending as failure until actual coverage',async()=>{
  const f=await fixture();await partial(f);const copy=f.ownerCopy();
  const ordinary=vi.spyOn(copy,'copyCurrent');let pending=0,completed=false,maxProviders=0;
  for(let i=0;i<20;i++){
    const before=provider(f),result=await copy.repairBatch(db,f.now(),1);
    maxProviders=Math.max(maxProviders,provider(f)-before);
    expect(result.processed).toBe(1);
    if(result.failed===0){completed=true;break;}
    pending++;expect(await db.prepare('SELECT error_code FROM pa_owner_recovery_repair_failures WHERE owner_id=?').bind(f.session.ownerId).first())
      .toEqual({error_code:'OWNER_RECOVERY_PENDING'});
    await expect(f.auth.requireSession(f.session.token)).rejects.toThrow();
  }
  expect(completed).toBe(true);expect(pending).toBeGreaterThan(1);expect(maxProviders).toBeLessThanOrEqual(26);expect(ordinary).not.toHaveBeenCalled();
  expect(await count('pa_owner_recovery_repair_failures',f.session.ownerId)).toBe(0);await noLogicalSave(f);
  console.info('recovery-scheduled-local',JSON.stringify({pending,maxProviders}));
},60_000);

it('rejects a changed recovery nonce after a quantum and applies the existing request cap before further work',async()=>{
  const f=await fixture();await partial(f);const step=OwnerRecoveryCopy.prototype.copyCurrentStep;
  const spy=vi.spyOn(OwnerRecoveryCopy.prototype,'copyCurrentStep').mockImplementation(async function(this:OwnerRecoveryCopy,...args){
    const result=await step.apply(this,args);
    await db.prepare('UPDATE pa_tool_metadata_batches SET batch_nonce=? WHERE owner_id=?').bind(crypto.randomUUID(),f.session.ownerId).run();
    return result;
  });
  await expect(route(request(f),service(f))).rejects.toMatchObject({code:'TOOL_METADATA_BATCH_CHANGED'});
  spy.mockRestore();
  await db.prepare('UPDATE pa_owners SET http_request_count=30,http_request_minute=CAST(unixepoch()/60 AS INTEGER) WHERE owner_id=?').bind(f.session.ownerId).run();
  const before={...f.count};await expect(route(request(f),service(f))).rejects.toMatchObject({code:'RATE_LIMITED'});expect(f.count).toEqual(before);
  await expect(f.auth.requireSession(f.session.token)).rejects.toThrow();
},60_000);

it('uses real signed device proofs to repair expired-access inventory without issuing tokens or extending idle until covered',async()=>{
  const f=await fixture(),{origin,pair,jwk,devices,grantId}=await device(f);
  await partial(f);f.advance();
  const idle=await db.prepare('SELECT idle_expires_at FROM pa_device_session_grants WHERE grant_id=?').bind(grantId).first();
  const sessions=await count('pa_sessions',f.session.ownerId);
  const verifier:IdentityVerifier={verifyNativeAuthorization:async()=>{throw Error('unexpected');},verifyRefreshIdentity:async value=>value};
  let pending=0,complete=false,maxProviders=0;
  for(let i=0;i<20;i++){
    const challenge=await devices.issueChallenge(grantId,'renew',origin);
    const deviceProof=await new SignJWT({v:1,jti:challenge.challengeId,sub:grantId,nonce:challenge.nonce,htm:'POST',
      htu:origin+'/v1/auth/session-renewals',iat:Math.floor(f.now()/1000),exp:Math.floor(f.now()/1000)+90})
      .setProtectedHeader({alg:'ES256',typ:'dpop+jwt',jwk}).sign(pair.privateKey);
    const before=provider(f);
    if(i===0){
      await expect(devices.renew({grantId,challengeId:challenge.challengeId,deviceProof:deviceProof.slice(0,-8)+'AAAAAAAA',origin},verifier)).rejects.toThrow();
      expect(provider(f)).toBe(before);
    }
    try{
      const renewed=await devices.renew({grantId,challengeId:challenge.challengeId,deviceProof,origin},verifier);
      maxProviders=Math.max(maxProviders,provider(f)-before);await f.auth.requireSession(renewed.token);complete=true;break;
    }catch(error){
      maxProviders=Math.max(maxProviders,provider(f)-before);expect(error).toMatchObject({code:'auth_unavailable',status:503});pending++;
      expect(await count('pa_sessions',f.session.ownerId)).toBe(sessions);
      expect(await db.prepare('SELECT idle_expires_at FROM pa_device_session_grants WHERE grant_id=?').bind(grantId).first()).toEqual(idle);
      expect(await db.prepare('SELECT consumed_by FROM pa_device_session_challenges WHERE challenge_id=?').bind(challenge.challengeId).first()).toEqual({consumed_by:null});
    }
  }
  expect(complete).toBe(true);expect(pending).toBeGreaterThan(1);expect(maxProviders).toBeLessThanOrEqual(26);
  expect(await count('pa_sessions',f.session.ownerId)).toBe(sessions+1);
  expect(await db.prepare('SELECT state FROM pa_tool_metadata_batches WHERE owner_id=?').bind(f.session.ownerId).first()).toEqual({state:'open'});
  console.info('recovery-device-local',JSON.stringify({pending,maxProviders}));
},60_000);
