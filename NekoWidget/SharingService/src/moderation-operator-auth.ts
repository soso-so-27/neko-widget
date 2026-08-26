import { base64urlDecode, base64urlEncode } from "./encoding";
import { encodeCanonicalFields } from "./protocol";

const accessHeaderName = "cf-access-jwt-assertion";
const maximumAccessJWTBytes = 16 * 1024;
const maximumJwksBytes = 64 * 1024;
const maximumJwksKeys = 8;
const maximumJwksCacheEntries = 4;
const maximumJwksCacheSeconds = 300;
const maximumFetchTimeoutMilliseconds = 5_000;
const unknownKidRefreshCooldownSeconds = 30;
const defaultClockSkewSeconds = 30;
const defaultMaximumTokenAgeSeconds = 900;
const defaultFetchTimeoutMilliseconds = 3_000;
const defaultJwksCacheSeconds = 300;

const encoder = new TextEncoder();
const fatalDecoder = new TextDecoder("utf-8", { fatal: true });
const lowercaseHexSHA256Pattern = /^[0-9a-f]{64}$/u;
const cloudflareAudiencePattern = /^[0-9a-f]{64}$/u;
const cloudflareIssuerPattern =
  /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/u;
const cloudflareSubjectPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const keyIdPattern = /^[0-9a-f]{64}$/u;

type FetchImplementation = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

interface ReviewedRSAJwk {
  kid: string;
  kty: "RSA";
  alg: "RS256";
  use: "sig";
  n: string;
  e: string;
  modulusBytes: number;
}

interface CachedJwks {
  expiresAt: number;
  keys: ReadonlyMap<string, ReviewedRSAJwk>;
  unknownKidRefreshNotBefore: number;
}

type JwksLoader = () => Promise<ReadonlyMap<string, ReviewedRSAJwk>>;

export class ModerationOperatorAuthError extends Error {
  constructor(readonly code: string) {
    super("Cloudflare Access authentication failed.");
  }
}

function fail(code: string): never {
  throw new ModerationOperatorAuthError(code);
}

function arrayBufferCopy(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

function exactKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const allowed = new Set([...required, ...optional]);
  const actual = Object.keys(value);
  if (required.some((key) => !Object.hasOwn(value, key))
      || actual.some((key) => !allowed.has(key))) {
    fail("invalid_fields");
  }
}

function record(value: unknown): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    fail("invalid_json");
  }
  return value as Record<string, unknown>;
}

function strictString(value: unknown, maximumLength: number): string {
  if (typeof value !== "string" || value.length === 0
      || value.length > maximumLength || value.trim() !== value) {
    fail("invalid_claim");
  }
  return value;
}

function safeInteger(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) fail("invalid_claim");
  return value as number;
}

function decodeCanonicalBase64url(
  value: string,
  maximumBytes: number,
  expectedBytes?: number,
): Uint8Array {
  if (value.length === 0 || value.length > Math.ceil(maximumBytes * 4 / 3) + 2) {
    fail("invalid_base64url");
  }
  let bytes: Uint8Array;
  try {
    bytes = base64urlDecode(value, expectedBytes);
  } catch {
    fail("invalid_base64url");
  }
  if (bytes.length > maximumBytes || base64urlEncode(bytes) !== value) {
    fail("invalid_base64url");
  }
  return bytes;
}

/** Reject duplicate JSON keys at every depth before JSON.parse normalizes them. */
function inspectJsonSyntax(text: string): void {
  type Container = { type: "array" } | {
    type: "object";
    expectKey: boolean;
    keys: Set<string>;
  };
  const stack: Container[] = [];
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (character === undefined) fail("invalid_json");
    if (/\s/u.test(character)) {
      continue;
    }
    if (character === '"') {
      const start = index;
      let escaped = false;
      for (index += 1; index < text.length; index += 1) {
        const next = text[index];
        if (next === undefined) fail("invalid_json");
        if (escaped) {
          escaped = false;
          continue;
        }
        if (next === "\\") {
          escaped = true;
          continue;
        }
        if (next === '"') break;
      }
      if (index >= text.length) fail("invalid_json");
      const container = stack.at(-1);
      if (container?.type === "object" && container.expectKey) {
        let key: unknown;
        try {
          key = JSON.parse(text.slice(start, index + 1));
        } catch {
          fail("invalid_json");
        }
        if (typeof key !== "string" || container.keys.has(key)) {
          fail("duplicate_json_key");
        }
        container.keys.add(key);
        container.expectKey = false;
      }
      continue;
    }
    if (character === "{") {
      stack.push({ type: "object", expectKey: true, keys: new Set() });
      continue;
    }
    if (character === "[") {
      stack.push({ type: "array" });
      continue;
    }
    if (character === "}" || character === "]") {
      const container = stack.pop();
      if (container === undefined
          || (character === "}" && container.type !== "object")
          || (character === "]" && container.type !== "array")) {
        fail("invalid_json");
      }
      continue;
    }
    if (character === ",") {
      const container = stack.at(-1);
      if (container?.type === "object") container.expectKey = true;
    }
  }
  if (stack.length !== 0) fail("invalid_json");
}

