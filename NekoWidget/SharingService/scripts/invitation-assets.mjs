import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
export const applicationIdentifier = 'FF96XYPPH2.jp.nekowidget.app';
export const invitationPaths = ['/join', '/family-join'];
const baseHeaders = `/*
  Referrer-Policy: no-referrer
  Content-Security-Policy: default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
  X-Content-Type-Options: nosniff
/.well-known/apple-app-site-association
  Content-Type: application/json
  Cache-Control: public, max-age=300
`;

// The Git-controlled docs are the only source. The deployment contains just
// the two exact invitation paths and AASA, without business bindings.
// Inline CSS keeps every other public path unchanged. Only exact script/style
// hashes are allowed; fragments stay in the browser and connect-src stays none.
export async function prepareInvitationAssets(output) {
  const aasa = (await readFile(join(repository, 'docs/.well-known/apple-app-site-association'), 'utf8')).replace(/\r\n/g, '\n');
  const expected = {applinks:{details:[{appIDs:[applicationIdentifier],components:invitationPaths.map(path=>({'/':path}))}]}};
  if (JSON.stringify(JSON.parse(aasa)) !== JSON.stringify(expected)) throw Error('Unexpected invitation application or path');
  const css = (await readFile(join(repository, 'docs/assets/site.css'), 'utf8')).replace(/\r\n/g, '\n');
  if (/@import|url\s*\(/iu.test(css)) throw Error('Invitation CSS must not load external resources');
  const pages = await Promise.all(invitationPaths.map(async path => {
    const html = (await readFile(join(repository, 'docs', path.slice(1)+'.html'), 'utf8')).replace(/\r\n/g, '\n');
    if (!html.includes('<link rel="stylesheet" href="assets/site.css">')) throw Error('Expected shared stylesheet');
    if (/<(?:form|input|iframe|img)\b|<script[^>]+src|\bon\w+\s*=/iu.test(html)) throw Error('Unexpected active content');
    if (!html.includes('nekowidget://' + path.slice(1)) || !html.includes('app-id=6801962436')) throw Error('Invitation target missing');
    return html.replace('<link rel="stylesheet" href="assets/site.css">', '<style>' + css + '</style>');
  }));
  const hash = text => "'sha256-" + createHash('sha256').update(text).digest('base64') + "'";
  let headers = baseHeaders;
  for (let i = 0; i < pages.length; i++) {
    const hashes = tag => [...pages[i].matchAll(new RegExp('<' + tag + '>([\\s\\S]*?)</' + tag + '>', 'g'))].map(m => hash(m[1])).join(' ');
    // Override, rather than append to, the restrictive wildcard CSP.
    headers += invitationPaths[i] + "\n  Content-Type: text/html; charset=utf-8\n  ! Content-Security-Policy\n  Content-Security-Policy: default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; script-src " + hashes('script') + '; style-src ' + hashes('style') + "\n";
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
