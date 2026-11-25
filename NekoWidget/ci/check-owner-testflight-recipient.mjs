// Read-only ASC preflight. Never creates groups, testers, builds, or assignments.
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const origin = 'https://api.appstoreconnect.apple.com';
const appID = '6801962436';
class RecipientCheckError extends Error {}
const requireValue = (value, message) => { if (!value) throw new RecipientCheckError(message); };
// Only our fixed messages may reach logs. Fetch/JSON/crypto errors can contain
// URLs, IDs or credential material and must never be logged verbatim.
export function failureMessage(error) {
  return error instanceof RecipientCheckError ? error.message : 'ASC read or credential processing failed; details suppressed.';
}
const resourceID = value => typeof value === 'string' && /^[A-Za-z0-9-]{8,80}$/.test(value);

function lowercaseTesterEmail(tester) {
  const email = tester.attributes?.email;
  return typeof email === 'string' ? email.toLowerCase() : undefined;
}

function recipientEmail(value) {
  const email = typeof value === 'string' ? value.trim().toLowerCase() : '';
  requireValue(email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email),
    'Owner recipient email pin is missing or invalid; do not distribute.');
  return email;
}

export async function checkRecipient({
  groupID, testerID, ownerEmail, get, authenticatedInternalOnly = false, appStoreCandidate = false,
}) {
  const expectedEmail = recipientEmail(ownerEmail);
  requireValue(resourceID(groupID) && resourceID(testerID), 'Pinned owner group/tester IDs are required; no name-based fallback.');
  // Read both independent collections before validating, so a group-shape
  // failure does not hide whether the pinned owner membership is still intact.
  const [groups, testers] = await Promise.all([
    get(`/v1/apps/${appID}/betaGroups?limit=200&fields%5BbetaGroups%5D=name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled`),
    get(`/v1/betaGroups/${groupID}/betaTesters?limit=200&fields%5BbetaTesters%5D=email`)
  ]);
  requireValue(groups.filter(g => g.id === groupID).length === 1, 'Pinned owner group is not in the expected app.');
  for (const group of groups) {
    const a = group.attributes;
    const label = group.id === groupID ? 'Owner group' : 'Another group';
    requireValue(group.type === 'betaGroups' && a, `${label}: invalid resource or missing attributes.`);
    requireValue(typeof a.isInternalGroup === 'boolean', `${label}: isInternalGroup is missing or not boolean.`);
    // External groups don't get new direct uploads automatically. ASC reports
    // null for the internal automatic-distribution setting on those groups.
    // For App Store candidates, confirm the exact resulting assignments as well.
    const excludedExternal = a.isInternalGroup === false && a.hasAccessToAllBuilds === null
      && (authenticatedInternalOnly === true || appStoreCandidate === true);
    requireValue(typeof a.hasAccessToAllBuilds === 'boolean' || excludedExternal,
      `${label}: hasAccessToAllBuilds is missing or not boolean; external null requires authenticated Internal Only IPA.`);
    if (group.id === groupID) {
      requireValue(a.name === '自分用' && a.isInternalGroup === true && a.hasAccessToAllBuilds === true
        && a.publicLinkEnabled !== true, 'Owner group identity/automatic distribution changed.');
    } else {
      requireValue(a.hasAccessToAllBuilds === false || excludedExternal, 'Another group can automatically receive this build.');
    }
  }
  requireValue(testers.length === 1 && testers[0].type === 'betaTesters' && testers[0].id === testerID
    && lowercaseTesterEmail(testers[0]) === expectedEmail, 'Owner group must contain only the pinned owner tester.');
  return true;
}

