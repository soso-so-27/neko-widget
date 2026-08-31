import {
  authenticateBillingSignedRequest,
  consumeBillingNonce,
  type AuthenticatedBillingAccount,
} from "./billing-auth";
import {
  billingAccountCreationTranscript,
} from "./billing-protocol";
import {
  type VerifiedBillingTransaction,
  verifyAppleTransactionViaService,
} from "./billing-verifier-client";
import {
  randomBase64url,
  sha256Base64url,
  verifyEd25519,
} from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import {
  enforceRateLimit,
  parseJsonBody,
  readBody,
  requireEmptyBody,
  transientNetworkKey,
} from "./http";
import {
  binaryField,
  exactKeys,
  protocolVersion,
  stringField,
  uuidField,
} from "./validation";

export const BILLING_PROTOCOL_VERSION = 1 as const;
const maximumSignedTransactionBytes = 48 * 1024;
const compactJWSPattern = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u;

interface BillingGateRow {
  account_bootstrap_enabled: 0 | 1;
  transaction_ingestion_enabled: 0 | 1;
}

interface BootstrapRow {
  request_hash: string;
  billing_account_id: string;
  billing_key_id: string;
  created_at: number;
}

interface BillingAccountRow { id: string }
interface LineageRow {
  billing_account_id: string;
  environment: "Sandbox" | "Production";
  subscription_group_id: string;
}
interface TransactionEventRow {
  event_fingerprint: string;
  ownership_type: "PURCHASED" | "FAMILY_SHARED";
  expires_date_ms: number;
  revocation_date_ms: number | null;
  revocation_reason: 0 | 1 | null;
  is_upgraded: 0 | 1;
}
interface LatestTransactionRow {
  product_id: string | null;
  expires_date_ms: number | null;
  active_candidate: 0 | 1 | null;
  last_event_signed_date_ms: number | null;
}

interface ProvisionalBillingEntitlement {
  status: "activeCandidate" | "noActiveCandidate";
  productId: string | null;
  expiresDateMs: number | null;
  lastEventSignedDateMs: number | null;
  evaluatedAtMs: number;
  provisional: true;
  grantsPlus: false;
}

export type BillingTransactionVerifier = (
  signedTransactionInfo: string,
  env: Env,
) => Promise<VerifiedBillingTransaction>;

async function loadBillingGate(env: Env): Promise<BillingGateRow> {
  let gate: BillingGateRow | null;
  try {
    gate = await env.DB.prepare(
      `SELECT account_bootstrap_enabled, transaction_ingestion_enabled
         FROM billing_runtime_gate WHERE singleton = 1`,
    ).first<BillingGateRow>();
  } catch {
    gate = null;
  }
  if (gate === null) {
    throw new ApiError(503, "billing_runtime_gate_unavailable", "Billing is temporarily unavailable.");
  }
  return gate;
}

function nowSeconds(): number { return Math.floor(Date.now() / 1_000); }

function accountResponse(row: BootstrapRow): Record<string, unknown> {
  return {
    protocolVersion: BILLING_PROTOCOL_VERSION,
    billingAccountId: row.billing_account_id,
    billingKeyId: row.billing_key_id,
    createdAt: row.created_at,
  };
}

async function loadBootstrap(env: Env, clientRequestId: string): Promise<BootstrapRow | null> {
  return env.DB.prepare(
    `SELECT request_hash, billing_account_id, billing_key_id, created_at
       FROM billing_account_bootstrap_requests WHERE client_request_id = ?`,
  ).bind(clientRequestId).first<BootstrapRow>();
}

