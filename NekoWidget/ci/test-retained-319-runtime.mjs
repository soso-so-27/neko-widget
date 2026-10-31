import { test } from 'node:test';
import assert from 'node:assert/strict';
import { check } from './check-retained-319-runtime.mjs';
const env = { GROUP_WINDOWS_APPROVAL: 'YES', PRESERVATION_APPROVAL: 'YES', BILLING_APPROVAL: 'YES',
  PRESERVATION_SCOPE: 'internal', BILLING_SCOPE: 'internal' };
const now = Date.parse('2026-10-31T00:00:00Z');
function fetcher(override = {}) {
  return async (url, options) => {
    assert.equal(options.method, 'GET'); assert.equal(options.redirect, 'error'); assert.equal(options.body, undefined);
    if (url.endsWith('/reports/reserve')) return { status: 503, json: async () => ({ error: { code: 'group_reports_disabled' } }) };
    const headers = new Headers({ 'neko-runtime-media': 'ON', 'neko-runtime-apns': 'ON', 'neko-runtime-report-ingestion': 'OFF',
      'neko-runtime-billing-owner-admission': 'READY',
      'neko-runtime-billing-owner-policy-sha256': '2ba5ccdd541812f635cb17e95f4f7a91e52a8d5a9bccd088a9617d3470ee806f',
      'neko-runtime-billing-apple-notification-history-recovery': 'OFF',
      'neko-runtime-billing-apple-notification-rate-limiter': 'READY' });
    for (const suffix of ['account-bootstrap', 'account-recovery', 'apple-notification-ingestion', 'effective-entitlement',
      'subscription-reconciliation', 'transaction-ingestion', 'window-sponsorship']) headers.set('neko-runtime-billing-' + suffix, 'ON');
    for (const [key, value] of Object.entries(override)) headers.set(key, value);
    return { status: 200, headers };
  };
}
test('same seven-day policy and gates are required using GET only', async () => {
  await check({ env, now, fetcher: fetcher() });
  for (const override of [{ 'neko-runtime-billing-owner-policy-sha256': 'different' },
    { 'neko-runtime-billing-owner-admission': 'CLOSED' }, { 'neko-runtime-report-ingestion': 'ON' },
    { 'neko-runtime-billing-apple-notification-history-recovery': 'ON' }])
    await assert.rejects(check({ env, now, fetcher: fetcher(override) }));
  for (const invalid of [Date.parse('2026-10-30T00:00:00Z'), Date.parse('2026-11-06T22:19:00Z')])
    await assert.rejects(check({ env, now: invalid, fetcher: fetcher() }));
  await assert.rejects(check({ env: { ...env, BILLING_APPROVAL: 'NO' }, now, fetcher: fetcher() }));
});
