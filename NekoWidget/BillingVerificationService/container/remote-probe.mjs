// Authenticated Wrangler remote bindings; this file never enables a gate or deploys.
// Default is a read-only OFF probe. A signed probe requires an explicit local key file.
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getPlatformProxy } from 'wrangler';
const directory = dirname(fileURLToPath(import.meta.url));
const scratch = join(directory, '.wrangler', 'remote-probe');
await mkdir(scratch, { recursive: true });
const configPath = join(scratch, 'caller.json');
await writeFile(configPath, JSON.stringify({ name: 'neko-billing-private-probe',
  account_id: '829a34ef925a39d81b0e9e08800d7c7f', compatibility_date: '2026-08-17',
  services: [{ binding: 'VERIFIER', service: 'neko-billing-verifier-disabled', entrypoint: 'BillingVerificationService', remote: true },
    { binding: 'PUBLIC', service: 'neko-billing-verifier-disabled', remote: true }],
}));
const platform = await getPlatformProxy({ configPath, remoteBindings: true, persist: false, envFiles: [] });
try {
  const url = 'https://billing-verifier.private.invalid/internal/v1/apple-transactions/verify';
  assert.equal((await platform.env.PUBLIC.fetch(url)).status, 404);
  const rejected = await platform.env.VERIFIER.fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  assert.equal(rejected.status, 503);
  const keyFile = process.argv[2];
  if (!keyFile) {
    console.log(JSON.stringify({ status: 'off-probe-passed', privateEntrypoint: true, default404: true,
      rejectedUnsignedRequest: true, containerStartupTested: false }));
  } else {
    const { BILLING_VERIFIER_SHARED_SECRET: key } = JSON.parse(await readFile(keyFile, 'utf8'));
    const secret = Buffer.from(key, 'base64url');
    assert.equal(secret.length, 32);
    const nonce = randomBytes(16).toString('base64url');
    const timestamp = Math.floor(Date.now() / 1000);
    const body = JSON.stringify({ protocolVersion: 1, signedTransactionInfo: 'header.payload.signature' });
    const hash = value => createHash('sha256').update(value).digest('base64url');
    const sign = value => createHmac('sha256', secret).update(value).digest('base64url');
    const headers = { 'content-type': 'application/json', 'neko-billing-protocol-version': '1',
      'neko-billing-timestamp': String(timestamp), 'neko-billing-nonce': nonce,
      'neko-billing-signature': sign(['NWB1.VERIFIER.REQUEST', timestamp, nonce, hash(body)].join('\n')) };
    const send = async () => {
      const start = performance.now();
      const response = await platform.env.VERIFIER.fetch(url, { method: 'POST', headers, body,
        signal: AbortSignal.timeout(20000) });
      const bytes = Buffer.from(await response.arrayBuffer());
      assert.equal(response.headers.get('neko-billing-response-signature'),
        sign(['NWB1.VERIFIER.RESPONSE', nonce, response.status, hash(bytes)].join('\n')));
      return { status: response.status, body: JSON.parse(bytes), seconds: (performance.now() - start) / 1000 };
    };
    const first = await send();
    assert.equal(first.status, 400);
    assert.equal(first.body.error.code, 'invalid_apple_transaction');
    const replay = await send();
    assert.equal(replay.body.error.code, 'billing_verifier_replayed_request');
    const result = { status: 'remote-signed-probe-passed', firstResponseSeconds: first.seconds,
      replayResponseSeconds: replay.seconds, privateBinding: true, nodeSignatureRetained: true,
      durableNonceBridge: true, replayRejected: true, realApplePurchaseTested: false };
    await writeFile(join(scratch, 'result.json'), JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  }
} finally { await platform.dispose(); }
