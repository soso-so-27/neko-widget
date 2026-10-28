import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { GROUP_MODERATION_BASELINE_VERSION, groupModerationStagingConfigs,
  prepareGroupModerationStaging, unwrapDownloadedGroupDefault } from './group-moderation-staging-config.mjs';

const projectDirectory = fileURLToPath(new URL('../', import.meta.url));
const options = {projectDirectory, legacyModule: resolve(projectDirectory, 'test-only-legacy.mjs'),
  version: GROUP_MODERATION_BASELINE_VERSION, accountId: '829a34ef925a39d81b0e9e08800d7c7f'};
function baseline() {
  return {name: 'neko-window-sharing-staging', main: 'src/group-staging-entry.js', workers_dev: true, preview_urls: false,
    compatibility_date: '2026-08-17', triggers: {crons: ['* * * * *', '2,7,12,17,22,27,32,37,42,47,52,57 * * * *', '*/5 * * * *']},
    vars: {APNS_RUNTIME_ENABLED:'YES', CHALLENGE_TTL_SECONDS:'300', ENVIRONMENT:'staging', FAMILY_RECORD_RUNTIME_ENABLED:'YES',
      GROUP_RUNTIME_ENABLED:'YES', IDEMPOTENCY_TTL_SECONDS:'172800', INVITATION_TTL_SECONDS:'86400', LEGACY_SHARING_RUNTIME_ENABLED:'NO',
      MOMENT_RUNTIME_ENABLED:'YES', PENDING_TTL_SECONDS:'86400', REACTION_RUNTIME_ENABLED:'YES', REPORT_INGESTION_RUNTIME_ENABLED:'YES',
      SPACE_INACTIVITY_TTL_SECONDS:'2592000', WINDOW_NAME_RUNTIME_ENABLED:'YES'},
    ratelimits: [{name:'CREATE_RATE_LIMITER',namespace_id:'710001',simple:{limit:5,period:60}},
      {name:'INVITE_RATE_LIMITER',namespace_id:'710002',simple:{limit:10,period:60}},
      {name:'MEMBER_RATE_LIMITER',namespace_id:'710003',simple:{limit:120,period:60}}],
    d1_databases:[{binding:'DB',database_id:'cb3b2386-3a6f-4253-b918-8aafed9ff735'}],
    r2_buckets:[{binding:'MEDIA',bucket_name:'neko-window-sharing-staging-media-private'},
      {binding:'MODERATION_MEDIA',bucket_name:'neko-window-sharing-staging-moderation-private'}],
    services:[{binding:'PRIVATE_BILLING_GATEWAY',service:'neko-billing-gateway-staging-private',environment:'production',entrypoint:'BillingGateway'}]};
}
const syntheticSource = `// Synthetic code stands in for unrelated frozen implementations.
function route() { return 'original route'; }
function createFamilyResponseRouter(family, replies) { return family; }
function createGroupStagingRouter(family, group, cleanup, cron) { return group; }
const family_entry_default = {fetch() { return new Response('original family'); }};
const readModerationResponses = () => 'original replies';
const src_default = {}, runGroupRelayCleanup = () => {}, MOMENT_CLEANUP_CRON2 = 'cleanup';
var family_entry_default2 = createFamilyResponseRouter(family_entry_default, readModerationResponses);
var group_staging_entry_default = createGroupStagingRouter(family_entry_default2, src_default, runGroupRelayCleanup, MOMENT_CLEANUP_CRON2);
export {
  group_staging_entry_default as default,
  route
};
//# sourceMappingURL=group-staging-entry.js.map
`;

