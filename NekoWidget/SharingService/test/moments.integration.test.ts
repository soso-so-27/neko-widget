import { env } from "cloudflare:workers";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { base64urlEncode, sha256Base64url } from "../src/encoding";
import type { Env } from "../src/env";
import { route } from "../src/index";
import {
  MOMENT_CLEANUP_OBJECT_LIMIT,
  MOMENT_REVOKED_SCOPE_LIMIT,
  MOMENT_RESERVATION_ATTEMPT_LIMIT,
  runMomentCleanup,
} from "../src/moments";
import { encodeCanonicalFields, signedRequestTranscript } from "../src/protocol";
import { REACTION_USAGE_RETENTION_DAYS } from "../src/reactions";
import { runScheduledCleanup } from "../src/scheduled";

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

describe("moment runtime kill switch", () => {
  it("treats the D1 media gate as a fail-closed lower bound without blocking safety routes", async () => {
    const restore = await temporarilySetRuntimeGate({ mediaEnabled: 0, apnsEnabled: 0 });
    try {
      for (const [path, code] of [
        ["/v2/moments/changes", "moment_runtime_disabled"],
        ["/v2/reactions/changes", "reaction_runtime_disabled"],
        ["/v2/window-name", "window_name_runtime_disabled"],
      ] as const) {
        await expect(route(new Request(`https://sharing.invalid${path}`), testEnv))
          .rejects.toMatchObject({ status: 503, code });
      }
      await expect(route(new Request(
        "https://sharing.invalid/v2/participants/0000000000000000000000/block",
        { method: "POST" },
      ), testEnv)).rejects.toMatchObject({ status: 401, code: "invalid_authentication" });

      const health = await route(new Request("https://sharing.invalid/health"), testEnv);
      expect(health.headers.get("cache-control")).toBe("no-store");
      expect(health.headers.get("neko-runtime-media")).toBe("OFF");
      expect(health.headers.get("neko-runtime-apns")).toBe("OFF");
      await expect(runMomentCleanup(testEnv)).resolves.toBeUndefined();
    } finally {
      await restore();
    }
  });

  it("keeps the health state fail closed when an upper var is off or the gate is missing", async () => {
    const upperOff = await route(
      new Request("https://sharing.invalid/health"),
      { ...testEnv, MOMENT_RUNTIME_ENABLED: "NO" } as Env,
    );
    expect(upperOff.headers.get("neko-runtime-media")).toBe("OFF");
    let serializedHeaders = "";
    upperOff.headers.forEach((value, name) => { serializedHeaders += `${name}:${value}\n`; });
    expect(serializedHeaders).not.toMatch(
      /account-id|database-id|member-id|device-id|credential|authorization|token|secret|email|jws/iu,
    );

    const unavailableGateEnv = {
      ...testEnv,
      DB: { prepare: () => { throw new Error("gate unavailable"); } } as unknown as D1Database,
    } as Env;
    await expect(route(new Request("https://sharing.invalid/health"), unavailableGateEnv))
      .rejects.toMatchObject({ status: 503, code: "runtime_gate_unavailable" });
  });

  it("fails closed for normal moment routes unless the exact server flag is enabled", async () => {
    for (const value of [undefined, "NO", "true", "yes"]) {
      const disabledEnv = {
        ...env,
        MOMENT_RUNTIME_ENABLED: value,
      } as Env;
      await expect(
        route(
          new Request("https://sharing.invalid/v2/moments/changes"),
          disabledEnv,
        ),
      ).rejects.toMatchObject({
        status: 503,
        code: "moment_runtime_disabled",
      });
    }
  });

  it("fails closed for paw reaction routes unless the exact independent flag is enabled", async () => {
    for (const value of [undefined, "NO", "true", "yes"]) {
      const disabledEnv = {
        ...env,
        REACTION_RUNTIME_ENABLED: value,
      } as Env;
      for (const request of [
        new Request("https://sharing.invalid/v2/reactions/changes"),
        new Request(
          "https://sharing.invalid/v2/moments/0000000000000000000000/reactions",
          { method: "POST" },
        ),
      ]) {
        await expect(route(request, disabledEnv)).rejects.toMatchObject({
          status: 503,
          code: "reaction_runtime_disabled",
        });
      }
    }
    const reactionOnlyEnv = {
      ...env,
      MOMENT_RUNTIME_ENABLED: "NO",
      REACTION_RUNTIME_ENABLED: "YES",
    } as Env;
    await expect(route(
      new Request(
        "https://sharing.invalid/v2/moments/0000000000000000000000/reactions",
        { method: "POST" },
      ),
      reactionOnlyEnv,
    )).rejects.toMatchObject({ status: 401, code: "invalid_authentication" });
  });

  it("fails closed for window-name routes under their independent exact flag", async () => {
    for (const value of [undefined, "NO", "true", "yes"]) {
      for (const method of ["GET", "PUT"]) {
        const disabledEnv = {
          ...env,
          WINDOW_NAME_RUNTIME_ENABLED: value,
        } as Env;
        await expect(
          route(
            new Request("https://sharing.invalid/v2/window-name", { method }),
            disabledEnv,
          ),
        ).rejects.toMatchObject({
          status: 503,
          code: "window_name_runtime_disabled",
        });
      }
    }
  });

  it("authenticates and burns signed nonces before independently stopping report ingestion", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const evidence = crypto.getRandomValues(new Uint8Array(192));
    const reservationBody = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      momentId: published.reservation.moment.id,
      reasonCode: "privacy",
      moderationKeyId: "moderation-v1",
      ciphertextSize: evidence.length,
      ciphertextSHA256: await sha256Base64url(evidence),
      reporterConsent: { version: 1, acceptedAt: new Date().toISOString() },
    };
    const disabledEnv = {
      ...testEnv,
      REPORT_INGESTION_RUNTIME_ENABLED: "NO",
    } as Env;

    await expect(route(
      new Request("https://sharing.invalid/v2/reports/reservations", { method: "POST" }),
      disabledEnv,
    )).rejects.toMatchObject({ status: 401, code: "invalid_authentication" });

    for (const value of [undefined, "NO", "true", "yes"]) {
      const nonce = randomValue(16);
      const currentEnv = {
        ...testEnv,
        REPORT_INGESTION_RUNTIME_ENABLED: value,
      } as Env;
      await expect(route(
        await signedRequest(
          "/v2/reports/reservations",
          "POST",
          space.invitee,
          reservationBody,
          nonce,
        ),
        currentEnv,
      )).rejects.toMatchObject({
        status: 503,
        code: "report_ingestion_runtime_disabled",
      });
      await expect(route(
        await signedRequest(
          "/v2/reports/reservations",
          "POST",
          space.invitee,
          reservationBody,
          nonce,
        ),
        { ...testEnv, REPORT_INGESTION_RUNTIME_ENABLED: "YES" } as Env,
      )).rejects.toMatchObject({ status: 409, code: "replayed_request" });
    }
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moment_reports WHERE moment_id = ?",
    ).bind(published.reservation.moment.id).first<{ count: number }>())?.count).toBe(0);

    const enabledEnv = {
      ...testEnv,
      REPORT_INGESTION_RUNTIME_ENABLED: "YES",
    } as Env;
    const reservedResponse = await route(
      await signedRequest(
        "/v2/reports/reservations",
        "POST",
        space.invitee,
        reservationBody,
      ),
      enabledEnv,
    );
    expect(reservedResponse.status).toBe(201);
    const reserved = await reservedResponse.json<{
      report: { id: string; state: string; uploadExpiresAt: number };
    }>();

    const uploadNonce = randomValue(16);
    await expect(route(
      await signedRequest(
        `/v2/reports/${reserved.report.id}/ciphertext`,
        "PUT",
        space.invitee,
        evidence,
        uploadNonce,
      ),
      disabledEnv,
    )).rejects.toMatchObject({
      status: 503,
      code: "report_ingestion_runtime_disabled",
    });
    await expect(route(
      await signedRequest(
        `/v2/reports/${reserved.report.id}/ciphertext`,
        "PUT",
        space.invitee,
        evidence,
        uploadNonce,
      ),
      enabledEnv,
    )).rejects.toMatchObject({ status: 409, code: "replayed_request" });
    expect((await testEnv.DB.prepare(
      "SELECT state FROM moment_reports WHERE id = ?",
    ).bind(reserved.report.id).first<{ state: string }>())?.state).toBe("reserved");

    const uploadResponse = await route(
      await signedRequest(
        `/v2/reports/${reserved.report.id}/ciphertext`,
        "PUT",
        space.invitee,
        evidence,
      ),
      enabledEnv,
    );
    expect(uploadResponse.status).toBe(200);

    const commitBody = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
    };
    const commitNonce = randomValue(16);
    await expect(route(
      await signedRequest(
        `/v2/reports/${reserved.report.id}/commit`,
        "POST",
        space.invitee,
        commitBody,
        commitNonce,
      ),
      disabledEnv,
    )).rejects.toMatchObject({
      status: 503,
      code: "report_ingestion_runtime_disabled",
    });
    await expect(route(
      await signedRequest(
        `/v2/reports/${reserved.report.id}/commit`,
        "POST",
        space.invitee,
        commitBody,
        commitNonce,
      ),
      enabledEnv,
    )).rejects.toMatchObject({ status: 409, code: "replayed_request" });
    expect((await testEnv.DB.prepare(
      "SELECT state FROM moment_reports WHERE id = ?",
    ).bind(reserved.report.id).first<{ state: string }>())?.state).toBe("uploaded");

    await runMomentCleanup(disabledEnv, reserved.report.uploadExpiresAt + 1);
    expect((await testEnv.DB.prepare(
      "SELECT state FROM moment_reports WHERE id = ?",
    ).bind(reserved.report.id).first<{ state: string }>())?.state).toBe("deleted");

    const blockSpace = await seedActiveSpace();
    const blockResponse = await route(
      await signedRequest(
        `/v2/participants/${blockSpace.invitee.id}/block`,
        "POST",
        blockSpace.owner,
        { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
      ),
      disabledEnv,
    );
    expect(blockResponse.status).toBe(200);
  });

  it("authenticates and burns the nonce when the D1 report lower gate is closed", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const evidence = crypto.getRandomValues(new Uint8Array(192));
    const body = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      momentId: published.reservation.moment.id,
      reasonCode: "privacy",
      moderationKeyId: "moderation-v1",
      ciphertextSize: evidence.length,
      ciphertextSHA256: await sha256Base64url(evidence),
      reporterConsent: { version: 1, acceptedAt: new Date().toISOString() },
    };
    const restore = await temporarilySetRuntimeGate({ reportIngestionEnabled: 0 });
    try {
      const nonce = randomValue(16);
      const request = await signedRequest(
        "/v2/reports/reservations", "POST", space.invitee, body, nonce,
      );
      const replay = await signedRequest(
        "/v2/reports/reservations", "POST", space.invitee, body, nonce,
      );
      await expect(route(request, { ...testEnv, REPORT_INGESTION_RUNTIME_ENABLED: "YES" } as Env))
        .rejects.toMatchObject({ status: 503, code: "report_ingestion_runtime_disabled" });
      await expect(route(replay, { ...testEnv, REPORT_INGESTION_RUNTIME_ENABLED: "YES" } as Env))
        .rejects.toMatchObject({ status: 409, code: "replayed_request" });
    } finally {
      await restore();
    }
  });
});

