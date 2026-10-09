/**
 * Disconnected advisory boundary. No Worker imports this module; it cannot send,
 * authorize, persist, delete, hide, or close anything. A future trusted caller
 * must minimize evidence, obtain data-use authorization, route child-safety
 * cases BEFORE preparing input, and atomically bind the result to a live case.
 * Opaque tickets bind case/evidence and prevent ticket reuse within one isolate.
 * They do NOT authenticate a provider response or its originating request.
 */
export const MODERATION_ADVISORY_POLICY = "neko-owner-advisory-v1" as const;
export const MODERATION_ADVISORY_MODEL = "omni-moderation-2024-09-26" as const;
export const MODERATION_ADVISORY_ENDPOINT = "https://api.openai.com/v1/moderations" as const;
export const moderationAdvisoryCategories = Object.freeze([
  "harassment", "harassment/threatening", "hate", "hate/threatening", "illicit",
  "illicit/violent", "self-harm", "self-harm/intent", "self-harm/instructions",
  "sexual", "sexual/minors", "violence", "violence/graphic",
] as const);
type Category = typeof moderationAdvisoryCategories[number];
type Modality = "text" | "image";
const textOnly = new Set<Category>([
  "harassment", "harassment/threatening", "hate", "hate/threatening",
  "illicit", "illicit/violent", "sexual/minors",
]);
const maxTextBytes = 8_192;
const maxImageBytes = 1_048_576;
const maxResponseBytes = 16_384;
const lifetimeMs = 30_000;
const encoder = new TextEncoder();

export interface ModerationAdvisoryCase {
  caseReferenceHmacKeyVersion: number;
  caseReferenceHmac: string;
  evidenceVersion: number;
  evidenceSHA256: string;
}
export interface ModerationAdvisoryInput {
  case: ModerationAdvisoryCase;
  // Trusted upstream classification, NOT an AI conclusion or authorization.
  safetyRoute: "general_review" | "child_safety_hold" | "unreviewed";
  text?: string;
  // Already minimized/re-encoded shared evidence; no URL, private album or key.
  // This module bounds/snapshots bytes; it does not decode or strip metadata.
  jpeg?: Uint8Array;
}
export interface ModerationAdvisoryTicket { readonly purpose: "moderation_advisory_only" }
interface Pending {
  case: Readonly<ModerationAdvisoryCase>;
  requestSHA256: string;
  createdAtMs: number;
  expiresAtMs: number;
  modalities: readonly Modality[];
}
const pending = new WeakMap<ModerationAdvisoryTicket, Pending>();
type Reason = "child_safety_hold" | "safety_route_unreviewed" | "provider_unavailable"
  | "provider_timeout" | "provider_invalid" | "stale_evidence" | "advisory_ready";
export interface ModerationAdvisoryResult {
  policy: typeof MODERATION_ADVISORY_POLICY;
  case: Readonly<ModerationAdvisoryCase>;
  status: "owner_review_required";
  reason: Reason;
  // Never lower the existing queue priority or deadline based on this hint.
  priorityHint: "preserve" | "raise";
  requestSHA256: string | null;
  model: typeof MODERATION_ADVISORY_MODEL | null;
  signals: readonly Readonly<{category: Category; flagged: boolean | null; score: number; appliedTo: readonly Modality[]}>[];
  unassessed: readonly string[];
  suggestedReply: string;
  replyKind: "fixed_acknowledgement_draft";
  canCloseCase: false;
  canDeleteContent: false;
  canApproveAction: false;
}
export type PreparedModerationAdvisory = ModerationAdvisoryResult | Readonly<{
  status: "prepared";
  ticket: ModerationAdvisoryTicket;
  endpoint: typeof MODERATION_ADVISORY_ENDPOINT;
  body: string;
  requestSHA256: string;
  expiresAtMs: number;
}>;

