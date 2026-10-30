// Read-only check for the exact approved seven-day build 319 recovery.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { check as reportOff } from '../SharingService/scripts/check-owner-internal-report-off.mjs';
const expiry = Date.parse('2026-11-06T22:48:45.100Z');
const expectedPolicy = '2ba5ccdd541812f635cb17e95f4f7a91e52a8d5a9bccd088a9617d3470ee806f';
export async function check({ fetcher = fetch, now = Date.now(), env = process.env } = {}) {
assert(now >= Date.parse('2026-10-30T22:48:45.100Z') && now < expiry - 30 * 60 * 1000,
  'Approved owner admission is not current or is too close to expiry');
for (const name of ['GROUP_WINDOWS_APPROVAL', 'PRESERVATION_APPROVAL', 'BILLING_APPROVAL'])
  assert.equal(env[name], 'YES', 'Existing protected approval is unavailable');
for (const name of ['PRESERVATION_SCOPE', 'BILLING_SCOPE'])
  assert.equal(env[name], 'internal', 'Existing internal scope is unavailable');
const response = await fetcher('https://neko-window-sharing-staging.nakanishisoya.workers.dev/v1/billing/health',
  { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(15000) });
assert.equal(response.status, 200, 'Billing health is unavailable');
const prefix = 'neko-runtime-billing-';
assert.equal(response.headers.get(prefix + 'owner-admission'), 'READY', 'Owner admission is not READY');
assert.equal(response.headers.get(prefix + 'owner-policy-sha256'), expectedPolicy, 'Approved owner policy changed');
for (const suffix of ['account-bootstrap', 'account-recovery', 'apple-notification-ingestion',
  'effective-entitlement', 'subscription-reconciliation', 'transaction-ingestion', 'window-sponsorship'])
  assert.equal(response.headers.get(prefix + suffix), 'ON', 'Existing billing gate is not ON');
assert.equal(response.headers.get(prefix + 'apple-notification-history-recovery'), 'OFF', 'History recovery scope changed');
assert.equal(response.headers.get(prefix + 'apple-notification-rate-limiter'), 'READY', 'Billing rate limiter is not READY');
const shared = await fetcher('https://neko-window-sharing-staging.nakanishisoya.workers.dev/health',
  { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(15000) });
assert.equal(shared.status, 200, 'Shared health unavailable');
for (const [suffix, expected] of [['media', 'ON'], ['apns', 'ON'], ['report-ingestion', 'OFF']])
  assert.equal(shared.headers.get('neko-runtime-' + suffix), expected, 'Shared runtime boundary changed');
await reportOff(fetcher);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
await check();
console.log('PASS build 319 runtime: same approved policy, admission READY, required gates ON, reports OFF, expiry 2026-11-07 07:48 JST');
}
