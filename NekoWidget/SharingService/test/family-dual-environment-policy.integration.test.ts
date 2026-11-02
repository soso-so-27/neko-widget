import {describe,expect,it} from 'vitest';
import type {Env} from '../src/env';
import {familyInvitationProof} from '../src/family-notebook-admission';
import {familyRosterBytes,verifyFamilyRoster,type FamilyCryptoMember,type VerifiedFamilyCryptoRoster} from '../src/family-notebook-crypto';
import {groupDeviceAuthorization,groupFields} from '../src/group-protocol';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {authority,billing,connection,gates,pauseOwner,plusOwner,settings} from './group-billing-fixture';
import {cipher,db,key,ok,person,send,sign,signed,type Person} from './group-fixture';

const limiter:RateLimit={limit:async()=>({success:true})};
const dual:Env={...settings,ENVIRONMENT:'production',BILLING_STORE_ENVIRONMENT:'Production',BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'YES',
  FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES',
  CREATE_RATE_LIMITER:limiter,MEMBER_RATE_LIMITER:limiter,INVITE_RATE_LIMITER:limiter,BILLING_RATE_LIMITER:limiter};
const single:Env={...dual,BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'NO'};
const root='/v3/family-notebooks';
function body(generation:number,extra:object={}) {return {operationId:crypto.randomUUID(),expectedGeneration:generation,...extra};}
async function call(p:Person,path:string,value?:unknown,env:Env=dual) {return send(await signed(p,path,value),env);}
async function create(p:Person,env:Env=dual) {
  await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run();
  const id=crypto.randomUUID();ok(await call(p,root,{operationId:crypto.randomUUID(),familyId:id},env));return id;
}
async function admit(a:Person,b:Person,family:string,generation=1) {
  const proof=await key(),invite=body(generation,{proofPublicKey:proof.publicKey,encryptedPreview:cipher()});
  ok(await call(a,`${root}/${family}/invitations`,invite));
  const join=body(generation);
  ok(await call(b,`${root}/${family}/invitations/${invite.operationId}/join`,{...join,encryptedDisplayName:cipher(),
    proofSignature:await sign(proof.privateKey,familyInvitationProof(family,invite.operationId,b.id,b.deviceId,'join',join.operationId))}));
  ok(await call(a,`${root}/${family}/requests/${join.operationId}/approve`,body(generation)));
}
async function register(p:Person,family:string,generation:number,epoch:number):Promise<FamilyCryptoMember> {
  const device={id:p.deviceId,signingPublicKey:p.signing.publicKey,hpkePublicKey:p.hpke,personAuthorization:''};
  device.personAuthorization=await sign(p.identity.privateKey,groupDeviceAuthorization(family,p.id,device));
  ok(await call(p,`${root}/${family}/crypto/devices`,{...body(generation),expectedEpoch:epoch,payload:{personAuthorization:device.personAuthorization}}));
  return {personId:p.id,identityPublicKey:p.identity.publicKey,devices:[device]};
}
async function roster(p:Person,family:string,members:FamilyCryptoMember[],generation:number,previous?:VerifiedFamilyCryptoRoster) {
  const value={familyId:family.toUpperCase(),epoch:(previous?.packet.roster.epoch??0)+1,
    previousHash:previous?.hash??'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',keyCommitment:randomBase64url(32),members};
  const packet={roster:value,signerDeviceId:p.deviceId,
    signature:await sign(p.signing.privateKey,groupFields(['FNB1.ROSTER.SIGN',familyRosterBytes(value),p.deviceId]))};
  const verified=await verifyFamilyRoster(packet,previous);
  ok(await call(p,`${root}/${family}/crypto/rosters`,{...body(generation),expectedEpoch:value.epoch-1,payload:packet}));
  return verified;
}
async function operation(p:Person,r:VerifiedFamilyCryptoRoster,generation:number,env:Env=dual) {
  const packet={familyId:r.packet.roster.familyId,keyEpoch:r.packet.roster.epoch,rosterHash:r.hash,
    operationId:crypto.randomUUID(),personId:p.id,deviceId:p.deviceId,ciphertext:randomBase64url(48),signature:''};
  const aad=groupFields(['FNB1.OPERATION',packet.familyId.toLowerCase(),String(packet.keyEpoch),base64urlDecode(r.hash,32),
    packet.operationId,p.id,p.deviceId,'48']);
  packet.signature=await sign(p.signing.privateKey,groupFields(['FNB1.OPERATION.SIGN',aad,
    base64urlDecode(await sha256Base64url(base64urlDecode(packet.ciphertext)),32)]));
  return call(p,`${root}/${packet.familyId.toLowerCase()}/crypto/operations`,
    {operationId:packet.operationId,expectedGeneration:generation,expectedEpoch:packet.keyEpoch,payload:packet},env);
}
function beforeCommit(action:()=>Promise<void>,env:Env=dual):Env {
  let pending=true;
  return {...env,DB:new Proxy(db,{get(target,property) {
    if(property==='batch')return async(statements:D1PreparedStatement[])=>{
      if(pending){pending=false;await action();}return target.batch(statements);
    };
    const value=Reflect.get(target,property);return typeof value==='function'?value.bind(target):value;
  }})};
}