test('three candidates preserve every input except approved entry, alias, account and four flags', () => {
  const input = baseline(), before = structuredClone(input), configs = groupModerationStagingConfigs(input, options);
  assert.deepEqual(input, before);
  const flagNames = ['GROUP_RUNTIME_ENABLED', 'GROUP_REPORT_RUNTIME_ENABLED', 'GROUP_APNS_RUNTIME_ENABLED', 'GROUP_MODERATION_RUNTIME_ENABLED'];
  for (const [mode, expected] of Object.entries({closed:['YES','NO','NO','NO'],verification:['YES','YES','YES','YES'],stop:['NO','NO','NO','YES']})) {
    const config = configs[mode];
    assert.deepEqual(flagNames.map(k => config.vars[k]), expected);
    assert.equal(config.main, resolve(projectDirectory, 'gateway/group-staging-entry.mjs'));
    assert.deepEqual(config.alias, {'group-staging-legacy': options.legacyModule});
    assert.equal(config.account_id, options.accountId);
    const restored = structuredClone(config); restored.main = input.main;
    delete restored.alias; delete restored.account_id;
    for (const key of flagNames.slice(1)) delete restored.vars[key];
    restored.vars.GROUP_RUNTIME_ENABLED = input.vars.GROUP_RUNTIME_ENABLED;
    assert.deepEqual(restored, input, mode);
  }
  configs.closed.triggers.crons.push('mutated');
  assert.deepEqual(configs.verification.triggers, input.triggers);
  assert.deepEqual(groupModerationStagingConfigs({...input, account_id:options.accountId}, options).stop, configs.stop);
});

test('changed identity, routes, binding scope, schedules, existing variables or version are refused', () => {
  const changes = [
    b => {b.name='production';}, b => {b.account_id='wrong';}, b => {b.main='other.js';},
    b => {b.workers_dev=false;}, b => {b.preview_urls=true;}, b => {b.compatibility_date='2026-08-18';},
    b => {b.vars.ENVIRONMENT='production';}, b => {b.vars.GROUP_RUNTIME_ENABLED='NO';},
    b => {b.vars.GROUP_REPORT_RUNTIME_ENABLED='YES';}, b => {b.vars.APNS_RUNTIME_ENABLED='NO';},
    b => {b.vars.NEW_SETTING='YES';}, b => {b.d1_databases[0].database_id='other';},
    b => {b.d1_databases.push({...b.d1_databases[0],binding:'OTHER'});},
    b => {b.r2_buckets[0].bucket_name='public';}, b => {b.r2_buckets[1].binding='EVIDENCE';},
    b => {b.services[0].environment='staging';}, b => {b.services[0].service='public';},
    b => {b.ratelimits[0].namespace_id='other';}, b => {b.triggers.crons.pop();},
    b => {b.routes=[];}, b => {b.alias={};}, b => {b.assets={directory:'public'};},
  ];
  for (const change of changes) { const b=baseline(); change(b); assert.throws(() => groupModerationStagingConfigs(b, options)); }
  for (const change of [{version:'unobserved'}, {accountId:'wrong'}, {legacyModule:'relative.js'}, {projectDirectory:'relative'}]) {
    assert.throws(() => groupModerationStagingConfigs(baseline(), {...options,...change}));
  }
});

test('only the default export reference changes; family, reply and route bodies stay byte-identical', () => {
  const transformed = unwrapDownloadedGroupDefault(syntheticSource);
  assert.equal(transformed, syntheticSource.replace('  group_staging_entry_default as default,', '  family_entry_default2 as default,'));
  assert.equal(transformed.replace('  family_entry_default2 as default,', '  group_staging_entry_default as default,'), syntheticSource);
  for (const source of [syntheticSource+'// later code', syntheticSource.replace('  route\n', '  otherRoute\n'),
    syntheticSource.replace('family_entry_default, readModerationResponses', 'family_entry_default, wrongReader'),
    syntheticSource.replace('MOMENT_CLEANUP_CRON2);', 'MOMENT_CLEANUP_CRON);'),
    syntheticSource+'\n'+syntheticSource, transformed]) assert.throws(() => unwrapDownloadedGroupDefault(source));
});

