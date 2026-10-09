import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import type { RegistrationResponseJSON } from "@simplewebauthn/server";
import {
  MODERATION_OPERATOR_REGISTRATION_POLICY,
  MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE,
  prepareModerationOperatorWebAuthnRegistration as prepare,
  verifyPreparedModerationOperatorWebAuthnRegistration as verify,
  prepareModerationOperatorWebAuthnAssertion,
  verifyPreparedModerationOperatorWebAuthnAssertion,
  type PrepareModerationOperatorWebAuthnRegistrationOptions,
  type PreparedModerationOperatorWebAuthnRegistration,
  type UnadmittedModerationOperatorWebAuthnRegistration,
} from "../src/moderation-operator-webauthn";

const encoder = new TextEncoder();
const origin = "https://moderation.operator.example.test";
const rpID = "operator.example.test";
type CBORValue = Parameters<typeof isoCBOR.encode>[0];

function b64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function concat(...values: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(values.reduce((size, value) => size + value.length, 0));
  let offset = 0;
  for (const value of values) { result.set(value, offset); offset += value.length; }
  return result;
}

async function hash(bytes: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer));
}

async function digest(bytes: Uint8Array): Promise<string> {
  return [...await hash(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function u32(value: number): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(4);
  new DataView(result.buffer).setUint32(0, value, false);
  return result;
}

function der(raw: Uint8Array): Uint8Array<ArrayBuffer> {
  expect(raw.length).toBe(64);
  function integer(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start += 1;
    const value = bytes.slice(start);
    const positive = (value[0]! & 0x80) ? concat(new Uint8Array([0]), value) : value;
    return concat(new Uint8Array([2, positive.length]), positive);
  }
  const r = integer(raw.slice(0, 32)); const s = integer(raw.slice(32));
  return concat(new Uint8Array([0x30, r.length + s.length]), r, s);
}

type FixtureOverrides = {
  format?: string;
  flags?: number;
  counter?: number;
  credentialLength?: number;
  attestedID?: Uint8Array;
  client?: (challenge: string) => Uint8Array;
  rpID?: string;
  key?: Uint8Array;
  badSignature?: boolean;
  outer?: "extra" | "duplicate" | "trailing";
  statement?: Map<string, CBORValue>;
};

async function fixture(overrides: FixtureOverrides = {}) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" },
    true, ["sign", "verify"]) as CryptoKeyPair;
  const rawKey = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const publicKeyCose = isoCBOR.encode(new Map<number, CBORValue>([
    [1, 2], [3, -7], [-1, 1], [-2, rawKey.slice(1, 33)], [-3, rawKey.slice(33)],
  ]));
  const credentialID = crypto.getRandomValues(new Uint8Array(overrides.credentialLength ?? 32));
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const format = overrides.format ?? "packed";
  const client = overrides.client?.(b64(challenge)) ?? encoder.encode(JSON.stringify({
    type: "webauthn.create", challenge: b64(challenge), origin, crossOrigin: false,
  }));
  const attestedID = overrides.attestedID ?? credentialID;
  const length = new Uint8Array(2); new DataView(length.buffer).setUint16(0, attestedID.length, false);
  const auth = concat(await hash(encoder.encode(overrides.rpID ?? rpID)),
    new Uint8Array([overrides.flags ?? 0x45]), u32(overrides.counter ?? 7),
    new Uint8Array(16), length, attestedID, overrides.key ?? publicKeyCose);
  async function sign(bytes: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
    return der(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" },
      pair.privateKey, new Uint8Array(bytes).buffer)));
  }
  const signature = await sign(concat(auth, await hash(client)));
  if (overrides.badSignature) signature[signature.length - 1] = signature[signature.length - 1]! ^ 1;
  const statement = overrides.statement ?? (format === "none" ? new Map<string, CBORValue>()
    : new Map<string, CBORValue>([["alg", -7], ["sig", signature]]));
  const outer = new Map<string, CBORValue>([["fmt", format], ["authData", auth], ["attStmt", statement]]);
  if (overrides.outer === "extra") outer.set("unreviewed", 1);
  let attestation = isoCBOR.encode(outer);
  if (overrides.outer === "trailing") attestation = concat(attestation, new Uint8Array([0]));
  if (overrides.outer === "duplicate") {
    attestation[0] = 0xa4;
    attestation = concat(attestation, isoCBOR.encode("fmt"), isoCBOR.encode(format));
  }
  const response: RegistrationResponseJSON = {
    id: b64(credentialID), rawId: b64(credentialID), type: "public-key",
    clientExtensionResults: {}, authenticatorAttachment: "cross-platform",
    response: { clientDataJSON: b64(client), attestationObject: b64(attestation), transports: ["usb"] },
  };
  const options: PrepareModerationOperatorWebAuthnRegistrationOptions = {
    response, expectedOrigin: origin, expectedRPID: rpID, expectedChallengeSHA256: await digest(challenge),
  };
  async function assertion(receipt: UnadmittedModerationOperatorWebAuthnRegistration, counter: number) {
    const fresh = crypto.getRandomValues(new Uint8Array(32));
    const clientData = encoder.encode(JSON.stringify({ type: "webauthn.get", challenge: b64(fresh), origin }));
    const authData = concat(await hash(encoder.encode(rpID)), new Uint8Array([0x05]), u32(counter));
    const prepared = await prepareModerationOperatorWebAuthnAssertion({
      expectedOrigin: origin, expectedRPID: rpID, expectedChallengeSHA256: await digest(fresh),
      // Pure compatibility check only, not a claim that this credential was admitted.
      credential: receipt.credential,
      response: { id: b64(credentialID), rawId: b64(credentialID), type: "public-key", clientExtensionResults: {},
        response: { clientDataJSON: b64(clientData), authenticatorData: b64(authData),
          signature: b64(await sign(concat(authData, await hash(clientData)))) } },
    });
    return verifyPreparedModerationOperatorWebAuthnAssertion(prepared);
  }
  return { options, response, credentialID, publicKeyCose, assertion };
}

