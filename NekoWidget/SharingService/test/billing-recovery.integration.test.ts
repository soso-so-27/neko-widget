import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { base64urlEncode } from "../src/encoding";
import { sha256Base64url } from "../src/encoding";
import type { Env } from "../src/env";
import { billingAccountRecoveryTranscript } from "../src/billing-protocol";
import { recoverBillingAccount } from "../src/billing-recovery";
import type { VerifiedBillingTransaction } from "../src/billing-verifier-client";
import type { VerifiedSubscriptionStatus } from "../src/billing-apple-client";
import { runBillingSubscriptionReconciliation } from "../src/billing-authority";

const testEnv = env as unknown as Env;
function random(bytes: number): string {
  const value = new Uint8Array(bytes); crypto.getRandomValues(value); return base64urlEncode(value);
}
function buffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length); copy.set(bytes); return copy.buffer;
}

async function seed(mode: "existing" | "missing-lineage" | "new" = "existing") {
  const account = crypto.randomUUID().toLowerCase();
  const original = String(BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 999)));
  const oldKey = random(16); const oldPublicKey = random(32);
  if (mode === "new") return { account, original, oldKey, oldPublicKey };
  await testEnv.DB.prepare("INSERT INTO billing_accounts(id) VALUES (?)").bind(account).run();
  await testEnv.DB.prepare(
    "INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state) VALUES(?,?,?,'active')",
  ).bind(oldKey, account, oldPublicKey).run();
  if (mode === "missing-lineage") return { account, original, oldKey, oldPublicKey };
  await testEnv.DB.prepare(
    `INSERT INTO billing_transaction_lineages(
       original_transaction_id,billing_account_id,environment,subscription_group_id
     ) VALUES(?,?,'Sandbox','20999999')`,
  ).bind(original, account).run();
  return { account, original, oldKey, oldPublicKey };
}

