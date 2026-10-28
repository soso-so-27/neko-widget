import { createHash } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

export const GROUP_MODERATION_BASELINE_VERSION = '75176a13-ed1d-4ff0-95dc-761f4df75d84';
const ACCOUNT = '829a34ef925a39d81b0e9e08800d7c7f';
// Approved downloaded input, not a live-state claim. The caller must separately
// verify the deployment still has this version before any eventual deployment.
const SOURCE_SHA256 = 'f4a590760ee5e7d5b1c3d0e813ed08ea41e8e5f6fe29eb42c1f3848846ae4fd8';
const BASELINE = {
  name: 'neko-window-sharing-staging', main: 'src/group-staging-entry.js',
  workers_dev: true, preview_urls: false, compatibility_date: '2026-08-17',
  triggers: {crons: ['* * * * *', '2,7,12,17,22,27,32,37,42,47,52,57 * * * *', '*/5 * * * *']},
  vars: {
    APNS_RUNTIME_ENABLED: 'YES', CHALLENGE_TTL_SECONDS: '300', ENVIRONMENT: 'staging',
    FAMILY_RECORD_RUNTIME_ENABLED: 'YES', GROUP_RUNTIME_ENABLED: 'YES',
    IDEMPOTENCY_TTL_SECONDS: '172800', INVITATION_TTL_SECONDS: '86400',
    LEGACY_SHARING_RUNTIME_ENABLED: 'NO', MOMENT_RUNTIME_ENABLED: 'YES', PENDING_TTL_SECONDS: '86400',
    REACTION_RUNTIME_ENABLED: 'YES', REPORT_INGESTION_RUNTIME_ENABLED: 'YES',
    SPACE_INACTIVITY_TTL_SECONDS: '2592000', WINDOW_NAME_RUNTIME_ENABLED: 'YES',
  },
  ratelimits: [
    {name: 'CREATE_RATE_LIMITER', namespace_id: '710001', simple: {limit: 5, period: 60}},
    {name: 'INVITE_RATE_LIMITER', namespace_id: '710002', simple: {limit: 10, period: 60}},
    {name: 'MEMBER_RATE_LIMITER', namespace_id: '710003', simple: {limit: 120, period: 60}},
  ],
  d1_databases: [{binding: 'DB', database_id: 'cb3b2386-3a6f-4253-b918-8aafed9ff735'}],
  r2_buckets: [
    {binding: 'MEDIA', bucket_name: 'neko-window-sharing-staging-media-private'},
    {binding: 'MODERATION_MEDIA', bucket_name: 'neko-window-sharing-staging-moderation-private'},
  ],
  services: [{binding: 'PRIVATE_BILLING_GATEWAY', service: 'neko-billing-gateway-staging-private',
    environment: 'production', entrypoint: 'BillingGateway'}],
};
const FAMILY = 'var family_entry_default2 = createFamilyResponseRouter(family_entry_default, readModerationResponses);';
const DEFAULT = '  group_staging_entry_default as default,';
const FOOTER = 'var group_staging_entry_default = createGroupStagingRouter(family_entry_default2, src_default, runGroupRelayCleanup, MOMENT_CLEANUP_CRON2);\n'
  + `export {\n${DEFAULT}\n  route\n};\n//# sourceMappingURL=group-staging-entry.js.map\n`;
const fail = () => { throw new Error('Approved group moderation staging baseline changed'); };

/** Pure structural transform; provenance is enforced by prepare below. The
 * old group wrapper stays in the source but is no longer the exported handler,
 * so the new wrapper schedules group cleanup once, retaining family replies. */
export function unwrapDownloadedGroupDefault(source) {
  if (typeof source !== 'string' || !source.endsWith(FOOTER)
      || source.split(FAMILY).length !== 2 || source.split(DEFAULT).length !== 2
      || source.split(FOOTER).length !== 2) fail();
  return source.slice(0, -FOOTER.length)
    + FOOTER.replace(DEFAULT, '  family_entry_default2 as default,');
}

