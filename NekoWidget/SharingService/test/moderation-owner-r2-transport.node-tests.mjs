import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {createOwnerR2Transport} from '../scripts/moderation-owner-r2-transport.mjs';
import {deriveRawModerationPublicKey} from '../scripts/moderation-report-lib.mjs';
import {createSyntheticModerationBundle} from '../scripts/moderation-staging-drill-lib.mjs';
import {moderationReviewSourceBinding} from '../scripts/moderation-bound-review-lib.mjs';
test('cancelled remote body read stops and releases no JPEG or key',async()=>{
 const temporaryKey=randomBytes(32),bundle=createSyntheticModerationBundle(deriveRawModerationPublicKey(temporaryKey),{moderationKeyId:'moderation-v2'});
 temporaryKey.fill(0);
 const ref={caseReferenceHmac:'a'.repeat(64),caseReferenceHmacKeyVersion:1};
 const source={schema:'jp.nekowidget.moderation-review-source.v1',...ref,objectKey:'reports/synthetic-cancellation',metadata:bundle.metadata};
 const control=new AbortController();let cancelled=false,started;
 const begun=new Promise(resolve=>{started=resolve});
 const body=new ReadableStream({pull(){started();return new Promise(()=>{})},cancel(){cancelled=true}},{highWaterMark:0});
 const transport=createOwnerR2Transport({bucket:{async get(){return {size:bundle.envelopeBytes.length,body}}},keyDirectory:process.cwd(),publicKeySHA256:'b'.repeat(64),pipeName:'unused',brokerRecordFile:'unused',async assertScope(){}});
 const response=transport({source,sourceSHA256:moderationReviewSourceBinding(source,ref).sourceSHA256,signal:control.signal,async readCurrentSource(){return source},async audit(){}});
 await begun;control.abort();await assert.rejects(response,{message:'owner_review_unavailable'});assert.equal(cancelled,true);
});
