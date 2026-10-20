import { resolve } from 'node:path';

const ACCOUNT='829a34ef925a39d81b0e9e08800d7c7f', DB='cb3b2386-3a6f-4253-b918-8aafed9ff735';
export function groupStagingConfigs(baseline, projectDirectory, legacyModule) {
  if(baseline.name!=='neko-window-sharing-staging' || baseline.compatibility_date!=='2026-08-17'
      || baseline.workers_dev!==true || baseline.preview_urls!==false || baseline.vars?.ENVIRONMENT!=='staging'
      || ![undefined,'NO'].includes(baseline.vars.GROUP_RUNTIME_ENABLED)
      || baseline.account_id && baseline.account_id!==ACCOUNT) throw Error('Approved staging baseline changed');
  if(baseline.d1_databases?.length!==1 || baseline.d1_databases[0].binding!=='DB'
      || baseline.d1_databases[0].database_id!==DB) throw Error('Unexpected database');
  if(baseline.services?.length!==1 || baseline.services[0].binding!=='PRIVATE_BILLING_GATEWAY'
      || baseline.services[0].service!=='neko-billing-gateway-staging-private'
      || baseline.services[0].entrypoint!=='BillingGateway') throw Error('Existing private gateway changed');
  if(baseline.routes?.length || baseline.route || baseline.assets || baseline.alias) throw Error('Unexpected routing/build configuration');
  const off={...structuredClone(baseline),account_id:ACCOUNT,
    main:resolve(projectDirectory,'gateway/group-staging-entry.mjs'),
    alias:{'group-staging-legacy':resolve(legacyModule)},
    vars:{...baseline.vars,GROUP_RUNTIME_ENABLED:'NO'}};
  const on={...structuredClone(off),vars:{...off.vars,GROUP_RUNTIME_ENABLED:'YES'}};
  return {off,on};
}