function invalid(): never { throw new Error("moderation_advisory_input_invalid"); }
function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function exact(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return record(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function caseSnapshot(value: unknown): Readonly<ModerationAdvisoryCase> {
  if (!exact(value, ["caseReferenceHmacKeyVersion", "caseReferenceHmac", "evidenceVersion", "evidenceSHA256"])) invalid();
  const { caseReferenceHmacKeyVersion, caseReferenceHmac, evidenceVersion, evidenceSHA256 } = value;
  for (const number of [caseReferenceHmacKeyVersion, evidenceVersion]) {
    if (!Number.isSafeInteger(number) || (number as number) < 1 || (number as number) > 2_147_483_647) invalid();
  }
  for (const digest of [caseReferenceHmac, evidenceSHA256]) {
    if (typeof digest !== "string" || !/^[0-9a-f]{64}$/u.test(digest)) invalid();
  }
  return Object.freeze({ caseReferenceHmacKeyVersion, caseReferenceHmac, evidenceVersion, evidenceSHA256 }) as Readonly<ModerationAdvisoryCase>;
}
function validTime(value: number): boolean { return Number.isSafeInteger(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER - lifetimeMs; }
function fallback(binding: Readonly<ModerationAdvisoryCase>, reason: Reason, requestSHA256: string | null = null): ModerationAdvisoryResult {
  return Object.freeze({
    policy: MODERATION_ADVISORY_POLICY, case: binding, status: "owner_review_required", reason,
    priorityHint: reason === "child_safety_hold" ? "raise" : "preserve", requestSHA256,
    model: null, signals: Object.freeze([]),
    unassessed: Object.freeze(["context", "privacy", "rights", "animal_welfare", "medical_context", "child_safety"]),
    suggestedReply: "通報を受け付けました。内容を確認します。", replyKind: "fixed_acknowledgement_draft",
    canCloseCase: false, canDeleteContent: false, canApproveAction: false,
  });
}
function base64(bytes: Uint8Array): string {
  let encoded = "";
  for (let i = 0; i < bytes.length; i += 12_288) {
    encoded += btoa(String.fromCharCode(...bytes.subarray(i, i + 12_288)));
  }
  return encoded;
}

/** Produces inert request data only. It is not permission to disclose evidence. */
export async function prepareModerationAdvisory(input: ModerationAdvisoryInput, nowMs: number): Promise<PreparedModerationAdvisory> {
  if (!record(input) || Object.keys(input).some(key => !["case", "safetyRoute", "text", "jpeg"].includes(key)) || !validTime(nowMs)) invalid();
  const binding = caseSnapshot(input.case);
  if (input.safetyRoute === "child_safety_hold") return fallback(binding, "child_safety_hold");
  if (input.safetyRoute === "unreviewed") return fallback(binding, "safety_route_unreviewed");
  if (input.safetyRoute !== "general_review") invalid();
  const text = input.text;
  const jpeg = input.jpeg;
  const parts: ({type: "text"; text: string} | {type: "image_url"; image_url: {url: string}})[] = [];
  const modalities: Modality[] = [];
  if (text !== undefined) {
    if (typeof text !== "string" || !text.trim() || text.length > maxTextBytes || encoder.encode(text).length > maxTextBytes || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(text)) invalid();
    parts.push({ type: "text", text });
    modalities.push("text");
  }
  if (jpeg !== undefined) {
    if (!(jpeg instanceof Uint8Array) || jpeg.length < 4 || jpeg.length > maxImageBytes) invalid();
    const snapshot = new Uint8Array(jpeg);
    // Format signature only, not a claim that decoding/metadata removal passed.
    if (snapshot[0] !== 0xff || snapshot[1] !== 0xd8 || snapshot.at(-2) !== 0xff || snapshot.at(-1) !== 0xd9) invalid();
    parts.push({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${base64(snapshot)}` } });
    modalities.push("image");
  }
  if (!parts.length) invalid();
  // Snapshot before the first await. Only selected evidence leaves this boundary;
  // case identifiers, hashes, other input properties and credentials never do.
  const body = JSON.stringify({ model: MODERATION_ADVISORY_MODEL, input: parts });
  const requestSHA256 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(body)))]
    .map(value => value.toString(16).padStart(2, "0")).join("");
  const ticket = Object.freeze({ purpose: "moderation_advisory_only" as const });
  const expiresAtMs = nowMs + lifetimeMs;
  pending.set(ticket, { case: binding, requestSHA256, createdAtMs: nowMs, expiresAtMs, modalities: Object.freeze(modalities) });
  return Object.freeze({ status: "prepared", ticket, endpoint: MODERATION_ADVISORY_ENDPOINT, body, requestSHA256, expiresAtMs });
}

export type ModerationAdvisoryDelivery = {kind: "response"; body: string}
  | {kind: "unavailable" | "timeout"};

/** Trusted caller supplies current DB evidence and the response to THIS request.
 * Does not verify network provenance or implement durable replay protection. */
export function completeModerationAdvisory(
  ticket: ModerationAdvisoryTicket, currentCase: ModerationAdvisoryCase,
  delivery: ModerationAdvisoryDelivery, nowMs: number,
): ModerationAdvisoryResult {
  const state = pending.get(ticket);
  if (!state) throw new Error("moderation_advisory_ticket_invalid");
  pending.delete(ticket); // Consume even rejected input; no same-ticket retries.
  let current: Readonly<ModerationAdvisoryCase>;
  try { current = caseSnapshot(currentCase); } catch { return fallback(state.case, "stale_evidence", state.requestSHA256); }
  if (JSON.stringify(current) !== JSON.stringify(state.case)) return fallback(state.case, "stale_evidence", state.requestSHA256);
  if (!validTime(nowMs) || nowMs < state.createdAtMs || nowMs >= state.expiresAtMs) return fallback(state.case, "provider_timeout", state.requestSHA256);
  if (!record(delivery)) return fallback(state.case, "provider_invalid", state.requestSHA256);
  if (exact(delivery, ["kind"]) && ["unavailable", "timeout"].includes(delivery.kind as string)) {
    return fallback(state.case, delivery.kind === "timeout" ? "provider_timeout" : "provider_unavailable", state.requestSHA256);
  }
  try {
    if (!exact(delivery, ["kind", "body"]) || delivery.kind !== "response" || typeof delivery.body !== "string"
      || delivery.body.length > maxResponseBytes || encoder.encode(delivery.body).length > maxResponseBytes) invalid();
    const raw: unknown = JSON.parse(delivery.body);
    if (!exact(raw, ["id", "model", "results"]) || typeof raw.id !== "string" || !/^modr-[A-Za-z0-9_-]{1,128}$/u.test(raw.id)
      || raw.model !== MODERATION_ADVISORY_MODEL || !Array.isArray(raw.results) || raw.results.length !== 1) invalid();
    const result: unknown = raw.results[0];
    if (!exact(result, ["flagged", "categories", "category_scores", "category_applied_input_types"])
      || typeof result.flagged !== "boolean" || !exact(result.categories, moderationAdvisoryCategories)
      || !exact(result.category_scores, moderationAdvisoryCategories) || !exact(result.category_applied_input_types, moderationAdvisoryCategories)) invalid();
    const { categories, category_scores: scores, category_applied_input_types: appliedTypes } = result;
    const unassessed = [...fallback(state.case, "advisory_ready").unassessed];
    const signals = moderationAdvisoryCategories.map(category => {
      const flagged = categories[category];
      const score = scores[category];
      const types = appliedTypes[category];
      if (typeof flagged !== "boolean" && !(flagged === null && (category === "illicit" || category === "illicit/violent"))) invalid();
      if (typeof score !== "number" || !Number.isFinite(score) || score < 0 || score > 1 || !Array.isArray(types)
        || types.length > 2 || new Set(types).size !== types.length
        || types.some(type => !state.modalities.includes(type) || (type === "image" && textOnly.has(category)))) invalid();
      if (types.length === 0 && (flagged === true || score !== 0)) invalid();
      for (const modality of state.modalities) {
        if (!types.includes(modality) || flagged === null) unassessed.push(`${category}:${modality}`);
      }
      return Object.freeze({ category, flagged, score, appliedTo: Object.freeze([...types]) as readonly Modality[] });
    });
    if (result.flagged !== signals.some(signal => signal.flagged === true)) invalid();
    return Object.freeze({ ...fallback(state.case, "advisory_ready", state.requestSHA256),
      priorityHint: result.flagged ? "raise" : "preserve", model: MODERATION_ADVISORY_MODEL,
      signals: Object.freeze(signals), unassessed: Object.freeze(unassessed),
    });
  } catch {
    // Do not echo provider errors, response text, credentials or report content.
    return fallback(state.case, "provider_invalid", state.requestSHA256);
  }
}
