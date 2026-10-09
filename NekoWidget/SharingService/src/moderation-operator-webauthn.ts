import {
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
  type AuthenticationResponseJSON,
  type RegistrationResponseJSON,
  type AuthenticatorTransportFuture,
} from "@simplewebauthn/server";
import { isoCBOR } from "@simplewebauthn/server/helpers";

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

export const MODERATION_OPERATOR_REGISTRATION_POLICY =
  "es256-single-device-none-or-packed-self-v1" as const;

const MAX_REGISTRATION_CANONICAL_BYTES = 16_384;
const MAX_ATTESTATION_OBJECT_BYTES = 8_192;
const ATTESTED_CREDENTIAL_OFFSET = 55;
const REGISTRATION_AUTHENTICATOR_FLAGS = 0x45; // UP | UV | AT only
const registrationTransports: readonly AuthenticatorTransportFuture[] = [
  "ble", "cable", "hybrid", "internal", "nfc", "smart-card", "usb",
];

export interface PrepareModerationOperatorWebAuthnRegistrationOptions {
  /** Compact browser projection, not an HTTP body parser. Unknown fields reject. */
  response: unknown;
  /** Trusted server policy, never request-selected or evidence of Access identity. */
  expectedOrigin: string;
  expectedRPID: string;
  /** Digest of a server-generated 32-byte enrollment challenge. */
  expectedChallengeSHA256: string;
}

declare const preparedRegistrationBrand: unique symbol;

/**
 * Unverified preflight digest backed by private, copied state. Verification
 * consumes this object once in this isolate, including on signature failure.
 * It does not consume a durable challenge or enforce expiry, identity or roles.
 */
export interface PreparedModerationOperatorWebAuthnRegistration {
  readonly registrationSHA256: string;
  readonly [preparedRegistrationBrand]: true;
}

/**
 * Cryptographic result only: neither none nor packed self-attestation establishes
 * trusted hardware or a real human. none has no attestation signature at all.
 * The credential is deliberately nested: admission and storage require a separate
 * authorized, durable ceremony. Raw ID/client data/attestation are not returned.
 */
export interface UnadmittedModerationOperatorWebAuthnRegistration {
  readonly kind: "unadmitted-operator-registration";
  readonly registrationSHA256: string;
  readonly credential: Readonly<ModerationOperatorStoredCredential>;
  readonly publicKeyCoseSHA256: string;
  readonly authenticatorAAGUIDSHA256: string;
  readonly attestationPolicy: typeof MODERATION_OPERATOR_REGISTRATION_POLICY;
  readonly attestationFormat: "none" | "packed";
  readonly selfAttestationSignatureVerified: boolean;
  readonly hardwareProvenanceVerified: false;
  readonly realHumanVerified: false;
  readonly enrollmentAdmissionAuthorized: false;
}

interface PreparedRegistrationInternals {
  response: RegistrationResponseJSON;
  expectedOrigin: string;
  expectedRPID: string;
  challenge: string;
  format: "none" | "packed";
  counter: number;
  publicKeyCose: Uint8Array<ArrayBuffer>;
  credentialIdSHA256: string;
  publicKeyCoseSHA256: string;
  authenticatorAAGUIDSHA256: string;
  registrationSHA256: string;
}

const preparedRegistrationInternals = new WeakMap<object, PreparedRegistrationInternals>();

function exactRegistrationMap(
  value: unknown,
  keys: readonly (string | number)[],
): asserts value is Map<string | number, unknown> {
  if (!(value instanceof Map) || value.size !== keys.length
      || keys.some((key) => !value.has(key))) fail();
}

