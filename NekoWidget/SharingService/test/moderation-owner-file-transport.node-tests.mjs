import {test} from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {createOwnerFileTransport,validateOwnerFileTransport} from '../scripts/moderation-owner-file-transport.mjs';
const config=()=>({schemaVersion:1,kind:'synthetic-local',entries:[{caseReferenceHmac:'a'.repeat(64),caseReferenceHmacKeyVersion:1,sourceSHA256:'b'.repeat(64),ciphertextFile:path.resolve('not-read/synthetic-report.ciphertext'),ciphertextSize:500,moderationKeyId:'moderation-v2',keyDirectory:path.resolve('not-read/keys'),expectedPublicKeySHA256:'c'.repeat(64)}]});
test('only one synthetic source is allowed, and administrative configuration is snapshotted',()=>{
  const c=config(),v=validateOwnerFileTransport(c);c.entries[0].sourceSHA256='d'.repeat(64);assert.equal(v.entries[0].sourceSHA256,'b'.repeat(64));
  for(const change of [c=>c.kind='live',c=>c.entries.push(c.entries[0]),c=>c.entries[0].moderationKeyId='moderation-v1',c=>c.entries[0].caseReferenceHmacKeyVersion=2,c=>c.entries[0].keyDirectory='relative',c=>c.entries[0].ciphertextSize=1048577,c=>c.endpoint='https://other.invalid']){
    const invalid=config();change(invalid);assert.throws(()=>validateOwnerFileTransport(invalid),{message:'owner_review_unavailable'});
  }
});
test('an unbound source is refused before opening any files or writing disclosure audit',async()=>{
  let audits=0;await assert.rejects(createOwnerFileTransport(config())({source:{caseReferenceHmac:'d'.repeat(64)},signal:new AbortController().signal,audit(){audits++}}),{message:'owner_review_unavailable'});assert.equal(audits,0);
});
