import { describe, expect, it } from "vitest";

import fixture from "../../ci/fixtures/pairing-protocol-v1.json";
import recoveryFixture from "../../ci/fixtures/device-recovery-protocol-v2.json";
import sharingFixture from "../../ci/fixtures/sharing-protocol-v1.json";
import windowNameFixture from "../../ci/fixtures/window-name-protocol-v1.json";
import {
  base64urlDecode,
  base64urlEncode,
  sha256,
  sha256Base64url,
  verifyEd25519,
} from "../src/encoding";
import {
  deviceRecoveryApprovalTranscript,
  deviceRecoveryClaimTranscript,
  deviceRecoverySignedRequestTranscript,
  enrollmentTranscript,
  encodeCanonicalFields,
  pairingTranscript,
  sharedManifestAAD,
  sharedMediaAAD,
  signedRequestTranscript,
  verificationPhrase,
} from "../src/protocol";

describe("device recovery protocol v2 golden vectors", () => {
  it("matches Swift canonical claim, approval and request bytes", async () => {
    const claim = recoveryFixture.claim;
    expect(["owner", "invitee"]).toContain(claim.target.role);
    expect(["owner", "invitee"]).toContain(claim.peer.role);
    const claimBytes = deviceRecoveryClaimTranscript({
      recoveryId: claim.recoveryId,
      spaceId: claim.spaceId,
      dailyBoundaryMinuteUTC: claim.dailyBoundaryMinuteUTC,
      expiresAt: claim.expiresAt,
      membershipRevision: claim.membershipRevision,
      keyEpoch: claim.keyEpoch,
      targetMemberId: claim.target.memberId,
      targetParticipantId: claim.target.participantId,
      targetRole: claim.target.role as "owner" | "invitee",
      targetAgreementPublicKey: claim.target.agreementPublicKey,
      targetSigningPublicKey: claim.target.signingPublicKey,
      initiatorMemberId: claim.peer.memberId,
      initiatorParticipantId: claim.peer.participantId,
      initiatorRole: claim.peer.role as "owner" | "invitee",
      initiatorAgreementPublicKey: claim.peer.agreementPublicKey,
      initiatorSigningPublicKey: claim.peer.signingPublicKey,
      clientRequestId: claim.clientRequestId,
      deviceId: claim.deviceId,
      agreementPublicKey: claim.agreementPublicKey,
      signingPublicKey: claim.signingPublicKey,
    });
    expect(base64urlEncode(claimBytes)).toBe(claim.expected.canonicalBase64URL);
    expect(await sha256Base64url(claimBytes)).toBe(claim.expected.sha256);
    expect(verificationPhrase(await sha256(claimBytes))).toBe(
      claim.expected.verificationPhrase,
    );

    const approvalBytes = deviceRecoveryApprovalTranscript({
      recoveryId: claim.recoveryId,
      spaceId: claim.spaceId,
      targetMemberId: claim.target.memberId,
      deviceId: claim.deviceId,
      membershipRevision: claim.membershipRevision,
      keyEpoch: claim.keyEpoch,
      transcriptHash: claim.expected.sha256,
      envelopeAlgorithm: "X25519-HKDF-SHA256-CHACHA20POLY1305",
      keyEnvelope: recoveryFixture.approval.keyEnvelope,
    });
    expect(base64urlEncode(approvalBytes)).toBe(
      recoveryFixture.approval.expected.canonicalBase64URL,
    );
    expect(await sha256Base64url(approvalBytes)).toBe(
      recoveryFixture.approval.expected.sha256,
    );

    const signed = recoveryFixture.request;
    const requestBytes = deviceRecoverySignedRequestTranscript({
      recoveryId: claim.recoveryId,
      timestamp: signed.timestamp,
      nonce: signed.nonce,
      method: signed.method,
      pathname: signed.pathname,
      bodySHA256: signed.bodySHA256,
    });
    expect(base64urlEncode(requestBytes)).toBe(signed.expected.canonicalBase64URL);
    expect(await sha256Base64url(requestBytes)).toBe(signed.expected.sha256);
  });
});

