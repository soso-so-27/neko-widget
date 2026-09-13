// Read-only HTTP/version verification. Creates only a fresh local inspection view.
import assert from 'node:assert/strict';
import { access, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';
import { verifyPreview, activeVersion } from './verify_preview.mjs';
import { restoreCurrentEdition } from './restore_schedule.mjs';
import { currentScheduledEdition, newOutput, route } from './schedule_bundle.mjs';
import { CHANNELS, INDEX_PATH } from '../src/scheduled.js';
import { activeFiles } from '../src/index.js';

const base = 'https://neko-widget-official-cats-preview.nakanishisoya.workers.dev';
export async function verifySchedule(bundle, version, output, { previousBundle, allowExpired = false, versionReader = activeVersion } = {}) {
  const initial = await currentScheduledEdition(bundle, Date.now(), { allowExpired });
  const target = await newOutput(output, [initial.root]);
  await mkdir(target);
  const current = await restoreCurrentEdition(bundle, path.join(target, 'current'), Date.now(), { allowExpired });
  assert.equal(current.editionID, initial.selected.id, 'Edition changed before inspection');
  let previous = previousBundle;
  if (previousBundle) {
    let scheduled = false;
    try { await access(path.join(previousBundle, 'schedule-record.json')); scheduled = true; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (scheduled) previous = (await restoreCurrentEdition(previousBundle, path.join(target, 'previous'), Date.now(), { allowExpired: true })).bundle;
  }
  const result = await verifyPreview(current.bundle, version, { previousBundle: previous, deploymentBundle: bundle, allowExpired, versionReader });
  const denied = [INDEX_PATH, `/__schedule/editions/${initial.selected.id}/catalog.json`, '/schedule-record.json',
    '/wrangler.jsonc', '/scheduled.js', '/index.js', '/windows/unknown/catalog.json'];
  // Check both future and formerly served JPEGs. At the finite final deadline
  // canonical routes return 503; internal routes must still return 404.
  const unavailableImages = new Set();
  const currentFiles = new Map(CHANNELS.map(channel => [channel,
    initial.expired ? new Set() : activeFiles(initial.content.catalogs[channel].catalog, Date.now(), channel)]));
  const { readFile } = await import('node:fs/promises');
  for (const edition of initial.index.editions) {
    for (const channel of CHANNELS) {
      const catalog = JSON.parse(await readFile(path.join(initial.root, 'assets/__schedule/editions', edition.id, route(channel), 'catalog.json'), 'utf8'));
      for (const photo of catalog.photos) if (!currentFiles.get(channel).has(photo.imageFilename)) unavailableImages.add('/' + [route(channel), photo.imageFilename].filter(Boolean).join('/'));
    }
  }
  for (const route of new Set(denied)) {
    const response = await fetch(base + route, { redirect: 'error', signal: AbortSignal.timeout(15_000) });
    assert.equal(response.status, 404, 'An internal or future file is publicly available');
    await response.body?.cancel();
  }
  for (const route of unavailableImages) {
    const response = await fetch(base + route, { redirect: 'error', signal: AbortSignal.timeout(15_000) });
    assert.equal(response.status, initial.expired ? 503 : 404, 'A future, withdrawn or expired JPEG remains available');
    await response.body?.cancel();
  }
  const final = await currentScheduledEdition(bundle, Date.now(), { allowExpired });
  assert.equal(final.selected.id, initial.selected.id, 'Edition changed during verification; inspect the new edition');
  assert.equal(final.expired, initial.expired, 'Schedule expired during verification');
  assert.equal(await versionReader(path.join(bundle, 'wrangler.jsonc')), version, 'Worker changed during schedule verification');
  const report = { ...result, editionID: current.editionID, endsAt: current.endsAt, through: initial.index.through, expired: initial.expired,
    inaccessibleURLsChecked: new Set(denied).size + unavailableImages.size };
  await writeFile(path.join(target, 'verification.json'), JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
  return report;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { bundle: { type: 'string' }, version: { type: 'string' }, output: { type: 'string' }, previous: { type: 'string' }, 'allow-expired': { type: 'boolean', default: false } } });
    if (!values.bundle || !values.version || !values.output) throw new Error('Usage: node tools/verify_schedule.mjs --bundle <scheduled-bundle> --version <recorded-version> --output <new-inspection-directory> [--previous <former-bundle>] [--allow-expired]');
    console.log(JSON.stringify(await verifySchedule(values.bundle, values.version, values.output, { previousBundle: values.previous, allowExpired: values['allow-expired'] }), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
