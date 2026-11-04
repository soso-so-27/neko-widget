// Deployment must pin this alias to the downloaded, verified live module.
import legacy from 'notebook-staging-legacy';
export { route } from 'notebook-staging-legacy';
import notebook from '../src/index.ts';
import { cleanupDissolvedFamilyRosters } from '../src/family-notebook-roster-cleanup.ts';
import { MOMENT_CLEANUP_CRON } from '../src/scheduled.ts';
import { createNotebookStagingRouter } from './notebook-staging-router.mjs';
export default createNotebookStagingRouter(legacy,notebook,cleanupDissolvedFamilyRosters,MOMENT_CLEANUP_CRON);
