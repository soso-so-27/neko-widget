import { env } from "cloudflare:workers";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { base64urlEncode, sha256Base64url } from "../src/encoding";
import { expireDeviceRecoveries } from "../src/device-recovery";
import type { Env } from "../src/env";
import {
  approvalTranscript,
  creationTranscript,
  deviceRecoveryApprovalTranscript,
  deviceRecoveryClaimTranscript,
  deviceRecoverySignedRequestTranscript,
  enrollmentTranscript,
  signedRequestTranscript,
} from "../src/protocol";

interface KeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

interface Identity {
  memberId: string;
  participantId: string;
  role: "owner" | "invitee";
  agreementPublicKey: string;
  signingPublicKey: string;
  state: string;
}

interface RecoveryMetadata {
  id: string;
  state: string;
  codePrefix: string;
  createdAt: number;
  expiresAt: number;
  membershipRevision: number;
  keyEpoch: number;
  clientRequestId: string | null;
  deviceId: string | null;
  transcript: string | null;
  transcriptHash: string | null;
  keyEnvelope: {
    algorithm: string;
    ciphertext: string;
    approvalSignature: string;
    approvedAt: number;
  } | null;
}

interface RecoveryResponse {
  protocolVersion: number;
  recovery: RecoveryMetadata;
  space: { id: string; dailyBoundaryMinuteUTC: number };
  target?: Identity;
  credential?: Identity;
  peer: Identity;
  previousTargetSigningPublicKey?: string;
  recoveredAt?: number | null;
}

