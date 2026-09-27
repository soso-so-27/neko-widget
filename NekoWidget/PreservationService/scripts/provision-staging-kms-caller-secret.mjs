// Private staging-only utility. The caller token is kept in SSM SecureString,
// then installed in both OFF, route-less Workers without printing it.
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AwsV4Signer } from 'aws4fetch';

const accountId = '164892691568';
const region = 'ap-northeast-1';
const profile = 'neko-preservation-test';
const parameterName = '/neko/preservation/staging/kms-caller-v1';
const keyArn = `arn:aws:kms:${region}:${accountId}:key/339319dc-388b-4bd7-adb8-29d37d836d72`;
const cloudflareAccountId = '829a34ef925a39d81b0e9e08800d7c7f';
const serviceDirectory = fileURLToPath(new URL('../', import.meta.url));
const wranglerPath = join(serviceDirectory, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
const awsExecutable = process.platform === 'win32'
  ? join(process.env.LOCALAPPDATA ?? '', 'Programs', 'Amazon', 'AWSCLIV2', 'aws.exe') : 'aws';
const targets = [
  { config: join(serviceDirectory, 'wrangler.kms.staging.jsonc'),
    name: 'neko-preservation-kms-staging-disabled', env: [],
    off: ['PRESERVATION_KMS_ENABLED'] },
  { config: join(serviceDirectory, 'wrangler.jsonc'),
    name: 'neko-preservation-staging-disabled', env: ['--env', 'staging'],
    off: ['PRESERVATION_ENABLED', 'CLEANUP_ENABLED'] },
];
const mode = process.argv[2];
if (!['--probe', '--create', '--recover'].includes(mode) || process.argv.length !== 3) {
  throw new Error('Choose exactly one of --probe, --create, or --recover');
}

function awsJson(...args) {
  try {
    return JSON.parse(execFileSync(awsExecutable,
      [...args, '--profile', profile, '--region', region, '--output', 'json'], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
      }));
  } catch { throw new Error('AWS session unavailable'); }
}
const caller = awsJson('sts', 'get-caller-identity');
if (caller.Account !== accountId) throw new Error('Unexpected AWS account');
const credentials = awsJson('configure', 'export-credentials', '--format', 'process');
if (!credentials.AccessKeyId || !credentials.SecretAccessKey || !credentials.SessionToken) {
  throw new Error('Short-lived AWS credentials unavailable');
}

async function ssm(operation, input) {
  const url = `https://ssm.${region}.amazonaws.com/`;
  const body = JSON.stringify(input);
  const signer = new AwsV4Signer({ url, method: 'POST', service: 'ssm', region,
    accessKeyId: credentials.AccessKeyId, secretAccessKey: credentials.SecretAccessKey,
    sessionToken: credentials.SessionToken, allHeaders: true,
    headers: { 'content-type': 'application/x-amz-json-1.1',
      'x-amz-target': `AmazonSSM.${operation}` }, body });
  const signed = await signer.sign();
  const response = await fetch(signed.url, { method: signed.method, headers: signed.headers,
    body: signed.body, redirect: 'error', signal: AbortSignal.timeout(30_000) });
  return { status: response.status, result: await response.json() };
}

