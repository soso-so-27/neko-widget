import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareInvitationAssets, applicationIdentifier, policyPaths, policyFile } from '../scripts/invitation-assets.mjs';

test('packs both exact invitation paths from docs with hash-scoped active content and unchanged AASA', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'neko-invitation-'));
  const out=join(parent,'assets');
  await prepareInvitationAssets(out);
  assert.deepEqual((await readdir(out)).sort(), ['.well-known','_headers','_redirects','assets','community','family-join','guide','index.html','join','privacy','support','tokushoho']);
  for (const path of policyPaths) {
    const file = policyFile(path);
    assert.equal(await readFile(join(out,file),'utf8'), (await readFile(new URL('../../../docs/'+file,import.meta.url),'utf8')).replace(/\r\n/g,'\n'));
  }
  const redirects = await readFile(join(out,'_redirects'),'utf8');
  assert.equal(redirects, '/ /index.html 200\n/privacy/ /privacy/index.html 200\n/privacy /privacy/ 301\n/support/ /support/index.html 200\n/support /support/ 301\n/community/ /community/index.html 200\n/community /community/ 301\n/guide/ /guide/index.html 200\n/guide /guide/ 301\n/tokushoho/ /tokushoho/index.html 200\n/tokushoho /tokushoho/ 301\n');
  const aasa=JSON.parse(await readFile(join(out,'.well-known/apple-app-site-association'),'utf8'));
  assert.deepEqual(aasa.applinks.details,[{appIDs:[applicationIdentifier],components:[{'/':'/join'},{'/':'/family-join'}]}]);
  for (const path of ['join','family-join']) {
    const html=await readFile(join(out,path),'utf8');
    assert.match(html, /<meta name="referrer" content="no-referrer">/u);
    assert.match(html, /App Store で入れる/u);
    assert.match(html, /window.location.hash/u);
    assert.match(html, /https:\/\/apps\.apple\.com\/jp\/app\/id6801962436/u);
    // 11/24: no Smart App Banner; its 「開く」 would open the app without the fragment.
    assert.doesNotMatch(html, /apple-itunes-app/u);
    assert.doesNotMatch(html, /<ol\b|招待の鍵は/u);
    assert.match(html, /<a href="\/privacy\/">招待リンクと鍵の扱い<\/a>/u);
    assert.doesNotMatch(html, /<form|<iframe|fetch\(|XMLHttpRequest|sendBeacon|<link/u);
    const source = (await readFile(new URL('../../../docs/' + path + '.html', import.meta.url), 'utf8')).replace(/\r\n/g, '\n');
    const css = (await readFile(new URL('../../../docs/assets/site.css', import.meta.url), 'utf8')).replace(/\r\n/g, '\n');
    assert.equal(html, source.replace('<link rel="stylesheet" href="assets/site.css">', '<style>' + css + '</style>'));
  }
  const h=await readFile(join(out,'_headers'),'utf8');
  assert.match(h, /Content-Type: application\/json/u);
  assert.match(h, /default-src 'none'/u);
  assert.match(h, /script-src 'sha256-/u);
  assert.match(h, /style-src 'sha256-/u);
  await assert.rejects(prepareInvitationAssets(out), {code:'EEXIST'});
});