interface TestMember {
  id: string;
  keys: KeyPair;
  deviceID?: string;
}

interface TestSpace {
  id: string;
  owner: TestMember;
  invitee: TestMember;
}

interface ReservationResponse {
  protocolVersion: number;
  moment: {
    id: string;
    clientMomentId: string;
    spaceId: string;
    senderParticipantId: string;
    senderDeviceId: string;
    kind: string;
    keyEpoch: number;
    state: string;
    ciphertextSize: number;
    ciphertextSHA256: string;
    uploadExpiresAt: number;
  };
  quota: { used: number; limit: number; remaining: number };
}

interface CommitResponse {
  moment: { id: string; state: string; committedAt: number; unreceivedExpiresAt: number };
  recipientCount: number;
  changeCursor: string;
}

interface WindowNameResponse {
  protocolVersion: number;
  windowName: null | {
    ownerMemberId: string;
    clientRevision: number;
    keyEpoch: number;
    ciphertext: string;
    ciphertextSHA256: string;
    ownerSignature: string;
  };
}

const testEnv = env as unknown as Env;

interface RuntimeGateTestState {
  generation: number;
  media_enabled: number;
  apns_enabled: number;
  report_ingestion_enabled: number;
}

async function temporarilySetRuntimeGate(patch: {
  mediaEnabled?: 0 | 1;
  apnsEnabled?: 0 | 1;
  reportIngestionEnabled?: 0 | 1;
}): Promise<() => Promise<void>> {
  const previous = await testEnv.DB.prepare(
    `SELECT generation, media_enabled, apns_enabled, report_ingestion_enabled
       FROM personal_staging_runtime_gate WHERE singleton = 1`,
  ).first<RuntimeGateTestState>();
  if (previous === null) throw new Error("runtime gate test baseline is unavailable");
  const next = {
    media: patch.mediaEnabled ?? previous.media_enabled,
    apns: patch.apnsEnabled ?? previous.apns_enabled,
    report: patch.reportIngestionEnabled ?? previous.report_ingestion_enabled,
  };
  const changed = await testEnv.DB.prepare(
    `UPDATE personal_staging_runtime_gate
        SET generation = generation + 1, media_enabled = ?, apns_enabled = ?,
            report_ingestion_enabled = ?, updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?`,
  ).bind(next.media, next.apns, next.report, previous.generation).run();
  if (changed.meta.changes !== 1) throw new Error("runtime gate test transition failed");
  return async () => {
    const restored = await testEnv.DB.prepare(
      `UPDATE personal_staging_runtime_gate
          SET generation = generation + 1, media_enabled = ?, apns_enabled = ?,
              report_ingestion_enabled = ?, updated_at = unixepoch()
        WHERE singleton = 1 AND generation = ?`,
    ).bind(
      previous.media_enabled,
      previous.apns_enabled,
      previous.report_ingestion_enabled,
      previous.generation + 1,
    ).run();
    if (restored.meta.changes !== 1) throw new Error("runtime gate test restore failed");
  };
}

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

async function signedRequest(
  path: string,
  method: "GET" | "POST" | "PUT",
  member: TestMember,
  value?: unknown | Uint8Array,
  nonce = randomValue(16),
): Promise<Request> {
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
    "CF-Connecting-IP": "192.0.2.88",
    "Neko-Protocol-Version": "1",
    "Neko-Member-ID": member.id,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
  });
  if (member.deviceID !== undefined) {
    headers.set("Neko-Device-ID", member.deviceID);
  }
  if (value !== undefined) {
    headers.set("Content-Type", binary ? "application/octet-stream" : "application/json");
  }
  const init: RequestInit = { method, headers };
  if (value !== undefined) init.body = binary ? bytes(bodyBytes) : new TextDecoder().decode(bodyBytes);
  return new Request(`https://sharing.invalid${path}`, init);
}

async function signedFetch(
  path: string,
  method: "GET" | "POST" | "PUT",
  member: TestMember,
  value?: unknown | Uint8Array,
  nonce = randomValue(16),
): Promise<Response> {
  return SELF.fetch(await signedRequest(path, method, member, value, nonce));
}

async function addFutureParticipant(spaceID: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const id = randomValue(16);
  await testEnv.DB.batch([
    testEnv.DB.prepare(
      `INSERT INTO moment_participants(
         id, space_id, role, state, created_at, activated_at
       ) VALUES (?, ?, 'member', 'active', ?, ?)`,
    ).bind(id, spaceID, now, now),
    testEnv.DB.prepare(
      `INSERT INTO moment_devices(
         id, participant_id, agreement_public_key, signing_public_key,
         state, created_at, activated_at
       ) VALUES (?, ?, ?, ?, 'active', ?, ?)`,
    ).bind(randomValue(16), id, randomValue(32), randomValue(32), now, now),
  ]);
  return id;
}

async function seedActiveSpace(): Promise<TestSpace> {
  const now = Math.floor(Date.now() / 1000);
  const ownerKeys = await signingKeys();
  const inviteeKeys = await signingKeys();
  const spaceID = randomValue(16);
  const ownerID = randomValue(16);
  const inviteeID = randomValue(16);
  await testEnv.DB.batch([
    testEnv.DB.prepare(
      `INSERT INTO spaces(
         id, creation_request_id, protocol_version, daily_boundary_minute_utc,
         state, created_at, last_activity_at, metadata_expires_at
       ) VALUES (?, ?, 1, 0, 'active', ?, ?, ?)`,
    ).bind(spaceID, crypto.randomUUID().toLowerCase(), now, now, now + 2_592_000),
    testEnv.DB.prepare(
      `INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, 'owner', ?, ?, ?, 'active', ?, ?)`,
    ).bind(
      ownerID,
      spaceID,
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
      inviteeID,
      spaceID,
      randomValue(16),
      randomValue(32),
      await signingPublicKey(inviteeKeys),
      now,
      now,
    ),
  ]);
  return {
    id: spaceID,
    owner: { id: ownerID, keys: ownerKeys },
    invitee: { id: inviteeID, keys: inviteeKeys },
  };
}

function reserveBody(
  ciphertext: Uint8Array,
  overrides: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    protocolVersion: 2,
    clientRequestId: crypto.randomUUID().toLowerCase(),
    clientMomentId: crypto.randomUUID().toLowerCase(),
    kind: "live",
    keyEpoch: 1,
    ciphertextSize: ciphertext.length,
    ciphertextSHA256: "",
    clientModerationVersion: 1,
    senderPolicyAcceptance: { version: 1, acceptedAt: new Date().toISOString() },
    ...overrides,
  };
}

async function reserve(
  member: TestMember,
  ciphertext: Uint8Array,
  overrides: Partial<Record<string, unknown>> = {},
): Promise<{ response: Response; body: Record<string, unknown> }> {
  const body = reserveBody(ciphertext, {
    ciphertextSHA256: await sha256Base64url(ciphertext),
    ...overrides,
  });
  return {
    response: await signedFetch("/v2/moments/reservations", "POST", member, body),
    body,
  };
}

async function publish(
  member: TestMember,
  ciphertext = crypto.getRandomValues(new Uint8Array(768)),
): Promise<{ reservation: ReservationResponse; commit: CommitResponse; ciphertext: Uint8Array }> {
  const reserved = await reserve(member, ciphertext);
  expect(reserved.response.status).toBe(201);
  const reservation = await reserved.response.json<ReservationResponse>();
  const upload = await signedFetch(
    `/v2/moments/${reservation.moment.id}/ciphertext`,
    "PUT",
    member,
    ciphertext,
  );
  expect(upload.status).toBe(200);
  const commitResponse = await signedFetch(
    `/v2/moments/${reservation.moment.id}/commit`,
    "POST",
    member,
    { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
  );
  expect(commitResponse.status).toBe(201);
  return {
    reservation,
    commit: await commitResponse.json<CommitResponse>(),
    ciphertext,
  };
}

async function windowNameBody(
  space: TestSpace,
  clientRevision: number,
  ciphertext = crypto.getRandomValues(new Uint8Array(96)),
  overrides: { clientRequestId?: string; keyEpoch?: number } = {},
): Promise<Record<string, unknown>> {
  const clientRequestId = overrides.clientRequestId
    ?? crypto.randomUUID().toLowerCase();
  const keyEpoch = overrides.keyEpoch ?? 1;
  const ciphertextSHA256 = await sha256Base64url(ciphertext);
  const ownerSignature = await sign(space.owner.keys, encodeCanonicalFields([
    "NW2.WINDOW-NAME-RECORD",
    "1",
    space.id,
    space.owner.id,
    String(clientRevision),
    String(keyEpoch),
    ciphertextSHA256,
  ]));
  return {
    protocolVersion: 2,
    clientRequestId,
    clientRevision,
    keyEpoch,
    ciphertext: base64urlEncode(ciphertext),
    ciphertextSHA256,
    ownerSignature,
  };
}

async function remapOwnerToDistinctMomentParticipant(space: TestSpace): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const participantID = randomValue(16);
  const credential = await testEnv.DB.prepare(
    "SELECT agreement_public_key, signing_public_key FROM members WHERE id = ?",
  ).bind(space.owner.id).first<{
    agreement_public_key: string;
    signing_public_key: string;
  }>();
  if (credential === null) throw new Error("owner credential fixture is missing");
  await testEnv.DB.batch([
    testEnv.DB.prepare(
      "DELETE FROM moment_devices WHERE legacy_member_id = ?",
    ).bind(space.owner.id),
    testEnv.DB.prepare(
      "DELETE FROM moment_participants WHERE legacy_member_id = ?",
    ).bind(space.owner.id),
    testEnv.DB.prepare(
      `INSERT INTO moment_participants(
         id, space_id, legacy_member_id, role, state, created_at, activated_at
       ) VALUES (?, ?, ?, 'owner', 'active', ?, ?)`,
    ).bind(participantID, space.id, space.owner.id, now, now),
    testEnv.DB.prepare(
      `INSERT INTO moment_devices(
         id, participant_id, legacy_member_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, ?, ?, ?, 'active', ?, ?)`,
    ).bind(
      randomValue(16),
      participantID,
      space.owner.id,
      credential.agreement_public_key,
      credential.signing_public_key,
      now,
      now,
    ),
  ]);
  return participantID;
}

