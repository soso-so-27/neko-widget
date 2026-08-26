import { describe, expect, it, vi } from "vitest";

import { base64urlEncode } from "../src/encoding";
import {
  authenticateCloudflareAccessRequest,
  ModerationAccessJwksCache,
  ModerationOperatorAuthError,
  verifyCloudflareAccessJWT,
  type CloudflareAccessAuthenticationOptions,
} from "../src/moderation-operator-auth";
import {
  moderationOperatorStepUpChallengeTranscript,
  ModerationOperatorProtocolError,
  type ModerationOperatorStepUpChallengeFields,
} from "../src/moderation-operator-protocol";

const encoder = new TextEncoder();
const issuer = "https://neko-operator.cloudflareaccess.com";
const audience = "b".repeat(64);
const kid = "a".repeat(64);
const previousKid = "9".repeat(64);
const now = 1_787_700_000;
const subject = "7335d417-61da-459d-899c-0a01c76a2f94";
const hmacKey = Uint8Array.from({ length: 32 }, (_value, index) => index + 1);
const cloudflarePem = `-----BEGIN CERTIFICATE-----\n${"A".repeat(64)}\n-----END CERTIFICATE-----\n`;

interface TestKeys {
  privateKey: CryptoKey;
  publicJwk: JsonWebKey;
}

let keyPromise: Promise<TestKeys> | undefined;

async function testKeys(): Promise<TestKeys> {
  keyPromise ??= (async () => {
    const pair = await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    ) as CryptoKeyPair;
    return {
      privateKey: pair.privateKey,
      publicJwk: await crypto.subtle.exportKey("jwk", pair.publicKey),
    };
  })();
  return keyPromise;
}

async function signedToken({
  header = { alg: "RS256", kid, typ: "JWT" },
  payload = {
    aud: [audience],
    email: "operator@example.invalid",
    exp: now + 600,
    iat: now,
    nbf: now,
    iss: issuer,
    type: "app",
    identity_nonce: "opaque-identity-nonce",
    sub: subject,
    device_id: "8469d7c4-83a9-11ee-b559-76e6e80876db",
    country: "JP",
  },
  headerText,
  payloadText,
  headerBytes,
}: {
  header?: Record<string, unknown>;
  payload?: Record<string, unknown>;
  headerText?: string;
  payloadText?: string;
  headerBytes?: Uint8Array;
} = {}): Promise<string> {
  const headerSegment = base64urlEncode(
    headerBytes ?? encoder.encode(headerText ?? JSON.stringify(header)),
  );
  const payloadSegment = base64urlEncode(encoder.encode(payloadText ?? JSON.stringify(payload)));
  const signingInput = encoder.encode(`${headerSegment}.${payloadSegment}`);
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    (await testKeys()).privateKey,
    signingInput,
  ));
  return `${headerSegment}.${payloadSegment}.${base64urlEncode(signature)}`;
}

async function signingJwk(keyId: string): Promise<Record<string, unknown>> {
  const publicJwk = (await testKeys()).publicJwk;
  return {
    kid: keyId,
    kty: "RSA",
    alg: "RS256",
    use: "sig",
    e: publicJwk.e,
    n: publicJwk.n,
  };
}

async function jwksBody(overrides: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  return {
    keys: [await signingJwk(kid), await signingJwk(previousKid)],
    public_cert: { kid, cert: cloudflarePem },
    public_certs: [
      { kid, cert: cloudflarePem },
      { kid: previousKid, cert: cloudflarePem },
    ],
    ...overrides,
  };
}

function jsonResponse(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    headers: { "Content-Type": "application/json" },
  });
}

async function options(
  overrides: Partial<CloudflareAccessAuthenticationOptions> = {},
): Promise<CloudflareAccessAuthenticationOptions> {
  return {
    issuer,
    audience,
    subjectHmacKey: hmacKey,
    subjectHmacKeyVersion: 1,
    now,
    maximumTokenAgeSeconds: 900,
    cache: new ModerationAccessJwksCache(),
    fetchImpl: async () => jsonResponse(await jwksBody()),
    ...overrides,
  };
}