function parseJsonObject(bytes: Uint8Array): Record<string, unknown> {
  let text: string;
  try {
    text = fatalDecoder.decode(bytes);
  } catch {
    fail("invalid_json");
  }
  inspectJsonSyntax(text);
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    fail("invalid_json");
  }
  const object = record(parsed);
  return object;
}

function hexadecimal(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return hexadecimal(new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    arrayBufferCopy(bytes),
  )));
}

export class ModerationAccessJwksCache {
  readonly #entries = new Map<string, CachedJwks>();
  readonly #inFlight = new Map<
    string,
    Promise<ReadonlyMap<string, ReviewedRSAJwk>>
  >();

  get(url: string, now: number): ReadonlyMap<string, ReviewedRSAJwk> | null {
    const entry = this.#entries.get(url);
    if (entry === undefined) return null;
    if (entry.expiresAt <= now) {
      this.#entries.delete(url);
      return null;
    }
    return entry.keys;
  }

  set(
    url: string,
    keys: ReadonlyMap<string, ReviewedRSAJwk>,
    expiresAt: number,
    unknownKidRefreshNotBefore = 0,
  ): void {
    this.#entries.delete(url);
    while (this.#entries.size >= maximumJwksCacheEntries) {
      const oldest = this.#entries.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.#entries.delete(oldest);
    }
    this.#entries.set(url, { expiresAt, keys, unknownKidRefreshNotBefore });
  }

  async getOrFetch(
    url: string,
    now: number,
    cacheSeconds: number,
    loader: JwksLoader,
  ): Promise<ReadonlyMap<string, ReviewedRSAJwk>> {
    const cached = this.get(url, now);
    if (cached !== null) return cached;
    return this.#loadSingleFlight(url, now, cacheSeconds, 0, loader);
  }

  async refreshForUnknownKid(
    url: string,
    now: number,
    cacheSeconds: number,
    loader: JwksLoader,
  ): Promise<ReadonlyMap<string, ReviewedRSAJwk>> {
    const running = this.#inFlight.get(url);
    if (running !== undefined) return running;
    const entry = this.#entries.get(url);
    if (entry === undefined || entry.expiresAt <= now) {
      return this.getOrFetch(url, now, cacheSeconds, loader);
    }
    if (entry.unknownKidRefreshNotBefore > now) return entry.keys;
    const refreshNotBefore = now + unknownKidRefreshCooldownSeconds;
    // Set the cooldown before starting I/O so failed and concurrent attacker-
    // selected kid values cannot turn into an unbounded JWKS fetch oracle.
    entry.unknownKidRefreshNotBefore = refreshNotBefore;
    return this.#loadSingleFlight(
      url,
      now,
      cacheSeconds,
      refreshNotBefore,
      loader,
    );
  }

  async #loadSingleFlight(
    url: string,
    now: number,
    cacheSeconds: number,
    unknownKidRefreshNotBefore: number,
    loader: JwksLoader,
  ): Promise<ReadonlyMap<string, ReviewedRSAJwk>> {
    const running = this.#inFlight.get(url);
    if (running !== undefined) return running;
    const load = (async () => {
      const keys = await loader();
      this.set(
        url,
        keys,
        now + cacheSeconds,
        unknownKidRefreshNotBefore,
      );
      return keys;
    })();
    this.#inFlight.set(url, load);
    try {
      return await load;
    } finally {
      if (this.#inFlight.get(url) === load) this.#inFlight.delete(url);
    }
  }

  clear(): void {
    this.#entries.clear();
    this.#inFlight.clear();
  }
}

const defaultJwksCache = new ModerationAccessJwksCache();