async function setGate(enabled: boolean) {
  const row = await testEnv.DB.prepare("SELECT generation FROM billing_runtime_gate WHERE singleton=1")
    .first<{ generation: number }>();
  await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate SET generation=generation+1, account_recovery_enabled=?,
       updated_at=unixepoch() WHERE singleton=1 AND generation=?`,
  ).bind(enabled ? 1 : 0, row!.generation).run();
}

async function keyPair() {
  return crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
}

async function recoveryFixture(mode: "existing" | "missing-lineage" | "new" = "existing", prior?: Awaited<ReturnType<typeof seed>>) {
  const seeded = prior ?? await seed(mode); const keys = await keyPair();
  const publicKey = base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
  const clientRequestId = crypto.randomUUID().toLowerCase();
  const deviceVerificationId = crypto.randomUUID().toLowerCase();
  const signedAppTransactionInfo = "a.b.c"; const signedTransactionInfo = "d.e.f";
  const text = new TextEncoder();
  const transcript = billingAccountRecoveryTranscript({
    clientRequestId, billingAccountId: seeded.account, signingPublicKey: publicKey,
    deviceVerificationId, expectedAppTransactionId: "opaque-app-id",
    expectedTransactionId: seeded.original, expectedOriginalTransactionId: seeded.original,
    signedAppTransactionHash: await sha256Base64url(text.encode(signedAppTransactionInfo)),
    signedTransactionHash: await sha256Base64url(text.encode(signedTransactionInfo)),
  });
  const signature = base64urlEncode(new Uint8Array(
    await crypto.subtle.sign("Ed25519", keys.privateKey, buffer(transcript)),
  ));
  const body = JSON.stringify({ protocolVersion: 1, clientRequestId,
    billingAccountId: seeded.account, signingPublicKey: publicKey, deviceVerificationId,
    expectedAppTransactionId: "opaque-app-id", signedAppTransactionInfo, signedTransactionInfo,
    expectedTransactionId: seeded.original, expectedOriginalTransactionId: seeded.original,
    recoverySignature: signature });
  const now = Date.now();
  const transaction: VerifiedBillingTransaction = {
    transactionId: seeded.original, originalTransactionId: seeded.original,
    billingAccountId: seeded.account, productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupId: "20999999", bundleId: "jp.nekowidget.app",
    environment: "Sandbox" as const, ownershipType: "PURCHASED" as const,
    transactionReason: "PURCHASE" as const, purchaseDateMs: now - 10_000,
    originalPurchaseDateMs: now - 10_000, expiresDateMs: now + 60_000,
    signedDateMs: now, revocationDateMs: null, revocationReason: null,
    isUpgraded: false,
  };
  return { seeded, clientRequestId, body, now, transaction };
}

function liveStatus(f: Awaited<ReturnType<typeof recoveryFixture>>): VerifiedSubscriptionStatus {
  return { requestedTransactionId: f.seeded.original,
    environment: f.transaction.environment, bundleId: f.transaction.bundleId,
    fetchedAtMs: f.now, items: [{ status: 1 as const,
      originalTransactionId: f.seeded.original, transaction: f.transaction,
      renewal: { originalTransactionId: f.seeded.original, billingAccountId: f.seeded.account,
        productId: f.transaction.productId, autoRenewProductId: null, autoRenewStatus: 1 as const,
        isInBillingRetryPeriod: false, gracePeriodExpiresDateMs: null,
        renewalDateMs: null, signedDateMs: f.now, environment: f.transaction.environment },
    }] };
}
function recoveryRequest(f: Awaited<ReturnType<typeof recoveryFixture>>) {
  return new Request("https://example.test/v1/billing/accounts/recover", {
    method: "POST", headers: { "content-type": "application/json" }, body: f.body,
  });
}

describe("first Apple-authorized purchase import", () => {
  it.each([
    ["new", "Sandbox"], ["new", "Production"], ["missing-lineage", "Sandbox"], ["missing-lineage", "Production"],
  ] as const)("imports %s in %s and schedules authority without granting a local entitlement", async (mode, storeEnvironment) => {
    const f = await recoveryFixture(mode); const hash = random(32);
    f.transaction.environment = storeEnvironment;
    await setGate(true);
    try {
      const response = await recoverBillingAccount(recoveryRequest(f), testEnv,
        async () => ({ appTransactionIdHash: hash, transaction: f.transaction }),
        async (_id, _env, environment) => {
          expect(environment).toBe(storeEnvironment); return liveStatus(f);
        });
      expect(response.status).toBe(200);
      const result = await response.json() as { billingKeyId: string };
      expect((await testEnv.DB.prepare("SELECT id FROM billing_account_keys WHERE billing_account_id=? AND state='active'")
        .bind(f.seeded.account).all()).results).toEqual([{ id: result.billingKeyId }]);
      expect(await testEnv.DB.prepare("SELECT billing_account_id,environment FROM billing_transaction_lineages WHERE original_transaction_id=?")
        .bind(f.seeded.original).first()).toEqual({ billing_account_id: f.seeded.account, environment: storeEnvironment });
      expect(await testEnv.DB.prepare("SELECT environment,request_generation FROM billing_reconciliation_jobs WHERE original_transaction_id=?")
        .bind(f.seeded.original).first()).toEqual({ environment: storeEnvironment, request_generation: 1 });
      expect(await testEnv.DB.prepare("SELECT 1 FROM billing_effective_entitlement_current WHERE original_transaction_id=?")
        .bind(f.seeded.original).first()).toBeNull();
      const replay = await recoverBillingAccount(recoveryRequest(f), testEnv,
        async () => { throw new Error("unexpected verifier replay"); },
        async () => { throw new Error("unexpected Apple replay"); });
      expect(await replay.json()).toEqual(result);
      await testEnv.DB.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,
        subscription_reconciliation_enabled=1,effective_entitlement_enabled=1,updated_at=unixepoch() WHERE singleton=1`).run();
      await runBillingSubscriptionReconciliation({ ...testEnv, BILLING_STORE_ENVIRONMENT: "Production",
        BILLING_ACCEPT_SANDBOX_IN_PRODUCTION: "YES" }, async () => liveStatus(f));
      expect(await testEnv.DB.prepare(`SELECT environment,materialized_grants_plus FROM billing_effective_entitlement_current
        WHERE original_transaction_id=?`).bind(f.seeded.original).first())
        .toEqual({ environment: storeEnvironment, materialized_grants_plus: 1 });
    } finally { await setGate(false); }
  });

  it.each(["stale", "environment", "account", "expired", "revoked"] as const)("rejects %s live authority without creating an account", async (failure) => {
    const f = await recoveryFixture("new"); const status = liveStatus(f);
    if (failure === "stale") status.fetchedAtMs -= 61_000;
    if (failure === "environment") status.environment = "Production";
    if (failure === "account") status.items[0]!.transaction = { ...f.transaction, billingAccountId: crypto.randomUUID() };
    if (failure === "expired") status.items[0]!.transaction = { ...f.transaction, expiresDateMs: f.now - 1 };
    if (failure === "revoked") status.items[0]!.transaction = { ...f.transaction, revocationDateMs: f.now - 1 };
    await setGate(true);
    try {
      await expect(recoverBillingAccount(recoveryRequest(f), testEnv,
        async () => ({ appTransactionIdHash: random(32), transaction: f.transaction }),
        async () => status)).rejects.toMatchObject({ status: 409, code: "billing_recovery_authority_denied" });
      expect(await testEnv.DB.prepare("SELECT id FROM billing_accounts WHERE id=?").bind(f.seeded.account).first()).toBeNull();
    } finally { await setGate(false); }
  });

  it("requires device-bound Apple verification and a signature over the exact request before any import", async () => {
    const f = await recoveryFixture("new");
    await setGate(true);
    try {
      await expect(recoverBillingAccount(recoveryRequest(f), testEnv,
        async () => { throw new Error("invalid Apple device proof"); },
        async () => { throw new Error("must not fetch after invalid proof"); })).rejects.toThrow("invalid Apple device proof");
      const tampered = { ...f, body: JSON.stringify({ ...JSON.parse(f.body), billingAccountId: crypto.randomUUID() }) };
      await expect(recoverBillingAccount(recoveryRequest(tampered), testEnv,
        async () => { throw new Error("must not verify unsigned mutation"); },
        async () => liveStatus(f))).rejects.toMatchObject({ code: "invalid_billing_recovery_signature" });
      expect(await testEnv.DB.prepare("SELECT id FROM billing_accounts WHERE id=?").bind(f.seeded.account).first()).toBeNull();
    } finally { await setGate(false); }
  });

  it("rolls back the initial account, key, receipt and lineage on a late Apple identity collision", async () => {
    const other = await seed(); const hash = random(32);
    await testEnv.DB.prepare("INSERT INTO billing_account_apple_identities(billing_account_id,app_transaction_id_hash,environment,first_original_transaction_id) VALUES(?,?,'Sandbox',?)")
      .bind(other.account, hash, other.original).run();
    const f = await recoveryFixture("new");
    await setGate(true);
    try {
      await expect(recoverBillingAccount(recoveryRequest(f), testEnv,
        async () => ({ appTransactionIdHash: hash, transaction: f.transaction }),
        async () => liveStatus(f))).rejects.toMatchObject({ code: "billing_recovery_conflict" });
      for (const table of ["billing_accounts", "billing_account_keys", "billing_account_bootstrap_requests", "billing_transaction_lineages"]) {
        const column = table === "billing_accounts" ? "id" : "billing_account_id";
        expect(await testEnv.DB.prepare(`SELECT 1 FROM ${table} WHERE ${column}=?`).bind(f.seeded.account).first()).toBeNull();
      }
      expect(await testEnv.DB.prepare("SELECT 1 FROM billing_reconciliation_jobs WHERE original_transaction_id=?").bind(f.seeded.original).first()).toBeNull();
    } finally { await setGate(false); }
  });

  it.each(["new", "missing-lineage"] as const)("keeps one winning key for parallel %s imports", async (mode) => {
    const first = await recoveryFixture(mode);
    const second = await recoveryFixture(mode, first.seeded);
    const hash = random(32); let arrived = 0; let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    await setGate(true);
    try {
      const execute = (f: typeof first) => recoverBillingAccount(recoveryRequest(f), testEnv,
        async () => ({ appTransactionIdHash: hash, transaction: f.transaction }),
        async () => { if (++arrived === 2) release(); await barrier; return liveStatus(f); });
      const results = await Promise.allSettled([execute(first), execute(second)]);
      expect(results.filter(r => r.status === "fulfilled")).toHaveLength(1);
      expect(results.filter(r => r.status === "rejected")).toHaveLength(1);
      const winner = results.find(r => r.status === "fulfilled") as PromiseFulfilledResult<Response>;
      const body = await winner.value.json() as { billingKeyId: string };
      expect((await testEnv.DB.prepare("SELECT id FROM billing_account_keys WHERE billing_account_id=? AND state='active'")
        .bind(first.seeded.account).all()).results).toEqual([{ id: body.billingKeyId }]);
    } finally { await setGate(false); }
  });
});