describe("encrypted private window name", () => {
  it("lets the owner publish opaque ciphertext and both active participants read it", async () => {
    const space = await seedActiveSpace();
    const momentParticipantID = await remapOwnerToDistinctMomentParticipant(space);
    expect(momentParticipantID).not.toBe(space.owner.id);
    const empty = await signedFetch("/v2/window-name", "GET", space.invitee);
    expect(empty.status).toBe(200);
    expect(await empty.json<WindowNameResponse>()).toEqual({
      protocolVersion: 2,
      windowName: null,
    });

    const body = await windowNameBody(space, 0);
    const put = await signedFetch("/v2/window-name", "PUT", space.owner, body);
    expect(put.status).toBe(200);
    const published = await put.json<WindowNameResponse>();
    expect(Object.keys(published).sort()).toEqual(["protocolVersion", "windowName"]);
    expect(Object.keys(published.windowName ?? {}).sort()).toEqual([
      "ciphertext",
      "ciphertextSHA256",
      "clientRevision",
      "keyEpoch",
      "ownerMemberId",
      "ownerSignature",
    ]);
    expect(published.windowName).toEqual({
      ownerMemberId: space.owner.id,
      clientRevision: body.clientRevision,
      keyEpoch: body.keyEpoch,
      ciphertext: body.ciphertext,
      ciphertextSHA256: body.ciphertextSHA256,
      ownerSignature: body.ownerSignature,
    });

    const inviteeGet = await signedFetch("/v2/window-name", "GET", space.invitee);
    expect(inviteeGet.status).toBe(200);
    expect(await inviteeGet.json<WindowNameResponse>()).toEqual(published);

    const deniedPut = await signedFetch("/v2/window-name", "PUT", space.invitee, body);
    expect(deniedPut.status).toBe(403);
    expect((await deniedPut.json<{ error: { code: string } }>()).error.code)
      .toBe("owner_required");

    const columns = await testEnv.DB.prepare("PRAGMA table_info(moment_window_names)")
      .all<{ name: string }>();
    expect(columns.results.map((column) => column.name)).not.toContain("name");
    expect(columns.results.map((column) => column.name)).not.toContain("plaintext");
  });

  it("enforces exact-request idempotency and monotonic revision conflicts", async () => {
    const space = await seedActiveSpace();
    const clientRequestId = crypto.randomUUID().toLowerCase();
    const ciphertext = crypto.getRandomValues(new Uint8Array(80));
    const revisionTwo = await windowNameBody(
      space,
      2,
      ciphertext,
      { clientRequestId },
    );
    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      revisionTwo,
    )).status).toBe(200);
    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      revisionTwo,
    )).status).toBe(200);

    const differentExactKey = await windowNameBody(
      space,
      3,
      crypto.getRandomValues(new Uint8Array(80)),
      { clientRequestId },
    );
    const exactKeyConflict = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      differentExactKey,
    );
    expect(exactKeyConflict.status).toBe(409);
    expect((await exactKeyConflict.json<{ error: { code: string } }>()).error.code)
      .toBe("idempotency_conflict");

    const stale = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(space, 1),
    );
    expect(stale.status).toBe(409);
    expect((await stale.json<{ error: { code: string } }>()).error.code)
      .toBe("stale_window_name_revision");

    const equalSame = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(space, 2, ciphertext),
    );
    expect(equalSame.status).toBe(200);

    const equalDifferent = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(space, 2),
    );
    expect(equalDifferent.status).toBe(409);
    expect((await equalDifferent.json<{ error: { code: string } }>()).error.code)
      .toBe("window_name_revision_conflict");

    const current = await signedFetch("/v2/window-name", "GET", space.owner);
    expect((await current.json<WindowNameResponse>()).windowName?.ciphertext)
      .toBe(revisionTwo.ciphertext);
  });

  it("commits only one of two concurrent ciphertexts for the same revision", async () => {
    const space = await seedActiveSpace();
    const first = await windowNameBody(space, 1);
    const second = await windowNameBody(space, 1);
    const responses = await Promise.all([
      signedFetch("/v2/window-name", "PUT", space.owner, first),
      signedFetch("/v2/window-name", "PUT", space.owner, second),
    ]);
    expect(responses.map((response) => response.status).sort()).toEqual([200, 409]);
    const rejected = responses.find((response) => response.status === 409);
    expect(rejected).toBeDefined();
    expect((await rejected!.json<{ error: { code: string } }>()).error.code)
      .toBe("window_name_revision_conflict");

    const current = await signedFetch("/v2/window-name", "GET", space.owner);
    const committed = (await current.json<WindowNameResponse>()).windowName;
    expect([first.ciphertext, second.ciphertext]).toContain(committed?.ciphertext);
  });

  it("rejects malformed, unverified, non-current, and oversized envelopes", async () => {
    const space = await seedActiveSpace();
    const valid = await windowNameBody(space, 0);

    const unexpectedPlaintextField = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      { ...valid, plaintextName: "not-accepted" },
    );
    expect(unexpectedPlaintextField.status).toBe(400);

    const malformed = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      { ...valid, ciphertext: "AA==" },
    );
    expect(malformed.status).toBe(400);

    const oversized = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(
        space,
        0,
        crypto.getRandomValues(new Uint8Array(513)),
      ),
    );
    expect(oversized.status).toBe(400);
    expect((await oversized.json<{ error: { code: string } }>()).error.code)
      .toBe("invalid_ciphertext_length");

    const hashMismatch = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      { ...valid, ciphertextSHA256: randomValue(32) },
    );
    expect(hashMismatch.status).toBe(400);
    expect((await hashMismatch.json<{ error: { code: string } }>()).error.code)
      .toBe("ciphertext_hash_mismatch");

    const invalidSignature = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      { ...valid, ownerSignature: randomValue(64) },
    );
    expect(invalidSignature.status).toBe(401);
    expect((await invalidSignature.json<{ error: { code: string } }>()).error.code)
      .toBe("invalid_owner_signature");

    const staleEpoch = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(space, 0, undefined, { keyEpoch: 2 }),
    );
    expect(staleEpoch.status).toBe(409);
    expect((await staleEpoch.json<{ error: { code: string } }>()).error.code)
      .toBe("key_epoch_required");
    expect((await signedFetch(
      "/v2/window-name",
      "GET",
      space.owner,
    ).then((response) => response.json<WindowNameResponse>())).windowName).toBeNull();
  });

  it("deletes the envelope and denies access after a block or space revoke", async () => {
    const space = await seedActiveSpace();
    const originalBody = await windowNameBody(space, 0);
    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      originalBody,
    )).status).toBe(200);

    const block = await signedFetch(
      `/v2/participants/${space.invitee.id}/block`,
      "POST",
      space.owner,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(block.status).toBe(200);
    expect(await testEnv.DB.prepare(
      "SELECT space_id FROM moment_window_names WHERE space_id = ?",
    ).bind(space.id).first()).toBeNull();
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM idempotency_records
        WHERE space_id = ? AND operation = 'put-window-name'`,
    ).bind(space.id).first<{ count: number }>())?.count).toBe(0);
    expect((await signedFetch("/v2/window-name", "GET", space.invitee)).status)
      .toBe(410);
    expect((await signedFetch("/v2/window-name", "GET", space.owner)).status)
      .toBe(410);
    const deletedReplay = await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      originalBody,
    );
    expect(deletedReplay.status).toBe(410);
    expect((await deletedReplay.json<{ error: { code: string } }>()).error.code)
      .toBe("window_name_blocked");

    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(space, 1, undefined, { keyEpoch: 2 }),
    )).status).toBe(410);

    const revokedSpace = await seedActiveSpace();
    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      revokedSpace.owner,
      await windowNameBody(revokedSpace, 0),
    )).status).toBe(200);
    const revoke = await signedFetch(
      "/v1/pairing/revoke",
      "POST",
      revokedSpace.owner,
      { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(revoke.status).toBe(202);
    expect(await testEnv.DB.prepare(
      "SELECT space_id FROM moment_window_names WHERE space_id = ?",
    ).bind(revokedSpace.id).first()).toBeNull();
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM idempotency_records
        WHERE space_id = ? AND operation = 'put-window-name'`,
    ).bind(revokedSpace.id).first<{ count: number }>())?.count).toBe(0);
    expect((await signedFetch("/v2/window-name", "GET", revokedSpace.owner)).status)
      .toBe(410);

    const cleanupSpace = await seedActiveSpace();
    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      cleanupSpace.owner,
      await windowNameBody(cleanupSpace, 0),
    )).status).toBe(200);
    await testEnv.DB.prepare(
      "DELETE FROM moment_spaces WHERE space_id = ?",
    ).bind(cleanupSpace.id).run();
    expect(await testEnv.DB.prepare(
      "SELECT space_id FROM moment_window_names WHERE space_id = ?",
    ).bind(cleanupSpace.id).first()).toBeNull();
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM idempotency_records
        WHERE space_id = ? AND operation = 'put-window-name'`,
    ).bind(cleanupSpace.id).first<{ count: number }>())?.count).toBe(0);
  });

  it("does not alter existing moment reservation, delivery, or ciphertext access", async () => {
    const space = await seedActiveSpace();
    expect((await signedFetch(
      "/v2/window-name",
      "PUT",
      space.owner,
      await windowNameBody(space, 0),
    )).status).toBe(200);
    const published = await publish(space.owner);
    const changes = await signedFetch("/v2/moments/changes", "GET", space.invitee);
    expect(changes.status).toBe(200);
    expect((await changes.json<{ changes: unknown[] }>()).changes).toHaveLength(1);
    const download = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/ciphertext`,
      "GET",
      space.invitee,
    );
    expect(download.status).toBe(200);
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(published.ciphertext);
    expect((await testEnv.DB.prepare(
      "SELECT state FROM moments WHERE id = ?",
    ).bind(published.reservation.moment.id).first<{ state: string }>())?.state)
      .toBe("committed");
  });
});

