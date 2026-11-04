import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareInvitationAssets, applicationIdentifier } from '../scripts/invitation-assets.mjs';

test('packs both exact invitation paths without secrets, redirects or active content', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'neko-invitation-'));
  const out=join(parent,'assets');
  await prepareInvitationAssets(out);
  assert.deepEqual((await readdir(out)).sort(), ['.well-known','_headers','family-join','join']);
  const aasa=JSON.parse(await readFile(join(out,'.well-known/apple-app-site-association'),'utf8'));
  assert.deepEqual(aasa.applinks.details,[{appIDs:[applicationIdentifier],components:[{'/':'/join'},{'/':'/family-join'}]}]);
  for (const path of ['join','family-join']) {
    const html=await readFile(join(out,path),'utf8');
    assert.match(html, /<meta name="referrer" content="no-referrer">/u);
    assert.match(html, /届いた招待リンクをもう一度開いてください/u);
    assert.doesNotMatch(html, /<script|<form|<iframe|location\.|fetch\(|https?:\/\//u);
  }
  const h=await readFile(join(out,'_headers'),'utf8');
  assert.match(h, /Content-Type: application\/json/u);
  assert.match(h, /default-src 'none'/u);
  await assert.rejects(prepareInvitationAssets(out), {code:'EEXIST'});
});