async function failure(promise: Promise<unknown>): Promise<void> {
  await expect(promise).rejects.toEqual(expect.objectContaining({
    name: "ModerationOperatorWebAuthnError", code: MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE,
    message: MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE,
  }));
}

describe("unadmitted operator registration cryptographic boundary", () => {
  beforeEach(() => { vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network is forbidden")); });
  afterEach(() => { expect(fetch).not.toHaveBeenCalled(); vi.restoreAllMocks(); });

  it.each(["none", "packed"])("verifies %s and uses its ES256 key through the existing assertion contract", async (format) => {
    const test = await fixture({ format });
    const prepared = await prepare(test.options);
    expect(Object.isFrozen(prepared)).toBe(true);
    expect(Object.keys(prepared)).toEqual(["registrationSHA256"]);
    const receipt = await verify(prepared);
    expect(receipt).toEqual({
      kind: "unadmitted-operator-registration", registrationSHA256: prepared.registrationSHA256,
      credential: { credentialIdSHA256: await digest(test.credentialID), publicKeyCose: test.publicKeyCose, counter: 7 },
      publicKeyCoseSHA256: await digest(test.publicKeyCose),
      authenticatorAAGUIDSHA256: await digest(new Uint8Array(16)),
      attestationPolicy: MODERATION_OPERATOR_REGISTRATION_POLICY, attestationFormat: format,
      selfAttestationSignatureVerified: format === "packed", hardwareProvenanceVerified: false,
      realHumanVerified: false, enrollmentAdmissionAuthorized: false,
    });
    expect(Object.isFrozen(receipt)).toBe(true);
    expect(Object.isFrozen(receipt.credential)).toBe(true);
    expect(receipt.credential.publicKeyCose.buffer).not.toBe(test.publicKeyCose.buffer);
    expect((await test.assertion(receipt, 8)).newCounter).toBe(8);
    await failure(test.assertion(receipt, 7));
  });

  it("preserves zero-counter assertion behavior and the maximum registration uint32", async () => {
    const test = await fixture({ counter: 0 });
    const receipt = await verify(await prepare(test.options));
    expect((await test.assertion(receipt, 0)).newCounter).toBe(0);
    const maximum = await fixture({ counter: 0xffff_ffff });
    expect((await verify(await prepare(maximum.options))).credential.counter).toBe(0xffff_ffff);
  });

  it("copies all input before awaiting and never admits or exposes the browser response", async () => {
    const test = await fixture();
    const pending = prepare(test.options);
    test.response.id = "changed"; test.response.rawId = "changed";
    test.response.response.attestationObject = "changed";
    test.response.response.clientDataJSON = "changed";
    test.response.response.transports!.push("internal");
    test.response.clientExtensionResults = { credProps: { rk: true } };
    test.options.expectedOrigin = "https://changed.test";
    test.options.expectedRPID = "changed.test";
    test.options.expectedChallengeSHA256 = "0".repeat(64);
    const receipt = await verify(await pending);
    expect(receipt.credential.credentialIdSHA256).toBe(await digest(test.credentialID));
    expect(receipt.enrollmentAdmissionAuthorized).toBe(false);
    expect(receipt).not.toHaveProperty("response");
    expect(receipt).not.toHaveProperty("id");
  });

  it("consumes once before verification and rejects forged or concurrently reused objects", async () => {
    const test = await fixture();
    const prepared = await prepare(test.options);
    await failure(verify({ ...prepared } as PreparedModerationOperatorWebAuthnRegistration));
    const outcomes = await Promise.allSettled([verify(prepared), verify(prepared)]);
    expect(outcomes.map((outcome) => outcome.status).sort()).toEqual(["fulfilled", "rejected"]);
    await failure(verify(prepared));
    await failure(verify(null as unknown as PreparedModerationOperatorWebAuthnRegistration));
    // Isolate capability use is not durable challenge consumption.
    await expect(verify(await prepare(test.options))).resolves.toHaveProperty("enrollmentAdmissionAuthorized", false);
  });

  it("consumes a failed packed signature attempt and emits only the fixed failure", async () => {
    const test = await fixture({ badSignature: true });
    const prepared = await prepare(test.options);
    await failure(verify(prepared));
    await failure(verify(prepared));
  });

  it.each([0x41, 0x44, 0x4d, 0x55, 0x47, 0x65, 0xc5, 0x05])(
    "rejects missing UP/UV/AT, backup, reserved or extension flags 0x%s", async (flags) => {
      await failure(prepare((await fixture({ flags })).options));
    },
  );

  it("binds exact trusted scope, 32-byte challenge digest and authenticator RP hash", async () => {
    const test = await fixture();
    for (const values of [
      { expectedOrigin: `${origin}/` }, { expectedOrigin: "http://moderation.operator.example.test" },
      { expectedOrigin: "https://other.operator.example.test" }, { expectedRPID: "other.test" },
      { expectedRPID: "OPERATOR.EXAMPLE.TEST" }, { expectedChallengeSHA256: "0".repeat(64) },
      { expectedChallengeSHA256: "A".repeat(64) },
    ]) await failure(prepare({ ...test.options, ...values }));
    await failure(prepare((await fixture({ rpID: "other.test" })).options));
  });

  it("rejects malformed UTF8, duplicate/unknown client keys, wrong ceremony and cross-origin data", async () => {
    for (const client of [
      () => new Uint8Array([0xc3, 0x28]),
      (challenge: string) => encoder.encode(`{"type":"webauthn.create","type":"webauthn.create","challenge":"${challenge}","origin":"${origin}"}`),
      (challenge: string) => encoder.encode(JSON.stringify({ type: "webauthn.get", challenge, origin })),
      (challenge: string) => encoder.encode(JSON.stringify({ type: "webauthn.create", challenge, origin, crossOrigin: true })),
      (challenge: string) => encoder.encode(JSON.stringify({ type: "webauthn.create", challenge, origin, topOrigin: origin })),
      (challenge: string) => encoder.encode(JSON.stringify({ type: "webauthn.create", challenge: `${challenge}=`, origin })),
      () => encoder.encode(JSON.stringify({ type: "webauthn.create", challenge: b64(new Uint8Array(31)), origin })),
    ]) await failure(prepare((await fixture({ client })).options));
  });

  it("rejects malformed response projection, extensions, browser key hints and unknown input fields", async () => {
    const test = await fixture();
    for (const response of [
      { ...test.response, rawId: b64(new Uint8Array([1])) },
      { ...test.response, id: `${test.response.id}=`, rawId: `${test.response.id}=` },
      { ...test.response, type: "other" }, { ...test.response, unexpected: true },
      { ...test.response, clientExtensionResults: { credProps: { rk: false } } },
      { ...test.response, authenticatorAttachment: "unreviewed" },
      { ...test.response, response: { ...test.response.response, publicKey: b64(test.publicKeyCose) } },
      { ...test.response, response: { ...test.response.response, publicKeyAlgorithm: -7 } },
      { ...test.response, response: { ...test.response.response, authenticatorData: "hint" } },
      { ...test.response, response: { ...test.response.response, transports: ["usb", "usb"] } },
      { ...test.response, response: { ...test.response.response, transports: ["unreviewed"] } },
      { ...test.response, response: { ...test.response.response, transports: Array(8).fill("usb") } },
    ]) await failure(prepare({ ...test.options, response }));
    await failure(prepare({ ...test.options, unknown: true } as PrepareModerationOperatorWebAuthnRegistrationOptions));
    let read = false;
    const accessor = { ...test.response };
    Object.defineProperty(accessor, "id", { enumerable: true, get() { read = true; return test.response.id; } });
    await failure(prepare({ ...test.options, response: accessor }));
    expect(read).toBe(false);
  });

  it("accepts optional fields absent and the maximum ID, and bounds each supplied byte string", async () => {
    const maximum = await fixture({ credentialLength: 1024 });
    delete maximum.response.authenticatorAttachment;
    delete maximum.response.response.transports;
    await expect(verify(await prepare(maximum.options))).resolves.toHaveProperty("enrollmentAdmissionAuthorized", false);
    await failure(prepare((await fixture({ credentialLength: 1025 })).options));
    const test = await fixture();
    for (const [name, length] of [["clientDataJSON", 4097], ["attestationObject", 8193]] as const) {
      await failure(prepare({ ...test.options, response: {
        ...test.response, response: { ...test.response.response, [name]: b64(new Uint8Array(length)) },
      } }));
    }
    for (const id of ["", "A", "AA=", "AA+", "AA/"]) {
      await failure(prepare({ ...test.options, response: { ...test.response, id, rawId: id } }));
    }
  });

  it.each(["extra", "duplicate", "trailing"] as const)("rejects %s outer CBOR content", async (outer) => {
    await failure(prepare((await fixture({ outer })).options));
  });

  it("requires the attested credential ID to equal both response IDs", async () => {
    await failure(prepare((await fixture({ attestedID: new Uint8Array([1, 2, 3]) })).options));
  });

  it("rejects off-curve points for unsigned none, non-ES256, extra and trailing COSE entries", async () => {
    const offCurve = isoCBOR.encode(new Map<number, CBORValue>([
      [1, 2], [3, -7], [-1, 1], [-2, new Uint8Array(32)], [-3, new Uint8Array(32)],
    ]));
    await failure(prepare((await fixture({ format: "none", key: offCurve })).options));
    const test = await fixture();
    const wrongAlgorithm = new Uint8Array(test.publicKeyCose); wrongAlgorithm[4] = 0x27;
    const extra = concat(new Uint8Array([0xa6]), test.publicKeyCose.slice(1), new Uint8Array([4, 1]));
    const duplicate = concat(new Uint8Array([0xa6]), test.publicKeyCose.slice(1), new Uint8Array([3, 0x26]));
    for (const key of [wrongAlgorithm, extra, duplicate, concat(test.publicKeyCose, new Uint8Array([0])),
      new Uint8Array(31), new Uint8Array(2049)]) {
      await failure(prepare((await fixture({ key })).options));
    }
  });

  it("rejects certificate attestation, other formats and nonempty none statements", async () => {
    for (const overrides of [
      { format: "android-key" },
      { statement: new Map<string, CBORValue>([["alg", -7], ["sig", new Uint8Array(64)], ["x5c", []]]) },
      { statement: new Map<string, CBORValue>([["alg", -8], ["sig", new Uint8Array(64)]]) },
      { statement: new Map<string, CBORValue>([["alg", -7], ["sig", new Uint8Array(73)]]) },
      { format: "none", statement: new Map<string, CBORValue>([["sig", new Uint8Array(64)]]) },
    ]) await failure(prepare((await fixture(overrides)).options));
  });
});
