// Local Docker + Workers + durable nonce integration. Uses only a generated HMAC
// key and public Apple roots. Never deploys, purchases, stores photos or enables staging.
import assert from 'node:assert/strict';
import { randomBytes, createHash, createHmac } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
const directory = dirname(fileURLToPath(import.meta.url));
const rootsFile = process.argv[2];
assert(rootsFile, 'Pass a file containing public Apple root certificates as a base64 JSON array');
const roots = JSON.parse(await readFile(rootsFile, 'utf8'));
assert(Array.isArray(roots) && roots.length > 0);
await mkdir(join(directory, '.wrangler'), { recursive: true });
const scratch = await mkdtemp(join(directory, '.wrangler', 'local-drill-'));
const production = JSON.parse(await readFile(join(directory, 'wrangler.jsonc'), 'utf8'));
const secret = randomBytes(32);
const verifierName = 'local-billing-verifier';
const verifier = { ...production, name: verifierName, main: join(directory, 'worker.mjs'),
  vars: { ...production.vars, BILLING_VERIFIER_CONTAINER_ENABLED: 'YES',
    BILLING_VERIFIER_SHARED_SECRET: secret.toString('base64url'),
    APPLE_ROOT_CERTIFICATES_BASE64_JSON: JSON.stringify(roots), BILLING_SUBSCRIPTION_GROUP_ID: '20999999',
    BILLING_MONTHLY_PRODUCT_ID: 'jp.nekowidget.plus.monthly' },
  containers: production.containers.map(container => ({ ...container,
    image: process.env.NEKO_LOCAL_VERIFIER_IMAGE ?? resolve(directory, container.image),
    image_build_context: resolve(directory, container.image_build_context) })),
};
await writeFile(join(scratch, 'verifier.json'), JSON.stringify(verifier));
await writeFile(join(scratch, 'caller.mjs'), `
  export default { async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const container = env.CONTAINER.getByName('private-billing-verifier-v1');
    if (path === '/restart') { await container.destroy(); return new Response(null, {status:204}); }
    if (path === '/state') return Response.json(await container.getState());
    if (path === '/public') return env.PUBLIC.fetch(request);
    return env.VERIFIER.fetch(new Request('https://billing-verifier.private.invalid/internal/v1/apple-transactions/verify', request));
  } };
`);
await writeFile(join(scratch, 'caller.json'), JSON.stringify({ name: 'local-billing-caller', main: 'caller.mjs',
  compatibility_date: production.compatibility_date,
  services: [{ binding: 'VERIFIER', service: verifierName, entrypoint: 'BillingVerificationService' },
    { binding: 'PUBLIC', service: verifierName }],
  durable_objects: { bindings: [{ name: 'CONTAINER', class_name: 'BillingVerifierContainer', script_name: verifierName }] },
}));
let output = '';
const child = spawn(process.execPath, [join(directory, 'node_modules/wrangler/bin/wrangler.js'),
  'dev', '-c', join(scratch, 'caller.json'), '-c', join(scratch, 'verifier.json'), '--local',
  '--port', '8898', '--persist-to', join(scratch, 'state'), '--show-interactive-dev-session=false', '--log-level=error'],
  { cwd: directory, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, WRANGLER_SEND_METRICS: 'false', CI: 'true' } });
for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { output = (output + chunk).slice(-24000); });
const origin = 'http://127.0.0.1:8898';
const pause = ms => new Promise(done => setTimeout(done, ms));
const deadline = Date.now() + 90000;
const sign = text => createHmac('sha256', secret).update(text).digest('base64url');
const hash = bytes => createHash('sha256').update(bytes).digest('base64url');
const body = JSON.stringify({ protocolVersion: 1, signedTransactionInfo: 'header.payload.signature' });
const nonce = randomBytes(16).toString('base64url');
const timestamp = Math.floor(Date.now() / 1000);
const headers = { 'content-type': 'application/json', 'neko-billing-protocol-version': '1',
  'neko-billing-timestamp': String(timestamp), 'neko-billing-nonce': nonce,
  'neko-billing-signature': sign(['NWB1.VERIFIER.REQUEST', timestamp, nonce, hash(body)].join('\n')) };
const authenticated = async () => {
  const start = performance.now();
  const response = await fetch(origin + '/verify', { method: 'POST', headers, body, signal: AbortSignal.timeout(20000) });
  const bytes = Buffer.from(await response.arrayBuffer());
  assert.equal(response.headers.get('neko-billing-response-signature'),
    sign(['NWB1.VERIFIER.RESPONSE', nonce, response.status, hash(bytes)].join('\n')),
    'The real Node reply must retain its HMAC signature through the Container Worker');
  return { status: response.status, body: JSON.parse(bytes), seconds: (performance.now() - start) / 1000 };
};
try {
  while (true) {
    try { if ((await fetch(origin + '/public', { signal: AbortSignal.timeout(1000) })).status === 404) break; }
    catch { /* bounded startup polling of this local process only */ }
    if (child.exitCode !== null || Date.now() >= deadline) throw new Error('Local Worker startup failed: ' + output);
    await pause(250);
  }
  assert.equal((await fetch(origin + '/verify', { method: 'POST', headers: { 'content-type': 'application/json' }, body })).status, 503);
  assert.equal((await (await fetch(origin + '/state')).json()).status, 'stopped');
  const first = await authenticated();
  assert.equal(first.status, 400);
  assert.equal(first.body.error.code, 'invalid_apple_transaction');
  const replay = await authenticated();
  assert.equal(replay.body.error.code, 'billing_verifier_replayed_request');
  assert.equal((await fetch(origin + '/restart', { method: 'POST' })).status, 204);
  const restarted = await authenticated();
  assert.equal(restarted.body.error.code, 'billing_verifier_replayed_request');
  const result = { status: 'passed', environment: 'local-only', coldStartSeconds: first.seconds,
    restartedSeconds: restarted.seconds, privateBinding: true, public404: true, invalidHmacDoesNotStart: true,
    realNodeResponseAuthenticated: true, outboundHostReachedDurableNonce: true, replaySurvivesContainerRestart: true,
    doesNotEstablish: ['remote startup and routing', 'real Apple purchase/OCSP', 'live account usage'] };
  await writeFile(join(scratch, 'result.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ ...result, evidenceFile: join(scratch, 'result.json') }));
} catch (error) {
  console.error(error instanceof Error ? error.message : 'Local drill failed');
  // Generated test credentials are redacted even though they have no remote privileges.
  console.error(output.replaceAll(secret.toString('base64url'), '[synthetic-key]')
    .replaceAll(JSON.stringify(roots), '[public-roots]'));
  process.exitCode = 1;
} finally {
  try { await fetch(origin + '/restart', { method: 'POST', signal: AbortSignal.timeout(2000) }); } catch { /* process cleanup follows */ }
  if (process.platform === 'win32' && child.pid) {
    await new Promise(done => {
      const stop = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      stop.on('error', done); stop.on('exit', done);
    });
  } else child.kill('SIGTERM');
}