describe("billing account recovery migration", () => {
  it("keeps recovery disabled by default", async () => {
    const row = await testEnv.DB.prepare(
      "SELECT account_recovery_enabled FROM billing_runtime_gate WHERE singleton=1",
    ).first<{ account_recovery_enabled: number }>();
    expect(row?.account_recovery_enabled).toBe(0);
  });

  it("atomically revokes the old key, binds Apple identity, and installs one new key", async () => {
    const value = await seed();
    const newKey = random(16); const hash = random(32); const publicKey = random(32);
    await testEnv.DB.prepare(
      `INSERT INTO billing_account_recovery_requests(
        environment,client_request_id,request_hash,billing_account_id,expected_generation,
        expected_transaction_id,expected_original_transaction_id,app_transaction_id_hash,
        replaced_billing_key_id,new_billing_key_id,new_signing_public_key
      ) VALUES('Sandbox',?,?,?,0,?,?,?,?,?,?)`,
    ).bind(crypto.randomUUID().toLowerCase(), random(32), value.account,
      value.original, value.original, hash, value.oldKey, newKey, publicKey).run();
    const keys = await testEnv.DB.prepare(
      "SELECT id,state FROM billing_account_keys WHERE billing_account_id=? ORDER BY id",
    ).bind(value.account).all<{ id: string; state: string }>();
    expect(keys.results).toEqual(expect.arrayContaining([
      { id: value.oldKey, state: "revoked" }, { id: newKey, state: "active" },
    ]));
    expect((await testEnv.DB.prepare(
      "SELECT generation FROM billing_account_key_state WHERE billing_account_id=?",
    ).bind(value.account).first<{ generation: number }>())?.generation).toBe(1);
  });

  it("lets exactly one concurrent generation win and cannot revoke the winner", async () => {
    const value = await seed(); const hash = random(32);
    const insert = (key: string, publicKey: string) => testEnv.DB.prepare(
      `INSERT INTO billing_account_recovery_requests(
        environment,client_request_id,request_hash,billing_account_id,expected_generation,
        expected_transaction_id,expected_original_transaction_id,app_transaction_id_hash,
        replaced_billing_key_id,new_billing_key_id,new_signing_public_key
      ) VALUES('Sandbox',?,?,?,0,?,?,?,?,?,?)`,
    ).bind(crypto.randomUUID().toLowerCase(), random(32), value.account,
      value.original, value.original, hash, value.oldKey, key, publicKey).run();
    const winner = random(16); await insert(winner, random(32));
    await expect(insert(random(16), random(32))).rejects.toThrow();
    const active = await testEnv.DB.prepare(
      "SELECT id FROM billing_account_keys WHERE billing_account_id=? AND state='active'",
    ).bind(value.account).all<{ id: string }>();
    expect(active.results).toEqual([{ id: winner }]);
  });

  it("rotates only after device-bound evidence and live active authority both succeed", async () => {
    const seeded = await seed(); const keys = await keyPair();
    const publicKey = base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
    const clientRequestId = crypto.randomUUID().toLowerCase();
    const deviceVerificationId = crypto.randomUUID().toLowerCase();
    const signedAppTransactionInfo = "a.b.c"; const signedTransactionInfo = "d.e.f";
    const text = new TextEncoder();
    const transcript = billingAccountRecoveryTranscript({
      clientRequestId, billingAccountId: seeded.account, signingPublicKey: publicKey,
      deviceVerificationId, expectedAppTransactionId: "opaque-app-id",
      expectedTransactionId: seeded.original, expectedOriginalTransactionId: seeded.original,
      signedAppTransactionHash: await sha256Base64url(text.encode(signedAppTransactionInfo)),
      signedTransactionHash: await sha256Base64url(text.encode(signedTransactionInfo)),
    });
    const signature = base64urlEncode(new Uint8Array(await crypto.subtle.sign("Ed25519", keys.privateKey, buffer(transcript))));
    const body = JSON.stringify({ protocolVersion: 1, clientRequestId,
      billingAccountId: seeded.account, signingPublicKey: publicKey, deviceVerificationId,
      expectedAppTransactionId: "opaque-app-id", signedAppTransactionInfo, signedTransactionInfo,
      expectedTransactionId: seeded.original, expectedOriginalTransactionId: seeded.original,
      recoverySignature: signature });
    const now = Date.now();
    const transaction = {
      transactionId: seeded.original, originalTransactionId: seeded.original,
      billingAccountId: seeded.account, productId: "jp.nekowidget.plus.monthly",
      subscriptionGroupId: "20999999", bundleId: "jp.nekowidget.app",
      environment: "Sandbox" as const, ownershipType: "PURCHASED" as const,
      transactionReason: "PURCHASE" as const, purchaseDateMs: now - 10_000,
      originalPurchaseDateMs: now - 10_000, expiresDateMs: now + 60_000,
      signedDateMs: now, revocationDateMs: null, revocationReason: null,
      isUpgraded: false,
    };
    await setGate(true);
    try {
      const result = await recoverBillingAccount(new Request("https://example.test/v1/billing/accounts/recover", {
        method: "POST", headers: { "content-type": "application/json" }, body,
      }), testEnv,
      async () => ({ appTransactionIdHash: random(32), transaction }),
      async () => ({ requestedTransactionId: seeded.original, environment: "Sandbox",
        bundleId: "jp.nekowidget.app", fetchedAtMs: now, items: [{ status: 1 as const,
          originalTransactionId: seeded.original, transaction,
          renewal: { originalTransactionId: seeded.original, billingAccountId: seeded.account,
            productId: transaction.productId, autoRenewProductId: null, autoRenewStatus: 0 as const,
            isInBillingRetryPeriod: false, gracePeriodExpiresDateMs: null,
            renewalDateMs: null, signedDateMs: now, environment: "Sandbox" as const },
        }] }),
      );
      expect(result.status).toBe(200);
      expect((await result.json() as { clientRequestId: string }).clientRequestId).toBe(clientRequestId);
    } finally { await setGate(false); }
  });

  it.each(["revoked", "upgraded", "family"] as const)(
    "fails restrictive when exact-time authority conflicts with %s evidence",
    async (conflict) => {
      const fixture = await recoveryFixture();
      const restrictive = {
        ...fixture.transaction,
        ownershipType: conflict === "family"
          ? "FAMILY_SHARED" as const : "PURCHASED" as const,
        revocationDateMs: conflict === "revoked" ? fixture.now - 1 : null,
        revocationReason: conflict === "revoked" ? 1 as const : null,
        isUpgraded: conflict === "upgraded",
      };
      const renewal = {
        originalTransactionId: fixture.seeded.original,
        billingAccountId: fixture.seeded.account,
        productId: fixture.transaction.productId,
        autoRenewProductId: null,
        autoRenewStatus: 1 as const,
        isInBillingRetryPeriod: false,
        gracePeriodExpiresDateMs: null,
        renewalDateMs: null,
        signedDateMs: fixture.now,
        environment: "Sandbox" as const,
      };
      await setGate(true);
      try {
        await expect(recoverBillingAccount(new Request(
          "https://example.test/v1/billing/accounts/recover",
          { method: "POST", headers: { "content-type": "application/json" }, body: fixture.body },
        ), testEnv,
        async () => ({ appTransactionIdHash: random(32), transaction: fixture.transaction }),
        async () => ({
          requestedTransactionId: fixture.seeded.original,
          environment: "Sandbox", bundleId: "jp.nekowidget.app",
          fetchedAtMs: fixture.now,
          // Put the clean row first and keep every signed time/status equal;
          // the shared selector must still choose the restrictive evidence.
          items: [
            { status: 1 as const, originalTransactionId: fixture.seeded.original,
              transaction: fixture.transaction, renewal },
            { status: 1 as const, originalTransactionId: fixture.seeded.original,
              transaction: restrictive, renewal },
          ],
        }))).rejects.toMatchObject({
          status: 409,
          code: "billing_recovery_authority_denied",
        });
        expect((await testEnv.DB.prepare(
          "SELECT generation FROM billing_account_key_state WHERE billing_account_id=?",
        ).bind(fixture.seeded.account).first<{ generation: number }>())?.generation).toBe(0);
        expect((await testEnv.DB.prepare(
          "SELECT state FROM billing_account_keys WHERE id=?",
        ).bind(fixture.seeded.oldKey).first<{ state: string }>())?.state).toBe("active");
      } finally { await setGate(false); }
    },
  );

  it("replays a committed response without rechecking Apple or exposing raw proof", async () => {
    const fixture = await recoveryFixture(); let verifierCalls = 0; let statusCalls = 0;
    const request = () => new Request("https://example.test/v1/billing/accounts/recover", {
      method: "POST", headers: { "content-type": "application/json" }, body: fixture.body,
    });
    const verify = async () => {
      verifierCalls += 1;
      return { appTransactionIdHash: random(32), transaction: fixture.transaction };
    };
    const fetchStatus = async () => {
      statusCalls += 1;
      return { requestedTransactionId: fixture.seeded.original,
        environment: "Sandbox" as const, bundleId: "jp.nekowidget.app",
        fetchedAtMs: fixture.now, items: [{ status: 1 as const,
          originalTransactionId: fixture.seeded.original, transaction: fixture.transaction,
          renewal: { originalTransactionId: fixture.seeded.original,
            billingAccountId: fixture.seeded.account, productId: fixture.transaction.productId,
            autoRenewProductId: null, autoRenewStatus: 1 as const,
            isInBillingRetryPeriod: false, gracePeriodExpiresDateMs: null,
            renewalDateMs: null, signedDateMs: fixture.now,
            environment: "Sandbox" as const },
        }] };
    };
    await setGate(true);
    try {
      const first = await recoverBillingAccount(request(), testEnv, verify, fetchStatus);
      const firstBody = await first.json() as Record<string, unknown>;
      const replay = await recoverBillingAccount(request(), testEnv,
        async () => { throw new Error("verifier must not run for committed replay"); },
        async () => { throw new Error("status must not run for committed replay"); });
      expect(await replay.json()).toEqual(firstBody);
      expect(verifierCalls).toBe(1); expect(statusCalls).toBe(1);
      const audit = await testEnv.DB.prepare(
        "SELECT * FROM billing_account_recovery_requests WHERE client_request_id=?",
      ).bind(fixture.clientRequestId).first<Record<string, unknown>>();
      expect(JSON.stringify(audit)).not.toContain("a.b.c");
      expect(JSON.stringify(audit)).not.toContain("d.e.f");
      expect(JSON.stringify(audit)).not.toContain(
        (JSON.parse(fixture.body) as { deviceVerificationId: string }).deviceVerificationId,
      );
    } finally { await setGate(false); }
  });

  it("rolls back the old-key revocation when the AFTER trigger cannot insert the new key", async () => {
    const fixture = await seed(); const collidingKey = random(16);
    await testEnv.DB.prepare(
      `INSERT INTO billing_account_keys(
        id,billing_account_id,signing_public_key,state,revoked_at
      ) VALUES(?,?,?,'revoked',unixepoch())`,
    ).bind(collidingKey, fixture.account, random(32)).run();
    await expect(testEnv.DB.prepare(
      `INSERT INTO billing_account_recovery_requests(
        environment,client_request_id,request_hash,billing_account_id,expected_generation,
        expected_transaction_id,expected_original_transaction_id,app_transaction_id_hash,
        replaced_billing_key_id,new_billing_key_id,new_signing_public_key
      ) VALUES('Sandbox',?,?,?,0,?,?,?,?,?,?)`,
    ).bind(crypto.randomUUID().toLowerCase(), random(32), fixture.account,
      fixture.original, fixture.original, random(32), fixture.oldKey,
      collidingKey, random(32)).run()).rejects.toThrow();
    expect((await testEnv.DB.prepare(
      "SELECT state FROM billing_account_keys WHERE id=?",
    ).bind(fixture.oldKey).first<{ state: string }>())?.state).toBe("active");
    expect((await testEnv.DB.prepare(
      "SELECT generation FROM billing_account_key_state WHERE billing_account_id=?",
    ).bind(fixture.account).first<{ generation: number }>())?.generation).toBe(0);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_account_recovery_requests WHERE billing_account_id=?",
    ).bind(fixture.account).first<{ count: number }>())?.count).toBe(0);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_account_apple_identities WHERE billing_account_id=?",
    ).bind(fixture.account).first<{ count: number }>())?.count).toBe(0);
  });
});
