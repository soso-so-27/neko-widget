// Read-only ASC preflight. Never creates groups, testers, builds, or assignments.
import { createPrivateKey, sign } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const origin = 'https://api.appstoreconnect.apple.com';
const appID = '6801962436';
const ownerEmail = 'nakanishisoya@gmail.com';
class RecipientCheckError extends Error {}
const requireValue = (value, message) => { if (!value) throw new RecipientCheckError(message); };
// Only our fixed messages may reach logs. Fetch/JSON/crypto errors can contain
// URLs, IDs or credential material and must never be logged verbatim.
export function failureMessage(error) {
  return error instanceof RecipientCheckError ? error.message : 'ASC read or credential processing failed; details suppressed.';
}
const resourceID = value => typeof value === 'string' && /^[A-Za-z0-9-]{8,80}$/.test(value);

export async function checkRecipient({ groupID, testerID, get }) {
  requireValue(resourceID(groupID) && resourceID(testerID), 'Pinned owner group/tester IDs are required; no name-based fallback.');
  const groups = await get(`/v1/apps/${appID}/betaGroups?limit=200&fields%5BbetaGroups%5D=name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled`);
  requireValue(groups.filter(g => g.id === groupID).length === 1, 'Pinned owner group is not in the expected app.');
  for (const group of groups) {
    const a = group.attributes;
    const label = group.id === groupID ? 'Owner group' : 'Another group';
    requireValue(group.type === 'betaGroups' && a, `${label}: invalid resource or missing attributes.`);
    requireValue(typeof a.isInternalGroup === 'boolean', `${label}: isInternalGroup is missing or not boolean.`);
    requireValue(typeof a.hasAccessToAllBuilds === 'boolean', `${label}: hasAccessToAllBuilds is missing or not boolean.`);
    if (group.id === groupID) {
      requireValue(a.name === '自分用' && a.isInternalGroup === true && a.hasAccessToAllBuilds === true
        && a.publicLinkEnabled !== true, 'Owner group identity/automatic distribution changed.');
    } else {
      requireValue(a.hasAccessToAllBuilds === false, 'Another group can automatically receive this build.');
    }
  }
  const testers = await get(`/v1/betaGroups/${groupID}/betaTesters?limit=200&fields%5BbetaTesters%5D=email`);
  requireValue(testers.length === 1 && testers[0].type === 'betaTesters' && testers[0].id === testerID
    && testers[0].attributes?.email?.toLowerCase() === ownerEmail, 'Owner group must contain only the pinned owner tester.');
  return true;
}

// Deliberately excludes names, email, IDs, URLs, and untrusted field values.
export function groupDiagnostics(groups, groupID) {
  const flag = value => value === true ? 'true' : value === false ? 'false'
    : value === null ? 'null' : value === undefined ? 'missing' : 'invalid';
  return groups.map(group => `${group.id === groupID ? 'Owner group' : 'Other group'}: ` +
    `internal=${flag(group.attributes?.isInternalGroup)}, allBuilds=${flag(group.attributes?.hasAccessToAllBuilds)}, publicLink=${flag(group.attributes?.publicLinkEnabled)}`);
}

export function reader(token, fetcher = fetch) {
  return async first => {
    let url = new URL(first, origin); const result = []; const seen = new Set();
    while (url) {
      requireValue(url.origin === origin && !url.username && !url.password
        && url.pathname.startsWith('/v1/') && !seen.has(url.href) && seen.size < 50,
        'Invalid ASC pagination URL.');
      seen.add(url.href);
      const response = await fetcher(url, { method: 'GET', redirect: 'error',
        headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' }, signal: AbortSignal.timeout(15000) });
      const route = url.pathname.endsWith('/betaGroups') ? 'beta groups'
        : url.pathname.endsWith('/betaTesters') ? 'group testers' : 'pagination';
      requireValue(response.status === 200, `ASC ${route} read unavailable (HTTP ${response.status}); do not distribute.`);
      const body = await response.json();
      requireValue(Array.isArray(body.data) && body.links, 'Incomplete ASC pagination.');
      result.push(...body.data);
      requireValue(result.length <= 10000, 'ASC response exceeds recipient audit limit.');
      if (!Object.hasOwn(body.links, 'next')) {
        requireValue(Number.isSafeInteger(body.meta?.paging?.total) && body.meta.paging.total === result.length,
          'ASC final page must prove the result is complete.');
      }
      url = body.links.next == null ? null : new URL(body.links.next, origin);
    }
    requireValue(new Set(result.map(x => x.id)).size === result.length, 'Duplicate ASC resources.');
    return result;
  };
}

async function main() {
  const { OWNER_INTERNAL_GROUP_ID: groupID, OWNER_INTERNAL_TESTER_ID: testerID,
    APP_STORE_CONNECT_KEY_ID: keyID, APP_STORE_CONNECT_ISSUER_ID: issuer } = process.env;
  requireValue(resourceID(groupID) && resourceID(testerID), 'Owner recipient pins are missing; do not distribute.');
  requireValue(/^[A-Z0-9]{10}$/.test(keyID ?? '') && /^[0-9a-f-]{36}$/i.test(issuer ?? ''), 'ASC read credentials unavailable.');
  // Reuse the existing upload credential. No new credential or operational key.
  const key = createPrivateKey(await readFile(path.join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyID}.p8`)));
  requireValue(key.asymmetricKeyType === 'ec' && key.asymmetricKeyDetails?.namedCurve === 'prime256v1', 'Unexpected ASC key type.');
  const now = Math.floor(Date.now() / 1000);
  const encode = obj => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const data = encode({ alg: 'ES256', kid: keyID, typ: 'JWT' }) + '.' +
    encode({ iss: issuer, iat: now, exp: now + 300, aud: 'appstoreconnect-v1' });
  const token = data + '.' + sign('sha256', Buffer.from(data), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  const get = reader(token);
  await checkRecipient({ groupID, testerID, get: async url => {
    const resources = await get(url);
    if (new URL(url, origin).pathname.endsWith('/betaGroups')) {
      for (const line of groupDiagnostics(resources, groupID)) console.log(line);
    }
    return resources;
  } });
  console.log('PASS owner recipient: pinned group, one owner tester, exclusive automatic distribution (GET only)');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(`Owner ASC recipient verification stopped: ${failureMessage(error)} Upload is blocked; no ASC setting changed.`); process.exitCode = 1; });
}
