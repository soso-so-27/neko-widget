// Read-only verification for the existing preview. No upload or state changes.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import { activeFiles } from '../src/index.js';
import { CAT_WINDOWS } from './prepare_update.mjs';

const service = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const base = 'https://neko-widget-official-cats-preview.nakanishisoya.workers.dev';
const account = '829a34ef925a39d81b0e9e08800d7c7f';
const readJSON = async file => JSON.parse(await readFile(file, 'utf8'));
const prefix = id => id === 'official-cats' ? '' : `/windows/${id}`;

export async function previousPhotosForChannel(bundle, channelID) {
  assert(/^[a-z0-9-]{1,64}$/.test(channelID), 'Invalid previous channel');
  const history = await readJSON(path.join(bundle, 'update-record.json'));
  assert(history.schemaVersion === 1 && Array.isArray(history.channels), 'Previous history required');
  const filename = path.join(bundle, 'assets', prefix(channelID).slice(1), 'catalog.json');
  if (!history.channels.some(row => row.channelID === channelID)) {
    assert(Object.hasOwn(CAT_WINDOWS, channelID), 'Unknown new channel');
    // Only first creation has no former URLs. A known channel with a missing
    // file or an unrecorded existing catalog must still fail verification.
    try { await readFile(filename); assert.fail('Previous catalog is missing from history'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    return [];
  }
  const old = await readJSON(filename);
  activeFiles(old, Date.parse(old.generatedAt), channelID);
  return old.photos;
}

export function deploymentVersion(deployments) {
  assert(Array.isArray(deployments) && deployments.length, 'No deployment evidence');
  assert(deployments.every(row => Number.isFinite(Date.parse(row.created_on))), 'Invalid deployment time');
  const latest = [...deployments].sort((a, b) => Date.parse(b.created_on) - Date.parse(a.created_on))[0];
  assert(latest.versions?.length === 1 && latest.versions[0].percentage === 100, 'Split deployment requires operator review');
  return latest.versions[0].version_id;
}

async function activeVersion(config) {
  const { stdout } = await promisify(execFile)(process.execPath,
    [path.join(service, 'node_modules/wrangler/bin/wrangler.js'), 'deployments', 'list', '--config', config, '--json'],
    { cwd: service, windowsHide: true, timeout: 45_000, maxBuffer: 2 * 1024 * 1024,
      env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  return deploymentVersion(JSON.parse(stdout.replace(/^\uFEFF/, '')));
}

export async function verifyPreview(bundle, expectedVersion, { allowExpired = false, previousBundle } = {}) {
  assert(path.isAbsolute(bundle), 'Use an absolute bundle path');
  assert(/^[a-f0-9-]{36}$/.test(expectedVersion), 'A recorded Worker version is required');
  const configPath = path.join(bundle, 'wrangler.jsonc'), config = await readJSON(configPath);
  const template = await readJSON(path.join(service, 'wrangler.jsonc'));
  delete template.$schema;
  template.main = './worker.js';
  template.assets.directory = './assets';
  assert.deepEqual(config, template, 'Candidate config changed');
  assert(config.account_id === account && config.name === 'neko-widget-official-cats-preview', 'Wrong preview target');
  assert.deepEqual(await readFile(path.join(bundle, 'worker.js')), await readFile(path.join(service, 'src/index.js')), 'Worker code changed');
  assert.equal(await activeVersion(configPath), expectedVersion, 'Live Worker is not the recorded edition');
  const history = await readJSON(path.join(bundle, 'update-record.json'));
  assert(history.schemaVersion === 1 && Array.isArray(history.channels) && history.channels.length, 'History required');
  const channels = [];
  for (const row of history.channels) {
    assert(/^[a-z0-9-]{1,64}$/.test(row.channelID), 'Invalid channel');
    const route = prefix(row.channelID);
    const catalog = await readJSON(path.join(bundle, 'assets', route.slice(1), 'catalog.json'));
    activeFiles(catalog, Date.parse(catalog.generatedAt), row.channelID);
    const response = await fetch(base + route + '/catalog.json', { redirect: 'error', signal: AbortSignal.timeout(15_000) });
    const now = Date.now();
    if (now >= Date.parse(catalog.validUntil)) {
      assert(allowExpired && response.status === 503, 'Expired edition requires explicit recovery verification');
      channels.push({ channelID: row.channelID, state: 'expired-known-version', photosChecked: 0 });
      continue;
    }
    assert.equal(response.status, 200, `Catalog unavailable: ${row.channelID}`);
    assert.deepEqual(await response.json(), catalog, `Live catalog differs: ${row.channelID}`);
    const files = activeFiles(catalog, now, row.channelID);
    for (const filename of files) {
      const image = await fetch(base + route + '/' + filename, { redirect: 'error', signal: AbortSignal.timeout(15_000) });
      assert.equal(image.status, 200, 'Published JPEG unavailable');
      assert.equal(image.headers.get('content-type'), 'image/jpeg');
      const bytes = Buffer.from(await image.arrayBuffer());
      assert.equal(createHash('sha256').update(bytes).digest('hex') + '.jpg', filename, 'Published JPEG hash differs');
    }
    const absent = new Set(catalog.photos.map(p => p.imageFilename).filter(file => !files.has(file)));
    if (previousBundle) {
      for (const photo of await previousPhotosForChannel(previousBundle, row.channelID)) {
        if (!files.has(photo.imageFilename)) absent.add(photo.imageFilename);
      }
    }
    for (const filename of absent) {
      assert(/^[a-f0-9]{64}\.jpg$/.test(filename), 'Invalid former JPEG path');
      const gone = await fetch(base + route + '/' + filename, { redirect: 'error', signal: AbortSignal.timeout(15_000) });
      assert.equal(gone.status, 404, 'Withdrawn or expired JPEG still available');
    }
    channels.push({ channelID: row.channelID, state: 'matched', photosChecked: files.size,
      unavailableChecked: absent.size, validUntil: catalog.validUntil });
  }
  // Do not accept a deployment that changed while HTTP checks were running.
  assert.equal(await activeVersion(configPath), expectedVersion, 'Worker changed during verification');
  return { schemaVersion: 1, checkedAt: new Date().toISOString(), workerVersion: expectedVersion, channels };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { bundle: { type: 'string' }, version: { type: 'string' },
      'allow-expired': { type: 'boolean', default: false }, previous: { type: 'string' } } });
    assert(values.bundle && values.version, 'Usage: node tools/verify_preview.mjs --bundle <bundle> --version <recorded-worker-version> [--allow-expired] [--previous <old-bundle>]');
    console.log(JSON.stringify(await verifyPreview(values.bundle, values.version,
      { allowExpired: values['allow-expired'], previousBundle: values.previous }), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
