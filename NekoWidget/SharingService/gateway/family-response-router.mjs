// Add only the signed reporter reply reads. Every other request and schedule
// stays with the exact deployed family implementation.
export function createFamilyResponseRouter(family, readResponses) {
  return {
    fetch(request, env, ctx) {
      const path = new URL(request.url).pathname;
      if (request.method === 'GET' && (path === '/v2/reports/responses'
        || /^\/v2\/reports\/responses\/[^/]+$/u.test(path))) {
        return readResponses(request, env);
      }
      return family.fetch(request, env, ctx);
    },
    scheduled(controller, env, ctx) {
      return family.scheduled(controller, env, ctx);
    },
  };
}
