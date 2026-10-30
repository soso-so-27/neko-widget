import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkRecipient, reader } from './check-owner-testflight-recipient.mjs';
import { check as checkReportOff } from '../SharingService/scripts/check-owner-internal-report-off.mjs';

const groupID = 'owner-group-id', testerID = 'owner-tester-id';
const group = { type: 'betaGroups', id: groupID, attributes: { name: '自分用', isInternalGroup: true, hasAccessToAllBuilds: true, publicLinkEnabled: false } };
const tester = { type: 'betaTesters', id: testerID, attributes: { email: 'nakanishisoya@gmail.com' } };
const run = (groups = [group], testers = [tester]) => checkRecipient({ groupID, testerID,
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
  await assert.rejects(checkRecipient({ groupID: '', testerID, get: async () => [] }));
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
