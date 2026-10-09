import { afterEach, describe, expect, it, vi } from "vitest";
import { requestModerationAdvisory, MODERATION_ADVISORY_TRANSPORT_DEADLINE_MS } from "../src/moderation-ai-transport";
import { MODERATION_ADVISORY_ENDPOINT, MODERATION_ADVISORY_MODEL, moderationAdvisoryCategories,
  type ModerationAdvisoryCase, type ModerationAdvisoryInput } from "../src/moderation-ai-advisory";

const binding = (): ModerationAdvisoryCase => ({caseReferenceHmacKeyVersion: 7, caseReferenceHmac: "a".repeat(64), evidenceVersion: 3, evidenceSHA256: "b".repeat(64)});
const input = (): ModerationAdvisoryInput => ({case: binding(), safetyRoute: "general_review", text: "猫の通報を確認してください"});
function provider(flag?: string) {
  return JSON.stringify({id: "modr-fixture", model: MODERATION_ADVISORY_MODEL, results: [{
    flagged: !!flag,
    categories: Object.fromEntries(moderationAdvisoryCategories.map(key => [key, key === flag])),
    category_scores: Object.fromEntries(moderationAdvisoryCategories.map(key => [key, key === flag ? 0.9 : 0])),
    category_applied_input_types: Object.fromEntries(moderationAdvisoryCategories.map(key => [key, ["text"]])),
  }]});
}
const response = (body = provider(), headers: Record<string, string> = {}) => new Response(body, {headers: {"content-type": "application/json", ...headers}});
const options = () => ({apiKey: "fixture-secret", readCurrentCase: async (key: ModerationAdvisoryCase) => ({...key})});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(r => { resolve = r; });
  return {promise, resolve};
}
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe("moderation transport workerd assumptions", () => {
  it("cancels a pending streamed body read without waiting for the source", async () => {
    let cancelled = false;
    const response = new Response(new ReadableStream<Uint8Array>({
      cancel() { cancelled = true; },
    }));
    const reader = response.body!.getReader();
    const pending = reader.read();
    await reader.cancel();
    expect(await pending).toEqual({done: true, value: undefined});
    expect(cancelled).toBe(true);
  });

  it("keeps each concurrent streamed response bound to its originating promise", async () => {
    const controllers: ReadableStreamDefaultController<Uint8Array>[] = [];
    const requests = ["a", "b"].map(async caseID => {
      const response = new Response(new ReadableStream<Uint8Array>({start(c) { controllers.push(c); }}));
      return {caseID, body: await response.text()};
    });
    controllers[1]!.enqueue(new TextEncoder().encode("second"));
    controllers[1]!.close();
    expect(await requests[1]).toEqual({caseID: "b", body: "second"});
    controllers[0]!.enqueue(new TextEncoder().encode("first"));
    controllers[0]!.close();
    expect(await requests[0]).toEqual({caseID: "a", body: "first"});
  });
});