interface PairFixture {
  spaceID: string;
  dailyBoundary: number;
  owner: Identity;
  ownerKeys: KeyPair;
  invitee: Identity;
  inviteeKeys: KeyPair;
  originalInviteeAgreement: string;
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

async function signedRequest(
  path: string,
  method: "GET" | "POST",
  memberID: string,
  keyPair: KeyPair,
  payload?: unknown,
  nonce = randomValue(16),
  deviceID?: string,
): Promise<Request> {
  const body = payload === undefined ? "" : JSON.stringify(payload);
  const timestamp = Math.floor(Date.now() / 1_000);
  const signature = await sign(keyPair, signedRequestTranscript({
    memberId: memberID,
    timestamp,
    nonce,
    method,
    pathname: path,
    bodySHA256: await sha256Base64url(new TextEncoder().encode(body)),
  }));
  const headers = new Headers({
    "Neko-Protocol-Version": "1",
    "Neko-Member-ID": memberID,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
    "CF-Connecting-IP": "192.0.2.40",
  });
  if (deviceID !== undefined) headers.set("Neko-Device-ID", deviceID);
  if (payload !== undefined) headers.set("Content-Type", "application/json");
  const init: RequestInit = { method, headers };
  if (payload !== undefined) init.body = body;
  return new Request(`https://sharing.invalid${path}`, init);
}

async function recoverySignedRequest(
  path: string,
  method: "GET" | "POST",
  recoveryID: string,
  keyPair: KeyPair,
  payload?: unknown,
  nonce = randomValue(16),
): Promise<Request> {
  const body = payload === undefined ? "" : JSON.stringify(payload);
  const timestamp = Math.floor(Date.now() / 1_000);
  const signature = await sign(keyPair, deviceRecoverySignedRequestTranscript({
    recoveryId: recoveryID,
    timestamp,
    nonce,
    method,
    pathname: path,
    bodySHA256: await sha256Base64url(new TextEncoder().encode(body)),
  }));
  const headers = new Headers({
    "Neko-Protocol-Version": "2",
    "Neko-Member-ID": recoveryID,
    "Neko-Timestamp": String(timestamp),
    "Neko-Nonce": nonce,
    "Neko-Signature": signature,
    "CF-Connecting-IP": "192.0.2.41",
  });
  if (payload !== undefined) headers.set("Content-Type", "application/json");
  const init: RequestInit = { method, headers };
  if (payload !== undefined) init.body = body;
  return new Request(`https://sharing.invalid${path}`, init);
}

async function pairedFixture(): Promise<PairFixture> {
  const ownerKeys = await signingKeyPair();
  const inviteProofKeys = await signingKeyPair();
  const ownerParticipantID = randomValue(16);
  const ownerAgreement = randomValue(32);
  const ownerSigning = await publicKeyValue(ownerKeys);
  const dailyBoundary = 540;
  const creationFields = {
    clientRequestId: crypto.randomUUID().toLowerCase(),
    participantId: ownerParticipantID,
    agreementPublicKey: ownerAgreement,
    signingPublicKey: ownerSigning,
    invitationProofPublicKey: await publicKeyValue(inviteProofKeys),
    dailyBoundaryMinuteUTC: dailyBoundary,
  };
  const createResponse = await SELF.fetch("https://sharing.invalid/v1/spaces", {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.42" },
    body: JSON.stringify({
      protocolVersion: 1,
      ...creationFields,
      creationSignature: await sign(ownerKeys, creationTranscript(creationFields)),
    }),
  });
  expect(createResponse.status).toBe(201);
  const create = await createResponse.json<{
    spaceId: string;
    member: { id: string };
    invitation: { id: string };
  }>();
  const challengeResponse = await SELF.fetch(
    `https://sharing.invalid/v1/invitations/${create.invitation.id}/challenges`,
    { method: "POST", headers: { "CF-Connecting-IP": "192.0.2.43" } },
  );
  const challenge = await challengeResponse.json<{
    spaceId: string;
    invitationId: string;
    challenge: { id: string; value: string; expiresAt: number };
  }>();
  const inviteeKeys = await signingKeyPair();
  const inviteeParticipantID = randomValue(16);
  const inviteeAgreement = randomValue(32);
  const inviteeSigning = await publicKeyValue(inviteeKeys);
  const enrollmentClientID = crypto.randomUUID().toLowerCase();
  const enrollTranscript = enrollmentTranscript({
    spaceId: challenge.spaceId,
    invitationId: challenge.invitationId,
    challengeId: challenge.challenge.id,
    challengeValue: challenge.challenge.value,
    challengeExpiresAt: challenge.challenge.expiresAt,
    clientRequestId: enrollmentClientID,
    participantId: inviteeParticipantID,
    agreementPublicKey: inviteeAgreement,
    signingPublicKey: inviteeSigning,
  });
  const enrollmentResponse = await SELF.fetch(
    `https://sharing.invalid/v1/invitations/${create.invitation.id}/enrollments`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.44" },
      body: JSON.stringify({
        protocolVersion: 1,
        clientRequestId: enrollmentClientID,
        challengeId: challenge.challenge.id,
        participantId: inviteeParticipantID,
        agreementPublicKey: inviteeAgreement,
        signingPublicKey: inviteeSigning,
        inviteProofSignature: await sign(inviteProofKeys, enrollTranscript),
        participantSignature: await sign(inviteeKeys, enrollTranscript),
      }),
    },
  );
  expect(enrollmentResponse.status).toBe(201);
  const enrollment = await enrollmentResponse.json<{
    member: { id: string };
    enrollment: { id: string; transcriptHash: string };
  }>();
  const envelope = randomValue(60);
  const approveResponse = await SELF.fetch(await signedRequest(
    `/v1/pairing/enrollments/${enrollment.enrollment.id}/approve`,
    "POST",
    create.member.id,
    ownerKeys,
    {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      transcriptHash: enrollment.enrollment.transcriptHash,
      envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      keyEnvelope: envelope,
      approvalSignature: await sign(
        ownerKeys,
        approvalTranscript(
          enrollment.enrollment.transcriptHash,
          "X25519-HKDF-SHA256-CHACHA20POLY1305",
          envelope,
        ),
      ),
    },
  ));
  expect(approveResponse.status).toBe(200);
  const completeResponse = await SELF.fetch(await signedRequest(
    `/v1/pairing/enrollments/${enrollment.enrollment.id}/complete`,
    "POST",
    enrollment.member.id,
    inviteeKeys,
    {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      transcriptHash: enrollment.enrollment.transcriptHash,
    },
  ));
  expect(completeResponse.status).toBe(200);
  return {
    spaceID: create.spaceId,
    dailyBoundary,
    owner: {
      memberId: create.member.id,
      participantId: ownerParticipantID,
      role: "owner",
      agreementPublicKey: ownerAgreement,
      signingPublicKey: ownerSigning,
      state: "active",
    },
    ownerKeys,
    invitee: {
      memberId: enrollment.member.id,
      participantId: inviteeParticipantID,
      role: "invitee",
      agreementPublicKey: inviteeAgreement,
      signingPublicKey: inviteeSigning,
      state: "active",
    },
    inviteeKeys,
    originalInviteeAgreement: inviteeAgreement,
  };
}

