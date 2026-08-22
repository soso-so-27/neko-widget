import { env } from "cloudflare:workers";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import apiFixture from "../../ci/fixtures/sharing-api-v1-responses.json";
import { base64urlEncode, sha256Base64url } from "../src/encoding";
import type { Env } from "../src/env";
import { route } from "../src/index";
import { signedRequestTranscript } from "../src/protocol";
import {
  CLEANUP_DAILY_FREEZE_CHUNK_SIZE,
  CLEANUP_DAILY_FREEZE_LIMIT,
  CLEANUP_FINALIZE_CHUNK_SIZE,
  CLEANUP_GENERATION_CHUNK_SIZE,
  CLEANUP_GENERATION_CLOSE_LIMIT,
  CLEANUP_IDEMPOTENCY_CHUNK_SIZE,
  CLEANUP_IDEMPOTENCY_LIMIT,
  CLEANUP_NONCE_CHUNK_SIZE,
  CLEANUP_NONCE_LIMIT,
  CLEANUP_OBJECT_LIMIT,
  CLEANUP_REVOKED_SCOPE_LIMIT,
  CLEANUP_SOURCE_UNBLOCK_LIMIT,
  CLEANUP_SUBREQUEST_GUARD,
  CLEANUP_TERMINAL_GENERATION_LIMIT,
  OBJECT_DELETE_CAS_TUPLE_LIMIT,
  R2_DELETE_BATCH_SIZE,
  runScheduledCleanup,
} from "../src/scheduled";

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

interface TestMember {
  id: string;
  keys: KeyPair;
}

interface TestSpace {
  id: string;
  owner: TestMember;
  invitee: TestMember;
}

interface ReserveResponse {
  source: { id: string; publisherMemberId: string };
  generation: {
    id: string;
    state: string;
    shareDayKey: number;
    itemCount: number;
    createdAt: number;
    expiresAt: number;
  };
  items: Array<{ mediaId: string; state: string }>;
}

interface PrepareResponse {
  generationId: string;
  prepareAttemptId: string;
  prepareAttemptRevision: number;
  reservedRevision: number;
  rotationAnchorUTC: number;
  prepareExpiresAt: number;
}

const testEnv = env as unknown as Env;

describe("legacy sharing runtime kill switch", () => {
  const legacyRoutes = [
    ["POST", "/v1/sharing/generations/reserve"],
    ["POST", "/v1/sharing/generations/generation/descriptors"],
    ["PUT", "/v1/sharing/generations/generation/media/media"],
    ["POST", "/v1/sharing/generations/generation/prepare"],
    ["PUT", "/v1/sharing/generations/generation/prepares/attempt/manifest"],
    ["POST", "/v1/sharing/generations/generation/commit"],
    ["GET", "/v1/sharing/sources"],
    ["GET", "/v1/sharing/sources/source/current"],
    ["GET", "/v1/sharing/generations/generation/manifest"],
    ["GET", "/v1/sharing/generations/generation/media/media"],
    ["GET", "/v1/sharing/generations/generation"],
    ["GET", "/v1/sharing"],
    ["GET", "/v1/sharing/future-transport"],
  ] as const;

  it("fails closed for all legacy sharing namespaces unless the exact flag is enabled", async () => {
    for (const value of [undefined, "NO", "true", "yes"]) {
      const disabledEnv = {
        ...env,
        LEGACY_SHARING_RUNTIME_ENABLED: value,
      } as Env;
      for (const [method, path] of legacyRoutes) {
        await expect(
          route(new Request(`https://sharing.invalid${path}`, { method }), disabledEnv),
        ).rejects.toMatchObject({
          status: 503,
          code: "legacy_sharing_runtime_disabled",
        });
      }
    }
  });

  it("does not match adjacent namespaces and permits the namespace only with exact YES", async () => {
    const disabledEnv = {
      ...env,
      LEGACY_SHARING_RUNTIME_ENABLED: "NO",
    } as Env;
    await expect(
      route(new Request("https://sharing.invalid/v1/sharingevil"), disabledEnv),
    ).rejects.toMatchObject({ status: 404, code: "not_found" });

    const enabledEnv = {
      ...env,
      LEGACY_SHARING_RUNTIME_ENABLED: "YES",
    } as Env;
    await expect(
      route(new Request("https://sharing.invalid/v1/sharing/future-transport"), enabledEnv),
    ).rejects.toMatchObject({ status: 404, code: "not_found" });
    await expect(
      route(new Request("https://sharing.invalid/v1/pairing/status"), disabledEnv),
    ).rejects.not.toMatchObject({ code: "legacy_sharing_runtime_disabled" });
    await expect(
      route(new Request("https://sharing.invalid/v2/reports/reservations", { method: "POST" }), disabledEnv),
    ).rejects.not.toMatchObject({ code: "legacy_sharing_runtime_disabled" });
  });
});

