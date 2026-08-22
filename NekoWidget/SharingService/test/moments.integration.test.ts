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
import { signedRequestTranscript } from "../src/protocol";
import { runScheduledCleanup } from "../src/scheduled";

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

describe("moment runtime kill switch", () => {
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
});

interface TestMember {
  id: string;
  keys: KeyPair;
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

const testEnv = env as unknown as Env;

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
    "CF-Connecting-IP": "192.0.2.88",
    "Neko-Protocol-Version": "1",
    "Neko-Member-ID": member.id,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
  });
  if (value !== undefined) {
    headers.set("Content-Type", binary ? "application/octet-stream" : "application/json");
  }
  const init: RequestInit = { method, headers };
  if (value !== undefined) init.body = binary ? bytes(bodyBytes) : new TextDecoder().decode(bodyBytes);
  return SELF.fetch(new Request(`https://sharing.invalid${path}`, init));
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
      report: { contentExpiresAt: number };
    }>();
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
