import { notifyIntakeState, type NotificationEnv } from './intake-notifications';
import { collectCosts, type CostEnv } from './intake-cost-provider';
import { renewIntake } from './intake-renewal';
export interface IntakeRenewalEnv extends CostEnv, NotificationEnv {
  ENVIRONMENT?: string; INTAKE_RENEWAL_ENABLED?: string; DB: D1Database;
}
export default {
  fetch() { return new Response(null, { status: 404, headers: { 'cache-control': 'no-store' } }); },
  async scheduled(_event: ScheduledController, env: IntakeRenewalEnv): Promise<void> {
    if (env.ENVIRONMENT !== 'production' || env.INTAKE_RENEWAL_ENABLED !== 'YES') return;
    try {
      await renewIntake(env.DB, Date.now, () => collectCosts(env, Date.now));
    } finally {
      await notifyIntakeState(env);
    }
  },
};
