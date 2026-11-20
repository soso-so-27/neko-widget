import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkRecipient, reader, failureMessage, groupDiagnostics, verifyInternalOnlyArtifact, confirmRetainedBuild } from './check-owner-testflight-recipient.mjs';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { check as checkReportOff } from '../SharingService/scripts/check-owner-internal-report-off.mjs';

const groupID = 'owner-group-id', testerID = 'owner-tester-id';
const group = { type: 'betaGroups', id: groupID, attributes: { name: '自分用', isInternalGroup: true, hasAccessToAllBuilds: true, publicLinkEnabled: false } };
const ownerEmail = 'synthetic-owner@example.invalid';
const tester = { type: 'betaTesters', id: testerID, attributes: { email: ownerEmail } };
const run = (groups = [group], testers = [tester]) => checkRecipient({ groupID, testerID, ownerEmail,
  get: async url => url.includes('/betaTesters') ? testers : groups });

test('pinned sole owner; no name-only fallback or additional automatic recipients', async () => {
  assert.equal(await run(), true);
  for (const groups of [[], [{ ...group, id: 'wrong-group' }],
    [{ ...group, attributes: { ...group.attributes, hasAccessToAllBuilds: false } }],
    [group, { ...group, id: 'other-group' }],
    [{ ...group, attributes: { ...group.attributes, isInternalGroup: false } }]]) {
    await assert.rejects(run(groups));
  }
  for (const testers of [[], [tester, { ...tester, id: 'another-person' }],
    [{ ...tester, attributes: { email: 'wrong@example.com' } }]]) await assert.rejects(run([group], testers));
  await assert.rejects(checkRecipient({ groupID: '', testerID, ownerEmail, get: async () => [] }));
});

test('owner email pin is required before querying Apple and is never logged', async () => {
  let contactedApple = false;
  const get = async () => { contactedApple = true; return []; };
  for (const badPin of [undefined, '', 'not-an-address']) {
    await assert.rejects(checkRecipient({ groupID, testerID, ownerEmail: badPin, get }),
      { message: 'Owner recipient email pin is missing or invalid; do not distribute.' });
  }
  assert.equal(contactedApple, false);
  for (const email of [null, 5, 'other@example.invalid']) {
    await assert.rejects(run([group], [{ ...tester, attributes: { email } }]),
      { message: 'Owner group must contain only the pinned owner tester.' });
  }
  assert.equal(await run([group], [{ ...tester, attributes: { email: ownerEmail.toUpperCase() } }]), true);
});

test('GET-only reader follows bounded same-origin pages and fails on unavailable data', async () => {
  const requests = [];
  const get = reader('synthetic-not-a-credential', async (url, options) => {
    requests.push([url, options]);
    return { status: 200, json: async () => ({ data: [{ id: String(requests.length) }],
      links: { next: requests.length === 1 ? '/v1/example?page=2' : null } }) };
  });
  assert.equal((await get('/v1/example')).length, 2);
  assert.ok(requests.every(([, o]) => o.method === 'GET' && o.redirect === 'error' && !o.body));
  for (const status of [401, 403, 500]) await assert.rejects(reader('test', async () => ({ status }))('/v1/example'));
  await assert.rejects(reader('test', async () => ({ status: 200, json: async () => ({ data: [], links: { next: 'https://wrong.example/v1/x' } }) }))('/v1/example'));
});

test('report OFF is observed, never set; ON and unknown stop release', async () => {
  const fake = body => async (_, options) => {
    assert.equal(options.method, 'GET'); assert.equal(options.body, undefined);
    return { status: 503, json: async () => body };
  };
  await checkReportOff(fake({ error: { code: 'group_reports_disabled' } }));
  await assert.rejects(checkReportOff(fake({ protocolVersion: 3, reportingAvailable: true })));
  await assert.rejects(checkReportOff(fake({ protocolVersion: 3 })));
});

test('failure diagnostics identify the boundary without printing IDs, responses or credentials', async () => {
  const secret = 'synthetic-private-token-and-owner-id';
  assert.equal(failureMessage(new Error(secret)), 'ASC read or credential processing failed; details suppressed.');
  try { await reader(secret, async () => ({ status: 403 }))('/v1/apps/private-id/betaGroups'); }
  catch (error) {
    assert.equal(failureMessage(error), 'ASC beta groups read unavailable (HTTP 403); do not distribute.');
    assert.ok(!failureMessage(error).includes(secret));
    assert.ok(!failureMessage(error).includes('private-id'));
  }
  await assert.rejects(run([]), error => failureMessage(error) === 'Pinned owner group is not in the expected app.');
});

test('explicit ASC fields are requested and incomplete booleans still block upload', async () => {
  await checkRecipient({ groupID, testerID, ownerEmail, get: async url => {
    const query = new URL(url, 'https://api.appstoreconnect.apple.com').searchParams;
    if (url.includes('/betaTesters')) {
      assert.equal(query.get('fields[betaTesters]'), 'email');
      return [tester];
    }
    assert.equal(query.get('fields[betaGroups]'), 'name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled');
    return [group];
  } });
  for (const field of ['isInternalGroup', 'hasAccessToAllBuilds']) {
    for (const value of [null, undefined, 'true', 1]) {
      await assert.rejects(run([{ ...group, attributes: { ...group.attributes, [field]: value } }]),
        error => failureMessage(error).startsWith(`Owner group: ${field} is missing or not boolean`));
    }
  }
  const privateValue = 'private-identifier-or-address';
  assert.deepEqual(groupDiagnostics([{ id: privateValue, attributes: {
    name: privateValue, isInternalGroup: true, hasAccessToAllBuilds: privateValue, publicLinkEnabled: null
  } }], groupID), ['Other group: internal=true, allBuilds=invalid, publicLink=null']);
});