function bytes(value: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(value.length);
  copy.set(value);
  return copy.buffer;
}

function randomValue(count: number): string {
  const value = new Uint8Array(count);
  crypto.getRandomValues(value);
  return base64urlEncode(value);
}

async function signingKeys(): Promise<KeyPair> {
  return crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  ) as Promise<KeyPair>;
}

async function signingPublicKey(keys: KeyPair): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
}

async function sign(keys: KeyPair, message: Uint8Array): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign(
    { name: "Ed25519" },
    keys.privateKey,
    bytes(message),
  )));
}

async function signedFetch(
  path: string,
  method: "GET" | "POST" | "PUT",
  member: TestMember,
  value?: unknown | Uint8Array,
  extraHeaders?: Record<string, string>,
  nonce = randomValue(16),
): Promise<Response> {
  const binary = value instanceof Uint8Array;
  const bodyBytes = value === undefined
    ? new Uint8Array()
    : binary
      ? value
      : new TextEncoder().encode(JSON.stringify(value));
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = await sign(member.keys, signedRequestTranscript({
    memberId: member.id,
    timestamp,
    nonce,
    method,
    pathname: path,
    bodySHA256: await sha256Base64url(bodyBytes),
  }));
  const headers = new Headers({
    "CF-Connecting-IP": "192.0.2.55",
    "Neko-Protocol-Version": "1",
    "Neko-Member-ID": member.id,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
    ...extraHeaders,
  });
  if (value !== undefined) {
    headers.set("Content-Type", binary ? "application/octet-stream" : "application/json");
  }
  const init: RequestInit = { method, headers };
  if (value !== undefined) init.body = binary ? bytes(bodyBytes) : new TextDecoder().decode(bodyBytes);
  return SELF.fetch(new Request(`https://sharing.invalid${path}`, init));
}

async function seedActiveSpace(): Promise<TestSpace> {
  const now = Math.floor(Date.now() / 1000);
  const ownerKeys = await signingKeys();
  const inviteeKeys = await signingKeys();
  const spaceId = randomValue(16);
  const ownerId = randomValue(16);
  const inviteeId = randomValue(16);
  const boundary = (Math.floor(now / 60) + 180) % 1440;
  await testEnv.DB.batch([
    testEnv.DB.prepare(
      `INSERT INTO spaces(
         id, creation_request_id, protocol_version, daily_boundary_minute_utc,
         state, created_at, last_activity_at, metadata_expires_at
       ) VALUES (?, ?, 1, ?, 'active', ?, ?, ?)`,
    ).bind(spaceId, crypto.randomUUID().toLowerCase(), boundary, now, now, now + 2_592_000),
    testEnv.DB.prepare(
      `INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, 'owner', ?, ?, ?, 'active', ?, ?)`,
    ).bind(
      ownerId,
      spaceId,
      randomValue(16),
      randomValue(32),
      await signingPublicKey(ownerKeys),
      now,
      now,
    ),
    testEnv.DB.prepare(
      `INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, 'invitee', ?, ?, ?, 'active', ?, ?)`,
    ).bind(
      inviteeId,
      spaceId,
      randomValue(16),
      randomValue(32),
      await signingPublicKey(inviteeKeys),
      now,
      now,
    ),
  ]);
  return {
    id: spaceId,
    owner: { id: ownerId, keys: ownerKeys },
    invitee: { id: inviteeId, keys: inviteeKeys },
  };
}

function shape(value: unknown): unknown {
  if (value === null) return null;
  if (Array.isArray(value)) return value.length === 0 ? [] : [shape(value[0])];
  if (typeof value !== "object") return typeof value;
  return Object.fromEntries(Object.entries(value as Record<string, unknown>)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, child]) => [key, shape(child)]));
}

