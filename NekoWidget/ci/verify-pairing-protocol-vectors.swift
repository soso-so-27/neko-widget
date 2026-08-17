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
        guard CommandLine.arguments.count == 2 else {
            throw VectorError.mismatch("Expected one fixture path argument")
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        try require(fixture.schemaVersion == 1, "Unsupported fixture schema")

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

        print("Pairing protocol v1 Swift vectors: PASS")
    }
}
