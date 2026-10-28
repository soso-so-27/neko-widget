// Route only the new namespace to current code. Every pre-existing request,
// environment and schedule stays with the downloaded, unchanged live module.
export function createGroupStagingRouter(legacy, group, cleanup, cleanupCron, drainGroup, drainCron, operations, drainMail) {
  return {
    fetch(request, env, ctx) {
      const path = new URL(request.url).pathname;
      const isGroup = path === '/v3/group-identities' || path.startsWith('/v3/group-identities/')
        || path === '/v3/group-windows' || path.startsWith('/v3/group-windows/');
      if (!isGroup) return legacy.fetch(request, env, ctx);
      if (env.ENVIRONMENT !== 'staging') return Response.json({error:{code:'group_runtime_disabled'}}, {status:503});
      return group.fetch(request, {...env,
        BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES', BILLING_STORE_ENVIRONMENT:'Sandbox'}, ctx);
    },
    scheduled(controller, env, ctx) {
      const existing = legacy.scheduled(controller, env, ctx);
      if (controller.cron === cleanupCron) ctx.waitUntil(cleanup(env));
      if (operations && controller.cron === cleanupCron) ctx.waitUntil(operations(env));
      if (drainGroup && controller.cron === drainCron) ctx.waitUntil(drainGroup(env));
      if (drainMail && controller.cron === drainCron) ctx.waitUntil(drainMail(env));
      return existing;
    },
  };
}
