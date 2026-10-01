import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createFamilyBillingRouter } from './family-router.mjs';

test('photo, family, health and near-match routes retain the original request, context and response', async () => {
  for (const path of ['/v1/moments', '/v1/family-records', '/health', '/v1/billing-other', '/v1/%62illing/accounts']) {
    const request = new Request('https://sharing.test' + path, { method: 'POST', body: 'unchanged-photo-body' });
    const env = { PRIVATE_BILLING_GATEWAY: { fetch() { assert.fail('Wrong recipient'); } } };
    const ctx = {};
    const response = new Response('family response', { headers: { 'x-neko-media-enabled': 'YES' } });
    const family = { async fetch(r, e, c) {
      assert.equal(r, request); assert.equal(e, env); assert.equal(c, ctx);
      assert.equal(await r.text(), 'unchanged-photo-body'); return response;
    } };
    assert.equal(await createFamilyBillingRouter(family).fetch(request, env, ctx), response);
  }
});

test('billing routes pass their unconsumed request only to the private gateway', async () => {
  for (const path of ['/v1/billing/accounts', '/v1/billing/transactions', '/v1/billing']) {
    const request = new Request('https://sharing.test' + path, { method: 'POST', body: 'signed-billing-body' });
    const response = new Response('private response', { status: 403 });
    const gateway = { async fetch(r) { assert.equal(r, request); assert.equal(await r.text(), 'signed-billing-body'); return response; } };
    const family = { fetch() { assert.fail('Billing must not fall through to family'); } };
    assert.equal(await createFamilyBillingRouter(family).fetch(request, { PRIVATE_BILLING_GATEWAY: gateway }, {}), response);
  }
});

test('absent or failed private binding rejects billing without executing family', async () => {
  const family = { fetch() { assert.fail('No fallback'); } };
  for (const env of [{}, { PRIVATE_BILLING_GATEWAY: { fetch() { throw new Error('unavailable'); } } }]) {
    const response = await createFamilyBillingRouter(family).fetch(new Request('https://sharing.test/v1/billing/transactions'), env, {});
    assert.equal(response.status, 503); assert.equal(response.headers.get('cache-control'), 'no-store');
  }
});

test('all schedules remain with the deployed family implementation', () => {
  const controller = {}, env = {}, ctx = {}, result = {};
  const family = { scheduled(c, e, x) { assert.equal(c, controller); assert.equal(e, env); assert.equal(x, ctx); return result; } };
  assert.equal(createFamilyBillingRouter(family).scheduled(controller, env, ctx), result);
});
