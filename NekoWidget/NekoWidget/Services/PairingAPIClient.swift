import Foundation

struct PairingCreateResult: Sendable {
    let spaceID: String
    let memberID: String
    let invitationID: String
    let expiresAt: Date
}

struct PairingChallengeResult: Sendable {
    let invitationID: String
    let spaceID: String
    let challengeID: String
    let challengeValue: String
    let expiresAtUnix: Int
    let inviter: PairingMemberIdentity
    let dailyBoundaryMinuteUTC: Int
}

struct PairingEnrollmentResult: Sendable {
    let enrollmentID: String
    let memberID: String
    let state: String
    let transcript: PairingVerificationTranscript
    let transcriptHash: String
}

struct PairingStatusResult: Sendable {
    let state: String
    let peer: PairingMemberIdentity?
    let transcript: PairingVerificationTranscript?
    let transcriptHash: String?
    let envelopeAlgorithm: String?
    let keyEnvelope: String?
    let approvalSignature: String?
}

struct PairingDeviceRecoveryDescriptor: Sendable {
    let recoveryID: String
    let state: String
    let createdAt: Date?
    let expiresAt: Date
    let membershipRevision: Int
    let keyEpoch: Int
    let spaceID: String
    let dailyBoundaryMinuteUTC: Int
    let target: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
}

struct PairingDeviceRecoveryClaimResult: Sendable {
    let descriptor: PairingDeviceRecoveryDescriptor
    let clientRequestID: String
    let deviceID: String
    let transcriptData: Data
    let transcriptHash: String
    let credential: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
}

struct PairingDeviceRecoveryStatusResult: Sendable {
    let recoveryID: String
    let deviceID: String
    let state: String
    let expiresAt: Date
    let membershipRevision: Int
    let keyEpoch: Int
    let spaceID: String
    let dailyBoundaryMinuteUTC: Int
    let transcriptData: Data
    let transcriptHash: String
    let credential: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
    let envelopeAlgorithm: String?
    let keyEnvelope: String?
    let approvalSignature: String?
    let recoveredAt: Date?
    let previousTargetSigningPublicKey: String
}

protocol PairingAPIClientProtocol {
    func createSpace(
        credential: PairingCredential,
        dailyBoundaryMinuteUTC: Int,
        clientRequestID: UUID
    ) async throws -> PairingCreateResult

    func requestChallenge(
        invitation: PairingInvitationCode
    ) async throws -> PairingChallengeResult

