import { describe, it, expect } from "vitest";
import { base64urlEncode, sha256Base64url } from "../src/encoding";
import { groupDeviceAuthorization, groupFields, groupRosterBytes, verifyGroupRoster, type GroupRosterDevice, type GroupRoster } from "../src/group-protocol";
import { groupRecoveryClaimBytes, groupRecoverySignatureBytes, validateGroupRecoveryProof, groupRecoveryIssuanceEnabled,
  type GroupRecoveryClaim, type GroupRecoveryLedger } from "../src/group-recovery-proof";
async function key() { const pair=await crypto.subtle.generateKey({name:"Ed25519"},true,["sign","verify"]) as CryptoKeyPair;
  return {secret:pair.privateKey,public:base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw",pair.publicKey)))}; }
const bytes=(n:number,size=32)=>base64urlEncode(new Uint8Array(size).fill(n));
const sign=async(k:CryptoKey,data:Uint8Array)=>base64urlEncode(new Uint8Array(await crypto.subtle.sign("Ed25519",k,data.slice().buffer)));
async function fixture(replace=false,count=1,memberRecovery=false) {
 const root=await key(),otherRoot=await key(),phone=await key(),newPhone=await key();
 async function device(id:string,person:string,k:Awaited<ReturnType<typeof key>>,r:Awaited<ReturnType<typeof key>>,hpke:number) {
  const d:GroupRosterDevice={id,signingPublicKey:k.public,hpkePublicKey:bytes(hpke),personAuthorization:""};
  d.personAuthorization=await sign(r.secret,groupDeviceAuthorization("room",person,d));return d;
 }
 const devices=[await device("old","owner",phone,root,1)];
 for(let i=1;i<count;i++)devices.push(await device("old"+i,"owner",await key(),root,i+10));
 const member={participantId:"p2",personId:"family",identityPublicKey:otherRoot.public,role:"member" as const,devices:[await device("family-phone","family",await key(),otherRoot,2)]};
 const old:GroupRoster={windowId:"room",revision:1,keyEpoch:1,previousHash:bytes(0),ownerPersonId:"owner",members:[{participantId:"p1",personId:"owner",identityPublicKey:root.public,role:"owner",devices},member]};
 const previous=await verifyGroupRoster({roster:old,signerDeviceId:"old",signature:await sign(phone.secret,groupFields(["NW3.ROSTER.SIGN",groupRosterBytes(old),"old"]))},{windowId:"room",ownerPersonId:"owner",ownerIdentityPublicKey:root.public});
 const targetRoot=memberRecovery?otherRoot:root, targetID=memberRecovery?"family":"owner", targetIndex=memberRecovery?1:0;
 const targetDevices=old.members[targetIndex]!.devices;
 const newDevice=await device("new",targetID,newPhone,targetRoot,3);
 const next:GroupRoster={...structuredClone(old),revision:2,keyEpoch:2,previousHash:previous.hash};next.members[targetIndex]!.devices=[...(replace?[]:targetDevices),newDevice];
 const claim:GroupRecoveryClaim={version:1,environment:"staging",windowId:"room",personId:targetID,participantId:old.members[targetIndex]!.participantId,recoveryGeneration:1,previousRevision:1,previousHash:previous.hash,nextHash:count===3&&!replace?bytes(0):await sha256Base64url(groupRosterBytes(next)),newDevice,replacedDeviceIds:replace?targetDevices.map(d=>d.id):[],operationId:"op1",challenge:bytes(7),issuedAt:1000,expiresAt:1300};
 const proof={claim,rootSignature:await sign(targetRoot.secret,groupRecoverySignatureBytes(claim,"root")),deviceSignature:await sign(newPhone.secret,groupRecoverySignatureBytes(claim,"device"))};
 const ledger:GroupRecoveryLedger={environment:"staging",windowId:"room",personId:targetID,participantId:old.members[targetIndex]!.participantId,identityPublicKey:targetRoot.public,revision:1,hash:previous.hash,recoveryGeneration:1,state:"active",newDeviceWasRevoked:false,challenge:{value:claim.challenge,operationId:"op1",issuedAt:1000,expiresAt:1300,consumed:false}};
 return {proof,previous,next,ledger,resign:async()=>{proof.rootSignature=await sign(targetRoot.secret,groupRecoverySignatureBytes(claim,"root"));proof.deviceSignature=await sign(newPhone.secret,groupRecoverySignatureBytes(claim,"device"));},check:()=>validateGroupRecoveryProof(proof,previous,next,ledger,1100)};
}
describe("root recovery P1: proof only, issuance disabled",()=>{
 it("accepts addition and explicit replacement without granting a roster capability",async()=>{for(const replace of [false,true]){const f=await fixture(replace);expect(await f.check()).toBeUndefined();}expect(groupRecoveryIssuanceEnabled).toBe(false);});
 it("accepts a member recovery without changing the owner",async()=>{const f=await fixture(false,1,true);expect(await f.check()).toBeUndefined();});
 it.each(["closed","deleted","left","removed","root-revoked"] as const)("rejects ledger state %s",async state=>{const f=await fixture();f.ledger.state=state;await expect(f.check()).rejects.toMatchObject({code:"stale_recovery_state"});});
 it("binds every trusted ledger input and rejects replay/revoked devices",async()=>{
  const mutations:((l:GroupRecoveryLedger)=>void)[]=[l=>{l.environment="production";},l=>{l.windowId="other";},l=>{l.personId="other";},l=>{l.participantId="other";},l=>{l.recoveryGeneration++;},l=>{l.revision++;},l=>{l.hash=bytes(9);},l=>{l.challenge.consumed=true;},l=>{l.newDeviceWasRevoked=true;},l=>{l.challenge.value=bytes(8);},l=>{l.challenge.operationId="other";},l=>{l.challenge.issuedAt--;},l=>{l.challenge.expiresAt++;}];
  for(const mutate of mutations){const f=await fixture();mutate(f.ledger);await expect(f.check()).rejects.toMatchObject({code:"stale_recovery_state"});}
 });
 it("rejects an untrusted root, forged root signature, and swapped signature purposes",async()=>{
  let f=await fixture();f.ledger.identityPublicKey=bytes(5);await expect(f.check()).rejects.toThrow();
  f=await fixture();f.proof.rootSignature=bytes(0,64);await expect(f.check()).rejects.toMatchObject({code:"invalid_signature"});
  f=await fixture();[f.proof.rootSignature,f.proof.deviceSignature]=[f.proof.deviceSignature,f.proof.rootSignature];await expect(f.check()).rejects.toMatchObject({code:"invalid_signature"});
 });
 it("requires a fresh bounded challenge and a supported exact format",async()=>{
  const f=await fixture();for(const now of [999,1300,NaN])await expect(validateGroupRecoveryProof(f.proof,f.previous,f.next,f.ledger,now)).rejects.toThrow();
  expect(()=>groupRecoveryClaimBytes({...f.proof.claim,expiresAt:1301})).toThrow();
  expect(()=>groupRecoveryClaimBytes({...f.proof.claim,version:2})).toThrowError(expect.objectContaining({code:"CLIENT_UPGRADE_REQUIRED",status:426}));
  expect(()=>groupRecoveryClaimBytes({...f.proof.claim,extra:true} as GroupRecoveryClaim)).toThrow();
 });
 it("rejects edits to another member, role, root, retained device, revision and key epoch",async()=>{
  const changes:((r:GroupRoster)=>void)[]=[r=>{r.members[1]!.participantId="other";},r=>{r.members[1]!.devices[0]!.hpkePublicKey=bytes(9);},r=>{r.members[0]!.identityPublicKey=bytes(9);},r=>{r.members[0]!.devices[0]!.personAuthorization=bytes(9,64);},r=>{r.revision=3;},r=>{r.keyEpoch=1;},r=>{r.ownerPersonId="family";}];
  for(const change of changes){const f=await fixture();change(f.next);try { f.proof.claim.nextHash=await sha256Base64url(groupRosterBytes(f.next)); } catch { f.proof.claim.nextHash=bytes(0); }await f.resign();await expect(f.check()).rejects.toThrow();}
 });
 it("enforces the three-device cap and prevents removing other people's devices",async()=>{
  await expect((await fixture(false,3)).check()).rejects.toThrow();const f=await fixture();f.proof.claim.replacedDeviceIds=["family-phone"];await expect(f.check()).rejects.toThrow();
 });
 it("canonicalizes binary fields and replacement order for Swift",async()=>{
  const c:GroupRecoveryClaim={version:1,environment:"staging",windowId:"room",personId:"owner",participantId:"p1",recoveryGeneration:1,previousRevision:1,previousHash:bytes(0),nextHash:bytes(1),newDevice:{id:"new",signingPublicKey:bytes(2),hpkePublicKey:bytes(3),personAuthorization:bytes(4,64)},replacedDeviceIds:["b","a"],operationId:"op1",challenge:bytes(5),issuedAt:1000,expiresAt:1300};
  expect(await sha256Base64url(groupRecoverySignatureBytes(c,"root"))).toBe("NV7JbqaSbEPsrqrsps4_VgJ-AY6aaUCuyqndzvzyLLo");
  expect(await sha256Base64url(groupRecoverySignatureBytes(c,"device"))).toBe("2LXPNN6swU0VJdJqFCAqCOJtTult4_VSTOZqLAGTqqs");
  expect(groupRecoveryClaimBytes(c)).toEqual(groupRecoveryClaimBytes({...c,replacedDeviceIds:["a","b"]}));
  expect(await sha256Base64url(groupRecoveryClaimBytes(c))).toBe("VLXwWfoFfKC_21jMxc1todZ3QSB-uH-mO-JVFb9YMrw");
 });
});
