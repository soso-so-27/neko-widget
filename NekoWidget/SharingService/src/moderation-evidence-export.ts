import { base64urlDecode, base64urlEncode } from "./encoding";

export const MODERATION_EVIDENCE_EVENT_SCHEMA =
  "jp.nekowidget.moderation-evidence-event.v2" as const;
export const MODERATION_EVIDENCE_EXPORT_SCHEMA =
  "jp.nekowidget.moderation-evidence-export.v2" as const;
export const MODERATION_EVIDENCE_SIGNATURE_SCHEMA =
  "jp.nekowidget.moderation-evidence-signature.v2" as const;
export const MODERATION_EVIDENCE_SIGNATURE_ALGORITHM = "Ed25519" as const;
export const MODERATION_EVIDENCE_GENESIS_SHA256 = "0".repeat(64);

const maximumExportBytes = 4 * 1024 * 1024;
const maximumExportEvents = 2_048;
const sha256Pattern = /^[0-9a-f]{64}$/u;
const uuidV4Pattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const keyIDPattern = /^[a-z][a-z0-9-]{2,63}$/u;

export const moderationEvidenceActionTypes = [
  "review_start",
  "evidence_export",
  "review_decision",
  "content_delete",
] as const;

export type ModerationEvidenceActionType =
  (typeof moderationEvidenceActionTypes)[number];

const actionTypes = new Set<string>(moderationEvidenceActionTypes);
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export class ModerationEvidenceExportError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = "ModerationEvidenceExportError";
  }
}

export interface ModerationEvidenceEventInput {
  eventID: string;
  actionID: string;
  actionType: ModerationEvidenceActionType;
  caseReferenceHmac: string;
  actorSubjectHmacKeyVersion: number;
  actorSubjectHmac: string;
  occurredAt: number;
  artifactSHA256: string;
}

export interface ModerationEvidenceEvent {
  schema: typeof MODERATION_EVIDENCE_EVENT_SCHEMA;
  sequence: number;
  eventID: string;
  actionID: string;
  actionType: ModerationEvidenceActionType;
  caseReferenceHmac: string;
  actorSubjectHmacKeyVersion: number;
  actorSubjectHmac: string;
  occurredAt: number;
  previousEventSHA256: string;
  artifactSHA256: string;
}

export interface ModerationEvidenceEventRecord {
  event: ModerationEvidenceEvent;
  eventSHA256: string;
}

export interface ModerationEvidenceExportBody {
  schema: typeof MODERATION_EVIDENCE_EXPORT_SCHEMA;
  exportID: string;
  actionID: string;
  actorSubjectHmacKeyVersion: number;
  actorSubjectHmac: string;
  generatedAt: number;
  caseReferenceHmac: string;
  eventCount: number;
  chainHeadSHA256: string;
  events: ModerationEvidenceEventRecord[];
}

export interface SignedModerationEvidenceExport {
  schema: typeof MODERATION_EVIDENCE_SIGNATURE_SCHEMA;
  algorithm: typeof MODERATION_EVIDENCE_SIGNATURE_ALGORITHM;
  keyID: string;
  export: ModerationEvidenceExportBody;
  exportSHA256: string;
  signature: string;
}

export interface ModerationEvidenceSigner {
  readonly algorithm: typeof MODERATION_EVIDENCE_SIGNATURE_ALGORITHM;
  readonly keyID: string;
  sign(message: Uint8Array): Promise<Uint8Array>;
}

export interface ModerationEvidenceVerifier {
  readonly algorithm: typeof MODERATION_EVIDENCE_SIGNATURE_ALGORITHM;
  readonly keyID: string;
  verify(message: Uint8Array, signature: Uint8Array): Promise<boolean>;
}

export type ModerationEvidenceVerifierResolver = (
  keyID: string,
) => Promise<ModerationEvidenceVerifier | null>;

/**
 * Implementations must atomically reject a previously consumed export ID or
 * event ID, and consume every supplied ID together on success. A durable
 * implementation is required before this foundation can be connected to a
 * production route.
 */
export interface ModerationEvidenceReplayGuard {
  consume(exportID: string, eventIDs: readonly string[]): Promise<boolean>;
}

type CanonicalValue =
  | null
  | boolean
  | number
  | string
  | CanonicalValue[]
  | { [key: string]: CanonicalValue };

function fail(code: string): never {
  throw new ModerationEvidenceExportError(code);
}

function exactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
  code = "invalid_fields",
): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length
      || actual.some((key, index) => key !== wanted[index])) {
    fail(code);
  }
}