async function publishOne(
  member: TestMember,
): Promise<{
  reserve: ReserveResponse;
  prepare: PrepareResponse;
  mediaId: string;
  mediaCiphertext: Uint8Array;
  manifestCiphertext: Uint8Array;
}> {
  const mediaId = randomValue(16);
  const reserveResponse = await signedFetch(
    "/v1/sharing/generations/reserve",
    "POST",
    member,
    { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase(), items: [{ mediaId }] },
  );
  expect(reserveResponse.status).toBe(201);
  const reserve = await reserveResponse.json<ReserveResponse>();
  expect(shape(reserve)).toEqual(shape(apiFixture.reserve));
  expect(reserve.generation.expiresAt - reserve.generation.createdAt)
    .toBeLessThanOrEqual(3_600);

  const mediaCiphertext = crypto.getRandomValues(new Uint8Array(512));
  const mediaHash = await sha256Base64url(mediaCiphertext);
  const descriptors = await signedFetch(
    `/v1/sharing/generations/${reserve.generation.id}/descriptors`,
    "POST",
    member,
    {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: [{ mediaId, ciphertextSize: mediaCiphertext.length, ciphertextSHA256: mediaHash }],
    },
  );
  expect(descriptors.status).toBe(200);
  expect(shape(await descriptors.json())).toEqual(shape(apiFixture.descriptors));

  const mediaUpload = await signedFetch(
    `/v1/sharing/generations/${reserve.generation.id}/media/${mediaId}`,
    "PUT",
    member,
    mediaCiphertext,
  );
  expect(mediaUpload.status).toBe(200);
  expect(shape(await mediaUpload.json())).toEqual(shape(apiFixture.mediaVerified));

  const prepareResponse = await signedFetch(
    `/v1/sharing/generations/${reserve.generation.id}/prepare`,
    "POST",
    member,
    { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase() },
  );
  expect(prepareResponse.status).toBe(200);
  const prepare = await prepareResponse.json<PrepareResponse>();
  expect(shape(prepare)).toEqual(shape(apiFixture.prepare));
  expect(prepare.rotationAnchorUTC - Math.floor(Date.now() / 1000)).toBeGreaterThanOrEqual(299);

  const resume = await signedFetch(
    `/v1/sharing/generations/${reserve.generation.id}`,
    "GET",
    member,
  );
  expect(resume.status).toBe(200);
  expect(shape(await resume.json())).toEqual(shape(apiFixture.generationResume));

  const manifestCiphertext = crypto.getRandomValues(new Uint8Array(384));
  const manifestUpload = await signedFetch(
    `/v1/sharing/generations/${reserve.generation.id}/prepares/${prepare.prepareAttemptId}/manifest`,
    "PUT",
    member,
    manifestCiphertext,
  );
  expect(manifestUpload.status).toBe(200);
  expect(shape(await manifestUpload.json())).toEqual(shape(apiFixture.manifestVerified));

  const commit = await signedFetch(
    `/v1/sharing/generations/${reserve.generation.id}/commit`,
    "POST",
    member,
    {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      prepareAttemptId: prepare.prepareAttemptId,
      prepareAttemptRevision: prepare.prepareAttemptRevision,
      reservedRevision: prepare.reservedRevision,
      manifestCiphertextSHA256: await sha256Base64url(manifestCiphertext),
    },
  );
  expect(commit.status).toBe(200);
  expect(shape(await commit.json())).toEqual(shape(apiFixture.commit));
  return { reserve, prepare, mediaId, mediaCiphertext, manifestCiphertext };
}

