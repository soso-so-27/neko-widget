// Compile a finite plan from reviewed local inputs. No network, publication or pointer updates.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { CHANNELS, MAX_EDITIONS, validateSchedule, instant } from '../src/scheduled.js';
import { prepareMaintenance } from './prepare_maintenance.mjs';
import { prepareUpdate } from './prepare_update.mjs';
import { service, file, json, hash, stamp, route, newOutput, validateDeployment, expectedConfig, readEdition, copyEdition } from './schedule_bundle.mjs';

const DAY = 86400_000;
function checkQueue(queue, record, now) {
  assert(queue?.schemaVersion === 1 && Array.isArray(queue.items), 'Approved queue required');
  const schedules = new Set();
  let overdue = 0;
  for (const item of queue.items) {
    assert(Array.isArray(item.channels) && item.channels.every(channel => CHANNELS.includes(channel)), 'Unknown queue channel');
    if (item.channels.includes('cat-tabby-nap')) assert.equal(item.photo?.catID, 'generated-tabby-nap', 'Different cat in future queue');
    const at = instant(item.scheduledAt), until = instant(item.approvedUntil);
    const unpublished = item.channels.some(channel => {
      const row = record.channels.find(row => row.channelID === channel);
      return row.enabled && !row.history.some(photo => photo.id === item.id || photo.sha256 === item.photo?.sha256);
    });
    if (!unpublished || until <= now) continue;
    assert(!schedules.has(at), 'Unpublished photos share a scheduled time; review distinct delivery times');
    schedules.add(at);
    if (at <= now) overdue += 1;
  }
  assert(overdue <= 1, 'Multiple overdue unpublished photos require operator review');
}
async function capCatalogs(bundle, through) {
  const record = await json(path.join(bundle, 'update-record.json'));
  const until = stamp(Math.min(instant(record.validUntil), through));
  for (const channel of CHANNELS) {
    const filename = path.join(bundle, 'assets', route(channel), 'catalog.json'), catalog = await json(filename);
    catalog.validUntil = until;
    await writeFile(filename, JSON.stringify(catalog, null, 2) + '\n');
  }
  record.validUntil = until;
  await writeFile(path.join(bundle, 'update-record.json'), JSON.stringify(record, null, 2) + '\n');
  return record;
}
export async function prepareSchedule(previous, queue, output, through, now = Math.floor(Date.now() / 1000) * 1000) {
  assert(Number.isSafeInteger(now) && now % 1000 === 0, 'Use whole-second preparation time');
  const end = instant(through);
  assert(end > now && end - now <= 14 * DAY, 'Schedule horizon must be after now and at most 14 days');
  const root = await validateDeployment(previous);
  const record = await json(path.join(root, 'update-record.json'));
  // Validate the former edition at its own time. Expired photos are dropped by prepareUpdate.
  await readEdition(path.join(root, 'assets'), record, instant(record.generatedAt));
  assert(instant(record.generatedAt) < now, 'Wait until the new edition can advance');
  checkQueue(queue, record, now);
  const imageRoots = queue.items.map(item => path.dirname(item.imagePath));
  const target = await newOutput(output, [root, ...new Set(imageRoots)]);
  await mkdir(target);
  await mkdir(path.join(target, 'steps'));
  const index = { schemaVersion: 1, startsAt: stamp(now), through, editions: [] }, planned = [], sources = [];
  let cursor = now, source = root;
  while (cursor < end) {
    assert(index.editions.length < MAX_EDITIONS, 'Too many editions; review the schedule');
    const id = `edition-${String(index.editions.length).padStart(3, '0')}`;
    const step = path.join(target, 'steps', id);
    const maintenance = await prepareMaintenance(source, queue, step, cursor);
    let bundle, next;
    if (maintenance.status === 'candidate-prepared') { bundle = maintenance.bundle; next = instant(maintenance.nextActionAt); }
    else {
      assert(!maintenance.deferredReason, 'Edition failed to advance');
      assert(index.editions.length === 0, 'Expected a scheduled maintenance event');
      bundle = (await prepareUpdate(source, { schemaVersion: 1, channels: [] }, step, cursor)).bundle;
      // The new lease starts now, so the former catalog's renewal event no longer applies.
      const fresh = await json(path.join(bundle, 'update-record.json'));
      next = Math.min(cursor + DAY,
        ...fresh.channels.flatMap(row => row.earliestPhotoExpiry ? [instant(row.earliestPhotoExpiry)] : []),
        ...maintenance.queue.items.filter(row => row.status === 'scheduled').map(row => instant(row.scheduledAt)));
    }
    assert(next > cursor, 'Schedule time did not advance');
    const currentRecord = await capCatalogs(bundle, end);
    const content = await readEdition(path.join(bundle, 'assets'), currentRecord, cursor, { through: end });
    const until = Math.min(next, end);
    for (const { catalog } of Object.values(content.catalogs)) assert(instant(catalog.validUntil) >= until, 'Gap in scheduled catalog coverage');
    index.editions.push({ id, startsAt: stamp(cursor), endsAt: stamp(until),
      catalogs: Object.fromEntries(CHANNELS.map(channel => [channel, hash(content.catalogs[channel].bytes)])) });
    planned.push({ id, record: currentRecord }); sources.push(bundle);
    cursor = until; source = bundle;
  }
  validateSchedule(index);
  const indexBytes = JSON.stringify(index, null, 2) + '\n';
  assert(Buffer.byteLength(indexBytes, 'utf8') <= 256 * 1024, 'Schedule index exceeds the Worker reader limit');
  const localRecord = JSON.stringify({ schemaVersion: 1, kind: 'planned-editions',
    preparedAt: stamp(now), through, sourceBundle: root, editions: planned }, null, 2) + '\n';
  assert(Buffer.byteLength(localRecord, 'utf8') <= 2 * 1024 * 1024, 'Planned history exceeds the restoration reader limit');
  const bundle = path.join(target, 'bundle');
  await mkdir(bundle); await mkdir(path.join(bundle, 'assets'));
  await mkdir(path.join(bundle, 'assets/__schedule')); await mkdir(path.join(bundle, 'assets/__schedule/editions'));
  for (const [position, edition] of index.editions.entries()) {
    const content = await readEdition(path.join(sources[position], 'assets'), planned[position].record, instant(edition.startsAt), { through: end });
    await copyEdition(content, path.join(bundle, 'assets/__schedule/editions', edition.id));
  }
  await writeFile(path.join(bundle, 'assets/__schedule/index.json'), indexBytes, { flag: 'wx' });
  await writeFile(path.join(bundle, 'schedule-record.json'), localRecord, { flag: 'wx' });
  for (const name of ['index.js', 'scheduled.js']) await writeFile(path.join(bundle, name), await file(path.join(service, 'src', name)), { flag: 'wx' });
  await writeFile(path.join(bundle, 'wrangler.jsonc'), JSON.stringify(await expectedConfig(true), null, 2) + '\n', { flag: 'wx' });
  const result = { schemaVersion: 1, status: 'schedule-prepared', bundle, startsAt: stamp(now), through, editionCount: index.editions.length,
    editions: index.editions.map((edition, position) => ({ id: edition.id, startsAt: edition.startsAt, endsAt: edition.endsAt,
      additions: planned[position].record.channels.flatMap(row => row.added.map(photoID => ({ channelID: row.channelID, photoID }))) })),
    warning: 'Finite planned editions, not publication evidence. No deployment or pointer update performed.' };
  await writeFile(path.join(target, 'plan.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx' });
  return result;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { previous: { type: 'string' }, queue: { type: 'string' }, output: { type: 'string' }, through: { type: 'string' } } });
    if (!values.previous || !values.queue || !values.output || !values.through) throw new Error('Usage: node tools/prepare_schedule.mjs --previous <legacy-bundle> --queue <approved-json> --output <new-directory> --through <UTC-seconds-Z>');
    console.log(JSON.stringify(await prepareSchedule(values.previous, await json(values.queue), values.output, values.through), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