test('observed external null is excluded only for an authenticated internal-only IPA', async () => {
  const external = { type: 'betaGroups', id: 'external-group', attributes: { isInternalGroup: false, hasAccessToAllBuilds: null } };
  const check = (other = external, proof = true) => checkRecipient({ groupID, testerID, ownerEmail,
    authenticatedInternalOnly: proof, get: async url => url.includes('/betaTesters') ? [tester] : [group, other] });
  assert.equal(await check(), true);
  await assert.rejects(check(external, false));
  for (const patch of [{ isInternalGroup: true }, { isInternalGroup: null },
    { hasAccessToAllBuilds: undefined }, { hasAccessToAllBuilds: true }, { hasAccessToAllBuilds: 'false' }]) {
    await assert.rejects(check({ ...external, attributes: { ...external.attributes, ...patch } }));
  }
  await assert.rejects(checkRecipient({ groupID, testerID, ownerEmail, authenticatedInternalOnly: true,
    get: async url => url.includes('/betaTesters') ? [tester] : [{ ...group, attributes: { ...group.attributes, hasAccessToAllBuilds: null } }] }));
});

test('internal-only evidence is authenticated first and bound to the exact uploaded bytes', async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'neko-recipient-test-'));
  assert.equal(path.dirname(root), path.resolve(tmpdir()));
  t.after(() => rm(root, { recursive: true, force: true }));
  const ipa = path.join(root, 'synthetic.ipa');
  const payload = Buffer.from('synthetic-ipa');
  const metadata = { schema: 'jp.nekowidget.moderation-release-metadata.v4', distributionProfile: 'owner-internal',
    releaseEnvironment: 'testflight', releaseMode: 'media-staging',
    testFlightInternalTestingOnly: true, internalEncryptedReportEnabled: false, internalEncryptedReportScope: '',
    ipaSha256: createHash('sha256').update(payload).digest('hex') };
  let authenticated = false;
  const authenticate = async directory => { assert.equal(directory, root); authenticated = true; };
  await writeFile(ipa, payload);
  const save = value => writeFile(path.join(root, 'moderation-release-metadata.json'), JSON.stringify(value));
  await save(metadata);
  assert.equal(await verifyInternalOnlyArtifact(root, ipa, authenticate), true);
  assert.equal(authenticated, true);
  for (const patch of [{ testFlightInternalTestingOnly: false }, { distributionProfile: 'existing-reviewed' },
    { releaseMode: 'disabled' }, { releaseEnvironment: 'production' },
    { internalEncryptedReportEnabled: true }, { internalEncryptedReportScope: 'unexpected' }, { ipaSha256: '0'.repeat(64) }]) {
    await save({ ...metadata, ...patch });
    await assert.rejects(verifyInternalOnlyArtifact(root, ipa, authenticate));
  }
  await save({...metadata, buildNumber:'387'});
  assert.equal(await verifyInternalOnlyArtifact(root, ipa, authenticate, '387'), true);
  await assert.rejects(verifyInternalOnlyArtifact(root, ipa, authenticate, '319'), /match the authenticated artifact/);
  await save(metadata);
  await assert.rejects(verifyInternalOnlyArtifact(root, ipa, async () => { throw Error('authentication failed'); }), /authentication failed/);
  await writeFile(ipa, 'different bytes');
  await assert.rejects(verifyInternalOnlyArtifact(root, ipa, authenticate));
});

test('delivery requires valid Internal Only build, IN_BETA_TESTING and pinned group assignment', async () => {
  const build = { type: 'builds', id: 'synthetic-build', attributes: {
    version: '319', processingState: 'VALID', buildAudienceType: 'INTERNAL_ONLY', expired: false } };
  const get = (patch = {}, state = 'IN_BETA_TESTING', assigned = true) => async (url, options) => {
    if (url.includes('/buildBetaDetail?')) {
      assert.equal(options.single, true);
      return { type: 'buildBetaDetails', attributes: { internalBuildState: state } };
    }
    const current = { ...build, attributes: { ...build.attributes, ...patch } };
    if (url.includes('/betaGroups/')) return assigned ? [current] : [];
    return [current];
  };
  assert.equal(await confirmRetainedBuild(get(), groupID, '319'), true);
  assert.equal(await confirmRetainedBuild(get({version:'387'}), groupID, '387'), true);
  await assert.rejects(confirmRetainedBuild(get(), groupID, '387'), /identity is ambiguous/);
  await assert.rejects(confirmRetainedBuild(get(), groupID, '388'), /Unapproved retained build number/);
  assert.equal(await confirmRetainedBuild(async () => [], groupID, '319'), false);
  assert.equal(await confirmRetainedBuild(get({}, 'READY_FOR_BETA_TESTING'), groupID, '319'), false);
  assert.equal(await confirmRetainedBuild(get({}, 'IN_BETA_TESTING', false), groupID, '319'), false);
  for (const patch of [{ processingState: 'INVALID' }, { buildAudienceType: 'APP_STORE_ELIGIBLE' }, { expired: true }])
    await assert.rejects(confirmRetainedBuild(get(patch), groupID, '319'));
  const one = { type: 'buildBetaDetails', id: 'synthetic-detail', attributes: {} };
  assert.deepEqual(await reader('synthetic', async () => ({ status: 200, json: async () => ({ data: one, links: {} }) }))('/v1/example', { single: true }), one);
  await assert.rejects(reader('synthetic', async () => ({ status: 200, json: async () => ({ data: [], links: {} }) }))('/v1/example', { single: true }));
});
