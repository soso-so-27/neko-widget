import {
  verifyAuthenticationResponse,
  type AuthenticationResponseJSON,
} from "@simplewebauthn/server";

export const MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE =
  "operator_webauthn_verification_failed" as const;

const MAX_ASSERTION_CANONICAL_BYTES = 16_384;
const MAX_CREDENTIAL_ID_BYTES = 1_024;
const MAX_CLIENT_DATA_BYTES = 4_096;
const MIN_AUTHENTICATOR_DATA_BYTES = 37;
const MAX_AUTHENTICATOR_DATA_BYTES = 1_024;
const MIN_ES256_SIGNATURE_BYTES = 8;
const MAX_ES256_SIGNATURE_BYTES = 72;
const MIN_COSE_PUBLIC_KEY_BYTES = 32;
const MAX_COSE_PUBLIC_KEY_BYTES = 2_048;
const FLAGS_OFFSET = 32;
const COUNTER_OFFSET = 33;
const ALLOWED_AUTHENTICATOR_FLAGS = 0x05; // UP | UV only
const lowercaseSHA256Pattern = /^[0-9a-f]{64}$/u;
const base64urlPattern = /^[A-Za-z0-9_-]+$/u;

const encoder = new TextEncoder();
const fatalDecoder = new TextDecoder("utf-8", { fatal: true });

export class ModerationOperatorWebAuthnError extends Error {
  readonly code = MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE;

  constructor() {
    super(MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE);
    this.name = "ModerationOperatorWebAuthnError";
  }
}

export interface ModerationOperatorStoredCredential {
  /** Lowercase hexadecimal SHA-256 of the credential raw ID. */
  credentialIdSHA256: string;
  /** The immutable ES256/P-256 COSE public key captured at registration. */
  publicKeyCose: Uint8Array;
  /** The registration counter or most recently consumed assertion counter. */
  counter: number;
}

export interface PrepareModerationOperatorWebAuthnAssertionOptions {
  response: unknown;
  /** A single, exact HTTPS origin. Arrays and predicates are never accepted. */
  expectedOrigin: string;
  /** A single, exact RP ID. */
  expectedRPID: string;
  /** Lowercase hexadecimal SHA-256 of the server-generated 32-byte challenge. */
  expectedChallengeSHA256: string;
  credential: ModerationOperatorStoredCredential;
}

declare const preparedAssertionBrand: unique symbol;

/**
 * Opaque, in-isolate preflight result. Only the assertion digest is exposed so
 * a route can persist a one-shot attempt before expensive signature checking.
 */
export interface PreparedModerationOperatorWebAuthnAssertion {
  readonly assertionSHA256: string;
  readonly [preparedAssertionBrand]: true;
}

export interface VerifiedModerationOperatorWebAuthnAssertion {
  readonly assertionSHA256: string;
  readonly newCounter: number;
}

interface PreparedInternals {
  response: AuthenticationResponseJSON;
  expectedOrigin: string;
  expectedRPID: string;
  credentialId: string;
  publicKeyCose: Uint8Array<ArrayBuffer>;
  counter: number;
  assertionSHA256: string;
}

const preparedInternals = new WeakMap<object, PreparedInternals>();

function fail(): never {
  throw new ModerationOperatorWebAuthnError();
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactOwnKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const allowed = new Set([...required, ...optional]);
  const ownKeys = Reflect.ownKeys(value);
  if (ownKeys.some((key) => typeof key !== "string")) fail();
  const keys = ownKeys as string[];
  if (keys.some((key) => !allowed.has(key))) fail();
  for (const key of required) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) fail();
  }
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined || !("value" in descriptor) || !descriptor.enumerable) fail();
  }
}

function exactString(value: unknown, maximumCharacters: number): string {
  if (typeof value !== "string" || value.length === 0
      || value.length > maximumCharacters) fail();
  return value;
}

