import { billingRetentionFence, retentionDigest } from './billing-retention-executor';
import { fetchAppleSubscriptionStatusViaService, type VerifiedSubscriptionStatus } from "./billing-apple-client";
import { selectAuthoritativeStatusItem } from "./billing-entitlement";
import { billingAccountRecoveryTranscript } from "./billing-protocol";
import { verifyAppleAccountRecoveryViaService, type VerifiedAccountRecoveryEvidence } from "./billing-verifier-client";
import { randomBase64url, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { enforceRateLimit, parseJsonBody, readBody, transientNetworkKey } from "./http";
import { binaryField, exactKeys, protocolVersion, stringField, uuidField } from "./validation";
import { requireOwnerSandboxAccount } from "./billing-sandbox-owner";

interface Gate { account_recovery_enabled: 0 | 1 }
interface Existing {
  request_hash: string; billing_account_id: string; new_billing_key_id: string; recovered_at: number;
}
interface State { generation: number; billing_key_id: string }
interface CurrentLineage { billing_account_id: string; environment: string; subscription_group_id: string }

type RecoveryVerifier = (input: Parameters<typeof verifyAppleAccountRecoveryViaService>[0], env: Env) => Promise<VerifiedAccountRecoveryEvidence>;
type StatusFetcher = (originalTransactionId: string, env: Env, storeEnvironment?: "Sandbox" | "Production") => Promise<VerifiedSubscriptionStatus>;

const jwsPattern = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u;
const transactionPattern = /^\d{1,32}$/u;

async function existing(env: Env, requestId: string): Promise<Existing | null> {
  return env.DB.prepare(
    `SELECT request_hash, billing_account_id, new_billing_key_id, recovered_at
       FROM billing_account_recovery_requests WHERE client_request_id = ?
     UNION ALL
     SELECT receipt.request_hash, receipt.billing_account_id, receipt.billing_key_id AS new_billing_key_id,
            receipt.created_at AS recovered_at
       FROM billing_account_bootstrap_requests AS receipt
       JOIN billing_account_keys AS key ON key.id=receipt.billing_key_id AND key.state='active'
      WHERE receipt.client_request_id = ?
        AND EXISTS(SELECT 1 FROM billing_account_apple_identities AS identity
          JOIN billing_transaction_lineages AS lineage
            ON lineage.environment=identity.environment AND lineage.original_transaction_id=identity.first_original_transaction_id
          WHERE identity.billing_account_id=receipt.billing_account_id AND lineage.billing_account_id=receipt.billing_account_id)
        AND NOT EXISTS(SELECT 1 FROM billing_retention_fences AS fence
          WHERE fence.billing_account_id=receipt.billing_account_id AND fence.state<>'active')`,
  ).bind(requestId, requestId).first<Existing>();
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
  // Reject a different account before Apple/Container work or key rotation.
  await requireOwnerSandboxAccount(env, billingAccountId);
  const retention=await billingRetentionFence(env,billingAccountId);
  if(retention && (retention.state==='deleting' || retention.receipt_recorded!==1)) {
    throw new ApiError(409,'billing_deletion_in_progress','Billing deletion is in progress.');
  }
  const replay = await existing(env, clientRequestId);
  if (replay !== null) {
    if (replay.request_hash !== requestHash) throw new ApiError(409, "billing_recovery_conflict", "The billing request ID was already used.");
    return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId: replay.billing_account_id, billingKeyId: replay.new_billing_key_id, recoveredAt: replay.recovered_at });
  }
  // Freeze the generation before awaiting Apple so concurrent attempts cannot
  // adopt and revoke the key that another in-flight attempt just installed.
  const state = await env.DB.prepare(
    `SELECT state.generation, key.id AS billing_key_id
       FROM billing_account_key_state AS state
       JOIN billing_account_keys AS key ON key.billing_account_id = state.billing_account_id
      WHERE state.billing_account_id = ? AND key.state = 'active'`,
  ).bind(billingAccountId).first<State>();
  const evidence = await verify({ signedAppTransactionInfo, signedTransactionInfo,
    deviceVerificationId, expectedAppTransactionId, expectedTransactionId, expectedOriginalTransactionId, billingAccountId }, env);
  let lineage = await env.DB.prepare(
    `SELECT billing_account_id, environment, subscription_group_id
       FROM billing_transaction_lineages WHERE environment = ? AND original_transaction_id = ?`,
  ).bind(evidence.transaction.environment, expectedOriginalTransactionId).first<CurrentLineage>();
  const missingLineage = lineage === null;
  if (missingLineage) {
    // An absent local ledger is not evidence that Apple never sold this
    // subscription. This is provisional only: no write precedes live authority.
    lineage={billing_account_id:billingAccountId,environment:evidence.transaction.environment,
      subscription_group_id:evidence.transaction.subscriptionGroupId};
  }
  if (lineage === null || lineage.billing_account_id !== billingAccountId) {
    throw new ApiError(409, "billing_recovery_lineage_mismatch", "The recovery evidence is invalid.");
  }
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
  const authority = await fetchStatus(expectedOriginalTransactionId, env, evidence.transaction.environment);
  const matches = authority.items.filter((item) => item.originalTransactionId === expectedOriginalTransactionId);
  // Reuse the entitlement authority's fail-restrictive ordering. If Apple
  // returns conflicting facts at the exact same signed time, Family Shared,
  // revoked, or upgraded evidence must win over a convenient active row.
  if (matches.length === 0) throw new ApiError(409, "billing_recovery_authority_denied", "The subscription is not eligible for recovery.");
  const item = selectAuthoritativeStatusItem(matches);
  const now = Date.now();
  const accessUntil = item.status === 4 ? item.renewal.gracePeriodExpiresDateMs : item.transaction.expiresDateMs;
  if ((!Number.isSafeInteger(authority.fetchedAtMs) || authority.fetchedAtMs>now || now-authority.fetchedAtMs>60_000)
    || authority.environment !== evidence.transaction.environment
    || item.transaction.environment !== evidence.transaction.environment
    || item.renewal.environment !== evidence.transaction.environment
    || item.transaction.subscriptionGroupId !== lineage.subscription_group_id
    || item.transaction.bundleId !== evidence.transaction.bundleId
    || item.transaction.productId !== evidence.transaction.productId
    || item.transaction.originalTransactionId !== expectedOriginalTransactionId
    || item.renewal.originalTransactionId !== expectedOriginalTransactionId
    || item.renewal.billingAccountId !== billingAccountId
    || (item.status !== 1 && item.status !== 4)
    || item.transaction.transactionId !== expectedTransactionId
    || item.transaction.billingAccountId !== billingAccountId
    || item.transaction.ownershipType !== "PURCHASED"
    || item.transaction.revocationDateMs !== null || item.transaction.revocationReason !== null
    || item.transaction.isUpgraded || accessUntil === null || accessUntil <= now) {
    throw new ApiError(409, "billing_recovery_authority_denied", "The subscription is not eligible for recovery.");
  }

  const recoveredAt = Math.floor(Date.now() / 1_000);
  await requireOwnerSandboxAccount(env, billingAccountId);
  const newKeyId = randomBase64url(16);
  try {
    const enqueue = env.DB.prepare(
      `INSERT OR IGNORE INTO billing_reconciliation_jobs(environment,original_transaction_id,requested_at,not_before,request_generation)
       VALUES(?,?,?,?,COALESCE((SELECT request_generation+1 FROM billing_effective_entitlement_current WHERE environment=? AND original_transaction_id=?),1))`,
    ).bind(evidence.transaction.environment,expectedOriginalTransactionId,recoveredAt,recoveredAt,
      evidence.transaction.environment,expectedOriginalTransactionId);
    if (state === null) {
      // Initial import, not a rotation of a fabricated old key. The existing
      // bootstrap receipt makes an identical retry idempotent; its hash is the
      // domain-separated, signed recovery transcript, not a bootstrap signature.
      // A competing initial import or an inconsistent existing account aborts
      // this whole batch at the account PK. It cannot revoke the winning key.
      if (!missingLineage || retention) throw new Error('inconsistent initial recovery');
      await env.DB.batch([
        env.DB.prepare(`INSERT INTO billing_accounts(id,created_at)
          SELECT ?,? WHERE EXISTS(SELECT 1 FROM billing_runtime_gate WHERE singleton=1 AND account_recovery_enabled=1)`)
          .bind(billingAccountId,recoveredAt),
        env.DB.prepare(`INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state,created_at)
          VALUES(?,?,?,'active',?)`).bind(newKeyId,billingAccountId,signingPublicKey,recoveredAt),
        env.DB.prepare(`INSERT INTO billing_account_bootstrap_requests(client_request_id,request_hash,billing_account_id,billing_key_id,created_at)
          VALUES(?,?,?,?,?)`).bind(clientRequestId,requestHash,billingAccountId,newKeyId,recoveredAt),
        env.DB.prepare(`INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id)
          VALUES(?,?,?,?)`).bind(expectedOriginalTransactionId,billingAccountId,evidence.transaction.environment,lineage.subscription_group_id),
        env.DB.prepare(`INSERT INTO billing_account_apple_identities(billing_account_id,app_transaction_id_hash,environment,first_original_transaction_id)
          VALUES(?,?,?,?)`).bind(billingAccountId,evidence.appTransactionIdHash,evidence.transaction.environment,expectedOriginalTransactionId),
        enqueue,
      ]);
      return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId, billingKeyId: newKeyId, recoveredAt });
    }
    const rotate=env.DB.prepare(
      `INSERT INTO billing_account_recovery_requests(
         environment, client_request_id, request_hash, billing_account_id, expected_generation,
         expected_transaction_id, expected_original_transaction_id, app_transaction_id_hash,
         replaced_billing_key_id, new_billing_key_id, new_signing_public_key, recovered_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(evidence.transaction.environment, clientRequestId, requestHash, billingAccountId, state.generation,
      expectedTransactionId, expectedOriginalTransactionId, evidence.appTransactionIdHash,
      state.billing_key_id, newKeyId, signingPublicKey, recoveredAt);
    if(retention) {
      const lineageHash=await retentionDigest(evidence.transaction.environment+':'+expectedOriginalTransactionId);
      const transactionHash=await retentionDigest(evidence.transaction.environment+':'+expectedTransactionId);
      // The whole transition is atomic. No caller observes a partially reopened account.
      const result=await env.DB.batch([
        env.DB.prepare(`UPDATE billing_retention_fences SET state='active',recovery_environment=?,
          recovery_lineage_hash=?,recovery_transaction_hash=?,recovery_request_id=?
          WHERE billing_account_id=? AND sequence=? AND state IN('closed','active')
          AND EXISTS(SELECT 1 FROM billing_retention_requests WHERE sequence=? AND state='completed' AND receipt_recorded=1)`)
          .bind(evidence.transaction.environment,lineageHash,transactionHash,clientRequestId,billingAccountId,retention.sequence,retention.sequence),
        env.DB.prepare(`INSERT OR IGNORE INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id)
          SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=? AND sequence=? AND state='active' AND recovery_request_id=?)`)
          .bind(expectedOriginalTransactionId,billingAccountId,evidence.transaction.environment,lineage.subscription_group_id,
            billingAccountId,retention.sequence,clientRequestId),
        env.DB.prepare(`INSERT OR IGNORE INTO billing_retention_recoveries(billing_account_id,sequence,environment,lineage_hash,transaction_hash,request_id)
          VALUES(?,?,?,?,?,?)`).bind(billingAccountId,retention.sequence,evidence.transaction.environment,lineageHash,transactionHash,clientRequestId),
        rotate,
        enqueue,
      ]);
      if(result[0]?.meta.changes!==1) throw new Error('retention recovery fence changed');
    } else if (missingLineage) {
      await env.DB.batch([
        env.DB.prepare(`INSERT OR IGNORE INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id)
          VALUES(?,?,?,?)`).bind(expectedOriginalTransactionId,billingAccountId,evidence.transaction.environment,lineage.subscription_group_id),
        rotate,
        enqueue,
      ]);
    } else await rotate.run();
  } catch {
    const raced = await existing(env, clientRequestId);
    if (raced !== null && raced.request_hash === requestHash) {
      return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId: raced.billing_account_id, billingKeyId: raced.new_billing_key_id, recoveredAt: raced.recovered_at });
    }
    throw new ApiError(409, "billing_recovery_conflict", "Billing recovery conflicted with another request.");
  }
  return jsonResponse({ protocolVersion: 1, clientRequestId, billingAccountId, billingKeyId: newKeyId, recoveredAt });
}
