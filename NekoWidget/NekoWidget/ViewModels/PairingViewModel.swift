import Foundation
import SwiftUI

@MainActor
final class PairingViewModel: ObservableObject {
    @Published private(set) var state: PairingState?
    @Published private(set) var invitationCode: String?
    @Published private(set) var isWorking = false
    @Published private(set) var configurationMessage: String?
    @Published private(set) var windowDisplayName = PrivateWindowDisplayName.fallback
    @Published private(set) var isSynchronizingWindowName = false
    @Published private(set) var windowNameStatusMessage: String?
    @Published private(set) var windowNameStatusIsError = false
    @Published private(set) var manualCheckMessage: String?
    @Published private(set) var manualCheckCompletedAt: Date?
    @Published private(set) var manualCheckSucceeded: Bool?
    @Published private(set) var operationCompletionMessage: String?
    @Published private(set) var operationErrorMessage: String?
    @Published var enteredInvitationCode = ""
    @Published var hasConfirmedPhrase = false

    private let configuration: SharingAPIConfiguration
    private let windowNameCoordinator: MomentSharingCoordinator
    private var api: (any PairingAPIClientProtocol)?
    private var didBootstrap = false

    init(configuration: SharingAPIConfiguration = .current) {
        self.configuration = configuration
        windowNameCoordinator = MomentSharingCoordinator(configuration: configuration)
        if configuration.isAvailable {
            do {
                api = try URLSessionPairingAPIClient(configuration: configuration)
            } catch {
                configurationMessage = Self.userFacingMessage(for: error)
            }
        } else {
            configurationMessage = "共有はこの開発ビルドでは未接続です。"
        }
    }

    var isConfigured: Bool { api != nil }
    var isMediaSyncEnabled: Bool { configuration.isMediaAvailable }
    var canEditWindowDisplayName: Bool { state?.role != .invitee }
    var userFacingStatusMessage: String? {
        if let operationErrorMessage { return operationErrorMessage }
        if let configurationMessage { return configurationMessage }
        // Build 34 and earlier could persist arbitrary relay text or a raw
        // Keychain status in lastError. Never render that legacy string.
        if state?.lastError != nil {
            return "前回の共有操作を完了できませんでした。画面の案内を確認して、もう一度お試しください。"
        }
        return nil
    }
    var hasCurrentMediaSharingConsent: Bool {
        state?.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion
            && state?.mediaSharingConsentAcceptedAt != nil
    }