function base64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function canonicalBase64url(
  value: unknown,
  minimumBytes: number,
  maximumBytes: number,
): { value: string; bytes: Uint8Array } {
  const maximumCharacters = Math.ceil(maximumBytes * 4 / 3);
  const string = exactString(value, maximumCharacters);
  if (!base64urlPattern.test(string) || string.length % 4 === 1) fail();
  let binary: string;
  try {
    const padding = "=".repeat((4 - (string.length % 4)) % 4);
    binary = atob(string.replaceAll("-", "+").replaceAll("_", "/") + padding);
  } catch {
    fail();
  }
  const bytes = Uint8Array.from(binary!, (character) => character.charCodeAt(0));
  if (bytes.length < minimumBytes || bytes.length > maximumBytes
      || base64urlEncode(bytes) !== string) fail();
  return { value: string, bytes };
}

function copyBytes(
  value: unknown,
  minimum: number,
  maximum: number,
): Uint8Array<ArrayBuffer> {
  if (!(value instanceof Uint8Array)
      || value.byteLength < minimum || value.byteLength > maximum) fail();
  const copy = new Uint8Array(value.byteLength);
  copy.set(value);
  return copy;
}

function sha256HexValue(value: unknown): string {
  if (typeof value !== "string" || !lowercaseSHA256Pattern.test(value)) fail();
  return value;
}

function uint32(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0
      || (value as number) > 0xffff_ffff) fail();
  return value as number;
}

