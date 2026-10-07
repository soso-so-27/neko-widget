import { parseOwnerAdmission } from "./billing-sandbox-owner-policy.mjs";
import { base64urlDecode, sha256 } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const closed = () => new ApiError(503, "billing_owner_admission_unavailable", "Billing is temporarily unavailable.");
const denied = () => new ApiError(403, "billing_owner_admission_required", "This purchase test is not available.");

export interface BillingSandboxOwnerAdmission {
  version: 1;
  bootstrapClientRequestId: string;
  initialPublicKeySHA256: string;
  startsAtMs: number;
  expiresAtMs: number;
}

/** Operator enrollment of one existing on-device billing key, not an Apple
 * identity claim, an email allowlist, or a first-request signup policy. The
 * public fingerprint and original request ID must be verified with the owner
 * before deployment. No secret, new account or new credential is made here.
 */
export function billingSandboxOwnerAdmission(env: Env, now = Date.now()): BillingSandboxOwnerAdmission {
  if (!['local', 'staging'].includes(env.ENVIRONMENT ?? '')
      || env.BILLING_STORE_ENVIRONMENT !== 'Sandbox'
      || typeof env.BILLING_SANDBOX_OWNER_ADMISSION !== 'string'
      || env.BILLING_SANDBOX_OWNER_ADMISSION.length > 512) throw closed();
  try { return parseOwnerAdmission(env.BILLING_SANDBOX_OWNER_ADMISSION, now); }
  catch { throw closed(); }
}

export function ownerOnlyBillingRequired(env: Env): boolean {
  return env.BILLING_SANDBOX_OWNER_ONLY_REQUIRED === 'YES';
}

/** Admission deadline, not cancellation of already executing D1 transactions. */
export function recheckOwnerSandboxAdmission(env: Env): void {
  if (ownerOnlyBillingRequired(env)) billingSandboxOwnerAdmission(env);
}

async function publicKeyFingerprint(key: string): Promise<string> {
  return [...await sha256(base64urlDecode(key, 32))].map(value => value.toString(16).padStart(2, '0')).join('');
}

export async function requireOwnerSandboxBootstrap(env: Env, clientRequestId: string, publicKey: string): Promise<void> {
  if (!ownerOnlyBillingRequired(env)) return;
  const policy = billingSandboxOwnerAdmission(env);
  if (clientRequestId !== policy.bootstrapClientRequestId
      || await publicKeyFingerprint(publicKey) !== policy.initialPublicKeySHA256) throw denied();
  billingSandboxOwnerAdmission(env); // Do not admit after an asynchronous proof crosses expiry.
}

/** The immutable original bootstrap binds recovery to the same billing account,
 * even after Apple-backed recovery revokes its original key. Never choose an
 * account from a header or from the first request seen at the public endpoint.
 */
export async function ownerSandboxBillingAccount(env: Env): Promise<string | null> {
  const policy = billingSandboxOwnerAdmission(env);
  let row: { billing_account_id: string; signing_public_key: string } | null;
  try {
    row = await env.DB.prepare(`SELECT b.billing_account_id, k.signing_public_key
      FROM billing_account_bootstrap_requests b JOIN billing_account_keys k
        ON k.id=b.billing_key_id AND k.billing_account_id=b.billing_account_id
      WHERE b.client_request_id=?`).bind(policy.bootstrapClientRequestId).first();
  } catch { throw closed(); }
  if (!row) return null;
  try {
    if (!uuid.test(row.billing_account_id)
        || await publicKeyFingerprint(row.signing_public_key) !== policy.initialPublicKeySHA256) throw closed();
  } catch { throw closed(); }
  billingSandboxOwnerAdmission(env);
  return row.billing_account_id;
}

export async function requireOwnerSandboxAccount(env: Env, accountId: string): Promise<void> {
  if (!ownerOnlyBillingRequired(env)) return;
  if (await ownerSandboxBillingAccount(env) !== accountId) throw denied();
}
