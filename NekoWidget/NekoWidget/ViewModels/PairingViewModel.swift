import Foundation
import SwiftUI

@MainActor
final class PairingViewModel: ObservableObject {
    @Published private(set) var state: PairingState?
    @Published private(set) var invitationCode: String?
    @Published private(set) var isWorking = false
    @Published private(set) var configurationMessage: String?
    @Published var enteredInvitationCode = ""
    @Published var hasConfirmedPhrase = false

    private let configuration: SharingAPIConfiguration
    private var api: (any PairingAPIClientProtocol)?
    private var didBootstrap = false

    init(configuration: SharingAPIConfiguration = .current) {
        self.configuration = configuration
        if configuration.isAvailable {
            do {
                api = try URLSessionPairingAPIClient(configuration: configuration)
            } catch {
                configurationMessage = error.localizedDescription
            }
        } else {
            configurationMessage = "共有はこの開発ビルドでは未接続です。"
        }
    }

    var isConfigured: Bool { api != nil }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            let result = try PairingInstallationGuard.bootstrap()
            state = result.state
            if result.invalidatedPreviousInstallation {
                configurationMessage = PairingError.installationChanged.localizedDescription
            }
            bestEffortScrubConsumedInvitationSecret(for: result.state)
            try restoreInvitationCodeIfAvailable()
            if isConfigured,
               [.awaitingInvitee, .pendingApproval, .awaitingCompletion]
                .contains(result.state.phase) {
                await refresh()
            }
        } catch {
            configurationMessage = error.localizedDescription
        }
    }

    func createInvitation(dailyBoundaryMinuteUTC: Int) async {
        guard let api else {
            configurationMessage = PairingError.apiNotConfigured.localizedDescription
            return
        }
        guard var current = state else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let credential: PairingCredential
            let requestID: UUID
            if current.phase == .creatingInvitation,
               let account = current.credentialAccount,
               let value = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)) {
                credential = try PairingKeychainStore.load(
                    account: account,
                    installationMarker: current.installationMarker
                )
                requestID = value
            } else {
                guard current.phase == .unpaired else { throw PairingError.stateUnavailable }
                credential = PairingCrypto.makeCredential(
                    installationMarker: current.installationMarker,
                    includesInvitationSecret: true,
                    includesRoomKey: true
                )
                requestID = UUID()
                try PairingKeychainStore.save(credential)
                current.phase = .creatingInvitation
                current.role = .inviter
                current.credentialAccount = credential.account
                current.participantID = credential.participantIDString
                current.dailyBoundaryMinuteUTC = dailyBoundaryMinuteUTC
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "create"
                current.pendingCancelRevokesWholeSpace = nil
                current.lastError = nil
                try persist(current)
            }

            guard let effectiveBoundary = current.dailyBoundaryMinuteUTC else {
                throw PairingError.stateUnavailable
            }
            let result = try await api.createSpace(
                credential: credential,
                dailyBoundaryMinuteUTC: effectiveBoundary,
                clientRequestID: requestID
            )
            guard let secret = credential.enrollmentSecret else {
                throw PairingError.malformedCredential
            }
            let invitation = try PairingInvitationCode(
                invitationID: result.invitationID,
                enrollmentSecret: secret
            )
            current.phase = .awaitingInvitee
            current.spaceID = result.spaceID
            current.memberID = result.memberID
            current.invitationID = result.invitationID
            current.invitationExpiresAt = result.expiresAt
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.lastUpdatedAt = .now
            current.lastError = nil
            try persist(current)
            invitationCode = invitation.code
            SharedLog.app.info("pairing", "Invitation created")
        } catch {
            if let pairingError = error as? PairingError,
               current.phase == .creatingInvitation,
               case let .requestRejected(status, code, _) = pairingError,
               status == 409,
               code == "space_creation_conflict" || code == "idempotency_conflict" {
                do {
                    // The create response is no longer recoverable, so the
                    // client never learned IDs it could use for signed revoke.
                    // Reset only local sharing data; the server expires the
                    // unreachable, unused space under its inactivity TTL.
                    try resetLocalPairing(
                        message: "招待作成の応答を復元できませんでした。もう一度招待を作成してください。"
                    )
                } catch {
                    record(error)
                }
                return
            }
            record(error)
        }
    }

    func joinInvitation() async {
        guard let api else {
            configurationMessage = PairingError.apiNotConfigured.localizedDescription
            return
        }
        guard var current = state else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let invitation: PairingInvitationCode
            let credential: PairingCredential
            let requestID: UUID

            if current.phase == .joining,
               let invitationID = current.invitationID,
               let account = current.credentialAccount,
               let existingRequestID = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)) {
                credential = try PairingKeychainStore.load(
                    account: account,
                    installationMarker: current.installationMarker
                )
                guard let secret = credential.enrollmentSecret else {
                    throw PairingError.malformedCredential
                }
                invitation = try PairingInvitationCode(
                    invitationID: invitationID,
                    enrollmentSecret: secret
                )
                requestID = existingRequestID
            } else {
                guard current.phase == .unpaired else { throw PairingError.stateUnavailable }
                invitation = try PairingInvitationCode(code: enteredInvitationCode)
                var generated = PairingCrypto.makeCredential(
                    installationMarker: current.installationMarker,
                    includesInvitationSecret: false,
                    includesRoomKey: false
                )
                generated.enrollmentSecret = invitation.enrollmentSecret
                credential = generated
                requestID = UUID()
                try PairingKeychainStore.save(credential)
                current.phase = .joining
                current.role = .invitee
                current.credentialAccount = credential.account
                current.participantID = credential.participantIDString
                current.invitationID = invitation.invitationID
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "enroll"
                current.pendingCancelRevokesWholeSpace = nil
                current.lastError = nil
                try persist(current)
            }

            let challenge: PairingChallengeResult
            if let challengeID = current.challengeID,
               let challengeValue = current.challengeValue,
               let expiresAt = current.challengeExpiresAtUnix,
               let spaceID = current.spaceID,
               let boundary = current.dailyBoundaryMinuteUTC,
               let peerParticipantID = current.peerParticipantID,
               let peerAgreement = current.peerAgreementPublicKey,
               let peerSigning = current.peerSigningPublicKey {
                challenge = PairingChallengeResult(
                    invitationID: invitation.invitationID,
                    spaceID: spaceID,
                    challengeID: challengeID,
                    challengeValue: challengeValue,
                    expiresAtUnix: expiresAt,
                    inviter: PairingMemberIdentity(
                        memberID: current.peerMemberID ?? "",
                        participantID: peerParticipantID,
                        agreementPublicKey: peerAgreement,
                        signingPublicKey: peerSigning
                    ),
                    dailyBoundaryMinuteUTC: boundary
                )
            } else {
                challenge = try await api.requestChallenge(invitation: invitation)
                current.spaceID = challenge.spaceID
                current.dailyBoundaryMinuteUTC = challenge.dailyBoundaryMinuteUTC
                current.peerMemberID = challenge.inviter.memberID
                current.peerParticipantID = challenge.inviter.participantID
                current.peerAgreementPublicKey = challenge.inviter.agreementPublicKey
                current.peerSigningPublicKey = challenge.inviter.signingPublicKey
                current.challengeID = challenge.challengeID
                current.challengeValue = challenge.challengeValue
                current.challengeExpiresAtUnix = challenge.expiresAtUnix
                current.lastUpdatedAt = .now
                try persist(current)
            }

            let result = try await api.enroll(
                invitation: invitation,
                challenge: challenge,
                clientRequestID: requestID,
                credential: credential
            )
            current.phase = .pendingApproval
            current.memberID = result.memberID
            current.enrollmentID = result.enrollmentID
            current.transcript = try result.transcript.canonicalData().base64URLEncodedString()
            current.transcriptHash = result.transcriptHash
            current.verificationPhrase = PairingCrypto.verificationPhrase(
                for: try result.transcript.hash()
            )
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.challengeID = nil
            current.challengeValue = nil
            current.challengeExpiresAtUnix = nil
            current.lastUpdatedAt = .now
            current.lastError = nil
            // Crash-order invariant: publish the recoverable server state
            // before deleting the one-time secret. A crash here can leave an
            // unnecessary secret, which bootstrap scrubs; the inverse order
            // would leave `.joining` without the secret needed for retry.
            try persist(current)
            bestEffortScrubConsumedInvitationSecret(for: current)
            enteredInvitationCode = ""
            SharedLog.app.info("pairing", "Enrollment submitted")
        } catch {
            if let pairingError = error as? PairingError,
               case let .requestRejected(status, code, _) = pairingError,
               [404, 409, 410].contains(status)
                || (status == 401 && code == "invalid_enrollment_proof") {
                do {
                    try resetLocalPairing(message: pairingError.localizedDescription)
                } catch {
                    record(error)
                }
                return
            }
            record(error)
        }
    }

    func refresh() async {
        guard let api, var current = state,
              let account = current.credentialAccount
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            bestEffortScrubConsumedInvitationSecret(for: current)
            var credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
            if current.role == .inviter,
               current.phase == .awaitingInvitee,
               let expiresAt = current.invitationExpiresAt,
               expiresAt <= .now {
                credential.enrollmentSecret = nil
                try PairingKeychainStore.save(credential)
                invitationCode = nil
                current.phase = .failed
                current.lastError = "招待コードの有効期限が切れました。新しい招待が必要です。"
                current.lastUpdatedAt = .now
                try persist(current)
                return
            }
            switch current.role {
            case .inviter:
                if current.phase == .awaitingCompletion || current.phase == .paired {
                    let result = try await api.status(state: current, credential: credential)
                    try applyOwnerStatus(result, to: &current)
                } else {
                    let result = try await api.pending(state: current, credential: credential)
                    if let transcript = result.transcript,
                       let hash = result.transcriptHash {
                        try applyTranscript(transcript, hash: hash, to: &current)
                        current.phase = .approvalRequired
                    }
                }
            case .invitee:
                let result = try await api.status(state: current, credential: credential)
                if result.state == "approvedAwaitingCompletion" {
                    try await finishInviteePairing(
                        result,
                        state: &current,
                        credential: credential,
                        api: api
                    )
                } else if result.state == "active" {
                    current.phase = .paired
                    current.pendingClientRequestID = nil
                    current.pendingOperation = nil
                } else if result.state == "expired" {
                    throw PairingError.requestRejected(
                        status: 410,
                        code: "enrollment_expired",
                        message: "招待の期限が切れました。"
                    )
                } else if result.state == "cancelled" {
                    throw PairingError.requestRejected(
                        status: 410,
                        code: "sharing_revoked",
                        message: "このペアリングは取り消されました。もう一度招待してください。"
                    )
                }
            case nil:
                throw PairingError.stateUnavailable
            }
            current.lastUpdatedAt = .now
            current.lastError = nil
            try persist(current)
            bestEffortScrubConsumedInvitationSecret(for: current)
        } catch {
            if let pairingError = error as? PairingError,
               Self.serverConfirmsPairingIsGone(pairingError)
                || (current.role == .invitee
                    && Self.isExpiredEnrollment(pairingError)) {
                do {
                    let message = Self.isInvalidAuthentication(pairingError)
                        ? "共有の有効期限が切れました。もう一度招待してください。"
                        : pairingError.localizedDescription
                    try resetLocalPairing(message: message)
                } catch {
                    record(error)
                }
                return
            }
            record(error)
        }
    }

    func approveAfterPhraseConfirmation() async {
        guard hasConfirmedPhrase else {
            record(PairingError.approvalNotConfirmed)
            return
        }
        guard let api, var current = state,
              current.phase == .approvalRequired,
              let account = current.credentialAccount,
              let memberID = current.memberID,
              let enrollmentID = current.enrollmentID,
              let transcriptValue = current.transcript,
              let transcript = Data(base64URLString: transcriptValue),
              let transcriptHashValue = current.transcriptHash,
              let transcriptHash = Data(base64URLString: transcriptHashValue),
              let peerAgreementValue = current.peerAgreementPublicKey,
              let peerAgreement = Data(base64URLString: peerAgreementValue)
        else {
            record(PairingError.stateUnavailable)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
            guard let roomKey = credential.roomKey else {
                throw PairingError.malformedCredential
            }
            let requestID: UUID
            let envelopeValue: String
            let signatureValue: String
            if current.pendingOperation == "approve",
               let savedRequestID = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)),
               let savedEnvelope = current.pendingKeyEnvelope,
               let savedSignature = current.pendingApprovalSignature {
                requestID = savedRequestID
                envelopeValue = savedEnvelope
                signatureValue = savedSignature
            } else {
                requestID = UUID()
                envelopeValue = try PairingCrypto.makeRoomKeyEnvelope(
                    roomKey: roomKey,
                    peerAgreementPublicKey: peerAgreement,
                    transcript: transcript,
                    transcriptHash: transcriptHash,
                    credential: credential
                ).base64URLEncodedString()
                let approvalTranscript = try PairingCrypto.approvalTranscript(
                    transcriptHash: transcriptHashValue,
                    envelopeAlgorithm: PairingProtocol.roomKeyEnvelopeAlgorithm,
                    keyEnvelope: envelopeValue
                )
                signatureValue = try PairingCrypto.sign(
                    approvalTranscript,
                    credential: credential
                ).base64URLEncodedString()
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "approve"
                current.pendingCancelRevokesWholeSpace = nil
                current.pendingKeyEnvelope = envelopeValue
                current.pendingApprovalSignature = signatureValue
                current.lastUpdatedAt = .now
                try persist(current)
            }
            try await api.approve(
                enrollmentID: enrollmentID,
                transcriptHash: transcriptHashValue,
                keyEnvelope: envelopeValue,
                approvalSignature: signatureValue,
                clientRequestID: requestID,
                memberID: memberID,
                credential: credential
            )
            var scrubbedCredential = credential
            scrubbedCredential.enrollmentSecret = nil
            try PairingKeychainStore.save(scrubbedCredential)
            invitationCode = nil
            current.phase = .awaitingCompletion
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.pendingCancelRevokesWholeSpace = nil
            current.pendingKeyEnvelope = nil
            current.pendingApprovalSignature = nil
            current.lastUpdatedAt = .now
            current.lastError = nil
            try persist(current)
            SharedLog.app.info("pairing", "Peer explicitly approved")
        } catch {
            record(error)
        }
    }

    func cancelAndReset() async {
        guard let api, var current = state,
              current.role != nil,
              let account = current.credentialAccount,
              current.memberID != nil,
              current.spaceID != nil
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
            var revokeWholeSpace = current.pendingOperation == "cancel"
                ? current.pendingCancelRevokesWholeSpace ?? false
                : current.phase == .paired || current.role == .inviter
            if current.pendingOperation != "cancel",
               current.role == .invitee,
               current.pendingOperation == "complete" {
                let latest = try await api.status(state: current, credential: credential)
                revokeWholeSpace = latest.state == "active"
                guard revokeWholeSpace || latest.state == "approvedAwaitingCompletion" else {
                    throw PairingError.invalidServerResponse
                }
            }
            let requestID: UUID
            if current.pendingOperation == "cancel",
               let saved = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)) {
                requestID = saved
            } else {
                requestID = UUID()
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "cancel"
                current.pendingCancelRevokesWholeSpace = revokeWholeSpace
                current.pendingKeyEnvelope = nil
                current.pendingApprovalSignature = nil
                current.lastUpdatedAt = .now
                try persist(current)
            }
            try await cancelServerPairing(
                api: api,
                state: &current,
                credential: credential,
                requestID: requestID,
                revokeWholeSpace: revokeWholeSpace
            )
            try resetLocalPairing()
            SharedLog.app.info("pairing", "Pairing cancelled and local keys removed")
        } catch {
            // A transport failure deliberately keeps the exact cancellation
            // request and credentials so the user can retry safely.
            record(error)
        }
    }

    /// Cancels the exact persisted operation. A transport error is propagated
    /// without changing its request ID or body. We only reconcile after the
    /// server explicitly reports a state conflict; completion may have won the
    /// race, in which case the now-active invitee must revoke the whole space.
    private func cancelServerPairing(
        api: any PairingAPIClientProtocol,
        state current: inout PairingState,
        credential: PairingCredential,
        requestID: UUID,
        revokeWholeSpace: Bool
    ) async throws {
        do {
            try await api.cancelPairing(
                state: current,
                revokeWholeSpace: revokeWholeSpace,
                clientRequestID: requestID,
                credential: credential
            )
            return
        } catch let error as PairingError {
            if Self.serverConfirmsPairingIsGone(error) {
                return
            }
            guard case let .requestRejected(status, code, _) = error,
                  status == 409,
                  code == "invalid_pairing_state"
            else { throw error }

            let latest: PairingStatusResult
            do {
                latest = try await api.status(state: current, credential: credential)
            } catch let statusError as PairingError {
                if Self.serverConfirmsPairingIsGone(statusError) {
                    return
                }
                throw statusError
            }

            switch latest.state {
            case "expired", "cancelled":
                return
            case "active" where !revokeWholeSpace:
                // Persist a new operation before sending it. Retrying after an
                // app/transport interruption will resend this exact revoke body.
                let revokeRequestID = UUID()
                current.pendingClientRequestID = revokeRequestID.uuidString
                current.pendingOperation = "cancel"
                current.pendingCancelRevokesWholeSpace = true
                current.lastUpdatedAt = .now
                try persist(current)
                do {
                    try await api.cancelPairing(
                        state: current,
                        revokeWholeSpace: true,
                        clientRequestID: revokeRequestID,
                        credential: credential
                    )
                } catch let revokeError as PairingError {
                    if Self.serverConfirmsPairingIsGone(revokeError) {
                        return
                    }
                    throw revokeError
                }
            default:
                // The original cancellation may still be valid. Preserve its
                // persisted request rather than silently changing semantics.
                throw error
            }
        }
    }

    private static func serverConfirmsPairingIsGone(_ error: PairingError) -> Bool {
        guard case let .requestRejected(status, code, _) = error else { return false }
        return (status == 401 && code == "invalid_authentication")
            || (status == 410 && code == "sharing_revoked")
    }

    private static func isInvalidAuthentication(_ error: PairingError) -> Bool {
        guard case let .requestRejected(status, code, _) = error else { return false }
        return status == 401 && code == "invalid_authentication"
    }

    private static func isExpiredEnrollment(_ error: PairingError) -> Bool {
        guard case let .requestRejected(status, code, _) = error else { return false }
        return status == 410 && code == "enrollment_expired"
    }

    private func finishInviteePairing(
        _ result: PairingStatusResult,
        state current: inout PairingState,
        credential: PairingCredential,
        api: any PairingAPIClientProtocol
    ) async throws {
        guard let transcriptModel = result.transcript,
              let transcriptHashValue = result.transcriptHash,
              let transcriptHash = Data(base64URLString: transcriptHashValue),
              let algorithm = result.envelopeAlgorithm,
              let envelopeValue = result.keyEnvelope,
              let envelope = Data(base64URLString: envelopeValue),
              let signatureValue = result.approvalSignature,
              let signature = Data(base64URLString: signatureValue),
              let peerSigningValue = current.peerSigningPublicKey,
              let peerSigning = Data(base64URLString: peerSigningValue),
              let peerAgreementValue = current.peerAgreementPublicKey,
              let peerAgreement = Data(base64URLString: peerAgreementValue),
              let enrollmentID = current.enrollmentID,
              let memberID = current.memberID
        else { throw PairingError.invalidServerResponse }
        try applyTranscript(transcriptModel, hash: transcriptHashValue, to: &current)
        let approvalTranscript = try PairingCrypto.approvalTranscript(
            transcriptHash: transcriptHashValue,
            envelopeAlgorithm: algorithm,
            keyEnvelope: envelopeValue
        )
        guard try PairingCrypto.verifySignature(
            signature,
            for: approvalTranscript,
            publicKey: peerSigning
        ) else { throw PairingError.transcriptMismatch }
        let canonical = try transcriptModel.canonicalData()
        let roomKey = try PairingCrypto.openRoomKeyEnvelope(
            envelope,
            peerAgreementPublicKey: peerAgreement,
            transcript: canonical,
            transcriptHash: transcriptHash,
            credential: credential
        )
        var updatedCredential = credential
        updatedCredential.roomKey = roomKey
        updatedCredential.enrollmentSecret = nil
        try PairingKeychainStore.save(updatedCredential)

        let completionID: UUID
        if current.pendingOperation == "complete",
           let saved = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)) {
            completionID = saved
        } else {
            completionID = UUID()
            current.pendingClientRequestID = completionID.uuidString
            current.pendingOperation = "complete"
            current.pendingCancelRevokesWholeSpace = nil
            current.lastUpdatedAt = .now
            try persist(current)
        }
        try await api.complete(
            enrollmentID: enrollmentID,
            transcriptHash: transcriptHashValue,
            clientRequestID: completionID,
            memberID: memberID,
            credential: updatedCredential
        )
        current.phase = .paired
        current.pendingClientRequestID = nil
        current.pendingOperation = nil
        current.pendingCancelRevokesWholeSpace = nil
    }

    private func applyOwnerStatus(
        _ result: PairingStatusResult,
        to current: inout PairingState
    ) throws {
        if let transcript = result.transcript,
           let hash = result.transcriptHash {
            try applyTranscript(transcript, hash: hash, to: &current)
        }
        switch result.state {
        case "active": current.phase = .paired
        case "approvedAwaitingCompletion": current.phase = .awaitingCompletion
        case "expired":
            throw PairingError.requestRejected(
                status: 410,
                code: "enrollment_expired",
                message: "招待の期限が切れました。"
            )
        case "cancelled":
            throw PairingError.requestRejected(
                status: 409,
                code: "pairing_cancelled",
                message: "相手が参加を取り消しました。ペアリングをやり直してください。"
            )
        default: break
        }
    }

    private func applyTranscript(
        _ transcript: PairingVerificationTranscript,
        hash: String,
        to current: inout PairingState
    ) throws {
        let canonical = try transcript.canonicalData()
        let localHash = PairingCrypto.sha256(canonical)
        guard localHash.base64URLEncodedString() == hash,
              transcript.spaceID == current.spaceID,
              transcript.invitationID == current.invitationID
        else { throw PairingError.transcriptMismatch }
        let peer = current.role == .inviter ? transcript.invitee : transcript.inviter
        current.enrollmentID = transcript.enrollmentID
        current.peerMemberID = peer.memberID
        current.peerParticipantID = peer.participantID
        current.peerAgreementPublicKey = peer.agreementPublicKey
        current.peerSigningPublicKey = peer.signingPublicKey
        current.transcript = canonical.base64URLEncodedString()
        current.transcriptHash = hash
        current.verificationPhrase = PairingCrypto.verificationPhrase(for: localHash)
        current.dailyBoundaryMinuteUTC = transcript.dailyBoundaryMinuteUTC
    }

    private func persist(_ value: PairingState) throws {
        let validated = try value.validated()
        try PairingStateStore.save(validated)
        state = validated
    }

    private func restoreInvitationCodeIfAvailable() throws {
        guard let state,
              state.role == .inviter,
              state.phase == .awaitingInvitee,
              let account = state.credentialAccount,
              let invitationID = state.invitationID
        else { return }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: state.installationMarker
        )
        guard let secret = credential.enrollmentSecret else { return }
        invitationCode = try PairingInvitationCode(
            invitationID: invitationID,
            enrollmentSecret: secret
        ).code
    }

    private func bestEffortScrubConsumedInvitationSecret(for state: PairingState) {
        let isConsumedPhase: Bool
        switch state.phase {
        case .pendingApproval, .approvalRequired, .awaitingCompletion, .paired:
            isConsumedPhase = true
        case .failed:
            isConsumedPhase = state.memberID != nil
        default:
            isConsumedPhase = false
        }
        guard isConsumedPhase, let account = state.credentialAccount else { return }
        do {
            var credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: state.installationMarker
            )
            guard credential.enrollmentSecret != nil else { return }
            credential.enrollmentSecret = nil
            try PairingKeychainStore.save(credential)
            invitationCode = nil
        } catch {
            // The state is already recoverable. Keep pairing usable and retry
            // this narrow cleanup on the next bootstrap/refresh.
            SharedLog.app.error(
                "pairing",
                "Could not scrub consumed invitation secret",
                metadata: ["reason": error.localizedDescription]
            )
        }
    }

    private func resetLocalPairing(message: String? = nil) throws {
        guard let state else { throw PairingError.stateUnavailable }
        if let account = state.credentialAccount {
            try PairingKeychainStore.delete(account: account)
        }
        try PairingStateStore.purgeAllSharingFiles()
        var reset = PairingState.unpaired(
            installationMarker: state.installationMarker
        )
        reset.lastError = message
        try PairingStateStore.save(reset)
        self.state = reset
        invitationCode = nil
        enteredInvitationCode = ""
        hasConfirmedPhrase = false
    }

    private func record(_ error: Error) {
        var updated = state
        updated?.lastError = error.localizedDescription
        updated?.lastUpdatedAt = .now
        if let updated {
            try? PairingStateStore.save(updated)
            state = updated
        }
        SharedLog.app.error(
            "pairing",
            "Pairing operation failed",
            metadata: ["reason": error.localizedDescription]
        )
    }
}
