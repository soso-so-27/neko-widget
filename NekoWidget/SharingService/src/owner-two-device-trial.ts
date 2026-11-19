import {billingSandboxOwnerAdmission, ownerSandboxBillingAccount} from './billing-sandbox-owner';
import {authenticateBillingSignedRequest} from './billing-auth';
import {base64urlDecode, sha256, sha256Base64url} from './encoding';
import type {Env} from './env';
import {ApiError} from './errors';
import {readBody} from './http';

const proofHeader = 'neko-owner-trial-proof';
const key = /^[A-Za-z0-9_-]{43}$/u;
const windowID = /^[A-Za-z0-9_-]{22}$/u;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const scopeFields = ['proofHash','family','window','aPerson','aDevice','bPerson','bDevice',
  'recoveryDevice','phase','phaseUntilMs','expiresAtMs'] as const;
const maxDay = 86_400_000;
type Phase = 'OFF' | 'PREPARE' | 'PHOTO' | 'REPORT' | 'RECOVERY';

export interface OwnerTrial {
  proofHash: string;
  family: string;
  window: string;
  aPerson: string;
  aDevice: string;
  bPerson: string | null;
  bDevice: string | null;
  recoveryDevice: string | null;
  phase: Phase;
  phaseUntilMs: number;
  expiresAtMs: number;
}

export const trialDenied = () => new ApiError(404, 'owner_trial_unavailable', 'The endpoint is unavailable.');

export function parseOwnerTrial(raw: string): OwnerTrial {
  if (raw.length > 1200) throw trialDenied();
  const value = JSON.parse(raw) as OwnerTrial;
  if (!value || Object.keys(value).length !== scopeFields.length
      || scopeFields.some(field => !Object.hasOwn(value, field))
      || ![value.proofHash,value.aPerson,value.aDevice].every(x => typeof x === 'string' && key.test(x))
      || typeof value.family !== 'string' || !uuid.test(value.family)
      || typeof value.window !== 'string' || !windowID.test(value.window)
      || !['OFF','PREPARE','PHOTO','REPORT','RECOVERY'].includes(value.phase)
      || !Number.isSafeInteger(value.phaseUntilMs) || !Number.isSafeInteger(value.expiresAtMs)
      || (value.bDevice === null) !== (value.bPerson === null)
      || ![value.bPerson,value.bDevice,value.recoveryDevice].every(x => x === null || typeof x === 'string' && key.test(x))
      || value.bPerson === value.aPerson || value.bDevice === value.aDevice
      || value.recoveryDevice === value.aDevice || value.recoveryDevice !== null && value.recoveryDevice === value.bDevice
      || value.phase !== 'OFF' && (!value.bDevice || value.phaseUntilMs > value.expiresAtMs)
      || value.phase === 'RECOVERY' && !value.recoveryDevice
      || value.phase === 'OFF' && value.phaseUntilMs !== 0) throw trialDenied();
  return value;
}

function stagePolicy(env: Env): OwnerTrial | undefined {
  if (env.ENVIRONMENT !== 'staging' || !env.OWNER_TWO_DEVICE_TRIAL) return;
  if (env.GROUP_REPORT_RUNTIME_ENABLED !== 'NO' || env.FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED !== 'NO'
      || env.GROUP_RECOVERY_CATALOG_ENABLED !== 'NO' || env.GROUP_REPORT_EMAIL_ENABLED !== 'NO'
      || env.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED === 'YES') throw trialDenied();
  try { return parseOwnerTrial(env.OWNER_TWO_DEVICE_TRIAL); }
  catch { throw trialDenied(); }
}