function record(value: unknown, code = "invalid_object"): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object"
      || (Object.getPrototypeOf(value) !== Object.prototype
          && Object.getPrototypeOf(value) !== null)) {
    fail(code);
  }
  return value as Record<string, unknown>;
}

function canonicalValue(value: unknown): CanonicalValue {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) fail("noncanonical_number");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  const object = record(value, "noncanonical_object");
  const result: { [key: string]: CanonicalValue } = {};
  for (const key of Object.keys(object).sort()) {
    if (key.length === 0) fail("noncanonical_key");
    result[key] = canonicalValue(object[key]);
  }
  return result;
}

export function canonicalModerationEvidenceBytes(value: unknown): Uint8Array {
  return encoder.encode(JSON.stringify(canonicalValue(value)));
}

function bytesCopy(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    bytesCopy(bytes),
  ));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function exactString(value: unknown, code: string): string {
  if (typeof value !== "string" || value.length === 0 || value.trim() !== value) {
    fail(code);
  }
  return value;
}

function sha256Value(value: unknown, code: string): string {
  const string = exactString(value, code);
  if (!sha256Pattern.test(string)) fail(code);
  return string;
}

function uuidV4(value: unknown, code: string): string {
  const string = exactString(value, code);
  if (!uuidV4Pattern.test(string)) fail(code);
  return string;
}

function positiveUnixSecond(value: unknown, code: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) fail(code);
  return value as number;
}

function positiveSequence(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1
      || (value as number) > maximumExportEvents) {
    fail("invalid_sequence");
  }
  return value as number;
}

function positiveKeyVersion(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1
      || (value as number) > 2_147_483_647) {
    fail("invalid_actor_subject_hmac_key_version");
  }
  return value as number;
}

function actionType(value: unknown): ModerationEvidenceActionType {
  const string = exactString(value, "invalid_action_type");
  if (!actionTypes.has(string)) fail("invalid_action_type");
  return string as ModerationEvidenceActionType;
}

function keyID(value: unknown): string {
  const string = exactString(value, "invalid_key_id");
  if (!keyIDPattern.test(string)) fail("invalid_key_id");
  return string;
}

function parseEvent(value: unknown): ModerationEvidenceEvent {
  const object = record(value);
  exactKeys(object, [
    "schema",
    "sequence",
    "eventID",
    "actionID",
    "actionType",
    "caseReferenceHmac",
    "actorSubjectHmacKeyVersion",
    "actorSubjectHmac",
    "occurredAt",
    "previousEventSHA256",
    "artifactSHA256",
  ]);
  if (object.schema !== MODERATION_EVIDENCE_EVENT_SCHEMA) fail("invalid_event_schema");
  return {
    schema: MODERATION_EVIDENCE_EVENT_SCHEMA,
    sequence: positiveSequence(object.sequence),
    eventID: uuidV4(object.eventID, "invalid_event_id"),
    actionID: uuidV4(object.actionID, "invalid_action_id"),
    actionType: actionType(object.actionType),
    caseReferenceHmac: sha256Value(
      object.caseReferenceHmac,
      "invalid_case_reference_hmac",
    ),
    actorSubjectHmacKeyVersion: positiveKeyVersion(
      object.actorSubjectHmacKeyVersion,
    ),
    actorSubjectHmac: sha256Value(
      object.actorSubjectHmac,
      "invalid_actor_subject_hmac",
    ),
    occurredAt: positiveUnixSecond(object.occurredAt, "invalid_occurred_at"),
    previousEventSHA256: sha256Value(
      object.previousEventSHA256,
      "invalid_previous_event_sha256",
    ),
    artifactSHA256: sha256Value(
      object.artifactSHA256,
      "invalid_artifact_sha256",
    ),
  };
}

function parseEventRecord(value: unknown): ModerationEvidenceEventRecord {
  const object = record(value);
  exactKeys(object, ["event", "eventSHA256"]);
  return {
    event: parseEvent(object.event),
    eventSHA256: sha256Value(object.eventSHA256, "invalid_event_sha256"),
  };
}

