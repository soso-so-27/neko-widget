import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash,createPublicKey,verify} from 'node:crypto';
const out=readFileSync(0,'utf8'),lines=out.split('\n').filter(s=>s.startsWith('RECOVERY_FRESH_WIRE='));
assert.equal(lines.length,1);
const {body:b,challenge:c}=JSON.parse(lines[0].slice('RECOVERY_FRESH_WIRE='.length));
const raw=s=>Buffer.from(s,'base64url'),fields=values=>Buffer.concat(values.map(v=>{const b=Buffer.isBuffer(v)?v:Buffer.from(String(v));assert(b.length<=65535);const n=Buffer.alloc(2);n.writeUInt16BE(b.length);return Buffer.concat([n,b]);}));
const sha=b=>createHash('sha256').update(b).digest();
const valid=(key,sig,bytes)=>verify(null,bytes,createPublicKey({format:'der',type:'spki',key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),raw(key)])}),raw(sig));
const p=b.proof.claim,d=p.newDevice,r=b.packet.roster,e=b.envelopes[0];
assert.deepEqual(Object.keys(p).sort(),['version','environment','windowId','personId','participantId','recoveryGeneration','previousRevision','previousHash','nextHash','newDevice','replacedDeviceIds','operationId','challenge','issuedAt','expiresAt'].sort());
const claim=fields(['NW3.RECOVER_DEVICE.V1',p.environment,p.windowId,p.personId,p.participantId,p.recoveryGeneration,p.previousRevision,
 raw(p.previousHash),raw(p.nextHash),d.id,raw(d.signingPublicKey),raw(d.hpkePublicKey),raw(d.personAuthorization),p.replacedDeviceIds.length,
 ...p.replacedDeviceIds.sort(),p.operationId,raw(p.challenge),p.issuedAt,p.expiresAt]);
assert(valid(c.identity_public_key,b.proof.rootSignature,fields(['NW3.RECOVER_DEVICE.ROOT.V1',claim])));
assert(valid(d.signingPublicKey,b.proof.deviceSignature,fields(['NW3.RECOVER_DEVICE.DEVICE.V1',claim])));
const challenge=fields(['NW3.RECOVERY.CATALOG.V1',c.environment,c.purpose,c.id,c.person_id,raw(c.identity_public_key),c.operation_id,raw(c.nonce),c.issued_at,c.expires_at]);
const material=fields(['NW3.RECOVERY.FRESH-MATERIAL.V1',r.windowId,r.revision,r.keyEpoch,raw(r.previousHash),b.packet.signerDeviceId,raw(b.packet.signature),
 b.encryptedName,r.members[0].participantId,b.encryptedMemberNames[r.members[0].participantId],e.windowId,e.keyEpoch,e.rosterHash,e.deviceId,e.encapsulatedKey,e.ciphertext,e.signerDeviceId,e.signature]);
assert(valid(c.identity_public_key,b.consentSignature,fields(['NW3.RECOVERY.FRESH-CONSENT.V1',challenge,sha(material)])));
assert(!valid(c.identity_public_key,b.consentSignature,fields(['NW3.RECOVERY.FRESH-CONSENT.V1',challenge,sha(Buffer.concat([material,Buffer.from([1])]))])));
assert(out.includes('recovery client: PASS'));assert(out.includes('recovery adapter: PASS'));
const boundary=JSON.parse(out.split('\n').find(s=>s.startsWith('PARTICIPATION_WIRE=')).slice('PARTICIPATION_WIRE='.length));
const boundaryKey=out.split('\n').find(s=>s.startsWith('PARTICIPATION_KEY=')).slice('PARTICIPATION_KEY='.length);
const boundaryBytes=fields(['NW3.RECOVERY.PARTICIPATION.V1',boundary.environment,boundary.windowId,boundary.personId,
 boundary.participantId,boundary.admissionRevision,raw(boundary.rosterHash),boundary.signerDeviceId]);
assert(valid(boundaryKey,boundary.signature,boundaryBytes));
assert(!valid(boundaryKey,boundary.signature,fields(['NW3.RECOVERY.PARTICIPATION.V1','production',boundary.windowId,boundary.personId,
 boundary.participantId,boundary.admissionRevision,raw(boundary.rosterHash),boundary.signerDeviceId])));
console.log('recovery client, adapter and independent native proof/consent wire: PASS');