async function verifiedBillingScope(env: Env, scope: OwnerTrial, now: number): Promise<Env> {
  const scoped = {...env,BILLING_STORE_ENVIRONMENT:'Sandbox',BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES'};
  const admission = billingSandboxOwnerAdmission(scoped, now);
  if (scope.expiresAtMs !== admission.expiresAtMs || scope.expiresAtMs - now > maxDay * 7) throw trialDenied();
  const account = await ownerSandboxBillingAccount(scoped);
  if (!account || !await env.DB.prepare(`SELECT 1 AS ready FROM group_billing_connections c
    JOIN group_person_devices d ON c.linked_device_id=d.id AND c.person_id=d.person_id
    JOIN group_people p ON p.id=d.person_id
    WHERE c.billing_account_id=? AND c.person_id=? AND c.linked_device_id=? AND d.state='active' AND p.state='active'`)
    .bind(account,scope.aPerson,scope.aDevice).first()) throw trialDenied();
  return scoped;
}

export async function ownerTrialFamilyPushEnvironment(env: Env): Promise<Env | undefined> {
  const scope = stagePolicy(env);
  const now = Date.now();
  if (!scope || scope.phase !== 'RECOVERY' || scope.phaseUntilMs <= now
    || scope.phaseUntilMs - now > 3_600_000) return;
  const billing = await verifiedBillingScope(env, scope, now);
  return {...billing, ownerTrial:scope, BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES',
    FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:'YES'};
}

const billingPaths = new Map([
  ['/v1/billing/transactions','POST'],
  ['/v1/billing/entitlement','GET'],
]);
const group = '/v3/group-windows';
const notebooks = '/v3/family-notebooks';

// A request-scoped copy is the only place where pilot gates can become YES.
// The Worker variables and general report intake are never changed by a request.
export async function ownerTrialRequest(request: Request, env: Env): Promise<Env | Response | undefined> {
  const proof = request.headers.get(proofHeader);
  // Unrelated deployments must not even read a trial binding before their own
  // request gate. A credential presented there cannot enable staging behavior.
  if (!Object.hasOwn(env, 'OWNER_TWO_DEVICE_TRIAL')) {
    if (proof) throw trialDenied();
    return;
  }
  const scope = stagePolicy(env);
  if (!scope) {
    if (proof) throw trialDenied();
    return;
  }
  const path = new URL(request.url).pathname;
  const isHealth = path === '/v1/billing/health' && request.method === 'GET';
  const family = notebooks + '/' + scope.family, window = group + '/' + scope.window;
  const onFamily = path === family || path.startsWith(family + '/');
  const onWindow = path === window || path.startsWith(window + '/');
  const now = Date.now();
  if (isHealth) {
    if (!env.PRIVATE_BILLING_GATEWAY || scope.phase !== 'OFF' || scope.expiresAtMs <= now) throw trialDenied();
    await verifiedBillingScope(env, scope, now);
    const response = await env.PRIVATE_BILLING_GATEWAY.fetch(request);
    if (response.status !== 200 || response.headers.get('neko-runtime-billing-owner-admission') !== 'READY') return response;
    const digest = Array.from(await sha256(new TextEncoder().encode(env.BILLING_SANDBOX_OWNER_ADMISSION!)),
      byte => byte.toString(16).padStart(2,'0')).join('');
    if (response.headers.get('neko-runtime-billing-owner-policy-sha256') !== digest) throw trialDenied();
    const headers = new Headers(response.headers);
    headers.set('cache-control','no-store');
    headers.set('neko-owner-two-device-readiness','READY');
    headers.set('neko-owner-two-device-feature-gates','OFF');
    headers.set('neko-owner-two-device-admission-expires-at-ms',String(scope.expiresAtMs));
    return new Response(response.body,{status:200,headers});
  }
  if (!proof) {
    if (onFamily || onWindow || billingPaths.has(path)) throw trialDenied();
    return {...env,reservedTrial:scope};
  }
  if (scope.expiresAtMs <= now || !key.test(proof)
      || await sha256Base64url(base64urlDecode(proof,32)) !== scope.proofHash) throw trialDenied();
  if (billingPaths.get(path) === request.method) {
    if (!env.PRIVATE_BILLING_GATEWAY) throw trialDenied();
    const billing = await verifiedBillingScope(env, scope, now);
    const body = await readBody(request,request.method==='GET'?0:131_072);
    await authenticateBillingSignedRequest(request,billing,body);
    const headers = new Headers(request.headers);
    headers.delete(proofHeader);
    return env.PRIVATE_BILLING_GATEWAY.fetch(new Request(request.url,{method:request.method,headers,
      ...(body.length?{body:body.slice().buffer}:{})}));
  }
  // An explicitly configured two-device photo trial can run to the existing
  // Sandbox admission expiry. Other phases retain the short expiry guard.
  const photoUntilAdmissionExpiry = scope.phase === 'PHOTO' && scope.recoveryDevice === null
    && scope.phaseUntilMs === scope.expiresAtMs;
  if (scope.phase === 'OFF' || scope.phaseUntilMs <= now
      || (!photoUntilAdmissionExpiry && scope.phaseUntilMs - now > 3_600_000)) {
    // The app ends its local participation on a successful empty directory.
    // A closed trial is a temporary read failure for trial clients.
    if (path === notebooks+'/me') {
      throw new ApiError(503, 'owner_trial_unavailable', 'The trial notebook is temporarily unavailable.');
    }
    if (path === group+'/list'
        || path === '/v3/group-identities' || path === '/v3/group-identities/challenges') return {...env,reservedTrial:scope};
    throw trialDenied();
  }
  const photos = scope.phase === 'PHOTO' || scope.phase === 'REPORT';
  const recovery = scope.phase === 'RECOVERY';
  if (path.startsWith('/v3/group-recovery/')) {
    if (!recovery || /\/(?:remove|fresh)$/u.test(path)) throw trialDenied();
  } else if (onFamily) {
    if (path.startsWith(family + '/representative-photos/')) {
      const read = request.method === 'GET' && /^\/(?:slots|assets\/[0-9a-f-]{36}(?:\/status)?)$/u
        .test(path.slice((family + '/representative-photos').length));
      if (!photos && !(recovery && read)) throw trialDenied();
      if (path.endsWith('/representative-photos/reports') && scope.phase !== 'REPORT') throw trialDenied();
    }
  } else if (onWindow) {
    // A new single-owner window is the source. Do not admit or remove members/devices here.
    const suffix = path.slice(window.length);
    const allowed = suffix === '' ? request.method === 'GET'
      : /^\/(?:anchor-receipt|close|moments(?:\/[-A-Za-z0-9_/]+)?|keys\/[0-9]+|rosters\/list|recovery\/(?:pending|[0-9a-f-]{36}\/(?:key-offers|complete)))$/u.test(suffix);
    if (!recovery || !allowed) throw trialDenied();
  } else if (path === notebooks+'/report-replies') {
    if (scope.phase !== 'REPORT') throw trialDenied();
  } else if (path === group) {
    if (!recovery) throw trialDenied();
  } else if (path !== notebooks && path !== notebooks+'/me' && path !== group+'/list' && path !== group+'/billing-connection') {
    if (path !== '/v3/group-identities' && path !== '/v3/group-identities/challenges') throw trialDenied();
    if (!recovery) return;
  }
  const billing = await verifiedBillingScope(env, scope, now);
  return {...billing,ownerTrial:scope,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES',
    FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED:photos||recovery?'YES':'NO',
    ...(recovery ? {FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED:'YES'} : {}),
    GROUP_RECOVERY_CATALOG_ENABLED:recovery?'YES':'NO'};
}

export function checkTrialActor(env: Env, person: string, device: string, owner = false): void {
  const scope = env.ownerTrial;
  if (scope && (Date.now() >= scope.phaseUntilMs || !(
    person === scope.aPerson && device === scope.aDevice ||
    !owner && person === scope.bPerson && device === scope.bDevice ||
    !owner && scope.phase === 'RECOVERY' && person === scope.aPerson && device === scope.recoveryDevice))) throw trialDenied();
}

export function checkTrialCreation(env: Env, kind: 'family' | 'window', id: string,
                                   person: string, device: string): void {
  if (env.ownerTrial) {
    checkTrialActor(env, person, device, true);
    if (id !== env.ownerTrial[kind]) throw trialDenied();
  } else if (id === env.reservedTrial?.[kind]) throw trialDenied();
}

export function checkTrialRecovery(env: Env, person: string, window?: string, device?: string): void {
  const scope = env.ownerTrial;
  if (scope && (Date.now() >= scope.phaseUntilMs || scope.phase !== 'RECOVERY' || person !== scope.aPerson
    || window !== undefined && window !== scope.window
    || device !== undefined && device !== scope.recoveryDevice)) throw trialDenied();
}