async function createRecovery(fixture: PairFixture, proofKeys: KeyPair): Promise<RecoveryResponse> {
  const response = await SELF.fetch(await signedRequest(
    "/v2/device-recoveries",
    "POST",
    fixture.owner.memberId,
    fixture.ownerKeys,
    {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      targetParticipantId: fixture.invitee.participantId,
      recoveryProofPublicKey: await publicKeyValue(proofKeys),
    },
  ));
  expect(response.status).toBe(201);
  return response.json<RecoveryResponse>();
}

async function claimRecovery(
  fixture: PairFixture,
  created: RecoveryResponse,
  proofKeys: KeyPair,
  replacementKeys: KeyPair,
  values?: { clientRequestID?: string; deviceID?: string; agreementPublicKey?: string },
): Promise<{ response: Response; transcript: Uint8Array; body: Record<string, unknown> }> {
  const clientRequestID = values?.clientRequestID ?? crypto.randomUUID().toLowerCase();
  const deviceID = values?.deviceID ?? randomValue(16);
  const newAgreement = values?.agreementPublicKey ?? randomValue(32);
  const newSigning = await publicKeyValue(replacementKeys);
  const transcript = deviceRecoveryClaimTranscript({
    recoveryId: created.recovery.id,
    spaceId: created.space.id,
    dailyBoundaryMinuteUTC: created.space.dailyBoundaryMinuteUTC,
    expiresAt: created.recovery.expiresAt,
    membershipRevision: created.recovery.membershipRevision,
    keyEpoch: created.recovery.keyEpoch,
    targetMemberId: created.target!.memberId,
    targetParticipantId: created.target!.participantId,
    targetRole: created.target!.role,
    targetAgreementPublicKey: created.target!.agreementPublicKey,
    targetSigningPublicKey: created.target!.signingPublicKey,
    initiatorMemberId: created.peer.memberId,
    initiatorParticipantId: created.peer.participantId,
    initiatorRole: created.peer.role,
    initiatorAgreementPublicKey: created.peer.agreementPublicKey,
    initiatorSigningPublicKey: created.peer.signingPublicKey,
    clientRequestId: clientRequestID,
    deviceId: deviceID,
    agreementPublicKey: newAgreement,
    signingPublicKey: newSigning,
  });
  const body = {
    protocolVersion: 2,
    clientRequestId: clientRequestID,
    deviceId: deviceID,
    agreementPublicKey: newAgreement,
    signingPublicKey: newSigning,
    recoveryProofSignature: await sign(proofKeys, transcript),
    deviceSignature: await sign(replacementKeys, transcript),
  };
  const response = await SELF.fetch(
    `https://sharing.invalid/v2/device-recoveries/${created.recovery.id}/claim`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.45" },
      body: JSON.stringify(body),
    },
  );
  return { response, transcript, body };
}

const testEnv = env as unknown as Env;

