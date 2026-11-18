import {describe, expect, it} from 'vitest';
import {base64urlDecode, base64urlEncode, randomBase64url, sha256, sha256Base64url} from '../src/encoding';
import {familyInvitationProof} from '../src/family-notebook-admission';
import {billingSignedRequestTranscript} from '../src/billing-protocol';
import {recoveryCatalogTranscript, type RecoveryChallenge} from '../src/group-recovery-catalog';
import {recoveryDeliveryState, type RecoveryPendingRow} from '../src/group-recovery-key-delivery';
import {route} from '../src/index';
import {ownerTrialRequest, type OwnerTrial} from '../src/owner-two-device-trial';
import {plusOwner, settings} from './group-billing-fixture';
import {cipher, create, db, key, member, ok, packet, person, send, sign, signed, type Person} from './group-fixture';
import type {Env} from '../src/env';

const familyRoot='/v3/family-notebooks', groupRoot='/v3/group-windows', recoveryRoot='/v3/group-recovery/';
const limiter={limit:async()=>({success:true})};

async function fixture() {
  const a=await plusOwner(), b=await person(), outside=await person(), recovery=await person(a.identity);
  const now=Date.now(), proof=randomBase64url(32), expiresAtMs=now+86_400_000;
  const bootstrapClientRequestId=crypto.randomUUID();
  const initialPublicKeySHA256=Array.from(await sha256(base64urlDecode(a.account.billingKey.publicKey,32)),
    byte=>byte.toString(16).padStart(2,'0')).join('');
  await db.prepare('INSERT INTO billing_account_bootstrap_requests(client_request_id,request_hash,billing_account_id,billing_key_id) VALUES(?,?,?,?)')
    .bind(bootstrapClientRequestId,randomBase64url(32),a.account.id,a.account.keyId).run();
  await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run();
  await db.prepare('UPDATE personal_staging_runtime_gate SET report_ingestion_enabled=0,generation=generation+1 WHERE singleton=1').run();
  const scope:OwnerTrial={proofHash:await sha256Base64url(base64urlDecode(proof,32)),family:crypto.randomUUID(),
    window:randomBase64url(16),aPerson:a.id,aDevice:a.deviceId,bPerson:b.id,bDevice:b.deviceId,
    recoveryDevice:recovery.deviceId,phase:'OFF',phaseUntilMs:0,expiresAtMs};
  const forwarded:string[]=[];
  const billingAdmission=JSON.stringify({version:1,bootstrapClientRequestId,initialPublicKeySHA256,
    startsAtMs:now-1000,expiresAtMs});
  const digest=Array.from(await sha256(new TextEncoder().encode(billingAdmission)),byte=>byte.toString(16).padStart(2,'0')).join('');
  const privateGateway={fetch:async(request:Request)=>{
    forwarded.push(new URL(request.url).pathname);
    return Response.json({status:'ok',protocolVersion:1},{headers:{'neko-runtime-billing-owner-admission':'READY',
      'neko-runtime-billing-owner-policy-sha256':digest,
      'neko-runtime-billing-transaction-ingestion':'ON','neko-runtime-billing-effective-entitlement':'ON'}});
  }} as Fetcher;
  const unscoped:Env={...settings,ENVIRONMENT:'staging',BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'NO',
    BILLING_SANDBOX_OWNER_ADMISSION:billingAdmission,PRIVATE_BILLING_GATEWAY:privateGateway,
    MEMBER_RATE_LIMITER:limiter,CREATE_RATE_LIMITER:limiter,INVITE_RATE_LIMITER:limiter,BILLING_RATE_LIMITER:limiter,
    FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'YES',
    FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED:'NO',GROUP_REPORT_RUNTIME_ENABLED:'NO',
    GROUP_MODERATION_RUNTIME_ENABLED:'YES',GROUP_REPORT_EMAIL_ENABLED:'NO',GROUP_RECOVERY_CATALOG_ENABLED:'NO'};
  const env=(phase:OwnerTrial['phase'], changes:Partial<OwnerTrial>={}):Env=>({...unscoped,
    OWNER_TWO_DEVICE_TRIAL:JSON.stringify({...scope,phase,phaseUntilMs:phase==='OFF'?0:now+120_000,...changes})});
  function mark(request:Request,credential:string|null=proof) {
    const headers=new Headers(request.headers);
    if(credential!==null)headers.set('neko-owner-trial-proof',credential);
    return new Request(request,{headers});
  }
  const call=async(p:Person,path:string,phase:OwnerTrial['phase'],body?:unknown,credential:string|null=proof)=>
    send(mark(await signed(p,path,body),credential),env(phase));
  return {a,b,outside,recovery,scope,env,call,mark,forwarded,unscoped};
}