function hexToBytes(value: string): Uint8Array {
  const output = new Uint8Array(32);
  for (let index = 0; index < output.length; index += 1) {
    output[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return output;
}

function bytesToHex(value: Uint8Array): string {
  let result = "";
  for (const byte of value) result += byte.toString(16).padStart(2, "0");
  return result;
}

async function sha256(value: Uint8Array): Promise<Uint8Array> {
  const copy = new Uint8Array(value);
  return new Uint8Array(await crypto.subtle.digest("SHA-256", copy.buffer));
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.length ^ right.length;
  const maximum = Math.max(left.length, right.length);
  for (let index = 0; index < maximum; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function validateExpectedScope(expectedOrigin: unknown, expectedRPID: unknown): {
  origin: string;
  rpID: string;
} {
  const origin = exactString(expectedOrigin, 512);
  const rpID = exactString(expectedRPID, 253);
  if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/u.test(rpID)
      || rpID.includes("..")
      || rpID.split(".").some((label) =>
        !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(label))) fail();
  let parsed: URL;
  try {
    parsed = new URL(origin);
  } catch {
    fail();
  }
  if (parsed!.protocol !== "https:" || parsed!.username !== "" || parsed!.password !== ""
      || parsed!.pathname !== "/" || parsed!.search !== "" || parsed!.hash !== ""
      || parsed!.origin !== origin
      || (parsed!.hostname !== rpID && !parsed!.hostname.endsWith(`.${rpID}`))) fail();
  let normalizedRPID: string;
  try {
    normalizedRPID = new URL(`https://${rpID}`).hostname;
  } catch {
    fail();
  }
  if (normalizedRPID! !== rpID) fail();
  return { origin, rpID };
}

class StrictClientDataParser {
  private index = 0;

  constructor(private readonly text: string) {}

  parse(): { type: string; challenge: string; origin: string; crossOrigin?: false } {
    this.whitespace();
    this.character("{");
    const fields = new Map<string, string | false>();
    this.whitespace();
    if (this.peek() !== "}") {
      while (true) {
        const key = this.string();
        if (fields.has(key)) fail();
        if (key !== "type" && key !== "challenge" && key !== "origin"
            && key !== "crossOrigin") fail();
        this.whitespace();
        this.character(":");
        this.whitespace();
        if (key === "crossOrigin") {
          if (this.text.slice(this.index, this.index + 5) !== "false") fail();
          this.index += 5;
          fields.set(key, false);
        } else {
          fields.set(key, this.string());
        }
        this.whitespace();
        if (this.peek() === "}") break;
        this.character(",");
        this.whitespace();
      }
    }
    this.character("}");
    this.whitespace();
    if (this.index !== this.text.length) fail();
    const type = fields.get("type");
    const challenge = fields.get("challenge");
    const origin = fields.get("origin");
    if (typeof type !== "string" || typeof challenge !== "string"
        || typeof origin !== "string" || fields.size < 3) fail();
    return fields.has("crossOrigin")
      ? { type, challenge, origin, crossOrigin: false }
      : { type, challenge, origin };
  }

  private peek(): string | undefined {
    return this.text[this.index];
  }

  private character(expected: string): void {
    if (this.text[this.index] !== expected) fail();
    this.index += 1;
  }

  private whitespace(): void {
    while (this.index < this.text.length
      && (this.text[this.index] === " " || this.text[this.index] === "\n"
        || this.text[this.index] === "\r" || this.text[this.index] === "\t")) {
      this.index += 1;
    }
  }

  private string(): string {
    if (this.text[this.index] !== "\"") fail();
    const start = this.index;
    this.index += 1;
    let escaped = false;
    while (this.index < this.text.length) {
      const code = this.text.charCodeAt(this.index);
      if (!escaped && code === 0x22) {
        this.index += 1;
        const token = this.text.slice(start, this.index);
        try {
          const decoded: unknown = JSON.parse(token);
          if (typeof decoded !== "string") fail();
          return decoded;
        } catch {
          fail();
        }
      }
      if (!escaped && code < 0x20) fail();
      if (!escaped && code === 0x5c) {
        escaped = true;
      } else {
        escaped = false;
      }
      this.index += 1;
    }
    fail();
  }
}

class StrictCBORCursor {
  private index = 0;

  constructor(private readonly bytes: Uint8Array) {}

  parseES256PublicKey(): void {
    const mapLength = this.header(5);
    if (mapLength !== 5) fail();
    const entries = new Map<number, number | Uint8Array>();
    for (let index = 0; index < mapLength; index += 1) {
      const key = this.integer();
      if (entries.has(key)) fail();
      if (key === -2 || key === -3) {
        const length = this.header(2);
        if (length !== 32 || this.index + length > this.bytes.length) fail();
        entries.set(key, this.bytes.slice(this.index, this.index + length));
        this.index += length;
      } else if (key === 1 || key === 3 || key === -1) {
        entries.set(key, this.integer());
      } else {
        fail();
      }
    }
    if (this.index !== this.bytes.length || entries.get(1) !== 2
        || entries.get(3) !== -7 || entries.get(-1) !== 1
        || !(entries.get(-2) instanceof Uint8Array)
        || !(entries.get(-3) instanceof Uint8Array)) fail();
  }

  private integer(): number {
    if (this.index >= this.bytes.length) fail();
    const major = this.bytes[this.index]! >>> 5;
    if (major !== 0 && major !== 1) fail();
    const value = this.header(major);
    return major === 0 ? value : -1 - value;
  }

  private header(expectedMajor: number): number {
    if (this.index >= this.bytes.length) fail();
    const initial = this.bytes[this.index++]!;
    const major = initial >>> 5;
    const additional = initial & 0x1f;
    if (major !== expectedMajor || additional === 31) fail();
    if (additional < 24) return additional;
    let byteCount: number;
    if (additional === 24) byteCount = 1;
    else if (additional === 25) byteCount = 2;
    else if (additional === 26) byteCount = 4;
    else fail();
    if (this.index + byteCount! > this.bytes.length) fail();
    let value = 0;
    for (let offset = 0; offset < byteCount!; offset += 1) {
      value = value * 256 + this.bytes[this.index++]!;
    }
    if ((byteCount! === 1 && value < 24)
        || (byteCount! === 2 && value <= 0xff)
        || (byteCount! === 4 && value <= 0xffff)) fail();
    return value;
  }
}

function canonicalAssertionBytes(
  response: AuthenticationResponseJSON,
  userHandleWasNull: boolean,
): Uint8Array {
  // This is an explicitly ordered serialization of the validated fields. It
  // never depends on property insertion order in the untrusted input object.
  const userHandle = userHandleWasNull ? ",\"userHandle\":null" : "";
  const attachment = response.authenticatorAttachment === undefined
    ? "" : `,\"authenticatorAttachment\":${JSON.stringify(response.authenticatorAttachment)}`;
  const canonical = "{"+
    `\"id\":${JSON.stringify(response.id)},`+
    `\"rawId\":${JSON.stringify(response.rawId)},`+
    "\"response\":{"+
    `\"clientDataJSON\":${JSON.stringify(response.response.clientDataJSON)},`+
    `\"authenticatorData\":${JSON.stringify(response.response.authenticatorData)},`+
    `\"signature\":${JSON.stringify(response.response.signature)}`+
    `${userHandle}}`+
    `${attachment},\"clientExtensionResults\":{},\"type\":\"public-key\"}`;
  const bytes = encoder.encode(canonical);
  if (bytes.byteLength > MAX_ASSERTION_CANONICAL_BYTES) fail();
  return bytes;
}

function validatedResponse(value: unknown): {
  response: AuthenticationResponseJSON;
  credentialIdBytes: Uint8Array;
  clientDataBytes: Uint8Array;
  authenticatorDataBytes: Uint8Array;
  userHandleWasNull: boolean;
} {
  if (!isPlainRecord(value)) fail();
  exactOwnKeys(value, ["id", "rawId", "response", "clientExtensionResults", "type"], [
    "authenticatorAttachment",
  ]);
  const id = canonicalBase64url(value.id, 1, MAX_CREDENTIAL_ID_BYTES);
  const rawId = canonicalBase64url(value.rawId, 1, MAX_CREDENTIAL_ID_BYTES);
  if (id.value !== rawId.value || !constantTimeEqual(id.bytes, rawId.bytes)) fail();
  if (value.type !== "public-key") fail();
  if (!isPlainRecord(value.clientExtensionResults)) fail();
  exactOwnKeys(value.clientExtensionResults, []);
  const attachment = value.authenticatorAttachment;
  if (attachment !== undefined && attachment !== "platform"
      && attachment !== "cross-platform") fail();
  if (!isPlainRecord(value.response)) fail();
  exactOwnKeys(value.response, ["clientDataJSON", "authenticatorData", "signature"], [
    "userHandle",
  ]);
  if (Object.prototype.hasOwnProperty.call(value.response, "userHandle")
      && value.response.userHandle !== null) fail();
  const clientData = canonicalBase64url(value.response.clientDataJSON, 2, MAX_CLIENT_DATA_BYTES);
  const authenticatorData = canonicalBase64url(
    value.response.authenticatorData,
    MIN_AUTHENTICATOR_DATA_BYTES,
    MAX_AUTHENTICATOR_DATA_BYTES,
  );
  const signature = canonicalBase64url(
    value.response.signature,
    MIN_ES256_SIGNATURE_BYTES,
    MAX_ES256_SIGNATURE_BYTES,
  );
  const assertionResponse: AuthenticationResponseJSON["response"] = {
    clientDataJSON: clientData.value,
    authenticatorData: authenticatorData.value,
    signature: signature.value,
  };
  const userHandleWasNull = Object.prototype.hasOwnProperty.call(
    value.response,
    "userHandle",
  );
  const response: AuthenticationResponseJSON = {
    id: id.value,
    rawId: rawId.value,
    response: assertionResponse,
    clientExtensionResults: {},
    type: "public-key",
    ...(attachment === undefined ? {} : { authenticatorAttachment: attachment }),
  };
  return {
    response,
    credentialIdBytes: id.bytes,
    clientDataBytes: clientData.bytes,
    authenticatorDataBytes: authenticatorData.bytes,
    userHandleWasNull,
  };
}

/**
 * Strictly parses and binds an assertion before any signature verification.
 * The challenge itself comes from the assertion, but must hash to the immutable
 * digest stored with the one-shot server challenge.
 */
export async function prepareModerationOperatorWebAuthnAssertion(
  options: PrepareModerationOperatorWebAuthnAssertionOptions,
): Promise<PreparedModerationOperatorWebAuthnAssertion> {
  try {
    if (!isPlainRecord(options) || !isPlainRecord(options.credential)) fail();
    exactOwnKeys(options as unknown as Record<string, unknown>, [
      "response", "expectedOrigin", "expectedRPID", "expectedChallengeSHA256", "credential",
    ]);
    exactOwnKeys(options.credential as unknown as Record<string, unknown>, [
      "credentialIdSHA256", "publicKeyCose", "counter",
    ]);
    const scope = validateExpectedScope(options.expectedOrigin, options.expectedRPID);
    const expectedChallengeDigest = hexToBytes(
      sha256HexValue(options.expectedChallengeSHA256),
    );
    const expectedCredentialDigest = hexToBytes(
      sha256HexValue(options.credential.credentialIdSHA256),
    );
    const publicKeyCose = copyBytes(
      options.credential.publicKeyCose,
      MIN_COSE_PUBLIC_KEY_BYTES,
      MAX_COSE_PUBLIC_KEY_BYTES,
    );
    new StrictCBORCursor(publicKeyCose).parseES256PublicKey();
    const counter = uint32(options.credential.counter);
    const validated = validatedResponse(options.response);
    if (!constantTimeEqual(await sha256(validated.credentialIdBytes), expectedCredentialDigest)) {
      fail();
    }
    let clientDataText: string;
    try {
      clientDataText = fatalDecoder.decode(validated.clientDataBytes);
    } catch {
      fail();
    }
    const clientData = new StrictClientDataParser(clientDataText!).parse();
    if (clientData.type !== "webauthn.get" || clientData.origin !== scope.origin) fail();
    const challenge = canonicalBase64url(clientData.challenge, 32, 32);
    if (!constantTimeEqual(await sha256(challenge.bytes), expectedChallengeDigest)) fail();
    const expectedRPIDHash = await sha256(encoder.encode(scope.rpID));
    if (!constantTimeEqual(
      validated.authenticatorDataBytes.subarray(0, 32),
      expectedRPIDHash,
    )) fail();
    const flags = validated.authenticatorDataBytes[FLAGS_OFFSET];
    if (flags !== ALLOWED_AUTHENTICATOR_FLAGS) fail();
    if (validated.authenticatorDataBytes.byteLength !== MIN_AUTHENTICATOR_DATA_BYTES) fail();
    const observedCounter = new DataView(
      validated.authenticatorDataBytes.buffer,
      validated.authenticatorDataBytes.byteOffset + COUNTER_OFFSET,
      4,
    ).getUint32(0, false);
    uint32(observedCounter);
    const assertionSHA256 = bytesToHex(await sha256(canonicalAssertionBytes(
      validated.response,
      validated.userHandleWasNull,
    )));
    const exposed = Object.freeze({ assertionSHA256 }) as unknown as
      PreparedModerationOperatorWebAuthnAssertion;
    preparedInternals.set(exposed as unknown as object, {
      response: validated.response,
      expectedOrigin: scope.origin,
      expectedRPID: scope.rpID,
      credentialId: validated.response.id,
      publicKeyCose,
      counter,
      assertionSHA256,
    });
    return exposed;
  } catch {
    fail();
  }
}

/** Consumes an opaque preflight result exactly once and verifies its ES256 signature. */
export async function verifyPreparedModerationOperatorWebAuthnAssertion(
  prepared: PreparedModerationOperatorWebAuthnAssertion,
): Promise<VerifiedModerationOperatorWebAuthnAssertion> {
  try {
    if (prepared === null || typeof prepared !== "object") fail();
    const internal = preparedInternals.get(prepared as unknown as object);
    if (internal === undefined) fail();
    preparedInternals.delete(prepared as unknown as object);
    const clientDataBytes = canonicalBase64url(
      internal.response.response.clientDataJSON,
      2,
      MAX_CLIENT_DATA_BYTES,
    ).bytes;
    const clientDataText = fatalDecoder.decode(clientDataBytes);
    const candidateChallenge = new StrictClientDataParser(clientDataText).parse().challenge;
    const result = await verifyAuthenticationResponse({
      response: internal.response,
      expectedChallenge: candidateChallenge,
      expectedOrigin: internal.expectedOrigin,
      expectedRPID: internal.expectedRPID,
      expectedType: "webauthn.get",
      requireUserVerification: true,
      credential: {
        id: internal.credentialId,
        publicKey: internal.publicKeyCose,
        counter: internal.counter,
      },
    });
    const info = result.authenticationInfo;
    if (!result.verified || info.credentialID !== internal.credentialId
        || info.origin !== internal.expectedOrigin || info.rpID !== internal.expectedRPID
        || info.userVerified !== true || info.credentialDeviceType !== "singleDevice"
        || info.credentialBackedUp !== false
        || info.authenticatorExtensionResults !== undefined) fail();
    const newCounter = uint32(info.newCounter);
    return Object.freeze({ assertionSHA256: internal.assertionSHA256, newCounter });
  } catch {
    fail();
  }
}
