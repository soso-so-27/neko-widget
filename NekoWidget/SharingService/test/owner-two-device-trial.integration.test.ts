import {describe, expect, it} from 'vitest';
import {base64urlDecode, base64urlEncode, randomBase64url, sha256, sha256Base64url} from '../src/encoding';
import {familyInvitationProof} from '../src/family-notebook-admission';
import {billingSignedRequestTranscript} from '../src/billing-protocol';
import {recoveryCatalogTranscript, type RecoveryChallenge} from '../src/group-recovery-catalog';
import {recoveryDeliveryState, type RecoveryPendingRow} from '../src/group-recovery-key-delivery';
import {route} from '../src/index';
import {ownerTrialFamilyPushEnvironment, ownerTrialRequest, type OwnerTrial} from '../src/owner-two-device-trial';
import {billing, plusOwner, settings} from './group-billing-fixture';
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
    expect(request.headers.has('neko-owner-trial-proof')).toBe(false);
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
  it('opens family push only in the verified recovery scope',async()=>{
    const f=await fixture(), path=`${familyRoot}/${f.scope.family}/push-subscription`;
    const req=()=>new Request('https://group.invalid'+path,{method:'POST'});
    for(const phase of ['OFF','PREPARE','PHOTO','REPORT'] as const) {
      expect(await ownerTrialFamilyPushEnvironment(f.env(phase))).toBeUndefined();
    }
    expect(await ownerTrialFamilyPushEnvironment(f.env('RECOVERY',{phaseUntilMs:Date.now()-1}))).toBeUndefined();
    expect(await ownerTrialFamilyPushEnvironment({...f.env('RECOVERY'),ENVIRONMENT:'production'})).toBeUndefined();
    const cron=await ownerTrialFamilyPushEnvironment(f.env('RECOVERY'));
    expect(cron).toMatchObject({FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:'YES',
      BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES',ownerTrial:{family:f.scope.family,recoveryDevice:f.recovery.deviceId}});
    expect(await ownerTrialRequest(f.mark(req()),f.env('RECOVERY'))).toMatchObject({FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:'YES'});
    await expect(ownerTrialRequest(req(),f.env('RECOVERY'))).rejects.toMatchObject({status:404});
    expect(f.unscoped.FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED).not.toBe('YES');
  });

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
    const billingRequest=async({id:billingAccountId,keyId:billingKeyId,billingKey}:Awaited<ReturnType<typeof billing>>)=>{
      const timestamp=Math.floor(Date.now()/1000),nonce=randomBase64url(16);
      const signature=await sign(billingKey.privateKey,billingSignedRequestTranscript({billingAccountId,billingKeyId,timestamp,nonce,
        method:'GET',pathname:path,bodySHA256:await sha256Base64url(new Uint8Array())}));
      return f.mark(new Request(req(path),{headers:{'neko-billing-protocol-version':'1','neko-billing-account-id':billingAccountId,
        'neko-billing-key-id':billingKeyId,'neko-billing-timestamp':String(timestamp),'neko-billing-nonce':nonce,'neko-billing-signature':signature}}));
    };
    await expect(ownerTrialRequest(await billingRequest(await billing()),f.env('OFF'))).rejects.toMatchObject({status:403});
    expect(await ownerTrialRequest(await billingRequest(f.a.account),f.env('OFF'))).toBeInstanceOf(Response);
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
    const end=scope.expiresAtMs, longPhoto=f.env('PHOTO',{phaseUntilMs:end,recoveryDevice:null});
    const scopedRead=async(p:Person,path:string,stage=longPhoto)=>send(f.mark(await signed(p,path)),stage);
    expect(ok(await scopedRead(a,familyRoot+'/me')).family.familyId).toBe(scope.family);
    expect((await scopedRead(a,photo+'/slots')).status).toBe(200);
    expect((await scopedRead(b,photo+'/slots')).status).toBe(200);
    expect((await scopedRead(outside,photo+'/slots')).status).toBe(404);
    expect((await scopedRead(f.recovery,photo+'/slots')).status).toBe(404);
    expect((await scopedRead(b,familyRoot+'/'+crypto.randomUUID()+'/representative-photos/slots')).status).toBe(404);
    expect((await send(f.mark(await signed(b,photo+'/reports',{})),longPhoto)).status).toBe(404);
    expect((await scopedRead(b,recoveryRoot+'catalog')).status).toBe(404);
    for(const stage of [f.env('PHOTO',{phaseUntilMs:end}),f.env('PHOTO',{phaseUntilMs:end-1,recoveryDevice:null}),
      f.env('PREPARE',{phaseUntilMs:end}),f.env('REPORT',{phaseUntilMs:end}),f.env('RECOVERY',{phaseUntilMs:end})]) {
      expect((await scopedRead(a,familyRoot+'/me',stage)).status).toBe(503);
    }
    expect((await scopedRead(a,familyRoot+'/me',f.env('PHOTO',{phaseUntilMs:end+1,recoveryDevice:null}))).status).toBe(404);
    expect((await scopedRead(a,familyRoot+'/me',f.env('PHOTO',{
      phaseUntilMs:Date.now()-1,expiresAtMs:Date.now()-1,recoveryDevice:null,
    }))).status).toBe(404);
    const unlisted=await person(a.identity);
    for(const device of [a,b,f.recovery]) expect((await call(device,photo+'/slots','RECOVERY')).status).toBe(200);
    expect((await call(unlisted,photo+'/slots','RECOVERY')).status).toBe(404);
    expect((await call(outside,photo+'/slots','RECOVERY')).status).toBe(404);
    expect((await call(f.recovery,photo+'/slots','RECOVERY',undefined,null)).status).toBe(404);
    expect((await call(f.recovery,familyRoot+'/'+crypto.randomUUID()+'/representative-photos/slots','RECOVERY')).status).toBe(404);
    const readAsset=crypto.randomUUID(),slot=crypto.randomUUID(),sample=new Uint8Array(100).fill(9);
    const digest=await sha256Base64url(sample),objectKey='family/owner-trial-test/'+readAsset;
    await f.unscoped.MEDIA!.put(objectKey,sample);
    await db.batch([
      db.prepare("INSERT INTO family_representative_slots VALUES(?,?,0,NULL,'active')").bind(scope.family,slot),
      db.prepare(`INSERT INTO family_representative_assets VALUES(?,?,?,?,?,?,1,1,?,?,?,?,'active',unixepoch(),unixepoch()+600,?)`)
        .bind(readAsset,scope.family,slot,crypto.randomUUID(),a.id,a.deviceId,digest,objectKey,sample.length,digest,digest),
      db.prepare('UPDATE family_representative_slots SET revision=1,asset_id=? WHERE family_id=? AND slot_id=?').bind(readAsset,scope.family,slot),
    ]);
    const assetPath=photo+'/assets/'+readAsset;
    expect(ok(await call(f.recovery,assetPath+'/status','RECOVERY')).available).toBe(true);
    const download=await route(f.mark(await signed(f.recovery,assetPath)),f.env('RECOVERY'));
    expect(download.status).toBe(200);
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(sample);
    expect((await call(unlisted,assetPath,'RECOVERY')).status).toBe(404);
    expect((await call(a,photo+'/uploads','RECOVERY',{})).status).toBe(404);
    expect((await call(b,photo+'/reports','RECOVERY',{})).status).toBe(404);
    expect((await call(a,root+'/crypto/operations','RECOVERY',{operationId:crypto.randomUUID(),expectedGeneration:2,
      expectedEpoch:0,payload:{},writeContract:{version:1,effects:[{kind:'clearPhoto',slotId:crypto.randomUUID()}]}})).status).toBe(404);
    const identity=async(path:string,body:unknown)=>send(f.mark(new Request('https://group.invalid/v3/group-identities'+path,
      {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})),f.env('RECOVERY'));
    expect((await identity('/challenges',{purpose:'register',signingPublicKey:unlisted.signing.publicKey,hpkePublicKey:unlisted.hpke})).status).toBe(404);
    expect((await identity('',unlisted.registration)).status).toBe(404);
    expect((await identity('',{...f.recovery.registration,personPublicKey:outside.identity.publicKey})).status).toBe(404);
    expect((await identity('',f.recovery.registration)).status).toBe(200);
    expect((await call(a,photo+'/reports','REPORT',{})).status).toBe(503);
    expect((await call(b,photo+'/reports','PHOTO',{})).status).toBe(404);
    const asset=crypto.randomUUID(),bytes=new Uint8Array(100).fill(7);
    await db.prepare('INSERT INTO family_photo_report_deliveries VALUES (?,?,?,?,?,unixepoch()+604800)')
      .bind(scope.family,asset,b.id,b.deviceId,a.id).run();
    // The iPhone's Foundation UUIDs are uppercase in the signed JSON body.
    const report=ok(await call(b,photo+'/reports','REPORT',{schemaVersion:1,operationId:crypto.randomUUID().toUpperCase(),assetId:asset.toUpperCase(),
      reasonCode:'privacy',moderationKeyId:'moderation-v2',ciphertext:base64urlEncode(bytes),
      ciphertextSHA256:await sha256Base64url(bytes),consentedAt:Math.floor(Date.now()/1000)}));
    expect(report).toMatchObject({familyId:scope.family,state:'committed'});
    expect(ok(await call(b,familyRoot+'/report-replies','REPORT')).replies).toHaveLength(1);
    expect((await call(outside,familyRoot+'/report-replies','REPORT')).status).toBe(404);
    expect((await db.prepare('SELECT report_ingestion_enabled FROM personal_staging_runtime_gate WHERE singleton=1').first())?.report_ingestion_enabled).toBe(0);
  });

  it('does not tell an enrolled device that it left the notebook when the trial closes',async()=>{
    const f=await fixture(), path=familyRoot+'/me';
    ok(await f.call(f.a,familyRoot,'PREPARE',{operationId:crypto.randomUUID(),familyId:f.scope.family}));
    expect(ok(await f.call(f.a,path,'PHOTO')).family.familyId).toBe(f.scope.family);

    const closed=await f.call(f.a,path,'OFF');
    expect({status:closed.status,family:closed.data.family}).toEqual({status:503,family:undefined});
    const expired=await send(f.mark(await signed(f.a,path)),f.env('PHOTO',{phaseUntilMs:Date.now()-1}));
    expect(expired.status).toBe(503);
    expect(ok(await f.call(f.a,path,'OFF',undefined,null)).family).toBeNull();
    expect(ok(await f.call(f.a,path,'PHOTO')).family.familyId).toBe(f.scope.family);
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
    ok(await call(a,familyRoot,'PREPARE',{operationId:crypto.randomUUID(),familyId:scope.family}));
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
    expect(body.notebooks).toEqual([{familyId:scope.family}]);
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
