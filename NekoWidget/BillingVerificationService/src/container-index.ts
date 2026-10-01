import { loadContainerConfig } from "./config.js";
import { DurableBillingVerifierNonceStore } from "./durable-nonce-store.js";
import { billingVerifierNonceScope } from "./nonce-store.js";
import { listen } from "./server.js";

const config = loadContainerConfig();
const nonceStore = new DurableBillingVerifierNonceStore(billingVerifierNonceScope(config));
await nonceStore.connect();
const listener = await listen(config, {
  nonceStore, onFatalDependencyTimeout: () => {
    process.exitCode = 1;
    setTimeout(() => process.exit(1), 100);
  },
}, undefined, {}, "0.0.0.0");
const close = async () => { await listener.close(); process.exitCode = 0; };
process.once("SIGTERM", () => { void close(); });
process.once("SIGINT", () => { void close(); });
