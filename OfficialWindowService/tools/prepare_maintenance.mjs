// Local queue selection and catalog maintenance. Never uploads or updates a pointer.
import { lstat, readdir, readFile, realpath, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { activeFiles } from '../src/index.js';
import { prepareUpdate } from './prepare_update.mjs';

const HOUR = 3600_000, DAY = 24 * HOUR;
const slug = /^[a-z0-9-]{1,64}$/, hash = /^[a-f0-9]{64}$/;
const stamp = value => new Date(value).toISOString().replace('.000Z', 'Z');
function require(condition, message) { if (!condition) throw new Error(message); }
// A publisher-output mix-up guard, not a decoder or metadata removal tool.
// Inspect headers between scans too: APP/COM data must not hide after SOS.
function validatePublisherJPEG(bytes, width, height) {
  require(bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216, 'Invalid publisher JPEG');
  let offset = 2, scan = false, frame = false, sawScan = false, jfif = false;
  while (offset < bytes.length) {
    if (scan) {
      while (offset < bytes.length && bytes[offset] !== 255) offset++;
      require(offset + 1 < bytes.length, 'Truncated JPEG scan');
    }
    require(bytes[offset++] === 255, 'Broken JPEG segment header');
    while (offset < bytes.length && bytes[offset] === 255) offset++;
    require(offset < bytes.length, 'Truncated JPEG marker');
    const marker = bytes[offset++];
    if (scan && (marker === 0 || (marker >= 0xd0 && marker <= 0xd7))) continue;
    scan = false;
    if (marker === 0xd9) {
      require(frame && sawScan && offset === bytes.length, 'Invalid JPEG end or trailing data');
      return;
    }
    require(!(marker >= 0xe1 && marker <= 0xef) && marker !== 0xfe, 'JPEG metadata segment is not permitted');
    require([0xe0, 0xc0, 0xc2, 0xc4, 0xdb, 0xdd, 0xda].includes(marker), 'Unsupported publisher JPEG marker');
    require(offset + 2 <= bytes.length, 'Truncated JPEG segment length');
    const length = bytes.readUInt16BE(offset), start = offset + 2, end = offset + length;
    require(length >= 2 && end <= bytes.length, 'Broken JPEG segment length');
    if (marker === 0xe0) {
      require(!jfif && length === 16 && bytes.subarray(start, start + 5).equals(Buffer.from('JFIF\0', 'ascii'))
        && bytes[start + 5] === 1 && bytes[start + 6] <= 2 && bytes[start + 7] <= 2
        && bytes.readUInt16BE(start + 8) > 0 && bytes.readUInt16BE(start + 10) > 0
        && bytes[start + 12] === 0 && bytes[start + 13] === 0, 'Only thumbnail-free JFIF APP0 is permitted');
      jfif = true;
    } else if (marker === 0xc0 || marker === 0xc2) {
      require(!frame && length >= 11 && bytes[start] === 8
        && bytes[start + 5] >= 1 && bytes[start + 5] <= 4 && length === 8 + 3 * bytes[start + 5]
        && bytes.readUInt16BE(start + 1) === height && bytes.readUInt16BE(start + 3) === width,
        'JPEG SOF dimensions do not match the approved metadata');
      frame = true;
    } else if (marker === 0xda) {
      require(frame && length >= 8 && bytes[start] >= 1 && bytes[start] <= 4
        && length === 6 + 2 * bytes[start], 'Broken JPEG SOS header');
      scan = true; sawScan = true;
    }
    offset = end;
  }
  throw new Error('JPEG end marker is missing');
}
function keys(value, allowed) {
  require(value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every(key => allowed.includes(key)), 'Unknown or invalid queue field');
}
function instant(value) {
  require(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)
    && Number.isFinite(Date.parse(value)) && stamp(Date.parse(value)) === value, 'Use a valid UTC timestamp');
  return Date.parse(value);
}
function localPath(value) {
  require(typeof value === 'string' && path.isAbsolute(value)
    && !value.startsWith('\\\\') && !value.startsWith('//'), 'Use absolute local paths');
  return path.resolve(value);
}
async function directory(value) {
  const resolved = localPath(value), info = await lstat(resolved);
  require(info.isDirectory() && !info.isSymbolicLink(), 'Use a regular local directory');
  const actual = await realpath(resolved);
  localPath(actual);
  return actual;
}
async function regularFile(filename, maximum) {
  const resolved = localPath(filename);
  const parent = await directory(path.dirname(resolved));
  const target = path.join(parent, path.basename(resolved)), info = await lstat(target);
  require(info.isFile() && !info.isSymbolicLink() && info.size <= maximum, 'Invalid input file');
  const bytes = await readFile(target);
  require(bytes.length <= maximum, 'Input grew beyond its size limit');
  return { bytes, path: target };
}
async function jsonFile(filename) {
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode((await regularFile(filename, 2 * 1024 * 1024)).bytes));
}
function outside(input, target) {
  const relative = path.relative(input, target);
  return relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative);
}
async function previousChannels(previous, now) {
  const root = await directory(previous), assets = await directory(path.join(root, 'assets'));
  // A heartbeat must never create a fresh history in place of a lost one.
  const record = await jsonFile(path.join(root, 'update-record.json'));
  require(record.schemaVersion === 1 && Array.isArray(record.channels), 'Publication history is required');
  const ids = ['official-cats'];
  try {
    const windows = await directory(path.join(assets, 'windows'));
    for (const id of (await readdir(windows)).sort()) {
      require(slug.test(id) && id !== 'official-cats', 'Invalid existing channel');
      ids.push(id);
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  require(record.channels.length === ids.length && new Set(record.channels.map(row => row.channelID)).size === ids.length,
    'Publication history does not cover every channel');
  const channels = new Map();
  for (const id of ids) {
    const location = id === 'official-cats' ? assets : await directory(path.join(assets, 'windows', id));
    const catalog = await jsonFile(path.join(location, 'catalog.json'));
    const generated = instant(catalog.generatedAt);
    require(generated <= now, 'Previous edition is from the future');
    activeFiles(catalog, generated, id); // Expired editions still have a valid historical structure.
    const saved = record.channels.find(row => row.channelID === id);
    require(saved && Array.isArray(saved.history) && saved.enabled === catalog.enabled
      && record.generatedAt === catalog.generatedAt, 'Publication history does not match the edition');
    const history = new Map();
    for (const photo of saved.history) {
      require(photo && typeof photo.id === 'string' && slug.test(photo.id) && hash.test(photo.sha256)
        && !history.has(photo.id) && instant(photo.publishedAt) <= now, 'Invalid publication history');
      history.set(photo.id, photo);
    }
    for (const photo of catalog.photos) {
      const known = history.get(photo.id);
      require(known && known.sha256 === photo.sha256 && known.publishedAt === photo.publishedAt,
        'Current photo is missing from publication history');
    }
    channels.set(id, { catalog, history, hashes: new Set([...history.values()].map(photo => photo.sha256)) });
  }
  return { root, channels };
}
function photoCatalog(channelID, photo, published, expires) {
  return { schemaVersion: 1, channelID, enabled: true, generatedAt: stamp(published),
    validUntil: stamp(published + 48 * HOUR), photos: [{ ...photo, publishedAt: stamp(published), expiresAt: stamp(expires) }] };
}
function summary(rows, channelIDs) {
  const pending = row => row.status !== 'already-published' && row.status !== 'approval-expired';
  const future = rows.filter(row => row.status === 'scheduled');
  const remaining = rows.filter(pending);
  const minimum = (values, field) => values.length ? stamp(Math.min(...values.map(value => instant(value[field])))) : null;
  return {
    remainingCount: new Set(remaining.map(row => row.id)).size,
    remainingAfterCandidate: new Set(remaining.filter(row => row.status !== 'selected').map(row => row.id)).size,
    expiredCount: new Set(rows.filter(row => row.status === 'approval-expired').map(row => row.id)).size,
    nextScheduledAt: minimum(future, 'scheduledAt'),
    earliestApprovalExpiry: minimum(remaining, 'approvedUntil'),
    channels: channelIDs.map(channelID => {
      const own = remaining.filter(row => row.channelID === channelID);
      return { channelID, remainingCount: own.length, remainingAfterCandidate: own.filter(row => row.status !== 'selected').length,
        nextScheduledAt: minimum(own.filter(row => row.status === 'scheduled'), 'scheduledAt'),
        earliestApprovalExpiry: minimum(own, 'approvedUntil') };
    }),
    items: rows,
  };
}

export async function prepareMaintenance(previous, queue, output, now = Math.floor(Date.now() / 1000) * 1000) {
  require(Number.isSafeInteger(now) && now % 1000 === 0, 'Use a whole-second maintenance time');
  keys(queue, ['schemaVersion', 'items']);
  require(queue.schemaVersion === 1 && Array.isArray(queue.items) && queue.items.length <= 256, 'Invalid or oversized queue');
  const { root, channels } = await previousChannels(previous, now);
  const destination = localPath(output), parent = await directory(path.dirname(destination));
  const target = path.join(parent, path.basename(destination));
  require(outside(root, target), 'Output must be outside the previous bundle');
  try { await lstat(target); throw new Error('Output already exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const ids = new Set(), hashes = new Set(), rows = [], additions = new Map(), imageBytes = new Map(), validated = [];
  const nextTimes = [];
  const reasons = [];
  for (const [id, { catalog }] of channels) {
    const renewalAt = instant(catalog.validUntil) - DAY;
    if (renewalAt <= now) reasons.push({ channelID: id, reason: 'catalog-renewal' });
    else nextTimes.push(renewalAt);
    for (const photo of catalog.photos) {
      if (instant(photo.expiresAt) <= now) reasons.push({ channelID: id, reason: 'photo-expired', photoID: photo.id });
      else nextTimes.push(instant(photo.expiresAt));
    }
  }
  for (const item of queue.items) {
    keys(item, ['id', 'channels', 'scheduledAt', 'approvedUntil', 'imagePath', 'photo', 'approved']);
    require(typeof item.id === 'string' && slug.test(item.id) && !ids.has(item.id) && item.approved === true
      && Array.isArray(item.channels) && item.channels.length > 0 && new Set(item.channels).size === item.channels.length
      && item.channels.every(id => channels.has(id)), 'Unapproved, duplicate, or unknown queue entry');
    const scheduled = instant(item.scheduledAt), approved = instant(item.approvedUntil);
    require(scheduled < approved, 'Approval must outlast the planned publication');
    keys(item.photo, ['id', 'catID', 'catName', 'credit', 'caption', 'imageFilename', 'sha256', 'width', 'height']);
    require(item.photo.id === item.id && !hashes.has(item.photo.sha256), 'Queue photo identity or bytes are duplicated');
    // Reuse the shipping catalog validator even for future and expired queue rows.
    activeFiles(photoCatalog(item.channels[0], item.photo, scheduled, Math.min(scheduled + 7 * DAY, approved)), scheduled, item.channels[0]);
    const image = await regularFile(item.imagePath, 4 * 1024 * 1024);
    require(path.basename(image.path) === item.photo.imageFilename && outside(path.dirname(image.path), target), 'Image/output path does not match the approved publisher asset');
    const bytes = image.bytes;
    require(bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216 && bytes.at(-2) === 255 && bytes.at(-1) === 217
      && createHash('sha256').update(bytes).digest('hex') === item.photo.sha256, 'Queue JPEG format or hash mismatch');
    validatePublisherJPEG(bytes, item.photo.width, item.photo.height);
    ids.add(item.id); hashes.add(item.photo.sha256);
    validated.push({ item, scheduled, approved, bytes });
  }
  // A late heartbeat still delivers only one new image across all channels.
  validated.sort((a, b) => a.scheduled - b.scheduled || (a.item.id < b.item.id ? -1 : a.item.id > b.item.id ? 1 : 0));
  let selectedID;
  for (const { item, scheduled, approved, bytes } of validated) {
    let selected = false;
    for (const channelID of item.channels) {
      const channel = channels.get(channelID), prior = channel.history.get(item.id);
      require(!prior || prior.sha256 === item.photo.sha256, 'A historical photo ID has different bytes');
      let status;
      if (prior || channel.hashes.has(item.photo.sha256)) status = 'already-published';
      else if (approved <= now) status = 'approval-expired';
      else if (!channel.catalog.enabled) status = 'paused';
      else if (scheduled > now) { status = 'scheduled'; nextTimes.push(scheduled); }
      else if (selectedID !== undefined) status = 'deferred';
      else {
        status = 'selected'; selected = true;
        const photo = { ...item.photo, publishedAt: stamp(now), expiresAt: stamp(Math.min(now + 7 * DAY, approved)) };
        const list = additions.get(channelID) ?? [];
        list.push(photo); additions.set(channelID, list);
        reasons.push({ channelID, reason: 'scheduled-photo', photoID: item.id });
      }
      rows.push({ id: item.id, channelID, status, scheduledAt: item.scheduledAt, approvedUntil: item.approvedUntil });
    }
    if (selected) { selectedID = item.id; imageBytes.set(item.photo.imageFilename, bytes); }
  }
  for (const [channelID, photos] of additions) {
    const old = channels.get(channelID).catalog.photos.filter(photo => instant(photo.expiresAt) > now);
    activeFiles({ ...channels.get(channelID).catalog, generatedAt: stamp(now), validUntil: stamp(now + 48 * HOUR),
      photos: [...old, ...photos] }, now, channelID); // Enforce the combined 60-photo limit before output.
  }
  const report = { schemaVersion: 1, checkedAt: stamp(now), reasons, queue: summary(rows, [...channels.keys()]) };
  if (!reasons.length) return { status: 'no-change', nextActionAt: stamp(Math.min(...nextTimes)), ...report };
  const earliestEdition = Math.max(...[...channels.values()].map(value => instant(value.catalog.generatedAt))) + 1000;
  if (earliestEdition > now) {
    const deferred = rows.map(row => row.status === 'selected' ? { ...row, status: 'deferred' } : row);
    return { status: 'no-change', nextActionAt: stamp(earliestEdition), deferredReason: 'edition-must-advance',
      ...report, queue: summary(deferred, [...channels.keys()]) };
  }
  // Validation is complete. Leave a failed partial output for inspection;
  // never clean it up, reuse its name, or update the deployed-bundle pointer.
  await mkdir(target);
  const extraRoot = path.join(target, 'additions');
  if (additions.size) await mkdir(extraRoot);
  const plan = { schemaVersion: 1, validForHours: 48, channels: [] };
  for (const [channelID, photos] of additions) {
    const assets = path.join(extraRoot, channelID);
    await mkdir(assets);
    for (const photo of photos) await writeFile(path.join(assets, photo.imageFilename), imageBytes.get(photo.imageFilename), { flag: 'wx' });
    const catalog = { schemaVersion: 1, channelID, enabled: true, generatedAt: stamp(now),
      validUntil: stamp(now + 48 * HOUR), photos };
    await writeFile(path.join(assets, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n', { flag: 'wx' });
    plan.channels.push({ channelID, addAssets: assets });
  }
  const result = await prepareUpdate(root, plan, path.join(target, 'update'), now);
  const next = [now + DAY, ...result.channels.flatMap(channel => channel.earliestPhotoExpiry ? [instant(channel.earliestPhotoExpiry)] : []),
    ...rows.filter(row => row.status === 'scheduled').map(row => instant(row.scheduledAt)),
    ...rows.filter(row => row.status === 'deferred').map(() => now + 1000)];
  const prepared = { status: 'candidate-prepared', bundle: result.bundle, nextActionAt: stamp(Math.min(...next)), ...report };
  await writeFile(path.join(target, 'maintenance-report.json'), JSON.stringify(prepared, null, 2) + '\n', { flag: 'wx' });
  return prepared;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { previous: { type: 'string' }, queue: { type: 'string' }, output: { type: 'string' } } });
    require(values.previous && values.queue && values.output, 'Usage: node tools/prepare_maintenance.mjs --previous <deployed-bundle> --queue <private-json> --output <new-directory>');
    console.log(JSON.stringify(await prepareMaintenance(values.previous, await jsonFile(values.queue), values.output), null, 2));
    console.log('Local candidate only. No deployment, scheduler, or pointer update was performed.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
