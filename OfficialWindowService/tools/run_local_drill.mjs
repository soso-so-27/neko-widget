// Exercise the actual local Workers runtime at one URL through A -> B -> pause.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { prepareBundle } from './prepare_bundle.mjs';

const service = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { values } = parseArgs({ options: { fixtures: { type: 'string' }, output: { type: 'string' }, port: { type: 'string', default: '8795' } } });
if (!values.fixtures || !values.output || !/^\d{4,5}$/.test(values.port) || Number(values.port) > 65535) throw new Error('Use --fixtures <first/updated/paused parent> --output <new-local-directory> [--port 8795]');
const output = path.resolve(values.output), base = `http://127.0.0.1:${values.port}`;
await mkdir(output); // deliberately fails for existing output; preserves prior evidence
const editions = {};
for (const name of ['first', 'updated', 'paused']) {
  const directory = path.join(output, name);
  await prepareBundle(path.join(values.fixtures, name), directory);
  editions[name] = {
    directory,
    catalog: JSON.parse(await readFile(path.join(directory, 'assets/catalog.json'), 'utf8')),
  };
}
const liveConfig = path.join(output, 'local-wrangler.jsonc');
async function select(name) {
  const config = JSON.parse(await readFile(path.join(editions[name].directory, 'wrangler.jsonc'), 'utf8'));
  config.main = path.resolve(editions[name].directory, config.main);
  config.assets.directory = path.join(editions[name].directory, 'assets');
  config.workers_dev = false;
  const temporary = `${liveConfig}.next`;
  await writeFile(temporary, JSON.stringify(config, null, 2));
  await rename(temporary, liveConfig);
}
await select('first');
let logs = '', processError;
const child = spawn(process.execPath, [
  path.join(service, 'node_modules/wrangler/bin/wrangler.js'), 'dev', '--local',
  '--config', liveConfig, '--port', values.port, '--inspector-port', '0',
], {
  cwd: service, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, WRANGLER_SEND_METRICS: 'false' },
});
child.on('error', error => { processError = error; });
child.stdout.on('data', data => { logs = (logs + data).slice(-200_000); });
child.stderr.on('data', data => { logs = (logs + data).slice(-200_000); });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const checks = [];
async function edition(name) {
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    if (processError || child.exitCode !== null) throw processError ?? new Error(`Wrangler exited with ${child.exitCode}`);
    try {
      const response = await fetch(`${base}/catalog.json`, { signal: AbortSignal.timeout(2000) });
      if (response.ok) {
        const actual = await response.json();
        if (actual.generatedAt === editions[name].catalog.generatedAt) {
          assert.deepEqual(actual, editions[name].catalog);
          assert.equal(response.headers.get('cache-control'), 'no-store');
          return actual;
        }
      }
    } catch { /* local runtime reloads briefly between asset editions */ }
    await pause(250);
  }
  throw new Error(`Timed out waiting for ${name}; see local-runtime.log`);
}
async function checkPhoto(photo) {
  const response = await fetch(`${base}/${photo.imageFilename}`, { signal: AbortSignal.timeout(5000) });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'image/jpeg');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(createHash('sha256').update(new Uint8Array(await response.arrayBuffer())).digest('hex'), photo.sha256);
}
try {
  const first = await edition('first');
  assert.equal(first.photos.length, 1); await checkPhoto(first.photos[0]);
  checks.push('A: native-format catalog and JPEG served');
  console.log(checks.at(-1));
  await select('updated');
  const updated = await edition('updated');
  assert.equal(updated.photos.length, 2);
  assert.notEqual(updated.photos[0].id, first.photos[0].id);
  assert.ok(Date.parse(updated.generatedAt) > Date.parse(first.generatedAt));
  await checkPhoto(updated.photos[0]);
  checks.push('B: same URL now serves the newer photo and catalog edition');
  console.log(checks.at(-1));
  await select('paused');
  const stopped = await edition('paused');
  assert.equal(stopped.enabled, false); assert.equal(stopped.photos.length, 0);
  for (const photo of updated.photos) {
    const response = await fetch(`${base}/${photo.imageFilename}`);
    assert.equal(response.status, 404); assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  assert.equal((await fetch(`${base}/source.json`)).status, 404);
  assert.equal((await fetch(`${base}/catalog.json`, { method: 'POST' })).status, 405);
  checks.push('Pause: both old JPEG URLs denied; unrelated files and writes denied');
  console.log(checks.at(-1));
  await writeFile(path.join(output, 'result.json'), JSON.stringify({
    result: 'passed', checkedAt: new Date().toISOString(), baseURL: base,
    syntheticOnly: true, externalDeployment: false, iPhoneWidgetVerified: false, checks,
  }, null, 2) + '\n');
} finally {
  // Stop only the tree created by this script, never other Node/Worker sessions.
  if (child.pid && child.exitCode === null) {
    if (process.platform === 'win32') spawnSync('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    else child.kill('SIGTERM');
  }
  await writeFile(path.join(output, 'local-runtime.log'), logs);
}
