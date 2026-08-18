import { env } from "cloudflare:workers";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import apiFixture from "../../ci/fixtures/pairing-api-v1-responses.json";
import { base64urlEncode, sha256Base64url, verifyEd25519 } from "../src/encoding";
import type { Env } from "../src/env";
import { enforceRateLimit } from "../src/http";
import {
  approvalTranscript,
  creationTranscript,
  enrollmentTranscript,
  signedRequestTranscript,
} from "../src/protocol";
import {
  CLEANUP_IDEMPOTENCY_LIMIT,
  CLEANUP_NONCE_LIMIT,
  CLEANUP_SPACE_LIMIT,
  PAIRING_EXPIRY_CANDIDATES_SQL,
  runScheduledCleanup,
} from "../src/scheduled";

interface MemberResponse {
  id: string;
  participantId: string;
  agreementPublicKey: string;
  signingPublicKey: string;
}

interface CreateResponse {
  spaceId: string;
  member: MemberResponse;
  invitation: { id: string; expiresAt: number };
}

interface ChallengeResponse {
  spaceId: string;
  dailyBoundaryMinuteUTC: number;
  invitationId: string;
  challenge: { id: string; value: string; expiresAt: number };
  inviter: MemberResponse;
}

interface EnrollResponse {
  spaceId: string;
  member: MemberResponse;
  enrollment: {
    id: string;
    transcript: string;
    transcriptHash: string;
  };
}

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

function randomValue(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64urlEncode(value);
}

async function signingKeyPair(): Promise<KeyPair> {
  return crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  ) as Promise<KeyPair>;
}

async function publicKeyValue(keyPair: KeyPair): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey)));
}

async function sign(keyPair: KeyPair, bytes: Uint8Array): Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign(
    { name: "Ed25519" },
    keyPair.privateKey,
    arrayBuffer(bytes),
  )));
}

function jsonBody(value: unknown): string {
  return JSON.stringify(value);
}

function jsonShape(value: unknown): unknown {
  if (value === null) return null;
  if (Array.isArray(value)) return value.length === 0 ? [] : [jsonShape(value[0])];
  if (typeof value !== "object") return typeof value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, child]) => [key, jsonShape(child)]),
  );
}

function expectSameJSONShape(actual: unknown, expected: unknown): void {
  expect(jsonShape(actual)).toEqual(jsonShape(expected));
}

async function signedRequest(
  path: string,
  method: "GET" | "POST",
  memberId: string,
  keyPair: KeyPair,
  payload?: unknown,
  nonce = randomValue(16),
): Promise<Request> {
  const body = payload === undefined ? "" : jsonBody(payload);
  const timestamp = Math.floor(Date.now() / 1000);
  const bodyBytes = new TextEncoder().encode(body);
  const signature = await sign(keyPair, signedRequestTranscript({
    memberId,
    timestamp,
    nonce,
    method,
    pathname: path,
    bodySHA256: await sha256Base64url(bodyBytes),
  }));
  const headers = new Headers({
    "Neko-Protocol-Version": "1",
    "Neko-Member-ID": memberId,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
    "CF-Connecting-IP": "192.0.2.10",
  });
  if (payload !== undefined) headers.set("Content-Type", "application/json");
  const init: RequestInit = { method, headers };
  if (payload !== undefined) init.body = body;
  return new Request(`https://sharing.invalid${path}`, init);
}

const testEnv = env as unknown as Env;

