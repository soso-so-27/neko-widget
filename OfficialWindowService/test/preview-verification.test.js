import test from 'node:test';
import assert from 'node:assert/strict';
import { deploymentVersion } from '../tools/verify_preview.mjs';

test('live deployment selection uses timestamps rather than CLI array order', () => {
  const old = { created_on: '2026-09-10T00:00:00Z', versions: [{ version_id: 'old', percentage: 100 }] };
  const recent = { created_on: '2026-09-13T00:00:00Z', versions: [{ version_id: 'current', percentage: 100 }] };
  assert.equal(deploymentVersion([old, recent]), 'current');
  assert.equal(deploymentVersion([recent, old]), 'current');
  assert.throws(() => deploymentVersion([]));
  assert.throws(() => deploymentVersion([{ ...recent, created_on: 'invalid' }]));
  assert.throws(() => deploymentVersion([{ ...recent, versions: [{ version_id: 'a', percentage: 50 }, { version_id: 'b', percentage: 50 }] }]));
});
