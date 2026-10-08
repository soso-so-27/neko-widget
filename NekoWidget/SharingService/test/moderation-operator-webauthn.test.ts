import { describe, expect, it, vi } from "vitest";

import {
  MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE,
  ModerationOperatorWebAuthnError,
  prepareModerationOperatorWebAuthnAssertion,
  verifyPreparedModerationOperatorWebAuthnAssertion,
  type PrepareModerationOperatorWebAuthnAssertionOptions,
} from "../src/moderation-operator-webauthn";
import {
  MODERATION_OPERATOR_ASSERTION_REQUEST_FAILURE_CODE,
  MODERATION_OPERATOR_ASSERTION_BODY_DEADLINE_MS,
  MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_READS,
  MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES,
  prepareModerationOperatorWebAuthnRequest,
} from "../src/moderation-operator-request";

const encoder = new TextEncoder();
const origin = "https://moderation.operator.example.test";
const rpID = "operator.example.test";

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function concat(...values: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(values.reduce((total, value) => total + value.length, 0));
  let offset = 0;
  for (const value of values) {
    output.set(value, offset);
    offset += value.length;
  }
  return output;
}

async function digest(bytes: Uint8Array): Promise<Uint8Array> {
  const copy = new Uint8Array(bytes);
  return new Uint8Array(await crypto.subtle.digest("SHA-256", copy.buffer));
}

async function digestHex(bytes: Uint8Array): Promise<string> {
  return [...await digest(bytes)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function counterBytes(counter: number): Uint8Array {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, counter, false);
  return bytes;
}

function coseES256(rawPublicKey: Uint8Array): Uint8Array {
  if (rawPublicKey.length !== 65 || rawPublicKey[0] !== 4) throw new Error("bad test key");
  const x = rawPublicKey.slice(1, 33);
  const y = rawPublicKey.slice(33, 65);
  return concat(
    new Uint8Array([
      0xa5, // map(5)
      0x01, 0x02, // 1: 2 (EC2)
      0x03, 0x26, // 3: -7 (ES256)
      0x20, 0x01, // -1: 1 (P-256)
      0x21, 0x58, 0x20, // -2: bytes(32)
    ]),
    x,
    new Uint8Array([0x22, 0x58, 0x20]), // -3: bytes(32)
    y,
  );
}

function derInteger(component: Uint8Array): Uint8Array {
  let first = 0;
  while (first < component.length - 1 && component[first] === 0) first += 1;
  const value = component.slice(first);
  const positive = (value[0]! & 0x80) === 0
    ? value : concat(new Uint8Array([0]), value);
  return concat(new Uint8Array([0x02, positive.length]), positive);
}

function rawES256ToDER(raw: Uint8Array): Uint8Array {
  if (raw.length !== 64) throw new Error("unexpected Workers ECDSA signature format");
  const r = derInteger(raw.slice(0, 32));
  const s = derInteger(raw.slice(32));
  return concat(new Uint8Array([0x30, r.length + s.length]), r, s);
}

type AssertionJSON = {
  id: string;
  rawId: string;
  response: {
    clientDataJSON: string;
    authenticatorData: string;
    signature: string;
    userHandle?: null | string;
    unexpected?: string;
  };
  authenticatorAttachment?: string;
  clientExtensionResults: Record<string, unknown>;
  type: string;
  unexpected?: string;
};

interface Fixture {
  options: PrepareModerationOperatorWebAuthnAssertionOptions;
  response: AssertionJSON;
  credentialId: Uint8Array;
  challenge: Uint8Array;
  publicKeyCose: Uint8Array;
}

async function fixture(): Promise<Fixture> {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const rawPublicKey = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));
  const publicKeyCose = coseES256(rawPublicKey);
  const credentialId = Uint8Array.from({ length: 32 }, (_value, index) => index + 1);
  const challenge = Uint8Array.from({ length: 32 }, (_value, index) => 0xa0 + index);
  const clientDataBytes = encoder.encode(JSON.stringify({
    type: "webauthn.get",
    challenge: base64url(challenge),
    origin,
    crossOrigin: false,
  }));
  const authenticatorData = concat(
    await digest(encoder.encode(rpID)),
    new Uint8Array([0x05]), // UP | UV, single-device and no extensions
    counterBytes(1),
  );
  const signatureBase = concat(authenticatorData, await digest(clientDataBytes));
  const signatureInput = new Uint8Array(signatureBase);
  const rawSignature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    keyPair.privateKey,
    signatureInput.buffer,
  ));
  const response: AssertionJSON = {
    id: base64url(credentialId),
    rawId: base64url(credentialId),
    response: {
      clientDataJSON: base64url(clientDataBytes),
      authenticatorData: base64url(authenticatorData),
      signature: base64url(rawES256ToDER(rawSignature)),
    },
    authenticatorAttachment: "platform",
    clientExtensionResults: {},
    type: "public-key",
  };
  return {
    response,
    credentialId,
    challenge,
    publicKeyCose,
    options: {
      response,
      expectedOrigin: origin,
      expectedRPID: rpID,
      expectedChallengeSHA256: await digestHex(challenge),
      credential: {
        credentialIdSHA256: await digestHex(credentialId),
        publicKeyCose,
        counter: 0,
      },
    },
  };
}

