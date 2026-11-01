import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { build } from 'esbuild';

// Service-binding cancellation terminates the invocation in workerd; merely
// disconnecting a Node HTTP client does not reproduce that locally.
const bundle = await build({ stdin: { contents: `
import { payloadWork } from './src/payload-work';
import { route } from './src/index';
let started = 0, finished = 0;
export default { async fetch(request, env, context) {
  const url = new URL(request.url);
  if (url.pathname === '/state') return Response.json({ started, finished });
  if (url.pathname === '/operation') return route(new Request('https://synthetic/v1/tool-metadata-batches', {
    method: 'POST', headers: { authorization: 'Bearer ' + 'x'.repeat(43), 'content-type': 'application/json' },
    body: '{}', signal: request.signal,
  }), { auth: { requireSession: async () => ({ ownerId: 'synthetic' }) },
    archive: { beginMetadataBatch: async () => {
      started++;
      await new Promise(resolve => setTimeout(resolve, 1000));
      finished++;
      if (url.searchParams.has('failure')) throw new Error('synthetic settled failure');
      return { status: 'open' };
    } },
  }, url.searchParams.has('unretained') ? undefined : context);
  try {
    const release = await payloadWork.acquire(request.signal, 80);
    release(); return new Response('entered');
  } catch (error) { return new Response(error.code, { status: error.status }); }
}}`, resolveDir: process.cwd(), sourcefile: 'payload-disconnect.ts', loader: 'ts' },
  bundle: true, write: false, format: 'esm', platform: 'browser', external: ['cloudflare:workers', 'node:*'] });
const front = `export default { async fetch(request, env) {
  const url = new URL(request.url);
  if (url.pathname === '/cancel') {
    try { return await env.BACKEND.fetch('https://synthetic/operation' + url.search,
      { signal: AbortSignal.timeout(150) }); }
    catch { return new Response('caller cancelled'); }
  }
  return env.BACKEND.fetch(request);
}}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
for (const mode of ['unretained', 'retained', 'failure']) {
  test(`cancelled invocation keeps admission until settlement: ${mode}`, async () => {
    const mf = new Miniflare(convertV4MiniflareOptions({ workers: [
      { name: 'front', modules: true, script: front, compatibilityDate: '2026-08-17',
        serviceBindings: { BACKEND: 'backend' } },
      { name: 'backend', modules: true, script: bundle.outputFiles[0].text,
        compatibilityDate: '2026-08-17', compatibilityFlags: ['nodejs_compat', 'enable_request_signal'] },
    ] }));
    try {
      const base = String(await mf.ready);
      const get = path => fetch(base + path);
      assert.equal(await (await get('cancel?' + mode)).text(), 'caller cancelled');
      assert.deepEqual(await (await get('state')).json(), { started: 1, finished: 0 });
      const held = await get('probe');
      assert.equal(held.status, 503); assert.equal(await held.text(), 'PRESERVATION_BUSY');
      await sleep(1100);
      const state = await (await get('state')).json();
      assert.deepEqual(state, { started: 1, finished: mode === 'unretained' ? 0 : 1 });
      const next = await get('probe');
      assert.equal(next.status, mode === 'unretained' ? 503 : 200);
      assert.equal(await next.text(), mode === 'unretained' ? 'PRESERVATION_BUSY' : 'entered');
    } finally { await mf.dispose(); }
  });
}
