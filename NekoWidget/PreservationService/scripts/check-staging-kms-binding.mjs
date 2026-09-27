// Calls the local-only Wrangler probe with synthetic data. Never prints the
// caller token, data key, ciphertext, or AWS credentials.
import { execFileSync } from 'node:child_process';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';
import { AwsV4Signer } from 'aws4fetch';

const accountId = '164892691568';
const region = 'ap-northeast-1';
const profile = 'neko-preservation-test';
const parameterName = '/neko/preservation/staging/kms-caller-v1';
const keyArn = `arn:aws:kms:${region}:${accountId}:key/339319dc-388b-4bd7-adb8-29d37d836d72`;
const port = process.env.NEKO_KMS_PROBE_PORT === '8800' ? 8800 : 8799;
const awsExecutable = process.platform === 'win32'
  ? join(process.env.LOCALAPPDATA ?? '', 'Programs', 'Amazon', 'AWSCLIV2', 'aws.exe') : 'aws';
const mode = process.argv[2];
if (!['--expect-off', '--expect-on'].includes(mode) || process.argv.length !== 3) {
  throw new Error('Choose --expect-off or --expect-on');
}

function awsJson(...args) {
  try {
    return JSON.parse(execFileSync(awsExecutable,
      [...args, '--profile', profile, '--region', region, '--output', 'json'], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
      }));
  } catch { throw new Error('AWS session unavailable'); }
}
if (awsJson('sts', 'get-caller-identity').Account !== accountId) {
  throw new Error('Unexpected AWS account');
}
const credentials = awsJson('configure', 'export-credentials', '--format', 'process');
if (!credentials.AccessKeyId || !credentials.SecretAccessKey || !credentials.SessionToken) {
  throw new Error('Short-lived AWS credentials unavailable');
}
const body = JSON.stringify({ Name: parameterName, WithDecryption: true });
const signer = new AwsV4Signer({ url: `https://ssm.${region}.amazonaws.com/`,
  method: 'POST', body, service: 'ssm', region,
  accessKeyId: credentials.AccessKeyId, secretAccessKey: credentials.SecretAccessKey,
  sessionToken: credentials.SessionToken, allHeaders: true,
  headers: { 'content-type': 'application/x-amz-json-1.1',
    'x-amz-target': 'AmazonSSM.GetParameter' } });
const signed = await signer.sign();
const parameterResponse = await fetch(signed.url, { method: signed.method,
  headers: signed.headers, body: signed.body, redirect: 'error',
  signal: AbortSignal.timeout(30_000) });
if (parameterResponse.status !== 200) throw new Error('Caller token read unavailable');
const parameter = await parameterResponse.json();
const token = parameter.Parameter?.Value;
if (parameter.Parameter?.Name !== parameterName
  || parameter.Parameter?.Type !== 'SecureString'
  || typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(token)) {
  throw new Error('Caller token invalid');
}

async function call(path, input, suppliedToken = token) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json',
      'x-neko-preservation-key-token': suppliedToken },
    body: JSON.stringify(input), redirect: 'error',
    signal: AbortSignal.timeout(15_000),
  });
  return { status: response.status, json: response.status === 200
    ? await response.json() : null };
}

const raw = randomBytes(32);
try {
  const contextSHA256 = randomBytes(32).toString('hex');
  const wrap = { version: 1, key: raw.toString('base64'), contextSHA256 };
  if (mode === '--expect-off') {
    const result = await call('/keys/wrap', wrap);
    if (result.status !== 503) throw new Error(`Expected private KMS gate OFF; got ${result.status}`);
    process.stdout.write('Remote private binding refused synthetic wrap while OFF.\n');
  } else {
    const wrapped = await call('/keys/wrap', wrap);
    if (wrapped.status !== 200 || wrapped.json?.version !== 1
      || wrapped.json?.keyId !== keyArn || typeof wrapped.json?.wrappedKey !== 'string') {
      throw new Error(`Synthetic wrap failed (HTTP ${wrapped.status})`);
    }
    const unwrap = { version: 1, keyId: keyArn,
      wrappedKey: wrapped.json.wrappedKey, contextSHA256 };
    const opened = await call('/keys/unwrap', unwrap);
    if (opened.status !== 200 || opened.json?.version !== 1
      || typeof opened.json?.key !== 'string'
      || !timingSafeEqual(raw, Buffer.from(opened.json.key, 'base64'))) {
      throw new Error(`Synthetic unwrap failed (HTTP ${opened.status})`);
    }
    const wrongToken = await call('/keys/wrap', wrap, randomBytes(32).toString('base64url'));
    const wrongContext = await call('/keys/unwrap',
      { ...unwrap, contextSHA256: randomBytes(32).toString('hex') });
    const wrongKeyId = await call('/keys/unwrap',
      { ...unwrap, keyId: keyArn.replace('339319dc', '039319dc') });
    if (wrongToken.status !== 503 || wrongContext.status !== 503
      || wrongKeyId.status !== 400) {
      throw new Error(`Boundary rejection failed (${wrongToken.status}/${wrongContext.status}/${wrongKeyId.status})`);
    }
    process.stdout.write('Remote private binding: synthetic wrap/unwrap and three rejection paths passed.\n');
  }
} finally { raw.fill(0); }