describe("isolated Cloudflare Access operator authentication", () => {
  it("verifies RS256, exact issuer/audience/time and returns only fixed digests", async () => {
    const token = await signedToken();
    const authenticated = await verifyCloudflareAccessJWT(token, await options());
    expect(authenticated).toEqual({
      operatorSubjectHmac: expect.stringMatching(/^[0-9a-f]{64}$/u),
      subjectHmacKeyVersion: 1,
      accessSessionSHA256: expect.stringMatching(/^[0-9a-f]{64}$/u),
      keyId: kid,
      issuedAt: now,
      expiresAt: now + 600,
    });
    expect(JSON.stringify(authenticated)).not.toContain(subject);
    expect(JSON.stringify(authenticated)).not.toContain("operator@example.invalid");
    expect(JSON.stringify(authenticated)).not.toContain("8469d7c4-83a9-11ee-b559-76e6e80876db");

    const second = await verifyCloudflareAccessJWT(token, await options());
    expect(second.operatorSubjectHmac).toBe(authenticated.operatorSubjectHmac);

    const otherSubject = await verifyCloudflareAccessJWT(await signedToken({
      payload: {
        aud: [audience], exp: now + 600, iat: now, nbf: now,
        iss: issuer, type: "app",
        sub: "8335d417-61da-459d-899c-0a01c76a2f94",
      },
    }), await options());
    expect(otherSubject.operatorSubjectHmac).not.toBe(authenticated.operatorSubjectHmac);

    const rotated = await verifyCloudflareAccessJWT(token, await options({
      subjectHmacKeyVersion: 2,
    }));
    expect(rotated.subjectHmacKeyVersion).toBe(2);
    expect(rotated.operatorSubjectHmac).not.toBe(authenticated.operatorSubjectHmac);
  });

  it("reads only Cf-Access-Jwt-Assertion and ignores spoofable email/name headers", async () => {
    const token = await signedToken();
    const request = new Request("https://operator.invalid/operator/v1/cases", {
      headers: {
        "Cf-Access-Jwt-Assertion": token,
        "Cf-Access-Authenticated-User-Email": "attacker@example.invalid",
        "X-Forwarded-User": "forged-name",
      },
    });
    const authenticated = await authenticateCloudflareAccessRequest(request, await options());
    expect(authenticated.operatorSubjectHmac).toMatch(/^[0-9a-f]{64}$/u);
    await expect(authenticateCloudflareAccessRequest(
      new Request("https://operator.invalid/operator/v1/cases", {
        headers: { "Cf-Access-Authenticated-User-Email": "operator@example.invalid" },
      }),
      await options(),
    )).rejects.toMatchObject({ code: "missing_access_jwt" });
  });

  it("verifies signed JSON bytes without requiring a serializer-specific layout", async () => {
    const whitespace = await signedToken({
      headerText: `{ \"alg\":\"RS256\", \"kid\":\"${kid}\", \"typ\":\"JWT\" }`,
    });
    await expect(verifyCloudflareAccessJWT(whitespace, await options()))
      .resolves.toMatchObject({ keyId: kid });
  });

  it("fails closed on alg confusion, unknown fields and noncanonical base64url", async () => {
    const algConfusion = await signedToken({
      header: { alg: "HS256", kid, typ: "JWT" },
    });
    await expect(verifyCloudflareAccessJWT(algConfusion, await options()))
      .rejects.toBeInstanceOf(ModerationOperatorAuthError);

    const unknownHeader = await signedToken({
      header: { alg: "RS256", kid, typ: "JWT", jku: "https://attacker.invalid/jwks" },
    });
    await expect(verifyCloudflareAccessJWT(unknownHeader, await options()))
      .rejects.toMatchObject({ code: "invalid_fields" });

    const invalidUtf8 = await signedToken({
      headerBytes: Uint8Array.of(0xff),
    });
    await expect(verifyCloudflareAccessJWT(invalidUtf8, await options()))
      .rejects.toMatchObject({ code: "invalid_json" });

    const unknownClaim = await signedToken({
      payload: {
        aud: [audience], exp: now + 600, iat: now, nbf: now,
        iss: issuer, type: "app", sub: subject, custom: { groups: ["admin"] },
      },
    });
    await expect(verifyCloudflareAccessJWT(unknownClaim, await options()))
      .rejects.toMatchObject({ code: "invalid_fields" });

    const valid = await signedToken();
    const [header, payload, signature] = valid.split(".");
    if (header === undefined || payload === undefined || signature === undefined) {
      throw new Error("signed test JWT must contain exactly three segments");
    }
    await expect(verifyCloudflareAccessJWT(
      `${header}=.${payload}.${signature}`,
      await options(),
    )).rejects.toMatchObject({ code: "invalid_base64url" });

    const tamperedSignature = `${signature.startsWith("A") ? "B" : "A"}${signature.slice(1)}`;
    await expect(verifyCloudflareAccessJWT(
      `${header}.${payload}.${tamperedSignature}`,
      await options(),
    )).rejects.toMatchObject({ code: "invalid_jwt_signature" });
  });

  it("rejects duplicate claims, wrong issuer/audience, actual service tokens, future and stale tokens", async () => {
    const duplicatePayload = `{"aud":["${audience}"],"exp":${now + 600},`
      + `"iat":${now},"nbf":${now},"iss":"${issuer}","type":"app",`
      + `"sub":"${subject}","sub":"${subject}"}`;
    await expect(verifyCloudflareAccessJWT(
      await signedToken({ payloadText: duplicatePayload }),
      await options(),
    )).rejects.toMatchObject({ code: "duplicate_json_key" });

    const serviceToken = await signedToken({
      payload: {
        type: "app",
        aud: [audience],
        exp: now + 600,
        iss: issuer,
        common_name: "e367826f93b8d71185e03fe518aff3b4.access",
        iat: now,
        sub: "",
      },
    });
    await expect(verifyCloudflareAccessJWT(serviceToken, await options()))
      .rejects.toBeInstanceOf(ModerationOperatorAuthError);

    const base = {
      aud: [audience], exp: now + 600, iat: now, nbf: now,
      iss: issuer, type: "app", sub: subject,
    };
    for (const payload of [
      { ...base, aud: ["c".repeat(64)] },
      { ...base, iss: "https://other.cloudflareaccess.com" },
      { ...base, sub: "" },
      { ...base, iat: now + 61, nbf: now + 61, exp: now + 661 },
      { ...base, iat: now - 1_000, nbf: now - 1_000, exp: now + 1 },
      { ...base, exp: now - 31 },
      // The operator Access app must not retain the account-wide 24h default.
      { ...base, exp: now + 3_600 },
    ]) {
      await expect(verifyCloudflareAccessJWT(
        await signedToken({ payload }),
        await options(),
      )).rejects.toBeInstanceOf(ModerationOperatorAuthError);
    }

    await expect(verifyCloudflareAccessJWT(await signedToken(), await options({
      maximumTokenAgeSeconds: 901,
    }))).rejects.toMatchObject({ code: "invalid_configuration" });
    await expect(verifyCloudflareAccessJWT(await signedToken(), await options({
      subjectHmacKeyVersion: 0,
    }))).rejects.toMatchObject({ code: "invalid_configuration" });
  });

  it("accepts the live Access cert index LF boundary and rejects broader trailing whitespace", async () => {
    await expect(verifyCloudflareAccessJWT(await signedToken(), await options()))
      .resolves.toMatchObject({ keyId: kid });
    await expect(verifyCloudflareAccessJWT(await signedToken(), await options({
      fetchImpl: async () => jsonResponse(await jwksBody({
        public_cert: { kid, cert: `${cloudflarePem}\n` },
      })),
    }))).rejects.toMatchObject({ code: "invalid_jwks" });
    await expect(verifyCloudflareAccessJWT(await signedToken(), await options({
      fetchImpl: async () => jsonResponse(await jwksBody({
        public_cert: { kid, cert: `${cloudflarePem} ` },
      })),
    }))).rejects.toMatchObject({ code: "invalid_jwks" });
  });

  it("requires an exact non-ambiguous signing JWK and rejects duplicate kid", async () => {
    const token = await signedToken();
    const base = (await jwksBody()).keys as Record<string, unknown>[];
    for (const keys of [
      [...base, { ...base[0] }],
      [{ ...base[0], use: "enc" }],
      [{ ...base[0], alg: "PS256" }],
      [{ ...base[0], kty: "EC" }],
      [{ ...base[0], x5u: "https://attacker.invalid/key" }],
    ]) {
      await expect(verifyCloudflareAccessJWT(token, await options({
        fetchImpl: async () => jsonResponse({ keys }),
      }))).rejects.toBeInstanceOf(ModerationOperatorAuthError);
    }
  });

  it("single-flights JWKS fetch and rate-limits one unknown-kid rotation refresh", async () => {
    const rotatedKid = "c".repeat(64);
    let fetchCount = 0;
    const fetchImpl = vi.fn(async () => {
      fetchCount += 1;
      await new Promise((resolve) => setTimeout(resolve, 10));
      if (fetchCount === 1) return jsonResponse(await jwksBody());
      return jsonResponse(await jwksBody({
        keys: [
          await signingJwk(kid),
          await signingJwk(previousKid),
          await signingJwk(rotatedKid),
        ],
      }));
    });
    const cache = new ModerationAccessJwksCache();
    const sharedOptions = await options({ fetchImpl, cache, jwksCacheSeconds: 60 });
    const token = await signedToken();
    await Promise.all(Array.from(
      { length: 8 },
      async () => verifyCloudflareAccessJWT(token, sharedOptions),
    ));
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    const rotatedKidToken = await signedToken({
      header: { alg: "RS256", kid: rotatedKid, typ: "JWT" },
    });
    await Promise.all(Array.from(
      { length: 8 },
      async () => verifyCloudflareAccessJWT(rotatedKidToken, sharedOptions),
    ));
    expect(fetchImpl).toHaveBeenCalledTimes(2);

    const attackerKidToken = await signedToken({
      header: { alg: "RS256", kid: "f".repeat(64), typ: "JWT" },
    });
    for (let index = 0; index < 3; index += 1) {
      await expect(verifyCloudflareAccessJWT(attackerKidToken, sharedOptions))
        .rejects.toMatchObject({ code: "unknown_jwt_key" });
    }
    expect(fetchImpl).toHaveBeenCalledTimes(2);

    const laterOptions = await options({
      fetchImpl,
      cache,
      jwksCacheSeconds: 60,
      now: now + 31,
    });
    const results = await Promise.allSettled(Array.from(
      { length: 8 },
      async () => verifyCloudflareAccessJWT(attackerKidToken, laterOptions),
    ));
    expect(results.every((result) => result.status === "rejected")).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  it("keeps a failed unknown-kid refresh behind the cooldown", async () => {
    let fetchCount = 0;
    const fetchImpl = vi.fn(async () => {
      fetchCount += 1;
      if (fetchCount === 1) return jsonResponse(await jwksBody());
      throw new Error("synthetic JWKS outage");
    });
    const cache = new ModerationAccessJwksCache();
    const sharedOptions = await options({ fetchImpl, cache });
    await verifyCloudflareAccessJWT(await signedToken(), sharedOptions);
    const unknownKidToken = await signedToken({
      header: { alg: "RS256", kid: "e".repeat(64), typ: "JWT" },
    });
    await expect(verifyCloudflareAccessJWT(unknownKidToken, sharedOptions))
      .rejects.toMatchObject({ code: "jwks_unavailable" });
    await expect(verifyCloudflareAccessJWT(unknownKidToken, sharedOptions))
      .rejects.toMatchObject({ code: "unknown_jwt_key" });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("bounds JWKS fetch timeout and response size", async () => {
    const token = await signedToken();

    await expect(verifyCloudflareAccessJWT(token, await options({
      fetchTimeoutMilliseconds: 1,
      fetchImpl: async () => new Promise<Response>(() => undefined),
    }))).rejects.toMatchObject({ code: "jwks_timeout" });

    await expect(verifyCloudflareAccessJWT(token, await options({
      fetchImpl: async () => new Response("x".repeat(65 * 1024), {
        headers: { "Content-Type": "application/json" },
      }),
    }))).rejects.toMatchObject({ code: "jwks_too_large" });
  });
});

describe("moderation operator step-up transcript", () => {
  const fields: ModerationOperatorStepUpChallengeFields = {
    operatorSubjectHmac: "1".repeat(64),
    subjectHmacKeyVersion: 1,
    accessSessionSHA256: "2".repeat(64),
    credentialIdSHA256: "3".repeat(64),
    challengeId: "11111111-1111-4111-8111-111111111111",
    challengeValue: base64urlEncode(Uint8Array.from({ length: 32 }, () => 7)),
    purpose: "request",
    actionType: "content_delete",
    actionId: "22222222-2222-4222-8222-222222222222",
    caseReferenceHmac: "4".repeat(64),
    method: "POST",
    pathname: "/operator/v1/cases/delete",
    bodySHA256: "5".repeat(64),
    issuedAt: now,
    expiresAt: now + 300,
  };

  it("is deterministic and binds identity, session, credential, case, action, request and expiry", () => {
    const first = moderationOperatorStepUpChallengeTranscript(fields);
    const second = moderationOperatorStepUpChallengeTranscript({ ...fields });
    expect([...second]).toEqual([...first]);
    for (const mutation of [
      { bodySHA256: "6".repeat(64) },
      { caseReferenceHmac: "7".repeat(64) },
      { actionId: "33333333-3333-4333-8333-333333333333" },
      { expiresAt: now + 299 },
      { purpose: "approve" as const },
      { subjectHmacKeyVersion: 2 },
    ]) {
      expect([
        ...moderationOperatorStepUpChallengeTranscript({ ...fields, ...mutation }),
      ]).not.toEqual([...first]);
    }
  });

  it("rejects unknown, whitespace, noncanonical and overlong challenge fields", () => {
    const invalid = [
      { ...fields, method: "post" },
      { ...fields, pathname: "/operator/v1/cases/delete?case=1" },
      { ...fields, pathname: `/operator/v1/${"a".repeat(513)}` },
      { ...fields, bodySHA256: ` ${"5".repeat(64)}` },
      { ...fields, subjectHmacKeyVersion: 0 },
      { ...fields, expiresAt: now + 301 },
      { ...fields, challengeValue: `${fields.challengeValue}=` },
      { ...fields, extra: "unknown" },
    ];
    for (const value of invalid) {
      expect(() => moderationOperatorStepUpChallengeTranscript(
        value as ModerationOperatorStepUpChallengeFields,
      )).toThrow(ModerationOperatorProtocolError);
    }
  });
});