describe("append-only encrypted moments", () => {
  it("reserves, immutably uploads, snapshots recipients, changes, downloads and ACKs", async () => {
    const space = await seedActiveSpace();
    const thirdParticipantID = await addFutureParticipant(space.id);
    const published = await publish(space.owner);
    expect(published.reservation.protocolVersion).toBe(2);
    expect(published.reservation.moment.senderParticipantId).toBe(space.owner.id);
    expect(published.reservation.moment.senderDeviceId).toBe(space.owner.id);
    expect(published.commit.recipientCount).toBe(2);

    // A retry that raced the commit reconciles the immutable object and must
    // never enqueue deletion of live ciphertext.
    const uploadAfterCommit = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/ciphertext`,
      "PUT",
      space.owner,
      published.ciphertext,
    );
    expect(uploadAfterCommit.status).toBe(200);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moment_object_deletions WHERE owner_id = ?",
    ).bind(published.reservation.moment.id).first<{ count: number }>())?.count).toBe(0);

    const fourthParticipantID = await addFutureParticipant(space.id);
    const changesResponse = await signedFetch("/v2/moments/changes", "GET", space.invitee);
    expect(changesResponse.status).toBe(200);
    const changes = await changesResponse.json<{
      changes: Array<{
        cursor: string;
        type: string;
        moment: {
          id: string;
          clientMomentId: string;
          deliveryState: string;
          ciphertextSHA256: string;
        };
      }>;
      nextCursor: string;
    }>();
    expect(changes.changes).toHaveLength(1);
    expect(changes.changes[0]?.type).toBe("momentCommitted");
    expect(changes.changes[0]?.moment.clientMomentId)
      .toBe(published.reservation.moment.clientMomentId);
    expect(changes.changes[0]?.moment.deliveryState).toBe("pending");
    const emptyPage = await signedFetch(
      `/v2/moments/changes/${changes.nextCursor}`,
      "GET",
      space.invitee,
    );
    expect(emptyPage.status).toBe(200);
    expect((await emptyPage.json<{ changes: unknown[] }>()).changes).toEqual([]);

    const download = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/ciphertext`,
      "GET",
      space.invitee,
    );
    expect(download.status).toBe(200);
    expect(download.headers.get("cache-control")).toContain("no-store");
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(published.ciphertext);

    const ack = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/ack`,
      "POST",
      space.invitee,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        ciphertextSHA256: changes.changes[0]?.moment.ciphertextSHA256,
      },
    );
    expect(ack.status).toBe(200);
    expect((await ack.json<{ delivery: { state: string } }>()).delivery.state)
      .toBe("acknowledged");

    const senderChangesResponse = await signedFetch(
      "/v2/moments/changes",
      "GET",
      space.owner,
    );
    expect(senderChangesResponse.status).toBe(200);
    const senderChanges = await senderChangesResponse.json<{
      changes: Array<{
        type: string;
        moment: {
          id: string;
          clientMomentId: string;
          deliveryState: string;
        };
      }>;
      nextCursor: string;
    }>();
    expect(senderChanges.changes).toHaveLength(1);
    expect(senderChanges.changes[0]?.type).toBe("momentCommitted");
    expect(senderChanges.changes[0]?.moment.id)
      .toBe(published.reservation.moment.id);
    expect(senderChanges.changes[0]?.moment.clientMomentId)
      .toBe(published.reservation.moment.clientMomentId);
    expect(senderChanges.changes[0]?.moment.deliveryState).toBe("acknowledged");

    const repeatedAck = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/ack`,
      "POST",
      space.invitee,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        ciphertextSHA256: changes.changes[0]?.moment.ciphertextSHA256,
      },
    );
    expect(repeatedAck.status).toBe(200);
    const senderChangesAfterRepeatedAck = await signedFetch(
      `/v2/moments/changes/${senderChanges.nextCursor}`,
      "GET",
      space.owner,
    );
    expect(senderChangesAfterRepeatedAck.status).toBe(200);
    expect((await senderChangesAfterRepeatedAck.json<{ changes: unknown[] }>()).changes)
      .toEqual([]);
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM moment_changes
        WHERE participant_id = ? AND change_type = 'moment_committed' AND moment_id = ?`,
    ).bind(
      space.owner.id,
      published.reservation.moment.id,
    ).first<{ count: number }>())?.count).toBe(1);

    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM moment_deliveries
        WHERE moment_id = ? AND recipient_participant_id = ?`,
    ).bind(
      published.reservation.moment.id,
      thirdParticipantID,
    ).first<{ count: number }>())?.count).toBe(1);
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM moment_deliveries
        WHERE moment_id = ? AND recipient_participant_id = ?`,
    ).bind(
      published.reservation.moment.id,
      fourthParticipantID,
    ).first<{ count: number }>())?.count).toBe(0);
  });

  it("fails closed on moderation and policy versions, preserves idempotency, and enforces quota", async () => {
    expect(MOMENT_CLEANUP_OBJECT_LIMIT * 24 * 12).toBeGreaterThan(
      10_000 * (5 * MOMENT_RESERVATION_ATTEMPT_LIMIT + 10),
    );
    expect(3 * Math.ceil(10_000 / MOMENT_REVOKED_SCOPE_LIMIT) * 5)
      .toBeLessThanOrEqual(17 * 60);
    const space = await seedActiveSpace();
    const ciphertext = crypto.getRandomValues(new Uint8Array(128));
    const rejectedModeration = await reserve(space.owner, ciphertext, {
      clientModerationVersion: 99,
    });
    expect(rejectedModeration.response.status).toBe(409);
    const rejectedPolicy = await reserve(space.owner, ciphertext, {
      senderPolicyAcceptance: { version: 99, acceptedAt: new Date().toISOString() },
    });
    expect(rejectedPolicy.response.status).toBe(409);
    const oversized = await reserve(space.owner, ciphertext, {
      ciphertextSize: 1024 * 1024 + 1,
    });
    expect(oversized.response.status).toBe(400);

    const first = await reserve(space.owner, ciphertext);
    expect(first.response.status).toBe(201);
    const firstJSON = await first.response.json<ReservationResponse>();
    const replay = await signedFetch("/v2/moments/reservations", "POST", space.owner, first.body);
    expect(replay.status).toBe(201);
    expect((await replay.json<ReservationResponse>()).moment.id).toBe(firstJSON.moment.id);
    for (let index = 0; index < 4; index += 1) {
      expect((await reserve(space.owner, ciphertext)).response.status).toBe(201);
    }
    const overQuota = await reserve(space.owner, ciphertext);
    expect(overQuota.response.status).toBe(429);
    const usage = await testEnv.DB.prepare(
      "SELECT reserved_count, committed_count FROM moment_daily_usage WHERE participant_id = ?",
    ).bind(space.owner.id).first<{ reserved_count: number; committed_count: number }>();
    expect(usage).toEqual({ reserved_count: 5, committed_count: 0 });
  });

  it("re-reserves an exact expired draft and rejects the old upload and commit IDs", async () => {
    const space = await seedActiveSpace();
    const ciphertext = crypto.getRandomValues(new Uint8Array(256));
    const first = await reserve(space.owner, ciphertext);
    expect(first.response.status).toBe(201);
    const firstJSON = await first.response.json<ReservationResponse>();
    const uploaded = await signedFetch(
      `/v2/moments/${firstJSON.moment.id}/ciphertext`,
      "PUT",
      space.owner,
      ciphertext,
    );
    expect(uploaded.status).toBe(200);

    await runMomentCleanup(testEnv, firstJSON.moment.uploadExpiresAt + 1);
    const expiredUpload = await signedFetch(
      `/v2/moments/${firstJSON.moment.id}/ciphertext`,
      "PUT",
      space.owner,
      ciphertext,
    );
    expect(expiredUpload.status).toBe(410);
    expect((await expiredUpload.json<{ error: { code: string } }>()).error.code)
      .toBe("reservation_expired");
    const expiredCommit = await signedFetch(
      `/v2/moments/${firstJSON.moment.id}/commit`,
      "POST",
      space.owner,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(expiredCommit.status).toBe(410);
    expect((await expiredCommit.json<{ error: { code: string } }>()).error.code)
      .toBe("reservation_expired");

    const retried = await signedFetch(
      "/v2/moments/reservations",
      "POST",
      space.owner,
      first.body,
    );
    expect(retried.status).toBe(201);
    const retriedJSON = await retried.json<ReservationResponse>();
    expect(retriedJSON.moment.id).not.toBe(firstJSON.moment.id);
    expect(retriedJSON.moment.clientMomentId).toBe(firstJSON.moment.clientMomentId);
    expect(retriedJSON.quota.used).toBe(1);
    const replay = await signedFetch(
      "/v2/moments/reservations",
      "POST",
      space.owner,
      first.body,
    );
    expect(replay.status).toBe(201);
    expect((await replay.json<ReservationResponse>()).moment.id).toBe(retriedJSON.moment.id);
    const usage = await testEnv.DB.prepare(
      "SELECT reserved_count, committed_count FROM moment_daily_usage WHERE participant_id = ?",
    ).bind(space.owner.id).first<{ reserved_count: number; committed_count: number }>();
    expect(usage).toEqual({ reserved_count: 1, committed_count: 0 });

    await runMomentCleanup(testEnv, retriedJSON.moment.uploadExpiresAt + 1);
    const third = await signedFetch(
      "/v2/moments/reservations",
      "POST",
      space.owner,
      first.body,
    );
    expect(third.status).toBe(201);
    const thirdJSON = await third.json<ReservationResponse>();
    expect(thirdJSON.moment.id).not.toBe(retriedJSON.moment.id);
    expect(thirdJSON.quota.used).toBe(1);
    await runMomentCleanup(testEnv, thirdJSON.moment.uploadExpiresAt + 1);
    const exhausted = await signedFetch(
      "/v2/moments/reservations",
      "POST",
      space.owner,
      first.body,
    );
    expect(exhausted.status).toBe(429);
    expect((await exhausted.json<{ error: { code: string } }>()).error.code)
      .toBe("reservation_retry_limit_exceeded");
  });

  it("makes a directional block revoke access, rotate the key epoch, and prevent new delivery", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const block = await signedFetch(
      `/v2/participants/${space.invitee.id}/block`,
      "POST",
      space.owner,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(block.status).toBe(200);
    const blockJSON = await block.json<{
      revokedDeliveryCount: number;
      requiredKeyEpoch: number;
    }>();
    expect(blockJSON.revokedDeliveryCount).toBe(1);
    expect(blockJSON.requiredKeyEpoch).toBe(2);
    const delivery = await testEnv.DB.prepare(
      `SELECT state FROM moment_deliveries
        WHERE moment_id = ? AND recipient_participant_id = ?`,
    ).bind(published.reservation.moment.id, space.invitee.id).first<{ state: string }>();
    expect(delivery?.state).toBe("revoked");
    const denied = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/ciphertext`,
      "GET",
      space.invitee,
    );
    expect(denied.status).toBe(410);
    const deniedChanges = await signedFetch("/v2/moments/changes", "GET", space.invitee);
    expect(deniedChanges.status).toBe(410);
    const deniedChangesJSON = await deniedChanges.json<{
      error: { code: string; reportOnlyUntil: number };
    }>();
    expect(deniedChangesJSON.error.code).toBe("report_only");
    expect(deniedChangesJSON.error.reportOnlyUntil).toBeGreaterThan(
      Math.floor(Date.now() / 1000) + 86_000,
    );
    expect((await signedFetch("/v1/sharing/sources", "GET", space.invitee)).status).toBe(410);
    expect((await testEnv.DB.prepare(
      "SELECT state FROM members WHERE id = ?",
    ).bind(space.invitee.id).first<{ state: string }>())?.state).toBe("revoked");
    const staleEpoch = await reserve(space.owner, published.ciphertext);
    expect(staleEpoch.response.status).toBe(409);
    const currentEpochButBlocked = await reserve(space.owner, published.ciphertext, { keyEpoch: 2 });
    expect(currentEpochButBlocked.response.status).toBe(409);
  });

  it("binds an additional reporting device to its member and signing key", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const primary = await testEnv.DB.prepare(
      `SELECT participant.id AS participant_id, device.id AS device_id
         FROM moment_participants AS participant
         JOIN moment_devices AS device
           ON device.participant_id = participant.id
          AND device.legacy_member_id = ?
        WHERE participant.legacy_member_id = ?`,
    ).bind(space.invitee.id, space.invitee.id).first<{
      participant_id: string;
      device_id: string;
    }>();
    expect(primary).not.toBeNull();
    if (primary === null) throw new Error("missing primary invitee device");

    const additionalKeys = await signingKeys();
    const additionalDeviceID = randomValue(16);
    const now = Math.floor(Date.now() / 1_000);
    await testEnv.DB.prepare(
      `INSERT INTO moment_devices(
         id, participant_id, legacy_member_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, NULL, ?, ?, 'active', ?, ?)`,
    ).bind(
      additionalDeviceID,
      primary.participant_id,
      randomValue(32),
      await signingPublicKey(additionalKeys),
      now,
      now,
    ).run();

    const reportCiphertext = crypto.getRandomValues(new Uint8Array(384));
    const reportRequest = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      momentId: published.reservation.moment.id,
      reasonCode: "privacy",
      moderationKeyId: "moderation-v1",
      ciphertextSize: reportCiphertext.length,
      ciphertextSHA256: await sha256Base64url(reportCiphertext),
      reporterConsent: { version: 1, acceptedAt: new Date().toISOString() },
    };
    const additionalDevice = {
      id: space.invitee.id,
      keys: additionalKeys,
      deviceID: additionalDeviceID,
    };
    const reserved = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      additionalDevice,
      reportRequest,
    );
    expect(reserved.status).toBe(201);

    const wrongDevice = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      { ...additionalDevice, deviceID: primary.device_id },
      { ...reportRequest, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(wrongDevice.status).toBe(401);
    expect((await wrongDevice.json<{ error: { code: string } }>()).error.code)
      .toBe("invalid_authentication");
  });

  it("stores a separately encrypted moderation report and removes it at its short TTL", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const revoke = await signedFetch(
      "/v1/pairing/revoke",
      "POST",
      space.owner,
      { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(revoke.status).toBe(202);
    const deletionJob = await testEnv.DB.prepare(
      "SELECT created_at FROM space_deletion_jobs WHERE space_id = ?",
    ).bind(space.id).first<{ created_at: number }>();
    expect(deletionJob).not.toBeNull();
    await runScheduledCleanup(testEnv, (deletionJob?.created_at ?? 0) + 601);
    await runScheduledCleanup(testEnv, (deletionJob?.created_at ?? 0) + 3_700);
    await runScheduledCleanup(testEnv, (deletionJob?.created_at ?? 0) + 3_762);
    expect(await testEnv.DB.prepare("SELECT id FROM spaces WHERE id = ?")
      .bind(space.id).first()).toBeNull();
    // The same signature is now a report-only credential. It cannot enter
    // normal v2 media/change routes or any legacy v1 route.
    expect((await signedFetch("/v2/moments/changes", "GET", space.invitee)).status).toBe(401);
    expect((await reserve(space.invitee, published.ciphertext)).response.status).toBe(401);
    expect((await signedFetch("/v1/sharing/sources", "GET", space.invitee)).status).toBe(401);
    const reportCiphertext = crypto.getRandomValues(new Uint8Array(384));
    const reportHash = await sha256Base64url(reportCiphertext);
    const reportRequest = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      momentId: published.reservation.moment.id,
      reasonCode: "privacy",
      moderationKeyId: "moderation-v1",
      ciphertextSize: reportCiphertext.length,
      ciphertextSHA256: reportHash,
      reporterConsent: { version: 1, acceptedAt: new Date().toISOString() },
    };
    const staleSweepProof = Math.floor(Date.now() / 1000) - 120;
    await testEnv.DB.prepare(
      `UPDATE moment_storage_scopes
          SET report_empty_sweep_started_at = ?, report_sweep_completed_at = ?
        WHERE space_id = ?`,
    ).bind(staleSweepProof, staleSweepProof + 60, space.id).run();
    const reserveReport = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      reportRequest,
    );
    expect(reserveReport.status).toBe(201);
    expect(await testEnv.DB.prepare(
      `SELECT report_empty_sweep_started_at, report_sweep_completed_at
         FROM moment_storage_scopes WHERE space_id = ?`,
    ).bind(space.id).first()).toEqual({
      report_empty_sweep_started_at: null,
      report_sweep_completed_at: null,
    });
    const report = await reserveReport.json<{
      report: { id: string; state: string; uploadExpiresAt: number };
    }>();
    const replayedReport = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      reportRequest,
    );
    expect(replayedReport.status).toBe(201);
    expect((await replayedReport.json<{ report: { id: string } }>()).report.id)
      .toBe(report.report.id);
    const deduplicated = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      { ...reportRequest, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(deduplicated.status).toBe(200);
    const deduplicatedJSON = await deduplicated.json<{
      report: { id: string };
      alreadyReported: boolean;
    }>();
    expect(deduplicatedJSON.alreadyReported).toBe(true);
    expect(deduplicatedJSON.report.id).toBe(report.report.id);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moment_reports WHERE moment_id = ?",
    ).bind(published.reservation.moment.id).first<{ count: number }>())?.count).toBe(1);
    const upload = await signedFetch(
      `/v2/reports/${report.report.id}/ciphertext`,
      "PUT",
      space.invitee,
      reportCiphertext,
    );
    expect(upload.status).toBe(200);
    const commit = await signedFetch(
      `/v2/reports/${report.report.id}/commit`,
      "POST",
      space.invitee,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(commit.status).toBe(201);
    const committed = await commit.json<{
      report: { committedAt: number; contentExpiresAt: number };
    }>();
    expect(await testEnv.DB.prepare(
      `SELECT committed_at, review_due_at
         FROM moderation_cases WHERE report_id = ?`,
    ).bind(report.report.id).first()).toEqual({
      committed_at: committed.report.committedAt,
      review_due_at: committed.report.committedAt + 172_800,
    });
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moderation_case_events WHERE report_id = ?",
    ).bind(report.report.id).first<{ count: number }>())?.count).toBe(0);
    const row = await testEnv.DB.prepare(
      "SELECT object_key FROM moment_reports WHERE id = ?",
    ).bind(report.report.id).first<{ object_key: string }>();
    expect(row).not.toBeNull();
    expect(row?.object_key).not.toContain(`/moments/${published.reservation.moment.id}`);
    expect(await testEnv.MODERATION_MEDIA?.head(row?.object_key ?? "missing")).not.toBeNull();
    expect(await testEnv.MEDIA?.head(row?.object_key ?? "missing")).toBeNull();
    const past = Math.floor(Date.now() / 1000) - 1;
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        "UPDATE moment_participants SET report_only_until = ? WHERE id = ?",
      ).bind(past, space.invitee.id),
      testEnv.DB.prepare(
        "UPDATE moment_devices SET report_only_until = ? WHERE participant_id = ?",
      ).bind(past, space.invitee.id),
    ]);
    const closedWindow = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      { ...reportRequest, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(closedWindow.status).toBe(410);
    expect((await closedWindow.json<{ error: { code: string } }>()).error.code)
      .toBe("report_window_closed");
    await runMomentCleanup(testEnv, committed.report.contentExpiresAt - 1);
    expect(await testEnv.MODERATION_MEDIA?.head(row?.object_key ?? "missing")).not.toBeNull();
    expect((await testEnv.DB.prepare(
      "SELECT state FROM moment_reports WHERE id = ?",
    ).bind(report.report.id).first<{ state: string }>())?.state).toBe("committed");
    await runMomentCleanup(testEnv, committed.report.contentExpiresAt + 1);
    expect(await testEnv.MODERATION_MEDIA?.head(row?.object_key ?? "missing")).toBeNull();
    expect((await testEnv.DB.prepare(
      "SELECT state FROM moment_reports WHERE id = ?",
    ).bind(report.report.id).first<{ state: string }>())?.state).toBe("deleted");
    const tombstone = await testEnv.DB.prepare(
      `SELECT content_deleted_at FROM moment_report_tombstones WHERE report_id = ?`,
    ).bind(report.report.id).first<{ content_deleted_at: number | null }>();
    expect(tombstone?.content_deleted_at).toBe(committed.report.contentExpiresAt + 1);
    await runMomentCleanup(testEnv, committed.report.contentExpiresAt + 62);
    expect(await testEnv.DB.prepare("SELECT space_id FROM moment_spaces WHERE space_id = ?")
      .bind(space.id).first()).toBeNull();
    expect(await testEnv.DB.prepare("SELECT id FROM moment_reports WHERE id = ?")
      .bind(report.report.id).first()).toBeNull();
    expect(await testEnv.DB.prepare(
      "SELECT report_id FROM moment_report_tombstones WHERE report_id = ?",
    ).bind(report.report.id).first()).not.toBeNull();
    expect(await testEnv.DB.prepare(
      "SELECT report_id FROM moderation_cases WHERE report_id = ?",
    ).bind(report.report.id).first()).not.toBeNull();
  });

  it("accepts both reviewed moderation keys and binds retries and tombstones to the exact key", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const evidence = crypto.getRandomValues(new Uint8Array(256));
    const request = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      momentId: published.reservation.moment.id,
      reasonCode: "privacy",
      moderationKeyId: "moderation-v2",
      ciphertextSize: evidence.length,
      ciphertextSHA256: await sha256Base64url(evidence),
      reporterConsent: { version: 1, acceptedAt: new Date().toISOString() },
    };

    for (const moderationKeyId of ["moderation-v3", " moderation-v2", "moderation-v2 "]) {
      const rejected = await signedFetch(
        "/v2/reports/reservations",
        "POST",
        space.invitee,
        { ...request, clientRequestId: crypto.randomUUID().toLowerCase(), moderationKeyId },
      );
      expect(rejected.status).toBe(409);
      expect((await rejected.json<{ error: { code: string } }>()).error.code)
        .toBe("moderation_key_required");
    }
    const { moderationKeyId: _omitted, ...missingKeyRequest } = request;
    const missing = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      { ...missingKeyRequest, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(missing.status).toBe(400);
    expect((await missing.json<{ error: { code: string } }>()).error.code)
      .toBe("invalid_fields");

    const reserved = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      request,
    );
    expect(reserved.status).toBe(201);
    const report = await reserved.json<{
      report: { id: string; moderationKeyId: string };
    }>();
    expect(report.report.moderationKeyId).toBe("moderation-v2");

    const changedKeyReplay = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      { ...request, moderationKeyId: "moderation-v1" },
    );
    expect(changedKeyReplay.status).toBe(409);
    expect((await changedKeyReplay.json<{ error: { code: string } }>()).error.code)
      .toBe("idempotency_conflict");

    const changedKeyRetry = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      {
        ...request,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        moderationKeyId: "moderation-v1",
      },
    );
    expect(changedKeyRetry.status).toBe(409);
    expect((await changedKeyRetry.json<{ error: { code: string } }>()).error.code)
      .toBe("already_reported");

    expect((await signedFetch(
      `/v2/reports/${report.report.id}/ciphertext`,
      "PUT",
      space.invitee,
      evidence,
    )).status).toBe(200);
    expect((await signedFetch(
      `/v2/reports/${report.report.id}/commit`,
      "POST",
      space.invitee,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    )).status).toBe(201);
    expect(await testEnv.DB.prepare(
      `SELECT report.moderation_key_id AS report_key,
              tombstone.moderation_key_id AS tombstone_key
         FROM moment_reports AS report
         JOIN moment_report_tombstones AS tombstone ON tombstone.report_id = report.id
        WHERE report.id = ?`,
    ).bind(report.report.id).first()).toEqual({
      report_key: "moderation-v2",
      tombstone_key: "moderation-v2",
    });
  });

  it("minimizes committed report metadata after evidence deletion while retaining opaque dedupe", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const evidence = crypto.getRandomValues(new Uint8Array(192));
    const request = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      momentId: published.reservation.moment.id,
      reasonCode: "other",
      moderationKeyId: "moderation-v1",
      ciphertextSize: evidence.length,
      ciphertextSHA256: await sha256Base64url(evidence),
      reporterConsent: { version: 1, acceptedAt: new Date().toISOString() },
    };
    const reserved = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      request,
    );
    expect(reserved.status).toBe(201);
    const firstReport = await reserved.json<{
      report: { id: string; uploadExpiresAt: number };
    }>();
    expect((await signedFetch(
      `/v2/reports/${firstReport.report.id}/ciphertext`,
      "PUT",
      space.invitee,
      evidence,
    )).status).toBe(200);
    await runMomentCleanup(testEnv, firstReport.report.uploadExpiresAt + 1);
    const expiredUpload = await signedFetch(
      `/v2/reports/${firstReport.report.id}/ciphertext`,
      "PUT",
      space.invitee,
      evidence,
    );
    expect(expiredUpload.status).toBe(410);
    expect((await expiredUpload.json<{ error: { code: string } }>()).error.code)
      .toBe("reservation_expired");
    const expiredCommit = await signedFetch(
      `/v2/reports/${firstReport.report.id}/commit`,
      "POST",
      space.invitee,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(expiredCommit.status).toBe(410);
    const replacement = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      request,
    );
    expect(replacement.status).toBe(201);
    const report = await replacement.json<{ report: { id: string } }>();
    expect(report.report.id).not.toBe(firstReport.report.id);
    expect((await signedFetch(
      `/v2/reports/${report.report.id}/ciphertext`,
      "PUT",
      space.invitee,
      evidence,
    )).status).toBe(200);
    const commit = await signedFetch(
      `/v2/reports/${report.report.id}/commit`,
      "POST",
      space.invitee,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(commit.status).toBe(201);
    const committed = await commit.json<{ report: { contentExpiresAt: number } }>();
    await runMomentCleanup(testEnv, committed.report.contentExpiresAt + 1);
    await runMomentCleanup(testEnv, committed.report.contentExpiresAt + 172_802);
    expect(await testEnv.DB.prepare("SELECT id FROM moment_reports WHERE id = ?")
      .bind(report.report.id).first()).toBeNull();
    expect(await testEnv.DB.prepare("SELECT report_id FROM moment_report_tombstones WHERE report_id = ?")
      .bind(report.report.id).first()).not.toBeNull();
    expect((await testEnv.DB.prepare("SELECT state FROM moment_spaces WHERE space_id = ?")
      .bind(space.id).first<{ state: string }>())?.state).toBe("active");
    const duplicate = await signedFetch(
      "/v2/reports/reservations",
      "POST",
      space.invitee,
      { ...request, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(duplicate.status).toBe(409);
    expect((await duplicate.json<{ error: { code: string } }>()).error.code)
      .toBe("already_reported");
  });
});

