import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import fixture from "../../ci/fixtures/billing-verifier-protocol-v1.json";
import {
  createBillingAccount,
  getBillingEntitlement,
  recordBillingTransaction,
  type BillingTransactionVerifier,
} from "../src/billing";
import {
  billingAccountCreationTranscript,
  billingSignedRequestTranscript,
} from "../src/billing-protocol";
import {
  billingVerifierRequestTranscript,
  billingVerifierResponseTranscript,
  bodySHA256,
  signBillingVerifierTranscript,
  verifyBillingVerifierTranscript,
} from "../src/billing-verifier-protocol";
import type { VerifiedBillingTransaction } from "../src/billing-verifier-client";
import { base64urlEncode, sha256Base64url } from "../src/encoding";
import type { Env } from "../src/env";
import { route } from "../src/index";

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

interface BillingAccountFixture {
  billingAccountId: string;
  billingKeyId: string;
  keys: KeyPair;
}

const testEnv = env as unknown as Env;

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

function randomValue(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64urlEncode(value);
}

async function signingKeyPair(): Promise<KeyPair> {
  return crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  ) as Promise<KeyPair>;
}

async function publicKeyValue(keys: KeyPair): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
}

async function sign(keys: KeyPair, message: Uint8Array): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign(
    { name: "Ed25519" },
    keys.privateKey,
    arrayBuffer(message),
  )));
}