function parseExportBody(value: unknown): ModerationEvidenceExportBody {
  const object = record(value);
  exactKeys(object, [
    "schema",
    "exportID",
    "actionID",
    "actorSubjectHmacKeyVersion",
    "actorSubjectHmac",
    "generatedAt",
    "caseReferenceHmac",
    "eventCount",
    "chainHeadSHA256",
    "events",
  ]);
  if (object.schema !== MODERATION_EVIDENCE_EXPORT_SCHEMA) fail("invalid_export_schema");
  if (!Array.isArray(object.events) || object.events.length < 1
      || object.events.length > maximumExportEvents) {
    fail("invalid_event_count");
  }
  if (!Number.isSafeInteger(object.eventCount)
      || object.eventCount !== object.events.length) {
    fail("invalid_event_count");
  }
  return {
    schema: MODERATION_EVIDENCE_EXPORT_SCHEMA,
    exportID: uuidV4(object.exportID, "invalid_export_id"),
    actionID: uuidV4(object.actionID, "invalid_action_id"),
    actorSubjectHmacKeyVersion: positiveKeyVersion(
      object.actorSubjectHmacKeyVersion,
    ),
    actorSubjectHmac: sha256Value(
      object.actorSubjectHmac,
      "invalid_actor_subject_hmac",
    ),
    generatedAt: positiveUnixSecond(object.generatedAt, "invalid_generated_at"),
    caseReferenceHmac: sha256Value(
      object.caseReferenceHmac,
      "invalid_case_reference_hmac",
    ),
    eventCount: object.eventCount,
    chainHeadSHA256: sha256Value(
      object.chainHeadSHA256,
      "invalid_chain_head_sha256",
    ),
    events: object.events.map(parseEventRecord),
  };
}

function parseSignedExport(value: unknown): SignedModerationEvidenceExport {
  const object = record(value);
  exactKeys(object, [
    "schema",
    "algorithm",
    "keyID",
    "export",
    "exportSHA256",
    "signature",
  ]);
  if (object.schema !== MODERATION_EVIDENCE_SIGNATURE_SCHEMA) {
    fail("invalid_signature_schema");
  }
  if (object.algorithm !== MODERATION_EVIDENCE_SIGNATURE_ALGORITHM) {
    fail("invalid_signature_algorithm");
  }
  const signature = exactString(object.signature, "invalid_signature");
  try {
    base64urlDecode(signature, 64);
  } catch {
    fail("invalid_signature");
  }
  return {
    schema: MODERATION_EVIDENCE_SIGNATURE_SCHEMA,
    algorithm: MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
    keyID: keyID(object.keyID),
    export: parseExportBody(object.export),
    exportSHA256: sha256Value(object.exportSHA256, "invalid_export_sha256"),
    signature,
  };
}

async function validateEventChain(
  body: ModerationEvidenceExportBody,
): Promise<void> {
  const eventIDs = new Set<string>();
  const actionIDs = new Set<string>();
  let previousDigest = MODERATION_EVIDENCE_GENESIS_SHA256;
  let previousTime = 0;

  for (const [index, recordValue] of body.events.entries()) {
    const record = parseEventRecord(recordValue);
    const expectedSequence = index + 1;
    if (record.event.sequence !== expectedSequence) fail("noncontiguous_sequence");
    if (record.event.caseReferenceHmac !== body.caseReferenceHmac) {
      fail("case_reference_mismatch");
    }
    if (record.event.previousEventSHA256 !== previousDigest) {
      fail("broken_event_chain");
    }
    if (record.event.occurredAt < previousTime
        || record.event.occurredAt > body.generatedAt) {
      fail("invalid_event_time_order");
    }
    if (eventIDs.has(record.event.eventID)) fail("replayed_event_id");
    if (actionIDs.has(record.event.actionID)) fail("replayed_action_id");
    const computedDigest = await sha256Hex(
      canonicalModerationEvidenceBytes(record.event),
    );
    if (computedDigest !== record.eventSHA256) fail("event_digest_mismatch");
    eventIDs.add(record.event.eventID);
    actionIDs.add(record.event.actionID);
    previousDigest = computedDigest;
    previousTime = record.event.occurredAt;
  }

  if (body.eventCount !== body.events.length) fail("invalid_event_count");
  if (body.chainHeadSHA256 !== previousDigest) fail("chain_head_mismatch");
  const exportEvent = body.events.at(-1)?.event;
  if (exportEvent?.actionID !== body.actionID
      || exportEvent.actionType !== "evidence_export"
      || exportEvent.actorSubjectHmacKeyVersion
        !== body.actorSubjectHmacKeyVersion
      || exportEvent.actorSubjectHmac !== body.actorSubjectHmac) {
    fail("export_action_mismatch");
  }
}

function signatureMessage(
  keyIdentifier: string,
  exportSHA256: string,
): Uint8Array {
  return canonicalModerationEvidenceBytes({
    schema: MODERATION_EVIDENCE_SIGNATURE_SCHEMA,
    algorithm: MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
    keyID: keyIdentifier,
    exportSHA256,
  });
}

