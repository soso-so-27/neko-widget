import Foundation

private struct Expected: Decodable {
    let canonicalBase64URL: String
    let sha256: String
    let verificationPhrase: String?
}

private struct PairingVector: Decodable {
    let spaceId: String
    let invitationId: String
    let enrollmentId: String
    let inviterMemberId: String
    let inviterParticipantId: String
    let inviteeMemberId: String
    let inviteeParticipantId: String
    let inviterAgreementPublicKey: String
    let inviterSigningPublicKey: String
    let inviteeAgreementPublicKey: String
    let inviteeSigningPublicKey: String
    let dailyBoundaryMinuteUTC: Int
    let expected: Expected
}

private struct EnrollmentVector: Decodable {
    let spaceId: String
    let invitationId: String
    let challengeId: String
    let challengeValue: String
    let challengeExpiresAt: Int
    let clientRequestId: String
    let participantId: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let expected: Expected
}

private struct RequestVector: Decodable {
    let memberId: String
    let timestamp: Int
    let nonce: String
    let method: String
    let pathname: String
    let bodyUTF8: String
    let bodySHA256: String
    let expected: Expected
}

private struct Fixture: Decodable {
    let schemaVersion: Int
    let pairing: PairingVector
    let enrollment: EnrollmentVector
    let request: RequestVector
}

private struct DeviceRecoveryClaimVector: Decodable {
    let recoveryId: String
    let spaceId: String
    let dailyBoundaryMinuteUTC: Int
    let expiresAt: Int
    let membershipRevision: Int
    let keyEpoch: Int
    let target: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
    let clientRequestId: String
    let deviceId: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let expected: Expected
}

private struct DeviceRecoveryApprovalVector: Decodable {
    let keyEnvelope: String
    let expected: Expected
}

private struct DeviceRecoveryRequestVector: Decodable {
    let timestamp: Int
    let nonce: String
    let method: String
    let pathname: String
    let bodySHA256: String
    let expected: Expected
}

private struct DeviceRecoveryFixture: Decodable {
    let schemaVersion: Int
    let claim: DeviceRecoveryClaimVector
    let approval: DeviceRecoveryApprovalVector
    let request: DeviceRecoveryRequestVector
}

private enum VectorError: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case let .mismatch(message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VectorError.mismatch(message) }
}

private func verify(
    data: Data,
    expected: Expected,
    label: String
) throws -> Data {
    let hash = PairingCrypto.sha256(data)
    try require(
        data.base64URLEncodedString() == expected.canonicalBase64URL,
        "\(label) canonical bytes differ"
    )
    try require(
        hash.base64URLEncodedString() == expected.sha256,
        "\(label) SHA-256 differs"
    )
    return hash
}

@main
private struct PairingProtocolVectorVerifier {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw VectorError.mismatch("Expected pairing and device-recovery fixture paths")
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        let recoveryFixture = try JSONDecoder().decode(
            DeviceRecoveryFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        )
        try require(fixture.schemaVersion == 1, "Unsupported fixture schema")
        try require(recoveryFixture.schemaVersion == 2, "Unsupported recovery fixture schema")

        let pairing = fixture.pairing
        let pairingTranscript = PairingVerificationTranscript(
            spaceID: pairing.spaceId,
            invitationID: pairing.invitationId,
            enrollmentID: pairing.enrollmentId,
            dailyBoundaryMinuteUTC: pairing.dailyBoundaryMinuteUTC,
            inviter: PairingMemberIdentity(
                memberID: pairing.inviterMemberId,
                participantID: pairing.inviterParticipantId,
                agreementPublicKey: pairing.inviterAgreementPublicKey,
                signingPublicKey: pairing.inviterSigningPublicKey
            ),
            invitee: PairingMemberIdentity(
                memberID: pairing.inviteeMemberId,
                participantID: pairing.inviteeParticipantId,
                agreementPublicKey: pairing.inviteeAgreementPublicKey,
                signingPublicKey: pairing.inviteeSigningPublicKey
            )
        )
        let pairingHash = try verify(
            data: pairingTranscript.canonicalData(),
            expected: pairing.expected,
            label: "pairing"
        )
        try require(
            PairingCrypto.verificationPhrase(for: pairingHash)
                == pairing.expected.verificationPhrase,
            "pairing verification phrase differs"
        )