export async function createBillingAccount(request: Request, env: Env): Promise<Response> {
  if ((await loadBillingGate(env)).account_bootstrap_enabled !== 1) {
    throw new ApiError(503, "billing_runtime_disabled", "Billing is temporarily unavailable.");
  }
  await enforceRateLimit(
    env,
    env.BILLING_RATE_LIMITER,
    transientNetworkKey(request, "billing-bootstrap"),
  );
  const body = await readBody(request, 2_048);
  const value = parseJsonBody(request, body);
  exactKeys(value, [
    "protocolVersion", "clientRequestId", "signingPublicKey", "creationSignature",
  ]);
  protocolVersion(value);
  const clientRequestId = uuidField(value, "clientRequestId");
  const signingPublicKey = binaryField(value, "signingPublicKey", 32);
  const creationSignature = binaryField(value, "creationSignature", 64);
  const creationTranscript = billingAccountCreationTranscript({
    clientRequestId,
    signingPublicKey,
  });
  let signatureValid = false;
  try {
    signatureValid = await verifyEd25519(
      signingPublicKey,
      creationSignature,
      creationTranscript,
    );
  } catch {
    signatureValid = false;
  }
  if (!signatureValid) {
    throw new ApiError(401, "invalid_billing_creation_signature", "Billing authentication failed.");
  }
  const requestHash = await sha256Base64url(creationTranscript);
  const existing = await loadBootstrap(env, clientRequestId);
  if (existing !== null) {
    if (existing.request_hash !== requestHash) {
      throw new ApiError(409, "billing_bootstrap_conflict", "The billing request ID was already used.");
    }
    return jsonResponse(accountResponse(existing), 201);
  }

  const createdAt = nowSeconds();
  const billingAccountId = crypto.randomUUID().toLowerCase();
  const billingKeyId = randomBase64url(16);
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO billing_accounts(id, created_at) VALUES (?, ?)")
        .bind(billingAccountId, createdAt),
      env.DB.prepare(
        `INSERT INTO billing_account_keys(
           id, billing_account_id, signing_public_key, state, created_at
         ) VALUES (?, ?, ?, 'active', ?)`,
      ).bind(billingKeyId, billingAccountId, signingPublicKey, createdAt),
      env.DB.prepare(
        `INSERT INTO billing_account_bootstrap_requests(
           client_request_id, request_hash, billing_account_id, billing_key_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`,
      ).bind(clientRequestId, requestHash, billingAccountId, billingKeyId, createdAt),
    ]);
  } catch {
    const raced = await loadBootstrap(env, clientRequestId);
    if (raced !== null) {
      if (raced.request_hash === requestHash) {
        return jsonResponse(accountResponse(raced), 201);
      }
      throw new ApiError(409, "billing_bootstrap_conflict", "The billing request ID was already used.");
    }
    throw new ApiError(503, "billing_account_unavailable", "Billing is temporarily unavailable.");
  }
  return jsonResponse(accountResponse({
    request_hash: requestHash,
    billing_account_id: billingAccountId,
    billing_key_id: billingKeyId,
    created_at: createdAt,
  }), 201);
}

async function semanticFingerprint(value: VerifiedBillingTransaction): Promise<string> {
  return sha256Base64url(new TextEncoder().encode(JSON.stringify([
    BILLING_PROTOCOL_VERSION, value.transactionId, value.originalTransactionId,
    value.billingAccountId, value.productId, value.subscriptionGroupId,
    value.bundleId, value.environment, value.ownershipType,
    value.transactionReason, value.purchaseDateMs, value.originalPurchaseDateMs,
    value.expiresDateMs, value.signedDateMs, value.revocationDateMs,
    value.revocationReason, value.isUpgraded,
  ])));
}

function eventDisposition(row: Pick<
  TransactionEventRow,
  "ownership_type" | "expires_date_ms" | "revocation_date_ms" | "revocation_reason" | "is_upgraded"
>): "candidate" | "nonEntitling" {
  return row.ownership_type === "PURCHASED"
    && row.revocation_date_ms === null
    && row.revocation_reason === null
    && row.is_upgraded === 0
    && row.expires_date_ms > Date.now()
    ? "candidate" : "nonEntitling";
}

