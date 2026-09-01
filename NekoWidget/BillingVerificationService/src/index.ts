import { loadConfig } from "./config.js";
import { connectRedisBillingVerifierNonceStore } from "./redis-nonce-store.js";
import { listen } from "./server.js";

const config = loadConfig();
const redis = await connectRedisBillingVerifierNonceStore(config.nonceRedisURL);
let listener: Awaited<ReturnType<typeof listen>>;
try {
  listener = await listen(config, {
    nonceStore: redis.nonceStore,
    onFatalDependencyTimeout: () => {
      process.exitCode = 1;
      setTimeout(() => process.exit(1), 100);
    },
  });
} catch {
  await redis.close();
  throw new Error("Billing verifier failed to start");
}

let closing = false;
const close = async (): Promise<void> => {
  if (closing) return;
  closing = true;
  await listener.close();
  await redis.close();
};
process.once("SIGINT", () => { void close(); });
process.once("SIGTERM", () => { void close(); });
