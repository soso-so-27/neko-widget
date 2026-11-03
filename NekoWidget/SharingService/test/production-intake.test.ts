import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { base64urlEncode } from "../src/encoding";
import type { Env } from "../src/env";
import worker from "../src/index";
import { creationTranscript } from "../src/protocol";
import { APNS_DRAIN_CRON } from "../src/push";
import { LEGACY_CLEANUP_CRON, MOMENT_CLEANUP_CRON } from "../src/scheduled";

const origin = "https://sharing.invalid";
const routes = [
  ["GET", "/health"], ["POST", "/v3/group-windows"],
  ["POST", "/v3/family-notebooks"], ["POST", "/v1/billing/transactions"],
  ["POST", "/v1/billing/apple-notifications"], ["POST", "/v3/group-identities/deletion-requests"],
  ["GET", "/operator/v1/reports"], ["GET", "/unknown"],
] as const;

// Local Requests have no edge-added cf metadata; the production entry accepts incoming Requests.
function incoming(path: string, init: RequestInit) {
  return new Request(origin + path, init) as Parameters<typeof worker.fetch>[0];
}

async function signedSpaceRequest() {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const publicKey = base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
  const fields = {
    clientRequestId: crypto.randomUUID(),
    participantId: base64urlEncode(crypto.getRandomValues(new Uint8Array(16))),
    agreementPublicKey: base64urlEncode(crypto.getRandomValues(new Uint8Array(32))),
    signingPublicKey: publicKey,
    invitationProofPublicKey: publicKey,
    dailyBoundaryMinuteUTC: 540,
  };
  const signature = await crypto.subtle.sign("Ed25519", keys.privateKey, new Uint8Array(creationTranscript(fields)));
  return incoming("/v1/spaces", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ protocolVersion: 1, ...fields, creationSignature: base64urlEncode(new Uint8Array(signature)) }),
  });
}

describe("sharing Worker production intake", () => {
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it.each([undefined, "", "yes", "NO", "YES "])("closes fetch and scheduled before all business work for %s", async value => {
    const signed = await signedSpaceRequest();
    const settings = { ENVIRONMENT: "production", ...(value === undefined ? {} : { INTAKE_ENABLED: value }) };
    const unexpectedRead = vi.fn();
    const closed = new Proxy(settings, {
      get(target, key) {
        if (key !== "ENVIRONMENT" && key !== "INTAKE_ENABLED") {
          unexpectedRead(key);
          throw new Error("business setting or binding used");
        }
        return Reflect.get(target, key);
      },
    }) as Env;
    const waitUntil = vi.fn();
    const ctx = { waitUntil } as unknown as ExecutionContext;
    const network = vi.fn(() => { throw new Error("outbound request"); });
    vi.stubGlobal("fetch", network);
    const verify = vi.spyOn(crypto.subtle, "verify");
    const requests = routes.map(([method, path]) => incoming(path, { method }));
    for (const req of [signed, ...requests]) {
      const res = await worker.fetch(req, closed, ctx);
      expect(res.status).toBe(503);
      expect(res.headers.get("Cache-Control")).toBe("no-store");
      expect(await res.text()).toBe("");
      expect(req.bodyUsed).toBe(false);
    }
    for (const cron of [APNS_DRAIN_CRON, MOMENT_CLEANUP_CRON, LEGACY_CLEANUP_CRON]) {
      await worker.scheduled({ cron } as ScheduledController, closed, ctx);
    }
    expect(unexpectedRead).not.toHaveBeenCalled();
    expect(waitUntil).not.toHaveBeenCalled();
    expect(network).not.toHaveBeenCalled();
    expect(verify).not.toHaveBeenCalled();
  });

  it.each([
    { ENVIRONMENT: "production", INTAKE_ENABLED: "YES" },
    { ENVIRONMENT: "staging" },
    { ENVIRONMENT: "staging", INTAKE_ENABLED: "NO" },
  ])("allows normal signed space creation for %o", async settings => {
    const active = { ...env, ...settings, CREATE_RATE_LIMITER: { limit: async () => ({ success: true }) } } as unknown as Env;
    const res = await worker.fetch(await signedSpaceRequest(), active, {} as ExecutionContext);
    expect(res.status).toBe(201);
  });
});
