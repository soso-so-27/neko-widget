// Fixed local monitor. No generation, deployment, queue mutation or pointer update.
import { readFile, writeFile, mkdir, access, rename } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';
const checkout = 'C:/dev/neko-official-supply-20260913';
const runtime = path.join(checkout, 'output/runtime');
const moduleAt = name => import(pathToFileURL(path.join(checkout, 'OfficialWindowService/tools', name)));
const { verifySchedule } = await moduleAt('verify_schedule.mjs');
const { prepareMaintenance } = await moduleAt('prepare_maintenance.mjs');
const { CAT_WINDOWS } = await moduleAt('prepare_update.mjs');
const read = async file => JSON.parse(await readFile(file, 'utf8'));
const json = value => JSON.stringify(value, null, 2) + '\n';
const pointer = path.join(runtime, 'current.json'), receipt = path.join(runtime, 'last-schedule-check.json');
const run = path.join(runtime, 'runs', new Date().toISOString().replace(/[-:.]/g, '') + '-schedule-check');
await mkdir(run);
try {
  await assert.rejects(access(path.join(runtime, 'pending.json')), error => error.code === 'ENOENT');
  const before = await read(pointer);
  assert.equal(before.mode, 'scheduled', 'Scheduled mode is required; do not fall back to legacy maintenance');
  const queue = await read(before.queue);
  for (const item of queue.items) for (const id of item.channels) {
    if (CAT_WINDOWS[id]) assert.equal(item.photo.catID, CAT_WINDOWS[id].catID, 'A future queue photo belongs to another cat');
  }
  const verified = await verifySchedule(before.currentBundle, before.workerVersion, path.join(run, 'verify'));
  const plan = await prepareMaintenance(path.join(run, 'verify/current'), queue, path.join(run, 'local-plan'));
  await writeFile(path.join(run, 'plan.json'), json(plan), { flag: 'wx' });
  assert.equal(plan.status, 'no-change', 'The current edition needs an unexpected update; review without deploying');
  assert(isDeepStrictEqual(await read(pointer), before), 'Deployment pointer changed while checking');
  assert(isDeepStrictEqual(await read(before.queue), queue), 'Approved queue changed while checking');
  const photos = {};
  for (const row of verified.channels) {
    const route = row.channelID === 'official-cats' ? '' : 'windows/' + row.channelID;
    const catalog = await read(path.join(run, 'verify/current/assets', route, 'catalog.json'));
    photos[row.channelID] = catalog.photos.map(photo => photo.id).sort();
  }
  const alerts = [];
  for (const [channelID, minimum] of [['official-cats', 3], ['cat-tabby-nap', 2]]) {
    const row = plan.queue.channels.find(value => value.channelID === channelID);
    assert(row, 'Missing channel stock');
    if (row.remainingCount < minimum) alerts.push('low-stock:' + channelID);
  }
  if (Date.parse(verified.through) - Date.now() <= 72 * 3600_000) alerts.push('schedule-ending:' + verified.through);
  let previous;
  try { previous = await read(receipt); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const newlyPublished = previous ? Object.entries(photos).flatMap(([channelID, ids]) =>
    ids.filter(id => !previous.photos?.[channelID]?.includes(id)).map(photoID => ({ channelID, photoID }))) : [];
  const newAlerts = alerts.filter(alert => !previous?.alerts?.includes(alert));
  const result = { schemaVersion: 1, checkedAt: verified.checkedAt, workerVersion: before.workerVersion,
    editionID: verified.editionID, through: verified.through, photos, alerts, newAlerts, newlyPublished,
    queue: plan.queue.channels, notify: newAlerts.length > 0 || newlyPublished.length > 0,
    message: 'Read-only server verification; device Widget delivery was not checked.' };
  await writeFile(path.join(run, 'result.json'), json(result), { flag: 'wx' });
  const temporary = path.join(run, 'receipt.json');
  await writeFile(temporary, json(result), { flag: 'wx' });
  for (const target of [temporary, receipt]) assert(path.resolve(target).startsWith(path.resolve(runtime) + path.sep));
  await rename(temporary, receipt);
  console.log(json({ run, notify: result.notify, newAlerts, newlyPublished, through: result.through }));
} catch (error) {
  await writeFile(path.join(run, 'failure.json'), json({ failedAt: new Date().toISOString(), message: error.message }), { flag: 'wx' });
  console.error(json({ run, notify: true, error: error.message, action: 'Read-only check stopped; no deployment was attempted.' }));
  process.exitCode = 1;
}