export async function verifyInternalOnlyArtifact(artifactRoot, ipaPath, authenticate = async root => {
  const ci = path.dirname(fileURLToPath(import.meta.url));
  await promisify(execFile)('python3', [path.join(ci, 'signed-artifact-authentication.py'), 'verify',
    '--ciphertext', path.join(root, 'NekoWidget-signed-artifacts.tar.gz.enc'),
    '--metadata', path.join(root, 'moderation-release-metadata.json'),
    '--authentication', path.join(root, 'signed-artifact-authentication.json')]);
}, expectedBuild) {
  requireValue(typeof artifactRoot === 'string' && typeof ipaPath === 'string', 'Authenticated artifact and IPA paths are required.');
  await authenticate(artifactRoot);
  const metadata = JSON.parse(await readFile(path.join(artifactRoot, 'moderation-release-metadata.json'), 'utf8'));
  requireValue(metadata.schema === 'jp.nekowidget.moderation-release-metadata.v4'
    && metadata.releaseEnvironment === 'testflight' && metadata.releaseMode === 'media-staging'
    && metadata.distributionProfile === 'owner-internal' && metadata.testFlightInternalTestingOnly === true
    && metadata.internalEncryptedReportEnabled === false && metadata.internalEncryptedReportScope === '',
    'Authenticated artifact must be owner-internal, Internal Only, with reports OFF.');
  requireValue(expectedBuild === undefined || String(metadata.buildNumber) === expectedBuild,
    'The confirmed build must match the authenticated artifact.');
  requireValue(/^[a-f0-9]{64}$/.test(metadata.ipaSha256 ?? '')
    && createHash('sha256').update(await readFile(ipaPath)).digest('hex') === metadata.ipaSha256,
    'Exact IPA does not match authenticated internal-only artifact.');
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
  return async (first, { single = false } = {}) => {
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
      if (single) {
        requireValue(body.data && !Array.isArray(body.data) && resourceID(body.data.id)
          && body.links && !body.links.next, 'Incomplete ASC single resource.');
        return body.data;
      }
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

export async function confirmRetainedBuild(get, groupID, number) {
  requireValue(['319', '387'].includes(number), 'Unapproved retained build number.');
  const builds = await get(`/v1/builds?filter%5Bapp%5D=${appID}&filter%5Bversion%5D=${number}&filter%5BpreReleaseVersion.platform%5D=IOS&fields%5Bbuilds%5D=version,processingState,expired,buildAudienceType&limit=200`);
  if (builds.length === 0) return false;
  requireValue(builds.length === 1 && builds[0].type === 'builds' && resourceID(builds[0].id)
    && builds[0].attributes?.version === number, `Build ${number} identity is ambiguous.`);
  const build = builds[0];
  requireValue(!['FAILED', 'INVALID'].includes(build.attributes.processingState), `Apple processing rejected build ${number}.`);
  if (build.attributes.processingState !== 'VALID') return false;
  requireValue(build.attributes.buildAudienceType === 'INTERNAL_ONLY' && build.attributes.expired === false,
    `Build ${number} must remain Internal Only and unexpired.`);
  const detail = await get(`/v1/builds/${build.id}/buildBetaDetail?fields%5BbuildBetaDetails%5D=internalBuildState`, { single: true });
  requireValue(detail.type === 'buildBetaDetails', 'Build beta detail has an unexpected type.');
  if (detail.attributes?.internalBuildState !== 'IN_BETA_TESTING') return false;
  const assigned = await get(`/v1/betaGroups/${groupID}/builds?limit=200&fields%5Bbuilds%5D=version`);
  return assigned.filter(item => item.type === 'builds' && item.id === build.id && item.attributes?.version === number).length === 1;
}

const candidateBuildNumber = number => typeof number === 'string' && /^[1-9]\d{0,5}$/.test(number);

export async function checkCandidateBuild(get, groupID, number, confirm) {
  requireValue(candidateBuildNumber(number), 'Invalid App Store candidate build number.');
  const builds = await get(
    `/v1/builds?filter%5Bapp%5D=${appID}&filter%5Bversion%5D=${number}&filter%5BpreReleaseVersion.platform%5D=IOS&include=betaGroups&fields%5Bbuilds%5D=version,processingState,expired,buildAudienceType,usesNonExemptEncryption,betaGroups&limit=200`);
  if (!confirm) {
    requireValue(builds.length === 0, 'This App Store candidate build already exists. Do not repeat the upload.');
    return true;
  }
  if (builds.length === 0) return false;
  requireValue(builds.length === 1 && builds[0].type === 'builds' && resourceID(builds[0].id)
    && builds[0].attributes?.version === number, 'App Store candidate build identity is ambiguous.');
  const { id, attributes: a } = builds[0];
  requireValue(['PROCESSING', 'VALID'].includes(a.processingState),
    'Apple processing rejected the App Store candidate.');
  if (a.processingState === 'PROCESSING') return false;
  requireValue(a.buildAudienceType === 'APP_STORE_ELIGIBLE' && a.expired === false,
    'The uploaded candidate is not eligible for the App Store.');
  const membership = builds[0].relationships?.betaGroups;
  const groups = membership?.data;
  requireValue(Array.isArray(groups) && !membership.links?.next
    && (membership.meta?.paging?.total ?? groups.length) === groups.length, 'Build group membership is incomplete.');
  const [individuals, detail] = await Promise.all([
    get(`/v1/builds/${id}/individualTesters?limit=200`),
    get(`/v1/builds/${id}/buildBetaDetail?fields%5BbuildBetaDetails%5D=internalBuildState`, { single: true }),
  ]);
  requireValue(groups.every(group => group.type === 'betaGroups' && group.id === groupID)
    && groups.length <= 1 && individuals.length === 0, 'The uploaded build has an unexpected TestFlight recipient.');
  requireValue(detail.type === 'buildBetaDetails', 'Unexpected build beta detail.');
  if (!groups.length || detail.attributes?.internalBuildState !== 'IN_BETA_TESTING') return false;
  requireValue(a.usesNonExemptEncryption === false, 'Apple export compliance needs verification in App Store Connect.');
  return true;
}

async function main() {
  const args = process.argv.slice(2);
  const productionOwner = args.length === 4 && args[0] === '--production-owner-artifact' && args[2] === '--ipa';
  const candidate = args.length === 2 && ['--app-store-candidate-preflight', '--app-store-candidate-confirm'].includes(args[0])
    && candidateBuildNumber(args[1]);
  requireValue(productionOwner || candidate || args.length === 0 || ([4, 6].includes(args.length) && args[0] === '--authenticated-artifact' && args[2] === '--ipa'
    && (args.length === 4 || (args[4] === '--confirm-build' && ['319', '387'].includes(args[5])))),
    'Expected authenticated artifact and exact IPA arguments, or read-only diagnosis without arguments.');
  let authenticatedInternalOnly = false;
  if (productionOwner) {
    await promisify(execFile)('python3', [path.join(path.dirname(fileURLToPath(import.meta.url)), 'production-owner-artifact.py'),
      'verify', '--root', args[1], '--ipa', args[3]]);
    authenticatedInternalOnly = true;
  } else if (args.length >= 4) authenticatedInternalOnly = await verifyInternalOnlyArtifact(args[1], args[3], undefined, args[5]);
  const { OWNER_INTERNAL_GROUP_ID: groupID, OWNER_INTERNAL_TESTER_ID: testerID,
    OWNER_INTERNAL_EMAIL,
    APP_STORE_CONNECT_KEY_ID: keyID, APP_STORE_CONNECT_ISSUER_ID: issuer } = process.env;
  requireValue(resourceID(groupID) && resourceID(testerID), 'Owner recipient pins are missing; do not distribute.');
  const ownerEmail = recipientEmail(OWNER_INTERNAL_EMAIL);
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
  await checkRecipient({ groupID, testerID, ownerEmail, authenticatedInternalOnly, appStoreCandidate: candidate, get: async url => {
    const resources = await get(url);
    if (new URL(url, origin).pathname.endsWith('/betaGroups')) {
      for (const line of groupDiagnostics(resources, groupID)) console.log(line);
    } else {
      console.log(`Owner membership: exactlyOne=${resources.length === 1}, pinnedTester=${resources.length === 1 && resources[0].id === testerID}, ownerEmail=${resources.length === 1 && lowercaseTesterEmail(resources[0]) === ownerEmail}`);
    }
    return resources;
  } });
  console.log('PASS owner recipient: pinned group, one owner tester, exclusive automatic distribution (GET only)');
  if (candidate) {
    const confirm = args[0] === '--app-store-candidate-confirm';
    if (await checkCandidateBuild(get, groupID, args[1], confirm)) {
      console.log(confirm
        ? `PASS build ${args[1]}: APP_STORE_ELIGIBLE, non-exempt encryption false, IN_BETA_TESTING, owner group only`
        : `PASS candidate ${args[1]}: no existing iOS build with this number`);
    } else {
      console.log(`PENDING build ${args[1]}: Apple processing or owner group assignment is not complete`);
      process.exitCode = 3;
    }
  }
  if (args.length === 6) {
    if (await confirmRetainedBuild(get, groupID, args[5])) console.log(`PASS build ${args[5]}: Internal Only, IN_BETA_TESTING, assigned to pinned owner group; confirmed ${new Date().toISOString()}`);
    else { console.log(`PENDING build ${args[5]}: Apple processing or owner group assignment is not complete`); process.exitCode = 3; }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(`Owner ASC recipient verification stopped: ${failureMessage(error)} Upload is blocked; no ASC setting changed.`); process.exitCode = 1; });
}