    func enroll(
        invitation: PairingInvitationCode,
        challenge: PairingChallengeResult,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingEnrollmentResult

    func pending(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingStatusResult

    func status(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingStatusResult

    func approve(
        enrollmentID: String,
        transcriptHash: String,
        keyEnvelope: String,
        approvalSignature: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws

    func complete(
        enrollmentID: String,
        transcriptHash: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws

    func cancelPairing(
        state: PairingState,
        revokeWholeSpace: Bool,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws

    func createDeviceRecovery(
        state: PairingState,
        proofPublicKey: String,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryDescriptor

    func deviceRecoveryDescriptor(
        recoveryID: String
    ) async throws -> PairingDeviceRecoveryDescriptor

    func claimDeviceRecovery(
        code: PairingDeviceRecoveryCode,
        descriptor: PairingDeviceRecoveryDescriptor,
        deviceID: String,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryClaimResult

    func pendingDeviceRecovery(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryClaimResult?

    func approveDeviceRecovery(
        recoveryID: String,
        targetMemberID: String,
        deviceID: String,
        membershipRevision: Int,
        keyEpoch: Int,
        transcriptHash: String,
        keyEnvelope: String,
        approvalSignature: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws

    func deviceRecoveryStatus(
        recoveryID: String,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryStatusResult

    func sponsorDeviceRecoveryStatus(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryStatusResult

    func completeDeviceRecovery(
        recoveryID: String,
        transcriptHash: String,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryStatusResult
}

actor URLSessionPairingAPIClient: PairingAPIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let sessionDelegate: PairingNoRedirectSessionDelegate?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: SharingAPIConfiguration, session: URLSession? = nil) throws {
        guard configuration.isEnabled, let baseURL = configuration.baseURL else {
            throw PairingError.apiNotConfigured
        }
        self.baseURL = baseURL
        if let session {
            self.session = session
            sessionDelegate = nil
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            let delegate = PairingNoRedirectSessionDelegate()
            sessionDelegate = delegate
            self.session = URLSession(
                configuration: sessionConfiguration,
                delegate: delegate,
                delegateQueue: nil
            )
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func createSpace(
        credential: PairingCredential,
        dailyBoundaryMinuteUTC: Int,
        clientRequestID: UUID
    ) async throws -> PairingCreateResult {
        guard (0...1_439).contains(dailyBoundaryMinuteUTC) else {
            throw PairingError.invalidServerResponse
        }
        let clientRequestID = clientRequestID.uuidString.lowercased()
        let participantID = credential.participantIDString
        let agreementPublicKey = try PairingCrypto.agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let signingPublicKey = try PairingCrypto.signingPublicKey(for: credential)
            .base64URLEncodedString()
        let invitationProofPublicKey = try PairingCrypto.invitationProofPublicKey(for: credential)
            .base64URLEncodedString()
        let transcript = try PairingCanonicalEncoder.encode([
            "NW1.CREATE",
            String(PairingProtocol.version),
            clientRequestID,
            participantID,
            agreementPublicKey,
            signingPublicKey,
            invitationProofPublicKey,
            String(dailyBoundaryMinuteUTC)
        ])
        let request = CreateSpaceRequest(
            protocolVersion: PairingProtocol.version,
            clientRequestId: clientRequestID,
            participantId: participantID,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey,
            invitationProofPublicKey: invitationProofPublicKey,
            dailyBoundaryMinuteUTC: dailyBoundaryMinuteUTC,
            creationSignature: try PairingCrypto.sign(transcript, credential: credential)
                .base64URLEncodedString()
        )
        let response: CreateSpaceResponse = try await send(
            path: "/v1/spaces",
            method: "POST",
            body: request,
            authentication: nil
        )
        guard response.protocolVersion == PairingProtocol.version,
              PairingValidation.isOpaqueIdentifier(response.spaceId),
              PairingValidation.isOpaqueIdentifier(response.member.id),
              PairingValidation.isOpaqueIdentifier(response.invitation.id)
        else { throw PairingError.invalidServerResponse }
        guard response.member.role == "owner",
              response.member.state == "active",
              response.member.participantId == participantID,
              response.member.agreementPublicKey == agreementPublicKey,
              response.member.signingPublicKey == signingPublicKey,
              response.dailyBoundaryMinuteUTC == dailyBoundaryMinuteUTC,
              response.invitation.state == "open"
        else { throw PairingError.invalidServerResponse }
        _ = try response.member.identity.validated()
        return PairingCreateResult(
            spaceID: response.spaceId,
            memberID: response.member.id,
            invitationID: response.invitation.id,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.invitation.expiresAt))
        )
    }

    func requestChallenge(
        invitation: PairingInvitationCode
    ) async throws -> PairingChallengeResult {
        let challengeResponse: ChallengeResponse = try await sendEmpty(
            path: "/v1/invitations/\(invitation.invitationID)/challenges",
            method: "POST",
            authentication: nil
        )
        return try validatedChallenge(challengeResponse, invitation: invitation)
    }

    func enroll(
        invitation: PairingInvitationCode,
        challenge: PairingChallengeResult,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingEnrollmentResult {
        let clientRequestID = clientRequestID.uuidString.lowercased()
        let participantID = credential.participantIDString
        let agreementPublicKey = try PairingCrypto.agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let signingPublicKey = try PairingCrypto.signingPublicKey(for: credential)
            .base64URLEncodedString()
        let transcript = try PairingCanonicalEncoder.encode([
            "NW1.ENROLL",
            String(PairingProtocol.version),
            challenge.spaceID,
            challenge.invitationID,
            challenge.challengeID,
            challenge.challengeValue,
            String(challenge.expiresAtUnix),
            clientRequestID,
            participantID,
            agreementPublicKey,
            signingPublicKey
        ])
        var invitationCredential = credential
        invitationCredential.enrollmentSecret = invitation.enrollmentSecret
        let request = EnrollmentRequest(
            protocolVersion: PairingProtocol.version,
            clientRequestId: clientRequestID,
            challengeId: challenge.challengeID,
            participantId: participantID,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey,
            inviteProofSignature: try PairingCrypto.signInvitationProof(
                transcript,
                credential: invitationCredential
            ).base64URLEncodedString(),
            participantSignature: try PairingCrypto.sign(transcript, credential: credential)
                .base64URLEncodedString()
        )
        let response: EnrollmentResponse = try await send(
            path: "/v1/invitations/\(invitation.invitationID)/enrollments",
            method: "POST",
            body: request,
            authentication: nil
        )
        guard response.protocolVersion == PairingProtocol.version,
              response.spaceId == challenge.spaceID,
              response.dailyBoundaryMinuteUTC == challenge.dailyBoundaryMinuteUTC,
              response.member.role == "invitee",
              response.member.state == "pending",
              response.member.participantId == participantID,
              response.member.agreementPublicKey == agreementPublicKey,
              response.member.signingPublicKey == signingPublicKey,
              response.enrollment.state == "pendingApproval",
              PairingValidation.isOpaqueIdentifier(response.enrollment.id),
              PairingValidation.isOpaqueIdentifier(response.member.id),
              Data(base64URLString: response.enrollment.transcriptHash)?.count == 32
        else { throw PairingError.invalidServerResponse }
        _ = try response.member.identity.validated()
        let verificationTranscript = PairingVerificationTranscript(
            spaceID: challenge.spaceID,
            invitationID: challenge.invitationID,
            enrollmentID: response.enrollment.id,
            dailyBoundaryMinuteUTC: challenge.dailyBoundaryMinuteUTC,
            inviter: challenge.inviter,
            invitee: response.member.identity
        )
        let canonical = try verificationTranscript.canonicalData()
        guard PairingCrypto.sha256(canonical).base64URLEncodedString()
                == response.enrollment.transcriptHash,
              Data(base64URLString: response.enrollment.transcript) == canonical
        else { throw PairingError.transcriptMismatch }
        return PairingEnrollmentResult(
            enrollmentID: response.enrollment.id,
            memberID: response.member.id,
            state: response.enrollment.state,
            transcript: verificationTranscript,
            transcriptHash: response.enrollment.transcriptHash
        )
    }

    func pending(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingStatusResult {
        guard let memberID = state.memberID,
              let spaceID = state.spaceID,
              let invitationID = state.invitationID,
              let boundary = state.dailyBoundaryMinuteUTC
        else { throw PairingError.stateUnavailable }
        let response: PendingResponse = try await sendEmpty(
            path: "/v1/pairing/pending",
            method: "GET",
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        guard response.protocolVersion == PairingProtocol.version,
              response.spaceId == spaceID,
              response.pending.count <= 1
        else { throw PairingError.invalidServerResponse }
        guard let pending = response.pending.first else {
            return PairingStatusResult(
                state: "awaitingInvitee",
                peer: nil,
                transcript: nil,
                transcriptHash: nil,
                envelopeAlgorithm: nil,
                keyEnvelope: nil,
                approvalSignature: nil
            )
        }
        let inviter = PairingMemberIdentity(
            memberID: memberID,
            participantID: credential.participantIDString,
            agreementPublicKey: try PairingCrypto.agreementPublicKey(for: credential)
                .base64URLEncodedString(),
            signingPublicKey: try PairingCrypto.signingPublicKey(for: credential)
                .base64URLEncodedString()
        )
        let transcript = PairingVerificationTranscript(
            spaceID: spaceID,
            invitationID: invitationID,
            enrollmentID: pending.id,
            dailyBoundaryMinuteUTC: boundary,
            inviter: inviter,
            invitee: pending.member.identity
        )
        guard pending.state == "pendingApproval",
              pending.member.role == "invitee",
              pending.member.state == "pending",
              pending.expiresAt > pending.createdAt
        else { throw PairingError.invalidServerResponse }
        _ = try pending.member.identity.validated()
        try validateTranscriptEcho(
            transcript,
            echoedTranscript: pending.transcript,
            echoedHash: pending.transcriptHash
        )
        return PairingStatusResult(
            state: pending.state,
            peer: pending.member.identity,
            transcript: transcript,
            transcriptHash: pending.transcriptHash,
            envelopeAlgorithm: nil,
            keyEnvelope: nil,
            approvalSignature: nil
        )
    }

    func status(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingStatusResult {
        guard let memberID = state.memberID else { throw PairingError.stateUnavailable }
        let response: StatusResponse = try await sendEmpty(
            path: "/v1/pairing/status",
            method: "GET",
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        return try validatedStatus(response, localState: state, credential: credential)
    }

    func approve(
        enrollmentID: String,
        transcriptHash: String,
        keyEnvelope: String,
        approvalSignature: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws {
        let request = ApprovalRequest(
            protocolVersion: PairingProtocol.version,
            clientRequestId: clientRequestID.uuidString.lowercased(),
            transcriptHash: transcriptHash,
            envelopeAlgorithm: PairingProtocol.roomKeyEnvelopeAlgorithm,
            keyEnvelope: keyEnvelope,
            approvalSignature: approvalSignature
        )
        let response: ApprovalResponse = try await send(
            path: "/v1/pairing/enrollments/\(enrollmentID)/approve",
            method: "POST",
            body: request,
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        guard response.protocolVersion == PairingProtocol.version,
              response.enrollmentId == enrollmentID,
              response.state == "approvedAwaitingCompletion"
        else { throw PairingError.invalidServerResponse }
    }

    func complete(
        enrollmentID: String,
        transcriptHash: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws {
        let request = CompletionRequest(
            protocolVersion: PairingProtocol.version,
            clientRequestId: clientRequestID.uuidString.lowercased(),
            transcriptHash: transcriptHash
        )
        let response: CompletionResponse = try await send(
            path: "/v1/pairing/enrollments/\(enrollmentID)/complete",
            method: "POST",
            body: request,
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        guard response.protocolVersion == PairingProtocol.version,
              response.enrollmentId == enrollmentID,
              response.memberId == memberID,
              response.state == "active"
        else { throw PairingError.invalidServerResponse }
    }

    func cancelPairing(
        state: PairingState,
        revokeWholeSpace: Bool,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws {
        guard let memberID = state.memberID,
              let spaceID = state.spaceID
        else { throw PairingError.stateUnavailable }
        let request = CancellationRequest(
            protocolVersion: PairingProtocol.version,
            clientRequestId: clientRequestID.uuidString.lowercased()
        )
        let authentication = Authentication(memberID: memberID, credential: credential)
        if !revokeWholeSpace {
            guard state.role == .invitee else { throw PairingError.stateUnavailable }
            guard let enrollmentID = state.enrollmentID else {
                throw PairingError.stateUnavailable
            }
            let response: CancellationResponse = try await send(
                path: "/v1/pairing/enrollments/\(enrollmentID)/cancel",
                method: "POST",
                body: request,
                authentication: authentication
            )
            guard response.protocolVersion == PairingProtocol.version,
                  response.spaceId == spaceID,
                  response.enrollmentId == enrollmentID,
                  response.memberId == memberID,
                  response.state == "cancelled"
            else { throw PairingError.invalidServerResponse }
        } else {
            let response: RevocationResponse = try await send(
                path: "/v1/pairing/revoke",
                method: "POST",
                body: request,
                authentication: authentication
            )
            guard response.protocolVersion == PairingProtocol.version,
                  response.spaceId == spaceID,
                  response.state == "revoked",
                  response.deletionState == "pending"
            else { throw PairingError.invalidServerResponse }
        }
    }

    func createDeviceRecovery(
        state: PairingState,
        proofPublicKey: String,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryDescriptor {
        guard state.phase == .paired,
              let memberID = state.memberID,
              let targetParticipantID = state.peerParticipantID,
              Data(base64URLString: proofPublicKey)?.count == 32
        else { throw PairingError.stateUnavailable }
        let request = DeviceRecoveryCreateRequest(
            protocolVersion: 2,
            clientRequestId: clientRequestID.uuidString.lowercased(),
            targetParticipantId: targetParticipantID,
            recoveryProofPublicKey: proofPublicKey
        )
        let response: DeviceRecoveryDescriptorResponse = try await send(
            path: "/v2/device-recoveries",
            method: "POST",
            body: request,
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        let descriptor = try validatedDeviceRecoveryDescriptor(response)
        let localAgreementPublicKey = try PairingCrypto.agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let localSigningPublicKey = try PairingCrypto.signingPublicKey(for: credential)
            .base64URLEncodedString()
        guard descriptor.state == "awaitingClaim",
              response.recovery.codePrefix
                == "\(PairingProtocol.deviceRecoveryPrefix).\(descriptor.recoveryID)",
              descriptor.spaceID == state.spaceID,
              descriptor.dailyBoundaryMinuteUTC == state.dailyBoundaryMinuteUTC,
              descriptor.target.participantID == targetParticipantID,
              descriptor.target.memberID == state.peerMemberID,
              descriptor.target.agreementPublicKey == state.peerAgreementPublicKey,
              descriptor.target.signingPublicKey == state.peerSigningPublicKey,
              descriptor.peer.memberID == memberID,
              descriptor.peer.participantID == credential.participantIDString,
              descriptor.peer.agreementPublicKey == localAgreementPublicKey,
              descriptor.peer.signingPublicKey == localSigningPublicKey
        else { throw PairingError.invalidServerResponse }
        return descriptor
    }

    func deviceRecoveryDescriptor(
        recoveryID: String
    ) async throws -> PairingDeviceRecoveryDescriptor {
        guard PairingValidation.isOpaqueIdentifier(recoveryID) else {
            throw PairingError.invalidDeviceRecoveryCode
        }
        let response: DeviceRecoveryDescriptorResponse = try await sendEmpty(
            path: "/v2/device-recoveries/\(recoveryID)/descriptor",
            method: "GET",
            authentication: nil
        )
        let descriptor = try validatedDeviceRecoveryDescriptor(response)
        guard descriptor.recoveryID == recoveryID,
              descriptor.state == "awaitingClaim"
        else { throw PairingError.invalidServerResponse }
        return descriptor
    }

    func claimDeviceRecovery(
        code: PairingDeviceRecoveryCode,
        descriptor: PairingDeviceRecoveryDescriptor,
        deviceID: String,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryClaimResult {
        guard descriptor.recoveryID == code.recoveryID,
              descriptor.state == "awaitingClaim",
              descriptor.expiresAt > .now,
              descriptor.target.participantID == credential.participantIDString,
              PairingValidation.isOpaqueIdentifier(deviceID)
        else { throw PairingError.stateUnavailable }
        let agreementPublicKey = try PairingCrypto.agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let signingPublicKey = try PairingCrypto.signingPublicKey(for: credential)
            .base64URLEncodedString()
        let requestID = clientRequestID.uuidString.lowercased()
        let transcript = PairingDeviceRecoveryTranscript(
            recoveryID: descriptor.recoveryID,
            spaceID: descriptor.spaceID,
            dailyBoundaryMinuteUTC: descriptor.dailyBoundaryMinuteUTC,
            expiresAtUnix: Int(descriptor.expiresAt.timeIntervalSince1970),
            membershipRevision: descriptor.membershipRevision,
            keyEpoch: descriptor.keyEpoch,
            target: descriptor.target,
            peer: descriptor.peer,
            clientRequestID: requestID,
            deviceID: deviceID,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey
        )
        let canonical = try transcript.canonicalData()
        let request = DeviceRecoveryClaimRequest(
            protocolVersion: 2,
            clientRequestId: requestID,
            deviceId: deviceID,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey,
            recoveryProofSignature: try PairingCrypto.signDeviceRecoveryProof(
                canonical,
                secret: code.proofSecret
            ).base64URLEncodedString(),
            deviceSignature: try PairingCrypto.sign(canonical, credential: credential)
                .base64URLEncodedString()
        )
        let response: DeviceRecoveryClaimResponse = try await send(
            path: "/v2/device-recoveries/\(descriptor.recoveryID)/claim",
            method: "POST",
            body: request,
            authentication: nil
        )
        return try validatedDeviceRecoveryClaim(
            response,
            descriptor: descriptor,
            expectedTranscript: transcript,
            expectedCanonical: canonical
        )
    }

    func pendingDeviceRecovery(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryClaimResult? {
        guard state.phase == .paired,
              let memberID = state.memberID,
              let spaceID = state.spaceID,
              let recoveryID = state.recoveryID,
              let expiresAt = state.recoveryExpiresAt,
              let membershipRevision = state.recoveryMembershipRevision,
              let keyEpoch = state.recoveryKeyEpoch,
              let targetMemberID = state.peerMemberID,
              let targetParticipantID = state.peerParticipantID,
              let targetAgreement = state.recoveryPreviousTargetAgreementPublicKey,
              let targetSigning = state.recoveryPreviousTargetSigningPublicKey,
              let peerRole = state.role,
              let boundary = state.dailyBoundaryMinuteUTC
        else { throw PairingError.stateUnavailable }
        let response: DeviceRecoveryPendingResponse = try await sendEmpty(
            path: "/v2/device-recoveries/pending",
            method: "GET",
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        guard response.protocolVersion == 2,
              response.spaceId == spaceID,
              response.pending.count <= 1
        else { throw PairingError.invalidServerResponse }
        guard let pending = response.pending.first else { return nil }
        let target = PairingDeviceRecoveryIdentity(
            memberID: targetMemberID,
            participantID: targetParticipantID,
            role: peerRole == .inviter ? "invitee" : "owner",
            agreementPublicKey: targetAgreement,
            signingPublicKey: targetSigning,
            state: "active"
        )
        let localIdentity = PairingDeviceRecoveryIdentity(
            memberID: memberID,
            participantID: credential.participantIDString,
            role: peerRole == .inviter ? "owner" : "invitee",
            agreementPublicKey: try PairingCrypto.agreementPublicKey(for: credential)
                .base64URLEncodedString(),
            signingPublicKey: try PairingCrypto.signingPublicKey(for: credential)
                .base64URLEncodedString(),
            state: "active"
        )
        let descriptor = PairingDeviceRecoveryDescriptor(
            recoveryID: recoveryID,
            state: pending.recovery.state,
            createdAt: nil,
            expiresAt: expiresAt,
            membershipRevision: membershipRevision,
            keyEpoch: keyEpoch,
            spaceID: spaceID,
            dailyBoundaryMinuteUTC: boundary,
            target: target,
            peer: localIdentity
        )
        guard let claimRequestID = pending.recovery.clientRequestId,
              let claimedDeviceID = pending.recovery.deviceId
        else { throw PairingError.invalidServerResponse }
        let expected = PairingDeviceRecoveryTranscript(
            recoveryID: recoveryID,
            spaceID: spaceID,
            dailyBoundaryMinuteUTC: boundary,
            expiresAtUnix: Int(expiresAt.timeIntervalSince1970),
            membershipRevision: membershipRevision,
            keyEpoch: keyEpoch,
            target: target,
            peer: localIdentity,
            clientRequestID: claimRequestID,
            deviceID: claimedDeviceID,
            agreementPublicKey: pending.credential.agreementPublicKey,
            signingPublicKey: pending.credential.signingPublicKey
        )
        let canonical = try expected.canonicalData()
        guard pending.recovery.id == recoveryID,
              pending.recovery.state == "pendingApproval",
              pending.recovery.expiresAt == Int(expiresAt.timeIntervalSince1970),
              pending.recovery.membershipRevision == membershipRevision,
              pending.recovery.keyEpoch == keyEpoch,
              pending.peer == localIdentity,
              pending.credential.memberID == targetMemberID,
              pending.credential.participantID == targetParticipantID,
              pending.credential.state == "pending"
        else { throw PairingError.invalidServerResponse }
        return try validatedDeviceRecoveryClaim(
            DeviceRecoveryClaimResponse(
                protocolVersion: 2,
                recovery: pending.recovery,
                credential: pending.credential,
                peer: pending.peer
            ),
            descriptor: descriptor,
            expectedTranscript: expected,
            expectedCanonical: canonical
        )
    }

    func approveDeviceRecovery(
        recoveryID: String,
        targetMemberID: String,
        deviceID: String,
        membershipRevision: Int,
        keyEpoch: Int,
        transcriptHash: String,
        keyEnvelope: String,
        approvalSignature: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws {
        let request = DeviceRecoveryApprovalRequest(
            protocolVersion: 2,
            clientRequestId: clientRequestID.uuidString.lowercased(),
            transcriptHash: transcriptHash,
            envelopeAlgorithm: PairingProtocol.roomKeyEnvelopeAlgorithm,
            keyEnvelope: keyEnvelope,
            approvalSignature: approvalSignature
        )
        let response: DeviceRecoveryApprovalResponse = try await send(
            path: "/v2/device-recoveries/\(recoveryID)/approve",
            method: "POST",
            body: request,
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        guard response.protocolVersion == 2,
              response.recoveryId == recoveryID,
              response.targetMemberId == targetMemberID,
              response.deviceId == deviceID,
              response.membershipRevision == membershipRevision,
              response.keyEpoch == keyEpoch,
              response.state == "approvedAwaitingCompletion"
        else { throw PairingError.invalidServerResponse }
    }

    func deviceRecoveryStatus(
        recoveryID: String,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryStatusResult {
        let response: DeviceRecoveryStatusResponse = try await sendEmpty(
            path: "/v2/device-recoveries/\(recoveryID)/status",
            method: "GET",
            authentication: .deviceRecovery(recoveryID: recoveryID, credential: credential)
        )
        return try validatedDeviceRecoveryStatus(response, recoveryID: recoveryID, credential: credential)
    }

    func sponsorDeviceRecoveryStatus(
        state: PairingState,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryStatusResult {
        guard state.phase == .paired,
              let recoveryID = state.recoveryID,
              let memberID = state.memberID
        else { throw PairingError.stateUnavailable }
        let response: DeviceRecoveryStatusResponse = try await sendEmpty(
            path: "/v2/device-recoveries/\(recoveryID)/sponsor-status",
            method: "GET",
            authentication: Authentication(memberID: memberID, credential: credential)
        )
        let result = try validatedDeviceRecoveryStatus(
            response,
            recoveryID: recoveryID,
            credential: nil
        )
        let localAgreementPublicKey = try PairingCrypto.agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let localSigningPublicKey = try PairingCrypto.signingPublicKey(for: credential)
            .base64URLEncodedString()
        guard result.spaceID == state.spaceID,
              result.membershipRevision == state.recoveryMembershipRevision,
              result.keyEpoch == state.recoveryKeyEpoch,
              result.peer.memberID == memberID,
              result.peer.participantID == credential.participantIDString,
              result.peer.agreementPublicKey == localAgreementPublicKey,
              result.peer.signingPublicKey == localSigningPublicKey,
              result.credential.memberID == state.peerMemberID,
              result.credential.participantID == state.peerParticipantID
        else { throw PairingError.invalidServerResponse }
        return result
    }

    func completeDeviceRecovery(
        recoveryID: String,
        transcriptHash: String,
        clientRequestID: UUID,
        credential: PairingCredential
    ) async throws -> PairingDeviceRecoveryStatusResult {
        let request = DeviceRecoveryCompletionRequest(
            protocolVersion: 2,
            clientRequestId: clientRequestID.uuidString.lowercased(),
            transcriptHash: transcriptHash
        )
        let response: DeviceRecoveryStatusResponse = try await send(
            path: "/v2/device-recoveries/\(recoveryID)/complete",
            method: "POST",
            body: request,
            authentication: .deviceRecovery(recoveryID: recoveryID, credential: credential)
        )
        let result = try validatedDeviceRecoveryStatus(
            response,
            recoveryID: recoveryID,
            credential: credential
        )
        guard result.state == "active",
              result.credential.state == "active",
              result.recoveredAt != nil,
              result.keyEnvelope == nil
        else { throw PairingError.invalidServerResponse }
        return result
    }

    private func validatedDeviceRecoveryDescriptor(
        _ response: DeviceRecoveryDescriptorResponse
    ) throws -> PairingDeviceRecoveryDescriptor {
        guard response.protocolVersion == 2,
              PairingValidation.isOpaqueIdentifier(response.recovery.id),
              ["awaitingClaim", "pendingApproval"].contains(response.recovery.state),
              response.recovery.expiresAt > Int(Date().timeIntervalSince1970),
              response.recovery.membershipRevision > 0,
              response.recovery.keyEpoch > 0,
              let deviceID = response.recovery.deviceId,
              PairingValidation.isOpaqueIdentifier(deviceID),
              PairingValidation.isOpaqueIdentifier(response.space.id),
              (0...1_439).contains(response.space.dailyBoundaryMinuteUTC),
              response.target.memberID != response.peer.memberID,
              response.target.participantID != response.peer.participantID,
              response.target.pairingRole != response.peer.pairingRole
        else { throw PairingError.invalidServerResponse }
        _ = try response.target.validated(allowedStates: ["active"])
        _ = try response.peer.validated(allowedStates: ["active"])
        return PairingDeviceRecoveryDescriptor(
            recoveryID: response.recovery.id,
            state: response.recovery.state,
            createdAt: response.recovery.createdAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.recovery.expiresAt)),
            membershipRevision: response.recovery.membershipRevision,
            keyEpoch: response.recovery.keyEpoch,
            spaceID: response.space.id,
            dailyBoundaryMinuteUTC: response.space.dailyBoundaryMinuteUTC,
            target: response.target,
            peer: response.peer
        )
    }

    private func validatedDeviceRecoveryClaim(
        _ response: DeviceRecoveryClaimResponse,
        descriptor: PairingDeviceRecoveryDescriptor,
        expectedTranscript: PairingDeviceRecoveryTranscript,
        expectedCanonical: Data
    ) throws -> PairingDeviceRecoveryClaimResult {
        guard response.protocolVersion == 2,
              response.recovery.id == descriptor.recoveryID,
              response.recovery.state == "pendingApproval",
              response.recovery.expiresAt
                == Int(descriptor.expiresAt.timeIntervalSince1970),
              response.recovery.membershipRevision == descriptor.membershipRevision,
              response.recovery.keyEpoch == descriptor.keyEpoch,
              response.credential.memberID == descriptor.target.memberID,
              response.credential.participantID == descriptor.target.participantID,
              response.credential.role == descriptor.target.role,
              response.credential.agreementPublicKey == expectedTranscript.agreementPublicKey,
              response.credential.signingPublicKey == expectedTranscript.signingPublicKey,
              response.credential.state == "pending",
              response.peer == descriptor.peer,
              let transcriptValue = response.recovery.transcript,
              let transcriptData = Data(base64URLString: transcriptValue),
              transcriptData == expectedCanonical,
              let hashValue = response.recovery.transcriptHash,
              let hashData = Data(base64URLString: hashValue),
              hashData.count == 32,
              PairingCrypto.sha256(expectedCanonical) == hashData
        else { throw PairingError.transcriptMismatch }
        _ = try response.credential.validated(allowedStates: ["pending"])
        _ = try response.peer.validated(allowedStates: ["active"])
        var claimedDescriptor = descriptor
        claimedDescriptor = PairingDeviceRecoveryDescriptor(
            recoveryID: descriptor.recoveryID,
            state: "pendingApproval",
            createdAt: descriptor.createdAt,
            expiresAt: descriptor.expiresAt,
            membershipRevision: descriptor.membershipRevision,
            keyEpoch: descriptor.keyEpoch,
            spaceID: descriptor.spaceID,
            dailyBoundaryMinuteUTC: descriptor.dailyBoundaryMinuteUTC,
            target: descriptor.target,
            peer: descriptor.peer
        )
        return PairingDeviceRecoveryClaimResult(
            descriptor: claimedDescriptor,
            clientRequestID: expectedTranscript.clientRequestID,
            deviceID: expectedTranscript.deviceID,
            transcriptData: transcriptData,
            transcriptHash: hashValue,
            credential: response.credential,
            peer: response.peer
        )
    }

    private func validatedDeviceRecoveryStatus(
        _ response: DeviceRecoveryStatusResponse,
        recoveryID: String,
        credential: PairingCredential?
    ) throws -> PairingDeviceRecoveryStatusResult {
        let localAgreement = try credential.map {
            try PairingCrypto.agreementPublicKey(for: $0).base64URLEncodedString()
        }
        let localSigning = try credential.map {
            try PairingCrypto.signingPublicKey(for: $0).base64URLEncodedString()
        }
        guard response.protocolVersion == 2,
              response.recovery.id == recoveryID,
              ["pendingApproval", "approvedAwaitingCompletion", "active", "expired"]
                .contains(response.recovery.state),
              response.recovery.expiresAt > 0,
              response.recovery.membershipRevision > 0,
              response.recovery.keyEpoch > 0,
              PairingValidation.isOpaqueIdentifier(response.space.id),
              (0...1_439).contains(response.space.dailyBoundaryMinuteUTC),
              credential == nil || response.credential.participantID == credential?.participantIDString,
              credential == nil || response.credential.agreementPublicKey == localAgreement,
              credential == nil || response.credential.signingPublicKey == localSigning,
              response.peer.memberID != response.credential.memberID,
              response.peer.participantID != response.credential.participantID,
              response.peer.pairingRole != response.credential.pairingRole,
              let transcriptValue = response.recovery.transcript,
              let transcriptData = Data(base64URLString: transcriptValue),
              let hashValue = response.recovery.transcriptHash,
              let hashData = Data(base64URLString: hashValue),
              hashData.count == 32,
              PairingCrypto.sha256(transcriptData) == hashData,
              Data(base64URLString: response.previousTargetSigningPublicKey)?.count == 32
        else { throw PairingError.invalidServerResponse }
        _ = try response.credential.validated(allowedStates: ["pending", "active"])
        _ = try response.peer.validated(allowedStates: ["active"])
        let envelope = response.recovery.keyEnvelope
        if let envelope {
            guard response.recovery.state == "approvedAwaitingCompletion",
                  envelope.algorithm == PairingProtocol.roomKeyEnvelopeAlgorithm,
                  Data(base64URLString: envelope.ciphertext)?.count == 60,
                  Data(base64URLString: envelope.approvalSignature)?.count == 64
            else { throw PairingError.invalidServerResponse }
        } else if response.recovery.state == "approvedAwaitingCompletion" {
            throw PairingError.invalidServerResponse
        }
        if response.recovery.state == "active" {
            guard response.credential.state == "active",
                  response.recoveredAt != nil,
                  envelope == nil
            else { throw PairingError.invalidServerResponse }
        }
        return PairingDeviceRecoveryStatusResult(
            recoveryID: recoveryID,
            deviceID: deviceID,
            state: response.recovery.state,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.recovery.expiresAt)),
            membershipRevision: response.recovery.membershipRevision,
            keyEpoch: response.recovery.keyEpoch,
            spaceID: response.space.id,
            dailyBoundaryMinuteUTC: response.space.dailyBoundaryMinuteUTC,
            transcriptData: transcriptData,
            transcriptHash: hashValue,
            credential: response.credential,
            peer: response.peer,
            envelopeAlgorithm: envelope?.algorithm,
            keyEnvelope: envelope?.ciphertext,
            approvalSignature: envelope?.approvalSignature,
            recoveredAt: response.recoveredAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            previousTargetSigningPublicKey: response.previousTargetSigningPublicKey
        )
    }

    private func validatedChallenge(
        _ response: ChallengeResponse,
        invitation: PairingInvitationCode
    ) throws -> PairingChallengeResult {
        guard response.invitationId == invitation.invitationID,
              response.protocolVersion == PairingProtocol.version,
              PairingValidation.isOpaqueIdentifier(response.spaceId),
              PairingValidation.isOpaqueIdentifier(response.challenge.id),
              Data(base64URLString: response.challenge.value)?.count == 32,
              (0...1_439).contains(response.dailyBoundaryMinuteUTC)
        else { throw PairingError.invalidServerResponse }
        _ = try response.inviter.validated()
        return PairingChallengeResult(
            invitationID: response.invitationId,
            spaceID: response.spaceId,
            challengeID: response.challenge.id,
            challengeValue: response.challenge.value,
            expiresAtUnix: response.challenge.expiresAt,
            inviter: response.inviter,
            dailyBoundaryMinuteUTC: response.dailyBoundaryMinuteUTC
        )
    }

    private func validatedStatus(
        _ response: StatusResponse,
        localState: PairingState,
        credential: PairingCredential
    ) throws -> PairingStatusResult {
        let localAgreementPublicKey = try PairingCrypto.agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let localSigningPublicKey = try PairingCrypto.signingPublicKey(for: credential)
            .base64URLEncodedString()
        guard response.protocolVersion == PairingProtocol.version,
              response.spaceId == localState.spaceID,
              response.dailyBoundaryMinuteUTC == localState.dailyBoundaryMinuteUTC,
              response.member.id == localState.memberID,
              response.member.participantId == credential.participantIDString,
              response.member.agreementPublicKey == localAgreementPublicKey,
              response.member.signingPublicKey == localSigningPublicKey
        else { throw PairingError.invalidServerResponse }
        _ = try response.member.identity.validated()
        let expectedLocalRole = localState.role == .inviter ? "owner" : "invitee"
        guard response.member.role == expectedLocalRole,
              ["awaitingInvitee", "pendingApproval", "approvedAwaitingCompletion", "active", "cancelled", "expired"]
                .contains(response.pairing.state)
        else { throw PairingError.invalidServerResponse }

        switch response.pairing.state {
        case "awaitingInvitee":
            guard response.pairing.enrollment == nil,
                  response.pairing.peer == nil,
                  response.pairing.keyEnvelope == nil
            else { throw PairingError.invalidServerResponse }
        case "pendingApproval":
            guard response.pairing.enrollment != nil,
                  response.pairing.peer != nil,
                  response.pairing.keyEnvelope == nil
            else { throw PairingError.invalidServerResponse }
        case "approvedAwaitingCompletion":
            guard response.pairing.enrollment != nil,
                  response.pairing.peer != nil,
                  (localState.role == .invitee
                    ? response.pairing.keyEnvelope != nil
                    : response.pairing.keyEnvelope == nil)
            else { throw PairingError.invalidServerResponse }
        case "active":
            guard response.pairing.peer != nil,
                  response.pairing.keyEnvelope == nil
            else { throw PairingError.invalidServerResponse }
        case "cancelled":
            guard response.pairing.enrollment != nil,
                  response.pairing.peer != nil,
                  response.pairing.keyEnvelope == nil
            else { throw PairingError.invalidServerResponse }
        case "expired":
            guard response.pairing.keyEnvelope == nil else {
                throw PairingError.invalidServerResponse
            }
        default:
            throw PairingError.invalidServerResponse
        }
        if let peer = response.pairing.peer {
            let expectedPeerRole = localState.role == .inviter ? "invitee" : "owner"
            guard peer.role == expectedPeerRole else { throw PairingError.invalidServerResponse }
            _ = try peer.identity.validated()
        }
        let transcript: PairingVerificationTranscript?
        if let enrollment = response.pairing.enrollment,
           let peer = response.pairing.peer,
           let invitationID = localState.invitationID {
            let local = response.member.identity
            let identities = localState.role == .inviter
                ? (inviter: local, invitee: peer.identity)
                : (inviter: peer.identity, invitee: local)
            let builtTranscript = PairingVerificationTranscript(
                spaceID: response.spaceId,
                invitationID: invitationID,
                enrollmentID: enrollment.id,
                dailyBoundaryMinuteUTC: response.dailyBoundaryMinuteUTC,
                inviter: identities.inviter,
                invitee: identities.invitee
            )
            transcript = builtTranscript
            try validateTranscriptEcho(
                builtTranscript,
                echoedTranscript: enrollment.transcript,
                echoedHash: enrollment.transcriptHash
            )
        } else {
            transcript = nil
        }
        if let envelope = response.pairing.keyEnvelope {
            guard envelope.algorithm == PairingProtocol.roomKeyEnvelopeAlgorithm,
                  Data(base64URLString: envelope.ciphertext)?.count == 60,
                  Data(base64URLString: envelope.approvalSignature)?.count == 64
            else { throw PairingError.invalidServerResponse }
        }
        return PairingStatusResult(
            state: response.pairing.state,
            peer: response.pairing.peer?.identity,
            transcript: transcript,
            transcriptHash: response.pairing.enrollment?.transcriptHash,
            envelopeAlgorithm: response.pairing.keyEnvelope?.algorithm,
            keyEnvelope: response.pairing.keyEnvelope?.ciphertext,
            approvalSignature: response.pairing.keyEnvelope?.approvalSignature
        )
    }

    private func validateTranscriptEcho(
        _ transcript: PairingVerificationTranscript,
        echoedTranscript: String,
        echoedHash: String
    ) throws {
        let canonical = try transcript.canonicalData()
        guard Data(base64URLString: echoedTranscript) == canonical,
              PairingCrypto.sha256(canonical).base64URLEncodedString() == echoedHash
        else { throw PairingError.transcriptMismatch }
    }

    private func sendEmpty<Response: Decodable>(
        path: String,
        method: String,
        authentication: Authentication?
    ) async throws -> Response {
        try await sendData(
            path: path,
            method: method,
            body: Data(),
            authentication: authentication
        )
    }

    private func send<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Request,
        authentication: Authentication?
    ) async throws -> Response {
        try await sendData(
            path: path,
            method: method,
            body: try encoder.encode(body),
            authentication: authentication
        )
    }

    private func sendData<Response: Decodable>(
        path: String,
        method: String,
        body: Data,
        authentication: Authentication?
    ) async throws -> Response {
        guard path.hasPrefix("/"), !path.contains("?") else {
            throw PairingError.invalidServerResponse
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PairingError.apiNotConfigured
        }
        components.path = path
        guard let url = components.url else { throw PairingError.apiNotConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authentication {
            try authenticate(
                request: &request,
                path: path,
                method: method,
                body: body,
                authentication: authentication
            )
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.invalidServerResponse
        }
        let maximumResponseBytes = 65_536
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int.init), contentLength > maximumResponseBytes {
            throw PairingError.invalidServerResponse
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw PairingError.invalidServerResponse
            }
            data.append(byte)
        }
        guard (200...299).contains(http.statusCode) else {
            let apiError = try? decoder.decode(APIErrorResponse.self, from: data)
            let serverMessage = apiError.map {
                String($0.error.message.prefix(240))
            }
            throw PairingError.requestRejected(
                status: http.statusCode,
                code: apiError?.error.code,
                message: serverMessage ?? "共有サーバーで処理を完了できませんでした（\(http.statusCode)）。"
            )
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PairingError.invalidServerResponse
        }
    }

    private func authenticate(
        request: inout URLRequest,
        path: String,
        method: String,
        body: Data,
        authentication: Authentication
    ) throws {
        guard PairingValidation.isOpaqueIdentifier(authentication.memberID) else {
            throw PairingError.malformedCredential
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = PairingCrypto.randomData(count: 16).base64URLEncodedString()
        let bodyHash = PairingCrypto.sha256(body).base64URLEncodedString()
        let transcript: Data
        let protocolVersion: Int
        switch authentication.domain {
        case .pairing:
            protocolVersion = PairingProtocol.version
            transcript = try PairingCanonicalEncoder.encode([
                "NW1.REQUEST",
                String(PairingProtocol.version),
                authentication.memberID,
                String(timestamp),
                nonce,
                method.uppercased(),
                path,
                bodyHash
            ])
        case .deviceRecovery:
            protocolVersion = 2
            transcript = try PairingCrypto.deviceRecoverySignedRequestTranscript(
                recoveryID: authentication.memberID,
                timestamp: timestamp,
                nonce: nonce,
                method: method,
                path: path,
                bodySHA256: bodyHash
            )
        }
        let signature = try PairingCrypto.sign(transcript, credential: authentication.credential)
            .base64URLEncodedString()
        request.setValue(String(protocolVersion), forHTTPHeaderField: "Neko-Protocol-Version")
        request.setValue(authentication.memberID, forHTTPHeaderField: "Neko-Member-ID")
        if let deviceID = authentication.credential.deviceID {
            request.setValue(deviceID, forHTTPHeaderField: "Neko-Device-ID")
        }
        request.setValue(String(timestamp), forHTTPHeaderField: "Neko-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "Neko-Nonce")
        request.setValue(signature, forHTTPHeaderField: "Neko-Signature")
    }
}

private final class PairingNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Signed identity headers and invite-proof payloads must never follow
        // an origin redirect. The caller can retry only against configured URL.
        completionHandler(nil)
    }
}

private struct Authentication {
    enum Domain {
        case pairing
        case deviceRecovery
    }

    let memberID: String
    let credential: PairingCredential
    let domain: Domain

    init(memberID: String, credential: PairingCredential) {
        self.memberID = memberID
        self.credential = credential
        domain = .pairing
    }

    static func deviceRecovery(
        recoveryID: String,
        credential: PairingCredential
    ) -> Self {
        Self(memberID: recoveryID, credential: credential, domain: .deviceRecovery)
    }

    private init(memberID: String, credential: PairingCredential, domain: Domain) {
        self.memberID = memberID
        self.credential = credential
        self.domain = domain
    }
}

private struct CreateSpaceRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let participantId: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let invitationProofPublicKey: String
    let dailyBoundaryMinuteUTC: Int
    let creationSignature: String
}

private struct CreateSpaceResponse: Decodable {
    let protocolVersion: Int
    let spaceId: String
    let dailyBoundaryMinuteUTC: Int
    let member: ServerMember
    struct Invitation: Decodable {
        let id: String
        let state: String
        let expiresAt: Int
    }
    let invitation: Invitation
}

private struct ChallengeResponse: Decodable {
    let protocolVersion: Int
    struct Challenge: Decodable {
        let id: String
        let value: String
        let expiresAt: Int
    }
    let invitationId: String
    let spaceId: String
    let challenge: Challenge
    let inviter: PairingMemberIdentity
    let dailyBoundaryMinuteUTC: Int
}

private struct EnrollmentRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let challengeId: String
    let participantId: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let inviteProofSignature: String
    let participantSignature: String
}

private struct EnrollmentResponse: Decodable {
    struct Enrollment: Decodable {
        let id: String
        let state: String
        let createdAt: Int
        let expiresAt: Int
        let transcript: String
        let transcriptHash: String
    }
    let protocolVersion: Int
    let spaceId: String
    let dailyBoundaryMinuteUTC: Int
    let member: ServerMember
    let enrollment: Enrollment
}

private struct PendingResponse: Decodable {
    struct Pending: Decodable {
        let id: String
        let state: String
        let createdAt: Int
        let expiresAt: Int
        let transcript: String
        let transcriptHash: String
        let member: ServerMember
    }
    let protocolVersion: Int
    let spaceId: String
    let pending: [Pending]
}

private struct StatusResponse: Decodable {
    struct Pairing: Decodable {
        struct Enrollment: Decodable {
            let id: String
            let createdAt: Int
            let expiresAt: Int
            let transcript: String
            let transcriptHash: String
        }
        struct KeyEnvelope: Decodable {
            let algorithm: String
            let ciphertext: String
            let approvalSignature: String
            let approvedAt: Int
        }
        let state: String
        let enrollment: Enrollment?
        let peer: ServerMember?
        let keyEnvelope: KeyEnvelope?
    }
    let protocolVersion: Int
    let spaceId: String
    let dailyBoundaryMinuteUTC: Int
    let member: ServerMember
    let pairing: Pairing
}

private struct ServerMember: Decodable {
    let id: String
    let role: String
    let state: String
    let participantId: String
    let agreementPublicKey: String
    let signingPublicKey: String

    var identity: PairingMemberIdentity {
        PairingMemberIdentity(
            memberID: id,
            participantID: participantId,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey
        )
    }
}

private struct ApprovalRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let transcriptHash: String
    let envelopeAlgorithm: String
    let keyEnvelope: String
    let approvalSignature: String
}

private struct CompletionRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let transcriptHash: String
}

private struct CancellationRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
}

private struct ApprovalResponse: Decodable {
    let protocolVersion: Int
    let spaceId: String
    let enrollmentId: String
    let state: String
    let approvedAt: Int
}

private struct CompletionResponse: Decodable {
    let protocolVersion: Int
    let spaceId: String
    let enrollmentId: String
    let memberId: String
    let state: String
    let activatedAt: Int
}

private struct CancellationResponse: Decodable {
    let protocolVersion: Int
    let spaceId: String
    let enrollmentId: String
    let memberId: String
    let state: String
}

private struct RevocationResponse: Decodable {
    let protocolVersion: Int
    let spaceId: String
    let state: String
    let deletionState: String
}

private struct DeviceRecoverySpace: Decodable {
    let id: String
    let dailyBoundaryMinuteUTC: Int
}

private struct DeviceRecoveryKeyEnvelope: Decodable {
    let algorithm: String
    let ciphertext: String
    let approvalSignature: String
    let approvedAt: Int
}

private struct DeviceRecoveryMetadata: Decodable {
    let id: String
    let state: String
    let codePrefix: String?
    let createdAt: Int?
    let expiresAt: Int
    let membershipRevision: Int
    let keyEpoch: Int
    let clientRequestId: String?
    let deviceId: String?
    let transcript: String?
    let transcriptHash: String?
    let keyEnvelope: DeviceRecoveryKeyEnvelope?
}

private struct DeviceRecoveryCreateRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let targetParticipantId: String
    let recoveryProofPublicKey: String
}

private struct DeviceRecoveryDescriptorResponse: Decodable {
    let protocolVersion: Int
    let recovery: DeviceRecoveryMetadata
    let space: DeviceRecoverySpace
    let target: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
}

private struct DeviceRecoveryClaimRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let deviceId: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let recoveryProofSignature: String
    let deviceSignature: String
}

private struct DeviceRecoveryClaimResponse: Decodable {
    let protocolVersion: Int
    let recovery: DeviceRecoveryMetadata
    let credential: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
}

private struct DeviceRecoveryPendingItem: Decodable {
    let recovery: DeviceRecoveryMetadata
    let credential: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
}

private struct DeviceRecoveryPendingResponse: Decodable {
    let protocolVersion: Int
    let spaceId: String
    let pending: [DeviceRecoveryPendingItem]
}

private struct DeviceRecoveryApprovalRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let transcriptHash: String
    let envelopeAlgorithm: String
    let keyEnvelope: String
    let approvalSignature: String
}

private struct DeviceRecoveryApprovalResponse: Decodable {
    let protocolVersion: Int
    let recoveryId: String
    let targetMemberId: String
    let deviceId: String
    let membershipRevision: Int
    let keyEpoch: Int
    let state: String
}

private struct DeviceRecoveryCompletionRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let transcriptHash: String
}

private struct DeviceRecoveryStatusResponse: Decodable {
    let protocolVersion: Int
    let recovery: DeviceRecoveryMetadata
    let space: DeviceRecoverySpace
    let credential: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
    let previousTargetSigningPublicKey: String
    let recoveredAt: Int?
}

private struct APIErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
    let error: ErrorBody
}

/// CI entry point for decoding the Worker-owned golden response fixture with
/// the exact DTOs used by the production client.
enum PairingAPIContractVerifier {
    static func verifyGoldenResponses(_ data: Data) throws {
        struct Fixture: Decodable {
            let schemaVersion: Int
            let create: CreateSpaceResponse
            let challenge: ChallengeResponse
            let enrollment: EnrollmentResponse
            let pending: PendingResponse
            let statusApprovedInvitee: StatusResponse
            let approve: ApprovalResponse
            let complete: CompletionResponse
            let cancel: CancellationResponse
            let revoke: RevocationResponse
        }
        let value = try JSONDecoder().decode(Fixture.self, from: data)
        guard value.schemaVersion == PairingProtocol.version,
              value.create.protocolVersion == PairingProtocol.version,
              value.challenge.protocolVersion == PairingProtocol.version,
              value.enrollment.protocolVersion == PairingProtocol.version,
              value.pending.protocolVersion == PairingProtocol.version,
              value.statusApprovedInvitee.protocolVersion == PairingProtocol.version,
              value.approve.protocolVersion == PairingProtocol.version,
              value.complete.protocolVersion == PairingProtocol.version,
              value.cancel.protocolVersion == PairingProtocol.version,
              value.cancel.state == "cancelled",
              value.revoke.protocolVersion == PairingProtocol.version,
              value.revoke.state == "revoked",
              value.revoke.deletionState == "pending",
              value.statusApprovedInvitee.pairing.keyEnvelope?.approvalSignature.isEmpty == false
        else { throw PairingError.invalidServerResponse }
    }
}
