import Foundation

private enum ContractVerificationError: Error {
    case missingFixturePath
    case unexpectedStatus(String)
    case acceptedInvalidStatus(String)
}

@main
private struct PairingAPIResponseVerifier {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ContractVerificationError.missingFixturePath
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try PairingAPIContractVerifier.verifyGoldenResponses(
            Data(contentsOf: fixtureURL)
        )
        try verifySavedOwnerPeer()
        print("Pairing API v1 Swift response contract: PASS")
        print("Owner status saved-peer boundaries: PASS (29 cases)")
    }

    private static func verifySavedOwnerPeer() throws {
        let marker = UUID().uuidString
        let ownerKey = PairingCrypto.makeCredential(
            installationMarker: marker, includesInvitationSecret: true, includesRoomKey: true
        )
        let inviteeKey = PairingCrypto.makeCredential(
            installationMarker: marker, includesInvitationSecret: false, includesRoomKey: false
        )
        func identifier(_ byte: UInt8) -> String {
            Data(repeating: byte, count: 16).base64URLEncodedString()
        }
        func identity(_ byte: UInt8, _ key: PairingCredential) throws -> PairingMemberIdentity {
            PairingMemberIdentity(
                memberID: identifier(byte), participantID: key.participantIDString,
                agreementPublicKey: try PairingCrypto.agreementPublicKey(for: key).base64URLEncodedString(),
                signingPublicKey: try PairingCrypto.signingPublicKey(for: key).base64URLEncodedString()
            )
        }
        func member(_ identity: PairingMemberIdentity, role: String) -> [String: Any] {
            ["id": identity.memberID, "participantId": identity.participantID,
             "agreementPublicKey": identity.agreementPublicKey,
             "signingPublicKey": identity.signingPublicKey, "role": role, "state": "active"]
        }
        let owner = try identity(1, ownerKey)
        let invitee = try identity(2, inviteeKey)
        let transcript = PairingVerificationTranscript(
            spaceID: identifier(3), invitationID: identifier(4), enrollmentID: identifier(5),
            dailyBoundaryMinuteUTC: 540, inviter: owner, invitee: invitee
        )
        let canonical = try transcript.canonicalData()
        let hash = PairingCrypto.sha256(canonical)
        var state = PairingState.unpaired(installationMarker: marker)
        state.phase = .failed
        state.role = .inviter
        state.credentialAccount = ownerKey.account
        state.participantID = owner.participantID
        state.memberID = owner.memberID
        state.spaceID = transcript.spaceID
        state.invitationID = transcript.invitationID
        state.enrollmentID = transcript.enrollmentID
        state.dailyBoundaryMinuteUTC = transcript.dailyBoundaryMinuteUTC
        state.peerMemberID = invitee.memberID
        state.peerParticipantID = invitee.participantID
        state.peerAgreementPublicKey = invitee.agreementPublicKey
        state.peerSigningPublicKey = invitee.signingPublicKey
        state.transcript = canonical.base64URLEncodedString()
        state.transcriptHash = hash.base64URLEncodedString()
        state.verificationPhrase = PairingCrypto.verificationPhrase(for: hash)
        let enrollment: [String: Any] = [
            "id": transcript.enrollmentID, "createdAt": 1, "expiresAt": 2,
            "transcript": canonical.base64URLEncodedString(), "transcriptHash": hash.base64URLEncodedString()
        ]
        func response(_ phase: String, local: [String: Any]? = nil,
                      echoed: [String: Any]? = nil, peer: [String: Any]? = nil) throws -> Data {
            let localMember = local ?? member(owner, role: "owner")
            var pairing: [String: Any] = [
                "state": phase, "enrollment": echoed ?? enrollment,
                "peer": peer.map { $0 as Any } ?? NSNull(), "keyEnvelope": NSNull()
            ]
            if phase == "approvedAwaitingCompletion", localMember["role"] as? String == "invitee" {
                pairing["keyEnvelope"] = [
                    "algorithm": PairingProtocol.roomKeyEnvelopeAlgorithm,
                    "ciphertext": Data(repeating: 1, count: 60).base64URLEncodedString(),
                    "approvalSignature": Data(repeating: 2, count: 64).base64URLEncodedString(),
                    "approvedAt": 1
                ]
            }
            return try JSONSerialization.data(withJSONObject: [
                "protocolVersion": PairingProtocol.version, "spaceId": transcript.spaceID,
                "dailyBoundaryMinuteUTC": transcript.dailyBoundaryMinuteUTC,
                "member": localMember, "pairing": pairing
            ])
        }
        func reject(_ name: String, _ data: Data, _ local: PairingState,
                    _ credential: PairingCredential? = nil) throws {
            do {
                _ = try PairingAPIContractVerifier.verifyStatusResponse(
                    data, localState: local, credential: credential ?? ownerKey
                )
            } catch is PairingError {
                return
            }
            throw ContractVerificationError.acceptedInvalidStatus(name)
        }
        for phase in ["pendingApproval", "approvedAwaitingCompletion", "cancelled"] {
            let result = try PairingAPIContractVerifier.verifyStatusResponse(
                response(phase), localState: state, credential: ownerKey
            )
            guard result.state == phase, result.peer == invitee,
                  result.transcript == transcript, result.transcriptHash == state.transcriptHash,
                  result.keyEnvelope == nil, result.approvalSignature == nil else {
                throw ContractVerificationError.unexpectedStatus(phase)
            }
        }
        let approved = try response("approvedAwaitingCompletion")
        let invalidStates: [(String, (inout PairingState) -> Void)] = [
            ("unknown peer", { $0.peerMemberID = nil }),
            ("different peer member", { $0.peerMemberID = identifier(6) }),
            ("different peer participant", { $0.peerParticipantID = identifier(7) }),
            ("different agreement key", { $0.peerAgreementPublicKey = owner.agreementPublicKey }),
            ("different signing key", { $0.peerSigningPublicKey = owner.signingPublicKey }),
            ("missing transcript", { $0.transcript = nil }),
            ("different transcript", { $0.transcript = Data([0]).base64URLEncodedString() }),
            ("missing hash", { $0.transcriptHash = nil }),
            ("different hash", { $0.transcriptHash = Data(repeating: 0, count: 32).base64URLEncodedString() }),
            ("missing verification phrase", { $0.verificationPhrase = nil }),
            ("different enrollment", { $0.enrollmentID = identifier(8) }),
            ("missing enrollment", { $0.enrollmentID = nil }),
            ("different invitation", { $0.invitationID = identifier(9) }),
            ("different account", { $0.credentialAccount = UUID().uuidString }),
            ("different installation", { $0.installationMarker = UUID().uuidString }),
            ("different local participant", { $0.participantID = identifier(10) })
        ]
        for (name, mutate) in invalidStates {
            var invalid = state
            mutate(&invalid)
            try reject(name, approved, invalid)
        }
        var wrongEcho = enrollment
        wrongEcho["transcript"] = Data([1]).base64URLEncodedString()
        try reject("server transcript mismatch", response("approvedAwaitingCompletion", echoed: wrongEcho), state)
        wrongEcho = enrollment
        wrongEcho["transcriptHash"] = Data(repeating: 1, count: 32).base64URLEncodedString()
        try reject("server hash mismatch", response("approvedAwaitingCompletion", echoed: wrongEcho), state)
        wrongEcho = enrollment
        wrongEcho["id"] = identifier(11)
        try reject("server enrollment mismatch", response("approvedAwaitingCompletion", echoed: wrongEcho), state)
        try reject("active still needs server peer", response("active"), state)
        var inviteeState = state
        inviteeState.role = .invitee
        inviteeState.credentialAccount = inviteeKey.account
        inviteeState.participantID = invitee.participantID
        inviteeState.memberID = invitee.memberID
        inviteeState.peerMemberID = owner.memberID
        inviteeState.peerParticipantID = owner.participantID
        inviteeState.peerAgreementPublicKey = owner.agreementPublicKey
        inviteeState.peerSigningPublicKey = owner.signingPublicKey
        for phase in ["pendingApproval", "approvedAwaitingCompletion", "cancelled", "active"] {
            try reject("invitee \(phase) still needs server peer",
                       response(phase, local: member(invitee, role: "invitee")), inviteeState, inviteeKey)
        }
        let active = try PairingAPIContractVerifier.verifyStatusResponse(
            response("active", peer: member(invitee, role: "invitee")),
            localState: state, credential: ownerKey
        )
        guard active.peer == invitee, active.transcript == transcript else {
            throw ContractVerificationError.unexpectedStatus("existing active response")
        }
        let inviteeApproved = try PairingAPIContractVerifier.verifyStatusResponse(
            response("approvedAwaitingCompletion", local: member(invitee, role: "invitee"),
                     peer: member(owner, role: "owner")),
            localState: inviteeState, credential: inviteeKey
        )
        guard inviteeApproved.peer == owner, inviteeApproved.transcript == transcript,
              inviteeApproved.keyEnvelope != nil else {
            throw ContractVerificationError.unexpectedStatus("existing invitee response")
        }
    }
}