describe("Phase 2 daily encrypted sharing", () => {
  it("publishes one private canonical set and lets the paired member conditionally fetch it", async () => {
    const space = await seedActiveSpace();
    const published = await publishOne(space.owner);

    const currentPath = `/v1/sharing/sources/${published.reserve.source.id}/current`;
    const sources = await signedFetch("/v1/sharing/sources", "GET", space.invitee);
    expect(sources.status).toBe(200);
    expect(shape(await sources.json())).toEqual(shape(apiFixture.sources));
    const currentResponse = await signedFetch(currentPath, "GET", space.invitee);
    expect(currentResponse.status).toBe(200);
    expect(shape(await currentResponse.clone().json())).toEqual(shape(apiFixture.current));
    const etag = currentResponse.headers.get("etag");
    expect(etag).toBeTruthy();
    const unchanged = await signedFetch(currentPath, "GET", space.invitee, undefined, {
      "If-None-Match": etag ?? "",
    });
    expect(unchanged.status).toBe(304);

    const manifest = await signedFetch(
      `/v1/sharing/generations/${published.reserve.generation.id}/manifest`,
      "GET",
      space.invitee,
    );
    expect(manifest.status).toBe(200);
    expect(manifest.headers.get("content-type")).toBe("application/octet-stream");
    expect(new Uint8Array(await manifest.arrayBuffer())).toEqual(published.manifestCiphertext);

    const media = await signedFetch(
      `/v1/sharing/generations/${published.reserve.generation.id}/media/${published.mediaId}`,
      "GET",
      space.invitee,
    );
    expect(media.status).toBe(200);
    expect(new Uint8Array(await media.arrayBuffer())).toEqual(published.mediaCiphertext);

    const columns = await testEnv.DB.prepare("PRAGMA table_info(sharing_generation_media)")
      .all<{ name: string }>();
    expect(columns.results.map((column) => column.name)).not.toContain("media_binding_hash");
  });

  it("uses the persisted space prefix for both active member-bound publishers", async () => {
    const space = await seedActiveSpace();
    const ownerMedia = randomValue(16);
    const inviteeMedia = randomValue(16);
    const [ownerResponse, inviteeResponse] = await Promise.all([
      signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [{ mediaId: ownerMedia }],
      }),
      signedFetch("/v1/sharing/generations/reserve", "POST", space.invitee, {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [{ mediaId: inviteeMedia }],
      }),
    ]);
    expect(ownerResponse.status).toBe(201);
    expect(inviteeResponse.status).toBe(201);
    const prefix = await testEnv.DB.prepare(
      "SELECT object_prefix FROM sharing_storage_scopes WHERE space_id = ?",
    ).bind(space.id).first<{ object_prefix: string }>();
    const keys = await testEnv.DB.prepare(
      `SELECT gm.object_key
         FROM sharing_generation_media AS gm
         JOIN sharing_generations AS g ON g.id = gm.generation_id
        WHERE g.space_id = ?`,
    ).bind(space.id).all<{ object_key: string }>();
    expect(prefix).not.toBeNull();
    expect(keys.results).toHaveLength(2);
    expect(keys.results.every((row) => row.object_key.startsWith(`v1/${prefix?.object_prefix}/`)))
      .toBe(true);
  });

  it("claims a binary-upload nonce before R2 and rejects the replay", async () => {
    const space = await seedActiveSpace();
    const mediaId = randomValue(16);
    const reserveResponse = await signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: [{ mediaId }],
    });
    const reserve = await reserveResponse.json<ReserveResponse>();
    const ciphertext = new Uint8Array(64).fill(11);
    const descriptor = await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/descriptors`,
      "POST",
      space.owner,
      {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [{
          mediaId,
          ciphertextSize: ciphertext.length,
          ciphertextSHA256: await sha256Base64url(ciphertext),
        }],
      },
    );
    expect(descriptor.status).toBe(200);
    const media = await testEnv.DB.prepare(
      `SELECT object_key FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`,
    ).bind(reserve.generation.id, mediaId).first<{ object_key: string }>();
    expect(media).not.toBeNull();
    await testEnv.MEDIA?.put(media?.object_key ?? "missing", new Uint8Array(64).fill(12));

    const path = `/v1/sharing/generations/${reserve.generation.id}/media/${mediaId}`;
    const nonce = randomValue(16);
    const conflict = await signedFetch(path, "PUT", space.owner, ciphertext, undefined, nonce);
    expect(conflict.status).toBe(409);
    expect((await conflict.json<{ error: { code: string } }>()).error.code)
      .toBe("object_integrity_conflict");
    const replay = await signedFetch(path, "PUT", space.owner, ciphertext, undefined, nonce);
    expect(replay.status).toBe(409);
    expect((await replay.json<{ error: { code: string } }>()).error.code)
      .toBe("replayed_request");
  });

  it("binds idempotency to the resource path and consumes mismatch nonces", async () => {
    const space = await seedActiveSpace();
    const mediaId = randomValue(16);
    const reserveResponse = await signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: [{ mediaId }],
    });
    const first = await reserveResponse.json<ReserveResponse>();
    const ciphertext = new Uint8Array(64).fill(21);
    const clientRequestId = crypto.randomUUID().toLowerCase();
    const descriptorBody = {
      protocolVersion: 1,
      clientRequestId,
      items: [{
        mediaId,
        ciphertextSize: ciphertext.length,
        ciphertextSHA256: await sha256Base64url(ciphertext),
      }],
    };
    expect((await signedFetch(
      `/v1/sharing/generations/${first.generation.id}/descriptors`,
      "POST",
      space.owner,
      descriptorBody,
    )).status).toBe(200);

    const now = Math.floor(Date.now() / 1000);
    const secondGenerationId = randomValue(16);
    const source = await testEnv.DB.prepare(
      `SELECT src.id, src.space_id, src.publisher_member_id, storage.object_prefix
         FROM sharing_sources AS src
         JOIN sharing_storage_scopes AS storage ON storage.space_id = src.space_id
        WHERE src.id = ?`,
    ).bind(first.source.id).first<{
      id: string;
      space_id: string;
      publisher_member_id: string;
      object_prefix: string;
    }>();
    expect(source).not.toBeNull();
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        `UPDATE sharing_generations SET state = 'expired', closed_at = ? WHERE id = ?`,
      ).bind(now, first.generation.id),
      testEnv.DB.prepare(
        `INSERT INTO sharing_daily_freezes(
           source_id, share_day_key, generation_id, created_at, expires_at
         ) VALUES (?, ?, ?, ?, ?)`,
      ).bind(
        source?.id,
        first.generation.shareDayKey + 1,
        secondGenerationId,
        now,
        now + 86_400,
      ),
      testEnv.DB.prepare(
        `INSERT INTO sharing_generations(
           id, source_id, space_id, publisher_member_id, share_day_key, state,
           item_count, reserve_request_hash, created_at, staging_expires_at
         ) VALUES (?, ?, ?, ?, ?, 'reserved', 1, ?, ?, ?)`,
      ).bind(
        secondGenerationId,
        source?.id,
        source?.space_id,
        source?.publisher_member_id,
        first.generation.shareDayKey + 1,
        randomValue(32),
        now,
        now + 3600,
      ),
      testEnv.DB.prepare(
        `INSERT INTO sharing_generation_media(generation_id, media_id, object_key, state)
         VALUES (?, ?, ?, 'reserved')`,
      ).bind(
        secondGenerationId,
        mediaId,
        `v1/${source?.object_prefix}/${randomValue(24)}`,
      ),
    ]);

    const secondPath = `/v1/sharing/generations/${secondGenerationId}/descriptors`;
    const nonce = randomValue(16);
    const mismatch = await signedFetch(secondPath, "POST", space.owner, descriptorBody, undefined, nonce);
    expect(mismatch.status).toBe(409);
    expect((await mismatch.json<{ error: { code: string } }>()).error.code)
      .toBe("idempotency_conflict");
    const replay = await signedFetch(secondPath, "POST", space.owner, descriptorBody, undefined, nonce);
    expect(replay.status).toBe(409);
    expect((await replay.json<{ error: { code: string } }>()).error.code)
      .toBe("replayed_request");
  });

  it("atomically accepts only one concurrent immutable descriptor set", async () => {
    const space = await seedActiveSpace();
    const mediaId = randomValue(16);
    const reserveResponse = await signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: [{ mediaId }],
    });
    const reserve = await reserveResponse.json<ReserveResponse>();
    const values = [new Uint8Array(64).fill(31), new Uint8Array(64).fill(32)];
    const hashes = await Promise.all(values.map(sha256Base64url));
    const responses = await Promise.all(hashes.map((hash) => signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/descriptors`,
      "POST",
      space.owner,
      {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [{ mediaId, ciphertextSize: 64, ciphertextSHA256: hash }],
      },
    )));
    expect(responses.map((response) => response.status).sort()).toEqual([200, 409]);
    const winnerIndex = responses.findIndex((response) => response.status === 200);
    const stored = await testEnv.DB.prepare(
      `SELECT ciphertext_sha256 FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`,
    ).bind(reserve.generation.id, mediaId).first<{ ciphertext_sha256: string }>();
    expect(stored?.ciphertext_sha256).toBe(hashes[winnerIndex]);
  });

  it("rejects partial, tampered and over-cap uploads without replacing current", async () => {
    const space = await seedActiveSpace();
    const ids = [randomValue(16), randomValue(16)].sort();
    const reserveResponse = await signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: ids.map((mediaId) => ({ mediaId })),
    });
    const reserve = await reserveResponse.json<ReserveResponse>();
    const first = crypto.getRandomValues(new Uint8Array(64));
    const second = crypto.getRandomValues(new Uint8Array(64));
    const descriptorResponse = await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/descriptors`,
      "POST",
      space.owner,
      {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [
          { mediaId: ids[0], ciphertextSize: first.length, ciphertextSHA256: await sha256Base64url(first) },
          { mediaId: ids[1], ciphertextSize: second.length, ciphertextSHA256: await sha256Base64url(second) },
        ],
      },
    );
    expect(descriptorResponse.status).toBe(200);
    const tampered = first.slice();
    tampered[0] = (tampered[0] ?? 0) ^ 1;
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/media/${ids[0]}`,
      "PUT",
      space.owner,
      tampered,
    )).status).toBe(409);
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/media/${ids[0]}`,
      "PUT",
      space.owner,
      first,
    )).status).toBe(200);
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/prepare`,
      "POST",
      space.owner,
      { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase() },
    )).status).toBe(409);

    const overCap = new Uint8Array(307201).fill(7);
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/media/${ids[1]}`,
      "PUT",
      space.owner,
      overCap,
    )).status).toBe(413);
    expect(await testEnv.DB.prepare("SELECT COUNT(*) AS count FROM sharing_currents WHERE source_id = ?")
      .bind(reserve.source.id).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("hides current ciphertext exactly at retention expiry before cron deletion", async () => {
    const space = await seedActiveSpace();
    const published = await publishOne(space.owner);
    const expiresAt = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "UPDATE sharing_generations SET content_expires_at = ? WHERE id = ?",
    ).bind(expiresAt, published.reserve.generation.id).run();

    const sources = await signedFetch("/v1/sharing/sources", "GET", space.invitee);
    const sourcesJSON = await sources.json<{
      sources: Array<{ id: string; current: unknown | null }>;
    }>();
    expect(sourcesJSON.sources.find((source) => source.id === published.reserve.source.id)?.current)
      .toBeNull();
    expect((await signedFetch(
      `/v1/sharing/sources/${published.reserve.source.id}/current`,
      "GET",
      space.invitee,
    )).status).toBe(404);
    expect((await signedFetch(
      `/v1/sharing/generations/${published.reserve.generation.id}/manifest`,
      "GET",
      space.invitee,
    )).status).toBe(404);
    expect((await signedFetch(
      `/v1/sharing/generations/${published.reserve.generation.id}/media/${published.mediaId}`,
      "GET",
      space.invitee,
    )).status).toBe(404);
    expect((await signedFetch(
      `/v1/sharing/generations/${published.reserve.generation.id}`,
      "GET",
      space.owner,
    )).status).toBe(404);
  });

  it("fails closed at the exact 60-minute staging boundary", async () => {
    const space = await seedActiveSpace();
    const mediaId = randomValue(16);
    const reserveResponse = await signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: [{ mediaId }],
    });
    expect(reserveResponse.status).toBe(201);
    const reserve = await reserveResponse.json<ReserveResponse>();
    const boundary = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      `UPDATE sharing_generations
          SET created_at = ?, staging_expires_at = ?
        WHERE id = ?`,
    ).bind(boundary - 3_600, boundary, reserve.generation.id).run();

    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}`,
      "GET",
      space.owner,
    )).status).toBe(404);
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/descriptors`,
      "POST",
      space.owner,
      {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [{
          mediaId,
          ciphertextSize: 64,
          ciphertextSHA256: randomValue(32),
        }],
      },
    )).status).toBe(404);
  });

  it("physically removes an expired staging object within the 80-minute normal bound", async () => {
    const space = await seedActiveSpace();
    const mediaId = randomValue(16);
    const reserveResponse = await signedFetch("/v1/sharing/generations/reserve", "POST", space.owner, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      items: [{ mediaId }],
    });
    expect(reserveResponse.status).toBe(201);
    const reserve = await reserveResponse.json<ReserveResponse>();
    const ciphertext = crypto.getRandomValues(new Uint8Array(64));
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/descriptors`,
      "POST",
      space.owner,
      {
        protocolVersion: 1,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        items: [{
          mediaId,
          ciphertextSize: ciphertext.length,
          ciphertextSHA256: await sha256Base64url(ciphertext),
        }],
      },
    )).status).toBe(200);
    expect((await signedFetch(
      `/v1/sharing/generations/${reserve.generation.id}/media/${mediaId}`,
      "PUT",
      space.owner,
      ciphertext,
    )).status).toBe(200);
    const media = await testEnv.DB.prepare(
      `SELECT object_key FROM sharing_generation_media
        WHERE generation_id = ? AND media_id = ?`,
    ).bind(reserve.generation.id, mediaId).first<{ object_key: string }>();
    expect(media).not.toBeNull();

    // Worst normal schedule: the first 10-minute run sees expiry at +70 min,
    // then the 10-minute in-flight grace is drained by the +80 min run.
    const closeAt = reserve.generation.createdAt + 4_200;
    const deleteAt = reserve.generation.createdAt + 4_800;
    await runScheduledCleanup(testEnv, closeAt);
    expect(await testEnv.MEDIA?.head(media?.object_key ?? "missing")).not.toBeNull();
    await runScheduledCleanup(testEnv, deleteAt);
    expect(await testEnv.MEDIA?.head(media?.object_key ?? "missing")).toBeNull();
    expect(await testEnv.DB.prepare("SELECT id FROM sharing_generations WHERE id = ?")
      .bind(reserve.generation.id).first()).toBeNull();
  });

  it("denies credentials before unlink storage cleanup and drains a late-object prefix", async () => {
    const space = await seedActiveSpace();
    const published = await publishOne(space.owner);
    const storage = await testEnv.DB.prepare(
      "SELECT object_prefix FROM sharing_storage_scopes WHERE space_id = ?",
    ).bind(space.id).first<{ object_prefix: string }>();
    const revoke = await signedFetch("/v1/pairing/revoke", "POST", space.invitee, {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
    });
    expect(revoke.status).toBe(202);
    expect((await signedFetch("/v1/sharing/sources", "GET", space.owner)).status).toBe(410);

    const job = await testEnv.DB.prepare(
      "SELECT created_at FROM space_deletion_jobs WHERE space_id = ?",
    ).bind(space.id).first<{ created_at: number }>();
    expect(job).not.toBeNull();
    await runScheduledCleanup(testEnv, (job?.created_at ?? 0) + 601);
    await runScheduledCleanup(testEnv, (job?.created_at ?? 0) + 3_700);
    await runScheduledCleanup(testEnv, (job?.created_at ?? 0) + 3_762);
    expect(await testEnv.DB.prepare("SELECT id FROM spaces WHERE id = ?")
      .bind(space.id).first()).toBeNull();
    const objects = await testEnv.MEDIA?.list({ prefix: `v1/${storage?.object_prefix ?? "missing"}/` });
    expect(objects?.objects).toHaveLength(0);
  });

  it("budgets the 10k synchronized daily burst and resumes exact object CAS cleanup", async () => {
    const cronRunsPerDay = 24 * 12;
    const publisherCount = 10_000;
    const objectsPerGeneration = 21;
    const steadyObjectsPerDay = publisherCount * objectsPerGeneration;
    expect(CLEANUP_NONCE_LIMIT * cronRunsPerDay).toBeGreaterThanOrEqual(480_000);
    expect(CLEANUP_OBJECT_LIMIT * cronRunsPerDay).toBeGreaterThan(steadyObjectsPerDay);
    expect(CLEANUP_GENERATION_CLOSE_LIMIT).toBeGreaterThanOrEqual(publisherCount);
    const synchronizedObjectDrainMinutes = Math.ceil(
      steadyObjectsPerDay / CLEANUP_OBJECT_LIMIT,
    ) * 5;
    expect(synchronizedObjectDrainMinutes).toBe(45);
    const abandonedStagingPhysicalDeletionMinutes = 60 + 5 + 10
      + synchronizedObjectDrainMinutes;
    expect(abandonedStagingPhysicalDeletionMinutes).toBeLessThanOrEqual(120);
    expect(Math.ceil(publisherCount / CLEANUP_TERMINAL_GENERATION_LIMIT) * 5).toBeLessThan(60);
    expect(Math.ceil(publisherCount / CLEANUP_SOURCE_UNBLOCK_LIMIT) * 5).toBeLessThan(60);
    expect(OBJECT_DELETE_CAS_TUPLE_LIMIT * 2).toBeLessThanOrEqual(100);
    const objectBatches = Math.ceil(CLEANUP_OBJECT_LIMIT / R2_DELETE_BATCH_SIZE);
    const objectCASQueries = objectBatches
      * Math.ceil(R2_DELETE_BATCH_SIZE / OBJECT_DELETE_CAS_TUPLE_LIMIT);
    const worstCaseD1Queries =
      Math.ceil(CLEANUP_NONCE_LIMIT / CLEANUP_NONCE_CHUNK_SIZE)
      + Math.ceil(CLEANUP_IDEMPOTENCY_LIMIT / CLEANUP_IDEMPOTENCY_CHUNK_SIZE)
      + Math.ceil(CLEANUP_DAILY_FREEZE_LIMIT / CLEANUP_DAILY_FREEZE_CHUNK_SIZE)
      + 7 // pairing expiry candidate query plus its six-statement batch
      + 11 // inactive candidate query plus the ten-statement revoke batch
      + 2 * Math.ceil(CLEANUP_GENERATION_CLOSE_LIMIT / CLEANUP_GENERATION_CHUNK_SIZE)
      + objectBatches // oldest-first object candidate queries
      + objectCASQueries
      // A confirmed-empty prefix uses list + a two-statement completion batch.
      + 3 + 2 * CLEANUP_REVOKED_SCOPE_LIMIT
      + Math.ceil(CLEANUP_TERMINAL_GENERATION_LIMIT / CLEANUP_FINALIZE_CHUNK_SIZE)
      + Math.ceil(CLEANUP_SOURCE_UNBLOCK_LIMIT / CLEANUP_FINALIZE_CHUNK_SIZE)
      + 9; // pending deletion candidate query plus its eight-statement batch
    // A non-empty prefix trades one of the two completion queries for one R2
    // delete, so either branch remains three subrequests per prefix.
    const worstCaseSubrequests = worstCaseD1Queries
      + objectBatches
      + CLEANUP_REVOKED_SCOPE_LIMIT;
    expect(worstCaseD1Queries).toBeLessThan(1_000);
    expect(worstCaseSubrequests).toBeLessThanOrEqual(CLEANUP_SUBREQUEST_GUARD);

    const now = Math.floor(Date.now() / 1000);
    const total = CLEANUP_OBJECT_LIMIT + 1;
    const rearmedKey = "capacity/object-000000";
    const remainingObjects = new Set<string>();
    const deleteBatchSizes: number[] = [];
    const numberRows = `
      WITH digits(value) AS (
        VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)
      ), numbers(value) AS (
        SELECT ones.value + 10 * tens.value + 100 * hundreds.value
             + 1000 * thousands.value + 10000 * ten_thousands.value
          FROM digits AS ones
          CROSS JOIN digits AS tens
          CROSS JOIN digits AS hundreds
          CROSS JOIN digits AS thousands
          CROSS JOIN digits AS ten_thousands
         ORDER BY 1 ASC
         LIMIT ?
      )`;
    await testEnv.DB.prepare(
      `${numberRows}
       INSERT INTO sharing_object_deletions(
         object_key, space_id, source_id, reason, state, not_before,
         attempts, created_at, deleted_at
       )
       SELECT printf('capacity/object-%06d', value), 'capacity-space', NULL,
              'rotation', 'pending', ?, 0, ? + value, NULL
         FROM numbers`,
    ).bind(total, now - 1, now - total).run();
    for (let index = 0; index < total; index += 1) {
      remainingObjects.add(`capacity/object-${index.toString().padStart(6, "0")}`);
    }

    let rearmOnce = true;
    const media = {
      async delete(keys: string | string[]): Promise<void> {
        const values = typeof keys === "string" ? [keys] : keys;
        deleteBatchSizes.push(values.length);
        for (const key of values) remainingObjects.delete(key);
        if (rearmOnce && values.includes(rearmedKey)) {
          rearmOnce = false;
          await testEnv.DB.prepare(
            `UPDATE sharing_object_deletions
                SET attempts = attempts + 1, not_before = ?
              WHERE object_key = ?`,
          ).bind(now + 600, rearmedKey).run();
        }
      },
      async list(): Promise<R2Objects> {
        return { objects: [], truncated: false } as unknown as R2Objects;
      },
    } as unknown as R2Bucket;
    const capacityEnv: Env = {
      DB: testEnv.DB,
      MEDIA: media,
      ENVIRONMENT: "test",
      INVITATION_TTL_SECONDS: "86400",
      CHALLENGE_TTL_SECONDS: "300",
      PENDING_TTL_SECONDS: "86400",
      IDEMPOTENCY_TTL_SECONDS: "172800",
      SPACE_INACTIVITY_TTL_SECONDS: "2592000",
    };

    const startedAt = performance.now();
    await runScheduledCleanup(capacityEnv, now);
    expect(performance.now() - startedAt).toBeLessThan(30_000);
    expect(deleteBatchSizes).toHaveLength(CLEANUP_OBJECT_LIMIT / 1_000);
    expect(deleteBatchSizes.every((size) => size === 1_000)).toBe(true);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM sharing_object_deletions",
    ).first<{ count: number }>()).toEqual({ count: 2 });
    expect(await testEnv.DB.prepare(
      "SELECT attempts FROM sharing_object_deletions WHERE object_key = ?",
    ).bind(rearmedKey).first()).toEqual({ attempts: 1 });
    expect(remainingObjects).toEqual(new Set(["capacity/object-024000"]));

    await runScheduledCleanup(capacityEnv, now + 601);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM sharing_object_deletions",
    ).first<{ count: number }>()).toEqual({ count: 0 });
    expect(remainingObjects.size).toBe(0);
  }, 30_000);

  it("clears cleanup-blocked sources in bounded oldest-first runs", async () => {
    const now = Math.floor(Date.now() / 1000);
    const total = CLEANUP_SOURCE_UNBLOCK_LIMIT + 1;
    const numberRows = `
      WITH digits(value) AS (
        VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)
      ), numbers(value) AS (
        SELECT ones.value + 10 * tens.value + 100 * hundreds.value
             + 1000 * thousands.value
          FROM digits AS ones
          CROSS JOIN digits AS tens
          CROSS JOIN digits AS hundreds
          CROSS JOIN digits AS thousands
         ORDER BY 1 ASC
         LIMIT ?
      )`;
    await testEnv.DB.prepare(
      `${numberRows}
       INSERT INTO spaces(
         id, creation_request_id, protocol_version, daily_boundary_minute_utc,
         state, created_at, last_activity_at, metadata_expires_at
       )
       SELECT printf('cleanup-space-%04d', value),
              printf('cleanup-create-%04d', value), 1, 0, 'active', ?, ?, ?
         FROM numbers`,
    ).bind(total, now, now, now + 2_592_000).run();
    await testEnv.DB.prepare(
      `${numberRows}
       INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       )
       SELECT printf('cleanup-member-%04d', value),
              printf('cleanup-space-%04d', value), 'owner',
              printf('participant-%04d', value), printf('agreement-%04d', value),
              printf('signing-%04d', value), 'active', ?, ?
         FROM numbers`,
    ).bind(total, now, now).run();
    await testEnv.DB.prepare(
      `${numberRows}
       INSERT INTO sharing_sources(
         id, space_id, publisher_member_id, state, cleanup_blocked,
         created_at, updated_at
       )
       SELECT printf('cleanup-source-%04d', value),
              printf('cleanup-space-%04d', value),
              printf('cleanup-member-%04d', value), 'active', 1,
              ? - value, ? - value
         FROM numbers`,
    ).bind(total, now, now).run();

    await runScheduledCleanup(testEnv, now);
    const afterOne = await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM sharing_sources
        WHERE cleanup_blocked = 1`,
    ).first<{ count: number }>();
    expect(afterOne?.count).toBe(1);
    expect(await testEnv.DB.prepare(
      "SELECT id FROM sharing_sources WHERE cleanup_blocked = 1",
    ).first()).toEqual({ id: "cleanup-source-0000" });
    await runScheduledCleanup(testEnv, now + 1);
    const afterTwo = await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM sharing_sources
        WHERE cleanup_blocked = 1`,
    ).first<{ count: number }>();
    expect(afterTwo?.count).toBe(0);
    expect(total).toBe(1_001);
  });
});
