import family from './family-v6-frozen.mjs';
import { createFamilyResponseRouter } from './family-response-router.mjs';
import { readModerationResponses } from '../src/moderation-response-entry.ts';
export { route } from './family-v6-frozen.mjs';
export default createFamilyResponseRouter(family, readModerationResponses);
