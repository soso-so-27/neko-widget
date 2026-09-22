/**
 * Separate offline contract run, deliberately outside test/*.test.mjs:
 * node test/test-adapter.mjs --source <PreservationService/src>
 * Run the provider build first. A missing source is an error, never a skip.
 *
 * Test-only transformation: transpile the actual contracts/documents/providers
 * files with TypeScript (type erasure, not type checking), rewriting only their
 * known relative static imports to temporary .mjs modules. No adapter function,
 * response, error or timeout is replaced. Nothing is copied into product src.
 * Fetcher is bridged to the real local provider; cancellation is injected into
 * that bridge, combined with the adapter's original timeout signal.
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import ts from 'typescript';
import { createImageValidator } from '../dist/provider.js';
import { jpeg, request, truncateEntropy } from './fixtures.mjs';

const { values } = parseArgs({ options: { source: { type: 'string' } }, strict: true, allowPositionals: false });
if (!values.source) throw new Error('Required: --source <PreservationService/src>; this run cannot skip.');
assert.ok(Number(process.versions.node.split('.')[0]) >= 22, 'Node 22 or newer is required.');
const sourceDirectory = await realpath(path.resolve(values.source));
const moduleNames = ['contracts', 'documents', 'providers'];
const originals = new Map(await Promise.all(moduleNames.map(async (name) => [name,
  await readFile(path.join(sourceDirectory, `${name}.ts`))])));
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

// This transform is intentionally closed: an expanded production dependency
// graph requires review instead of silently executing additional source files.
const temporaryImports = (context) => {
  const visit = (node) => {
    if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword
      || (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
      throw new Error('Dynamic imports/require are outside this test transformation.');
    }
    if (ts.isImportDeclaration(node) || (ts.isExportDeclaration(node) && node.moduleSpecifier)) {
      const specifier = node.moduleSpecifier;
      assert.ok(ts.isStringLiteral(specifier), 'Only literal static imports are supported.');
      const match = /^\.\/(contracts|documents|providers)(?:\.js)?$/.exec(specifier.text);
      assert.ok(match, `Unreviewed adapter dependency: ${specifier.text}`);
      const replacement = ts.factory.createStringLiteral(`./${match[1]}.mjs`);
      return ts.isImportDeclaration(node)
        ? ts.factory.updateImportDeclaration(node, node.modifiers, node.importClause, replacement, node.attributes)
        : ts.factory.updateExportDeclaration(node, node.modifiers, node.isTypeOnly, node.exportClause, replacement, node.attributes);
    }
    return ts.visitEachChild(node, visit, context);
  };
  return (file) => ts.visitNode(file, visit);
};

const temporaryRoot = await realpath(tmpdir());
const prefix = 'neko-adapter-contract-';
const temporaryDirectory = await realpath(await mkdtemp(path.join(temporaryRoot, prefix)));
const started = performance.now();
const originalFetch = globalThis.fetch;
globalThis.fetch = async () => { throw new Error('External fetch is forbidden in this offline contract run.'); };
try {
  for (const [name, original] of originals) {
    const result = ts.transpileModule(original.toString('utf8'), {
      fileName: `${name}.ts`, reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
      transformers: { before: [temporaryImports] },
    });
    assert.equal(result.diagnostics?.filter((item) => item.category === ts.DiagnosticCategory.Error).length, 0,
      `Cannot transpile ${name}.ts`);
    await writeFile(path.join(temporaryDirectory, `${name}.mjs`), result.outputText);
  }
  const { boundPhotoValidator } = await import(pathToFileURL(path.join(temporaryDirectory, 'providers.mjs')).href);
  const { ServiceError } = await import(pathToFileURL(path.join(temporaryDirectory, 'contracts.mjs')).href);
  const photo = await jpeg();
  const unchangedPhoto = digest(photo);

  function connect(getProvider, getCancellation = () => undefined) {
    const calls = [];
    const statuses = [];
    const binding = { async fetch(url, init) {
      assert.equal(url, 'https://preservation-internal/images/validate-jpeg');
      assert.equal(init.method, 'POST');
      assert.equal(init.redirect, 'error');
      assert.ok(init.signal instanceof AbortSignal);
      calls.push(init.body);
      const cancellation = getCancellation();
      const signal = cancellation ? AbortSignal.any([init.signal, cancellation]) : init.signal;
      const response = await getProvider().fetch(new Request(url, { ...init, signal }));
      statuses.push(response.status);
      return response;
    } };
    return { adapter: boundPhotoValidator(binding), calls, statuses };
  }
  const unavailable = (error) => error instanceof ServiceError
    && error.status === 503 && error.code === 'DEPENDENCY_UNAVAILABLE';

  await test('actual adapter accepts the real provider JPEG response without changing bytes', async () => {
    const provider = createImageValidator({ enabled: true });
    const { adapter, calls, statuses } = connect(() => provider);
    assert.equal(await adapter.validateJPEG(photo), true);
    assert.deepEqual(JSON.parse(calls[0]), { photoBase64: photo.toString('base64') });
    assert.deepEqual(statuses, [200]);
    assert.equal(digest(photo), unchangedPhoto);
  });

  await test('entropy truncation is false, not success or an availability error', async () => {
    const provider = createImageValidator({ enabled: true });
    const { adapter, statuses } = connect(() => provider);
    assert.equal(await adapter.validateJPEG(truncateEntropy(photo)), false);
    assert.deepEqual(statuses, [200]);
  });

  await test('disabled provider rejects with 503; identical input succeeds after activation', async () => {
    let provider = createImageValidator();
    const { adapter, calls, statuses } = connect(() => provider);
    await assert.rejects(adapter.validateJPEG(photo), unavailable);
    provider = createImageValidator({ enabled: true });
    assert.equal(await adapter.validateJPEG(photo), true);
    assert.deepEqual(statuses, [503, 200]);
    assert.equal(calls[0], calls[1]);
  });

  await test('in-flight cancellation rejects with 503; identical input can retry', async () => {
    const provider = createImageValidator({ enabled: true });
    let controller = new AbortController();
    const { adapter, calls, statuses } = connect(() => provider, () => controller.signal);
    const pending = adapter.validateJPEG(photo);
    controller.abort();
    await assert.rejects(pending, unavailable);
    controller = new AbortController();
    assert.equal(await adapter.validateJPEG(photo), true);
    assert.deepEqual(statuses, [503, 200]);
    assert.equal(calls[0], calls[1]);
  });

  await test('real provider overload rejects with 503 and releases capacity for identical retry', async () => {
    const provider = createImageValidator({ enabled: true });
    const controller = new AbortController();
    const held = provider.fetch(request(photo, {
      body: new ReadableStream({ start() {} }), duplex: 'half', signal: controller.signal,
    }));
    const { adapter, calls, statuses } = connect(() => provider);
    try {
      await assert.rejects(adapter.validateJPEG(photo), unavailable);
    } finally {
      controller.abort();
      assert.equal((await held).status, 503);
    }
    assert.equal(await adapter.validateJPEG(photo), true);
    assert.deepEqual(statuses, [503, 200]);
    assert.equal(calls[0], calls[1]);
  });

  await test('the three actual TypeScript input files remain byte-identical', async () => {
    for (const [name, original] of originals) {
      assert.equal(digest(await readFile(path.join(sourceDirectory, `${name}.ts`))), digest(original), `${name}.ts changed`);
    }
  });
} finally {
  globalThis.fetch = originalFetch;
  // Remove only this run's mkdtemp output, after checking its resolved absolute
  // path is a direct child of the resolved temp root with our dedicated prefix.
  const resolved = await realpath(temporaryDirectory);
  assert.ok(path.isAbsolute(resolved));
  assert.equal(resolved, temporaryDirectory);
  assert.equal(path.dirname(resolved), temporaryRoot);
  assert.ok(path.basename(resolved).startsWith(prefix));
  await rm(resolved, { recursive: true, force: false });
  console.log(`Offline adapter contract elapsed: ${((performance.now() - started) / 1000).toFixed(3)}s; temporary output removed.`);
}
