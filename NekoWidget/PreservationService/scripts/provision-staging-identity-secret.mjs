// Private staging-only operator utility. Never prints the HMAC secret or AWS credentials.
// Run from NekoWidget/PreservationService with --probe, --create, or --recover.
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AwsV4Signer } from 'aws4fetch';

const accountId = '164892691568';
const region = 'ap-northeast-1';
const profile = 'neko-preservation-test';
const parameterName = '/neko/preservation/staging/identity-index-v1';
const keyArn = `arn:aws:kms:${region}:${accountId}:key/339319dc-388b-4bd7-adb8-29d37d836d72`;
const cloudflareAccountId = '829a34ef925a39d81b0e9e08800d7c7f';
const workerName = 'neko-preservation-staging-disabled';
const serviceDirectory = fileURLToPath(new URL('../', import.meta.url));
const configPath = join(serviceDirectory, 'wrangler.jsonc');
const wranglerPath = join(serviceDirectory, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
const awsExecutable = process.platform === 'win32'
  ? join(process.env.LOCALAPPDATA ?? '', 'Programs', 'Amazon', 'AWSCLIV2', 'aws.exe') : 'aws';
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
  const result = await response.json();
  return { status: response.status, result };
}

async function getParameter(withDecryption) {
  const { status, result } = await ssm('GetParameter', { Name: parameterName, WithDecryption: withDecryption });
  if (status === 400 && /(?:^|#)ParameterNotFound$/u.test(result.__type ?? '')) return null;
  if (status !== 200 || result.Parameter?.Type !== 'SecureString'
    || result.Parameter.Name !== parameterName || typeof result.Parameter.Value !== 'string') {
    throw new Error(`SSM parameter read failed (HTTP ${status}, type ${String(result.__type ?? 'unknown').slice(0, 80)})`);
  }
  return result.Parameter.Value;
}

async function putCloudflareSecret(secret) {
  const child = spawn(process.execPath, [wranglerPath, 'secret', 'put', 'IDENTITY_INDEX_SECRET',
    '--config', configPath, '--env', 'staging'], {
    cwd: serviceDirectory, env: cloudflareEnv,
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  // Drain without echoing a CLI response that could contain the secret.
  child.stdout.resume();
  child.stderr.resume();
  child.stdin.on('error', () => {});
  child.stdin.end(`${secret}\n`);
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', resolve);
  });
  if (code !== 0) throw new Error(`Cloudflare secret registration failed (exit ${code})`);
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

function verifyCloudflareTarget() {
  const config = JSON.parse(readFileSync(configPath, 'utf8'));
  const staging = config.env?.staging;
  if (staging?.name !== workerName || staging.workers_dev !== false
    || staging.vars?.PRESERVATION_ENABLED !== 'NO'
    || staging.vars?.CLEANUP_ENABLED !== 'NO'
    || staging.routes?.length || staging.route) {
    throw new Error('Unexpected staging Worker configuration');
  }
  const identity = wranglerJson('whoami', '--json', '--account', cloudflareAccountId);
  if (identity.loggedIn !== true || identity.accounts?.length !== 1
    || identity.accounts[0]?.id !== cloudflareAccountId) {
    throw new Error('Unexpected Cloudflare account');
  }
  const deployments = wranglerJson('deployments', 'list', '--json',
    '--config', configPath, '--env', 'staging', '--name', workerName);
  if (!Array.isArray(deployments) || deployments.length === 0
    || !deployments.some((deployment) => deployment.versions?.length > 0)) {
    throw new Error('Expected private staging Worker not deployed');
  }
  const current = deployments.reduce((latest, deployment) =>
    !latest || deployment.created_on > latest.created_on ? deployment : latest, null);
  if (current.versions?.length !== 1 || current.versions[0]?.percentage !== 100) {
    throw new Error('Unexpected staging Worker traffic split');
  }
  const versionId = current.versions[0].version_id;
  const version = wranglerJson('versions', 'view', versionId, '--json',
    '--config', configPath, '--env', 'staging', '--name', workerName);
  const bindings = version.resources?.bindings;
  const isOff = (name) => bindings?.some((binding) => binding.name === name
    && binding.type === 'plain_text' && binding.text === 'NO');
  if (version.id !== versionId || !isOff('PRESERVATION_ENABLED') || !isOff('CLEANUP_ENABLED')) {
    throw new Error('Deployed staging Worker is not verified OFF');
  }
}

verifyCloudflareTarget();

if (mode === '--probe') {
  const value = await getParameter(false);
  process.stdout.write(`AWS account verified; parameter ${value === null ? 'absent' : 'present'}\n`);
} else {
  let secret;
  if (mode === '--create') {
    if (await getParameter(false) !== null) throw new Error('Parameter already exists; use --recover');
    secret = randomBytes(32).toString('base64url');
    const { status } = await ssm('PutParameter', { Name: parameterName,
      Description: 'Stable private staging identity HMAC key; do not rotate without migration',
      Value: secret, Type: 'SecureString', KeyId: keyArn,
      Tier: 'Standard', Overwrite: false });
    if (status !== 200) throw new Error('SSM parameter creation failed');
  } else {
    secret = await getParameter(true);
    if (secret === null) throw new Error('Parameter missing; use --create');
  }
  if (!/^[A-Za-z0-9_-]{43}$/u.test(secret)
    || Buffer.from(secret, 'base64url').length !== 32) throw new Error('Invalid HMAC key format');
  const stored = await getParameter(true);
  if (stored === null || !timingSafeEqual(Buffer.from(secret), Buffer.from(stored))) {
    throw new Error('SSM read-back mismatch');
  }
  await putCloudflareSecret(secret);
  secret = undefined;
  process.stdout.write('Identity index secret registered in SSM and private staging Worker.\n');
}