async function readBoundedResponse(response: Response): Promise<Uint8Array> {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximumJwksBytes) {
      fail("jwks_too_large");
    }
  }
  if (response.body === null) fail("jwks_unavailable");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      length += result.value.length;
      if (length > maximumJwksBytes) {
        await reader.cancel();
        fail("jwks_too_large");
      }
      chunks.push(result.value);
    }
  } catch (error) {
    if (error instanceof ModerationOperatorAuthError) throw error;
    fail("jwks_unavailable");
  }
  if (length < 1) fail("jwks_unavailable");
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.length;
  }
  return output;
}

function exactJwk(value: unknown): ReviewedRSAJwk {
  const jwk = record(value);
  exactKeys(jwk, ["kid", "kty", "alg", "use", "n", "e"]);
  const kid = strictString(jwk.kid, 64);
  if (!keyIdPattern.test(kid) || jwk.kty !== "RSA"
      || jwk.alg !== "RS256" || jwk.use !== "sig") {
    fail("invalid_jwk");
  }
  const modulus = decodeCanonicalBase64url(strictString(jwk.n, 1_024), 512);
  const exponent = decodeCanonicalBase64url(strictString(jwk.e, 16), 8);
  if (modulus.length < 256 || modulus.length > 512
      || exponent.length < 1 || exponent.length > 8
      || (modulus.at(-1) ?? 0) % 2 === 0 || (exponent.at(-1) ?? 0) % 2 === 0) {
    fail("invalid_jwk");
  }
  return {
    kid,
    kty: "RSA",
    alg: "RS256",
    use: "sig",
    n: strictString(jwk.n, 1_024),
    e: strictString(jwk.e, 16),
    modulusBytes: modulus.length,
  };
}

function pemCertificate(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 16 * 1024) {
    fail("invalid_jwks");
  }
  // Cloudflare's live certs endpoint terminates PEM values with exactly one LF.
  // Accept that conventional terminator, while continuing to reject CRLF,
  // multiple terminal newlines, spaces and non-PEM wrappers.
  const certificate = value.endsWith("\n") ? value.slice(0, -1) : value;
  if (certificate.length === 0 || certificate.trim() !== certificate
      || certificate.includes("\r") || value.endsWith("\n\n")
      || !certificate.startsWith("-----BEGIN CERTIFICATE-----\n")
      || !certificate.endsWith("\n-----END CERTIFICATE-----")) {
    fail("invalid_jwks");
  }
  return value;
}

function validateCertificateIndex(
  value: unknown,
  knownKids: ReadonlySet<string>,
): void {
  const certificate = record(value);
  exactKeys(certificate, ["kid", "cert"]);
  const kid = strictString(certificate.kid, 64);
  const cert = pemCertificate(certificate.cert);
  if (!keyIdPattern.test(kid) || !knownKids.has(kid)
      || !cert.startsWith("-----BEGIN CERTIFICATE-----")
      || !cert.includes("-----END CERTIFICATE-----")) {
    fail("invalid_jwks");
  }
}

function parseJwks(bytes: Uint8Array): ReadonlyMap<string, ReviewedRSAJwk> {
  const jwks = parseJsonObject(bytes);
  exactKeys(jwks, ["keys"], ["public_cert", "public_certs"]);
  if (!Array.isArray(jwks.keys) || jwks.keys.length < 1
      || jwks.keys.length > maximumJwksKeys) {
    fail("invalid_jwks");
  }
  const keys = new Map<string, ReviewedRSAJwk>();
  for (const value of jwks.keys) {
    const key = exactJwk(value);
    if (keys.has(key.kid)) fail("duplicate_jwk_kid");
    keys.set(key.kid, key);
  }
  const knownKids = new Set(keys.keys());
  if (jwks.public_cert !== undefined) {
    validateCertificateIndex(jwks.public_cert, knownKids);
  }
  if (jwks.public_certs !== undefined) {
    if (!Array.isArray(jwks.public_certs)
        || jwks.public_certs.length > maximumJwksKeys) {
      fail("invalid_jwks");
    }
    const seen = new Set<string>();
    for (const value of jwks.public_certs) {
      validateCertificateIndex(value, knownKids);
      const kid = (value as Record<string, unknown>).kid as string;
      if (seen.has(kid)) fail("duplicate_jwk_kid");
      seen.add(kid);
    }
  }
  return keys;
}