function cloneResponse(value: AssertionJSON): AssertionJSON {
  return structuredClone(value);
}

async function fixedFailure(promise: Promise<unknown>): Promise<void> {
  await expect(promise).rejects.toEqual(expect.objectContaining({
    name: "ModerationOperatorWebAuthnError",
    message: MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE,
    code: MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE,
  }));
}

describe("strict moderation operator WebAuthn verification", () => {
  it("verifies a real Workers WebCrypto ES256 assertion and returns only audit-safe fields", async () => {
    const test = await fixture();
    const prepared = await prepareModerationOperatorWebAuthnAssertion(test.options);
    // A route must persist its one-shot attempt between these two calls.
    const result = await verifyPreparedModerationOperatorWebAuthnAssertion(prepared);

    expect(result).toEqual({
      assertionSHA256: expect.stringMatching(/^[0-9a-f]{64}$/u),
      newCounter: 1,
    });
    expect(Object.keys(result)).toEqual(["assertionSHA256", "newCounter"]);
    expect(Object.isFrozen(result)).toBe(true);
  });

  it("exposes only a deterministic digest during preflight and consumes it once", async () => {
    const test = await fixture();
    const prepared = await prepareModerationOperatorWebAuthnAssertion(test.options);
    expect(Object.keys(prepared)).toEqual(["assertionSHA256"]);
    expect(Object.isFrozen(prepared)).toBe(true);
    const first = await verifyPreparedModerationOperatorWebAuthnAssertion(prepared);
    expect(first.assertionSHA256).toBe(prepared.assertionSHA256);
    await fixedFailure(verifyPreparedModerationOperatorWebAuthnAssertion(prepared));

    const forged = { assertionSHA256: prepared.assertionSHA256 } as unknown as
      Parameters<typeof verifyPreparedModerationOperatorWebAuthnAssertion>[0];
    await fixedFailure(verifyPreparedModerationOperatorWebAuthnAssertion(forged));
  });

  it("hashes an explicitly ordered canonical assertion independent of input key order", async () => {
    const test = await fixture();
    const reordered: AssertionJSON = {
      type: test.response.type,
      clientExtensionResults: {},
      response: {
        signature: test.response.response.signature,
        authenticatorData: test.response.response.authenticatorData,
        clientDataJSON: test.response.response.clientDataJSON,
      },
      rawId: test.response.rawId,
      id: test.response.id,
      ...(test.response.authenticatorAttachment === undefined
        ? {} : { authenticatorAttachment: test.response.authenticatorAttachment }),
    };
    const left = await prepareModerationOperatorWebAuthnAssertion(test.options);
    const right = await prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      response: reordered,
    });
    expect(right.assertionSHA256).toBe(left.assertionSHA256);
  });

  it("uses fixed, non-secret errors", () => {
    const error = new ModerationOperatorWebAuthnError();
    expect(error.message).toBe(MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE);
    expect(error.code).toBe(MODERATION_OPERATOR_WEBAUTHN_FAILURE_CODE);
  });

  it("rejects unknown, missing, inherited, accessor, and nested response fields", async () => {
    const test = await fixture();
    const unknown = cloneResponse(test.response);
    unknown.unexpected = "value";
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: unknown }));

    const nested = cloneResponse(test.response);
    nested.response.unexpected = "value";
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: nested }));

    const missing = cloneResponse(test.response) as Partial<AssertionJSON>;
    delete missing.clientExtensionResults;
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: missing }));

    const inherited = Object.create({ id: test.response.id }) as Record<string, unknown>;
    Object.assign(inherited, test.response);
    delete inherited.id;
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: inherited }));

    const accessor = cloneResponse(test.response) as unknown as Record<string, unknown>;
    Object.defineProperty(accessor, "id", { enumerable: true, get: () => test.response.id });
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: accessor }));

    const hidden = cloneResponse(test.response) as unknown as Record<string, unknown>;
    Object.defineProperty(hidden, "hidden", { enumerable: false, value: "value" });
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: hidden }));

    const symbolKey = cloneResponse(test.response) as unknown as Record<PropertyKey, unknown>;
    symbolKey[Symbol("unexpected")] = "value";
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: symbolKey }));

    const unknownOption = { ...test.options, unexpected: "value" } as unknown as
      PrepareModerationOperatorWebAuthnAssertionOptions;
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion(unknownOption));

    const unknownCredential = {
      ...test.options,
      credential: { ...test.options.credential, unexpected: "value" },
    } as unknown as PrepareModerationOperatorWebAuthnAssertionOptions;
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion(unknownCredential));
  });

  it("rejects non-canonical or mismatched credential identifiers and digest", async () => {
    const test = await fixture();
    const padded = cloneResponse(test.response);
    padded.id += "=";
    padded.rawId = padded.id;
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: padded }));

    const mismatch = cloneResponse(test.response);
    mismatch.rawId = base64url(new Uint8Array([1, 2, 3]));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: mismatch }));

    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      credential: { ...test.options.credential, credentialIdSHA256: "0".repeat(64) },
    }));
  });

  it("rejects the wrong credential type, user handle, attachment, and client extensions", async () => {
    const test = await fixture();
    for (const mutate of [
      (value: AssertionJSON) => { value.type = "password"; },
      (value: AssertionJSON) => { value.response.userHandle = ""; },
      (value: AssertionJSON) => { value.authenticatorAttachment = "remote"; },
      (value: AssertionJSON) => { value.clientExtensionResults = { appid: true }; },
    ]) {
      const response = cloneResponse(test.response);
      mutate(response);
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response }));
    }
  });

  it("accepts an explicitly null userHandle but includes its presence in the audit digest", async () => {
    const test = await fixture();
    const withNull = cloneResponse(test.response);
    withNull.response.userHandle = null;
    const absent = await prepareModerationOperatorWebAuthnAssertion(test.options);
    const present = await prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      response: withNull,
    });
    expect(present.assertionSHA256).not.toBe(absent.assertionSHA256);
    await expect(verifyPreparedModerationOperatorWebAuthnAssertion(present)).resolves.toEqual({
      assertionSHA256: present.assertionSHA256,
      newCounter: 1,
    });
  });

  it("rejects malformed UTF-8, duplicate and unknown ClientDataJSON keys", async () => {
    const test = await fixture();
    for (const bytes of [
      new Uint8Array([0xc3, 0x28]),
      encoder.encode(`{"type":"webauthn.get","type":"webauthn.get","challenge":"${base64url(test.challenge)}","origin":"${origin}"}`),
      encoder.encode(`{"type":"webauthn.get","challenge":"${base64url(test.challenge)}","origin":"${origin}","topOrigin":"https://evil.test"}`),
    ]) {
      const response = cloneResponse(test.response);
      response.response.clientDataJSON = base64url(bytes);
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response }));
    }
  });

  it("rejects wrong client type, origin, cross-origin state, and challenge digest", async () => {
    const test = await fixture();
    const cases = [
      { type: "webauthn.create", challenge: base64url(test.challenge), origin },
      { type: "webauthn.get", challenge: base64url(test.challenge), origin: "https://evil.test" },
      { type: "webauthn.get", challenge: base64url(test.challenge), origin, crossOrigin: true },
      { type: "webauthn.get", challenge: `${base64url(test.challenge)}=`, origin },
      { type: "webauthn.get", challenge: base64url(new Uint8Array(32)), origin },
    ];
    for (const clientData of cases) {
      const response = cloneResponse(test.response);
      response.response.clientDataJSON = base64url(encoder.encode(JSON.stringify(clientData)));
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response }));
    }
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      expectedChallengeSHA256: "0".repeat(64),
    }));
  });

  it("rejects non-canonical expected origin and RP ID scope", async () => {
    const test = await fixture();
    for (const overrides of [
      { expectedOrigin: `${origin}/` },
      { expectedOrigin: "http://moderation.operator.example.test" },
      { expectedOrigin: "https://evil.test" },
      { expectedRPID: "example.invalid" },
      { expectedRPID: "OPERATOR.EXAMPLE.TEST" },
    ]) {
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
        ...test.options,
        ...overrides,
      }));
    }
  });

  it("rejects RP hash, UP/UV, backup, attested-credential, extension and reserved flags", async () => {
    const test = await fixture();
    const original = (() => {
      const value = test.response.response.authenticatorData;
      const padding = "=".repeat((4 - value.length % 4) % 4);
      const binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
      return Uint8Array.from(binary, (character) => character.charCodeAt(0));
    })();
    const mutations = [
      (bytes: Uint8Array) => { bytes[0] = bytes[0]! ^ 1; },
      (bytes: Uint8Array) => { bytes[32] = 0x04; }, // no UP
      (bytes: Uint8Array) => { bytes[32] = 0x01; }, // no UV
      (bytes: Uint8Array) => { bytes[32] = 0x0d; }, // backup eligibility
      (bytes: Uint8Array) => { bytes[32] = 0x45; }, // AT
      (bytes: Uint8Array) => { bytes[32] = 0x85; }, // ED
      (bytes: Uint8Array) => { bytes[32] = 0x07; }, // reserved flag
    ];
    for (const mutate of mutations) {
      const bytes = new Uint8Array(original);
      mutate(bytes);
      const response = cloneResponse(test.response);
      response.response.authenticatorData = base64url(bytes);
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response }));
    }
  });

  it("bounds authenticator data, signature, COSE key, and counters", async () => {
    const test = await fixture();
    const shortAuth = cloneResponse(test.response);
    shortAuth.response.authenticatorData = base64url(new Uint8Array(36));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: shortAuth }));

    const longAuth = cloneResponse(test.response);
    longAuth.response.authenticatorData = base64url(new Uint8Array(1_025));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: longAuth }));

    const shortSignature = cloneResponse(test.response);
    shortSignature.response.signature = base64url(new Uint8Array(7));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: shortSignature }));

    const longSignature = cloneResponse(test.response);
    longSignature.response.signature = base64url(new Uint8Array(73));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({ ...test.options, response: longSignature }));

    const longCredentialID = cloneResponse(test.response);
    longCredentialID.id = base64url(new Uint8Array(1_025));
    longCredentialID.rawId = longCredentialID.id;
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      response: longCredentialID,
    }));

    const longClientData = cloneResponse(test.response);
    longClientData.response.clientDataJSON = base64url(new Uint8Array(4_097));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      response: longClientData,
    }));

    for (const publicKeyCose of [new Uint8Array(31), new Uint8Array(2_049)]) {
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
        ...test.options,
        credential: { ...test.options.credential, publicKeyCose },
      }));
    }

    for (const counter of [-1, 0x1_0000_0000, 1.5]) {
      await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
        ...test.options,
        credential: { ...test.options.credential, counter },
      }));
    }
  });

  it("strictly requires an exact ES256/P-256 COSE key without duplicate or extra keys", async () => {
    const test = await fixture();
    const wrongAlgorithm = new Uint8Array(test.publicKeyCose);
    wrongAlgorithm[4] = 0x27; // -8, not ES256 (-7)
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      credential: { ...test.options.credential, publicKeyCose: wrongAlgorithm },
    }));

    const extraEntry = concat(new Uint8Array([0xa6]), test.publicKeyCose.slice(1), new Uint8Array([0x04, 0x01]));
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      credential: { ...test.options.credential, publicKeyCose: extraEntry },
    }));

    const duplicateAlgorithm = concat(
      new Uint8Array([0xa6]),
      test.publicKeyCose.slice(1),
      new Uint8Array([0x03, 0x26]),
    );
    await fixedFailure(prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      credential: { ...test.options.credential, publicKeyCose: duplicateAlgorithm },
    }));
  });

  it("collapses invalid signatures and counter replay into the same fixed failure", async () => {
    const test = await fixture();
    const invalidSignature = cloneResponse(test.response);
    const signature = new Uint8Array(70);
    signature.set([0x30, 0x44, 0x02, 0x20], 0);
    invalidSignature.response.signature = base64url(signature);
    const invalidPrepared = await prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      response: invalidSignature,
    });
    await fixedFailure(verifyPreparedModerationOperatorWebAuthnAssertion(invalidPrepared));

    const replayPrepared = await prepareModerationOperatorWebAuthnAssertion({
      ...test.options,
      credential: { ...test.options.credential, counter: 1 },
    });
    await fixedFailure(verifyPreparedModerationOperatorWebAuthnAssertion(replayPrepared));
  });
});