describe('explicit dual-environment family notebook policy',()=>{
  it('creates, admits, preserves encrypted history and resumes with the remaining Sandbox Plus member after payer departure',async()=>{
    const a=await plusOwner(),b=await plusOwner(),f=await create(a);
    const ma=await register(a,f,1,0),r1=await roster(a,f,[ma],1);ok(await operation(a,r1,1));
    await admit(a,b,f);const mb=await register(b,f,2,1),r2=await roster(a,f,[ma,mb],2,r1);
    ok(await operation(b,r2,2));
    expect(ok(await call(b,`${root}/${f}/payer`))).toMatchObject({sharingStatus:'active',payerPersonId:a.id,canClaimPayer:false});
    ok(await call(a,`${root}/${f}/leave`,body(2)));
    expect(ok(await call(b,`${root}/${f}/payer`))).toMatchObject({sharingStatus:'paused',pauseReason:'no_payer',canClaimPayer:true});
    ok(await call(b,`${root}/${f}/payer/claim`,body(3)));
    expect(ok(await call(b,`${root}/${f}/payer`))).toMatchObject({sharingStatus:'active',payerPersonId:b.id,role:'payer'});
    expect((await call(a,`${root}/${f}/crypto/operations/0`)).status).toBe(404);
    const r3=await roster(b,f,[mb],4,r2);ok(await operation(b,r3,4));
    expect(ok(await call(b,`${root}/${f}/crypto/operations/0`)).operations).toHaveLength(3);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_environment_checks').first())?.n).toBe(0);
    expect((await db.prepare("SELECT accept_sandbox_in_production permission FROM family_notebook_payer_events WHERE operation='claim'").first())?.permission).toBe(1);
  });

  it('accepts a nominated Sandbox payer, rechecking verified Plus at the commit boundary',async()=>{
    const a=await plusOwner(),b=await plusOwner(),f=await create(a);await admit(a,b,f);
    const nomination=body(2,{personId:b.id});ok(await call(a,`${root}/${f}/payer/nominate`,nomination));
    expect(ok(await call(b,`${root}/${f}/payer/handover`))).toMatchObject({canAccept:true});
    const accept=body(3,{nominationId:nomination.operationId});
    expect((await call(b,`${root}/${f}/payer/accept`,accept,beforeCommit(()=>pauseOwner(b)))).data.error.code).toBe('plus_entitlement_required');
    expect(ok(await call(a,`${root}/${f}/payer`)).payerPersonId).toBe(a.id);
    await b.verified.refresh();ok(await call(b,`${root}/${f}/payer/accept`,accept));
    expect(ok(await call(a,`${root}/${f}/payer`))).toMatchObject({payerPersonId:b.id,sharingStatus:'active'});
  });

  it('keeps Production authority and writes active when equal-ID Sandbox is revoked, including after dual OFF',async()=>{
    const a=await person(),account=await billing();const prod=await authority(account,'PURCHASED',Date.now(),'Production');
    const sandbox=await authority(account,'PURCHASED',Date.now(),'Sandbox',prod.transaction.originalTransactionId);
    ok(await send((await connection(a,account)).request,dual));
    const f=await create(a),member=await register(a,f,1,0),r=await roster(a,f,[member],1);
    await sandbox.refresh({revocationDateMs:Date.now(),revocationReason:1},5);
    for(const env of [dual,single]) {
      expect(ok(await call(a,`${root}/${f}/payer`,undefined,env))).toMatchObject({sharingStatus:'active',payerPersonId:a.id});
      ok(await operation(a,r,1,env));
      ok(await call(a,`${root}/${f}/invitations`,body(1,{proofPublicKey:(await key()).publicKey,encryptedPreview:cipher()}),env));
    }
    expect((await db.prepare("SELECT materialized_grants_plus FROM billing_effective_entitlement_current WHERE environment='Production' AND original_transaction_id=?")
      .bind(prod.transaction.originalTransactionId).first())?.materialized_grants_plus).toBe(1);
  });

  it('fails closed for unknown/OFF/inconsistent owner contexts but retains current-member reading and departure',async()=>{
    const a=await plusOwner(),b=await plusOwner(),f=await create(a);
    const member=await register(a,f,1,0),r=await roster(a,f,[member],1);
    const absent:Env={...dual};delete absent.BILLING_ACCEPT_SANDBOX_IN_PRODUCTION;
    const invalid:Env[]=[single,absent,{...dual,BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'yes'},
      {...dual,BILLING_STORE_ENVIRONMENT:'Unknown'},{...dual,BILLING_STORE_ENVIRONMENT:'Sandbox'},
      {...dual,BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES'},{...dual,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'NO'}];
    for(const env of invalid) {
      expect(ok(await call(a,`${root}/${f}/payer`,undefined,env))).toMatchObject({sharingStatus:'paused',payerPersonId:a.id,canClaimPayer:false});
      expect((await call(b,root,{operationId:crypto.randomUUID(),familyId:crypto.randomUUID()},env)).status).not.toBe(200);
      expect((await operation(a,r,1,env)).data.error.code).toBe('family_notebook_paused');
      expect((await call(a,`${root}/${f}/invitations`,body(1,{proofPublicKey:(await key()).publicKey,encryptedPreview:cipher()}),env)).status).not.toBe(200);
    }
    expect(ok(await call(a,`${root}/${f}/payer`,undefined,{...dual,ENVIRONMENT:'local',BILLING_STORE_ENVIRONMENT:'Sandbox',
      BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'NO',BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES'}))).toMatchObject({sharingStatus:'active'});
    await admit(a,b,f);ok(await call(a,`${root}/${f}/leave`,body(2),single));
    expect(ok(await call(b,`${root}/${f}/payer`,undefined,single))).toMatchObject({pauseReason:'no_payer',canClaimPayer:false});
    expect((await call(b,`${root}/${f}/payer/claim`,body(3),single)).data.error.code).toBe('plus_entitlement_required');
    ok(await call(b,`${root}/${f}/payer/claim`,body(3)));
  });

  it('retains API/transaction gates and rechecks lower billing gate before an encrypted append commits',async()=>{
    const a=await plusOwner(),f=await create(a),member=await register(a,f,1,0),r=await roster(a,f,[member],1);
    expect((await call(a,`${root}/${f}/payer`,undefined,{...dual,FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'NO'})).status).toBe(404);
    expect((await call(a,`${root}/${f}/payer`,undefined,{...dual,FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'NO'})).status).toBe(503);
    expect((await operation(a,r,1,beforeCommit(()=>gates(0)))).data.error.code).toBe('family_notebook_paused');
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_operations WHERE family_id=?').bind(f).first())?.n).toBe(0);
    expect((await db.prepare('SELECT COUNT(*) n FROM family_notebook_crypto_receipts WHERE family_id=?').bind(f).first())?.n).toBe(2); // device + roster only
    await gates();await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=0,generation=generation+1 WHERE singleton=1').run();
    expect((await call(a,`${root}/${f}/payer`)).status).toBe(503);
  });

  it('rejects malformed dual SQL contexts and refuses Family Sharing/expired/revoked authority without granting ownership',async()=>{
    const a=await plusOwner(),f=await create(a);
    for(const [environment,allow] of [['Sandbox',1],['Unknown',1],[null,1],['Production',2]] as const) {
      await expect(db.prepare('INSERT INTO family_notebook_crypto_environment_checks VALUES(?,?,?,?,?,?,?,?,?)')
        .bind(crypto.randomUUID(),f,a.id,a.deviceId,1,null,'read',environment,allow).run()).rejects.toThrow('CHECK constraint failed');
    }
    const shared=await plusOwner('FAMILY_SHARED'),expired=await plusOwner(),revoked=await plusOwner();
    await expired.verified.refresh({expiresDateMs:Date.now()-1});await pauseOwner(revoked);
    for(const owner of [shared,expired,revoked]) {
      expect((await call(owner,root,{operationId:crypto.randomUUID(),familyId:crypto.randomUUID()})).data.error.code).toBe('plus_entitlement_required');
    }
    await pauseOwner(a);
    expect(ok(await call(a,`${root}/${f}/payer`))).toMatchObject({sharingStatus:'paused',payerPersonId:a.id,canClaimPayer:false});
  });
});
