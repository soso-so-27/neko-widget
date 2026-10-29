import { ApiError } from './errors';
import type { Env } from './env';
import { familyNotebookAdmission } from './family-notebook-admission';
import { familyNotebookDirectory } from './family-notebook-directory';
import { familyNotebookGovernance } from './family-notebook-governance';
import { familyNotebookHistory } from './family-notebook-history';
import { familyNotebookPayer } from './family-notebook-payer';

/** No photo-room membership or operator identity crosses this boundary. Each
 * handler rechecks registered-device authentication, the family runtime gate,
 * and its transaction-specific membership/Plus/generation conditions. */
export async function familyNotebookAPI(request: Request, env: Env): Promise<Response> {
  if (env.FAMILY_NOTEBOOK_API_RUNTIME_ENABLED !== 'YES') {
    throw new ApiError(503, 'family_notebook_disabled', 'Family notebooks are unavailable.');
  }
  const { pathname: path, search } = new URL(request.url);
  if (search) throw new ApiError(400, 'invalid_request', 'Query parameters are not supported.');
  const root = '/v3/family-notebooks', method = request.method;
  if (method === 'POST' && path === root) return familyNotebookAdmission(request, env);
  if (method === 'GET' && path === root + '/me') return familyNotebookDirectory(request, env);
  const match = /^\/v3\/family-notebooks\/([0-9a-f-]+)\/(.+)$/u.exec(path);
  if (!match) throw new ApiError(404, 'not_found', 'Unknown family endpoint.');
  const family = match[1]!, action = match[2]!;
  if (method === 'GET' && ['members', 'requests', 'invitations'].includes(action)) {
    return familyNotebookDirectory(request, env);
  }
  if ((method === 'POST' && (action === 'invitations'
      || /^invitations\/[0-9a-f-]+\/(preview|join|revoke)$/u.test(action)
      || /^requests\/[0-9a-f-]+\/(approve|reject)$/u.test(action)))) {
    return familyNotebookAdmission(request, env);
  }
  if (method === 'GET' && action === 'payer') return familyNotebookPayer(request, env, family);
  if (method === 'POST' && action === 'leave') return familyNotebookPayer(request, env, family, 'leave');
  if (method === 'POST' && action === 'payer/claim') return familyNotebookPayer(request, env, family, 'claim');
  if ((method === 'GET' && action === 'payer/handover')
      || (method === 'POST' && (['payer/nominate', 'payer/accept', 'payer/cancel', 'dissolve'].includes(action)
        || /^members\/[A-Za-z0-9_-]+\/remove$/u.test(action)))) {
    return familyNotebookGovernance(request, env);
  }
  if (['GET', 'POST'].includes(method) && /^crypto\/(state|devices|rosters|keys|operations)(\/\d+)?$/u.test(action)) {
    return familyNotebookHistory(request, env);
  }
  throw new ApiError(404, 'not_found', 'Unknown family endpoint.');
}
