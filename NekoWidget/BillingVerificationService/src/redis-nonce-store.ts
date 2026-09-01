import { createHash } from "node:crypto";
import { createClient } from "@redis/client";
import type {
  BillingVerifierNonceClaim,
  BillingVerifierNonceStore,
} from "./nonce-store.js";

type AtomicRedisClaim = (
  key: string,
  retentionSeconds: number,
) => Promise<unknown>;

export function redisNonceSetOptions(retentionSeconds: number) {
  return {
    condition: "NX" as const,
    expiration: { type: "EX" as const, value: retentionSeconds },
  };
}

export function redisNonceClientOptions(url: string) {
  const parsed = new URL(url);
  return {
    url,
    socket: {
      tls: true as const,
      servername: parsed.hostname,
      rejectUnauthorized: true,
      connectTimeout: 2_000,
      reconnectStrategy: (retries: number) => (
        retries >= 3 ? false : Math.min(100 * (2 ** retries), 1_000)
      ),
    },
    disableOfflineQueue: true,
    commandsQueueMaxLength: 32,
    commandOptions: { timeout: 1_500 },
    disableClientInfo: true,
  };
}

export class RedisBillingVerifierNonceStore implements BillingVerifierNonceStore {
  constructor(
    private readonly atomicClaim: AtomicRedisClaim,
    private readonly isReady: () => boolean = () => true,
  ) {}

  ready(): boolean {
    return this.isReady();
  }

  async claim(input: BillingVerifierNonceClaim): Promise<"claimed" | "replayed"> {
    if (
      input.scope === ""
      || !/^[A-Za-z0-9_-]{22}$/u.test(input.nonce)
      || Buffer.from(input.nonce, "base64url").length !== 16
      || !Number.isSafeInteger(input.retentionSeconds)
      || input.retentionSeconds < 1
      || input.retentionSeconds > 3_600
    ) {
      throw new Error("Invalid billing verifier nonce claim");
    }
    const digest = createHash("sha256")
      .update(input.scope, "utf8")
      .update("\0", "utf8")
      .update(input.nonce, "ascii")
      .digest("base64url");
    const result = await this.atomicClaim(`nwb:verifier:nonce:${digest}`, input.retentionSeconds);
    if (result === "OK") return "claimed";
    if (result === null) return "replayed";
    throw new Error("Unexpected billing verifier nonce store response");
  }
}

export async function connectRedisBillingVerifierNonceStore(
  url: string,
): Promise<{ nonceStore: BillingVerifierNonceStore; close: () => Promise<void> }> {
  const client = createClient(redisNonceClientOptions(url));
  // node-redis requires an error listener. Metrics are added at the private
  // ingress layer; never log errors here because URLs may contain credentials.
  client.on("error", () => {});
  try {
    await client.connect();
  } catch {
    if (client.isOpen) client.destroy();
    throw new Error("Billing verifier nonce store is unavailable");
  }
  return {
    nonceStore: new RedisBillingVerifierNonceStore(
      async (key, retentionSeconds) => (
        client.set(key, "1", redisNonceSetOptions(retentionSeconds))
      ),
      () => client.isReady,
    ),
    close: async () => {
      if (client.isOpen) await client.close();
    },
  };
}
