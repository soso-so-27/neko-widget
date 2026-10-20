// Deployment alias points at the module freshly downloaded from the approved
// live version. Never recompile an unrelated replacement for legacy routes.
import legacy from 'group-staging-legacy';
export { route } from 'group-staging-legacy';
import group from '../src/index.ts';
import { runGroupRelayCleanup } from '../src/group-cleanup.ts';
import { MOMENT_CLEANUP_CRON } from '../src/scheduled.ts';
import { createGroupStagingRouter } from './group-staging-router.mjs';
export default createGroupStagingRouter(legacy, group, runGroupRelayCleanup, MOMENT_CLEANUP_CRON);
