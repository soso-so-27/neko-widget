// A separate entry point for the reviewed production installation. Initial
// enrollment still happens locally; signed scope adoption and current Windows
// key custody are required by the common host before opening its listener.
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {main as startOwner,validateStagingOwnerConfig} from './moderation-operator-staging-start.mjs';

export function validateProductionOwnerConfig(value){
 if(value?.mode!=='owner-production')throw Error('invalid_production_owner_config');
 return validateStagingOwnerConfig(value);
}
export async function main(args){
 if(args.length!==3||args[0]!=='--config'||!path.isAbsolute(args[1])||!['--check','--serve'].includes(args[2]))throw Error('invalid_production_owner_arguments');
 validateProductionOwnerConfig(JSON.parse(await readFile(args[1],'utf8')));
 return startOwner(args,'owner-production');
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main(process.argv.slice(2)).catch(()=>{console.error('owner_production_startup_failed');process.exitCode=1});