function validatedRegistrationResponse(value: unknown): {
  response: RegistrationResponseJSON;
  credentialIdBytes: Uint8Array;
  clientDataBytes: Uint8Array;
  attestationBytes: Uint8Array<ArrayBuffer>;
} {
  if (!isPlainRecord(value)) fail();
  exactOwnKeys(value, ["id", "rawId", "type", "response", "clientExtensionResults"], [
    "authenticatorAttachment",
  ]);
  const id = canonicalBase64url(value.id, 1, MAX_CREDENTIAL_ID_BYTES);
  if (value.rawId !== id.value || value.type !== "public-key") fail();
  if (!isPlainRecord(value.clientExtensionResults)) fail();
  exactOwnKeys(value.clientExtensionResults, []);
  const attachment = value.authenticatorAttachment;
  if (attachment !== undefined && attachment !== "platform" && attachment !== "cross-platform") fail();
  if (!isPlainRecord(value.response)) fail();
  // Browser-derived publicKey/authenticatorData/algorithm fields are not authority.
  exactOwnKeys(value.response, ["clientDataJSON", "attestationObject"], ["transports"]);
  const suppliedTransports = value.response.transports;
  let transports: AuthenticatorTransportFuture[] | undefined;
  if (suppliedTransports !== undefined) {
    if (!Array.isArray(suppliedTransports) || suppliedTransports.length > registrationTransports.length) fail();
    transports = [];
    for (const transport of suppliedTransports) {
      if (typeof transport !== "string"
          || !registrationTransports.includes(transport as AuthenticatorTransportFuture)) fail();
      transports.push(transport as AuthenticatorTransportFuture);
    }
    if (new Set(transports).size !== transports.length) fail();
  }
  const client = canonicalBase64url(value.response.clientDataJSON, 2, MAX_CLIENT_DATA_BYTES);
  const attestation = canonicalBase64url(value.response.attestationObject, 3, MAX_ATTESTATION_OBJECT_BYTES);
  return {
    response: {
      id: id.value, rawId: id.value, type: "public-key", clientExtensionResults: {},
      response: {
        clientDataJSON: client.value, attestationObject: attestation.value,
        ...(transports === undefined ? {} : { transports }),
      },
      ...(attachment === undefined ? {} : { authenticatorAttachment: attachment }),
    },
    credentialIdBytes: id.bytes,
    clientDataBytes: client.bytes,
    attestationBytes: new Uint8Array(attestation.bytes),
  };
}

/**
 * Strict local registration preflight; no route, storage or admission is wired.
 * Reuses assertion origin/client-data/COSE rules. Actual authenticator support
 * and client attestation preference require a separately reviewed browser policy.
 */
export async function prepareModerationOperatorWebAuthnRegistration(
  options: PrepareModerationOperatorWebAuthnRegistrationOptions,
): Promise<PreparedModerationOperatorWebAuthnRegistration> {
  try {
    if (!isPlainRecord(options)) fail();
    exactOwnKeys(options as unknown as Record<string, unknown>, [
      "response", "expectedOrigin", "expectedRPID", "expectedChallengeSHA256",
    ]);
    const scope = validateExpectedScope(options.expectedOrigin, options.expectedRPID);
    const expectedChallengeDigest = hexToBytes(sha256HexValue(options.expectedChallengeSHA256));
    // Snapshot every caller-owned field before the first await.
    const validated = validatedRegistrationResponse(options.response);
    const client = new StrictClientDataParser(fatalDecoder.decode(validated.clientDataBytes)).parse();
    if (client.type !== "webauthn.create" || client.origin !== scope.origin) fail();
    const challenge = canonicalBase64url(client.challenge, 32, 32);
    if (!constantTimeEqual(await sha256(challenge.bytes), expectedChallengeDigest)) fail();
    const decoded = isoCBOR.decodeFirst<unknown>(validated.attestationBytes);
    exactRegistrationMap(decoded, ["fmt", "authData", "attStmt"]);
    // The decoder is general-purpose. Exact round-trip also rejects duplicate,
    // noncanonical and trailing CBOR content before invoking the verifier.
    if (!constantTimeEqual(
      isoCBOR.encode(decoded as Parameters<typeof isoCBOR.encode>[0]),
      validated.attestationBytes,
    )) fail();
    const format = decoded.get("fmt");
    const auth = decoded.get("authData");
    const statement = decoded.get("attStmt");
    if (!(auth instanceof Uint8Array) || auth.length < ATTESTED_CREDENTIAL_OFFSET + 1
        || auth.length > ATTESTED_CREDENTIAL_OFFSET + MAX_CREDENTIAL_ID_BYTES + MAX_COSE_PUBLIC_KEY_BYTES
        || auth[FLAGS_OFFSET] !== REGISTRATION_AUTHENTICATOR_FLAGS) fail();
    if (!constantTimeEqual(auth.subarray(0, 32), await sha256(encoder.encode(scope.rpID)))) fail();
    const counter = uint32(new DataView(auth.buffer, auth.byteOffset + COUNTER_OFFSET, 4).getUint32(0, false));
    const credentialLength = new DataView(auth.buffer, auth.byteOffset + 53, 2).getUint16(0, false);
    if (credentialLength < 1 || credentialLength > MAX_CREDENTIAL_ID_BYTES
        || ATTESTED_CREDENTIAL_OFFSET + credentialLength >= auth.length) fail();
    if (!constantTimeEqual(
      auth.subarray(ATTESTED_CREDENTIAL_OFFSET, ATTESTED_CREDENTIAL_OFFSET + credentialLength),
      validated.credentialIdBytes,
    )) fail();
    const publicKeyCose = copyBytes(auth.subarray(ATTESTED_CREDENTIAL_OFFSET + credentialLength),
      MIN_COSE_PUBLIC_KEY_BYTES, MAX_COSE_PUBLIC_KEY_BYTES);
    new StrictCBORCursor(publicKeyCose).parseES256PublicKey();
    if (format === "none") {
      exactRegistrationMap(statement, []);
    } else if (format === "packed") {
      exactRegistrationMap(statement, ["alg", "sig"]);
      const signature = statement.get("sig");
      if (statement.get("alg") !== -7 || !(signature instanceof Uint8Array)
          || signature.length < MIN_ES256_SIGNATURE_BYTES || signature.length > MAX_ES256_SIGNATURE_BYTES) fail();
    } else fail();
    // none verifies no signature, so validate the P-256 point independently too.
    const cose = isoCBOR.decodeFirst<unknown>(publicKeyCose);
    exactRegistrationMap(cose, [1, 3, -1, -2, -3]);
    const x = cose.get(-2); const y = cose.get(-3);
    if (!(x instanceof Uint8Array) || !(y instanceof Uint8Array)) fail();
    const raw = new Uint8Array(65); raw[0] = 4; raw.set(x, 1); raw.set(y, 33);
    await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const canonical = encoder.encode(JSON.stringify({
      policy: MODERATION_OPERATOR_REGISTRATION_POLICY, response: validated.response,
    }));
    if (canonical.length > MAX_REGISTRATION_CANONICAL_BYTES) fail();
    const registrationSHA256 = bytesToHex(await sha256(canonical));
    const prepared = Object.freeze({ registrationSHA256 }) as unknown as PreparedModerationOperatorWebAuthnRegistration;
    preparedRegistrationInternals.set(prepared, {
      response: validated.response, expectedOrigin: scope.origin, expectedRPID: scope.rpID,
      challenge: challenge.value, format, counter, publicKeyCose, registrationSHA256,
      credentialIdSHA256: bytesToHex(await sha256(validated.credentialIdBytes)),
      publicKeyCoseSHA256: bytesToHex(await sha256(publicKeyCose)),
      authenticatorAAGUIDSHA256: bytesToHex(await sha256(auth.subarray(37, 53))),
    });
    return prepared;
  } catch {
    fail();
  }
}

