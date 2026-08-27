import { base64urlDecode } from "./encoding";
import { encodeCanonicalFields } from "./protocol";

export const MODERATION_OPERATOR_CASE_REFERENCE_DOMAIN =
  "NW.MODERATION-OPERATOR.CASE-REFERENCE" as const;
export const MODERATION_OPERATOR_CASE_REFERENCE_PROTOCOL_VERSION = 1 as const;
export const MODERATION_OPERATOR_CASE_REFERENCE_FAILURE_CODE =
  "operator_case_reference_derivation_failed" as const;

const REPORT_ID_BYTES = 16;
const REPORT_ID_CHARACTERS = 22;
const HMAC_SECRET_BYTES = 32;

export class ModerationOperatorCaseReferenceError extends Error {
  readonly code = MODERATION_OPERATOR_CASE_REFERENCE_FAILURE_CODE;

  constructor() {
    super(MODERATION_OPERATOR_CASE_REFERENCE_FAILURE_CODE);
    this.name = "ModerationOperatorCaseReferenceError";
  }
}

/**
 * The raw report ID is an input only. Callers must not log this object. The
 * key version is part of the authenticated transcript and must be stored with
 * the derived HMAC in the authoritative 0018 versioned-reference row. Callers
 * must never insert the 0013 compatibility table directly.
 */
export interface ModerationOperatorCaseReferenceFields {
  reportId: string;
  caseReferenceHmacKeyVersion: number;
}

/** Values intended for a future version-bound database row. */
export interface ModerationOperatorCaseReferenceBinding {
  caseReferenceHmacKeyVersion: number;
  caseReferenceHmac: string;
}

function fail(): never {
  throw new ModerationOperatorCaseReferenceError();
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactFields(value: unknown): Record<string, unknown> {
  if (!isPlainRecord(value)) fail();
  const keys = Reflect.ownKeys(value);
  if (keys.length !== 2 || keys.some((key) => typeof key !== "string")) fail();
  const expected = new Set(["reportId", "caseReferenceHmacKeyVersion"]);
  if (keys.some((key) => !expected.has(key as string))) fail();
  for (const key of expected) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined || !("value" in descriptor)
        || !descriptor.enumerable) fail();
  }
  return value;
}

function reportId(value: unknown): string {
  if (typeof value !== "string" || value.length !== REPORT_ID_CHARACTERS
      || !/^[A-Za-z0-9_-]{22}$/u.test(value)) fail();
  try {
    base64urlDecode(value, REPORT_ID_BYTES);
  } catch {
    throw new ModerationOperatorCaseReferenceError();
  }
  return value;
}

function positiveInt32(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1
      || (value as number) > 0x7fff_ffff) fail();
  return value as number;
}

function copySecret(value: unknown): Uint8Array<ArrayBuffer> {
  if (!(value instanceof Uint8Array) || value.byteLength !== HMAC_SECRET_BYTES) {
    fail();
  }
  const copy = new Uint8Array(HMAC_SECRET_BYTES);
  copy.set(value);
  return copy;
}

function lowercaseHex(value: Uint8Array): string {
  let output = "";
  for (const byte of value) output += byte.toString(16).padStart(2, "0");
  return output;
}

/**
 * Derive a pseudonymous case reference with WebCrypto HMAC-SHA256.
 *
 * This pure function performs no I/O and never returns the raw report ID or
 * key. The caller remains responsible for keeping both out of logs and for
 * persisting the returned key version and HMAC only through the atomic 0018
 * versioned-reference statement.
 */
export async function deriveModerationOperatorCaseReference(
  fieldsValue: unknown,
  hmacSecretValue: unknown,
): Promise<ModerationOperatorCaseReferenceBinding> {
  let secret: Uint8Array<ArrayBuffer> | undefined;
  try {
    const fields = exactFields(fieldsValue);
    const canonicalReportId = reportId(fields.reportId);
    const keyVersion = positiveInt32(fields.caseReferenceHmacKeyVersion);
    secret = copySecret(hmacSecretValue);
    const key = await crypto.subtle.importKey(
      "raw",
      secret.buffer,
      { name: "HMAC", hash: "SHA-256", length: 256 },
      false,
      ["sign"],
    );
    const transcript = encodeCanonicalFields([
      MODERATION_OPERATOR_CASE_REFERENCE_DOMAIN,
      String(MODERATION_OPERATOR_CASE_REFERENCE_PROTOCOL_VERSION),
      String(keyVersion),
      canonicalReportId,
    ]);
    const message = new Uint8Array(transcript);
    const signature = new Uint8Array(await crypto.subtle.sign(
      "HMAC",
      key,
      message.buffer,
    ));
    return Object.freeze({
      caseReferenceHmacKeyVersion: keyVersion,
      caseReferenceHmac: lowercaseHex(signature),
    });
  } catch {
    fail();
  } finally {
    secret?.fill(0);
  }
  // TypeScript does not infer the terminating catch through this finally.
  throw new ModerationOperatorCaseReferenceError();
}