describe('owner-only staging trial',()=>{
  it('reports readiness while closed and sends only proved transaction/entitlement calls to the private verifier',async()=>{
    const f=await fixture(),path='/v1/billing/entitlement';
    const req=(path:string)=>new Request('https://group.invalid'+path);
    const response=await ownerTrialRequest(req('/v1/billing/health'),f.env('OFF'));
    expect(response instanceof Response&&response.headers.get('neko-owner-two-device-readiness')).toBe('READY');
    expect(response instanceof Response&&response.headers.get('neko-owner-two-device-feature-gates')).toBe('OFF');
    await expect(ownerTrialRequest(req(path),f.env('OFF'))).rejects.toMatchObject({status:404});
    await expect(ownerTrialRequest(f.mark(req(path),randomBase64url(32)),f.env('OFF'))).rejects.toMatchObject({status:404});
    await expect(ownerTrialRequest(f.mark(req(path)),f.env('OFF',{expiresAtMs:Date.now()-1}))).rejects.toMatchObject({status:404});
    await expect(ownerTrialRequest(f.mark(req(path)),{...f.env('OFF'),ENVIRONMENT:'production'})).rejects.toMatchObject({status:404});
    await expect(ownerTrialRequest(f.mark(req('/v1/billing/accounts/recover')),f.env('OFF'))).rejects.toMatchObject({status:404});
    await expect(ownerTrialRequest(f.mark(req(path)),f.env('OFF'))).rejects.toMatchObject({status:401});
    const {id:billingAccountId,keyId:billingKeyId,billingKey}=f.a.account;
    const timestamp=Math.floor(Date.now()/1000),nonce=randomBase64url(16);
    const signature=await sign(billingKey.privateKey,billingSignedRequestTranscript({billingAccountId,billingKeyId,timestamp,nonce,
      method:'GET',pathname:path,bodySHA256:await sha256Base64url(new Uint8Array())}));
    const signed=new Request(req(path),{headers:{'neko-billing-protocol-version':'1','neko-billing-account-id':billingAccountId,
      'neko-billing-key-id':billingKeyId,'neko-billing-timestamp':String(timestamp),'neko-billing-nonce':nonce,'neko-billing-signature':signature}});
    expect(await ownerTrialRequest(f.mark(signed),f.env('OFF'))).toBeInstanceOf(Response);
    expect(f.forwarded).toEqual(['/v1/billing/health',path]);
    expect(f.unscoped.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED).toBe('NO');
  });

  it('creates the one notebook, admits B, and rejects other purposes or registered devices',async()=>{
    const f=await fixture(), {a,b,outside,scope,call}=f, root=familyRoot+'/'+scope.family;
    const creation={operationId:crypto.randomUUID(),familyId:scope.family};
    expect((await call(a,familyRoot,'OFF',creation)).status).toBe(404);
    expect((await call(a,familyRoot,'PREPARE',creation,null)).status).toBe(404);
    expect((await call(b,familyRoot,'PREPARE',creation)).status).toBe(404);
    expect((await call(a,familyRoot,'PREPARE',{...creation,familyId:crypto.randomUUID()})).status).toBe(404);
    ok(await call(a,familyRoot,'PREPARE',creation));
    const proof=await key(), id=crypto.randomUUID(), joinId=crypto.randomUUID();
    ok(await call(a,root+'/invitations','PREPARE',{operationId:id,expectedGeneration:1,
      proofPublicKey:proof.publicKey,encryptedPreview:cipher()}));
    const join=async(p:Person)=>call(p,root+'/invitations/'+id+'/join','PREPARE',{operationId:joinId,expectedGeneration:1,
      encryptedDisplayName:cipher(),proofSignature:await sign(proof.privateKey,
        familyInvitationProof(scope.family,id,p.id,p.deviceId,'join',joinId))});
    expect((await join(outside)).status).toBe(404);
    ok(await join(b));
    ok(await call(a,root+'/requests/'+joinId+'/approve','PREPARE',{operationId:crypto.randomUUID(),expectedGeneration:1}));
    expect(ok(await call(b,root+'/members','PREPARE')).members.map((m:{personId:string})=>m.personId).sort()).toEqual([a.id,b.id].sort());
    const photo=root+'/representative-photos';
    expect((await call(b,photo+'/slots','PREPARE')).status).toBe(404);
    expect((await call(outside,photo+'/slots','PHOTO')).status).toBe(404);
    expect((await call(b,photo+'/slots','PHOTO',undefined,null)).status).toBe(404);
    expect((await call(b,familyRoot+'/'+crypto.randomUUID()+'/representative-photos/slots','PHOTO')).status).toBe(404);
    expect((await call(a,photo+'/reports','REPORT',{})).status).toBe(503);
    expect((await call(b,photo+'/reports','PHOTO',{})).status).toBe(404);
    const report = await call(b,photo+'/reports','REPORT',{});
    expect(report.status).toBe(400);
    expect((await db.prepare('SELECT report_ingestion_enabled FROM personal_staging_runtime_gate WHERE singleton=1').first())?.report_ingestion_enabled).toBe(0);
  });

  it('only discovers the new window and binds key delivery to its approved root and recovery device',async()=>{
    const f=await fixture(), {a,b,outside,recovery,scope,call,env}=f;
    const neighbor=await create(a,201,'',settings);
    const roster={windowId:scope.window,revision:1,keyEpoch:1,previousHash:base64urlEncode(new Uint8Array(32)),
      ownerPersonId:a.id,members:[await member(a,scope.window,'owner')]};
    const {hash:_,...wire}=await packet(a,roster);
    const creation={operationId:crypto.randomUUID(),...wire};
    expect((await call(a,groupRoot,'RECOVERY',creation,null)).status).toBe(404);
    ok(await call(a,groupRoot,'RECOVERY',creation),201);
    const listing=ok(await call(a,groupRoot+'/list','RECOVERY',{after:null,limit:20}));
    expect(listing.items.map((x:{windowId:string})=>x.windowId)).toEqual([scope.window]);
    const catalog=async(p:Person)=>{
      const request=(action:string,body:unknown)=>f.mark(new Request('https://group.invalid'+recoveryRoot+action,
        {method:'POST',body:JSON.stringify(body),headers:{'content-type':'application/json'}}));
      const stage=env('RECOVERY');
      const issued=await route(request('challenges',{identityPublicKey:p.identity.publicKey,
        operationId:crypto.randomUUID(),purpose:'catalog'}),stage);
      const {challenge}=await issued.json() as {challenge:RecoveryChallenge};
      return route(request('catalog',{challengeId:challenge.id,rootSignature:await sign(p.identity.privateKey,
        recoveryCatalogTranscript(challenge))}),stage);
    };
    await expect(catalog(outside)).rejects.toMatchObject({status:404});
    const body=await (await catalog(a)).json() as {windows:{windowId:string}[];notebooks:unknown[];devices:{deviceId:string}[]};
    expect(body.windows.map(x=>x.windowId)).toEqual([scope.window]);
    expect(body.notebooks).toEqual([]);
    expect(body.devices.map(x=>x.deviceId).sort()).toEqual([a.deviceId,recovery.deviceId].sort());
    expect((await call(a,groupRoot+'/'+neighbor.windowId+'/recovery/pending','RECOVERY',{})).status).toBe(404);
    expect((await call(b,groupRoot+'/'+scope.window+'/recovery/pending','RECOVERY',{})).status).toBe(404);
    const scoped=await ownerTrialRequest(f.mark(await signed(a,groupRoot+'/'+scope.window+'/recovery/pending',{})),env('RECOVERY')) as Env;
    const pending:RecoveryPendingRow={window_id:scope.window,person_id:a.id,device_id:recovery.deviceId,
      operation_id:crypto.randomUUID(),signing_public_key:recovery.signing.publicKey,
      hpke_public_key:recovery.hpke,model:'test',proof_json:'invalid deliberately'};
    // Wrong subjects must be rejected before any stored proof is decoded.
    for(const override of [{window_id:neighbor.windowId},{person_id:b.id},{device_id:outside.deviceId}]) {
      await expect(recoveryDeliveryState(scoped,{...pending,...override},null!)).rejects.toMatchObject({status:404});
    }
  });
});
