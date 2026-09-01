import assert from "node:assert/strict";
import test from "node:test";
import {
  RedisBillingVerifierNonceStore,
  redisNonceClientOptions,
  redisNonceSetOptions,
} from "../src/redis-nonce-store.js";

const claim = {
  scope: "nwb:verifier:v1:Sandbox:jp.nekowidget.app",
  nonce: "4pKv7Kqzb_sLLmA3k6Pn5A",
  retentionSeconds: 601,
};

test("uses an opaque fixed Redis key and atomic claim retention", async () => {
  const calls: { key: string; retentionSeconds: number }[] = [];
  const store = new RedisBillingVerifierNonceStore(async (key, retentionSeconds) => {
    calls.push({ key, retentionSeconds });
    return "OK";
  });
  assert.equal(await store.claim(claim), "claimed");
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.retentionSeconds, 601);
  assert.match(calls[0]?.key ?? "", /^nwb:verifier:nonce:[A-Za-z0-9_-]{43}$/u);
  assert.equal(calls[0]?.key.includes(claim.nonce), false);
  assert.equal(calls[0]?.key.includes("jp.nekowidget.app"), false);
});

test("maps an existing Redis key to replay without a fallback", async () => {
  const store = new RedisBillingVerifierNonceStore(async () => null);
  assert.equal(await store.claim(claim), "replayed");
});

test("pins TLS, bounded queues, and an atomic SET NX EX command", () => {
  const options = redisNonceClientOptions("rediss://billing-nonce.invalid:6380/0");
  assert.equal(options.socket.tls, true);
  assert.equal(options.socket.servername, "billing-nonce.invalid");
  assert.equal(options.socket.rejectUnauthorized, true);
  assert.equal(options.disableOfflineQueue, true);
  assert.equal(options.commandsQueueMaxLength, 32);
  assert.equal(options.commandOptions.timeout, 1_500);
  assert.equal(options.socket.reconnectStrategy(0), 100);
  assert.equal(options.socket.reconnectStrategy(1), 200);
  assert.equal(options.socket.reconnectStrategy(2), 400);
  assert.equal(options.socket.reconnectStrategy(3), false);
  assert.deepEqual(redisNonceSetOptions(601), {
    condition: "NX",
    expiration: { type: "EX", value: 601 },
  });
});

test("fails closed for invalid claims, store errors, and unexpected replies", async () => {
  const invalid = new RedisBillingVerifierNonceStore(async () => "OK");
  await assert.rejects(() => invalid.claim({ ...claim, retentionSeconds: 0 }), {
    message: "Invalid billing verifier nonce claim",
  });

  const unavailable = new RedisBillingVerifierNonceStore(async () => {
    throw new Error("redis unavailable");
  });
  await assert.rejects(() => unavailable.claim(claim), /redis unavailable/u);

  const unexpected = new RedisBillingVerifierNonceStore(async () => "QUEUED");
  await assert.rejects(() => unexpected.claim(claim), /Unexpected/u);
});
