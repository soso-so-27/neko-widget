import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createFamilyPhotoModerationFixture,SYNTHETIC_CANONICAL_JPEG} from './fixtures/family-photo-moderation.mjs';
import {decryptFamilyPhotoModerationReport} from '../scripts/family-photo-moderation-report-lib.mjs';
import {decryptGroupModerationReport} from '../scripts/group-moderation-report-lib.mjs';
import {familyPhotoModerationReviewSourceBinding,withBoundFamilyPhotoModerationReview} from '../scripts/family-photo-moderation-bound-review-lib.mjs';
test('family evidence decrypts only in its own domain and binds target and reporter',async()=>{
 const f=createFamilyPhotoModerationFixture();
 assert.deepEqual(decryptFamilyPhotoModerationReport(f.metadata,f.envelopeBytes,f.privateKeyBytes).canonicalJPEG,SYNTHETIC_CANONICAL_JPEG);
 assert.throws(()=>decryptGroupModerationReport(f.metadata,f.envelopeBytes,f.privateKeyBytes));
 for(const name of ['familyId','assetId','reporterPersonId']){
 const changed={...f.metadata,[name]:name==='reporterPersonId'?Buffer.alloc(32,9).toString('base64url'):'00000000-0000-4000-8000-000000000009'};
 assert.throws(()=>decryptFamilyPhotoModerationReport(changed,f.envelopeBytes,f.privateKeyBytes));
 }
 assert.equal(familyPhotoModerationReviewSourceBinding(f.source,f.ref).sourceSHA256.length,64);
 let delivered=false;
 await withBoundFamilyPhotoModerationReview(f.ref,{
 readCurrentSource:async()=>f.source,readCiphertext:async()=>Buffer.from(f.envelopeBytes),
 readReviewedKey:async()=>({...f.reviewed,privateKeyBytes:Buffer.from(f.privateKeyBytes),companionPublicKeyBytes:Buffer.from(f.reviewed.companionPublicKeyBytes)}),
 audit:async()=>{},
 },({jpeg})=>{assert.deepEqual(jpeg,SYNTHETIC_CANONICAL_JPEG);delivered=true;});
 assert.equal(delivered,true);f.privateKeyBytes.fill(0);
});
test('unknown envelope fields, domain substitution and expired evidence are refused',()=>{
 for(const changeEnvelope of [e=>{e.domain='NW3.MODERATION-REPORT'},e=>{e.extra=1}]){
 const f=createFamilyPhotoModerationFixture({changeEnvelope});
 assert.throws(()=>decryptFamilyPhotoModerationReport(f.metadata,f.envelopeBytes,f.privateKeyBytes));f.privateKeyBytes.fill(0);
 }
 const f=createFamilyPhotoModerationFixture({committedAt:1});
 assert.throws(()=>decryptFamilyPhotoModerationReport(f.metadata,f.envelopeBytes,f.privateKeyBytes));f.privateKeyBytes.fill(0);
});