async function fetchJwks(
  url: string,
  fetchImpl: FetchImplementation,
  timeoutMilliseconds: number,
): Promise<ReadonlyMap<string, ReviewedRSAJwk>> {
  const controller = new AbortController();
  let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timeoutHandle = setTimeout(() => {
      controller.abort();
      reject(new ModerationOperatorAuthError("jwks_timeout"));
    }, timeoutMilliseconds);
  });
  try {
    const response = await Promise.race([
      (async () => {
        const fetched = await fetchImpl(url, {
          method: "GET",
          headers: { Accept: "application/json" },
          redirect: "error",
          signal: controller.signal,
        });
        if (!fetched.ok) fail("jwks_unavailable");
        const contentType = fetched.headers.get("content-type") ?? "";
        if (!/^application\/json(?:\s*;|$)/iu.test(contentType)) {
          fail("invalid_jwks");
        }
        return parseJwks(await readBoundedResponse(fetched));
      })(),
      timeout,
    ]);
    return response;
  } catch (error) {
    if (error instanceof ModerationOperatorAuthError) throw error;
    return fail("jwks_unavailable");
  } finally {
    if (timeoutHandle !== undefined) clearTimeout(timeoutHandle);
  }
}

export interface CloudflareAccessAuthenticationOptions {
  issuer: string;
  audience: string;
  subjectHmacKey: Uint8Array | CryptoKey;
  subjectHmacKeyVersion: number;
  now?: number;
  clockSkewSeconds?: number;
  maximumTokenAgeSeconds?: number;
  fetchTimeoutMilliseconds?: number;
  jwksCacheSeconds?: number;
  fetchImpl?: FetchImplementation;
  cache?: ModerationAccessJwksCache;
}

export interface AuthenticatedModerationOperatorAccess {
  operatorSubjectHmac: string;
  subjectHmacKeyVersion: number;
  accessSessionSHA256: string;
  keyId: string;
  issuedAt: number;
  expiresAt: number;
}

interface ValidatedOptions {
  issuer: string;
  audience: string;
  jwksUrl: string;
  subjectHmacKey: Uint8Array | CryptoKey;
  subjectHmacKeyVersion: number;
  now: number;
  clockSkewSeconds: number;
  maximumTokenAgeSeconds: number;
  fetchTimeoutMilliseconds: number;
  jwksCacheSeconds: number;
  fetchImpl: FetchImplementation;
  cache: ModerationAccessJwksCache;
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  maximum: number,
): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved < 1 || resolved > maximum) {
    fail("invalid_configuration");
  }
  return resolved;
}

function validateOptions(options: CloudflareAccessAuthenticationOptions): ValidatedOptions {
  const keys = Object.keys(options);
  const allowed = new Set([
    "issuer",
    "audience",
    "subjectHmacKey",
    "subjectHmacKeyVersion",
    "now",
    "clockSkewSeconds",
    "maximumTokenAgeSeconds",
    "fetchTimeoutMilliseconds",
    "jwksCacheSeconds",
    "fetchImpl",
    "cache",
  ]);
  if (keys.some((key) => !allowed.has(key))) fail("invalid_configuration");
  if (!cloudflareIssuerPattern.test(options.issuer)
      || !cloudflareAudiencePattern.test(options.audience)) {
    fail("invalid_configuration");
  }
  if (options.subjectHmacKey instanceof Uint8Array) {
    if (options.subjectHmacKey.length !== 32) fail("invalid_configuration");
  } else {
    if (!(options.subjectHmacKey instanceof CryptoKey)) fail("invalid_configuration");
    const algorithm = options.subjectHmacKey.algorithm as KeyAlgorithm & {
      hash?: KeyAlgorithm;
    };
    if (options.subjectHmacKey.type !== "secret"
        || algorithm.name !== "HMAC"
        || algorithm.hash?.name !== "SHA-256"
        || !options.subjectHmacKey.usages.includes("sign")) {
      fail("invalid_configuration");
    }
  }
  if (!Number.isSafeInteger(options.subjectHmacKeyVersion)
      || options.subjectHmacKeyVersion < 1
      || options.subjectHmacKeyVersion > 0x7fff_ffff) {
    fail("invalid_configuration");
  }
  const now = options.now ?? Math.floor(Date.now() / 1_000);
  if (!Number.isSafeInteger(now) || now < 1) fail("invalid_configuration");
  return {
    issuer: options.issuer,
    audience: options.audience,
    jwksUrl: `${options.issuer}/cdn-cgi/access/certs`,
    subjectHmacKey: options.subjectHmacKey,
    subjectHmacKeyVersion: options.subjectHmacKeyVersion,
    now,
    clockSkewSeconds: boundedInteger(
      options.clockSkewSeconds,
      defaultClockSkewSeconds,
      60,
    ),
    maximumTokenAgeSeconds: boundedInteger(
      options.maximumTokenAgeSeconds,
      defaultMaximumTokenAgeSeconds,
      defaultMaximumTokenAgeSeconds,
    ),
    fetchTimeoutMilliseconds: boundedInteger(
      options.fetchTimeoutMilliseconds,
      defaultFetchTimeoutMilliseconds,
      maximumFetchTimeoutMilliseconds,
    ),
    jwksCacheSeconds: boundedInteger(
      options.jwksCacheSeconds,
      defaultJwksCacheSeconds,
      maximumJwksCacheSeconds,
    ),
    fetchImpl: options.fetchImpl ?? fetch,
    cache: options.cache ?? defaultJwksCache,
  };
}