describe("pairing protocol v1 golden vectors", () => {
  it("matches the same canonical bytes, hashes and phrase as CryptoKit", async () => {
    const pairing = fixture.pairing;
    const pairingBytes = pairingTranscript({
      spaceId: pairing.spaceId,
      invitationId: pairing.invitationId,
      enrollmentId: pairing.enrollmentId,
      dailyBoundaryMinuteUTC: pairing.dailyBoundaryMinuteUTC,
      inviterMemberId: pairing.inviterMemberId,
      inviterParticipantId: pairing.inviterParticipantId,
      inviterAgreementPublicKey: pairing.inviterAgreementPublicKey,
      inviterSigningPublicKey: pairing.inviterSigningPublicKey,
      inviteeMemberId: pairing.inviteeMemberId,
      inviteeParticipantId: pairing.inviteeParticipantId,
      inviteeAgreementPublicKey: pairing.inviteeAgreementPublicKey,
      inviteeSigningPublicKey: pairing.inviteeSigningPublicKey,
    });
    expect(base64urlEncode(pairingBytes)).toBe(pairing.expected.canonicalBase64URL);
    expect(await sha256Base64url(pairingBytes)).toBe(pairing.expected.sha256);
    expect(verificationPhrase(await sha256(pairingBytes))).toBe(pairing.expected.verificationPhrase);

    const enrollment = fixture.enrollment;
    const enrollmentBytes = enrollmentTranscript({
      spaceId: enrollment.spaceId,
      invitationId: enrollment.invitationId,
      challengeId: enrollment.challengeId,
      challengeValue: enrollment.challengeValue,
      challengeExpiresAt: enrollment.challengeExpiresAt,
      clientRequestId: enrollment.clientRequestId,
      participantId: enrollment.participantId,
      agreementPublicKey: enrollment.agreementPublicKey,
      signingPublicKey: enrollment.signingPublicKey,
    });
    expect(base64urlEncode(enrollmentBytes)).toBe(enrollment.expected.canonicalBase64URL);
    expect(await sha256Base64url(enrollmentBytes)).toBe(enrollment.expected.sha256);

    const signed = fixture.request;
    const body = new TextEncoder().encode(signed.bodyUTF8);
    expect(await sha256Base64url(body)).toBe(signed.bodySHA256);
    const signedBytes = signedRequestTranscript({
      memberId: signed.memberId,
      timestamp: signed.timestamp,
      nonce: signed.nonce,
      method: signed.method,
      pathname: signed.pathname,
      bodySHA256: signed.bodySHA256,
    });
    expect(base64urlEncode(signedBytes)).toBe(signed.expected.canonicalBase64URL);
    expect(await sha256Base64url(signedBytes)).toBe(signed.expected.sha256);

    expect(base64urlDecode(pairing.expected.sha256, 32)).toHaveLength(32);
  });
});

describe("private window-name protocol v1 golden vector", () => {
  it("uses the same UInt16-prefixed creator-signature transcript as Swift", async () => {
    const record = windowNameFixture.record;
    const canonical = encodeCanonicalFields(record.fields);
    expect(base64urlEncode(canonical)).toBe(record.expected.canonicalBase64URL);
    expect(await sha256Base64url(canonical)).toBe(record.expected.sha256);
    expect(await verifyEd25519(
      record.expected.signingPublicKey,
      record.expected.signature,
      canonical,
    )).toBe(true);
  });
});

describe("sharing protocol v1 golden vectors", () => {
  it("binds media and manifest ciphertext to the same typed fields as CryptoKit", async () => {
    const media = sharingFixture.media;
    const mediaBytes = sharedMediaAAD(media.fields);
    expect(base64urlEncode(mediaBytes)).toBe(media.canonicalBase64url);
    expect(await sha256Base64url(mediaBytes)).toBe(media.sha256);

    const manifest = sharingFixture.manifest;
    const manifestBytes = sharedManifestAAD(manifest.fields);
    expect(base64urlEncode(manifestBytes)).toBe(manifest.canonicalBase64url);
    expect(await sha256Base64url(manifestBytes)).toBe(manifest.sha256);
  });
});
