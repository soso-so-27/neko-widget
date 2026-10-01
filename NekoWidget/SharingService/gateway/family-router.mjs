const unavailable = () => Response.json({ error: { code: 'billing_unavailable' } }, {
  status: 503, headers: { 'cache-control': 'no-store' },
});

// The deployed family implementation remains the owner of every other route
// and every scheduled callback. This adapter never reads a photo request body.
export function createFamilyBillingRouter(family) {
  return {
    async fetch(request, env, ctx) {
      const path = new URL(request.url).pathname;
      if (/^\/v1\/billing(?:\/|$)/u.test(path)) {
        if (typeof env.PRIVATE_BILLING_GATEWAY?.fetch !== 'function') return unavailable();
        try { return await env.PRIVATE_BILLING_GATEWAY.fetch(request); }
        catch { return unavailable(); }
      }
      return family.fetch(request, env, ctx);
    },
    scheduled(controller, env, ctx) {
      return family.scheduled(controller, env, ctx);
    },
  };
}