async function provisionalEntitlement(
  env: Env,
  billingAccountId: string,
): Promise<ProvisionalBillingEntitlement> {
  const evaluatedAtMs = Date.now();
  const latest = await env.DB.prepare(
    `WITH ranked AS (
       SELECT product_id, expires_date_ms, signed_date_ms, event_fingerprint,
              ownership_type, revocation_date_ms, revocation_reason, is_upgraded,
              ROW_NUMBER() OVER (
                PARTITION BY transaction_id
                ORDER BY signed_date_ms DESC, received_at DESC, event_fingerprint DESC
              ) AS event_rank
         FROM billing_transaction_events
        WHERE billing_account_id = ?
     ), latest_events AS (
       SELECT product_id, expires_date_ms, signed_date_ms, event_fingerprint,
              ownership_type, revocation_date_ms, revocation_reason, is_upgraded
         FROM ranked WHERE event_rank = 1
     ), selected AS (
       SELECT product_id, expires_date_ms, signed_date_ms, event_fingerprint,
              CASE WHEN ownership_type = 'PURCHASED'
                         AND revocation_date_ms IS NULL
                         AND revocation_reason IS NULL
                         AND is_upgraded = 0
                         AND expires_date_ms > ?
                   THEN 1 ELSE 0 END AS active_candidate
         FROM latest_events
        ORDER BY active_candidate DESC,
                 CASE WHEN active_candidate = 1 THEN expires_date_ms ELSE signed_date_ms END DESC,
                 signed_date_ms DESC,
                 event_fingerprint DESC
        LIMIT 1
     ), summary AS (
       SELECT MAX(signed_date_ms) AS last_event_signed_date_ms
         FROM latest_events
     )
     SELECT selected.product_id, selected.expires_date_ms,
            selected.active_candidate, summary.last_event_signed_date_ms
       FROM summary LEFT JOIN selected ON 1 = 1`,
  ).bind(billingAccountId, evaluatedAtMs).first<LatestTransactionRow>();
  const active = latest?.active_candidate === 1;
  return {
    status: active ? "activeCandidate" : "noActiveCandidate",
    productId: active ? latest.product_id : null,
    expiresDateMs: active ? latest.expires_date_ms : null,
    lastEventSignedDateMs: latest?.last_event_signed_date_ms ?? null,
    evaluatedAtMs,
    // A verified transaction ledger is not a complete subscription authority:
    // Notifications V2 and periodic Subscription Status reconciliation remain
    // mandatory before this result can grant production Plus access.
    provisional: true,
    grantsPlus: false,
  };
}

async function transactionResponse(
  env: Env,
  value: VerifiedBillingTransaction,
  event: TransactionEventRow,
): Promise<Record<string, unknown>> {
  return {
    protocolVersion: BILLING_PROTOCOL_VERSION,
    billingAccountId: value.billingAccountId,
    originalTransactionId: value.originalTransactionId,
    transactionId: value.transactionId,
    recorded: true,
    disposition: eventDisposition(event),
    entitlement: await provisionalEntitlement(env, value.billingAccountId),
  };
}

async function loadEvent(env: Env, fingerprint: string): Promise<TransactionEventRow | null> {
  return env.DB.prepare(
    `SELECT event_fingerprint, ownership_type, expires_date_ms,
            revocation_date_ms, revocation_reason, is_upgraded
       FROM billing_transaction_events WHERE event_fingerprint = ?`,
  ).bind(fingerprint).first<TransactionEventRow>();
}

