import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import { base64urlEncode, sha256Base64url } from "../src/encoding";
import type { Env } from "../src/env";
import worker, { route } from "../src/index";
import {
  APNS_ADDITIVE_PROTOCOL_VERSION,
  APNS_DRAIN_CRON,
  APNS_SUBSCRIPTION_TTL_SECONDS,
  drainNotificationOutbox,
  momentNotificationEventStatements,
  reactionNotificationEventStatements,
} from "../src/push";
import { signedRequestTranscript } from "../src/protocol";

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

interface Fixture {
  spaceID: string;
  ownerID: string;
  ownerKeys: KeyPair;
  inviteeID: string;
  inviteeKeys: KeyPair;
}

const databaseEnv = env as unknown as Env;

function buffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

function randomValue(count: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(count));
  return base64urlEncode(bytes);
}

async function ed25519Keys(): Promise<KeyPair> {
  return crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  ) as Promise<KeyPair>;
}

async function publicKeyValue(keys: KeyPair): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
}

async function sign(keys: KeyPair, message: Uint8Array): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign(
    { name: "Ed25519" },
    keys.privateKey,
    buffer(message),
  )));
}

async function signedRequest(
  path: string,
  method: "PUT" | "DELETE",
  memberID: string,
  keys: KeyPair,
  payload: unknown,
  deviceID?: string,
): Promise<Request> {
  const body = JSON.stringify(payload);
  const bodyBytes = new TextEncoder().encode(body);
  const timestamp = Math.floor(Date.now() / 1_000);
  const nonce = randomValue(16);
  const signature = await sign(keys, signedRequestTranscript({
    memberId: memberID,
    timestamp,
    nonce,
    method,
    pathname: path,
    bodySHA256: await sha256Base64url(bodyBytes),
  }));
  const headers = new Headers({
    "Content-Type": "application/json",
    "CF-Connecting-IP": "192.0.2.190",
    "Neko-Protocol-Version": "1",
    "Neko-Member-ID": memberID,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
  });
  if (deviceID !== undefined) headers.set("Neko-Device-ID", deviceID);
  return new Request(`https://sharing.invalid${path}`, {
    method,
    headers,
    body,
  });
}

async function seedFixture(): Promise<Fixture> {
  const now = Math.floor(Date.now() / 1_000);
  const ownerKeys = await ed25519Keys();
  const inviteeKeys = await ed25519Keys();
  const spaceID = randomValue(16);
  const ownerID = randomValue(16);
  const inviteeID = randomValue(16);
  await databaseEnv.DB.batch([
    databaseEnv.DB.prepare(
      `INSERT INTO spaces(
         id, creation_request_id, protocol_version, daily_boundary_minute_utc,
         state, created_at, last_activity_at, metadata_expires_at
       ) VALUES (?, ?, 1, 0, 'active', ?, ?, ?)`,
    ).bind(spaceID, crypto.randomUUID().toLowerCase(), now, now, now + 2_592_000),
    databaseEnv.DB.prepare(
      `INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, 'owner', ?, ?, ?, 'active', ?, ?)`,
    ).bind(
      ownerID,
      spaceID,
      randomValue(16),
      randomValue(32),
      await publicKeyValue(ownerKeys),
      now,
      now,
    ),
    databaseEnv.DB.prepare(
      `INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, 'invitee', ?, ?, ?, 'active', ?, ?)`,
    ).bind(
      inviteeID,
      spaceID,
      randomValue(16),
      randomValue(32),
      await publicKeyValue(inviteeKeys),
      now,
      now,
    ),
  ]);
  return { spaceID, ownerID, ownerKeys, inviteeID, inviteeKeys };
}

function pem(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary);
  const lines = encoded.match(/.{1,64}/gu) ?? [];
  return `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----`;
}

async function pushEnv(): Promise<Env> {
  const providerKeys = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  ) as KeyPair;
  const privateKey = new Uint8Array(await crypto.subtle.exportKey("pkcs8", providerKeys.privateKey));
  return {
    ...databaseEnv,
    APNS_RUNTIME_ENABLED: "YES",
    APNS_PROVIDER_CREDENTIAL_JSON: JSON.stringify({
      keyId: "A1B2C3D4E5",
      teamId: "Z9Y8X7W6V5",
      bundleId: "jp.example.NekoWidget",
      environment: "production",
      privateKey: pem(privateKey),
    }),
    APNS_TOKEN_KEYRING_JSON: JSON.stringify({
      current: "key-1",
      keys: { "key-1": randomValue(32) },
    }),
  };
}