test('preparation rejects unknown full source even with the expected footer and version', () => {
  assert.throws(() => prepareGroupModerationStaging({baseline:baseline(),source:syntheticSource,...options}));
});

// Local-only observation with an already downloaded approved artifact. CI never
// fetches live code and no large deployed-bundle fixture is added to the repo.
const downloadDirectory = process.env.GROUP_MODERATION_STAGING_BASELINE_DIRECTORY;
test('approved downloaded old/new workerd bundles agree on non-group health and anonymous rejection', {
  skip: !downloadDirectory && 'Set GROUP_MODERATION_STAGING_BASELINE_DIRECTORY for the existing local download', timeout: 30000,
}, async () => {
  const input=JSON.parse(await readFile(resolve(downloadDirectory,'wrangler.jsonc'),'utf8'));
  const source=await readFile(resolve(downloadDirectory,'src/group-staging-entry.js'),'utf8');
  const prepared=prepareGroupModerationStaging({baseline:input,source,...options});
  assert.equal(prepared.legacySource,source.replace('  group_staging_entry_default as default,','  family_entry_default2 as default,'));
  assert.throws(() => prepareGroupModerationStaging({baseline:input,source:source.replace('var family_entry_default2', 'var family_entry_changed'),...options}));
  const compiled=await build({entryPoints:[resolve(projectDirectory,'gateway/group-staging-entry.mjs')],
    bundle:true,format:'esm',platform:'neutral',target:'es2022',write:false,external:['cloudflare:workers'],
    plugins:[{name:'approved-local-legacy',setup(builder) {
      builder.onResolve({filter:/^group-staging-legacy$/},()=>({path:'approved-legacy',namespace:'local-approved'}));
      builder.onLoad({filter:/.*/,namespace:'local-approved'},()=>({contents:prepared.legacySource,loader:'js'}));
    }}]});
  const settings={modules:true,compatibilityDate:'2026-08-17',d1Databases:{DB:'moderation-config-local'},
    serviceBindings:{PRIVATE_BILLING_GATEWAY:'private'},bindings:prepared.configs.closed.vars,
    ratelimits:{MEMBER_RATE_LIMITER:{namespace_id:'710003',simple:{limit:120,period:60}}}};
  const mf=new Miniflare(convertV4MiniflareOptions({cf:false,workers:[
    {name:'front',modules:true,compatibilityDate:'2026-08-17',
      script:`export default {fetch(r,e){const u=new URL(r.url),old=u.pathname.startsWith('/old/');u.pathname=u.pathname.slice(4);return (old?e.OLD:e.NEW).fetch(new Request(u,r));}}`,
      serviceBindings:{OLD:'old',NEW:'new'}},
    {...settings,name:'old',script:source}, {...settings,name:'new',script:compiled.outputFiles[0].text},
    {name:'private',modules:true,compatibilityDate:'2026-08-17',script:`export default {fetch(){return new Response('local-only',{status:503});}}`},
  ]}));
  try {
    const db=await mf.getD1Database('DB','new');
    await db.exec('CREATE TABLE personal_staging_runtime_gate(singleton INTEGER PRIMARY KEY,generation INTEGER,media_enabled INTEGER,apns_enabled INTEGER,report_ingestion_enabled INTEGER); INSERT INTO personal_staging_runtime_gate VALUES(1,1,1,1,1)');
    for (const [path,expected] of [['/health',200],['/v2/family-records',401],['/v2/reports/responses',401],['/not-found',404]]) {
      const old=await mf.dispatchFetch('https://local/old'+path), fresh=await mf.dispatchFetch('https://local/new'+path);
      assert.equal(old.status,expected,path); assert.equal(fresh.status,old.status,path);
      assert.equal(await fresh.text(),await old.text(),path);
      const relevant=response=>[...response.headers].filter(([key])=>['content-type','cache-control','x-content-type-options'].includes(key));
      assert.deepEqual(relevant(fresh),relevant(old),path);
    }
  } finally { await mf.dispose(); }
});