interface JwtHeader {
  alg: "RS256";
  kid: string;
  typ: "JWT";
}

function parseJwtHeader(segment: string): JwtHeader {
  const bytes = decodeCanonicalBase64url(segment, 1_024);
  const header = parseJsonObject(bytes);
  exactKeys(header, ["alg", "kid", "typ"]);
  if (header.alg !== "RS256" || header.typ !== "JWT") fail("invalid_jwt_header");
  const kid = strictString(header.kid, 64);
  if (!keyIdPattern.test(kid)) fail("invalid_jwt_header");
  return { alg: "RS256", kid, typ: "JWT" };
}

interface JwtClaims {
  aud: readonly string[];
  exp: number;
  iat: number;
  nbf: number;
  iss: string;
  sub: string;
  type: "app";
}

function parseJwtClaims(segment: string, options: ValidatedOptions): JwtClaims {
  const bytes = decodeCanonicalBase64url(segment, 12 * 1024);
  const claims = parseJsonObject(bytes);
  exactKeys(
    claims,
    ["aud", "exp", "iat", "nbf", "iss", "sub", "type"],
    ["email", "identity_nonce", "country", "device_id"],
  );
  // This deliberately rejects Access custom claims. The future isolated
  // operator deployment must prove that its Access application has custom
  // claims disabled and a policy session no longer than 900 seconds; the
  // account-wide 24-hour default is not suitable for this control plane.
  if (!Array.isArray(claims.aud) || claims.aud.length !== 1
      || claims.aud[0] !== options.audience) {
    fail("invalid_audience");
  }
  const issuer = strictString(claims.iss, 256);
  const subject = strictString(claims.sub, 128);
  if (issuer !== options.issuer || claims.type !== "app"
      || !cloudflareSubjectPattern.test(subject)) {
    fail("invalid_claim");
  }
  if (claims.email !== undefined) strictString(claims.email, 320);
  if (claims.identity_nonce !== undefined) strictString(claims.identity_nonce, 512);
  if (claims.country !== undefined
      && !/^[A-Z]{2}$/u.test(strictString(claims.country, 2))) {
    fail("invalid_claim");
  }
  if (claims.device_id !== undefined
      && !cloudflareSubjectPattern.test(strictString(claims.device_id, 128))) {
    fail("invalid_claim");
  }
  const exp = safeInteger(claims.exp);
  const iat = safeInteger(claims.iat);
  const nbf = safeInteger(claims.nbf);
  if (iat > options.now + options.clockSkewSeconds
      || nbf > options.now + options.clockSkewSeconds
      || options.now - options.clockSkewSeconds >= exp
      || nbf > iat
      || exp <= iat
      || exp - iat > options.maximumTokenAgeSeconds
      || options.now - iat > options.maximumTokenAgeSeconds + options.clockSkewSeconds) {
    fail("invalid_token_time");
  }
  return {
    aud: [options.audience],
    exp,
    iat,
    nbf,
    iss: issuer,
    sub: subject,
    type: "app",
  };
}