async function seedCommittedMoment(
  fixture: Fixture,
  now: number,
  senderID = fixture.ownerID,
  recipientID = fixture.inviteeID,
): Promise<string> {
  const momentID = randomValue(16);
  await databaseEnv.DB.batch([
    databaseEnv.DB.prepare(
      `INSERT INTO moments(
         id, client_moment_id, space_id, sender_participant_id,
         sender_device_id, kind, key_epoch, state, object_key,
         ciphertext_size, ciphertext_sha256, client_moderation_version,
         sender_policy_version, sender_policy_accepted_at, quota_day_key,
         quota_counted, reservation_attempt, reserve_request_hash,
         created_at, upload_expires_at, uploaded_at, committed_at,
         unreceived_expires_at, closed_at
       ) VALUES (
         ?, ?, ?, ?, ?, 'live', 1, 'committed', ?,
         64, ?, 1, 1, ?, ?, 0, 1, ?,
         ?, ?, ?, ?, ?, NULL
       )`,
    ).bind(
      momentID,
      crypto.randomUUID().toLowerCase(),
      fixture.spaceID,
      senderID,
      senderID,
      `v2/test/${momentID}`,
      randomValue(32),
      now,
      Math.floor(now / 86_400),
      randomValue(32),
      now - 10,
      now + 300,
      now - 5,
      now,
      now + 30 * 86_400,
    ),
    databaseEnv.DB.prepare(
      `INSERT INTO moment_deliveries(
         moment_id, recipient_participant_id, state, created_at, access_expires_at
       ) VALUES (?, ?, 'pending', ?, ?)`,
    ).bind(momentID, recipientID, now, now + 30 * 86_400),
  ]);
  return momentID;
}