async function getParameter(withDecryption) {
  const { status, result } = await ssm('GetParameter',
    { Name: parameterName, WithDecryption: withDecryption });
  if (status === 400 && /(?:^|#)ParameterNotFound$/u.test(result.__type ?? '')) return null;
  if (status !== 200 || result.Parameter?.Type !== 'SecureString'
    || result.Parameter.Name !== parameterName || typeof result.Parameter.Value !== 'string') {
    throw new Error('SSM parameter read failed');
  }
  return result.Parameter.Value;
}

const cloudflareEnv = { ...process.env, CLOUDFLARE_ACCOUNT_ID: cloudflareAccountId };
function wranglerJson(...args) {
  try {
    return JSON.parse(execFileSync(process.execPath, [wranglerPath, ...args], {
      cwd: serviceDirectory, env: cloudflareEnv,
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
    }));
  } catch { throw new Error('Cloudflare target verification unavailable'); }
}

function verifyWorker(target) {
  const config = JSON.parse(readFileSync(target.config, 'utf8'));
  const configured = target.env.length ? config.env?.staging : config;
  if (configured?.name !== target.name || configured.workers_dev !== false
    || configured.routes?.length || configured.route
    || target.off.some(name => configured.vars?.[name] !== 'NO')) {
    throw new Error(`Unsafe local config: ${target.name}`);
  }
  const deployments = wranglerJson('deployments', 'list', '--json',
    '--config', target.config, ...target.env, '--name', target.name);
  if (!Array.isArray(deployments) || !deployments.length) {
    throw new Error(`Worker missing: ${target.name}`);
  }
  const current = deployments.reduce((latest, item) =>
    !latest || item.created_on > latest.created_on ? item : latest, null);
  if (current.versions?.length !== 1 || current.versions[0]?.percentage !== 100) {
    throw new Error(`Worker traffic split: ${target.name}`);
  }
  const id = current.versions[0].version_id;
  const version = wranglerJson('versions', 'view', id, '--json',
    '--config', target.config, ...target.env, '--name', target.name);
  const bindings = version.resources?.bindings;
  if (version.id !== id || target.off.some(name =>
    !bindings?.some(binding => binding.name === name
      && binding.type === 'plain_text' && binding.text === 'NO'))) {
    throw new Error(`Worker remotely enabled: ${target.name}`);
  }
}

async function putSecret(target, secret) {
  const child = spawn(process.execPath, [wranglerPath, 'secret', 'put',
    'KEY_WRAPPER_CALLER_SECRET', '--config', target.config, ...target.env], {
    cwd: serviceDirectory, env: cloudflareEnv,
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  child.stdout.resume();
  child.stderr.resume();
  child.stdin.on('error', () => {});
  child.stdin.end(`${secret}\n`);
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', resolve);
  });
  if (code !== 0) throw new Error(`Secret registration failed: ${target.name}`);
  const names = wranglerJson('secret', 'list', '--config', target.config,
    ...target.env, '--format', 'json');
  if (!names.some(item => item.name === 'KEY_WRAPPER_CALLER_SECRET')) {
    throw new Error(`Secret read-back missing: ${target.name}`);
  }
  verifyWorker(target);
}

const identity = wranglerJson('whoami', '--json', '--account', cloudflareAccountId);
if (identity.loggedIn !== true || identity.accounts?.length !== 1
  || identity.accounts[0]?.id !== cloudflareAccountId) {
  throw new Error('Unexpected Cloudflare account');
}
for (const target of targets) verifyWorker(target);

if (mode === '--probe') {
  process.stdout.write(`Caller token ${await getParameter(false) === null ? 'absent' : 'present'}; both Workers OFF.\n`);
} else {
  let secret;
  if (mode === '--create') {
    if (await getParameter(false) !== null) throw new Error('Parameter already exists; use --recover');
    secret = randomBytes(32).toString('base64url');
    const { status } = await ssm('PutParameter', { Name: parameterName,
      Description: 'Private staging KMS service-binding caller token',
      Value: secret, Type: 'SecureString', KeyId: keyArn,
      Tier: 'Standard', Overwrite: false });
    if (status !== 200) throw new Error('SSM parameter creation failed');
  } else {
    secret = await getParameter(true);
    if (secret === null) throw new Error('Parameter missing; use --create');
  }
  if (!/^[A-Za-z0-9_-]{43}$/u.test(secret)
    || Buffer.from(secret, 'base64url').length !== 32) throw new Error('Invalid token format');
  const stored = await getParameter(true);
  if (stored === null || !timingSafeEqual(Buffer.from(secret), Buffer.from(stored))) {
    throw new Error('SSM read-back mismatch');
  }
  // Both Workers are OFF; an interrupted rotation is recovered by --recover.
  for (const target of targets) await putSecret(target, secret);
  secret = undefined;
  process.stdout.write('Caller token registered in SSM and both OFF Workers.\n');
}
