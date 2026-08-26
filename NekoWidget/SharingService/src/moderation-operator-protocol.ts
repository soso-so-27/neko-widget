import { base64urlDecode } from "./encoding";
import { encodeCanonicalFields } from "./protocol";

export const MODERATION_OPERATOR_PROTOCOL_VERSION = 2 as const;
export const MODERATION_OPERATOR_STEP_UP_DOMAIN =
  "NW.MODERATION-OPERATOR.STEP-UP" as const;
export const MODERATION_OPERATOR_MAXIMUM_CHALLENGE_SECONDS = 300;
export const MODERATION_OPERATOR_MAXIMUM_PATHNAME_CHARACTERS = 512;

export const moderationOperatorActionTypes = [
  "review_start",
  "evidence_export",
  "review_decision",
  "content_delete",
] as const;

export type ModerationOperatorActionType =
  (typeof moderationOperatorActionTypes)[number];
export type ModerationOperatorChallengePurpose = "request" | "approve";

export class ModerationOperatorProtocolError extends Error {}

const lowercaseHexSHA256Pattern = /^[0-9a-f]{64}$/u;
const lowercaseUUIDv4Pattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const operatorPathPattern = /^\/operator\/v1(?:\/[A-Za-z0-9_-]+)+$/u;
const actionTypes = new Set<string>(moderationOperatorActionTypes);
const methods = new Set(["DELETE", "POST", "PUT"]);

function fail(message: string): never {
  throw new ModerationOperatorProtocolError(message);
}

function exactKeys(
  value: object,
  expected: readonly string[],
): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length
      || actual.some((key, index) => key !== wanted[index])) {
    fail("step-up challenge fields are invalid");
  }
}

function exactString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0 || value.trim() !== value) {
    fail(`${label} is not canonical`);
  }
  return value;
}

function sha256Hex(value: unknown, label: string): string {
  const string = exactString(value, label);
  if (!lowercaseHexSHA256Pattern.test(string)) fail(`${label} is not a SHA-256 digest`);
  return string;
}

function uuidV4(value: unknown, label: string): string {
  const string = exactString(value, label);
  if (!lowercaseUUIDv4Pattern.test(string)) fail(`${label} is not a lowercase UUIDv4`);
  return string;
}

function safeUnixSecond(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) {
    fail(`${label} is not a positive Unix second`);
  }
  return value as number;
}

function positiveInt32(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1
      || (value as number) > 0x7fff_ffff) {
    fail(`${label} is not a positive 32-bit integer`);
  }
  return value as number;
}

function challengeValue(value: unknown): string {
  const string = exactString(value, "challengeValue");
  try {
    base64urlDecode(string, 32);
  } catch {
    fail("challengeValue is not canonical 32-byte base64url");
  }
  return string;
}

function operatorPath(value: unknown): string {
  const path = exactString(value, "pathname");
  if (path.length > MODERATION_OPERATOR_MAXIMUM_PATHNAME_CHARACTERS
      || !operatorPathPattern.test(path) || path.includes("//")
      || path.split("/").some((segment) => segment === "." || segment === "..")) {
    fail("pathname is not a canonical operator path");
  }
  return path;
}

export interface ModerationOperatorStepUpChallengeFields {
  operatorSubjectHmac: string;
  subjectHmacKeyVersion: number;
  accessSessionSHA256: string;
  credentialIdSHA256: string;
  challengeId: string;
  challengeValue: string;
  purpose: ModerationOperatorChallengePurpose;
  actionType: ModerationOperatorActionType;
  actionId: string;
  caseReferenceHmac: string;
  method: string;
  pathname: string;
  bodySHA256: string;
  issuedAt: number;
  expiresAt: number;
}

/**
 * Canonical, ambiguity-free transcript for a future hardware-backed step-up
 * assertion. This function does not verify WebAuthn and is intentionally not an
 * authentication success path by itself.
 */
export function moderationOperatorStepUpChallengeTranscript(
  fields: ModerationOperatorStepUpChallengeFields,
): Uint8Array {
  if (fields === null || Array.isArray(fields) || typeof fields !== "object") {
    fail("step-up challenge fields are invalid");
  }
  exactKeys(fields, [
    "operatorSubjectHmac",
    "subjectHmacKeyVersion",
    "accessSessionSHA256",
    "credentialIdSHA256",
    "challengeId",
    "challengeValue",
    "purpose",
    "actionType",
    "actionId",
    "caseReferenceHmac",
    "method",
    "pathname",
    "bodySHA256",
    "issuedAt",
    "expiresAt",
  ]);

  const operatorSubjectHmac = sha256Hex(
    fields.operatorSubjectHmac,
    "operatorSubjectHmac",
  );
  const subjectHmacKeyVersion = positiveInt32(
    fields.subjectHmacKeyVersion,
    "subjectHmacKeyVersion",
  );
  const accessSessionSHA256 = sha256Hex(
    fields.accessSessionSHA256,
    "accessSessionSHA256",
  );
  const credentialIdSHA256 = sha256Hex(
    fields.credentialIdSHA256,
    "credentialIdSHA256",
  );
  const challengeId = uuidV4(fields.challengeId, "challengeId");
  const canonicalChallengeValue = challengeValue(fields.challengeValue);
  if (fields.purpose !== "request" && fields.purpose !== "approve") {
    fail("purpose is invalid");
  }
  if (!actionTypes.has(fields.actionType)) fail("actionType is invalid");
  const actionId = uuidV4(fields.actionId, "actionId");
  const caseReferenceHmac = sha256Hex(
    fields.caseReferenceHmac,
    "caseReferenceHmac",
  );
  const method = exactString(fields.method, "method");
  if (!methods.has(method)) fail("method is not canonical");
  const pathname = operatorPath(fields.pathname);
  const bodySHA256 = sha256Hex(fields.bodySHA256, "bodySHA256");
  const issuedAt = safeUnixSecond(fields.issuedAt, "issuedAt");
  const expiresAt = safeUnixSecond(fields.expiresAt, "expiresAt");
  if (expiresAt <= issuedAt
      || expiresAt - issuedAt > MODERATION_OPERATOR_MAXIMUM_CHALLENGE_SECONDS) {
    fail("step-up challenge expiry is invalid");
  }

  return encodeCanonicalFields([
    MODERATION_OPERATOR_STEP_UP_DOMAIN,
    String(MODERATION_OPERATOR_PROTOCOL_VERSION),
    operatorSubjectHmac,
    String(subjectHmacKeyVersion),
    accessSessionSHA256,
    credentialIdSHA256,
    challengeId,
    canonicalChallengeValue,
    fields.purpose,
    fields.actionType,
    actionId,
    caseReferenceHmac,
    method,
    pathname,
    bodySHA256,
    String(issuedAt),
    String(expiresAt),
  ]);
}
