// Restore only the currently serving edition for a reviewed update/stop operation.
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { currentScheduledEdition, newOutput, copyEdition, expectedConfig, file, service } from './schedule_bundle.mjs';

export async function restoreCurrentEdition(bundle, output, now = Date.now(), { allowExpired = false } = {}) {
  const current = await currentScheduledEdition(bundle, now, { allowExpired });
  const target = await newOutput(output, [current.root]);
  await mkdir(target);
  await copyEdition(current.content, path.join(target, 'assets'));
  await writeFile(path.join(target, 'update-record.json'), JSON.stringify(current.record, null, 2) + '\n', { flag: 'wx' });
  await writeFile(path.join(target, 'worker.js'), await file(path.join(service, 'src/index.js')), { flag: 'wx' });
  await writeFile(path.join(target, 'wrangler.jsonc'), JSON.stringify(await expectedConfig(), null, 2) + '\n', { flag: 'wx' });
  return { bundle: target, editionID: current.selected.id, startsAt: current.selected.startsAt, endsAt: current.selected.endsAt,
    expired: current.expired,
    warning: 'Local update input only. Verify the recorded live version (and all-channel 503 before expired recovery). Never deploy this legacy bundle or treat future photos as published.' };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { bundle: { type: 'string' }, output: { type: 'string' }, 'allow-expired': { type: 'boolean', default: false } } });
    if (!values.bundle || !values.output) throw new Error('Usage: node tools/restore_schedule.mjs --bundle <scheduled-bundle> --output <new-local-directory> [--allow-expired]');
    console.log(JSON.stringify(await restoreCurrentEdition(values.bundle, values.output, Date.now(), { allowExpired: values['allow-expired'] }), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