describe("notification outbox route wiring", () => {
  it("creates recipient delivery rows from the real commit and new-heart routes", async () => {
    const space = await seedActiveSpace();
    const now = Math.floor(Date.now() / 1_000);
    const participants = await testEnv.DB.prepare(
      `SELECT member.id AS member_id, participant.id AS participant_id, device.id AS device_id
         FROM members AS member
         JOIN moment_participants AS participant ON participant.legacy_member_id = member.id
         JOIN moment_devices AS device ON device.participant_id = participant.id
        WHERE member.id IN (?, ?)
        ORDER BY member.id ASC`,
    ).bind(space.owner.id, space.invitee.id).all<{
      member_id: string;
      participant_id: string;
      device_id: string;
    }>();
    expect(participants.results).toHaveLength(2);
    await testEnv.DB.batch(participants.results.map((row) => testEnv.DB.prepare(
      `INSERT INTO apns_subscriptions(
         device_id, participant_id, environment,
         token_ciphertext, token_nonce, token_digest, encryption_key_id,
         created_at, updated_at, expires_at
       ) VALUES (?, ?, 'production', ?, ?, ?, 'test-key', ?, ?, ?)`,
    ).bind(
      row.device_id,
      row.participant_id,
      randomValue(48),
      randomValue(12),
      randomValue(32),
      now,
      now,
      now + 86_400,
    )));

    const notificationEnv = {
      ...testEnv,
      MOMENT_RUNTIME_ENABLED: "YES",
      REACTION_RUNTIME_ENABLED: "YES",
      APNS_RUNTIME_ENABLED: "YES",
    } as Env;
    const ciphertext = crypto.getRandomValues(new Uint8Array(768));
    const reservationRequest = await signedRequest(
      "/v2/moments/reservations",
      "POST",
      space.owner,
      reserveBody(ciphertext, {
        ciphertextSHA256: await sha256Base64url(ciphertext),
      }),
    );
    const reservationResponse = await route(reservationRequest, notificationEnv);
    expect(reservationResponse.status).toBe(201);
    const reservation = await reservationResponse.json<ReservationResponse>();
    expect((await route(
      await signedRequest(
        `/v2/moments/${reservation.moment.id}/ciphertext`,
        "PUT",
        space.owner,
        ciphertext,
      ),
      notificationEnv,
    )).status).toBe(200);
    expect((await route(
      await signedRequest(
        `/v2/moments/${reservation.moment.id}/commit`,
        "POST",
        space.owner,
        { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
      ),
      notificationEnv,
    )).status).toBe(201);

    const momentEvent = await testEnv.DB.prepare(
      `SELECT event.kind, event.participant_id, COUNT(delivery.device_id) AS delivery_count
         FROM notification_events AS event
         LEFT JOIN notification_deliveries AS delivery ON delivery.event_id = event.id
        WHERE event.moment_id = ?
        GROUP BY event.id, event.kind, event.participant_id`,
    ).bind(reservation.moment.id).first<{
      kind: string;
      participant_id: string;
      delivery_count: number;
    }>();
    const invitee = participants.results.find((row) => row.member_id === space.invitee.id);
    expect(momentEvent).toEqual({
      kind: "new_moment",
      participant_id: invitee?.participant_id,
      delivery_count: 1,
    });

    const heartResponse = await route(
      await signedRequest(
        `/v2/moments/${reservation.moment.id}/reactions`,
        "POST",
        space.invitee,
        { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase(), kind: "paw" },
      ),
      notificationEnv,
    );
    expect(heartResponse.status).toBe(201);
    const heart = await heartResponse.json<{ reaction: { id: string } }>();
    const heartEvent = await testEnv.DB.prepare(
      `SELECT event.kind, event.participant_id, COUNT(delivery.device_id) AS delivery_count
         FROM notification_events AS event
         LEFT JOIN notification_deliveries AS delivery ON delivery.event_id = event.id
        WHERE event.reaction_id = ?
        GROUP BY event.id, event.kind, event.participant_id`,
    ).bind(heart.reaction.id).first<{
      kind: string;
      participant_id: string;
      delivery_count: number;
    }>();
    const owner = participants.results.find((row) => row.member_id === space.owner.id);
    expect(heartEvent).toEqual({
      kind: "heart",
      participant_id: owner?.participant_id,
      delivery_count: 1,
    });
  });
});

describe("bounded paw reactions", () => {
  function pawBody(clientRequestId = crypto.randomUUID().toLowerCase()): Record<string, unknown> {
    return { protocolVersion: 2, clientRequestId, kind: "paw" };
  }

  it("records one paw, preserves exact idempotency, and exposes a separate sender-only feed", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const momentID = published.reservation.moment.id;
    const body = pawBody();

    const created = await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.invitee,
      body,
    );
    expect(created.status).toBe(201);
    const first = await created.json<{
      protocolVersion: number;
      reaction: { id: string; momentId: string; kind: string };
      alreadyReacted: boolean;
    }>();
    expect(first).toEqual({
      protocolVersion: 2,
      reaction: {
        id: first.reaction.id,
        momentId: momentID,
        kind: "paw",
      },
      alreadyReacted: false,
    });
    expect(Object.keys(first).sort()).toEqual([
      "alreadyReacted",
      "protocolVersion",
      "reaction",
    ]);
    expect(Object.keys(first.reaction).sort()).toEqual(["id", "kind", "momentId"]);

    const exactReplay = await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.invitee,
      body,
    );
    expect(exactReplay.status).toBe(201);
    expect(await exactReplay.json()).toEqual(first);

    const duplicate = await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.invitee,
      pawBody(),
    );
    expect(duplicate.status).toBe(200);
    expect(await duplicate.json()).toEqual({ ...first, alreadyReacted: true });

    // Model an event created without any registered physical-device delivery.
    // A successful cursor read may remove that empty event tomb, while the
    // multi-device case below proves that another iPhone's delivery survives.
    const now = Math.floor(Date.now() / 1_000);
    await testEnv.DB.prepare(
      `INSERT INTO notification_events(
         id, kind, participant_id, moment_id, reaction_id, created_at, expires_at
       ) VALUES (?, 'heart', ?, NULL, ?, ?, ?)`,
    ).bind(
      randomValue(16),
      space.owner.id,
      first.reaction.id,
      now,
      now + 86_400,
    ).run();

    const senderChangesResponse = await signedFetch(
      "/v2/reactions/changes",
      "GET",
      space.owner,
    );
    expect(senderChangesResponse.status).toBe(200);
    const senderChanges = await senderChangesResponse.json<{
      protocolVersion: number;
      changes: Array<{
        cursor: string;
        type: string;
        reaction: { id: string; momentId: string; kind: string };
      }>;
      nextCursor: string;
    }>();
    expect(senderChanges.protocolVersion).toBe(2);
    expect(senderChanges.changes).toEqual([{
      cursor: senderChanges.nextCursor,
      type: "pawReceived",
      reaction: { id: first.reaction.id, momentId: momentID, kind: "paw" },
    }]);
    expect(Object.keys(senderChanges.changes[0] ?? {}).sort())
      .toEqual(["cursor", "reaction", "type"]);
    expect(Object.keys(senderChanges.changes[0]?.reaction ?? {}).sort())
      .toEqual(["id", "kind", "momentId"]);
    expect(await testEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE reaction_id = ?",
    ).bind(first.reaction.id).first()).toBeNull();

    const emptySenderPage = await signedFetch(
      `/v2/reactions/changes/${senderChanges.nextCursor}`,
      "GET",
      space.owner,
    );
    expect(emptySenderPage.status).toBe(200);
    expect((await emptySenderPage.json<{ changes: unknown[] }>()).changes).toEqual([]);
    const reactorFeed = await signedFetch(
      "/v2/reactions/changes",
      "GET",
      space.invitee,
    );
    expect(reactorFeed.status).toBe(200);
    expect((await reactorFeed.json<{ changes: unknown[] }>()).changes).toEqual([]);

    const originalMomentFeed = await signedFetch(
      "/v2/moments/changes",
      "GET",
      space.invitee,
    );
    expect(originalMomentFeed.status).toBe(200);
    const momentChanges = await originalMomentFeed.json<{
      changes: Array<{ type: string; moment: { id: string } }>;
    }>();
    expect(momentChanges.changes).toHaveLength(1);
    expect(momentChanges.changes[0]).toMatchObject({
      type: "momentCommitted",
      moment: { id: momentID },
    });
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moment_reactions WHERE moment_id = ?",
    ).bind(momentID).first<{ count: number }>())?.count).toBe(1);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM reaction_changes WHERE reaction_id = ?",
    ).bind(first.reaction.id).first<{ count: number }>())?.count).toBe(1);
    expect((await testEnv.DB.prepare(
      `SELECT reaction_count FROM moment_reaction_daily_usage
        WHERE participant_id = ?`,
    ).bind(space.invitee.id).first<{ reaction_count: number }>())?.reaction_count).toBe(1);
  });

  it("acknowledges a heart alert only for the requesting physical device", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const created = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/reactions`,
      "POST",
      space.invitee,
      pawBody(),
    );
    expect(created.status).toBe(201);
    const reactionID = (await created.json<{ reaction: { id: string } }>()).reaction.id;

    const primary = await testEnv.DB.prepare(
      `SELECT participant.id AS participant_id, device.id AS device_id
         FROM moment_participants AS participant
         JOIN moment_devices AS device
           ON device.participant_id = participant.id
          AND device.legacy_member_id = ?
        WHERE participant.legacy_member_id = ?`,
    ).bind(space.owner.id, space.owner.id).first<{
      participant_id: string;
      device_id: string;
    }>();
    expect(primary).not.toBeNull();

    const now = Math.floor(Date.now() / 1_000);
    const additionalKeys = await signingKeys();
    const additionalDeviceID = randomValue(16);
    const primaryDigest = randomValue(32);
    const additionalDigest = randomValue(32);
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        `INSERT INTO moment_devices(
           id, participant_id, legacy_member_id, agreement_public_key,
           signing_public_key, state, created_at, activated_at
         ) VALUES (?, ?, NULL, ?, ?, 'active', ?, ?)`,
      ).bind(
        additionalDeviceID,
        primary?.participant_id,
        randomValue(32),
        await signingPublicKey(additionalKeys),
        now,
        now,
      ),
      ...[
        [primary?.device_id, primaryDigest],
        [additionalDeviceID, additionalDigest],
      ].map(([deviceID, digest]) => testEnv.DB.prepare(
        `INSERT INTO apns_subscriptions(
           device_id, participant_id, environment,
           token_ciphertext, token_nonce, token_digest, encryption_key_id,
           created_at, updated_at, expires_at
         ) VALUES (?, ?, 'production', ?, ?, ?, 'test-key', ?, ?, ?)`,
      ).bind(
        deviceID,
        primary?.participant_id,
        randomValue(48),
        randomValue(12),
        digest,
        now,
        now,
        now + 86_400,
      )),
      testEnv.DB.prepare(
        `INSERT INTO notification_events(
           id, kind, participant_id, moment_id, reaction_id, created_at, expires_at
         ) VALUES (?, 'heart', ?, NULL, ?, ?, ?)`,
      ).bind(
        randomValue(16),
        primary?.participant_id,
        reactionID,
        now,
        now + 86_400,
      ),
    ]);
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM notification_deliveries AS delivery
         JOIN notification_events AS event ON event.id = delivery.event_id
        WHERE event.reaction_id = ?`,
    ).bind(reactionID).first<{ count: number }>()).toEqual({ count: 2 });

    const additionalChanges = await signedFetch(
      "/v2/reactions/changes",
      "GET",
      { id: space.owner.id, keys: additionalKeys, deviceID: additionalDeviceID },
    );
    expect(additionalChanges.status).toBe(200);
    expect((await additionalChanges.json<{ changes: unknown[] }>()).changes).toHaveLength(1);
    expect(await testEnv.DB.prepare(
      `SELECT delivery.token_digest
         FROM notification_deliveries AS delivery
         JOIN notification_events AS event ON event.id = delivery.event_id
        WHERE event.reaction_id = ?`,
    ).bind(reactionID).all<{ token_digest: string }>()).toMatchObject({
      results: [{ token_digest: primaryDigest }],
    });
    expect(await testEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE reaction_id = ?",
    ).bind(reactionID).first()).not.toBeNull();

    const primaryChanges = await signedFetch(
      "/v2/reactions/changes",
      "GET",
      space.owner,
    );
    expect(primaryChanges.status).toBe(200);
    expect((await primaryChanges.json<{ changes: unknown[] }>()).changes).toHaveLength(1);
    expect(await testEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE reaction_id = ?",
    ).bind(reactionID).first()).toBeNull();
  });

  it("acknowledges a moment alert only for the requesting physical device", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const momentID = published.reservation.moment.id;
    const primary = await testEnv.DB.prepare(
      `SELECT participant.id AS participant_id, device.id AS device_id
         FROM moment_participants AS participant
         JOIN moment_devices AS device
           ON device.participant_id = participant.id
          AND device.legacy_member_id = ?
        WHERE participant.legacy_member_id = ?`,
    ).bind(space.invitee.id, space.invitee.id).first<{
      participant_id: string;
      device_id: string;
    }>();
    expect(primary).not.toBeNull();

    const now = Math.floor(Date.now() / 1_000);
    const additionalKeys = await signingKeys();
    const additionalDeviceID = randomValue(16);
    const primaryDigest = randomValue(32);
    const additionalDigest = randomValue(32);
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        `INSERT INTO moment_devices(
           id, participant_id, legacy_member_id, agreement_public_key,
           signing_public_key, state, created_at, activated_at
         ) VALUES (?, ?, NULL, ?, ?, 'active', ?, ?)`,
      ).bind(
        additionalDeviceID,
        primary?.participant_id,
        randomValue(32),
        await signingPublicKey(additionalKeys),
        now,
        now,
      ),
      ...[
        [primary?.device_id, primaryDigest],
        [additionalDeviceID, additionalDigest],
      ].map(([deviceID, digest]) => testEnv.DB.prepare(
        `INSERT INTO apns_subscriptions(
           device_id, participant_id, environment,
           token_ciphertext, token_nonce, token_digest, encryption_key_id,
           created_at, updated_at, expires_at
         ) VALUES (?, ?, 'production', ?, ?, ?, 'test-key', ?, ?, ?)`,
      ).bind(
        deviceID,
        primary?.participant_id,
        randomValue(48),
        randomValue(12),
        digest,
        now,
        now,
        now + 86_400,
      )),
      testEnv.DB.prepare(
        `INSERT INTO notification_events(
           id, kind, participant_id, moment_id, reaction_id, created_at, expires_at
         ) VALUES (?, 'new_moment', ?, ?, NULL, ?, ?)`,
      ).bind(
        randomValue(16),
        primary?.participant_id,
        momentID,
        now,
        now + 86_400,
      ),
    ]);
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM notification_deliveries AS delivery
         JOIN notification_events AS event ON event.id = delivery.event_id
        WHERE event.moment_id = ?`,
    ).bind(momentID).first<{ count: number }>()).toEqual({ count: 2 });

    const acknowledgeBody = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      ciphertextSHA256: published.reservation.moment.ciphertextSHA256,
    };
    expect((await signedFetch(
      `/v2/moments/${momentID}/ack`,
      "POST",
      { id: space.invitee.id, keys: additionalKeys, deviceID: additionalDeviceID },
      acknowledgeBody,
    )).status).toBe(200);
    expect(await testEnv.DB.prepare(
      `SELECT delivery.token_digest
         FROM notification_deliveries AS delivery
         JOIN notification_events AS event ON event.id = delivery.event_id
        WHERE event.moment_id = ?`,
    ).bind(momentID).all<{ token_digest: string }>()).toMatchObject({
      results: [{ token_digest: primaryDigest }],
    });
    expect(await testEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE moment_id = ?",
    ).bind(momentID).first()).not.toBeNull();

    expect((await signedFetch(
      `/v2/moments/${momentID}/ack`,
      "POST",
      space.invitee,
      { ...acknowledgeBody, clientRequestId: crypto.randomUUID().toLowerCase() },
    )).status).toBe(200);
    expect(await testEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE moment_id = ?",
    ).bind(momentID).first()).toBeNull();
  });

  it("accepts an acknowledged delivery, rejects self and expired access, and consumes replayed nonces", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const momentID = published.reservation.moment.id;

    const changesResponse = await signedFetch(
      "/v2/moments/changes",
      "GET",
      space.invitee,
    );
    const changes = await changesResponse.json<{
      changes: Array<{ moment: { ciphertextSHA256: string } }>;
    }>();
    expect((await signedFetch(
      `/v2/moments/${momentID}/ack`,
      "POST",
      space.invitee,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        ciphertextSHA256: changes.changes[0]?.moment.ciphertextSHA256,
      },
    )).status).toBe(200);

    const nonce = randomValue(16);
    const body = pawBody();
    expect((await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.invitee,
      body,
      nonce,
    )).status).toBe(201);
    const replayedNonce = await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.invitee,
      body,
      nonce,
    );
    expect(replayedNonce.status).toBe(409);
    expect((await replayedNonce.json<{ error: { code: string } }>()).error.code)
      .toBe("replayed_request");

    const self = await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.owner,
      pawBody(),
    );
    expect(self.status).toBe(403);
    expect((await self.json<{ error: { code: string } }>()).error.code)
      .toBe("self_reaction_not_allowed");

    const expiredSpace = await seedActiveSpace();
    const expired = await publish(expiredSpace.owner);
    await testEnv.DB.prepare(
      `UPDATE moment_deliveries SET access_expires_at = ?
        WHERE moment_id = ? AND recipient_participant_id = ?`,
    ).bind(
      Math.floor(Date.now() / 1000) - 1,
      expired.reservation.moment.id,
      expiredSpace.invitee.id,
    ).run();
    const denied = await signedFetch(
      `/v2/moments/${expired.reservation.moment.id}/reactions`,
      "POST",
      expiredSpace.invitee,
      pawBody(),
    );
    expect(denied.status).toBe(410);
    expect((await denied.json<{ error: { code: string } }>()).error.code)
      .toBe("reaction_not_allowed");
  });

  it("enforces the daily quota without charging duplicates", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      `INSERT INTO moment_reaction_daily_usage(
         participant_id, day_key, reaction_count, updated_at
       ) VALUES (?, ?, 30, ?)`,
    ).bind(space.invitee.id, Math.floor(now / 86_400), now).run();
    const denied = await signedFetch(
      `/v2/moments/${published.reservation.moment.id}/reactions`,
      "POST",
      space.invitee,
      pawBody(),
    );
    expect(denied.status).toBe(429);
    expect((await denied.json<{ error: { code: string } }>()).error.code)
      .toBe("reaction_daily_quota_reached");

    const oldDay = Math.floor(now / 86_400) - REACTION_USAGE_RETENTION_DAYS - 1;
    const boundaryDay = Math.floor(now / 86_400) - REACTION_USAGE_RETENTION_DAYS;
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        `INSERT INTO moment_reaction_daily_usage(
           participant_id, day_key, reaction_count, updated_at
         ) VALUES (?, ?, 1, ?)`,
      ).bind(space.invitee.id, oldDay, now),
      testEnv.DB.prepare(
        `INSERT INTO moment_reaction_daily_usage(
           participant_id, day_key, reaction_count, updated_at
         ) VALUES (?, ?, 1, ?)`,
      ).bind(space.invitee.id, boundaryDay, now),
    ]);
    await runMomentCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      `SELECT day_key FROM moment_reaction_daily_usage
        WHERE participant_id = ? AND day_key = ?`,
    ).bind(space.invitee.id, oldDay).first()).toBeNull();
    expect(await testEnv.DB.prepare(
      `SELECT day_key FROM moment_reaction_daily_usage
        WHERE participant_id = ? AND day_key = ?`,
    ).bind(space.invitee.id, boundaryDay).first()).not.toBeNull();
  });

  it("removes reaction state and replay records when delivery trust is revoked", async () => {
    const space = await seedActiveSpace();
    const published = await publish(space.owner);
    const momentID = published.reservation.moment.id;
    const created = await signedFetch(
      `/v2/moments/${momentID}/reactions`,
      "POST",
      space.invitee,
      pawBody(),
    );
    expect(created.status).toBe(201);
    const reactionID = (await created.json<{ reaction: { id: string } }>()).reaction.id;
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moment_reactions WHERE moment_id = ?",
    ).bind(momentID).first<{ count: number }>())?.count).toBe(1);

    const consumed = await signedFetch(
      "/v2/reactions/changes",
      "GET",
      space.owner,
    );
    expect(consumed.status).toBe(200);
    const consumedCursor = (await consumed.json<{ nextCursor: string }>()).nextCursor;
    expect(consumedCursor).not.toBe("");

    const block = await signedFetch(
      `/v2/participants/${space.invitee.id}/block`,
      "POST",
      space.owner,
      { protocolVersion: 2, clientRequestId: crypto.randomUUID().toLowerCase() },
    );
    expect(block.status).toBe(200);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM moment_reactions WHERE moment_id = ?",
    ).bind(momentID).first<{ count: number }>())?.count).toBe(0);
    expect((await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM reaction_changes WHERE reaction_id = ?",
    ).bind(reactionID).first<{ count: number }>())?.count).toBe(0);
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM reaction_changes
        WHERE cursor = ? AND reaction_id IS NULL AND created_at IS NOT NULL`,
    ).bind(consumedCursor).first<{ count: number }>())?.count).toBe(1);
    expect((await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM idempotency_records
        WHERE operation = 'post-paw-reaction' AND space_id = ?`,
    ).bind(space.id).first<{ count: number }>())?.count).toBe(0);
    const afterDeletedCursor = await signedFetch(
      `/v2/reactions/changes/${consumedCursor}`,
      "GET",
      space.owner,
    );
    expect(afterDeletedCursor.status).toBe(200);
    expect((await afterDeletedCursor.json<{ changes: unknown[] }>()).changes).toEqual([]);
  });
});