    @discardableResult
    func recordMediaSharingConsent() -> Bool {
        guard configuration.isMediaAvailable else { return false }
        do {
            let operation = try beginOperation()
            var current = operation.expectedState
            current.mediaSharingConsentVersion = PairingMediaSharingConsent.currentVersion
            current.mediaSharingConsentAcceptedAt = .now
            current.lastUpdatedAt = .now
            current.lastError = nil
            current = try persist(current, operation: operation)
            return true
        } catch {
            record(error)
            return false
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            let result = try await PairingInstallationGuard.bootstrapAsync()
            if result.invalidatedPreviousInstallation {
                configurationMessage = Self.message(for: .installationChanged)
            }
            let operation = try beginOperation()
            let current = operation.expectedState
            let lifecycleToken = operation.lifecycleToken
            windowDisplayName = PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: current,
                validating: lifecycleToken
            )
            bestEffortScrubConsumedInvitationSecret(
                for: current,
                lifecycleToken: lifecycleToken
            )
            try restoreInvitationCodeIfAvailable(
                from: current,
                lifecycleToken: lifecycleToken
            )
            if isConfigured,
               [.awaitingInvitee, .pendingApproval, .awaitingCompletion]
                .contains(current.phase) {
                await refresh(isManual: false)
            }
        } catch {
            configurationMessage = Self.userFacingMessage(for: error)
        }
    }

    /// Updates presentation metadata only. PairingState and its exact-state
    /// CAS revision remain untouched, so a label edit cannot interrupt a
    /// concurrent approval, refresh, consent, or cancellation operation.
    @discardableResult
    func updateWindowDisplayName(_ rawValue: String) async -> Bool {
        guard canEditWindowDisplayName else {
            configurationMessage = "まどの名前は、まどを作った人が変更できます。"
            return false
        }
        guard !isSynchronizingWindowName, !isWorking else { return false }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch {
            configurationMessage = Self.userFacingMessage(for: error)
            return false
        }
        do {
            let saved = try PrivateWindowPresentationStore.save(
                displayName: rawValue,
                pairing: operation.expectedState,
                validating: operation.lifecycleToken
            )
            windowDisplayName = saved.displayName
            configurationMessage = nil
            windowNameStatusIsError = false
            windowNameStatusMessage = operation.expectedState.phase == .paired
                ? "このiPhoneに保存しました。相手へ共有しています…"
                : "このiPhoneに保存しました。ペアリング完了後に相手へ共有します。"
            NotificationCenter.default.post(
                name: .momentSharingPresentationNeedsRefresh,
                object: nil
            )
            guard operation.expectedState.phase == .paired else { return true }

            isSynchronizingWindowName = true
            defer { isSynchronizingWindowName = false }
            do {
                try await windowNameCoordinator.synchronizeWindowNameForUser(
                    trigger: "explicit-window-name-save"
                )
                windowNameStatusIsError = false
                windowNameStatusMessage = "相手のiPhoneへ反映できる状態です。"
            } catch {
                // Refresh from disk because a terminal authenticated response
                // may have revoked and purged the pairing while this call was
                // awaiting the relay.
                reloadWindowDisplayName()
                windowNameStatusIsError = true
                if state?.phase == .paired {
                    // The local edit is durable when only the relay is
                    // unavailable. Keep this copy free of internal details.
                    windowNameStatusMessage =
                        "このiPhoneには保存しましたが、相手への共有を完了できませんでした。もう一度お試しください。"
                } else {
                    windowNameStatusMessage =
                        "共有が解除されたため保存内容を消去しました。もう一度ペアリングしてください。"
                }
                SharedLog.app.warning(
                    "window-name-sync",
                    "Explicit private window name synchronization failed"
                )
            }
            return true
        } catch {
            configurationMessage = Self.userFacingMessage(for: error)
            windowNameStatusIsError = true
            windowNameStatusMessage = "まどの名前を保存できませんでした。"
            SharedLog.app.error(
                "window-presentation",
                "Private window display name could not be saved",
                metadata: SharedLog.errorMetadata(error, category: .pairing)
            )
            return false
        }
    }

    func reloadWindowDisplayName() {
        do {
            let operation = try beginOperation()
            windowDisplayName = PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: operation.expectedState,
                validating: operation.lifecycleToken
            )
        } catch {
            // Keep the last verified presentation value. Pairing/bootstrap
            // surfaces authority failures through its existing status path.
        }
    }

    func createInvitation(dailyBoundaryMinuteUTC: Int) async {
        clearTransientOperationFeedback()
        guard let api else {
            configurationMessage = Self.message(for: .apiNotConfigured)
            return
        }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
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
                current.phase = .creatingInvitation
                current.role = .inviter
                current.credentialAccount = credential.account
                current.participantID = credential.participantIDString
                current.dailyBoundaryMinuteUTC = dailyBoundaryMinuteUTC
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "create"
                current.pendingCancelRevokesWholeSpace = nil
                current.lastError = nil
                current = try persistInitialCredential(
                    credential,
                    state: current,
                    operation: operation
                )
            }

            guard let effectiveBoundary = current.dailyBoundaryMinuteUTC else {
                throw PairingError.stateUnavailable
            }
            try SharingLifecycleGate.validate(lifecycleToken)
            let result = try await api.createSpace(
                credential: credential,
                dailyBoundaryMinuteUTC: effectiveBoundary,
                clientRequestID: requestID
            )
            try SharingLifecycleGate.validate(lifecycleToken)
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
            current = try persist(current, operation: operation)
            try SharingLifecycleGate.validate(lifecycleToken)
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
                    try await resetLocalPairing(
                        operation: operation,
                        message: "招待作成の応答を復元できませんでした。もう一度招待を作成してください。"
                    )
                } catch {
                    record(error, operation: operation)
                }
                return
            }
            record(error, operation: operation)
        }
    }

    func joinInvitation() async {
        clearTransientOperationFeedback()
        guard let api else {
            configurationMessage = Self.message(for: .apiNotConfigured)
            return
        }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
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
                current.phase = .joining
                current.role = .invitee
                current.credentialAccount = credential.account
                current.participantID = credential.participantIDString
                current.invitationID = invitation.invitationID
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "enroll"
                current.pendingCancelRevokesWholeSpace = nil
                current.lastError = nil
                current = try persistInitialCredential(
                    credential,
                    state: current,
                    operation: operation
                )
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
                try SharingLifecycleGate.validate(lifecycleToken)
                challenge = try await api.requestChallenge(invitation: invitation)
                try SharingLifecycleGate.validate(lifecycleToken)
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
                current = try persist(current, operation: operation)
            }

            try SharingLifecycleGate.validate(lifecycleToken)
            let result = try await api.enroll(
                invitation: invitation,
                challenge: challenge,
                clientRequestID: requestID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
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
            current = try persist(current, operation: operation)
            bestEffortScrubConsumedInvitationSecret(
                for: current,
                lifecycleToken: lifecycleToken
            )
            enteredInvitationCode = ""
            SharedLog.app.info("pairing", "Enrollment submitted")
        } catch {
            if let pairingError = error as? PairingError,
               case let .requestRejected(status, code, _) = pairingError,
               [404, 409, 410].contains(status)
                || (status == 401 && code == "invalid_enrollment_proof") {
                do {
                    try await resetLocalPairing(
                        operation: operation,
                        message: Self.message(for: pairingError)
                    )
                } catch {
                    record(error, operation: operation)
                }
                return
            }
            record(error, operation: operation)
        }
    }

    func refresh(isManual: Bool = true) async {
        guard let api else { return }
        operationErrorMessage = nil
        if isManual {
            manualCheckMessage = nil
            manualCheckCompletedAt = nil
            manualCheckSucceeded = nil
        }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
        guard let account = current.credentialAccount else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            bestEffortScrubConsumedInvitationSecret(
                for: current,
                lifecycleToken: lifecycleToken
            )
            var credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
            if current.role == .inviter,
               current.phase == .awaitingInvitee,
               let expiresAt = current.invitationExpiresAt,
               expiresAt <= .now {
                credential.enrollmentSecret = nil
                try PairingKeychainStore.save(
                    credential,
                    lifecycleToken: lifecycleToken
                )
                invitationCode = nil
                current.phase = .failed
                current.lastError = "招待コードの有効期限が切れました。新しい招待が必要です。"
                current.lastUpdatedAt = .now
                current = try persist(current, operation: operation)
                return
            }
            switch current.role {
            case .inviter:
                if current.phase == .awaitingCompletion || current.phase == .paired {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let result = try await api.status(state: current, credential: credential)
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try applyOwnerStatus(result, to: &current)
                } else {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let result = try await api.pending(state: current, credential: credential)
                    try SharingLifecycleGate.validate(lifecycleToken)
                    if let transcript = result.transcript,
                       let hash = result.transcriptHash {
                        try applyTranscript(transcript, hash: hash, to: &current)
                        current.phase = .approvalRequired
                    }
                }
            case .invitee:
                try SharingLifecycleGate.validate(lifecycleToken)
                let result = try await api.status(state: current, credential: credential)
                try SharingLifecycleGate.validate(lifecycleToken)
                if result.state == "approvedAwaitingCompletion" {
                    try await finishInviteePairing(
                        result,
                        state: &current,
                        credential: credential,
                        api: api,
                        operation: operation
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
            current = try persist(current, operation: operation)
            bestEffortScrubConsumedInvitationSecret(
                for: current,
                lifecycleToken: lifecycleToken
            )
            if isManual {
                manualCheckCompletedAt = .now
                manualCheckSucceeded = true
                manualCheckMessage = Self.manualCheckMessage(for: current.phase)
            }
        } catch {
            if let pairingError = error as? PairingError,
               Self.serverConfirmsPairingIsGone(pairingError)
                || (current.role == .invitee
                    && Self.isExpiredEnrollment(pairingError)) {
                do {
                    let message = Self.isInvalidAuthentication(pairingError)
                        ? "共有の有効期限が切れました。もう一度招待してください。"
                        : Self.message(for: pairingError)
                    try await resetLocalPairing(operation: operation, message: message)
                } catch {
                    record(error, operation: operation)
                }
                return
            }
            record(error, operation: operation)
            if isManual {
                manualCheckCompletedAt = .now
                manualCheckSucceeded = false
                manualCheckMessage = "確認を完了できませんでした。画面の案内を確認して、もう一度お試しください。"
            }
        }
    }

    private static func manualCheckMessage(for phase: PairingPhase) -> String {
        switch phase {
        case .awaitingInvitee:
            return "確認処理が終わりました。まだ相手の参加を待っています。"
        case .pendingApproval:
            return "確認処理が終わりました。まだ、まどを作った人の承認を待っています。"
        case .awaitingCompletion:
            return "確認処理が終わりました。まだ相手のiPhoneでの確認を待っています。"
        case .paired:
            return "確認処理が終わりました。このまどは接続されています。"
        default:
            return "確認処理が終わりました。画面に表示されている次の操作へ進んでください。"
        }
    }

    func approveAfterPhraseConfirmation() async {
        clearTransientOperationFeedback()
        guard hasConfirmedPhrase else {
            record(PairingError.approvalNotConfirmed)
            return
        }
        guard let api else { return }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
        guard
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
                current = try persist(current, operation: operation)
            }
            try SharingLifecycleGate.validate(lifecycleToken)
            try await api.approve(
                enrollmentID: enrollmentID,
                transcriptHash: transcriptHashValue,
                keyEnvelope: envelopeValue,
                approvalSignature: signatureValue,
                clientRequestID: requestID,
                memberID: memberID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            var scrubbedCredential = credential
            scrubbedCredential.enrollmentSecret = nil
            try PairingKeychainStore.save(
                scrubbedCredential,
                lifecycleToken: lifecycleToken
            )
            invitationCode = nil
            current.phase = .awaitingCompletion
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.pendingCancelRevokesWholeSpace = nil
            current.pendingKeyEnvelope = nil
            current.pendingApprovalSignature = nil
            current.lastUpdatedAt = .now
            current.lastError = nil
            current = try persist(current, operation: operation)
            SharedLog.app.info("pairing", "Peer explicitly approved")
        } catch {
            record(error, operation: operation)
        }
    }

    func cancelAndReset() async {
        clearTransientOperationFeedback()
        guard let api else { return }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
        guard
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
                try SharingLifecycleGate.validate(lifecycleToken)
                let latest = try await api.status(state: current, credential: credential)
                try SharingLifecycleGate.validate(lifecycleToken)
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
                current = try persist(current, operation: operation)
            }
            try await cancelServerPairing(
                api: api,
                state: &current,
                credential: credential,
                requestID: requestID,
                revokeWholeSpace: revokeWholeSpace,
                operation: operation
            )
            try await resetLocalPairing(operation: operation)
            operationCompletionMessage =
                "共有を解除しました。このiPhoneの共有鍵、届いた写真、まど内の思い出の印を削除しました。"
            SharedLog.app.info("pairing", "Pairing cancelled and local keys removed")
        } catch {
            // A transport failure deliberately keeps the exact cancellation
            // request and credentials so the user can retry safely.
            record(error, operation: operation)
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
        revokeWholeSpace: Bool,
        operation: PairingOperation
    ) async throws {
        let lifecycleToken = operation.lifecycleToken
        do {
            try SharingLifecycleGate.validate(lifecycleToken)
            try await api.cancelPairing(
                state: current,
                revokeWholeSpace: revokeWholeSpace,
                clientRequestID: requestID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
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
                try SharingLifecycleGate.validate(lifecycleToken)
                latest = try await api.status(state: current, credential: credential)
                try SharingLifecycleGate.validate(lifecycleToken)
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
                current = try persist(current, operation: operation)
                do {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try await api.cancelPairing(
                        state: current,
                        revokeWholeSpace: true,
                        clientRequestID: revokeRequestID,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
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
        api: any PairingAPIClientProtocol,
        operation: PairingOperation
    ) async throws {
        let lifecycleToken = operation.lifecycleToken
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
        try PairingKeychainStore.save(
            updatedCredential,
            lifecycleToken: lifecycleToken
        )

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
            current = try persist(current, operation: operation)
        }
        try SharingLifecycleGate.validate(lifecycleToken)
        try await api.complete(
            enrollmentID: enrollmentID,
            transcriptHash: transcriptHashValue,
            clientRequestID: completionID,
            memberID: memberID,
            credential: updatedCredential
        )
        try SharingLifecycleGate.validate(lifecycleToken)
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

    private final class PairingOperation {
        let lifecycleToken: SharingLifecycleGate.Token
        var expectedState: PairingState

        init(
            lifecycleToken: SharingLifecycleGate.Token,
            expectedState: PairingState
        ) {
            self.lifecycleToken = lifecycleToken
            self.expectedState = expectedState
        }
    }

    /// Token and metadata are captured under the same short lifecycle flock.
    /// `state` is refreshed from disk here so a cleanup/re-pair cannot combine
    /// a new epoch token with stale MainActor state.
    private func beginOperation() throws -> PairingOperation {
        let snapshot = try PairingStateStore.beginOperation()
        guard let current = snapshot.state else {
            throw PairingError.stateUnavailable
        }
        state = current
        return PairingOperation(
            lifecycleToken: snapshot.lifecycleToken,
            expectedState: current
        )
    }

    private func clearTransientOperationFeedback() {
        manualCheckMessage = nil
        manualCheckCompletedAt = nil
        manualCheckSucceeded = nil
        operationCompletionMessage = nil
        operationErrorMessage = nil
    }

    /// Saves with an exact-state CAS, then returns the decoded committed value.
    /// Callers must replace their local operation state with this return value
    /// before another mutation so storageRevision and ISO-8601 dates stay exact.
    @discardableResult
    private func persist(
        _ value: PairingState,
        operation: PairingOperation
    ) throws -> PairingState {
        let previous = operation.expectedState
        guard value.storageRevision == previous.storageRevision
        else { throw PairingError.stateUnavailable }
        let validated = try value.validated()
        let committed = try PairingStateStore.save(
            validated,
            expected: previous,
            lifecycleToken: operation.lifecycleToken
        )
        operation.expectedState = committed
        state = committed
        let becamePaired = previous.phase != .paired && committed.phase == .paired
        let acceptedMediaNow = previous.mediaSharingConsentVersion
            != PairingMediaSharingConsent.currentVersion
            && committed.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion
        if (becamePaired || acceptedMediaNow),
           committed.pendingOperation == nil,
           committed.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
           committed.mediaSharingConsentAcceptedAt != nil {
            NotificationCenter.default.post(name: .sharingMediaSyncRequested, object: nil)
        }
        return committed
    }

    /// Publishes the initial credential account and recoverable operation state
    /// under one short lifecycle flock. Crash-before-state remains recoverable
    /// by bootstrap's orphan cleanup; bootstrap cannot interleave between the
    /// two writes while this process is alive.
    private func persistInitialCredential(
        _ credential: PairingCredential,
        state value: PairingState,
        operation: PairingOperation
    ) throws -> PairingState {
        let committed = try PairingStateStore.saveInitialCredentialAndState(
            credential: credential,
            state: try value.validated(),
            expected: operation.expectedState,
            lifecycleToken: operation.lifecycleToken
        )
        operation.expectedState = committed
        state = committed
        return committed
    }

    private func restoreInvitationCodeIfAvailable(
        from state: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        guard
              state.role == .inviter,
              state.phase == .awaitingInvitee,
              let account = state.credentialAccount,
              let invitationID = state.invitationID
        else { return }
        try SharingLifecycleGate.validate(lifecycleToken)
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: state.installationMarker
        )
        guard let secret = credential.enrollmentSecret else { return }
        try SharingLifecycleGate.validate(lifecycleToken)
        invitationCode = try PairingInvitationCode(
            invitationID: invitationID,
            enrollmentSecret: secret
        ).code
    }

    private func bestEffortScrubConsumedInvitationSecret(
        for state: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) {
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
            try PairingKeychainStore.save(
                credential,
                lifecycleToken: lifecycleToken
            )
            invitationCode = nil
        } catch {
            // The state is already recoverable. Keep pairing usable and retry
            // this narrow cleanup on the next bootstrap/refresh.
            SharedLog.app.error(
                "pairing",
                "Could not remove consumed invitation material",
                metadata: SharedLog.errorMetadata(error, category: .pairing)
            )
        }
    }

    private func resetLocalPairing(
        operation: PairingOperation,
        message: String? = nil
    ) async throws {
        _ = try await PairingInstallationGuard.resetLocalSharingAsync(
            expectedState: operation.expectedState,
            lifecycleToken: operation.lifecycleToken,
            message: message
        )
        // Reload the exact durable value before any later CAS; this also
        // prevents a stale operation from retaining the pre-cleanup state.
        let snapshot = try PairingStateStore.beginOperation()
        guard let reset = snapshot.state else { throw PairingError.stateUnavailable }
        state = reset
        if let message {
            operationErrorMessage = message
        }
        windowDisplayName = PrivateWindowDisplayName.fallback
        invitationCode = nil
        enteredInvitationCode = ""
        hasConfirmedPhrase = false
        NotificationCenter.default.post(name: .sharingMediaSyncRequested, object: nil)
    }

    private func record(
        _ error: Error,
        operation: PairingOperation? = nil
    ) {
        operationErrorMessage = Self.userFacingMessage(for: error)
        if let operation {
            var updated = operation.expectedState
            updated.lastError = operationErrorMessage
            updated.lastUpdatedAt = .now
            do {
                _ = try persist(updated, operation: operation)
            } catch {
                // The operation may have been invalidated by unlink/reinstall
                // or lost an exact-state CAS. Reload only; never issue a fresh
                // token and write an old operation's error into the new state.
                if let snapshot = try? PairingStateStore.beginOperation() {
                    state = snapshot.state
                }
            }
        }
        SharedLog.app.error(
            "pairing",
            "Pairing operation failed",
            metadata: SharedLog.errorMetadata(error, category: .pairing)
        )
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let pairingError = error as? PairingError {
            return message(for: pairingError)
        }
        if error is URLError {
            return "通信を完了できませんでした。接続を確認して、もう一度お試しください。"
        }
        return "共有の状態を確認できませんでした。時間をおいて、もう一度お試しください。"
    }

    private static func message(for error: PairingError) -> String {
        error.errorDescription
            ?? "共有の処理を完了できませんでした。状態を確認して、もう一度お試しください。"
    }
}