async function createPairingFixture(): Promise<{
  ownerKeys: KeyPair;
  inviteProofKeys: KeyPair;
  createBody: string;
  create: CreateResponse;
  challenge: ChallengeResponse;
  inviteeKeys: KeyPair;
  inviteeParticipantId: string;
  inviteeAgreementPublicKey: string;
}> {
  const ownerKeys = await signingKeyPair();
  const inviteProofKeys = await signingKeyPair();
  const creationFields = {
    clientRequestId: crypto.randomUUID().toLowerCase(),
    participantId: randomValue(16),
    agreementPublicKey: randomValue(32),
    signingPublicKey: await publicKeyValue(ownerKeys),
    invitationProofPublicKey: await publicKeyValue(inviteProofKeys),
    dailyBoundaryMinuteUTC: 540,
  };
  const createBody = jsonBody({
    protocolVersion: 1,
    ...creationFields,
    creationSignature: await sign(ownerKeys, creationTranscript(creationFields)),
  });
  const createResponse = await SELF.fetch("https://sharing.invalid/v1/spaces", {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.10" },
    body: createBody,
  });
  expect(createResponse.status).toBe(201);
  expect(createResponse.headers.get("cache-control")).toContain("no-store");
  const create = await createResponse.json<CreateResponse>();
  expectSameJSONShape(create, apiFixture.create);

  const challengeResponse = await SELF.fetch(
    `https://sharing.invalid/v1/invitations/${create.invitation.id}/challenges`,
    { method: "POST", headers: { "CF-Connecting-IP": "192.0.2.11" } },
  );
  expect(challengeResponse.status).toBe(201);
  const challenge = await challengeResponse.json<ChallengeResponse>();
  expectSameJSONShape(challenge, apiFixture.challenge);
  const inviteeKeys = await signingKeyPair();
  return {
    ownerKeys,
    inviteProofKeys,
    createBody,
    create,
    challenge,
    inviteeKeys,
    inviteeParticipantId: randomValue(16),
    inviteeAgreementPublicKey: randomValue(32),
  };
}

async function enrollPairingFixture(
  fixture: Awaited<ReturnType<typeof createPairingFixture>>,
): Promise<EnrollResponse> {
  const clientRequestId = crypto.randomUUID().toLowerCase();
  const signingPublicKey = await publicKeyValue(fixture.inviteeKeys);
  const transcript = enrollmentTranscript({
    spaceId: fixture.challenge.spaceId,
    invitationId: fixture.challenge.invitationId,
    challengeId: fixture.challenge.challenge.id,
    challengeValue: fixture.challenge.challenge.value,
    challengeExpiresAt: fixture.challenge.challenge.expiresAt,
    clientRequestId,
    participantId: fixture.inviteeParticipantId,
    agreementPublicKey: fixture.inviteeAgreementPublicKey,
    signingPublicKey,
  });
  const body = {
    protocolVersion: 1,
    clientRequestId,
    challengeId: fixture.challenge.challenge.id,
    participantId: fixture.inviteeParticipantId,
    agreementPublicKey: fixture.inviteeAgreementPublicKey,
    signingPublicKey,
    inviteProofSignature: await sign(fixture.inviteProofKeys, transcript),
    participantSignature: await sign(fixture.inviteeKeys, transcript),
  };
  const response = await SELF.fetch(
    `https://sharing.invalid/v1/invitations/${fixture.create.invitation.id}/enrollments`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: jsonBody(body),
    },
  );
  expect(response.status).toBe(201);
  return response.json<EnrollResponse>();
}