export async function buildModerationEvidenceChain(
  inputs: readonly ModerationEvidenceEventInput[],
): Promise<ModerationEvidenceEventRecord[]> {
  if (inputs.length < 1 || inputs.length > maximumExportEvents) {
    fail("invalid_event_count");
  }
  const eventIDs = new Set<string>();
  const actionIDs = new Set<string>();
  let previousDigest = MODERATION_EVIDENCE_GENESIS_SHA256;
  let previousTime = 0;
  const records: ModerationEvidenceEventRecord[] = [];

  for (const [index, inputValue] of inputs.entries()) {
    const input = record(inputValue);
    exactKeys(input, [
      "eventID",
      "actionID",
      "actionType",
      "caseReferenceHmac",
      "actorSubjectHmacKeyVersion",
      "actorSubjectHmac",
      "occurredAt",
      "artifactSHA256",
    ]);
    const event: ModerationEvidenceEvent = {
      schema: MODERATION_EVIDENCE_EVENT_SCHEMA,
      sequence: index + 1,
      eventID: uuidV4(input.eventID, "invalid_event_id"),
      actionID: uuidV4(input.actionID, "invalid_action_id"),
      actionType: actionType(input.actionType),
      caseReferenceHmac: sha256Value(
        input.caseReferenceHmac,
        "invalid_case_reference_hmac",
      ),
      actorSubjectHmacKeyVersion: positiveKeyVersion(
        input.actorSubjectHmacKeyVersion,
      ),
      actorSubjectHmac: sha256Value(
        input.actorSubjectHmac,
        "invalid_actor_subject_hmac",
      ),
      occurredAt: positiveUnixSecond(input.occurredAt, "invalid_occurred_at"),
      previousEventSHA256: previousDigest,
      artifactSHA256: sha256Value(
        input.artifactSHA256,
        "invalid_artifact_sha256",
      ),
    };
    if (event.occurredAt < previousTime) fail("invalid_event_time_order");
    if (eventIDs.has(event.eventID)) fail("replayed_event_id");
    if (actionIDs.has(event.actionID)) fail("replayed_action_id");
    const eventSHA256 = await sha256Hex(canonicalModerationEvidenceBytes(event));
    records.push({ event, eventSHA256 });
    eventIDs.add(event.eventID);
    actionIDs.add(event.actionID);
    previousDigest = eventSHA256;
    previousTime = event.occurredAt;
  }
  return records;
}

export async function createSignedModerationEvidenceExport(
  fields: {
    exportID: string;
    actionID: string;
    actorSubjectHmacKeyVersion: number;
    actorSubjectHmac: string;
    generatedAt: number;
    caseReferenceHmac: string;
    events: readonly ModerationEvidenceEventRecord[];
  },
  signer: ModerationEvidenceSigner,
): Promise<Uint8Array> {
  const fieldsObject = record(fields);
  exactKeys(fieldsObject, [
    "exportID",
    "actionID",
    "actorSubjectHmacKeyVersion",
    "actorSubjectHmac",
    "generatedAt",
    "caseReferenceHmac",
    "events",
  ]);
  if (signer === null || typeof signer !== "object"
      || typeof signer.sign !== "function") {
    fail("invalid_signing_boundary");
  }
  const identifier = keyID(signer.keyID);
  if (signer.algorithm !== MODERATION_EVIDENCE_SIGNATURE_ALGORITHM) {
    fail("invalid_signature_algorithm");
  }
  const events = fields.events.map(parseEventRecord);
  if (events.length < 1 || events.length > maximumExportEvents) {
    fail("invalid_event_count");
  }
  const body: ModerationEvidenceExportBody = {
    schema: MODERATION_EVIDENCE_EXPORT_SCHEMA,
    exportID: uuidV4(fields.exportID, "invalid_export_id"),
    actionID: uuidV4(fields.actionID, "invalid_action_id"),
    actorSubjectHmacKeyVersion: positiveKeyVersion(
      fields.actorSubjectHmacKeyVersion,
    ),
    actorSubjectHmac: sha256Value(
      fields.actorSubjectHmac,
      "invalid_actor_subject_hmac",
    ),
    generatedAt: positiveUnixSecond(fields.generatedAt, "invalid_generated_at"),
    caseReferenceHmac: sha256Value(
      fields.caseReferenceHmac,
      "invalid_case_reference_hmac",
    ),
    eventCount: events.length,
    chainHeadSHA256: events.at(-1)?.eventSHA256 ?? fail("invalid_event_count"),
    events,
  };
  await validateEventChain(body);
  const exportSHA256 = await sha256Hex(canonicalModerationEvidenceBytes(body));
  const rawSignature = await signer.sign(signatureMessage(identifier, exportSHA256));
  if (!(rawSignature instanceof Uint8Array) || rawSignature.length !== 64) {
    fail("invalid_signer_output");
  }
  const envelope: SignedModerationEvidenceExport = {
    schema: MODERATION_EVIDENCE_SIGNATURE_SCHEMA,
    algorithm: MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
    keyID: identifier,
    export: body,
    exportSHA256,
    signature: base64urlEncode(rawSignature),
  };
  return canonicalModerationEvidenceBytes(envelope);
}

