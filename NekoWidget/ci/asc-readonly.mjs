// No raw API output, credentials, resource IDs, feedback text, or attachments in CI logs.
import { spawnSync } from 'node:child_process';
import { createPrivateKey, sign } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export function safeText(value, secrets = []) {
  let s = String(value ?? '');
  for (const secret of secrets.filter(Boolean).sort((a,b) => b.length-a.length)) s = s.split(secret).join('[redacted]');
  return s.replace(/https?:\/\/\S+/g, '[URL]').replace(/[\w.+-]+@[\w.-]+/g, '[email]')
    .replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, '[resource]')
    .replace(/\b\d{8,}\b/g, '[resource]').replace(/[\r\n]/g, ' ').slice(0, 1600);
}
export function validationSummary(report, secrets) {
  return {
    summary: report.summary,
    checks: (report.checks ?? []).map(c => Object.fromEntries(
      ['id','severity','locale','field','message','remediation'].filter(k => c[k] !== undefined)
        .map(k => [k, safeText(c[k], [...secrets, report.appId, report.versionId, c.resourceId])]))),
  };
}
function main() {
  const env = {...process.env, ASC_TELEMETRY_DISABLED:'1', DO_NOT_TRACK:'1'};
  const build = env.ASC_READ_BUILD;
  if (!/^\d{1,6}$/.test(build ?? '')) throw Error('Invalid build number');
  const secrets = [env.APP_STORE_CONNECT_KEY_ID, env.APP_STORE_CONNECT_ISSUER_ID, env.OWNER_INTERNAL_GROUP_ID];
  function read(args, allowFindings = false) {
    const r = spawnSync('asc', args, {env, encoding:'utf8', timeout:240000, maxBuffer:32*1024*1024});
    let data; try { data = JSON.parse(r.stdout); } catch { /* Never echo raw output. */ }
    if (r.error || !data || (r.status !== 0 && !(allowFindings && Array.isArray(data.checks)))) {
      const http = (r.stderr ?? '').match(/\b(401|403|429|500|502|503)\b/)?.[1] ?? 'unknown';
      throw Error(`Read unavailable (${args.slice(0,2).join(' ')}, exit=${r.status}, HTTP=${http}); no writes attempted`);
    }
    return data;
  }
  if (read(['telemetry','status']).enabled !== false) throw Error('Telemetry not disabled');
  const now = Math.floor(Date.now()/1000);
  const b64 = x => Buffer.from(JSON.stringify(x)).toString('base64url');
  const unsigned = b64({alg:'ES256',kid:env.APP_STORE_CONNECT_KEY_ID,typ:'JWT'})+'.'+b64({iss:env.APP_STORE_CONNECT_ISSUER_ID,iat:now,exp:now+1200,aud:'appstoreconnect-v1'});
  const key = createPrivateKey(Buffer.from(env.APP_STORE_CONNECT_PRIVATE_KEY_BASE64, 'base64'));
  env.ASC_BEARER_TOKEN = unsigned+'.'+sign('sha256',Buffer.from(unsigned),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
  for (const name of Object.keys(env)) if (name.startsWith('APP_STORE_CONNECT_') || name.startsWith('OWNER_INTERNAL_')) delete env[name];
  const apps = read(['apps','list','--name','ねこのまど','--output','json']);
  const matches = apps.data?.filter(a => a.attributes?.name === 'ねこのまど');
  if (matches?.length !== 1) throw Error('App identity is not unique');
  const app = matches[0].id; secrets.push(app);
  const builds = read(['builds','list','--app',app,'--build-number',build,'--include','betaGroups,buildBetaDetail','--output','json']);
  const result = builds.data?.find(b => b.attributes?.version === build);
  if (!result) throw Error('Requested build not found');
  const groupIDs = result.relationships?.betaGroups?.data?.map(g => g.id) ?? [];
  const detail = builds.included?.find(d => d.type === 'buildBetaDetails' && d.relationships?.build?.data?.id === result.id)
    ?? builds.included?.find(d => d.type === 'buildBetaDetails');
  console.log(JSON.stringify({build,processingState:result.attributes.processingState,expired:result.attributes.expired,
    ownerGroupAssigned:groupIDs.includes(process.env.OWNER_INTERNAL_GROUP_ID),internalBuildState:detail?.attributes?.internalBuildState ?? 'unverified'}));
  const report = read(['validate','--app',app,'--version','1.0','--output','json'],true);
  console.log('VALIDATION '+JSON.stringify(validationSummary(report,secrets)));
  for (const kind of ['crashes','feedback']) {
    const reports = read(['testflight',kind,'list','--app',app,'--include','build','--paginate','--output','json']);
    const versions = new Map((reports.included ?? []).filter(x=>x.type==='builds').map(x=>[x.id,x.attributes?.version]));
    const counts = {};
    for (const item of reports.data ?? []) {
      const version = versions.get(item.relationships?.build?.data?.id) ?? 'unverified';
      const label = /^\d{1,6}$/.test(version) ? version : 'unverified';
      counts[label] = (counts[label] ?? 0)+1;
    }
    console.log(JSON.stringify({kind,count:reports.data?.length ?? 0,byBuild:counts,detail:'Free text and attachments omitted for privacy'}));
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { main(); } catch (e) { console.error(e.message.startsWith('Read unavailable') ? e.message : 'Read-only report stopped; no raw diagnostic or credential output'); process.exitCode=1; }
}