describe("case-owned bounded advisory transport", () => {
  it("sends once to the fixed endpoint with no redirect/cookies and never grants authority", async () => {
    const network = vi.spyOn(globalThis, "fetch").mockResolvedValue(response());
    const read = vi.fn(options().readCurrentCase);
    const result = await requestModerationAdvisory(input(), {...options(), readCurrentCase: read});
    expect(network).toHaveBeenCalledTimes(1);
    expect(read).toHaveBeenCalledTimes(2);
    const [url, init] = network.mock.calls[0]!;
    expect(url).toBe(MODERATION_ADVISORY_ENDPOINT);
    expect(init).toMatchObject({method: "POST", redirect: "manual", credentials: "omit", headers: {Authorization: "Bearer fixture-secret"}});
    expect(JSON.parse(init!.body as string)).toEqual({model: MODERATION_ADVISORY_MODEL, input: [{type: "text", text: input().text}]});
    expect(init!.body).not.toContain(binding().caseReferenceHmac);
    expect(result).toMatchObject({case: binding(), reason: "advisory_ready", status: "owner_review_required", canCloseCase: false, canDeleteContent: false, canApproveAction: false});
    expect(JSON.stringify(result)).not.toContain("fixture-secret");
  });

  it.each(["child_safety_hold", "unreviewed"] as const)("makes zero requests/DB reads for %s", async safetyRoute => {
    const network = vi.spyOn(globalThis, "fetch");
    const read = vi.fn(options().readCurrentCase);
    const result = await requestModerationAdvisory({...input(), safetyRoute}, {...options(), readCurrentCase: read});
    expect(network).not.toHaveBeenCalled();
    expect(read).not.toHaveBeenCalled();
    expect(result.reason).toBe(safetyRoute === "unreviewed" ? "safety_route_unreviewed" : "child_safety_hold");
  });

  it("binds reversed A/B completion to the corresponding request and evidence", async () => {
    const a = deferred<Response>(); const b = deferred<Response>(); const started = deferred<void>();
    const network = vi.spyOn(globalThis, "fetch").mockReturnValueOnce(a.promise).mockImplementationOnce(() => { started.resolve(); return b.promise; });
    const first = requestModerationAdvisory(input(), options());
    await vi.waitFor(() => expect(network).toHaveBeenCalledTimes(1));
    const secondInput = {...input(), case: {...binding(), caseReferenceHmac: "c".repeat(64)}, text: "別件"};
    const second = requestModerationAdvisory(secondInput, options());
    await started.promise;
    b.resolve(response(provider("violence")));
    const secondResult = await second;
    a.resolve(response());
    const firstResult = await first;
    expect(secondResult).toMatchObject({case: secondInput.case, priorityHint: "raise", reason: "advisory_ready"});
    expect(firstResult).toMatchObject({case: binding(), priorityHint: "preserve", reason: "advisory_ready"});
    expect(firstResult.requestSHA256).not.toBe(secondResult.requestSHA256);
    expect(network).toHaveBeenCalledTimes(2);
  });

  it.each([null, {...binding(), evidenceVersion: 4}, {...binding(), caseReferenceHmac: "d".repeat(64)}])("does not disclose evidence when the initial case changed: %j", async current => {
    const network = vi.spyOn(globalThis, "fetch");
    const result = await requestModerationAdvisory(input(), {...options(), readCurrentCase: async () => current});
    expect(network).not.toHaveBeenCalled();
    expect(result.reason).toBe("stale_evidence");
  });

  it.each(["updated", "closed", "read-failed"])("discards a successful reply when the case is %s before completion", async change => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(response(provider("violence")));
    let reads = 0;
    const result = await requestModerationAdvisory(input(), {...options(), readCurrentCase: async () => {
      if (++reads === 1) return binding();
      if (change === "read-failed") throw new Error("private DB details");
      return change === "closed" ? null : {...binding(), evidenceVersion: 4};
    }});
    expect(result).toMatchObject({reason: "stale_evidence", signals: [], priorityHint: "preserve"});
    expect(JSON.stringify(result)).not.toContain("private DB details");
  });

  it.each([301, 307, 401, 429, 500])("never follows or retries status %i and discards its error body", async status => {
    let cancelled = false;
    const network = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(new ReadableStream({cancel() { cancelled = true; }}),
      {status, headers: {location: "https://untrusted.invalid/", "content-type": "text/plain"}}));
    const result = await requestModerationAdvisory(input(), options());
    expect(result.reason).toBe("provider_unavailable");
    expect(network).toHaveBeenCalledTimes(1);
    expect(cancelled).toBe(true);
  });

  it("bounds a stalled fetch even when the transport ignores AbortSignal; cancels the late body", async () => {
    vi.useFakeTimers();
    const pending = deferred<Response>(); const started = deferred<void>();
    let sentSignal: AbortSignal | null | undefined;
    const network = vi.spyOn(globalThis, "fetch").mockImplementation((_url, init) => {
      sentSignal = init?.signal; started.resolve(); return pending.promise;
    });
    const resultPromise = requestModerationAdvisory(input(), options());
    await started.promise;
    await vi.advanceTimersByTimeAsync(MODERATION_ADVISORY_TRANSPORT_DEADLINE_MS);
    expect((await resultPromise).reason).toBe("provider_timeout");
    expect(sentSignal?.aborted).toBe(true);
    let cancelled = false;
    pending.resolve(new Response(new ReadableStream({cancel() { cancelled = true; }})));
    await pending.promise;
    expect(cancelled).toBe(true);
    expect(network).toHaveBeenCalledTimes(1);
  });

  it("includes a stalled response body in the same deadline and cancels it", async () => {
    vi.useFakeTimers();
    const reading = deferred<void>(); let cancelled = false;
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(new ReadableStream({
      pull() { reading.resolve(); }, cancel() { cancelled = true; },
    }, {highWaterMark: 0}), {headers: {"content-type": "application/json"}}));
    const pending = requestModerationAdvisory(input(), options());
    await reading.promise;
    await vi.advanceTimersByTimeAsync(MODERATION_ADVISORY_TRANSPORT_DEADLINE_MS);
    expect((await pending).reason).toBe("provider_timeout");
    expect(cancelled).toBe(true);
  });

  it("bounds a stalled post-response DB read without accepting stale advice", async () => {
    vi.useFakeTimers();
    const reading = deferred<void>(); let reads = 0;
    vi.spyOn(globalThis, "fetch").mockResolvedValue(response());
    const pending = requestModerationAdvisory(input(), {...options(), readCurrentCase: async () => {
      if (++reads === 1) return binding();
      reading.resolve(); return new Promise(() => {});
    }});
    await reading.promise;
    await vi.advanceTimersByTimeAsync(MODERATION_ADVISORY_TRANSPORT_DEADLINE_MS);
    expect(await pending).toMatchObject({reason: "provider_timeout", signals: []});
  });

  it("does not send after an already-aborted caller", async () => {
    const network = vi.spyOn(globalThis, "fetch"); const abort = new AbortController(); abort.abort();
    expect((await requestModerationAdvisory(input(), {...options(), signal: abort.signal})).reason).toBe("provider_unavailable");
    expect(network).not.toHaveBeenCalled();
  });

  it("cancels a pending body when the caller aborts, without waiting for its deadline", async () => {
    const reading = deferred<void>(); let cancelled = false;
    const abort = new AbortController();
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(new ReadableStream({
      pull() { reading.resolve(); }, cancel() { cancelled = true; },
    }, {highWaterMark: 0}), {headers: {"content-type": "application/json"}}));
    const pending = requestModerationAdvisory(input(), {...options(), signal: abort.signal});
    await reading.promise; abort.abort();
    expect((await pending).reason).toBe("provider_unavailable");
    expect(cancelled).toBe(true);
  });

  it.each(["oversize", "empty-chunks", "bad-utf8", "declared-large", "wrong-type", "length-mismatch"])("rejects %s response within fixed read limits", async mode => {
    let chunks = 0; let cancelled = false;
    const raw = new TextEncoder().encode(provider());
    const headers: Record<string, string> = {"content-type": mode === "wrong-type" ? "text/html" : "application/json"};
    if (mode === "declared-large") headers["content-length"] = "16385";
    if (mode === "length-mismatch") headers["content-length"] = String(raw.length + 1);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(new ReadableStream<Uint8Array>({
      pull(controller) {
        chunks++;
        if (mode === "oversize") controller.enqueue(new Uint8Array(4_096));
        else if (mode === "empty-chunks") controller.enqueue(new Uint8Array());
        else { controller.enqueue(mode === "bad-utf8" ? new Uint8Array([0xff]) : raw); controller.close(); }
      }, cancel() { cancelled = true; },
    }), {headers}));
    expect((await requestModerationAdvisory(input(), options())).reason).toBe("provider_invalid");
    if (mode === "oversize") { expect(chunks).toBeLessThanOrEqual(7); expect(cancelled).toBe(true); }
    if (mode === "empty-chunks") { expect(chunks).toBeLessThanOrEqual(1_027); expect(cancelled).toBe(true); }
  });

  it("accepts exactly 16KiB streamed JSON and does not echo network exceptions", async () => {
    const body = provider().padEnd(16_384, " ");
    const network = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(response(body, {"content-length": "16384"}))
      .mockRejectedValueOnce(new Error("fixture-secret private-report"));
    expect((await requestModerationAdvisory(input(), options())).reason).toBe("advisory_ready");
    const result = await requestModerationAdvisory(input(), options());
    expect(result.reason).toBe("provider_unavailable");
    expect(JSON.stringify(result)).not.toMatch(/fixture-secret|private-report/u);
    expect(network).toHaveBeenCalledTimes(2);
  });

  it("cancels a rejected stream before waiting for the DB even when cancellation never settles", async () => {
    const readingDB = deferred<void>(); const current = deferred<ModerationAdvisoryCase>();
    let cancelled = false; let sentSignal: AbortSignal | null | undefined; let reads = 0;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      sentSignal = init?.signal;
      return new Response(new ReadableStream<Uint8Array>({
        pull(controller) { controller.enqueue(new Uint8Array(16_385)); },
        cancel() { cancelled = true; return new Promise(() => {}); },
      }, {highWaterMark: 0}), {headers: {"content-type": "application/json"}});
    });
    const pending = requestModerationAdvisory(input(), {...options(), readCurrentCase: async () => {
      if (++reads === 1) return binding();
      readingDB.resolve(); return current.promise;
    }});
    await readingDB.promise;
    expect(cancelled).toBe(true);
    expect(sentSignal?.aborted).toBe(true);
    current.resolve(binding());
    expect((await pending).reason).toBe("provider_invalid");
  });

  it.each(["", "bad\r\nheader", "x".repeat(513)])("does not send invalid server credentials", async apiKey => {
    const network = vi.spyOn(globalThis, "fetch");
    expect((await requestModerationAdvisory(input(), {...options(), apiKey})).reason).toBe("provider_unavailable");
    expect(network).not.toHaveBeenCalled();
  });
});
