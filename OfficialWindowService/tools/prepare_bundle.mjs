// Prepare a reviewable local deployment folder. Never invokes Wrangler or uploads.
import { lstat, readdir, readFile, mkdir, writeFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { parseArgs } from 'node:util';
import { activeFiles } from '../src/index.js';

const service = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function feedSetting(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.port
      || url.search || url.hash || url.pathname !== '/catalog.json') throw new Error('Use an HTTPS /catalog.json URL without credentials, port or query');
  return `// Include after the existing app configuration. Applies to both app and Widget.\nOFFICIAL_WINDOW_FEED_URL = ${url.href.replace('https://', 'https:/$()/')}\n`;
}

async function readCatalogDirectory(input, target, expectedChannel) {
  const source = path.resolve(input);
  if (source.startsWith('\\\\') || source.startsWith('//')) throw new Error('Use local paths');
  const rootInfo = await lstat(source);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw new Error('Use a regular local asset directory');
  const sourceReal = await realpath(source);
  const relative = path.relative(sourceReal, target);
  if (!relative || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))) throw new Error('Keep output outside the asset directory');
  const manifestPath = path.join(source, 'catalog.json');
  const manifestInfo = await lstat(manifestPath);
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink() || manifestInfo.size > 256 * 1024) throw new Error('Invalid catalog file');
  const catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readFile(manifestPath)));
  activeFiles(catalog, Date.now(), expectedChannel ?? catalog.channelID);
  const filenames = new Set(catalog.photos.map(photo => photo.imageFilename));
  const expected = new Set(['catalog.json', ...filenames]);
  const entries = await readdir(source);
  if (entries.length !== expected.size || entries.some(name => !expected.has(name))) throw new Error('Asset directory must contain only catalog.json and its listed JPEGs');
  const images = [];
  for (const filename of filenames) {
    const location = path.join(source, filename), info = await lstat(location);
    if (!info.isFile() || info.isSymbolicLink() || info.size < 4 || info.size > 4 * 1024 * 1024) throw new Error('Invalid JPEG file');
    const bytes = await readFile(location);
    if (`${createHash('sha256').update(bytes).digest('hex')}.jpg` !== filename
        || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes.at(-2) !== 0xff || bytes.at(-1) !== 0xd9) throw new Error('JPEG checksum or format mismatch');
    images.push([filename, bytes]);
  }
  return { catalog, images };
}

// Keep the original three-argument API and legacy root output unchanged.
export async function prepareBundle(input, output, feedURL, additionalInputs = []) {
  if (!Array.isArray(additionalInputs) || additionalInputs.some(value => typeof value !== 'string' || !value)) throw new Error('Additional assets must be local directory paths');
  const destination = path.resolve(output);
  if (destination.startsWith('\\\\') || destination.startsWith('//')) throw new Error('Use local paths');
  // Creating a fresh output is the only mutation. Never overwrite a reviewed edition.
  try { await lstat(destination); throw new Error('Output already exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const parent = await realpath(path.dirname(destination));
  const target = path.join(parent, path.basename(destination));
  const legacy = await readCatalogDirectory(input, target, 'official-cats');
  const editions = [legacy], channels = new Set(['official-cats']);
  for (const additional of additionalInputs) {
    const edition = await readCatalogDirectory(additional, target);
    if (channels.has(edition.catalog.channelID)) throw new Error('Duplicate channel or legacy channel overwrite');
    channels.add(edition.catalog.channelID);
    editions.push(edition);
  }
  const setting = feedURL === undefined ? undefined : feedSetting(feedURL);
  const config = JSON.parse(await readFile(path.join(service, 'wrangler.jsonc'), 'utf8'));
  const worker = await readFile(path.join(service, 'src/index.js'));
  delete config.$schema;
  config.main = './worker.js';
  config.assets.directory = './assets';
  // Every input has been checked before any output is created.
  await mkdir(target);
  await mkdir(path.join(target, 'assets'));
  if (additionalInputs.length) await mkdir(path.join(target, 'assets/windows'));
  for (const { catalog, images } of editions) {
    const directory = catalog.channelID === 'official-cats'
      ? path.join(target, 'assets') : path.join(target, 'assets/windows', catalog.channelID);
    if (catalog.channelID !== 'official-cats') await mkdir(directory);
    for (const [filename, bytes] of images) await writeFile(path.join(directory, filename), bytes, { flag: 'wx' });
    await writeFile(path.join(directory, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n', { flag: 'wx' });
  }
  await writeFile(path.join(target, 'worker.js'), worker, { flag: 'wx' });
  await writeFile(path.join(target, 'wrangler.jsonc'), JSON.stringify(config, null, 2) + '\n', { flag: 'wx' });
  if (setting) await writeFile(path.join(target, 'OfficialWindow.xcconfig'), setting, { flag: 'wx' });
  const { catalog } = legacy;
  const result = { directory: target, photos: catalog.photos.length, enabled: catalog.enabled, generatedAt: catalog.generatedAt, validUntil: catalog.validUntil };
  if (additionalInputs.length) result.additionalChannels = editions.slice(1).map(({ catalog: value }) => ({ channelID: value.channelID, photos: value.photos.length, enabled: value.enabled, validUntil: value.validUntil }));
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { assets: { type: 'string' }, output: { type: 'string' }, 'feed-url': { type: 'string' }, 'additional-assets': { type: 'string', multiple: true } } });
    if (!values.assets || !values.output) throw new Error('Usage: node tools/prepare_bundle.mjs --assets <legacy-catalog-dir> --output <new-dir> [--additional-assets <channel-dir>]... [--feed-url <https-url>]');
    console.log(JSON.stringify(await prepareBundle(values.assets, values.output, values['feed-url'], values['additional-assets']), null, 2));
    console.log('Local bundle prepared. Nothing was uploaded or deployed.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