/** Pure config preparation. Unknown settings/bindings/vars are rejected, not
 * silently dropped or accepted as a newly reviewed deployment baseline. */
export function groupModerationStagingConfigs(baseline, {projectDirectory, legacyModule, version, accountId}) {
  if (version !== GROUP_MODERATION_BASELINE_VERSION || accountId !== ACCOUNT
      || typeof projectDirectory !== 'string' || !isAbsolute(projectDirectory)
      || typeof legacyModule !== 'string' || !isAbsolute(legacyModule)) fail();
  const original = structuredClone(baseline);
  if (Object.hasOwn(original, 'account_id')) {
    if (original.account_id !== ACCOUNT) fail();
    delete original.account_id;
  }
  if (!isDeepStrictEqual(original, BASELINE)) fail();
  const base = {...structuredClone(baseline), account_id: ACCOUNT,
    main: resolve(projectDirectory, 'gateway/group-staging-entry.mjs'),
    alias: {'group-staging-legacy': resolve(legacyModule)}};
  const flags = {
    // Initial pre-report candidate only. After real reports/restrictions exist,
    // closed is not a safe rollback either: retain enforcement with stop.
    closed: ['YES', 'NO', 'NO', 'NO'],
    verification: ['YES', 'YES', 'YES', 'YES'],
    // Keep enforcement and exact-report replies alive. Rolling back to the old
    // Worker after real reports could expose content that has been restricted.
    stop: ['NO', 'NO', 'NO', 'YES'],
  };
  return Object.fromEntries(Object.entries(flags).map(([name, values]) => [name, {
    ...structuredClone(base), vars: {...base.vars, ...Object.fromEntries([
      'GROUP_RUNTIME_ENABLED', 'GROUP_REPORT_RUNTIME_ENABLED',
      'GROUP_APNS_RUNTIME_ENABLED', 'GROUP_MODERATION_RUNTIME_ENABLED',
    ].map((key, index) => [key, values[index]]))},
  }]));
}

/** No network, deployment, DB, secret reads or writes. Returns candidate data.
 * The source hash binds the full family/route bodies to the approved download. */
export function prepareGroupModerationStaging({baseline, source, ...options}) {
  const configs = groupModerationStagingConfigs(baseline, options);
  if (typeof source !== 'string' || createHash('sha256').update(source, 'utf8').digest('hex') !== SOURCE_SHA256) fail();
  return {configs, legacySource: unwrapDownloadedGroupDefault(source)};
}

// Explicit local output only. No Wrangler/API/process invocation. Existing
// output directories are refused to avoid overwriting another review candidate.
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [downloadDirectory, projectDirectory, outputDirectory, version, accountId, extra] = process.argv.slice(2);
  if (extra !== undefined || ![downloadDirectory, projectDirectory, outputDirectory].every(p => typeof p === 'string' && isAbsolute(p))) {
    throw new Error('Usage: node group-moderation-staging-config.mjs <absolute-download-dir> <absolute-project-dir> <new-absolute-output-dir> <approved-version> <approved-account>');
  }
  const legacyModule = resolve(outputDirectory, 'group-legacy-family.mjs');
  // The approved download is strict JSON even though Wrangler names it jsonc.
  const baseline = JSON.parse(await readFile(resolve(downloadDirectory, 'wrangler.jsonc'), 'utf8'));
  const source = await readFile(resolve(downloadDirectory, 'src/group-staging-entry.js'), 'utf8');
  const result = prepareGroupModerationStaging({baseline, source, projectDirectory, legacyModule, version, accountId});
  await mkdir(outputDirectory);
  await writeFile(legacyModule, result.legacySource, {flag: 'wx'});
  for (const [mode, config] of Object.entries(result.configs)) {
    await writeFile(resolve(outputDirectory, `group-moderation-${mode}.json`), JSON.stringify(config, null, 2) + '\n', {flag: 'wx'});
  }
  console.log('Prepared closed, verification and stop configs plus the family-only legacy export; no deployment.');
}
