// Extend the live staging entry only for the notebook namespace. Existing
// photo, billing, notification and report routes keep their exact live owner.
export function createNotebookStagingRouter(legacy, notebook, cleanup, cleanupCron) {
  return {
    fetch(request, env, ctx) {
      const path=new URL(request.url).pathname;
      if (path!=='/v3/family-notebooks' && !path.startsWith('/v3/family-notebooks/')) return legacy.fetch(request,env,ctx);
      if (env.ENVIRONMENT!=='staging') return new Response(null,{status:503,headers:{'Cache-Control':'no-store'}});
      return notebook.fetch(request,{...env,BILLING_STORE_ENVIRONMENT:'Sandbox',BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES'},ctx);
    },
    scheduled(controller, env, ctx) {
      const result=legacy.scheduled(controller,env,ctx);
      if(env.ENVIRONMENT==='staging' && controller.cron===cleanupCron) ctx.waitUntil(cleanup(env));
      return result;
    },
  };
}
