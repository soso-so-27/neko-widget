import {
  prepareModerationAdvisory, completeModerationAdvisory,
  type ModerationAdvisoryCase, type ModerationAdvisoryInput,
  type ModerationAdvisoryDelivery, type ModerationAdvisoryResult,
} from "./moderation-ai-advisory";

export const MODERATION_ADVISORY_TRANSPORT_DEADLINE_MS = 10_000;
const maxResponseBytes = 16_384;
const maxResponseChunks = 1_024;
const caseKeys = ["caseReferenceHmacKeyVersion", "caseReferenceHmac", "evidenceVersion", "evidenceSHA256"] as const;

export interface ModerationAdvisoryTransport {
  // Server configuration only. Never obtain this from a report or an AI reply.
  apiKey: string;
  // Trusted repository read; null includes a closed/deleted/ineligible case.
  readCurrentCase: (binding: Readonly<ModerationAdvisoryCase>) => Promise<ModerationAdvisoryCase | null>;
  signal?: AbortSignal;
}

/** Not connected to any Worker route. A future caller must authorize/minimize
 * disclosure and screen evidence before calling this function. This sender
 * owns the request/response pair: it never accepts a caller-supplied response.
 * Persistence must still atomically compare the returned evidence with the DB.
 * This is neither a durable queue nor an authority to hide, delete or reply.
 */
export async function requestModerationAdvisory(
  input: ModerationAdvisoryInput, transport: ModerationAdvisoryTransport,
): Promise<ModerationAdvisoryResult> {
  const binding = Object.freeze({...input.case});
  const {apiKey, readCurrentCase, signal} = transport;
  const prepared = await prepareModerationAdvisory(input, Date.now());
  if (prepared.status !== "prepared") return prepared; // No network for holds.

  const finish = (current: ModerationAdvisoryCase | null, delivery: ModerationAdvisoryDelivery) =>
    // The boundary deliberately rejects null as stale/missing evidence.
    completeModerationAdvisory(prepared.ticket, current as ModerationAdvisoryCase, delivery, Date.now());
  if (typeof apiKey !== "string" || !/^[\x21-\x7e]{1,512}$/u.test(apiKey)) {
    return finish(binding, {kind: "unavailable"});
  }
  const controller = new AbortController();
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let stopReason: "timeout" | "unavailable" | null = null;
  let rejectStop!: (reason: Error) => void;
  const stopped = new Promise<never>((_, reject) => { rejectStop = reject; });
  // Observe rejection even if an already-aborted caller prevents the first race.
  void stopped.catch(() => {});
  const stop = (reason: "timeout" | "unavailable") => {
    if (stopReason !== null) return;
    stopReason = reason;
    controller.abort();
    void reader?.cancel().catch(() => {});
    rejectStop(new Error("moderation_advisory_transport_stopped"));
  };
  const timer = setTimeout(() => stop("timeout"), MODERATION_ADVISORY_TRANSPORT_DEADLINE_MS);
  const onAbort = () => stop("unavailable");
  signal?.addEventListener("abort", onAbort, {once: true});
  if (signal?.aborted) onAbort();
  const bounded = <T>(operation: Promise<T>): Promise<T> => Promise.race([operation, stopped]);
  const readCurrent = async () => {
    try { return await bounded(Promise.resolve().then(() => readCurrentCase(binding))); }
    catch {
      if (stopReason !== null) throw new Error("moderation_advisory_transport_stopped");
      return null; // Never substitute an old case when a fresh read fails.
    }
  };
  const matches = (current: ModerationAdvisoryCase | null) => current !== null
    && typeof current === "object" && Object.keys(current).length === caseKeys.length
    && caseKeys.every(key => Object.hasOwn(current, key) && current[key] === binding[key]);

  try {
    if (stopReason !== null) return finish(binding, {kind: stopReason});
    const before = await readCurrent();
    if (!matches(before)) return finish(before, {kind: "unavailable"});
    if (stopReason !== null) return finish(binding, {kind: stopReason});

    // No configurable URL, redirects, cookies, retries, or provider error logs.
    const pendingResponse = fetch(prepared.endpoint, {
      method: "POST", redirect: "manual", credentials: "omit",
      headers: {"Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json", "Accept": "application/json"},
      body: prepared.body, signal: controller.signal,
    });
    // Also clean up a late response from a transport that ignored cancellation.
    void pendingResponse.then(response => {
      if (stopReason !== null) void response.body?.cancel().catch(() => {});
    }, () => {});
    const response = await bounded(pendingResponse);
    reader = response.body?.getReader();
    if (response.status !== 200) return finish(binding, {kind: "unavailable"});
    const contentType = response.headers.get("content-type") ?? "";
    const declaredLength = response.headers.get("content-length");
    let invalid = !/^application\/json(?:\s*;|$)/iu.test(contentType) || !reader;
    if (declaredLength !== null && (!/^(0|[1-9][0-9]*)$/u.test(declaredLength)
      || !Number.isSafeInteger(Number(declaredLength)) || Number(declaredLength) > maxResponseBytes)) invalid = true;
    const bytes = new Uint8Array(maxResponseBytes);
    let length = 0;
    let body = "";
    if (!invalid && reader) {
      for (let chunks = 0; ; chunks++) {
        const part = await bounded(reader.read());
        if (part.done) break;
        if (chunks >= maxResponseChunks || !(part.value instanceof Uint8Array)
          || part.value.byteLength > maxResponseBytes - length) { invalid = true; break; }
        bytes.set(part.value, length);
        length += part.value.byteLength;
      }
      if (declaredLength !== null && length !== Number(declaredLength)) invalid = true;
      if (!invalid) {
        try { body = new TextDecoder("utf-8", {fatal: true}).decode(bytes.subarray(0, length)); }
        catch { invalid = true; }
      }
    }
    if (invalid) {
      // Stop receiving immediately; a slow current-case read must not keep an
      // already rejected provider stream alive. Preserve the invalid reason.
      controller.abort();
      void reader?.cancel().catch(() => {});
    }
    const current = await readCurrent();
    if (stopReason !== null) return finish(binding, {kind: stopReason});
    return finish(current, {kind: "response", body: invalid ? "" : body});
  } catch {
    // No report text, secret, provider body, or internal exception in the result.
    return finish(binding, {kind: stopReason ?? "unavailable"});
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
    controller.abort();
    // Do not await an uncooperative remote source's cancellation promise.
    void reader?.cancel().catch(() => {});
  }
}