describe("moderation operator assertion HTTP boundary", () => {
  function request(body: string | ReadableStream<Uint8Array>, headers: Record<string, string> = {}): Request {
    return new Request(`${origin}/operator/v1/assertions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body,
    });
  }

  function trustedOptions(test: Fixture): Omit<PrepareModerationOperatorWebAuthnAssertionOptions, "response"> {
    const { response: _response, ...options } = test.options;
    return options;
  }

  async function requestFailure(promise: Promise<unknown>): Promise<void> {
    await expect(promise).rejects.toEqual(expect.objectContaining({
      name: "ModerationOperatorAssertionRequestError",
      message: MODERATION_OPERATOR_ASSERTION_REQUEST_FAILURE_CODE,
      code: MODERATION_OPERATOR_ASSERTION_REQUEST_FAILURE_CODE,
    }));
  }

  it("prepares a real signed HTTP assertion and leaves signature verification separate", async () => {
    const test = await fixture();
    const body = JSON.stringify(test.response);
    const prepared = await prepareModerationOperatorWebAuthnRequest(request(body, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": String(encoder.encode(body).byteLength),
    }), trustedOptions(test));
    const direct = await prepareModerationOperatorWebAuthnAssertion(test.options);
    expect(prepared).toEqual(direct);
    expect(Object.keys(prepared)).toEqual(["assertionSHA256"]);
    expect(Object.isFrozen(prepared)).toBe(true);
    expect(await verifyPreparedModerationOperatorWebAuthnAssertion(prepared)).toEqual({
      assertionSHA256: prepared.assertionSHA256,
      newCounter: 1,
    });

    const invalid = cloneResponse(test.response);
    invalid.response.signature = base64url(new Uint8Array(64).fill(9));
    const unverified = await prepareModerationOperatorWebAuthnRequest(
      request(JSON.stringify(invalid)), trustedOptions(test),
    );
    await fixedFailure(verifyPreparedModerationOperatorWebAuthnAssertion(unverified));
  });

  it("rejects same-value and escaped duplicate keys before JSON can discard them", async () => {
    const test = await fixture();
    const body = JSON.stringify(test.response);
    const nested = '"signature":' + JSON.stringify(test.response.response.signature);
    for (const duplicate of [
      body.replace('"type":"public-key"', '"type":"public-key","type":"public-key"'),
      body.replace('"type":"public-key"', '"ty\\u0070e":"public-key","type":"public-key"'),
      body.replace(nested, `${nested},${nested}`),
      body.replace(nested, `${nested},"signat\\u0075re":${JSON.stringify(test.response.response.signature)}`),
      body.replace('"clientExtensionResults":{}', '"clientExtensionResults":{},"clientExtensionResults":{}'),
    ]) {
      // Each would pass the existing object preflight after lossy JSON.parse.
      await expect(prepareModerationOperatorWebAuthnAssertion({
        ...test.options, response: JSON.parse(duplicate),
      })).resolves.toEqual(expect.objectContaining({ assertionSHA256: expect.any(String) }));
      await requestFailure(prepareModerationOperatorWebAuthnRequest(
        request(duplicate), trustedOptions(test),
      ));
    }
  });

  it("rejects wrong shape, unknown fields, malformed JSON and excessive nesting", async () => {
    const test = await fixture();
    for (const body of [
      "null", "[]", "{}", "true", "", " ", "{", "{}{}",
      JSON.stringify({ ...test.response, expectedOrigin: origin }),
      JSON.stringify({ assertion: test.response }),
      JSON.stringify({ ...test.response, clientExtensionResults: { value: "sensitive-body" } }),
      '{"response":[[[[[{"x":1,"x":2}]]]]]}',
      JSON.stringify(test.response).replace('"type":"public-key"', '"type":"public-key",'),
    ]) {
      await requestFailure(prepareModerationOperatorWebAuthnRequest(
        request(body), trustedOptions(test),
      ));
    }
  });

  it("rejects unsupported media, encoding and invalid lengths before reading the body", async () => {
    const test = await fixture();
    for (const headers of [
      { "Content-Type": "text/plain" },
      { "Content-Type": "application/json; charset=iso-8859-1" },
      { "Content-Type": "application/json; arbitrary=secret" },
      { "Content-Encoding": "gzip" },
      { "Content-Encoding": "identity" },
      ...["-1", "1.0", "01", "1, 1", "9007199254740993", "16385"].map(
        (length) => ({ "Content-Length": length }),
      ),
    ]) {
      let bodyRead = false;
      const original = request(JSON.stringify(test.response), headers);
      const guarded = new Proxy(original, {
        get(target, property) {
          if (property === "body") { bodyRead = true; throw new Error("sensitive-body"); }
          return Reflect.get(target, property, target);
        },
      });
      await requestFailure(prepareModerationOperatorWebAuthnRequest(guarded, trustedOptions(test)));
      expect(bodyRead).toBe(false);
    }
  });

  it("accepts the exact byte limit and refuses a mismatched declared length", async () => {
    const test = await fixture();
    const body = JSON.stringify(test.response);
    const atLimit = body.padEnd(MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES, " ");
    await expect(prepareModerationOperatorWebAuthnRequest(request(atLimit), trustedOptions(test)))
      .resolves.toEqual(expect.objectContaining({ assertionSHA256: expect.any(String) }));
    for (const length of ["0", String(body.length - 1), String(body.length + 1)]) {
      await requestFailure(prepareModerationOperatorWebAuthnRequest(request(body, {
        "Content-Length": length,
      }), trustedOptions(test)));
    }
  });

  it("limits actual streamed bytes with no length header and cancels before preflight", async () => {
    const test = await fixture();
    let cancelled = false;
    let prepared = false;
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode("あ".repeat(6_000)));
      },
      cancel() { cancelled = true; throw new Error("sensitive-cancel-error"); },
    });
    const options = new Proxy(trustedOptions(test), {
      ownKeys() { prepared = true; throw new Error("preflight must not run"); },
    });
    await requestFailure(prepareModerationOperatorWebAuthnRequest(request(body), options));
    expect(cancelled).toBe(true);
    expect(prepared).toBe(false);
    expect(body.locked).toBe(false);
  });

  it("counts every chunk and rejects one byte beyond the allowed total", async () => {
    const test = await fixture();
    let cancelled = false;
    const first = encoder.encode(JSON.stringify(test.response).padEnd(
      MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES, " ",
    ));
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(first);
        controller.enqueue(new Uint8Array([32]));
      },
      cancel() { cancelled = true; },
    });
    await requestFailure(prepareModerationOperatorWebAuthnRequest(request(body), trustedOptions(test)));
    expect(cancelled).toBe(true);
    expect(body.locked).toBe(false);
  });

  it("rejects invalid UTF-8, a BOM, truncated input and stream failure without leaking details", async () => {
    const test = await fixture();
    const valid = encoder.encode(JSON.stringify(test.response));
    for (const chunks of [
      [new Uint8Array([0xef, 0xbb, 0xbf]), valid],
      [new Uint8Array([0xe3]), new Uint8Array([0x28, 0xa1])],
      [new Uint8Array([0xe3, 0x81])],
      [valid.slice(0, valid.length - 1)],
    ]) {
      const body = new ReadableStream<Uint8Array>({
        start(controller) { for (const chunk of chunks) controller.enqueue(chunk); controller.close(); },
      });
      await requestFailure(prepareModerationOperatorWebAuthnRequest(request(body), trustedOptions(test)));
      expect(body.locked).toBe(false);
    }
    const failed = new ReadableStream<Uint8Array>({
      start(controller) { controller.error(new Error("sensitive-stream-error")); },
    });
    await requestFailure(prepareModerationOperatorWebAuthnRequest(request(failed), trustedOptions(test)));
    expect(failed.locked).toBe(false);
  });

  it("processes an assertion divided across chunks without changing its audit digest", async () => {
    const test = await fixture();
    const bytes = encoder.encode(JSON.stringify(test.response));
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let index = 0; index < bytes.length; index += 7) controller.enqueue(bytes.slice(index, index + 7));
        controller.close();
      },
    });
    const streamed = await prepareModerationOperatorWebAuthnRequest(request(body), trustedOptions(test));
    const direct = await prepareModerationOperatorWebAuthnAssertion(test.options);
    expect(streamed.assertionSHA256).toBe(direct.assertionSHA256);
    expect(body.locked).toBe(false);
  });

  it("uses one absolute deadline even with partial progress and a never-settling cancel hook", async () => {
    const test = await fixture();
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(value) { controller = value; value.enqueue(encoder.encode("{")); },
      cancel() { cancelled = true; return new Promise<void>(() => {}); },
    });
    vi.useFakeTimers();
    try {
      let settled = false;
      const pending = prepareModerationOperatorWebAuthnRequest(request(body), trustedOptions(test));
      const rejection = requestFailure(pending).then(() => { settled = true; });
      await vi.advanceTimersByTimeAsync(MODERATION_OPERATOR_ASSERTION_BODY_DEADLINE_MS - 1_000);
      expect(settled).toBe(false);
      controller!.enqueue(encoder.encode('"id":'));
      await vi.advanceTimersByTimeAsync(1_000);
      await rejection;
      expect(settled).toBe(true);
      expect(cancelled).toBe(true);
      expect(body.locked).toBe(false);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects endless empty chunks without depending on timers receiving a turn", async () => {
    const test = await fixture();
    let reads = 0;
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) { reads += 1; controller.enqueue(new Uint8Array()); },
      cancel() { cancelled = true; },
    });
    await requestFailure(prepareModerationOperatorWebAuthnRequest(request(body), trustedOptions(test)));
    expect(reads).toBeLessThanOrEqual(MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_READS + 1);
    expect(cancelled).toBe(true);
    expect(body.locked).toBe(false);
  });

  it("does not wait for cancellation after detecting an oversized body", async () => {
    const test = await fixture();
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(MODERATION_OPERATOR_MAXIMUM_ASSERTION_BODY_BYTES + 1));
      },
      cancel() { cancelled = true; return new Promise<void>(() => {}); },
    });
    await requestFailure(prepareModerationOperatorWebAuthnRequest(request(body), trustedOptions(test)));
    expect(cancelled).toBe(true);
    expect(body.locked).toBe(false);
  });
});