        let enrollment = fixture.enrollment
        let enrollmentData = try PairingCanonicalEncoder.encode([
            "NW1.ENROLL",
            String(PairingProtocol.version),
            enrollment.spaceId,
            enrollment.invitationId,
            enrollment.challengeId,
            enrollment.challengeValue,
            String(enrollment.challengeExpiresAt),
            enrollment.clientRequestId,
            enrollment.participantId,
            enrollment.agreementPublicKey,
            enrollment.signingPublicKey
        ])
        _ = try verify(
            data: enrollmentData,
            expected: enrollment.expected,
            label: "enrollment"
        )

        let request = fixture.request
        try require(
            PairingCrypto.sha256(Data(request.bodyUTF8.utf8)).base64URLEncodedString()
                == request.bodySHA256,
            "request body SHA-256 differs"
        )
        let requestData = try PairingCanonicalEncoder.encode([
            "NW1.REQUEST",
            String(PairingProtocol.version),
            request.memberId,
            String(request.timestamp),
            request.nonce,
            request.method.uppercased(),
            request.pathname,
            request.bodySHA256
        ])
        _ = try verify(data: requestData, expected: request.expected, label: "request")

        let recovery = recoveryFixture.claim
        let recoveryTranscript = PairingDeviceRecoveryTranscript(
            recoveryID: recovery.recoveryId,
            spaceID: recovery.spaceId,
            dailyBoundaryMinuteUTC: recovery.dailyBoundaryMinuteUTC,
            expiresAtUnix: recovery.expiresAt,
            membershipRevision: recovery.membershipRevision,
            keyEpoch: recovery.keyEpoch,
            target: recovery.target,
            peer: recovery.peer,
            clientRequestID: recovery.clientRequestId,
            deviceID: recovery.deviceId,
            agreementPublicKey: recovery.agreementPublicKey,
            signingPublicKey: recovery.signingPublicKey
        )
        let recoveryHash = try verify(
            data: recoveryTranscript.canonicalData(),
            expected: recovery.expected,
            label: "device recovery claim"
        )
        try require(
            PairingCrypto.verificationPhrase(for: recoveryHash)
                == recovery.expected.verificationPhrase,
            "device recovery verification phrase differs"
        )

        let approval = recoveryFixture.approval
        let approvalData = try PairingCrypto.deviceRecoveryApprovalTranscript(
            recoveryID: recovery.recoveryId,
            spaceID: recovery.spaceId,
            targetMemberID: recovery.target.memberID,
            deviceID: recovery.deviceId,
            membershipRevision: recovery.membershipRevision,
            keyEpoch: recovery.keyEpoch,
            transcriptHash: recovery.expected.sha256,
            envelopeAlgorithm: PairingProtocol.roomKeyEnvelopeAlgorithm,
            keyEnvelope: approval.keyEnvelope
        )
        _ = try verify(
            data: approvalData,
            expected: approval.expected,
            label: "device recovery approval"
        )

        let recoveryRequest = recoveryFixture.request
        let recoveryRequestData = try PairingCrypto.deviceRecoverySignedRequestTranscript(
            recoveryID: recovery.recoveryId,
            timestamp: recoveryRequest.timestamp,
            nonce: recoveryRequest.nonce,
            method: recoveryRequest.method,
            path: recoveryRequest.pathname,
            bodySHA256: recoveryRequest.bodySHA256
        )
        _ = try verify(
            data: recoveryRequestData,
            expected: recoveryRequest.expected,
            label: "device recovery request"
        )

        print("Pairing v1 and device recovery v2 Swift vectors: PASS")
    }
}
