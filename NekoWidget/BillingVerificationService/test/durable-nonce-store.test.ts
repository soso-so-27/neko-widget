import assert from "node:assert/strict";
import test from "node:test";
import { DurableBillingVerifierNonceStore, nonceScopeDigest } from "../src/durable-nonce-store.js";
import { loadContainerConfig } from "../src/config.js";
const scope = "nwb:verifier:v1:Sandbox:jp.nekowidget.app";
const input = { scope, nonce: Buffer.alloc(16, 9).toString("base64url"), retentionSeconds: 601 };
test("private nonce adapter sends only opaque hashes and validates every outcome", async () => {
  let calls = 0;
  const store = new DurableBillingVerifierNonceStore(scope, async (url, init) => {
    assert.equal(new URL(String(url)).origin, "http://billing-nonce.internal.invalid");
    assert.equal(new Headers(init?.headers).get("neko-nonce-scope"), nonceScopeDigest(scope));
    assert.equal(init?.redirect, "error");
    calls++;
    if (String(url).endsWith("/ready")) return Response.json({ ready: true });
    const body = JSON.parse(init?.body as string) as { digest: string };
    assert.deepEqual(Object.keys(body), ["digest"]);
    assert.match(body.digest, /^[A-Za-z0-9_-]{43}$/u);
    assert.equal((init?.body as string).includes(input.nonce), false);
    assert.equal((init?.body as string).includes("jp.nekowidget.app"), false);
    return Response.json({ outcome: calls === 2 ? "claimed" : "replayed" });
  });
  assert.equal(store.ready(), false);
  await store.connect();
  assert.equal(store.ready(), true);
  assert.equal(await store.claim(input), "claimed");
  assert.equal(await store.claim(input), "replayed");
});
test("nonce failures, extra response fields, oversize and lost responses fail closed without retry", async () => {
  for (const response of [Response.json({ outcome: "claimed", extra: true }),
    Response.json({ outcome: "unknown" }), new Response("x".repeat(513)), new Response(null, { status: 503 }), null]) {
    let calls = 0;
    const store = new DurableBillingVerifierNonceStore(scope, async () => {
      calls++; if (response === null) throw new Error("Synthetic connection lost"); return response;
    });
    await assert.rejects(store.claim(input), /dependency unavailable/);
    assert.equal(calls, 1);
    assert.equal(store.ready(), false);
  }
});
test("scope, retention and noncanonical nonce mismatches do not reach storage", async () => {
  const store = new DurableBillingVerifierNonceStore(scope, async () => { throw new Error("Must not fetch"); });
  for (const bad of [{ ...input, scope: scope.replace("Sandbox", "Production") },
    { ...input, retentionSeconds: 600 }, { ...input, nonce: "A".repeat(21) + "B" }]) {
    await assert.rejects(store.claim(bad), /Invalid billing nonce/);
  }
});
test("container configuration retains identity gates and cannot adopt Redis settings", () => {
  const env = { BILLING_VERIFIER_RUNTIME_ENABLED: "YES", BILLING_VERIFIER_CONTAINER_RUNTIME_ENABLED: "YES",
    BILLING_VERIFIER_SHARED_SECRET: Buffer.alloc(32, 9).toString("base64url"),
    APPLE_ROOT_CERTIFICATES_BASE64_JSON: JSON.stringify([Buffer.alloc(300, 1).toString("base64")]),
    BILLING_STORE_ENVIRONMENT: "Sandbox", BILLING_BUNDLE_ID: "jp.nekowidget.app",
    BILLING_SUBSCRIPTION_GROUP_ID: "20999999", BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly" };
  assert.equal(loadContainerConfig(env).environment, "Sandbox");
  assert.equal(loadContainerConfig(env).subscriptionStatusEnabled, false);
  for (const bad of [{ ...env, BILLING_VERIFIER_RUNTIME_ENABLED: "NO" },
    { ...env, BILLING_VERIFIER_CONTAINER_RUNTIME_ENABLED: "NO" },
    { ...env, BILLING_NONCE_REDIS_URL: "rediss://unused.invalid" },
    { ...env, BILLING_BUNDLE_ID: "wrong id" }]) assert.throws(() => loadContainerConfig(bad));
});
