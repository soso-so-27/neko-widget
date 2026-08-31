import { fetchAppleSubscriptionStatusViaService, type VerifiedSubscriptionStatus } from "./billing-apple-client";
import { selectAuthoritativeStatusItem } from "./billing-entitlement";
import { billingAccountRecoveryTranscript } from "./billing-protocol";
import { verifyAppleAccountRecoveryViaService, type VerifiedAccountRecoveryEvidence } from "./billing-verifier-client";
import { randomBase64url, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { enforceRateLimit, parseJsonBody, readBody, transientNetworkKey } from "./http";
import { binaryField, exactKeys, protocolVersion, stringField, uuidField } from "./validation";

interface Gate { account_recovery_enabled: 0 | 1 }
interface Existing {
  request_hash: string; billing_account_id: string; new_billing_key_id: string; recovered_at: number;
}
interface State { generation: number; billing_key_id: string }
interface CurrentLineage { billing_account_id: string; environment: string; subscription_group_id: string }

type RecoveryVerifier = (input: Parameters<typeof verifyAppleAccountRecoveryViaService>[0], env: Env) => Promise<VerifiedAccountRecoveryEvidence>;
type StatusFetcher = (originalTransactionId: string, env: Env) => Promise<VerifiedSubscriptionStatus>;

const jwsPattern = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u;
const transactionPattern = /^\d{1,32}$/u;

async function existing(env: Env, requestId: string): Promise<Existing | null> {
  return env.DB.prepare(
    `SELECT request_hash, billing_account_id, new_billing_key_id, recovered_at
       FROM billing_account_recovery_requests WHERE client_request_id = ?`,
  ).bind(requestId).first<Existing>();
}

export async function recoverBillingAccount(
  request: Request,
  env: Env,
  verify: RecoveryVerifier = verifyAppleAccountRecoveryViaService,
  fetchStatus: StatusFetcher = fetchAppleSubscriptionStatusViaService,
): Promise<Response> {
  const gate = await env.DB.prepare(
    "SELECT account_recovery_enabled FROM billing_runtime_gate WHERE singleton = 1",
  ).first<Gate>().catch(() => null);
  if (gate?.account_recovery_enabled !== 1) throw new ApiError(503, "billing_runtime_disabled", "Billing is temporarily unavailable.");
  await enforceRateLimit(env, env.BILLING_RATE_LIMITER, transientNetworkKey(request, "billing-recovery"));
  const body = await readBody(request, 128 * 1024);
  const value = parseJsonBody(request, body);
  exactKeys(value, [
    "protocolVersion", "clientRequestId", "billingAccountId", "signingPublicKey",
    "deviceVerificationId", "expectedAppTransactionId", "signedAppTransactionInfo", "signedTransactionInfo",
    "expectedTransactionId", "expectedOriginalTransactionId", "recoverySignature",
  ]);
  protocolVersion(value);
  const clientRequestId = uuidField(value, "clientRequestId");
  const billingAccountId = uuidField(value, "billingAccountId");
  const signingPublicKey = binaryField(value, "signingPublicKey", 32);
  const deviceVerificationId = stringField(value, "deviceVerificationId");
  const expectedAppTransactionId = stringField(value, "expectedAppTransactionId");
  const recoverySignature = binaryField(value, "recoverySignature", 64);
  const signedAppTransactionInfo = stringField(value, "signedAppTransactionInfo");
  const signedTransactionInfo = stringField(value, "signedTransactionInfo");
  const expectedTransactionId = stringField(value, "expectedTransactionId");
  const expectedOriginalTransactionId = stringField(value, "expectedOriginalTransactionId");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(deviceVerificationId)
    || !/^[^\u0000-\u001f\u007f-\u009f]{1,256}$/u.test(expectedAppTransactionId)
    || !jwsPattern.test(signedAppTransactionInfo) || !jwsPattern.test(signedTransactionInfo)
    || signedAppTransactionInfo.length > 60 * 1024 || signedTransactionInfo.length > 60 * 1024
    || !transactionPattern.test(expectedTransactionId)
    || !transactionPattern.test(expectedOriginalTransactionId)) {
    throw new ApiError(400, "invalid_billing_recovery", "The recovery evidence is invalid.");
  }
  const text = new TextEncoder();
  const transcript = billingAccountRecoveryTranscript({
    clientRequestId, billingAccountId, signingPublicKey, deviceVerificationId, expectedAppTransactionId,
    expectedTransactionId, expectedOriginalTransactionId,
    signedAppTransactionHash: await sha256Base64url(text.encode(signedAppTransactionInfo)),
    signedTransactionHash: await sha256Base64url(text.encode(signedTransactionInfo)),
  });
  let signatureValid = false;
  try { signatureValid = await verifyEd25519(signingPublicKey, recoverySignature, transcript); }
  catch { signatureValid = false; }
  if (!signatureValid) throw new ApiError(401, "invalid_billing_recovery_signature", "Billing authentication failed.");
  const requestHash = await sha256Base64url(transcript);
  const replay = await existing(env, clientRequestId);
  if (replay !== null) {
    if (replay.request_hash !== requestHash) throw new ApiError(409, "billing_recovery_conflict", "The billing request ID was already used.");
    return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId: replay.billing_account_id, billingKeyId: replay.new_billing_key_id, recoveredAt: replay.recovered_at });
  }
  const lineage = await env.DB.prepare(
    `SELECT billing_account_id, environment, subscription_group_id
       FROM billing_transaction_lineages WHERE original_transaction_id = ?`,
  ).bind(expectedOriginalTransactionId).first<CurrentLineage>();
  if (lineage === null || lineage.billing_account_id !== billingAccountId) {
    throw new ApiError(409, "billing_recovery_lineage_mismatch", "The recovery evidence is invalid.");
  }
  const evidence = await verify({ signedAppTransactionInfo, signedTransactionInfo,
    deviceVerificationId, expectedAppTransactionId, expectedTransactionId, expectedOriginalTransactionId, billingAccountId }, env);
  if (evidence.transaction.environment !== lineage.environment
    || evidence.transaction.subscriptionGroupId !== lineage.subscription_group_id
    || evidence.transaction.transactionId !== expectedTransactionId
    || evidence.transaction.originalTransactionId !== expectedOriginalTransactionId
    || evidence.transaction.billingAccountId !== billingAccountId
    || evidence.transaction.ownershipType !== "PURCHASED"
    || evidence.transaction.revocationDateMs !== null
    || evidence.transaction.revocationReason !== null
    || evidence.transaction.isUpgraded) {
    throw new ApiError(409, "billing_recovery_lineage_mismatch", "The recovery evidence is invalid.");
  }
  // Never trust the client-labelled "current" transaction. Query Apple's
  // subscription authority immediately before rotating the key.
  const authority = await fetchStatus(expectedOriginalTransactionId, env);
  const matches = authority.items.filter((item) => item.originalTransactionId === expectedOriginalTransactionId);
  // Reuse the entitlement authority's fail-restrictive ordering. If Apple
  // returns conflicting facts at the exact same signed time, Family Shared,
  // revoked, or upgraded evidence must win over a convenient active row.
  if (matches.length === 0) throw new ApiError(409, "billing_recovery_authority_denied", "The subscription is not eligible for recovery.");
  const item = selectAuthoritativeStatusItem(matches);
  const now = Date.now();
  const accessUntil = item.status === 4 ? item.renewal.gracePeriodExpiresDateMs : item.transaction.expiresDateMs;
  if ((item.status !== 1 && item.status !== 4)
    || item.transaction.transactionId !== expectedTransactionId
    || item.transaction.billingAccountId !== billingAccountId
    || item.transaction.ownershipType !== "PURCHASED"
    || item.transaction.revocationDateMs !== null || item.transaction.revocationReason !== null
    || item.transaction.isUpgraded || accessUntil === null || accessUntil <= now) {
    throw new ApiError(409, "billing_recovery_authority_denied", "The subscription is not eligible for recovery.");
  }

  const state = await env.DB.prepare(
    `SELECT state.generation, key.id AS billing_key_id
       FROM billing_account_key_state AS state
       JOIN billing_account_keys AS key ON key.billing_account_id = state.billing_account_id
      WHERE state.billing_account_id = ? AND key.state = 'active'`,
  ).bind(billingAccountId).first<State>();
  if (state === null) throw new ApiError(409, "billing_recovery_conflict", "Billing recovery conflicted with another request.");
  const recoveredAt = Math.floor(Date.now() / 1_000);
  const newKeyId = randomBase64url(16);
  try {
    await env.DB.prepare(
      `INSERT INTO billing_account_recovery_requests(
         client_request_id, request_hash, billing_account_id, expected_generation,
         expected_transaction_id, expected_original_transaction_id, app_transaction_id_hash,
         replaced_billing_key_id, new_billing_key_id, new_signing_public_key, recovered_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(clientRequestId, requestHash, billingAccountId, state.generation,
      expectedTransactionId, expectedOriginalTransactionId, evidence.appTransactionIdHash,
      state.billing_key_id, newKeyId, signingPublicKey, recoveredAt).run();
  } catch {
    const raced = await existing(env, clientRequestId);
    if (raced !== null && raced.request_hash === requestHash) {
      return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId: raced.billing_account_id, billingKeyId: raced.new_billing_key_id, recoveredAt: raced.recovered_at });
    }
    throw new ApiError(409, "billing_recovery_conflict", "Billing recovery conflicted with another request.");
  }
  return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId, billingKeyId: newKeyId, recoveredAt });
}
