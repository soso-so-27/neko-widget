import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { clientUpgradeResponse } from '../../ServiceProtocol/client-upgrade-required.ts';

const request = build => new Request('https://service.example/v3/group-windows', {
  headers: build === undefined ? {} : { 'X-Neko-App-Build': build }
});
test('absent/OFF/misspelled policy leaves every existing response unchanged', () => {
  for (const enabled of [undefined, 'NO', 'yes', ' YES']) {
    assert.equal(clientUpgradeResponse(request('355'), {
      CLIENT_UPGRADE_REQUIRED_ENABLED: enabled, MINIMUM_SUPPORTED_IOS_BUILD: '356'
    }), null);
  }
});
test('old iOS build receives only the fixed, non-cacheable upgrade response', async () => {
  const response = clientUpgradeResponse(request('355'), {
    CLIENT_UPGRADE_REQUIRED_ENABLED: 'YES', MINIMUM_SUPPORTED_IOS_BUILD: '356'
  });
  assert.equal(response.status, 426);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(await response.json(), { error: { code: 'CLIENT_UPGRADE_REQUIRED' } });
});
test('current/newer builds, Apple/service calls, invalid minimum do not change behavior', () => {
  const policy = { CLIENT_UPGRADE_REQUIRED_ENABLED: 'YES', MINIMUM_SUPPORTED_IOS_BUILD: '356' };
  for (const build of ['356', '357', undefined, 'invalid', '-1']) {
    assert.equal(clientUpgradeResponse(request(build), policy), null);
  }
  for (const minimum of [undefined, '0', '-1', 'latest', '9999999999']) {
    assert.equal(clientUpgradeResponse(request('355'), { ...policy, MINIMUM_SUPPORTED_IOS_BUILD: minimum }), null);
  }
});
test('both real Worker fetch boundaries use the same policy; operational flag remains absent', () => {
  for (const file of ['src/index.ts', '../PreservationService/src/index.ts']) {
    assert.match(readFileSync(new URL('../' + file, import.meta.url), 'utf8'),
      /const upgrade = clientUpgradeResponse\(request, env\);\s*if \(upgrade\) return upgrade;/);
  }
});