async function importVerificationKey(key: ReviewedRSAJwk): Promise<CryptoKey> {
  try {
    return await crypto.subtle.importKey(
      "jwk",
      {
        kty: key.kty,
        alg: key.alg,
        use: key.use,
        n: key.n,
        e: key.e,
        ext: true,
        key_ops: ["verify"],
      },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
  } catch {
    fail("invalid_jwk");
  }
}

async function subjectHmac(
  keyValue: Uint8Array | CryptoKey,
  keyVersion: number,
  issuer: string,
  subject: string,
): Promise<string> {
  let key: CryptoKey;
  if (keyValue instanceof Uint8Array) {
    key = await crypto.subtle.importKey(
      "raw",
      arrayBufferCopy(keyValue),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
  } else {
    key = keyValue;
  }
  const message = encodeCanonicalFields([
    "NW.MODERATION-OPERATOR.SUBJECT-HMAC",
    "2",
    String(keyVersion),
    issuer,
    subject,
  ]);
  return hexadecimal(new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    arrayBufferCopy(message),
  )));
}

export async function verifyCloudflareAccessJWT(
  tokenValue: string,
  unvalidatedOptions: CloudflareAccessAuthenticationOptions,
): Promise<AuthenticatedModerationOperatorAccess> {
  const options = validateOptions(unvalidatedOptions);
  if (typeof tokenValue !== "string" || tokenValue.length < 1
      || tokenValue.length > maximumAccessJWTBytes || tokenValue.trim() !== tokenValue) {
    fail("invalid_jwt");
  }
  const segments = tokenValue.split(".");
  if (segments.length !== 3) fail("invalid_jwt");
  const headerSegment = segments[0];
  const payloadSegment = segments[1];
  const signatureSegment = segments[2];
  if (headerSegment === undefined || payloadSegment === undefined
      || signatureSegment === undefined) {
    fail("invalid_jwt");
  }
  const header = parseJwtHeader(headerSegment);
  const claims = parseJwtClaims(payloadSegment, options);
  const loader = async () => fetchJwks(
    options.jwksUrl,
    options.fetchImpl,
    options.fetchTimeoutMilliseconds,
  );
  let keys = options.cache.get(options.jwksUrl, options.now);
  let loadedFromNetwork = false;
  if (keys === null) {
    loadedFromNetwork = true;
    keys = await options.cache.getOrFetch(
      options.jwksUrl,
      options.now,
      options.jwksCacheSeconds,
      loader,
    );
  }
  let reviewedKey = keys.get(header.kid);
  if (reviewedKey === undefined && !loadedFromNetwork) {
    keys = await options.cache.refreshForUnknownKid(
      options.jwksUrl,
      options.now,
      options.jwksCacheSeconds,
      loader,
    );
    reviewedKey = keys.get(header.kid);
  }
  if (reviewedKey === undefined) fail("unknown_jwt_key");
  const signature = decodeCanonicalBase64url(
    signatureSegment,
    reviewedKey.modulusBytes,
    reviewedKey.modulusBytes,
  );
  const signingInput = encoder.encode(`${headerSegment}.${payloadSegment}`);
  let valid: boolean;
  try {
    valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      await importVerificationKey(reviewedKey),
      arrayBufferCopy(signature),
      arrayBufferCopy(signingInput),
    );
  } catch {
    fail("invalid_jwt_signature");
  }
  if (!valid) fail("invalid_jwt_signature");
  const tokenBytes = encoder.encode(tokenValue);
  const result = {
    operatorSubjectHmac: await subjectHmac(
      options.subjectHmacKey,
      options.subjectHmacKeyVersion,
      claims.iss,
      claims.sub,
    ),
    subjectHmacKeyVersion: options.subjectHmacKeyVersion,
    accessSessionSHA256: await sha256Hex(tokenBytes),
    keyId: header.kid,
    issuedAt: claims.iat,
    expiresAt: claims.exp,
  };
  if (!lowercaseHexSHA256Pattern.test(result.operatorSubjectHmac)
      || !lowercaseHexSHA256Pattern.test(result.accessSessionSHA256)) {
    fail("invalid_identity_digest");
  }
  return result;
}

/** Reads only the signed Access assertion. Email/name convenience headers are ignored. */
export async function authenticateCloudflareAccessRequest(
  request: Request,
  options: CloudflareAccessAuthenticationOptions,
): Promise<AuthenticatedModerationOperatorAccess> {
  const token = request.headers.get(accessHeaderName);
  if (token === null) fail("missing_access_jwt");
  return verifyCloudflareAccessJWT(token, options);
}