async function storeVerifiedTransaction(
  env: Env,
  value: VerifiedBillingTransaction,
  submitter: AuthenticatedBillingAccount,
): Promise<TransactionEventRow> {
  if (value.billingAccountId !== submitter.billingAccountId) {
    throw new ApiError(409, "billing_account_mismatch", "The App Store transaction is invalid.");
  }
  const fingerprint = await semanticFingerprint(value);
  const replay = await loadEvent(env, fingerprint);
  if (replay !== null) return replay;
  const account = await env.DB.prepare("SELECT id FROM billing_accounts WHERE id = ?")
    .bind(value.billingAccountId).first<BillingAccountRow>();
  if (account === null) {
    throw new ApiError(409, "billing_account_not_registered", "The billing account is unavailable.");
  }
  const lineage = await env.DB.prepare(
    `SELECT billing_account_id, environment, subscription_group_id
       FROM billing_transaction_lineages WHERE original_transaction_id = ?`,
  ).bind(value.originalTransactionId).first<LineageRow>();
  if (lineage !== null && (
    lineage.billing_account_id !== value.billingAccountId
    || lineage.environment !== value.environment
    || lineage.subscription_group_id !== value.subscriptionGroupId
  )) {
    throw new ApiError(409, "billing_lineage_conflict", "The App Store transaction is invalid.");
  }
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT OR IGNORE INTO billing_transaction_lineages(
           original_transaction_id, billing_account_id, environment, subscription_group_id
         ) VALUES (?, ?, ?, ?)`,
      ).bind(
        value.originalTransactionId, value.billingAccountId,
        value.environment, value.subscriptionGroupId,
      ),
      env.DB.prepare(
        `INSERT INTO billing_transaction_events(
           event_fingerprint, transaction_id, original_transaction_id,
           billing_account_id, submitted_by_billing_key_id, source,
           product_id, subscription_group_id, environment, ownership_type,
           transaction_reason, purchase_date_ms, original_purchase_date_ms,
           expires_date_ms, signed_date_ms, revocation_date_ms,
           revocation_reason, is_upgraded
         ) VALUES (?, ?, ?, ?, ?, 'app', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        fingerprint, value.transactionId, value.originalTransactionId,
        value.billingAccountId, submitter.billingKeyId, value.productId,
        value.subscriptionGroupId, value.environment, value.ownershipType,
        value.transactionReason, value.purchaseDateMs, value.originalPurchaseDateMs,
        value.expiresDateMs, value.signedDateMs, value.revocationDateMs,
        value.revocationReason, value.isUpgraded ? 1 : 0,
      ),
    ]);
  } catch {
    const raced = await loadEvent(env, fingerprint);
    if (raced !== null) return raced;
    throw new ApiError(409, "billing_transaction_conflict", "The App Store transaction conflicts with recorded data.");
  }
  return {
    event_fingerprint: fingerprint,
    ownership_type: value.ownershipType,
    expires_date_ms: value.expiresDateMs,
    revocation_date_ms: value.revocationDateMs,
    revocation_reason: value.revocationReason,
    is_upgraded: value.isUpgraded ? 1 : 0,
  };
}

export async function getBillingEntitlement(request: Request, env: Env): Promise<Response> {
  if ((await loadBillingGate(env)).transaction_ingestion_enabled !== 1) {
    throw new ApiError(503, "billing_runtime_disabled", "Billing is temporarily unavailable.");
  }
  await enforceRateLimit(
    env,
    env.BILLING_RATE_LIMITER,
    transientNetworkKey(request, "billing-entitlement"),
  );
  const body = await readBody(request, 0);
  requireEmptyBody(body);
  const account = await authenticateBillingSignedRequest(request, env, body);
  await consumeBillingNonce(env, account);
  return jsonResponse({
    protocolVersion: BILLING_PROTOCOL_VERSION,
    billingAccountId: account.billingAccountId,
    entitlement: await provisionalEntitlement(env, account.billingAccountId),
  });
}

export async function recordBillingTransaction(
  request: Request,
  env: Env,
  verify: BillingTransactionVerifier = verifyAppleTransactionViaService,
): Promise<Response> {
  if ((await loadBillingGate(env)).transaction_ingestion_enabled !== 1) {
    throw new ApiError(503, "billing_runtime_disabled", "Billing is temporarily unavailable.");
  }
  await enforceRateLimit(
    env,
    env.BILLING_RATE_LIMITER,
    transientNetworkKey(request, "billing-transaction"),
  );
  const body = await readBody(request, maximumSignedTransactionBytes + 1_024);
  const account = await authenticateBillingSignedRequest(request, env, body);
  await consumeBillingNonce(env, account);
  const value = parseJsonBody(request, body);
  exactKeys(value, ["protocolVersion", "signedTransactionInfo"]);
  protocolVersion(value);
  const signedTransactionInfo = stringField(value, "signedTransactionInfo");
  if (
    signedTransactionInfo.length > maximumSignedTransactionBytes
    || !compactJWSPattern.test(signedTransactionInfo)
  ) throw new ApiError(400, "invalid_apple_transaction", "The App Store transaction is invalid.");

  const verified = await verify(signedTransactionInfo, env);
  const event = await storeVerifiedTransaction(env, verified, account);
  return jsonResponse(await transactionResponse(env, verified, event));
}
