import { createHash } from "node:crypto";
import type { BillingVerifierNonceClaim, BillingVerifierNonceStore } from "./nonce-store.js";
import { BILLING_VERIFIER_NONCE_RETENTION_SECONDS } from "./nonce-store.js";

// Only the isolated container's outbound handler resolves this virtual host.
// There is no public-HTTP fallback or configurable credential-bearing URL.
const origin = "http://billing-nonce.internal.invalid";
export function nonceScopeDigest(scope: string): string {
  return createHash("sha256").update(scope, "utf8").digest("base64url");
}

export class DurableBillingVerifierNonceStore implements BillingVerifierNonceStore {
  private connected = false;
  constructor(private readonly scope: string, private readonly fetcher: typeof fetch = fetch) {}
  ready(): boolean { return this.connected; }

  private async request(path: string, body?: object): Promise<Record<string, unknown>> {
    try {
      const response = await this.fetcher(`${origin}${path}`, {
        method: body === undefined ? "GET" : "POST",
        headers: { "content-type": "application/json", "neko-nonce-scope": nonceScopeDigest(this.scope) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        redirect: "error", signal: AbortSignal.timeout(1500),
      });
      if (response.status !== 200 || !response.body) throw new Error();
      const reader = response.body.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          if ((size += value.byteLength) > 512) throw new Error();
          chunks.push(value);
        }
      } catch { void reader.cancel().catch(() => undefined); throw new Error(); }
      const raw: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new Error();
      return raw as Record<string, unknown>;
    } catch {
      this.connected = false;
      throw new Error("Billing nonce dependency unavailable");
    }
  }

  async connect(): Promise<void> {
    const reply = await this.request("/ready");
    if (Object.keys(reply).length !== 1 || reply.ready !== true) {
      this.connected = false;
      throw new Error("Billing nonce dependency unavailable");
    }
    this.connected = true;
  }

  async claim(input: BillingVerifierNonceClaim): Promise<"claimed" | "replayed"> {
    const bytes = Buffer.from(input.nonce, "base64url");
    if (input.scope !== this.scope || this.scope.length < 1 || this.scope.length > 512
      || !/^[A-Za-z0-9_-]{22}$/u.test(input.nonce) || bytes.length !== 16
      || bytes.toString("base64url") !== input.nonce
      || input.retentionSeconds !== BILLING_VERIFIER_NONCE_RETENTION_SECONDS) {
      throw new Error("Invalid billing nonce claim");
    }
    const digest = createHash("sha256").update(input.scope, "utf8").update("\0")
      .update(input.nonce, "ascii").digest("base64url");
    const reply = await this.request("/claim", { digest });
    if (Object.keys(reply).length !== 1 || (reply.outcome !== "claimed" && reply.outcome !== "replayed")) {
      this.connected = false;
      throw new Error("Billing nonce dependency unavailable");
    }
    this.connected = true;
    return reply.outcome;
  }
}