describe("APNs durable notification delivery", () => {
  it("rejects legacy protocol bodies at the additive subscription boundary", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();

    await expect(route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        {
          protocolVersion: 2,
          token: randomValue(32),
          environment: "production",
        },
      ),
      configuredEnv,
    )).rejects.toMatchObject({ status: 400, code: "unsupported_protocol" });

    await expect(route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "DELETE",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2 },
      ),
      configuredEnv,
    )).rejects.toMatchObject({ status: 400, code: "unsupported_protocol" });
  });

  it("authenticates and consumes a signed registration nonce before failing closed", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const request = await signedRequest(
      "/v2/push-subscriptions/current",
      "PUT",
      fixture.inviteeID,
      fixture.inviteeKeys,
      { protocolVersion: 2, token: randomValue(32), environment: "production" },
    );
    const replay = request.clone();
    await expect(route(request, { ...configuredEnv, APNS_RUNTIME_ENABLED: "NO" })).rejects
      .toMatchObject({ status: 503, code: "apns_runtime_disabled" });
    await expect(route(replay as unknown as Request, configuredEnv)).rejects
      .toMatchObject({ status: 409, code: "replayed_request" });
  });

  it("binds an encrypted renewable token and dispatches a generic alert with an opaque target", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
    const token = base64urlEncode(tokenBytes);
    const put = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    );
    expect(put.status).toBe(200);
    await expect(put.json()).resolves.toEqual({
      protocolVersion: 2,
      subscription: { state: "active" },
    });

    const subscription = await databaseEnv.DB.prepare(
      `SELECT device_id, participant_id, token_ciphertext, token_digest,
              updated_at, expires_at, route_schema_version
         FROM apns_subscriptions WHERE device_id = ?`,
    ).bind(fixture.inviteeID).first<{
      device_id: string;
      participant_id: string;
      token_ciphertext: string;
      token_digest: string;
      updated_at: number;
      expires_at: number;
      route_schema_version: number;
    }>();
    expect(subscription).not.toBeNull();
    expect(subscription?.device_id).toBe(fixture.inviteeID);
    expect(subscription?.participant_id).toBe(fixture.inviteeID);
    expect(subscription?.token_ciphertext).not.toContain(token);
    expect(subscription?.token_digest).toBe(await sha256Base64url(tokenBytes));
    expect(subscription?.route_schema_version).toBe(1);
    expect((subscription?.expires_at ?? 0) - (subscription?.updated_at ?? 0))
      .toBe(APNS_SUBSCRIPTION_TTL_SECONDS);

    const now = Math.floor(Date.now() / 1_000);
    const momentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(momentNotificationEventStatements(configuredEnv, momentID, now));

    let requestURL = "";
    let requestHeaders = new Headers();
    let requestPayload = "";
    const drained = await drainNotificationOutbox(
      configuredEnv,
      now,
      async (input, init) => {
        requestURL = String(input);
        requestHeaders = new Headers(init?.headers);
        requestPayload = String(init?.body ?? "");
        return new Response(null, { status: 200 });
      },
    );
    expect(drained).toMatchObject({ leased: 1, accepted: 1, invalidated: 0 });
    expect(requestURL).toBe(
      `https://api.push.apple.com/3/device/${[...tokenBytes]
        .map((byte) => byte.toString(16).padStart(2, "0")).join("")}`,
    );
    expect(requestHeaders.get("apns-topic")).toBe("jp.example.NekoWidget");
    expect(requestHeaders.get("apns-push-type")).toBe("alert");
    expect(requestHeaders.get("apns-priority")).toBe("10");
    expect(requestHeaders.get("authorization")).toMatch(/^bearer [^.]+\.[^.]+\.[^.]+$/u);
    expect(requestPayload).toContain("新しい一枚が届きました");
    expect(JSON.parse(requestPayload)).toEqual({
      aps: {
        alert: { title: "ねこのまど", body: "新しい一枚が届きました。" },
        "content-available": 1,
      },
      neko: { v: 1, kind: "new_moment" },
      nekoTarget: {
        v: 1,
        spaceId: fixture.spaceID,
        momentId: momentID,
      },
    });
    expect(requestPayload).not.toContain(fixture.ownerID);
    expect(requestPayload).not.toContain(fixture.inviteeID);
    expect(requestPayload).not.toContain(token);
    expect(await databaseEnv.DB.prepare(
      "SELECT state FROM notification_deliveries WHERE device_id = ?",
    ).bind(fixture.inviteeID).first<{ state: string }>()).toEqual({ state: "accepted" });

    const heartMomentID = await seedCommittedMoment(
      fixture,
      now + 1,
      fixture.inviteeID,
      fixture.ownerID,
    );
    const reactionID = randomValue(16);
    await databaseEnv.DB.batch([
      databaseEnv.DB.prepare(
        `INSERT INTO moment_reactions(
           id, moment_id, space_id, reactor_participant_id,
           recipient_participant_id, kind, quota_day_key, created_at
         ) VALUES (?, ?, ?, ?, ?, 'paw', ?, ?)`,
      ).bind(
        reactionID,
        heartMomentID,
        fixture.spaceID,
        fixture.ownerID,
        fixture.inviteeID,
        Math.floor((now + 1) / 86_400),
        now + 1,
      ),
      ...reactionNotificationEventStatements(
        configuredEnv,
        reactionID,
        fixture.inviteeID,
        now + 1,
      ),
    ]);
    let heartPayload = "";
    const heartDrain = await drainNotificationOutbox(
      configuredEnv,
      now + 1,
      async (_input, init) => {
        heartPayload = String(init?.body ?? "");
        return new Response(null, { status: 200 });
      },
    );
    expect(heartDrain).toMatchObject({ leased: 1, accepted: 1 });
    expect(JSON.parse(heartPayload)).toEqual({
      aps: {
        alert: { title: "ねこのまど", body: "届けた写真にハートが届きました。" },
        "content-available": 1,
      },
      neko: { v: 1, kind: "heart" },
      nekoTarget: {
        v: 1,
        spaceId: fixture.spaceID,
        momentId: heartMomentID,
      },
    });
    expect(heartPayload).not.toContain(reactionID);
    expect(heartPayload).not.toContain(fixture.ownerID);
    expect(heartPayload).not.toContain(fixture.inviteeID);
    expect(heartPayload).not.toContain(token);

    const acknowledgedMomentID = await seedCommittedMoment(fixture, now + 2);
    await databaseEnv.DB.batch(
      momentNotificationEventStatements(configuredEnv, acknowledgedMomentID, now + 2),
    );
    await databaseEnv.DB.prepare(
      `UPDATE moment_deliveries
          SET state = 'acknowledged', acknowledged_at = ?
        WHERE moment_id = ? AND recipient_participant_id = ?`,
    ).bind(now + 3, acknowledgedMomentID, fixture.inviteeID).run();
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE moment_id = ?",
    ).bind(acknowledgedMomentID).first()).not.toBeNull();
    // Participant-scoped delivery state cannot identify which physical iPhone
    // synchronized. The signed ACK route performs device-scoped cleanup; this
    // direct-SQL fixture removes its rows only to isolate the following drain.
    await databaseEnv.DB.prepare(
      `DELETE FROM notification_deliveries
        WHERE event_id IN (
          SELECT id FROM notification_events WHERE moment_id = ?
        )`,
    ).bind(acknowledgedMomentID).run();
    await databaseEnv.DB.prepare(
      "DELETE FROM notification_events WHERE moment_id = ?",
    ).bind(acknowledgedMomentID).run();

    const secondMomentID = await seedCommittedMoment(fixture, now + 3);
    await databaseEnv.DB.batch(
      momentNotificationEventStatements(configuredEnv, secondMomentID, now + 3),
    );
    const invalidated = await drainNotificationOutbox(
      configuredEnv,
      now + 3,
      async () => new Response(JSON.stringify({ reason: "Unregistered" }), {
        status: 410,
        headers: { "Content-Type": "application/json" },
      }),
    );
    expect(invalidated.invalidated).toBe(1);
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM apns_subscriptions WHERE device_id = ?",
    ).bind(fixture.inviteeID).first()).toBeNull();

    const rePut = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    );
    expect(rePut.status).toBe(200);
    const deleted = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "DELETE",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2 },
      ),
      { ...configuredEnv, APNS_RUNTIME_ENABLED: "NO" },
    );
    expect(deleted.status).toBe(200);
    await expect(deleted.json()).resolves.toEqual({
      protocolVersion: 2,
      subscription: { state: "deleted" },
    });
  });

  it("does not turn historical foreground-synced events into alerts on first registration", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const now = Math.floor(Date.now() / 1_000);
    const historicalMomentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(
      momentNotificationEventStatements(configuredEnv, historicalMomentID, now),
    );
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_deliveries WHERE event_id IN (SELECT id FROM notification_events WHERE moment_id = ?)",
    ).bind(historicalMomentID).first()).toBeNull();

    const registered = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2, token: randomValue(32), environment: "production" },
      ),
      configuredEnv,
    );
    expect(registered.status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_deliveries WHERE event_id IN (SELECT id FROM notification_events WHERE moment_id = ?)",
    ).bind(historicalMomentID).first()).toBeNull();
  });

  it("does not resurrect pre-opt-out alerts when the same token registers again", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const token = randomValue(32);
    const registrationBody = {
      protocolVersion: 2,
      token,
      environment: "production",
    };
    expect((await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        registrationBody,
      ),
      configuredEnv,
    )).status).toBe(200);
    const now = Math.floor(Date.now() / 1_000);
    const momentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(
      momentNotificationEventStatements(configuredEnv, momentID, now),
    );
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_deliveries WHERE device_id = ?",
    ).bind(fixture.inviteeID).first()).not.toBeNull();

    expect((await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "DELETE",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2 },
      ),
      { ...configuredEnv, APNS_RUNTIME_ENABLED: "NO" },
    )).status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE moment_id = ?",
    ).bind(momentID).first()).toBeNull();
    expect((await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        registrationBody,
      ),
      configuredEnv,
    )).status).toBe(200);

    let requests = 0;
    const drained = await drainNotificationOutbox(
      configuredEnv,
      now + 1,
      async () => {
        requests += 1;
        return new Response(null, { status: 200 });
      },
    );
    expect(requests).toBe(0);
    expect(drained).toMatchObject({ leased: 0, accepted: 0 });
  });

  it("moves one physical token to the latest signed selected device", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const additionalKeys = await ed25519Keys();
    const additionalDeviceID = randomValue(16);
    const now = Math.floor(Date.now() / 1_000);
    await databaseEnv.DB.prepare(
      `INSERT INTO moment_devices(
         id, participant_id, legacy_member_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, NULL, ?, ?, 'active', ?, ?)`,
    ).bind(
      additionalDeviceID,
      fixture.inviteeID,
      randomValue(32),
      await publicKeyValue(additionalKeys),
      now,
      now,
    ).run();

    const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
    const token = base64urlEncode(tokenBytes);
    const firstResponse = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    );
    expect(firstResponse.status).toBe(200);
    const replacedMomentID = await seedCommittedMoment(fixture, now + 1);
    await databaseEnv.DB.batch(
      momentNotificationEventStatements(configuredEnv, replacedMomentID, now + 1),
    );
    expect(await databaseEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM notification_events WHERE moment_id = ?",
    ).bind(replacedMomentID).first<{ count: number }>()).toEqual({ count: 1 });

    const replacementResponse = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        additionalKeys,
        { protocolVersion: 2, token, environment: "production" },
        additionalDeviceID,
      ),
      configuredEnv,
    );
    expect(replacementResponse.status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM notification_events WHERE moment_id = ?",
    ).bind(replacedMomentID).first<{ count: number }>()).toEqual({ count: 0 });
    const digest = await sha256Base64url(tokenBytes);
    expect(await databaseEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM apns_subscriptions WHERE token_digest = ?",
    ).bind(digest).first<{ count: number }>()).toEqual({ count: 1 });
    expect(await databaseEnv.DB.prepare(
      "SELECT device_id FROM apns_subscriptions WHERE token_digest = ?",
    ).bind(digest).first<{ device_id: string }>()).toEqual({
      device_id: additionalDeviceID,
    });

    const momentID = await seedCommittedMoment(fixture, now + 2);
    await databaseEnv.DB.batch(
      momentNotificationEventStatements(configuredEnv, momentID, now + 2),
    );
    expect(await databaseEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM notification_deliveries WHERE token_digest = ?",
    ).bind(digest).first<{ count: number }>()).toEqual({ count: 1 });

    let requests = 0;
    const invalidated = await drainNotificationOutbox(
      configuredEnv,
      now + 2,
      async () => {
        requests += 1;
        return new Response(JSON.stringify({ reason: "Unregistered" }), {
          status: 410,
          headers: { "Content-Type": "application/json" },
        });
      },
    );
    expect(invalidated.invalidated).toBe(1);
    expect(requests).toBe(1);
    expect(await databaseEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM apns_subscriptions WHERE token_digest = ?",
    ).bind(digest).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await databaseEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM notification_deliveries WHERE token_digest = ?",
    ).bind(digest).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("keeps additive targeted bindings for every signed window and downgrades fail closed", async () => {
    const first = await seedFixture();
    const second = await seedFixture();
    const configuredEnv = await pushEnv();
    const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
    const token = base64urlEncode(tokenBytes);
    const digest = await sha256Base64url(tokenBytes);

    // Reproduce an installed v2 client. The first v3 registration removes
    // this generic-route binding before any additive targeted rows coexist.
    expect((await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        first.inviteeID,
        first.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    )).status).toBe(200);
    expect((await route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "PUT",
        second.inviteeID,
        second.inviteeKeys,
        {
          protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION,
          token,
          environment: "production",
        },
      ),
      configuredEnv,
    )).status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      `SELECT device_id, route_schema_version
         FROM apns_subscriptions WHERE token_digest = ?`,
    ).bind(digest).all<{ device_id: string; route_schema_version: number }>())
      .toMatchObject({
        results: [{
          device_id: second.inviteeID,
          route_schema_version: 2,
        }],
      });

    expect((await route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "PUT",
        first.inviteeID,
        first.inviteeKeys,
        {
          protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION,
          token,
          environment: "production",
        },
      ),
      configuredEnv,
    )).status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      `SELECT COUNT(*) AS count, MIN(route_schema_version) AS minimum,
              MAX(route_schema_version) AS maximum
         FROM apns_subscriptions WHERE token_digest = ?`,
    ).bind(digest).first<{
      count: number;
      minimum: number;
      maximum: number;
    }>()).toEqual({ count: 2, minimum: 2, maximum: 2 });

    const now = Math.floor(Date.now() / 1_000);
    const firstMomentID = await seedCommittedMoment(first, now);
    const secondMomentID = await seedCommittedMoment(second, now + 1);
    await databaseEnv.DB.batch([
      ...momentNotificationEventStatements(configuredEnv, firstMomentID, now),
      ...momentNotificationEventStatements(configuredEnv, secondMomentID, now + 1),
    ]);
    const payloads: Array<{
      neko: { v: number; kind: string };
      nekoTarget: { v: number; spaceId: string; momentId: string };
    }> = [];
    const drained = await drainNotificationOutbox(
      configuredEnv,
      now + 1,
      async (_input, init) => {
        payloads.push(JSON.parse(String(init?.body ?? "")) as typeof payloads[number]);
        return new Response(null, { status: 200 });
      },
    );
    expect(drained).toMatchObject({ leased: 2, accepted: 2 });
    expect(payloads).toHaveLength(2);
    expect(payloads.every((payload) => payload.neko.v === 2)).toBe(true);
    expect(new Set(payloads.map((payload) => payload.nekoTarget.spaceId)))
      .toEqual(new Set([first.spaceID, second.spaceID]));
    expect(new Set(payloads.map((payload) => payload.nekoTarget.momentId)))
      .toEqual(new Set([firstMomentID, secondMomentID]));

    const deleted = await route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "DELETE",
        first.inviteeID,
        first.inviteeKeys,
        { protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION },
      ),
      { ...configuredEnv, APNS_RUNTIME_ENABLED: "NO" },
    );
    expect(deleted.status).toBe(200);
    await expect(deleted.json()).resolves.toEqual({
      protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION,
      subscription: { state: "deleted" },
    });
    expect(await databaseEnv.DB.prepare(
      `SELECT device_id, route_schema_version
         FROM apns_subscriptions WHERE token_digest = ?`,
    ).bind(digest).first<{
      device_id: string;
      route_schema_version: number;
    }>()).toEqual({
      device_id: second.inviteeID,
      route_schema_version: 2,
    });

    // A downgraded v2 client restores the original selected-window-only
    // contract and its v1 route, removing every targeted sibling binding.
    expect((await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        first.inviteeID,
        first.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    )).status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      `SELECT device_id, route_schema_version
         FROM apns_subscriptions WHERE token_digest = ?`,
    ).bind(digest).all<{
      device_id: string;
      route_schema_version: number;
    }>()).toMatchObject({
      results: [{
        device_id: first.inviteeID,
        route_schema_version: 1,
      }],
    });
  });

  it("normalizes a rolled-back Worker UPSERT and restores the targeted route on v3 renewal", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const token = randomValue(32);
    expect((await route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        {
          protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION,
          token,
          environment: "production",
        },
      ),
      configuredEnv,
    )).status).toBe(200);

    const row = await databaseEnv.DB.prepare(
      `SELECT device_id, participant_id, environment,
              token_ciphertext, token_nonce, token_digest, encryption_key_id,
              created_at, updated_at, expires_at
         FROM apns_subscriptions WHERE device_id = ?`,
    ).bind(fixture.inviteeID).first<Record<string, string | number>>();
    expect(row).not.toBeNull();
    if (row === null) throw new Error("missing APNs fixture row");

    // This is the pre-0011 Worker UPSERT shape: it cannot name or update the
    // new route column. The migration trigger must still normalize the row.
    await databaseEnv.DB.prepare(
      `INSERT INTO apns_subscriptions(
         device_id, participant_id, environment,
         token_ciphertext, token_nonce, token_digest, encryption_key_id,
         created_at, updated_at, expires_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET
         participant_id = excluded.participant_id,
         environment = excluded.environment,
         token_ciphertext = excluded.token_ciphertext,
         token_nonce = excluded.token_nonce,
         token_digest = excluded.token_digest,
         encryption_key_id = excluded.encryption_key_id,
         updated_at = excluded.updated_at,
         expires_at = excluded.expires_at`,
    ).bind(
      row.device_id,
      row.participant_id,
      row.environment,
      row.token_ciphertext,
      row.token_nonce,
      row.token_digest,
      row.encryption_key_id,
      row.created_at,
      row.updated_at,
      row.expires_at,
    ).run();
    expect(await databaseEnv.DB.prepare(
      "SELECT route_schema_version FROM apns_subscriptions WHERE device_id = ?",
    ).bind(fixture.inviteeID).first()).toEqual({ route_schema_version: 1 });

    expect((await route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        {
          protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION,
          token,
          environment: "production",
        },
      ),
      configuredEnv,
    )).status).toBe(200);
    expect(await databaseEnv.DB.prepare(
      "SELECT route_schema_version FROM apns_subscriptions WHERE device_id = ?",
    ).bind(fixture.inviteeID).first()).toEqual({ route_schema_version: 2 });
  });

  it.each([
    {
      initialPath: "/v2/push-subscriptions/current",
      initialVersion: 2,
      replacementPath: "/v3/push-subscriptions/current",
      replacementVersion: 3,
    },
    {
      initialPath: "/v3/push-subscriptions/current",
      initialVersion: 3,
      replacementPath: "/v2/push-subscriptions/current",
      replacementVersion: 2,
    },
  ])("does not send a leased row after its route schema changes ($initialVersion -> $replacementVersion)", async ({
    initialPath,
    initialVersion,
    replacementPath,
    replacementVersion,
  }) => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const token = randomValue(32);
    expect((await route(
      await signedRequest(
        initialPath,
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: initialVersion, token, environment: "production" },
      ),
      configuredEnv,
    )).status).toBe(200);

    const now = Math.floor(Date.now() / 1_000);
    const momentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(momentNotificationEventStatements(configuredEnv, momentID, now));
    let requests = 0;
    const drained = await drainNotificationOutbox(
      configuredEnv,
      now,
      async () => {
        requests += 1;
        return new Response(null, { status: 200 });
      },
      {
        afterLease: async () => {
          expect((await route(
            await signedRequest(
              replacementPath,
              "PUT",
              fixture.inviteeID,
              fixture.inviteeKeys,
              {
                protocolVersion: replacementVersion,
                token,
                environment: "production",
              },
            ),
            configuredEnv,
          )).status).toBe(200);
        },
      },
    );
    expect(drained).toMatchObject({ leased: 1, accepted: 0, skipped: 1 });
    expect(requests).toBe(0);
    expect(await databaseEnv.DB.prepare(
      "SELECT route_schema_version FROM apns_subscriptions WHERE device_id = ?",
    ).bind(fixture.inviteeID).first()).toEqual({
      route_schema_version: replacementVersion === 3 ? 2 : 1,
    });
  });

  it("retries with the current route when the schema changes during APNs I/O", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const token = randomValue(32);
    expect((await route(
      await signedRequest(
        "/v3/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        {
          protocolVersion: APNS_ADDITIVE_PROTOCOL_VERSION,
          token,
          environment: "production",
        },
      ),
      configuredEnv,
    )).status).toBe(200);

    const now = Math.floor(Date.now() / 1_000);
    const momentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(momentNotificationEventStatements(configuredEnv, momentID, now));
    const routeVersions: number[] = [];
    const first = await drainNotificationOutbox(
      configuredEnv,
      now,
      async (_input, init) => {
        const payload = JSON.parse(String(init?.body ?? "")) as {
          neko: { v: number };
        };
        routeVersions.push(payload.neko.v);
        expect((await route(
          await signedRequest(
            "/v2/push-subscriptions/current",
            "PUT",
            fixture.inviteeID,
            fixture.inviteeKeys,
            { protocolVersion: 2, token, environment: "production" },
          ),
          configuredEnv,
        )).status).toBe(200);
        return new Response(null, { status: 200 });
      },
    );
    expect(first).toMatchObject({ leased: 1, accepted: 0, retried: 1 });
    expect(await databaseEnv.DB.prepare(
      `SELECT state, last_status, last_reason
         FROM notification_deliveries AS delivery
         JOIN notification_events AS event ON event.id = delivery.event_id
        WHERE event.moment_id = ?`,
    ).bind(momentID).first()).toEqual({
      state: "pending",
      last_status: 200,
      last_reason: "RouteChanged",
    });

    const second = await drainNotificationOutbox(
      configuredEnv,
      now,
      async (_input, init) => {
        const payload = JSON.parse(String(init?.body ?? "")) as {
          neko: { v: number };
        };
        routeVersions.push(payload.neko.v);
        return new Response(null, { status: 200 });
      },
    );
    expect(second).toMatchObject({ leased: 1, accepted: 1, retried: 0 });
    expect(routeVersions).toEqual([2, 1]);
  });

  it("rechecks a leased delivery before APNs when foreground sync removes it", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const token = randomValue(32);
    expect((await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    )).status).toBe(200);

    const now = Math.floor(Date.now() / 1_000);
    const momentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(momentNotificationEventStatements(configuredEnv, momentID, now));

    let requests = 0;
    const drained = await drainNotificationOutbox(
      configuredEnv,
      now,
      async () => {
        requests += 1;
        return new Response(null, { status: 200 });
      },
      {
        afterLease: async ({ eventID, deviceID }) => {
          // This is the same durable boundary used by foreground cursor/ack
          // cleanup: the delivery disappears after candidate read and lease.
          await databaseEnv.DB.batch([
            databaseEnv.DB.prepare(
              "DELETE FROM notification_deliveries WHERE event_id = ? AND device_id = ?",
            ).bind(eventID, deviceID),
            databaseEnv.DB.prepare(
              `DELETE FROM notification_events
                WHERE id = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM notification_deliveries AS delivery
                     WHERE delivery.event_id = notification_events.id
                  )`,
            ).bind(eventID),
          ]);
        },
      },
    );
    expect(drained).toMatchObject({ leased: 1, accepted: 0, skipped: 1 });
    expect(requests).toBe(0);
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM notification_events WHERE moment_id = ?",
    ).bind(momentID).first()).toBeNull();
  });

  it("does not let subscriptions from the other APNs environment consume the drain limit", async () => {
    const fixture = await seedFixture();
    const configuredEnv = await pushEnv();
    const token = randomValue(32);
    const registered = await route(
      await signedRequest(
        "/v2/push-subscriptions/current",
        "PUT",
        fixture.inviteeID,
        fixture.inviteeKeys,
        { protocolVersion: 2, token, environment: "production" },
      ),
      configuredEnv,
    );
    expect(registered.status).toBe(200);

    await databaseEnv.DB.prepare(
      "UPDATE apns_subscriptions SET environment = 'development' WHERE device_id = ?",
    ).bind(fixture.inviteeID).run();
    const now = Math.floor(Date.now() / 1_000);
    const momentID = await seedCommittedMoment(fixture, now);
    await databaseEnv.DB.batch(momentNotificationEventStatements(configuredEnv, momentID, now));

    let requests = 0;
    const mismatched = await drainNotificationOutbox(
      configuredEnv,
      now,
      async () => {
        requests += 1;
        return new Response(null, { status: 200 });
      },
    );
    expect(mismatched).toMatchObject({ leased: 0, accepted: 0 });
    expect(requests).toBe(0);
    expect(await databaseEnv.DB.prepare(
      "SELECT state FROM notification_deliveries WHERE device_id = ?",
    ).bind(fixture.inviteeID).first<{ state: string }>()).toEqual({ state: "pending" });

    // Switching back to the credential's environment makes the same durable
    // delivery eligible without recreating or mutating the notification event.
    await databaseEnv.DB.prepare(
      "UPDATE apns_subscriptions SET environment = 'production' WHERE device_id = ?",
    ).bind(fixture.inviteeID).run();
    const matched = await drainNotificationOutbox(
      configuredEnv,
      now,
      async () => {
        requests += 1;
        return new Response(null, { status: 200 });
      },
    );
    expect(matched).toMatchObject({ leased: 1, accepted: 1 });
    expect(requests).toBe(1);
  });

  it("expires stale registrations even while APNs dispatch is disabled", async () => {
    const fixture = await seedFixture();
    const now = Math.floor(Date.now() / 1_000);
    await databaseEnv.DB.prepare(
      `INSERT INTO apns_subscriptions(
         device_id, participant_id, environment,
         token_ciphertext, token_nonce, token_digest, encryption_key_id,
         created_at, updated_at, expires_at
       ) VALUES (?, ?, 'production', ?, ?, ?, 'test-key', ?, ?, ?)`,
    ).bind(
      fixture.inviteeID,
      fixture.inviteeID,
      randomValue(48),
      randomValue(12),
      randomValue(32),
      now - 100,
      now - 100,
      now + 1,
    ).run();
    await drainNotificationOutbox({ ...databaseEnv, APNS_RUNTIME_ENABLED: "NO" }, now + 2);
    expect(await databaseEnv.DB.prepare(
      "SELECT 1 AS present FROM apns_subscriptions WHERE device_id = ?",
    ).bind(fixture.inviteeID).first()).toBeNull();
  });

  it("wires only the exact every-minute APNs cron to the durable drain", async () => {
    const scheduled = worker.scheduled;
    expect(scheduled).toBeDefined();
    const scheduledEnv = {
      ...databaseEnv,
      APNS_RUNTIME_ENABLED: "NO",
      DB: {
        prepare() {
          return { bind() { return {}; } };
        },
        async batch() { return []; },
      },
    } as unknown as Env;
    const waits: Promise<unknown>[] = [];
    const context = {
      waitUntil(promise: Promise<unknown>) {
        waits.push(promise);
      },
    } as unknown as ExecutionContext;
    await scheduled?.(
      { cron: APNS_DRAIN_CRON } as unknown as ScheduledController,
      scheduledEnv,
      context,
    );
    expect(waits).toHaveLength(1);
    await Promise.all(waits);

    const ignoredWaits: Promise<unknown>[] = [];
    await scheduled?.(
      { cron: "0 * * * *" } as unknown as ScheduledController,
      scheduledEnv,
      {
        waitUntil(promise: Promise<unknown>) {
          ignoredWaits.push(promise);
        },
      } as unknown as ExecutionContext,
    );
    expect(ignoredWaits).toHaveLength(0);
  });
});
