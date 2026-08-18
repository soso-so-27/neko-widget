import { describe, expect, it } from "vitest";

import fixture from "../../ci/fixtures/pairing-protocol-v1.json";
import sharingFixture from "../../ci/fixtures/sharing-protocol-v1.json";
import { base64urlDecode, base64urlEncode, sha256, sha256Base64url } from "../src/encoding";
import {
  enrollmentTranscript,
  pairingTranscript,
  sharedManifestAAD,
  sharedMediaAAD,
  signedRequestTranscript,
  verificationPhrase,
} from "../src/protocol";

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