describe("Phase 1 pairing Worker", () => {
  it("bypasses a missing rate limiter only in the explicit local environment", async () => {
    await expect(enforceRateLimit({ ...testEnv, ENVIRONMENT: "local" }, undefined, "test"))
      .resolves.toBeUndefined();
    await expect(enforceRateLimit({ ...testEnv, ENVIRONMENT: "prod" }, undefined, "test"))
      .rejects.toMatchObject({ status: 503, code: "rate_limiter_unavailable" });
    await expect(enforceRateLimit({ ...testEnv, ENVIRONMENT: "" }, undefined, "test"))
      .rejects.toMatchObject({ status: 503, code: "rate_limiter_unavailable" });
  });

  it("pairs two signed, space-specific identities and revokes them", async () => {
    const fixture = await createPairingFixture();
    const createRetry = await SELF.fetch("https://sharing.invalid/v1/spaces", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: fixture.createBody,
    });
    expect(createRetry.status).toBe(201);
    expect((await createRetry.json<CreateResponse>()).spaceId).toBe(fixture.create.spaceId);
    const clientRequestId = crypto.randomUUID().toLowerCase();
    const inviteeSigningPublicKey = await publicKeyValue(fixture.inviteeKeys);
    const enrollmentBytes = enrollmentTranscript({
      spaceId: fixture.challenge.spaceId,
      invitationId: fixture.challenge.invitationId,
      challengeId: fixture.challenge.challenge.id,
      challengeValue: fixture.challenge.challenge.value,
      challengeExpiresAt: fixture.challenge.challenge.expiresAt,
      clientRequestId,
      participantId: fixture.inviteeParticipantId,
      agreementPublicKey: fixture.inviteeAgreementPublicKey,
      signingPublicKey: inviteeSigningPublicKey,
    });

    const invalidEnrollBody = jsonBody({
      protocolVersion: 1,
      clientRequestId,
      challengeId: fixture.challenge.challenge.id,
      participantId: fixture.inviteeParticipantId,
      agreementPublicKey: fixture.inviteeAgreementPublicKey,
      signingPublicKey: inviteeSigningPublicKey,
      inviteProofSignature: randomValue(64),
      participantSignature: await sign(fixture.inviteeKeys, enrollmentBytes),
    });
    const invalidEnrollment = await SELF.fetch(
      `https://sharing.invalid/v1/invitations/${fixture.create.invitation.id}/enrollments`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: invalidEnrollBody },
    );
    expect(invalidEnrollment.status).toBe(401);

    const enrollBody = jsonBody({
      protocolVersion: 1,
      clientRequestId,
      challengeId: fixture.challenge.challenge.id,
      participantId: fixture.inviteeParticipantId,
      agreementPublicKey: fixture.inviteeAgreementPublicKey,
      signingPublicKey: inviteeSigningPublicKey,
      inviteProofSignature: await sign(fixture.inviteProofKeys, enrollmentBytes),
      participantSignature: await sign(fixture.inviteeKeys, enrollmentBytes),
    });
    const enrollmentResponse = await SELF.fetch(
      `https://sharing.invalid/v1/invitations/${fixture.create.invitation.id}/enrollments`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: enrollBody },
    );
    expect(enrollmentResponse.status).toBe(201);
    const enrollment = await enrollmentResponse.json<EnrollResponse>();
    expectSameJSONShape(enrollment, apiFixture.enrollment);

    const enrollmentRetry = await SELF.fetch(
      `https://sharing.invalid/v1/invitations/${fixture.create.invitation.id}/enrollments`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: enrollBody },
    );
    expect(enrollmentRetry.status).toBe(201);
    expect((await enrollmentRetry.json<EnrollResponse>()).enrollment.id)
      .toBe(enrollment.enrollment.id);

    const invitation = await testEnv.DB.prepare(
      "SELECT status, invite_proof_public_key FROM invitations WHERE id = ?",
    ).bind(fixture.create.invitation.id).first<{
      status: string;
      invite_proof_public_key: string | null;
    }>();
    expect(invitation).toEqual({ status: "consumed", invite_proof_public_key: null });

    const pendingResponse = await SELF.fetch(await signedRequest(
      "/v1/pairing/pending",
      "GET",
      fixture.create.member.id,
      fixture.ownerKeys,
    ));
    expect(pendingResponse.status).toBe(200);
    const pending = await pendingResponse.json<{
      pending: Array<{ id: string; transcriptHash: string }>;
    }>();
    expectSameJSONShape(pending, apiFixture.pending);
    expect(pending.pending).toHaveLength(1);
    expect(pending.pending[0]?.id).toBe(enrollment.enrollment.id);
    expect(pending.pending[0]?.transcriptHash).toBe(enrollment.enrollment.transcriptHash);

    const replayNonce = randomValue(16);
    const statusRequest = await signedRequest(
      "/v1/pairing/status",
      "GET",
      enrollment.member.id,
      fixture.inviteeKeys,
      undefined,
      replayNonce,
    );
    expect((await SELF.fetch(statusRequest)).status).toBe(200);
    const replayedStatus = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      enrollment.member.id,
      fixture.inviteeKeys,
      undefined,
      replayNonce,
    ));
    expect(replayedStatus.status).toBe(409);
    expect((await replayedStatus.json<{ error: { code: string } }>()).error.code)
      .toBe("replayed_request");

    const pendingRevoke = await SELF.fetch(await signedRequest(
      "/v1/pairing/revoke",
      "POST",
      enrollment.member.id,
      fixture.inviteeKeys,
      { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase() },
    ));
    expect(pendingRevoke.status).toBe(403);

    const envelope = randomValue(60);
    const ownerApprovalSignature = await sign(fixture.ownerKeys, approvalTranscript(
      enrollment.enrollment.transcriptHash,
      "X25519-HKDF-SHA256-CHACHA20POLY1305",
      envelope,
    ));
    const approveBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      transcriptHash: enrollment.enrollment.transcriptHash,
      envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      keyEnvelope: envelope,
      approvalSignature: ownerApprovalSignature,
    };
    const approvalResponse = await SELF.fetch(await signedRequest(
      `/v1/pairing/enrollments/${enrollment.enrollment.id}/approve`,
      "POST",
      fixture.create.member.id,
      fixture.ownerKeys,
      approveBody,
    ));
    expect(approvalResponse.status).toBe(200);
    const approvalJSON = await approvalResponse.json();
    expectSameJSONShape(approvalJSON, apiFixture.approve);
    const approvalRetry = await SELF.fetch(await signedRequest(
      `/v1/pairing/enrollments/${enrollment.enrollment.id}/approve`,
      "POST",
      fixture.create.member.id,
      fixture.ownerKeys,
      approveBody,
    ));
    expect(approvalRetry.status).toBe(200);
    expect(await approvalRetry.json()).toEqual(approvalJSON);

    const inviteeStatusResponse = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      enrollment.member.id,
      fixture.inviteeKeys,
    ));
    expect(inviteeStatusResponse.status).toBe(200);
    const inviteeStatus = await inviteeStatusResponse.json<{
      pairing: {
        state: string;
        keyEnvelope: null | {
          algorithm: string;
          ciphertext: string;
          approvalSignature: string;
        };
      };
    }>();
    expectSameJSONShape(inviteeStatus, apiFixture.statusApprovedInvitee);
    expect(inviteeStatus.pairing.state).toBe("approvedAwaitingCompletion");
    expect(inviteeStatus.pairing.keyEnvelope).toEqual(expect.objectContaining({
      algorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      ciphertext: envelope,
      approvalSignature: ownerApprovalSignature,
    }));
    expect(await verifyEd25519(
      fixture.create.member.signingPublicKey,
      inviteeStatus.pairing.keyEnvelope!.approvalSignature,
      approvalTranscript(
        enrollment.enrollment.transcriptHash,
        inviteeStatus.pairing.keyEnvelope!.algorithm,
        inviteeStatus.pairing.keyEnvelope!.ciphertext,
      ),
    )).toBe(true);

    const completeBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      transcriptHash: enrollment.enrollment.transcriptHash,
    };
    const completionResponse = await SELF.fetch(await signedRequest(
      `/v1/pairing/enrollments/${enrollment.enrollment.id}/complete`,
      "POST",
      enrollment.member.id,
      fixture.inviteeKeys,
      completeBody,
    ));
    expect(completionResponse.status).toBe(200);
    const completionJSON = await completionResponse.json();
    expectSameJSONShape(completionJSON, apiFixture.complete);
    const completionRetry = await SELF.fetch(await signedRequest(
      `/v1/pairing/enrollments/${enrollment.enrollment.id}/complete`,
      "POST",
      enrollment.member.id,
      fixture.inviteeKeys,
      completeBody,
    ));
    expect(completionRetry.status).toBe(200);
    expect(await completionRetry.json()).toEqual(completionJSON);

    const clearedApproval = await testEnv.DB.prepare(
      "SELECT key_envelope, approval_signature FROM approval_events WHERE enrollment_id = ?",
    ).bind(enrollment.enrollment.id).first<{
      key_envelope: string | null;
      approval_signature: string | null;
    }>();
    expect(clearedApproval).toEqual({ key_envelope: null, approval_signature: null });

    const cancelAfterCompletion = await SELF.fetch(await signedRequest(
      `/v1/pairing/enrollments/${enrollment.enrollment.id}/cancel`,
      "POST",
      enrollment.member.id,
      fixture.inviteeKeys,
      { protocolVersion: 1, clientRequestId: crypto.randomUUID().toLowerCase() },
    ));
    expect(cancelAfterCompletion.status).toBe(409);
    expect((await cancelAfterCompletion.json<{ error: { code: string } }>()).error.code)
      .toBe("invalid_pairing_state");

    const activeStatusResponse = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      fixture.create.member.id,
      fixture.ownerKeys,
    ));
    expect(activeStatusResponse.status).toBe(200);
    expect((await activeStatusResponse.json<{ pairing: { state: string } }>()).pairing.state)
      .toBe("active");

    const revokeBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
    };
    const revokeResponse = await SELF.fetch(await signedRequest(
      "/v1/pairing/revoke",
      "POST",
      fixture.create.member.id,
      fixture.ownerKeys,
      revokeBody,
    ));
    expect(revokeResponse.status).toBe(202);
    const revokeJSON = await revokeResponse.json();
    expectSameJSONShape(revokeJSON, apiFixture.revoke);
    const revokeRetry = await SELF.fetch(await signedRequest(
      "/v1/pairing/revoke",
      "POST",
      fixture.create.member.id,
      fixture.ownerKeys,
      revokeBody,
    ));
    expect(revokeRetry.status).toBe(202);
    expect(await revokeRetry.json()).toEqual(revokeJSON);
    expect(await testEnv.DB.prepare(
      "SELECT state FROM space_deletion_jobs WHERE space_id = ?",
    ).bind(fixture.create.spaceId).first<{ state: string }>()).toEqual({ state: "pending" });
    expect(await testEnv.DB.prepare(
      "SELECT challenge_id FROM enrollments WHERE id = ?",
    ).bind(enrollment.enrollment.id).first<{ challenge_id: string | null }>())
      .toEqual({ challenge_id: null });
  });

  it("lets a pending invitee cancel only its own enrollment without extending retention", async () => {
    const fixture = await createPairingFixture();
    const enrollment = await enrollPairingFixture(fixture);
    const envelope = randomValue(60);
    const approveBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      transcriptHash: enrollment.enrollment.transcriptHash,
      envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      keyEnvelope: envelope,
      approvalSignature: await sign(fixture.ownerKeys, approvalTranscript(
        enrollment.enrollment.transcriptHash,
        "X25519-HKDF-SHA256-CHACHA20POLY1305",
        envelope,
      )),
    };
    expect((await SELF.fetch(await signedRequest(
      `/v1/pairing/enrollments/${enrollment.enrollment.id}/approve`,
      "POST",
      fixture.create.member.id,
      fixture.ownerKeys,
      approveBody,
    ))).status).toBe(200);

    const fixedExpiry = Math.floor(Date.now() / 1000) + 123_456;
    await testEnv.DB.prepare(
      "UPDATE spaces SET metadata_expires_at = ? WHERE id = ?",
    ).bind(fixedExpiry, fixture.create.spaceId).run();
    const cancelBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
    };
    const cancelPath = `/v1/pairing/enrollments/${enrollment.enrollment.id}/cancel`;
    const cancellationResponse = await SELF.fetch(await signedRequest(
      cancelPath,
      "POST",
      enrollment.member.id,
      fixture.inviteeKeys,
      cancelBody,
    ));
    expect(cancellationResponse.status).toBe(202);
    const cancellationJSON = await cancellationResponse.json();
    expectSameJSONShape(cancellationJSON, apiFixture.cancel);

    const cancellationRetry = await SELF.fetch(await signedRequest(
      cancelPath,
      "POST",
      enrollment.member.id,
      fixture.inviteeKeys,
      cancelBody,
    ));
    expect(cancellationRetry.status).toBe(202);
    expect(await cancellationRetry.json()).toEqual(cancellationJSON);

    const revokedStatus = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      enrollment.member.id,
      fixture.inviteeKeys,
    ));
    expect(revokedStatus.status).toBe(410);
    expect((await revokedStatus.json<{ error: { code: string } }>()).error.code)
      .toBe("sharing_revoked");

    expect(await testEnv.DB.prepare(
      "SELECT state, metadata_expires_at FROM spaces WHERE id = ?",
    ).bind(fixture.create.spaceId).first()).toEqual({
      state: "active",
      metadata_expires_at: fixedExpiry,
    });
    expect(await testEnv.DB.prepare(
      `SELECT e.state AS enrollment_state, m.state AS member_state, e.challenge_id,
              a.key_envelope, a.approval_signature
         FROM enrollments AS e
         JOIN members AS m ON m.id = e.member_id
         LEFT JOIN approval_events AS a ON a.enrollment_id = e.id
        WHERE e.id = ?`,
    ).bind(enrollment.enrollment.id).first()).toEqual({
      enrollment_state: "revoked",
      member_state: "revoked",
      challenge_id: null,
      key_envelope: null,
      approval_signature: null,
    });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM space_deletion_jobs WHERE space_id = ?",
    ).bind(fixture.create.spaceId).first<{ count: number }>()).toEqual({ count: 0 });

    const ownerStatus = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      fixture.create.member.id,
      fixture.ownerKeys,
    ));
    expect(ownerStatus.status).toBe(200);
    expect((await ownerStatus.json<{ pairing: { state: string } }>()).pairing.state)
      .toBe("cancelled");
  });

  it("expires idempotency records and hard-deletes inactive Phase 1 metadata", async () => {
    const fixture = await createPairingFixture();
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      `UPDATE idempotency_records
          SET created_at = ?, expires_at = ?
        WHERE space_id = ?`,
    ).bind(now - 2, now - 1, fixture.create.spaceId).run();

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM idempotency_records WHERE space_id = ?",
    ).bind(fixture.create.spaceId).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM spaces WHERE id = ?",
    ).bind(fixture.create.spaceId).first<{ count: number }>()).toEqual({ count: 1 });

    await testEnv.DB.prepare(
      `UPDATE spaces
          SET created_at = ?, last_activity_at = ?, metadata_expires_at = ?
        WHERE id = ?`,
    ).bind(now - 2_592_002, now - 2_592_002, now - 1, fixture.create.spaceId).run();
    await runScheduledCleanup(testEnv, now);

    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM spaces WHERE id = ?",
    ).bind(fixture.create.spaceId).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM members WHERE space_id = ?",
    ).bind(fixture.create.spaceId).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM space_deletion_jobs WHERE space_id = ?",
    ).bind(fixture.create.spaceId).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("carries an over-limit inactivity backlog into the next scheduled run", async () => {
    const now = Math.floor(Date.now() / 1000);
    const total = CLEANUP_SPACE_LIMIT + 5;
    const inserts = Array.from({ length: total }, (_, index) => testEnv.DB.prepare(
      `INSERT INTO spaces(
         id, creation_request_id, protocol_version, daily_boundary_minute_utc,
         state, created_at, last_activity_at, metadata_expires_at
       ) VALUES (?, ?, 1, 540, 'active', ?, ?, ?)`,
    ).bind(
      randomValue(16),
      crypto.randomUUID().toLowerCase(),
      now - 2_592_100 - index,
      now - 2_592_100 - index,
      now - 100 - index,
    ));
    for (let offset = 0; offset < inserts.length; offset += 40) {
      await testEnv.DB.batch(inserts.slice(offset, offset + 40));
    }

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM spaces WHERE metadata_expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 5 });

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM spaces WHERE metadata_expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("bounds each pairing-expiry source before deduplication and uses partial indexes", async () => {
    const now = Math.floor(Date.now() / 1000);
    const plan = await testEnv.DB.prepare(
      `EXPLAIN QUERY PLAN ${PAIRING_EXPIRY_CANDIDATES_SQL}`,
    ).bind(
      now,
      CLEANUP_SPACE_LIMIT,
      now,
      CLEANUP_SPACE_LIMIT,
      now,
      CLEANUP_SPACE_LIMIT,
      CLEANUP_SPACE_LIMIT,
    ).all<{ detail: string }>();
    const planText = plan.results.map((row) => row.detail).join("\n");
    expect(planText).toContain("open_invitations_expiry");
    expect(planText).toContain("live_enrollments_expiry");
    expect(planText).toContain("live_invitation_challenges_expiry");

    const total = CLEANUP_SPACE_LIMIT + 5;
    const inserts: D1PreparedStatement[] = [];
    for (let index = 0; index < total; index += 1) {
      const spaceId = randomValue(16);
      const memberId = randomValue(16);
      const createdAt = now - 200 - index;
      inserts.push(
        testEnv.DB.prepare(
          `INSERT INTO spaces(
             id, creation_request_id, protocol_version, daily_boundary_minute_utc,
             state, created_at, last_activity_at, metadata_expires_at
           ) VALUES (?, ?, 1, 540, 'active', ?, ?, ?)`,
        ).bind(
          spaceId,
          crypto.randomUUID().toLowerCase(),
          createdAt,
          createdAt,
          now + 10_000,
        ),
        testEnv.DB.prepare(
          `INSERT INTO members(
             id, space_id, role, participant_id, agreement_public_key,
             signing_public_key, state, created_at, activated_at
           ) VALUES (?, ?, 'owner', ?, ?, ?, 'active', ?, ?)`,
        ).bind(
          memberId,
          spaceId,
          randomValue(16),
          randomValue(32),
          randomValue(32),
          createdAt,
          createdAt,
        ),
        testEnv.DB.prepare(
          `INSERT INTO invitations(
             id, space_id, inviter_member_id, invite_proof_public_key,
             status, created_at, expires_at
           ) VALUES (?, ?, ?, ?, 'open', ?, ?)`,
        ).bind(
          randomValue(16),
          spaceId,
          memberId,
          randomValue(32),
          createdAt,
          now - 1 - index,
        ),
      );
    }
    for (let offset = 0; offset < inserts.length; offset += 39) {
      await testEnv.DB.batch(inserts.slice(offset, offset + 39));
    }

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM invitations WHERE status = 'open' AND expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 5 });

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM invitations WHERE status = 'open' AND expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("does not read an entire abusive pairing-expiry source", async () => {
    const now = Math.floor(Date.now() / 1000);
    const total = 1_000;
    await testEnv.DB.prepare(
      `WITH RECURSIVE sequence(value) AS (
         VALUES(1)
         UNION ALL
         SELECT value + 1 FROM sequence WHERE value < ?
       )
       INSERT INTO spaces(
         id, creation_request_id, protocol_version, daily_boundary_minute_utc,
         state, created_at, last_activity_at, metadata_expires_at
       )
       SELECT printf('space-%04d', value), printf('request-%04d', value),
              1, 540, 'active', ?, ?, ?
         FROM sequence`,
    ).bind(total, now - 2_000, now - 2_000, now + 10_000).run();
    await testEnv.DB.prepare(
      `WITH RECURSIVE sequence(value) AS (
         VALUES(1)
         UNION ALL
         SELECT value + 1 FROM sequence WHERE value < ?
       )
       INSERT INTO members(
         id, space_id, role, participant_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       )
       SELECT printf('member-%04d', value), printf('space-%04d', value), 'owner',
              printf('participant-%04d', value), printf('agreement-%04d', value),
              printf('signing-%04d', value), 'active', ?, ?
         FROM sequence`,
    ).bind(total, now - 2_000, now - 2_000).run();
    await testEnv.DB.prepare(
      `WITH RECURSIVE sequence(value) AS (
         VALUES(1)
         UNION ALL
         SELECT value + 1 FROM sequence WHERE value < ?
       )
       INSERT INTO invitations(
         id, space_id, inviter_member_id, invite_proof_public_key,
         status, created_at, expires_at
       )
       SELECT printf('invite-%04d', value), printf('space-%04d', value),
              printf('member-%04d', value), printf('proof-%04d', value),
              'open', ?, ? - value
         FROM sequence`,
    ).bind(total, now - 2_000, now).run();

    const candidates = await testEnv.DB.prepare(PAIRING_EXPIRY_CANDIDATES_SQL).bind(
      now,
      CLEANUP_SPACE_LIMIT,
      now,
      CLEANUP_SPACE_LIMIT,
      now,
      CLEANUP_SPACE_LIMIT,
      CLEANUP_SPACE_LIMIT,
    ).all<{ id: string }>();
    expect(candidates.results).toHaveLength(CLEANUP_SPACE_LIMIT);
    expect(candidates.meta.rows_read).toBeLessThan(total);
  });

  it("bounds nonce and idempotency cleanup and drains the oldest backlog first", async () => {
    const fixture = await createPairingFixture();
    const now = Math.floor(Date.now() / 1000);
    const nonceTotal = CLEANUP_NONCE_LIMIT + 5;
    const idempotencyTotal = CLEANUP_IDEMPOTENCY_LIMIT + 5;
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
       INSERT INTO request_nonces(member_id, nonce, created_at, expires_at)
       SELECT ?, printf('cleanup-nonce-%05d', value), ? - 3 - value, ? - 2 - value
         FROM numbers`,
    ).bind(nonceTotal, fixture.create.member.id, now, now).run();
    await testEnv.DB.prepare(
      `${numberRows}
       INSERT INTO idempotency_records(
         operation, actor_id, client_request_id, space_id, request_hash,
         response_status, response_json, created_at, expires_at
       )
       SELECT 'cleanup-fixture', ?, printf('cleanup-request-%05d', value), ?,
              printf('cleanup-hash-%05d', value), 200, '{}',
              ? - 3 - value, ? - 2 - value
         FROM numbers`,
    ).bind(
      idempotencyTotal,
      fixture.create.member.id,
      fixture.create.spaceId,
      now,
      now,
    ).run();

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM request_nonces WHERE expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 5 });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM idempotency_records WHERE expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 5 });
    expect(await testEnv.DB.prepare(
      `SELECT MIN(nonce) AS first, MAX(nonce) AS last
         FROM request_nonces
        WHERE nonce LIKE 'cleanup-nonce-%'`,
    ).first()).toEqual({
      first: "cleanup-nonce-00000",
      last: "cleanup-nonce-00004",
    });

    await runScheduledCleanup(testEnv, now);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM request_nonces WHERE expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM idempotency_records WHERE expires_at <= ?",
    ).bind(now).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("expires an unused invitation and removes its proof material", async () => {
    const fixture = await createPairingFixture();
    const past = Math.floor(Date.now() / 1000) - 1;
    await testEnv.DB.batch([
      testEnv.DB.prepare("UPDATE invitations SET created_at = ?, expires_at = ? WHERE id = ?")
        .bind(past - 1, past, fixture.create.invitation.id),
      testEnv.DB.prepare(
        "UPDATE invitation_challenges SET created_at = ?, expires_at = ? WHERE invitation_id = ?",
      ).bind(past - 1, past, fixture.create.invitation.id),
    ]);

    const response = await SELF.fetch(
      `https://sharing.invalid/v1/invitations/${fixture.create.invitation.id}/challenges`,
      { method: "POST", headers: { "CF-Connecting-IP": "192.0.2.12" } },
    );
    expect(response.status).toBe(410);
    expect(await testEnv.DB.prepare(
      "SELECT status, invite_proof_public_key FROM invitations WHERE id = ?",
    ).bind(fixture.create.invitation.id).first()).toEqual({
      status: "expired",
      invite_proof_public_key: null,
    });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM invitation_challenges WHERE invitation_id = ?",
    ).bind(fixture.create.invitation.id).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("enforces the eight-live-challenge cap under concurrent requests", async () => {
    const fixture = await createPairingFixture();
    const responses = await Promise.all(
      Array.from({ length: 12 }, (_, index) => SELF.fetch(
        `https://sharing.invalid/v1/invitations/${fixture.create.invitation.id}/challenges`,
        {
          method: "POST",
          headers: { "CF-Connecting-IP": `192.0.2.${20 + index}` },
        },
      )),
    );
    expect(responses.filter((response) => response.status === 201)).toHaveLength(7);
    expect(responses.filter((response) => response.status === 429)).toHaveLength(5);
    expect(responses.every((response) => response.status === 201 || response.status === 429))
      .toBe(true);
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM invitation_challenges
        WHERE invitation_id = ? AND consumed_at IS NULL`,
    ).bind(fixture.create.invitation.id).first<{ count: number }>()).toEqual({ count: 8 });
  });
});
