import assert from 'node:assert/strict';
import {createPublicKey,verify} from 'node:crypto';
import {readFileSync} from 'node:fs';

// Consumes only the signature for an existing synthetic PUBLIC test vector.
// No new evidence file, private key, production request or network call.
const output=readFileSync(0,'utf8');
const matches=[...output.matchAll(/^GROUP_HTTP_SIGNATURE=([A-Za-z0-9_-]{86})$/gm)];
assert.equal(matches.length,1,'one actual CryptoKit fixture signature');
const fixture=JSON.parse(readFileSync(new URL('./fixtures/group-http-v3.json',import.meta.url),'utf8'));
const publicKey=createPublicKey({format:'der',type:'spki',key:Buffer.concat([
  Buffer.from('302a300506032b6570032100','hex'),Buffer.from(fixture.signingPublicKey,'base64url')])});
const bytes=Buffer.from(fixture.request.canonicalBytes,'base64url');
const signature=Buffer.from(matches[0][1],'base64url');
assert(verify(null,bytes,publicKey,signature),'actual native signature accepted by independent verifier');
assert(!verify(null,Buffer.concat([bytes,Buffer.from([0])]),publicKey,signature),'modified request refused');
assert(output.includes('Group adapter: wire, signed names, HPKE, durable retries and device-root separation passed'));
process.stdout.write('Group adapter and independent native HTTP signature verification passed\n');
