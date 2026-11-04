import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
export const applicationIdentifier = 'FF96XYPPH2.jp.nekowidget.app';
export const invitationPaths = ['/join', '/family-join'];
export const headers = `/*
  Referrer-Policy: no-referrer
  Content-Security-Policy: default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
  X-Content-Type-Options: nosniff
/.well-known/apple-app-site-association
  Content-Type: application/json
  Cache-Control: public, max-age=300
/join
  Content-Type: text/html; charset=utf-8
/family-join
  Content-Type: text/html; charset=utf-8
`;

// The Git-controlled docs are the only source. The deployment contains just
// the two exact invitation paths and AASA, without business bindings or JS.
export async function prepareInvitationAssets(output) {
  const aasa = await readFile(join(repository, 'docs/.well-known/apple-app-site-association'), 'utf8');
  const expected = {applinks:{details:[{appIDs:[applicationIdentifier],components:invitationPaths.map(path=>({'/':path}))}]}};
  if (JSON.stringify(JSON.parse(aasa)) !== JSON.stringify(expected)) throw Error('Unexpected invitation application or path');
  const pages = await Promise.all(invitationPaths.map(path=>readFile(join(repository, 'docs', path.slice(1)+'.html'), 'utf8')));
  for (const html of pages) {
    if (/<(?:script|form|input|iframe|img|link)\b|\bon\w+\s*=|\b(?:src|href)\s*=/iu.test(html)) throw Error('Invitation pages must not transmit or collect invitation data');
    if (!html.includes('届いた招待リンクをもう一度開いてください。')) throw Error('Reopen-original-link guidance missing');
  }
  await mkdir(output); // Refuse existing output; never erase a prior deployment.
  await mkdir(join(output, '.well-known'));
  await writeFile(join(output, '.well-known/apple-app-site-association'), aasa);
  for (let i=0;i<pages.length;i++) await writeFile(join(output, invitationPaths[i].slice(1)), pages[i]);
  await writeFile(join(output, '_headers'), headers);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw Error('Usage: node scripts/invitation-assets.mjs NEW_OUTPUT_DIRECTORY');
  await prepareInvitationAssets(resolve(process.argv[2]));
  console.log('Prepared only /join, /family-join and AASA; no deployment performed.');
}
