import {
  prepareModerationOperatorWebAuthnAssertion,
  type PrepareModerationOperatorWebAuthnAssertionOptions,
  type PreparedModerationOperatorWebAuthnAssertion,
} from "./moderation-operator-webauthn";

export const MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES = 16_384;
export const MODERATION_OPERATOR_ASSERTION_BODY_DEADLINE_MS = 5_000;
export const MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_READS =
  MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES + 1;
export const MODERATION_OPERATOR_ASSERTION_REQUEST_FAILURE_CODE =
  "operator_assertion_request_invalid" as const;

export class ModerationOperatorAssertionRequestError extends Error {
  readonly code = MODERATION_OPERATOR_ASSERTION_REQUEST_FAILURE_CODE;

  constructor() {
    super(MODERATION_OPERATOR_ASSERTION_REQUEST_FAILURE_CODE);
    this.name = "ModerationOperatorAssertionRequestError";
  }
}

function fail(): never {
  throw new ModerationOperatorAssertionRequestError();
}

/** Inspect decoded keys before JSON.parse can discard duplicate members. */
function inspectJsonMembers(text: string): void {
  type Container = { type: "array" } | {
    type: "object";
    expectKey: boolean;
    keys: Set<string>;
  };
  const stack: Container[] = [];
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (character === '"') {
      const start = index;
      let escaped = false;
      for (index += 1; index < text.length; index += 1) {
        const next = text[index];
        if (escaped) {
          escaped = false;
        } else if (next === "\\") {
          escaped = true;
        } else if (next === '"') {
          break;
        }
      }
      if (index >= text.length) fail();
      const container = stack.at(-1);
      if (container?.type === "object" && container.expectKey) {
        const key: unknown = JSON.parse(text.slice(start, index + 1));
        if (typeof key !== "string" || container.keys.has(key)) fail();
        container.keys.add(key);
        container.expectKey = false;
      }
    } else if (character === "{" || character === "[") {
      // A WebAuthn assertion needs only two object levels. Bound inspection
      // even for a malformed body which the strict assertion schema rejects.
      if (stack.length >= 4) fail();
      stack.push(character === "{"
        ? { type: "object", expectKey: true, keys: new Set() }
        : { type: "array" });
    } else if (character === "}" || character === "]") {
      const container = stack.pop();
      if (container === undefined
          || (character === "}" && container.type !== "object")
          || (character === "]" && container.type !== "array")) fail();
    } else if (character === ",") {
      const container = stack.at(-1);
      if (container?.type === "object") container.expectKey = true;
    }
  }
  if (stack.length !== 0) fail();
}

async function readAssertionBody(request: Request): Promise<Uint8Array> {
  const contentType = request.headers.get("content-type");
  if (contentType === null
      || !/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(contentType.trim())
      || request.headers.has("content-encoding")) fail();
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^(?:0|[1-9][0-9]{0,5})$/u.test(declared)
      || Number(declared) > MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES)) fail();
  if (request.body === null) fail();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let completed = false;
  let stopped = false;
  const deadlineAt = Date.now() + MODERATION_OPERATOR_ASSERTION_BODY_DEADLINE_MS;
  const collect = async (): Promise<Uint8Array> => {
    let reads = 0;
    while (true) {
      // A deadline alone cannot stop immediately-resolving empty chunks from
      // monopolizing the microtask queue before the timer can run.
      reads += 1;
      if (stopped || Date.now() >= deadlineAt
          || reads > MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_READS) fail();
      const { value, done } = await reader.read();
      if (stopped || Date.now() >= deadlineAt) fail();
      if (done) break;
      if (!(value instanceof Uint8Array)) fail();
      total += value.byteLength;
      if (total > MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES
          || (declared !== null && total > Number(declared))) fail();
      if (value.byteLength > 0) chunks.push(value.slice());
    }
    if (declared !== null && total !== Number(declared)) fail();
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    completed = true;
    return bytes;
  };
  let deadlineTimer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    deadlineTimer = setTimeout(
      () => reject(new ModerationOperatorAssertionRequestError()),
      MODERATION_OPERATOR_ASSERTION_BODY_DEADLINE_MS,
    );
  });
  try {
    return await Promise.race([collect(), deadline]);
  } finally {
    stopped = true;
    clearTimeout(deadlineTimer);
    // Do not await an underlying stream's cancel hook: it may never settle.
    // Releasing the reader also rejects an outstanding read after a deadline.
    if (!completed) {
      try { void reader.cancel().catch(() => {}); } catch { /* fixed outer failure */ }
    }
    reader.releaseLock();
  }
}

/**
 * Body boundary for a future authenticated operator route. The HTTP body is
 * the assertion itself; challenge, credential and expected scope come only
 * from the caller's trusted server state. This does not authorize a request,
 * verify a signature, consume a challenge or access D1/R2. The route must first
 * apply its runtime/Access/quota gates, then durably commit the one-shot
 * assertion attempt before calling verifyPreparedModerationOperatorWebAuthnAssertion.
 */
export async function prepareModerationOperatorWebAuthnRequest(
  request: Request,
  options: Omit<PrepareModerationOperatorWebAuthnAssertionOptions, "response">,
): Promise<PreparedModerationOperatorWebAuthnAssertion> {
  try {
    const bytes = await readAssertionBody(request);
    // Reject a BOM instead of silently stripping bytes from the HTTP body.
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
    inspectJsonMembers(text);
    const response: unknown = JSON.parse(text);
    return await prepareModerationOperatorWebAuthnAssertion({ ...options, response });
  } catch {
    fail();
  }
}