describe("device recovery", () => {
  it("keeps participant-scoped data independent from one device closing", async () => {
    for (const removedTrigger of [
      "moment_window_names_delete_on_device_revoke",
      "moment_window_names_cleanup_on_device_delete",
      "moment_reactions_delete_on_device_close",
    ]) {
      expect(await testEnv.DB.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?",
      ).bind(removedTrigger).first()).toBeNull();
    }
    for (const retainedTrigger of [
      "moment_window_names_delete_on_participant_revoke",
      "moment_reactions_delete_on_participant_close",
      "moment_reactions_delete_on_space_close",
    ]) {
      expect(await testEnv.DB.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?",
      ).bind(retainedTrigger).first()).toEqual({ name: retainedTrigger });
    }
  });

  it("requires the primary owner device to sponsor an invitee enrollment", async () => {
    const fixture = await pairedFixture();
    const additionalKeys = await signingKeyPair();
    const additionalDeviceID = randomValue(16);
    const additionalAgreement = randomValue(32);
    const additionalSigning = await publicKeyValue(additionalKeys);
    const now = Math.floor(Date.now() / 1_000);
    await testEnv.DB.prepare(
      `INSERT INTO moment_devices(
         id, participant_id, legacy_member_id, agreement_public_key,
         signing_public_key, state, created_at, activated_at
       ) VALUES (?, ?, NULL, ?, ?, 'active', ?, ?)`,
    ).bind(
      additionalDeviceID,
      fixture.owner.memberId,
      additionalAgreement,
      additionalSigning,
      now,
      now,
    ).run();
    const proofKeys = await signingKeyPair();
    const response = await SELF.fetch(await signedRequest(
      "/v2/device-recoveries",
      "POST",
      fixture.owner.memberId,
      additionalKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        targetParticipantId: fixture.invitee.participantId,
        recoveryProofPublicKey: await publicKeyValue(proofKeys),
      },
      undefined,
      additionalDeviceID,
    ));
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({
      error: { code: "primary_owner_device_required" },
    });

    const primaryResponse = await SELF.fetch(await signedRequest(
      "/v2/device-recoveries",
      "POST",
      fixture.owner.memberId,
      fixture.ownerKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        targetParticipantId: fixture.invitee.participantId,
        recoveryProofPublicKey: await publicKeyValue(proofKeys),
      },
    ));
    expect(primaryResponse.status).toBe(201);
    const primaryRecovery = await primaryResponse.json<RecoveryResponse>();
    expect(primaryRecovery).toMatchObject({
      target: { memberId: fixture.invitee.memberId },
      peer: {
        memberId: fixture.owner.memberId,
        signingPublicKey: fixture.owner.signingPublicKey,
      },
    });

    // Simulate an open recovery admitted before this rollout. Its initiator
    // keys identify the owner's additional device rather than the primary one.
    await testEnv.DB.prepare(
      `UPDATE device_recoveries
          SET initiator_agreement_public_key = ?, initiator_signing_public_key = ?
        WHERE id = ?`,
    ).bind(
      additionalAgreement,
      additionalSigning,
      primaryRecovery.recovery.id,
    ).run();
    const legacyRecovery = {
      ...primaryRecovery,
      peer: {
        ...primaryRecovery.peer,
        agreementPublicKey: additionalAgreement,
        signingPublicKey: additionalSigning,
      },
    };
    const legacyClaim = await claimRecovery(
      fixture,
      legacyRecovery,
      proofKeys,
      await signingKeyPair(),
    );
    expect(legacyClaim.response.status).toBe(410);
    expect(await legacyClaim.response.json()).toMatchObject({
      error: { code: "recovery_unavailable" },
    });
    for (const path of [
      "/v2/window-name",
      "/v2/moments/changes",
      "/v2/reactions/changes",
    ]) {
      const read = await SELF.fetch(await signedRequest(
        path,
        "GET",
        fixture.owner.memberId,
        additionalKeys,
        undefined,
        undefined,
        additionalDeviceID,
      ));
      expect(read.status, path).toBe(200);
    }
  });

  it("atomically adds one device while retaining participant history and old keys", async () => {
    const fixture = await pairedFixture();
    const proofKeys = await signingKeyPair();
    const replacementKeys = await signingKeyPair();
    const created = await createRecovery(fixture, proofKeys);
    expect(created.recovery.state).toBe("awaitingClaim");
    expect(created.target).toMatchObject(fixture.invitee);

    const claimed = await claimRecovery(fixture, created, proofKeys, replacementKeys);
    expect(claimed.response.status).toBe(201);
    const claim = await claimed.response.json<RecoveryResponse>();
    expect(claim.recovery).toMatchObject({
      state: "pendingApproval",
      clientRequestId: claimed.body.clientRequestId,
      deviceId: claimed.body.deviceId,
      transcript: base64urlEncode(claimed.transcript),
      transcriptHash: await sha256Base64url(claimed.transcript),
    });

    const unchanged = await testEnv.DB.prepare(
      `SELECT member.agreement_public_key AS member_key,
              moment_space.membership_revision,
              COUNT(device.id) AS active_devices
         FROM members AS member
         JOIN moment_participants AS participant ON participant.legacy_member_id = member.id
         JOIN moment_devices AS device ON device.participant_id = participant.id
         JOIN moment_spaces AS moment_space ON moment_space.space_id = participant.space_id
        WHERE member.id = ? AND device.state = 'active'`,
    ).bind(fixture.invitee.memberId).first<{
      member_key: string;
      membership_revision: number;
      active_devices: number;
    }>();
    expect(unchanged).toEqual({
      member_key: fixture.originalInviteeAgreement,
      membership_revision: created.recovery.membershipRevision,
      active_devices: 1,
    });

    const pendingResponse = await SELF.fetch(await signedRequest(
      "/v2/device-recoveries/pending",
      "GET",
      fixture.owner.memberId,
      fixture.ownerKeys,
    ));
    expect(pendingResponse.status).toBe(200);
    const pending = await pendingResponse.json<{
      pending: Array<{ recovery: RecoveryMetadata; credential: Identity }>;
    }>();
    expect(pending.pending[0]?.recovery.clientRequestId).toBe(claimed.body.clientRequestId);
    expect(pending.pending[0]?.credential.signingPublicKey).toBe(claimed.body.signingPublicKey);

    const envelope = randomValue(60);
    const approval = await sign(fixture.ownerKeys, deviceRecoveryApprovalTranscript({
      recoveryId: created.recovery.id,
      spaceId: fixture.spaceID,
      targetMemberId: fixture.invitee.memberId,
      deviceId: claimed.body.deviceId as string,
      membershipRevision: created.recovery.membershipRevision,
      keyEpoch: created.recovery.keyEpoch,
      transcriptHash: claim.recovery.transcriptHash!,
      envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      keyEnvelope: envelope,
    }));
    const approveResponse = await SELF.fetch(await signedRequest(
      `/v2/device-recoveries/${created.recovery.id}/approve`,
      "POST",
      fixture.owner.memberId,
      fixture.ownerKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        transcriptHash: claim.recovery.transcriptHash,
        envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
        keyEnvelope: envelope,
        approvalSignature: approval,
      },
    ));
    expect(approveResponse.status).toBe(200);
    expect(await approveResponse.json()).toMatchObject({
      targetMemberId: fixture.invitee.memberId,
      deviceId: claimed.body.deviceId,
      membershipRevision: created.recovery.membershipRevision,
      keyEpoch: created.recovery.keyEpoch,
    });

    const statusPath = `/v2/device-recoveries/${created.recovery.id}/status`;
    const approvedStatus = await SELF.fetch(await recoverySignedRequest(
      statusPath,
      "GET",
      created.recovery.id,
      replacementKeys,
    ));
    expect(approvedStatus.status).toBe(200);
    expect((await approvedStatus.json<RecoveryResponse>()).recovery.keyEnvelope).toMatchObject({
      ciphertext: envelope,
      approvalSignature: approval,
    });

    const completionBody = {
      protocolVersion: 2,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      transcriptHash: claim.recovery.transcriptHash,
    };
    const completePath = `/v2/device-recoveries/${created.recovery.id}/complete`;
    const completeResponse = await SELF.fetch(await recoverySignedRequest(
      completePath,
      "POST",
      created.recovery.id,
      replacementKeys,
      completionBody,
    ));
    expect(completeResponse.status).toBe(200);
    const completed = await completeResponse.json<RecoveryResponse>();
    expect(completed).toMatchObject({
      recovery: { state: "active", keyEnvelope: null },
      credential: {
        memberId: fixture.invitee.memberId,
        participantId: fixture.invitee.participantId,
        signingPublicKey: claimed.body.signingPublicKey,
        state: "active",
      },
    });
    expect(completed.recoveredAt).toEqual(expect.any(Number));

    const completeRetry = await SELF.fetch(await recoverySignedRequest(
      completePath,
      "POST",
      created.recovery.id,
      replacementKeys,
      completionBody,
    ));
    expect(completeRetry.status).toBe(200);
    expect(await completeRetry.json()).toMatchObject({
      recovery: { state: "active" },
      credential: { signingPublicKey: claimed.body.signingPublicKey, state: "active" },
      recoveredAt: completed.recoveredAt,
    });

    const oldStatus = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      fixture.invitee.memberId,
      fixture.inviteeKeys,
    ));
    expect(oldStatus.status).toBe(200);
    expect(await oldStatus.json()).toMatchObject({
      member: { signingPublicKey: fixture.invitee.signingPublicKey },
    });
    const missingDeviceHeader = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      fixture.invitee.memberId,
      replacementKeys,
    ));
    expect(missingDeviceHeader.status).toBe(401);
    const newStatus = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      fixture.invitee.memberId,
      replacementKeys,
      undefined,
      undefined,
      claimed.body.deviceId as string,
    ));
    expect(newStatus.status).toBe(200);
    const status = await newStatus.json<{
      member: { agreementPublicKey: string; signingPublicKey: string };
      pairing: { state: string; enrollment: unknown; peer: { signingPublicKey: string } };
    }>();
    expect(status.member).toMatchObject({
      agreementPublicKey: claimed.body.agreementPublicKey,
      signingPublicKey: claimed.body.signingPublicKey,
    });
    expect(status.pairing).toMatchObject({
      state: "active",
      enrollment: null,
      peer: { signingPublicKey: fixture.owner.signingPublicKey },
    });

    const reserveResponse = await SELF.fetch(await signedRequest(
      "/v2/moments/reservations",
      "POST",
      fixture.invitee.memberId,
      replacementKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        clientMomentId: crypto.randomUUID().toLowerCase(),
        kind: "live",
        keyEpoch: created.recovery.keyEpoch,
        ciphertextSize: 64,
        ciphertextSHA256: randomValue(32),
        clientModerationVersion: 1,
        senderPolicyAcceptance: {
          version: 1,
          acceptedAt: new Date().toISOString(),
        },
      },
      undefined,
      claimed.body.deviceId as string,
    ));
    expect(reserveResponse.status).toBe(201);

    const database = await testEnv.DB.prepare(
      `SELECT member.agreement_public_key AS retained_member_key,
              old_device.state AS old_state,
              old_device.legacy_member_id AS old_legacy_id,
              new_device.state AS new_state,
              new_device.legacy_member_id AS new_legacy_id,
              approval.key_envelope, approval.approval_signature
         FROM device_recoveries AS recovery
         JOIN members AS member ON member.id = recovery.target_member_id
         JOIN moment_devices AS old_device ON old_device.id = recovery.target_device_id
         JOIN device_recovery_claim_events AS claim ON claim.recovery_id = recovery.id
         JOIN moment_devices AS new_device ON new_device.id = claim.proposed_device_id
         JOIN device_recovery_approval_events AS approval ON approval.recovery_id = recovery.id
        WHERE recovery.id = ?`,
    ).bind(created.recovery.id).first<{
      retained_member_key: string;
      old_state: string;
      old_legacy_id: string | null;
      new_state: string;
      new_legacy_id: string | null;
      key_envelope: string | null;
      approval_signature: string | null;
    }>();
    expect(database).toEqual({
      retained_member_key: fixture.originalInviteeAgreement,
      old_state: "active",
      old_legacy_id: fixture.invitee.memberId,
      new_state: "active",
      new_legacy_id: null,
      key_envelope: null,
      approval_signature: null,
    });

    const sponsorStatus = await SELF.fetch(await signedRequest(
      `/v2/device-recoveries/${created.recovery.id}/sponsor-status`,
      "GET",
      fixture.owner.memberId,
      fixture.ownerKeys,
    ));
    expect(sponsorStatus.status).toBe(200);
    expect(await sponsorStatus.json()).toMatchObject({
      recovery: { state: "active" },
      credential: { signingPublicKey: claimed.body.signingPublicKey, state: "active" },
    });

    const retiredSigningKeys = await signingKeyPair();
    const retiredAgreement = randomValue(32);
    const retiredAt = Math.floor(Date.now() / 1_000) - 1;
    await testEnv.DB.prepare(
      `INSERT INTO moment_devices(
         id, participant_id, agreement_public_key, signing_public_key,
         state, created_at, revoked_at
       ) VALUES (?, ?, ?, ?, 'revoked', ?, ?)`,
    ).bind(
      randomValue(16),
      fixture.invitee.memberId,
      retiredAgreement,
      await publicKeyValue(retiredSigningKeys),
      retiredAt - 1,
      retiredAt,
    ).run();
    const resurrectionProof = await signingKeyPair();
    const resurrection = await createRecovery(fixture, resurrectionProof);
    const reusedRevokedKeys = await claimRecovery(
      fixture,
      resurrection,
      resurrectionProof,
      retiredSigningKeys,
      { agreementPublicKey: retiredAgreement },
    );
    expect(reusedRevokedKeys.response.status).toBe(409);
  });

  it("does not mutate credentials for an invalid or merely claimed recovery", async () => {
    const fixture = await pairedFixture();
    const proofKeys = await signingKeyPair();
    const replacementKeys = await signingKeyPair();
    const created = await createRecovery(fixture, proofKeys);
    const wrongProof = await signingKeyPair();
    const rejected = await claimRecovery(fixture, created, wrongProof, replacementKeys);
    expect(rejected.response.status).toBe(401);

    const claimed = await claimRecovery(fixture, created, proofKeys, replacementKeys);
    expect(claimed.response.status).toBe(201);
    const row = await testEnv.DB.prepare(
      `SELECT member.agreement_public_key,
              device.signing_public_key, device.state, device.legacy_member_id,
              moment_space.membership_revision
         FROM members AS member
         JOIN moment_participants AS participant ON participant.legacy_member_id = member.id
         JOIN moment_devices AS device
           ON device.participant_id = participant.id AND device.legacy_member_id = member.id
         JOIN moment_spaces AS moment_space ON moment_space.space_id = participant.space_id
        WHERE member.id = ?`,
    ).bind(fixture.invitee.memberId).first<{
      agreement_public_key: string;
      signing_public_key: string;
      state: string;
      legacy_member_id: string;
      membership_revision: number;
    }>();
    expect(row).toEqual({
      agreement_public_key: fixture.originalInviteeAgreement,
      signing_public_key: fixture.invitee.signingPublicKey,
      state: "active",
      legacy_member_id: fixture.invitee.memberId,
      membership_revision: created.recovery.membershipRevision,
    });
  });

  it("lets the invitee recover the owner without discarding the signed window name", async () => {
    const fixture = await pairedFixture();
    await testEnv.DB.prepare(
      `INSERT INTO moment_window_names(
         space_id, owner_member_id, client_revision, key_epoch, ciphertext,
         ciphertext_size, ciphertext_sha256, owner_signature, updated_at
       ) VALUES (?, ?, 1, 1, ?, 29, ?, ?, ?)`,
    ).bind(
      fixture.spaceID,
      fixture.owner.memberId,
      randomValue(29),
      randomValue(32),
      randomValue(64),
      Math.floor(Date.now() / 1_000),
    ).run();
    const proofKeys = await signingKeyPair();
    const replacementKeys = await signingKeyPair();
    const createResponse = await SELF.fetch(await signedRequest(
      "/v2/device-recoveries",
      "POST",
      fixture.invitee.memberId,
      fixture.inviteeKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        targetParticipantId: fixture.owner.participantId,
        recoveryProofPublicKey: await publicKeyValue(proofKeys),
      },
    ));
    expect(createResponse.status).toBe(201);
    const created = await createResponse.json<RecoveryResponse>();
    expect(created.target).toMatchObject(fixture.owner);
    expect(created.peer).toMatchObject(fixture.invitee);

    const claimed = await claimRecovery(fixture, created, proofKeys, replacementKeys);
    expect(claimed.response.status).toBe(201);
    const claim = await claimed.response.json<RecoveryResponse>();
    const envelope = randomValue(60);
    const approvalSignature = await sign(
      fixture.inviteeKeys,
      deviceRecoveryApprovalTranscript({
        recoveryId: created.recovery.id,
        spaceId: fixture.spaceID,
        targetMemberId: fixture.owner.memberId,
        deviceId: claimed.body.deviceId as string,
        membershipRevision: created.recovery.membershipRevision,
        keyEpoch: created.recovery.keyEpoch,
        transcriptHash: claim.recovery.transcriptHash!,
        envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
        keyEnvelope: envelope,
      }),
    );
    const approved = await SELF.fetch(await signedRequest(
      `/v2/device-recoveries/${created.recovery.id}/approve`,
      "POST",
      fixture.invitee.memberId,
      fixture.inviteeKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        transcriptHash: claim.recovery.transcriptHash,
        envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
        keyEnvelope: envelope,
        approvalSignature,
      },
    ));
    expect(approved.status).toBe(200);
    const completePath = `/v2/device-recoveries/${created.recovery.id}/complete`;
    const completed = await SELF.fetch(await recoverySignedRequest(
      completePath,
      "POST",
      created.recovery.id,
      replacementKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        transcriptHash: claim.recovery.transcriptHash,
      },
    ));
    expect(completed.status).toBe(200);
    expect(await completed.json()).toMatchObject({
      recovery: { state: "active" },
      credential: {
        memberId: fixture.owner.memberId,
        participantId: fixture.owner.participantId,
        role: "owner",
        signingPublicKey: claimed.body.signingPublicKey,
      },
      peer: { memberId: fixture.invitee.memberId },
      previousTargetSigningPublicKey: fixture.owner.signingPublicKey,
    });

    const ownerStatus = await SELF.fetch(await signedRequest(
      "/v1/pairing/status",
      "GET",
      fixture.owner.memberId,
      replacementKeys,
      undefined,
      undefined,
      claimed.body.deviceId as string,
    ));
    expect(ownerStatus.status).toBe(200);
    expect(await ownerStatus.json()).toMatchObject({
      member: { signingPublicKey: claimed.body.signingPublicKey },
      pairing: {
        state: "active",
        enrollment: null,
        peer: { signingPublicKey: fixture.invitee.signingPublicKey },
      },
    });
    expect(await testEnv.DB.prepare(
      "SELECT owner_signature FROM moment_window_names WHERE space_id = ?",
    ).bind(fixture.spaceID).first()).toEqual({ owner_signature: expect.any(String) });
  });

  it("expires recovery capabilities and fails closed on membership revision changes", async () => {
    const fixture = await pairedFixture();
    const proofKeys = await signingKeyPair();
    const replacementKeys = await signingKeyPair();
    const created = await createRecovery(fixture, proofKeys);
    const claimed = await claimRecovery(fixture, created, proofKeys, replacementKeys);
    expect(claimed.response.status).toBe(201);
    const claim = await claimed.response.json<RecoveryResponse>();

    const envelope = randomValue(60);
    const approvalSignature = await sign(fixture.ownerKeys, deviceRecoveryApprovalTranscript({
      recoveryId: created.recovery.id,
      spaceId: fixture.spaceID,
      targetMemberId: fixture.invitee.memberId,
      deviceId: claimed.body.deviceId as string,
      membershipRevision: created.recovery.membershipRevision,
      keyEpoch: created.recovery.keyEpoch,
      transcriptHash: claim.recovery.transcriptHash!,
      envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      keyEnvelope: envelope,
    }));
    const approval = await SELF.fetch(await signedRequest(
      `/v2/device-recoveries/${created.recovery.id}/approve`,
      "POST",
      fixture.owner.memberId,
      fixture.ownerKeys,
      {
        protocolVersion: 2,
        clientRequestId: crypto.randomUUID().toLowerCase(),
        transcriptHash: claim.recovery.transcriptHash,
        envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
        keyEnvelope: envelope,
        approvalSignature,
      },
    ));
    expect(approval.status).toBe(200);

    await testEnv.DB.prepare(
      "UPDATE moment_spaces SET membership_revision = membership_revision + 1 WHERE space_id = ?",
    ).bind(fixture.spaceID).run();
    const candidateStatus = await SELF.fetch(await recoverySignedRequest(
      `/v2/device-recoveries/${created.recovery.id}/status`,
      "GET",
      created.recovery.id,
      replacementKeys,
    ));
    expect(candidateStatus.status).toBe(200);
    expect(await candidateStatus.json()).toMatchObject({
      recovery: { state: "expired", keyEnvelope: null },
    });
    const sponsorStatus = await SELF.fetch(await signedRequest(
      `/v2/device-recoveries/${created.recovery.id}/sponsor-status`,
      "GET",
      fixture.owner.memberId,
      fixture.ownerKeys,
    ));
    expect(sponsorStatus.status).toBe(200);
    expect(await sponsorStatus.json()).toMatchObject({
      recovery: { state: "expired", keyEnvelope: null },
    });

    const expired = await testEnv.DB.prepare(
      `SELECT recovery.state, recovery.recovery_proof_public_key,
              claim.recovery_proof_signature, claim.device_signature,
              approval.key_envelope, approval.approval_signature
         FROM device_recoveries AS recovery
         JOIN device_recovery_claim_events AS claim ON claim.recovery_id = recovery.id
         JOIN device_recovery_approval_events AS approval ON approval.recovery_id = recovery.id
        WHERE recovery.id = ?`,
    ).bind(created.recovery.id).first<{
      state: string;
      recovery_proof_public_key: string | null;
      recovery_proof_signature: string | null;
      device_signature: string | null;
      key_envelope: string | null;
      approval_signature: string | null;
    }>();
    expect(expired).toEqual({
      state: "expired",
      recovery_proof_public_key: null,
      recovery_proof_signature: null,
      device_signature: null,
      key_envelope: null,
      approval_signature: null,
    });

    const ttlRecovery = await createRecovery(fixture, await signingKeyPair());
    const expiredAt = Math.floor(Date.now() / 1_000) - 1;
    await testEnv.DB.prepare(
      "UPDATE device_recoveries SET created_at = ?, expires_at = ? WHERE id = ?",
    ).bind(expiredAt - 60, expiredAt, ttlRecovery.recovery.id).run();
    await expireDeviceRecoveries(testEnv, expiredAt + 1);
    const descriptor = await SELF.fetch(
      `https://sharing.invalid/v2/device-recoveries/${ttlRecovery.recovery.id}/descriptor`,
      { headers: { "CF-Connecting-IP": "192.0.2.46" } },
    );
    expect(descriptor.status).toBe(410);

    const retried = await createRecovery(fixture, await signingKeyPair());
    expect(retried.recovery).toMatchObject({
      state: "awaitingClaim",
      membershipRevision: created.recovery.membershipRevision + 1,
    });
    expect(retried.recovery.id).not.toBe(created.recovery.id);
  });
});
