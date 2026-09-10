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

export async function prepareBundle(input, output, feedURL) {
  const source = path.resolve(input), destination = path.resolve(output);
  if ([source, destination].some(value => value.startsWith('\\\\') || value.startsWith('//'))) throw new Error('Use local paths');
  const rootInfo = await lstat(source);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw new Error('Use a regular local asset directory');
  // Creating a fresh output is the only mutation. Never overwrite a reviewed edition.
  try { await lstat(destination); throw new Error('Output already exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const parent = await realpath(path.dirname(destination));
  const target = path.join(parent, path.basename(destination));
  const sourceReal = await realpath(source);
  const relative = path.relative(sourceReal, target);
  if (!relative || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))) throw new Error('Keep output outside the asset directory');
  const manifestPath = path.join(source, 'catalog.json');
  const manifestInfo = await lstat(manifestPath);
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink() || manifestInfo.size > 256 * 1024) throw new Error('Invalid catalog file');
  const catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readFile(manifestPath)));
  activeFiles(catalog);
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
  const setting = feedURL === undefined ? undefined : feedSetting(feedURL);
  const config = JSON.parse(await readFile(path.join(service, 'wrangler.jsonc'), 'utf8'));
  const worker = await readFile(path.join(service, 'src/index.js'));
  delete config.$schema;
  config.main = './worker.js';
  config.assets.directory = './assets';
  // Every input has been checked before any output is created.
  await mkdir(target);
  await mkdir(path.join(target, 'assets'));
  for (const [filename, bytes] of images) await writeFile(path.join(target, 'assets', filename), bytes, { flag: 'wx' });
  await writeFile(path.join(target, 'assets/catalog.json'), JSON.stringify(catalog, null, 2) + '\n', { flag: 'wx' });
  await writeFile(path.join(target, 'worker.js'), worker, { flag: 'wx' });
  await writeFile(path.join(target, 'wrangler.jsonc'), JSON.stringify(config, null, 2) + '\n', { flag: 'wx' });
  if (setting) await writeFile(path.join(target, 'OfficialWindow.xcconfig'), setting, { flag: 'wx' });
  return { directory: target, photos: catalog.photos.length, enabled: catalog.enabled, generatedAt: catalog.generatedAt, validUntil: catalog.validUntil };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { assets: { type: 'string' }, output: { type: 'string' }, 'feed-url': { type: 'string' } } });
    if (!values.assets || !values.output) throw new Error('Usage: node tools/prepare_bundle.mjs --assets <catalog-dir> --output <new-dir> [--feed-url <https-url>]');
    console.log(JSON.stringify(await prepareBundle(values.assets, values.output, values['feed-url']), null, 2));
    console.log('Local bundle prepared. Nothing was uploaded or deployed.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