async function setLowerGate(enabled: boolean): Promise<void> {
  const row = await testEnv.DB.prepare(
    `SELECT generation, account_bootstrap_enabled, transaction_ingestion_enabled
       FROM billing_runtime_gate WHERE singleton = 1`,
  ).first<{
    generation: number;
    account_bootstrap_enabled: number;
    transaction_ingestion_enabled: number;
  }>();
  if (row === null) throw new Error("missing billing runtime gate");
  const target = enabled ? 1 : 0;
  if (
    row.account_bootstrap_enabled === target
    && row.transaction_ingestion_enabled === target
  ) return;
  const result = await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate
        SET generation = generation + 1,
            account_bootstrap_enabled = ?,
            transaction_ingestion_enabled = ?,
            updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?`,
  ).bind(target, target, row.generation).run();
  if (result.meta.changes !== 1) throw new Error("billing runtime gate CAS failed");
}

async function accountRequest(keys: KeyPair, clientRequestId: string): Promise<Request> {
  const signingPublicKey = await publicKeyValue(keys);
  const body = JSON.stringify({
    protocolVersion: 1,
    clientRequestId,
    signingPublicKey,
    creationSignature: await sign(
      keys,
      billingAccountCreationTranscript({ clientRequestId, signingPublicKey }),
    ),
  });
  return new Request("https://sharing.invalid/v1/billing/accounts", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "192.0.2.70",
    },
    body,
  });
}

async function createAccount(
  suppliedKeys?: KeyPair,
  clientRequestId = crypto.randomUUID().toLowerCase(),
): Promise<BillingAccountFixture> {
  const keys = suppliedKeys ?? await signingKeyPair();
  const response = await createBillingAccount(
    await accountRequest(keys, clientRequestId),
    testEnv,
  );
  expect(response.status).toBe(201);
  const value = await response.json<{
    billingAccountId: string;
    billingKeyId: string;
  }>();
  return { ...value, keys };
}

async function transactionRequest(
  account: BillingAccountFixture,
  signedTransactionInfo: string,
  nonce = randomValue(16),
): Promise<Request> {
  const body = JSON.stringify({ protocolVersion: 1, signedTransactionInfo });
  const timestamp = Math.floor(Date.now() / 1_000);
  const signature = await sign(account.keys, billingSignedRequestTranscript({
    billingAccountId: account.billingAccountId,
    billingKeyId: account.billingKeyId,
    timestamp,
    nonce,
    method: "POST",
    pathname: "/v1/billing/transactions",
    bodySHA256: await sha256Base64url(new TextEncoder().encode(body)),
  }));
  return new Request("https://sharing.invalid/v1/billing/transactions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "192.0.2.71",
      "Neko-Billing-Protocol-Version": "1",
      "Neko-Billing-Account-ID": account.billingAccountId,
      "Neko-Billing-Key-ID": account.billingKeyId,
      "Neko-Billing-Timestamp": String(timestamp),
      "Neko-Billing-Nonce": nonce,
      "Neko-Billing-Signature": signature,
    },
    body,
  });
}

async function entitlementRequest(
  account: BillingAccountFixture,
  nonce = randomValue(16),
): Promise<Request> {
  const timestamp = Math.floor(Date.now() / 1_000);
  const body = new Uint8Array();
  const signature = await sign(account.keys, billingSignedRequestTranscript({
    billingAccountId: account.billingAccountId,
    billingKeyId: account.billingKeyId,
    timestamp,
    nonce,
    method: "GET",
    pathname: "/v1/billing/entitlement",
    bodySHA256: await sha256Base64url(body),
  }));
  return new Request("https://sharing.invalid/v1/billing/entitlement", {
    method: "GET",
    headers: {
      "CF-Connecting-IP": "192.0.2.72",
      "Neko-Billing-Protocol-Version": "1",
      "Neko-Billing-Account-ID": account.billingAccountId,
      "Neko-Billing-Key-ID": account.billingKeyId,
      "Neko-Billing-Timestamp": String(timestamp),
      "Neko-Billing-Nonce": nonce,
      "Neko-Billing-Signature": signature,
    },
  });
}

function verifiedTransaction(
  billingAccountId: string,
  overrides: Partial<VerifiedBillingTransaction> = {},
): VerifiedBillingTransaction {
  const now = Date.now();
  return {
    transactionId: "200000000000001",
    originalTransactionId: "200000000000001",
    billingAccountId,
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupId: "20999999",
    bundleId: "jp.nekowidget.app",
    environment: "Sandbox",
    ownershipType: "PURCHASED",
    transactionReason: "PURCHASE",
    purchaseDateMs: now - 1_000,
    originalPurchaseDateMs: now - 1_000,
    expiresDateMs: now + 2_592_000_000,
    signedDateMs: now,
    revocationDateMs: null,
    revocationReason: null,
    isUpgraded: false,
    ...overrides,
  };
}

function verifier(value: VerifiedBillingTransaction): BillingTransactionVerifier {
  return async () => value;
}

describe.sequential("disabled Plus billing foundation", () => {
  it("keeps both upper and lower gates fail-closed before body, DB, or limiter work", async () => {
    const inaccessible = new Proxy({} as Env, {
      get(_target, property) {
        if (property === "BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED") return "NO";
        if (property === "BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED") return "NO";
        throw new Error(`unexpected environment read: ${String(property)}`);
      },
    });
    await expect(route(new Request("https://sharing.invalid/v1/billing/accounts", {
      method: "POST",
      body: "not-json",
    }), inaccessible)).rejects.toMatchObject({
      status: 503,
      code: "billing_runtime_disabled",
    });
    await expect(route(new Request("https://sharing.invalid/v1/billing/transactions", {
      method: "POST",
      body: "not-json",
    }), inaccessible)).rejects.toMatchObject({
      status: 503,
      code: "billing_runtime_disabled",
    });
    await expect(route(new Request("https://sharing.invalid/v1/billing/entitlement"), inaccessible))
      .rejects.toMatchObject({
        status: 503,
        code: "billing_runtime_disabled",
      });

    await setLowerGate(false);
    await expect(createBillingAccount(new Request(
      "https://sharing.invalid/v1/billing/accounts",
      { method: "POST", body: "not-json" },
    ), testEnv)).rejects.toMatchObject({
      status: 503,
      code: "billing_runtime_disabled",
    });
    await expect(getBillingEntitlement(new Request(
      "https://sharing.invalid/v1/billing/entitlement",
    ), testEnv)).rejects.toMatchObject({
      status: 503,
      code: "billing_runtime_disabled",
    });
    await setLowerGate(true);
    await expect(testEnv.DB.prepare(
      `UPDATE billing_runtime_gate
          SET account_bootstrap_enabled = 0,
              transaction_ingestion_enabled = 0,
              updated_at = unixepoch()
        WHERE singleton = 1`,
    ).run()).rejects.toThrow();
  });

  it("creates a self-authenticated account idempotently and conflicts on changed input", async () => {
    await setLowerGate(true);
    const clientRequestId = crypto.randomUUID().toLowerCase();
    const keys = await signingKeyPair();
    const invalidRequest = await accountRequest(keys, crypto.randomUUID().toLowerCase());
    const invalidBody = await invalidRequest.json<Record<string, unknown>>();
    invalidBody.creationSignature = randomValue(64);
    await expect(createBillingAccount(new Request(invalidRequest.url, {
      method: "POST",
      headers: invalidRequest.headers,
      body: JSON.stringify(invalidBody),
    }), testEnv)).rejects.toMatchObject({
      status: 401,
      code: "invalid_billing_creation_signature",
    });

    const first = await createBillingAccount(await accountRequest(keys, clientRequestId), testEnv);
    const reorderedRequest = await accountRequest(keys, clientRequestId);
    const reordered = await reorderedRequest.json<Record<string, unknown>>();
    const retry = await createBillingAccount(new Request(reorderedRequest.url, {
      method: "POST",
      headers: reorderedRequest.headers,
      body: JSON.stringify({
        creationSignature: reordered.creationSignature,
        signingPublicKey: reordered.signingPublicKey,
        clientRequestId: reordered.clientRequestId,
        protocolVersion: reordered.protocolVersion,
      }, null, 2),
    }), testEnv);
    expect(first.status).toBe(201);
    expect(await retry.json()).toEqual(await first.json());

    const otherKeys = await signingKeyPair();
    await expect(createBillingAccount(
      await accountRequest(otherKeys, clientRequestId),
      testEnv,
    )).rejects.toMatchObject({ status: 409, code: "billing_bootstrap_conflict" });
  });

  it("records one verified event on retry and never persists the raw Apple JWS", async () => {
    await setLowerGate(true);
    const account = await createAccount();
    const jws = "eyJhbGciOiJFUzI1NiJ9.billingrawmarker.signature";
    const verified = verifiedTransaction(account.billingAccountId);
    const first = await recordBillingTransaction(
      await transactionRequest(account, jws),
      testEnv,
      verifier(verified),
    );
    expect(await first.json()).toMatchObject({
      recorded: true,
      disposition: "candidate",
      billingAccountId: account.billingAccountId,
    });
    const retry = await recordBillingTransaction(
      await transactionRequest(account, jws),
      testEnv,
      verifier(verified),
    );
    expect(await retry.json()).toMatchObject({ recorded: true, disposition: "candidate" });
    const count = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_transaction_events WHERE transaction_id = ?",
    ).bind(verified.transactionId).first<{ count: number }>();
    expect(count).toEqual({ count: 1 });
    const rows = await testEnv.DB.prepare(
      `SELECT event_fingerprint, transaction_id, original_transaction_id,
              billing_account_id, product_id, subscription_group_id,
              environment, ownership_type, transaction_reason
         FROM billing_transaction_events WHERE transaction_id = ?`,
    ).bind(verified.transactionId).all();
    expect(JSON.stringify(rows.results)).not.toContain(jws);
    expect(JSON.stringify(rows.results)).not.toContain("billingrawmarker");
    const columns = await testEnv.DB.prepare(
      "PRAGMA table_info(billing_transaction_events)",
    ).all<{ name: string }>();
    expect(columns.results.map((column) => column.name).join(" "))
      .not.toMatch(/jws|signature|signed_transaction/iu);
    await expect(testEnv.DB.prepare(
      "UPDATE billing_transaction_events SET product_id = 'tampered' WHERE transaction_id = ?",
    ).bind(verified.transactionId).run()).rejects.toThrow();
  });

  it("records family, refunded, and upgraded facts without treating them as entitlement", async () => {
    await setLowerGate(true);
    const account = await createAccount();
    const now = Date.now();
    const verified = verifiedTransaction(account.billingAccountId, {
      transactionId: "200000000000002",
      originalTransactionId: "200000000000002",
      ownershipType: "FAMILY_SHARED",
      revocationDateMs: now,
      revocationReason: 1,
      isUpgraded: true,
    });
    const response = await recordBillingTransaction(
      await transactionRequest(account, "header.family.signature"),
      testEnv,
      verifier(verified),
    );
    expect(await response.json()).toMatchObject({ disposition: "nonEntitling" });
    expect(await testEnv.DB.prepare(
      `SELECT ownership_type, revocation_reason, is_upgraded
         FROM billing_transaction_events WHERE transaction_id = ?`,
    ).bind(verified.transactionId).first()).toEqual({
      ownership_type: "FAMILY_SHARED",
      revocation_reason: 1,
      is_upgraded: 1,
    });
  });

  it("rejects token reassignment, lineage reassignment, and nonce replay", async () => {
    await setLowerGate(true);
    const first = await createAccount();
    const second = await createAccount();
    const invalidSignatureRequest = await transactionRequest(
      first,
      "header.invalidsignature.signature",
    );
    const invalidSignatureHeaders = new Headers(invalidSignatureRequest.headers);
    invalidSignatureHeaders.set("Neko-Billing-Signature", randomValue(64));
    let invalidSignatureVerifierCalls = 0;
    await expect(recordBillingTransaction(
      new Request(invalidSignatureRequest, { headers: invalidSignatureHeaders }),
      testEnv,
      async () => {
        invalidSignatureVerifierCalls += 1;
        return verifiedTransaction(first.billingAccountId);
      },
    )).rejects.toMatchObject({ status: 401, code: "invalid_billing_authentication" });
    expect(invalidSignatureVerifierCalls).toBe(0);

    await expect(recordBillingTransaction(
      await transactionRequest(first, "header.mismatch.signature"),
      testEnv,
      verifier(verifiedTransaction(second.billingAccountId, {
        transactionId: "200000000000003",
        originalTransactionId: "200000000000003",
      })),
    )).rejects.toMatchObject({ status: 409, code: "billing_account_mismatch" });

    const originalTransactionId = "200000000000004";
    await recordBillingTransaction(
      await transactionRequest(first, "header.first.signature"),
      testEnv,
      verifier(verifiedTransaction(first.billingAccountId, {
        transactionId: originalTransactionId,
        originalTransactionId,
      })),
    );
    await expect(recordBillingTransaction(
      await transactionRequest(second, "header.second.signature"),
      testEnv,
      verifier(verifiedTransaction(second.billingAccountId, {
        transactionId: "200000000000005",
        originalTransactionId,
      })),
    )).rejects.toMatchObject({ status: 409, code: "billing_lineage_conflict" });

    const replayNonce = randomValue(16);
    let verifierCalls = 0;
    const replayVerifier: BillingTransactionVerifier = async () => {
      verifierCalls += 1;
      return verifiedTransaction(first.billingAccountId, {
        transactionId: "200000000000006",
        originalTransactionId: "200000000000006",
      });
    };
    await recordBillingTransaction(
      await transactionRequest(first, "header.replay.signature", replayNonce),
      testEnv,
      replayVerifier,
    );
    await expect(recordBillingTransaction(
      await transactionRequest(first, "header.replay.signature", replayNonce),
      testEnv,
      replayVerifier,
    )).rejects.toMatchObject({ status: 409, code: "replayed_billing_request" });
    expect(verifierCalls).toBe(1);
  });

  it("folds only the latest fact per transaction into a provisional account status", async () => {
    await setLowerGate(true);
    const account = await createAccount();
    const now = Date.now();
    const originalTransactionId = "200000000000020";
    const first = verifiedTransaction(account.billingAccountId, {
      transactionId: originalTransactionId,
      originalTransactionId,
      signedDateMs: now - 4_000,
      expiresDateMs: now + 1_000_000,
    });
    const firstResponse = await recordBillingTransaction(
      await transactionRequest(account, "header.statusfirst.signature"),
      testEnv,
      verifier(first),
    );
    expect(await firstResponse.json()).toMatchObject({
      disposition: "candidate",
      entitlement: {
        status: "activeCandidate",
        productId: first.productId,
        provisional: true,
        grantsPlus: false,
      },
    });

    await recordBillingTransaction(
      await transactionRequest(account, "header.statusrevoked.signature"),
      testEnv,
      verifier({
        ...first,
        signedDateMs: now - 3_000,
        revocationDateMs: now - 3_000,
        revocationReason: 1,
      }),
    );
    const renewal = verifiedTransaction(account.billingAccountId, {
      transactionId: "200000000000021",
      originalTransactionId,
      productId: "jp.nekowidget.plus.annual",
      transactionReason: "RENEWAL",
      purchaseDateMs: now - 2_000,
      expiresDateMs: now + 2_000_000,
      signedDateMs: now - 2_000,
    });
    await recordBillingTransaction(
      await transactionRequest(account, "header.statusrenewal.signature"),
      testEnv,
      verifier(renewal),
    );

    const activeStatus = await getBillingEntitlement(
      await entitlementRequest(account),
      testEnv,
    );
    expect(await activeStatus.json()).toMatchObject({
      billingAccountId: account.billingAccountId,
      entitlement: {
        status: "activeCandidate",
        productId: renewal.productId,
        expiresDateMs: renewal.expiresDateMs,
        lastEventSignedDateMs: renewal.signedDateMs,
        provisional: true,
        grantsPlus: false,
      },
    });
    const otherAccount = await createAccount();
    const isolatedStatus = await getBillingEntitlement(
      await entitlementRequest(otherAccount),
      testEnv,
    );
    expect(await isolatedStatus.json()).toMatchObject({
      billingAccountId: otherAccount.billingAccountId,
      entitlement: {
        status: "noActiveCandidate",
        productId: null,
        provisional: true,
        grantsPlus: false,
      },
    });

    await recordBillingTransaction(
      await transactionRequest(account, "header.statusrenewalrevoked.signature"),
      testEnv,
      verifier({
        ...renewal,
        signedDateMs: now - 1_000,
        revocationDateMs: now - 1_000,
        revocationReason: 0,
      }),
    );
    const inactiveStatus = await getBillingEntitlement(
      await entitlementRequest(account),
      testEnv,
    );
    expect(await inactiveStatus.json()).toMatchObject({
      entitlement: {
        status: "noActiveCandidate",
        productId: null,
        expiresDateMs: null,
        lastEventSignedDateMs: now - 1_000,
        provisional: true,
        grantsPlus: false,
      },
    });
  });

  it("matches the Node verifier HMAC protocol fixture in the Worker runtime", async () => {
    const requestBody = new TextEncoder().encode(fixture.requestBody);
    expect(await bodySHA256(requestBody)).toBe(fixture.requestBodySHA256);
    const requestTranscript = billingVerifierRequestTranscript(
      fixture.timestamp,
      fixture.nonce,
      fixture.requestBodySHA256,
    );
    expect(await signBillingVerifierTranscript(fixture.secret, requestTranscript))
      .toBe(fixture.requestSignature);
    expect(await verifyBillingVerifierTranscript(
      fixture.secret,
      fixture.requestSignature,
      requestTranscript,
    )).toBe(true);

    const responseBody = new TextEncoder().encode(fixture.responseBody);
    expect(await bodySHA256(responseBody)).toBe(fixture.responseBodySHA256);
    const responseTranscript = billingVerifierResponseTranscript(
      fixture.nonce,
      fixture.responseStatus,
      fixture.responseBodySHA256,
    );
    expect(await signBillingVerifierTranscript(fixture.secret, responseTranscript))
      .toBe(fixture.responseSignature);
  });
});