export async function verifySignedModerationEvidenceExport(
  bytes: Uint8Array,
  resolveVerifier: ModerationEvidenceVerifierResolver,
  replayGuard: ModerationEvidenceReplayGuard,
): Promise<SignedModerationEvidenceExport> {
  if (typeof resolveVerifier !== "function"
      || replayGuard === null || typeof replayGuard !== "object"
      || typeof replayGuard.consume !== "function") {
    fail("invalid_verification_boundary");
  }
  if (!(bytes instanceof Uint8Array) || bytes.length < 1
      || bytes.length > maximumExportBytes) {
    fail("invalid_export_bytes");
  }
  let text: string;
  let parsed: unknown;
  try {
    text = decoder.decode(bytes);
    parsed = JSON.parse(text) as unknown;
  } catch {
    fail("invalid_export_json");
  }
  const envelope = parseSignedExport(parsed);
  // Validate the fixed-depth schema before recursively canonicalizing. This
  // prevents an otherwise well-sized but pathologically deep unknown JSON
  // value from turning canonicalization into an unbounded stack walk.
  const canonical = canonicalModerationEvidenceBytes(parsed);
  if (text !== decoder.decode(canonical)) fail("noncanonical_export_json");
  await validateEventChain(envelope.export);
  const computedExportSHA256 = await sha256Hex(
    canonicalModerationEvidenceBytes(envelope.export),
  );
  if (computedExportSHA256 !== envelope.exportSHA256) {
    fail("export_digest_mismatch");
  }
  const verifier = await resolveVerifier(envelope.keyID);
  if (verifier === null || verifier.keyID !== envelope.keyID
      || verifier.algorithm !== MODERATION_EVIDENCE_SIGNATURE_ALGORITHM) {
    fail("untrusted_signing_key");
  }
  let signature: Uint8Array;
  try {
    signature = base64urlDecode(envelope.signature, 64);
  } catch {
    fail("invalid_signature");
  }
  if (!await verifier.verify(
    signatureMessage(envelope.keyID, envelope.exportSHA256),
    signature,
  )) {
    fail("signature_verification_failed");
  }
  if (!await replayGuard.consume(
    envelope.export.exportID,
    envelope.export.events.map((entry) => entry.event.eventID),
  )) {
    fail("replayed_export");
  }
  return envelope;
}

function assertEd25519Key(
  key: CryptoKey,
  expectedType: "private" | "public",
  usage: "sign" | "verify",
): void {
  if (key.type !== expectedType || key.algorithm.name !== "Ed25519"
      || !key.usages.includes(usage)
      || (expectedType === "private" && key.extractable)) {
    fail("invalid_ed25519_key");
  }
}

/**
 * Standard WebCrypto Ed25519 adapter. Cloudflare Workers and Node 22 both
 * expose this algorithm. The private CryptoKey must come from an external
 * secret/key-management boundary; this module never imports or stores it.
 */
export function webCryptoEd25519EvidenceSigner(
  identifierValue: string,
  privateKey: CryptoKey,
): ModerationEvidenceSigner {
  const identifier = keyID(identifierValue);
  assertEd25519Key(privateKey, "private", "sign");
  return {
    algorithm: MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
    keyID: identifier,
    async sign(message): Promise<Uint8Array> {
      return new Uint8Array(await crypto.subtle.sign(
        MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
        privateKey,
        bytesCopy(message),
      ));
    },
  };
}

export function webCryptoEd25519EvidenceVerifier(
  identifierValue: string,
  publicKey: CryptoKey,
): ModerationEvidenceVerifier {
  const identifier = keyID(identifierValue);
  assertEd25519Key(publicKey, "public", "verify");
  return {
    algorithm: MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
    keyID: identifier,
    verify(message, signature): Promise<boolean> {
      return crypto.subtle.verify(
        MODERATION_EVIDENCE_SIGNATURE_ALGORITHM,
        publicKey,
        bytesCopy(signature),
        bytesCopy(message),
      );
    },
  };
}
