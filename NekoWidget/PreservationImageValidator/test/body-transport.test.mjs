import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { createImageValidator } from '../dist/provider.js';
import { createValidatorHTTPServer } from '../dist/http-server.js';
import { MAX_PHOTO_BYTES } from '../dist/limits.js';
import { jpeg } from './fixtures.mjs';

async function maximumJPEG() {
 const photo=await jpeg(); const padding=[];let remaining=MAX_PHOTO_BYTES-photo.length;
 while(remaining>0){const length=Math.min(65537,remaining);assert.ok(length>=4);
  const segment=Buffer.alloc(length,0x5a);segment[0]=0xff;segment[1]=0xfe;segment.writeUInt16BE(length-2,2);
  padding.push(segment);remaining-=length;}
 return Buffer.concat([photo.subarray(0,2),...padding,photo.subarray(2)]);
}

test('actual decoder accepts maximum JPEG JSON delivered in 4 KiB fragments',async()=>{
 const photo=await maximumJPEG();const bytes=Buffer.from(JSON.stringify({photoBase64:photo.toString('base64')}));let offset=0,reads=0;
 const body=new ReadableStream({pull(c){reads++;if(offset===bytes.length){c.close();return;}
  c.enqueue(bytes.subarray(offset,offset+4096));offset=Math.min(offset+4096,bytes.length);}}, {highWaterMark:0});
 const response=await createImageValidator({enabled:true}).fetch(new Request('http://validator/images/validate-jpeg',
  {method:'POST',headers:{'content-type':'application/json','content-length':String(bytes.length)},body,duplex:'half'}));
 assert.equal(response.status,200);assert.deepEqual(await response.json(),{valid:true,mediaType:'image/jpeg',frames:1});
 assert.equal(reads,Math.ceil(bytes.length/4096)+1);assert.ok(reads>6800);
});

test('real private HTTP bridge accepts a six-second body with steady progress',async()=>{
 const secret='A'.repeat(43);const server=createValidatorHTTPServer(secret);server.listen(0,'127.0.0.1');await once(server,'listening');
 const bytes=Buffer.from(JSON.stringify({photoBase64:(await jpeg()).toString('base64')}));let offset=0;
 const step=Math.ceil(bytes.length/12);const started=performance.now();
 const body=new ReadableStream({async pull(c){if(offset===bytes.length){c.close();return;}
  await sleep(500);c.enqueue(bytes.subarray(offset,offset+step));offset=Math.min(offset+step,bytes.length);}}, {highWaterMark:0});
 try {const response=await fetch(`http://127.0.0.1:${server.address().port}/images/validate-jpeg`,
  {method:'POST',headers:{'content-type':'application/json','x-neko-validator-secret':secret},body,duplex:'half'});
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{valid:true,mediaType:'image/jpeg',frames:1});
  assert.ok(performance.now()-started>=5900);
 }finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
});