/**
 * Consumes the opaque prepared object before invoking registration verification.
 * Re-preparing the same response is possible: durable replay/expiry, Access
 * identity, role and approval checks must precede any future admission.
 */
export async function verifyPreparedModerationOperatorWebAuthnRegistration(
  prepared: PreparedModerationOperatorWebAuthnRegistration,
): Promise<UnadmittedModerationOperatorWebAuthnRegistration> {
  try {
    if (prepared === null || typeof prepared !== "object") fail();
    const internal = preparedRegistrationInternals.get(prepared);
    if (internal === undefined) fail();
    preparedRegistrationInternals.delete(prepared);
    const result = await verifyRegistrationResponse({
      response: internal.response,
      expectedChallenge: internal.challenge,
      expectedOrigin: internal.expectedOrigin,
      expectedRPID: internal.expectedRPID,
      expectedType: "webauthn.create",
      supportedAlgorithmIDs: [-7],
      requireUserPresence: true,
      requireUserVerification: true,
    });
    if (!result.verified) fail();
    const info = result.registrationInfo;
    if (info.credential.id !== internal.response.id || info.origin !== internal.expectedOrigin
        || info.rpID !== internal.expectedRPID || info.fmt !== internal.format
        || info.credentialType !== "public-key" || info.userVerified !== true
        || info.credentialDeviceType !== "singleDevice" || info.credentialBackedUp !== false
        || info.authenticatorExtensionResults !== undefined
        || info.credential.counter !== internal.counter
        || !constantTimeEqual(info.credential.publicKey, internal.publicKeyCose)) fail();
    return Object.freeze({
      kind: "unadmitted-operator-registration",
      registrationSHA256: internal.registrationSHA256,
      credential: Object.freeze({
        credentialIdSHA256: internal.credentialIdSHA256,
        publicKeyCose: new Uint8Array(internal.publicKeyCose),
        counter: internal.counter,
      }),
      publicKeyCoseSHA256: internal.publicKeyCoseSHA256,
      authenticatorAAGUIDSHA256: internal.authenticatorAAGUIDSHA256,
      attestationPolicy: MODERATION_OPERATOR_REGISTRATION_POLICY,
      attestationFormat: internal.format,
      selfAttestationSignatureVerified: internal.format === "packed",
      hardwareProvenanceVerified: false,
      realHumanVerified: false,
      enrollmentAdmissionAuthorized: false,
    });
  } catch {
    fail();
  }
}
