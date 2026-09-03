import Foundation
import SwiftUI

@MainActor
final class PairingViewModel: ObservableObject {
    @Published private(set) var state: PairingState?
    @Published private(set) var invitationCode: String?
    @Published private(set) var recoveryInvitationCode: String?
    @Published private(set) var isWorking = false
    @Published private(set) var configurationMessage: String?
    @Published private(set) var windowDisplayName = PrivateWindowDisplayName.fallback
    @Published private(set) var isSynchronizingWindowName = false
    @Published private(set) var windowNameStatusMessage: String?
    @Published private(set) var windowNameStatusIsError = false
    @Published private(set) var privateWindows: [PrivateWindowCatalogEntry] = []
    @Published private(set) var activePrivateWindowID: String?
    @Published private(set) var manualCheckMessage: String?
    @Published private(set) var manualCheckCompletedAt: Date?
    @Published private(set) var manualCheckSucceeded: Bool?
    @Published private(set) var operationCompletionMessage: String?
    @Published private(set) var operationErrorMessage: String?
    @Published private(set) var bootstrapRetryMessage: String?
    @Published private(set) var isBootstrapping = false
    @Published var enteredInvitationCode = ""
    @Published var enteredRecoveryCode = ""
    @Published var hasConfirmedPhrase = false
    @Published var hasConfirmedRecoveryPhrase = false

    private let configuration: SharingAPIConfiguration
    private let windowNameCoordinator: MomentSharingCoordinator
    private var api: (any PairingAPIClientProtocol)?
    private var didBootstrap = false
    private var bootstrapRetryRequested = false

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
    var canEditWindowDisplayName: Bool {
        state?.role != .invitee && state?.localDeviceIsAdditional != true
    }
    var windowNameIsLocalDraft: Bool {
        guard let state else { return false }
        return Self.isLocalWindowNameDraft(state)
    }
    var canPersistWindowDisplayName: Bool {
        guard let state, canEditWindowDisplayName else { return false }
        return Self.isLocalWindowNameDraft(state)
            || (state.role == .inviter
                && state.spaceID != nil
                && state.participantID != nil)
    }
    var shouldShowWindowName: Bool {
        windowNameIsLocalDraft || state?.spaceID != nil
    }
    var userFacingStatusMessage: String? {
        if let operationErrorMessage { return operationErrorMessage }
        if let bootstrapRetryMessage { return bootstrapRetryMessage }
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
    var hasPendingDeviceRecovery: Bool {
        state?.recoveryID != nil && state?.recoveryCompletedAt == nil
    }
    var hasPrivateWindowSetupInProgress: Bool {
        privateWindows.contains(where: privateWindowNeedsSetup)
    }
    var canCreateAnotherPrivateWindow: Bool {
        privateWindows.count < PrivateWindowCatalogState.maximumProductWindowCount
            && !hasPrivateWindowSetupInProgress
    }
    var canCreateDeviceRecoveryInvitation: Bool {
        guard let state, state.phase == .paired else { return false }
        return state.role != .inviter || state.localDeviceIsAdditional != true
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
        if isBootstrapping {
            // Foreground and protected-data notifications can race the first
            // bootstrap. Preserve one follow-up attempt instead of dropping
            // the only signal that storage became readable.
            bootstrapRetryRequested = true
            return
        }
        isBootstrapping = true
        defer {
            isBootstrapping = false
            let shouldRetry = bootstrapRetryRequested && !didBootstrap
            bootstrapRetryRequested = false
            if shouldRetry {
                Task { await self.bootstrap() }
            }
        }
        do {
            let result = try await PairingInstallationGuard.bootstrapAsync()
            if result.invalidatedPreviousInstallation {
                configurationMessage = Self.message(for: .installationChanged)
            }
            let operation = try beginOperation()
            var current = operation.expectedState
            let lifecycleToken = operation.lifecycleToken
            if current.phase == .unpaired,
               current.pendingOperation == nil,
               current.lastError != nil {
                // A durable error from an older build describes the operation
                // that already ended, not the current recovery choice screen.
                current.lastError = nil
                current.lastUpdatedAt = .now
                current = try persist(current, operation: operation)
            }
            windowDisplayName = resolvedWindowDisplayName(
                pairing: current,
                validating: lifecycleToken
            )
            reloadPrivateWindowCatalog()
            bestEffortScrubConsumedInvitationSecret(
                for: current,
                lifecycleToken: lifecycleToken
            )
            try restoreInvitationCodeIfAvailable(
                from: current,
                lifecycleToken: lifecycleToken
            )
            try restoreRecoveryInvitationCodeIfAvailable(
                from: current,
                lifecycleToken: lifecycleToken
            )
            if isConfigured,
               current.recoveryID != nil,
               current.recoveryCompletedAt == nil {
                await refreshDeviceRecovery(isManual: false)
            } else if isConfigured,
               [.awaitingInvitee, .pendingApproval, .awaitingCompletion]
                .contains(current.phase) {
                await refresh(isManual: false)
            }
            bootstrapRetryMessage = nil
            didBootstrap = true
            if isConfigured {
                await windowNameCoordinator
                    .synchronizeInactiveWindowNamesForWindowList(
                        trigger: "window-list-bootstrap"
                    )
                reloadPrivateWindowCatalog()
            }
        } catch let error as PairingInstallationGuard.RetryableBootstrapError {
            // Data Protection/Keychain availability is not a completed
            // bootstrap. Keep this model eligible for the next foreground or
            // protected-data notification instead of freezing an empty view.
            didBootstrap = false
            bootstrapRetryMessage = Self.userFacingMessage(for: error)
        } catch {
            if Self.isRetryableBootstrapCompletionError(error) {
                didBootstrap = false
                bootstrapRetryMessage =
                    "共有の状態を一時的に確認できませんでした。iPhoneのロックを解除したまま、もう一度お試しください。"
            } else {
                didBootstrap = true
                bootstrapRetryMessage = nil
                configurationMessage = Self.userFacingMessage(for: error)
            }
        }
    }

    /// Updates presentation metadata only. PairingState and its exact-state
    /// CAS revision remain untouched, so a label edit cannot interrupt a
    /// concurrent approval, refresh, consent, or cancellation operation.
    @discardableResult
    func updateWindowDisplayName(_ rawValue: String) async -> Bool {
        guard canEditWindowDisplayName else {
            configurationMessage = state?.localDeviceIsAdditional == true
                ? "追加したiPhoneでは名前を変更できません。最初のiPhoneで変更してください。"
                : "まどの名前は、まどを作った人が変更できます。"
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
            if Self.isLocalWindowNameDraft(operation.expectedState) {
                let saved = try PairingStateStore.updateActiveDraftDisplayName(
                    rawValue,
                    expected: operation.expectedState,
                    lifecycleToken: operation.lifecycleToken
                )
                windowDisplayName = saved.displayName
                reloadPrivateWindowCatalog()
                configurationMessage = nil
                windowNameStatusIsError = false
                windowNameStatusMessage = "このiPhoneに名前を保存しました。"
                NotificationCenter.default.post(
                    name: .momentSharingPresentationNeedsRefresh,
                    object: nil
                )
                return true
            }
            guard canPersistWindowDisplayName else {
                throw PairingError.stateUnavailable
            }
            let saved = try PrivateWindowPresentationStore.save(
                displayName: rawValue,
                pairing: operation.expectedState,
                validating: operation.lifecycleToken
            )
            windowDisplayName = saved.displayName
            try? SharingLifecycleGate.withValidatedToken(operation.lifecycleToken) {
                try PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked(
                    displayName: saved.displayName,
                    spaceID: operation.expectedState.spaceID,
                    credentialAccount: operation.expectedState.credentialAccount
                )
            }
            reloadPrivateWindowCatalog()
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
        } catch PrivateWindowCatalogStore.Error.duplicateWindowName {
            configurationMessage = "同じ名前のまどがあります。区別できる名前を付けてください。"
            windowNameStatusIsError = true
            windowNameStatusMessage = "別のまどと同じ名前にはできません。"
            return false
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
            windowDisplayName = resolvedWindowDisplayName(
                pairing: operation.expectedState,
                validating: operation.lifecycleToken
            )
        } catch {
            // Keep the last verified presentation value. Pairing/bootstrap
            // surfaces authority failures through its existing status path.
        }
    }

    func createAnotherPrivateWindow() async {
        clearTransientOperationFeedback()
        guard !isWorking else { return }
        // A Widget, deep link, or another view can switch/create a window
        // without passing through this model. Re-read the authoritative
        // catalog before using its count or active selection.
        reloadPrivateWindowCatalog()
        guard canCreateAnotherPrivateWindow else {
            operationErrorMessage = hasPrivateWindowSetupInProgress
                ? "先に、設定中のまどを完了してください。"
                : "初期版では、まどは合計3個までです。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await PairingInstallationGuard
                .createAndActivatePrivateWindowAsync()
            applyActivatedWindow(result)
            operationCompletionMessage = "新しいまどを追加しました。名前を付けて相手を招待できます。"
            NotificationCenter.default.post(
                name: .momentSharingPresentationNeedsRefresh,
                object: nil
            )
            Task {
                await MomentPushSubscriptionService.shared.reconcileRegistration()
            }
        } catch {
            record(error)
        }
    }

    func activatePrivateWindow(localWindowID: String) async {
        clearTransientOperationFeedback()
        guard !isWorking else { return }
        // Do not let a cached active ID turn a legitimate switch-back into a
        // no-op after another surface changed the catalog.
        reloadPrivateWindowCatalog()
        guard localWindowID != activePrivateWindowID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await PairingInstallationGuard.activatePrivateWindowAsync(
                localWindowID: localWindowID
            )
            applyActivatedWindow(result)
            NotificationCenter.default.post(name: .sharingMediaSyncRequested, object: nil)
            NotificationCenter.default.post(
                name: .momentSharingPresentationNeedsRefresh,
                object: nil
            )
            Task {
                await MomentPushSubscriptionService.shared.reconcileRegistration()
            }
        } catch {
            record(error)
        }
    }

    private func applyActivatedWindow(
        _ result: PairingInstallationGuard.BootstrapResult
    ) {
        state = result.state
        windowDisplayName = resolvedWindowDisplayName(
            pairing: result.state,
            validating: result.lifecycleToken
        )
        invitationCode = nil
        recoveryInvitationCode = nil
        enteredInvitationCode = ""
        enteredRecoveryCode = ""
        hasConfirmedPhrase = false
        hasConfirmedRecoveryPhrase = false
        setupResetAfterWindowSelection()
        reloadPrivateWindowCatalog()
    }

    private func setupResetAfterWindowSelection() {
        manualCheckMessage = nil
        manualCheckCompletedAt = nil
        manualCheckSucceeded = nil
        windowNameStatusMessage = nil
        windowNameStatusIsError = false
    }

    private func reloadPrivateWindowCatalog() {
        guard let catalog = try? PrivateWindowCatalogStore.load() else {
            privateWindows = []
            activePrivateWindowID = nil
            return
        }
        privateWindows = catalog.windows.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.localWindowID < $1.localWindowID
        }
        activePrivateWindowID = catalog.activeWindowID
    }

    private func privateWindowNeedsSetup(_ window: PrivateWindowCatalogEntry) -> Bool {
        do {
            guard let pairing = try PairingStateStore.load(
                localWindowID: window.localWindowID
            ) else { return true }
            return pairing.phase != .paired
        } catch {
            // An unreadable slot must not become authority to create another
            // draft beside it. Keep the existing slot visible for recovery.
            return true
        }
    }

    private func resolvedWindowDisplayName(
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) -> String {
        if let presentation = try? PrivateWindowPresentationStore.load(
            pairing: pairing,
            validating: lifecycleToken
        ) {
            return presentation.displayName
        }
        return (try? SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let active = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  })
            else { throw PairingError.stateUnavailable }
            return active.displayName
        }) ?? PrivateWindowDisplayName.fallback
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
            current = try persistCreatedInvitationPromotingDraftName(
                current,
                operation: operation
            )
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
                    if let peer = result.peer {
                        try applyCurrentPeer(peer, to: &current)
                    }
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

    func createDeviceRecoveryInvitation() async {
        clearTransientOperationFeedback()
        guard canCreateDeviceRecoveryInvitation else {
            operationErrorMessage =
                "このiPhoneでは追加コードを作れません。まどを最初に作ったiPhoneで操作してください。"
            return
        }
        guard let api else {
            configurationMessage = Self.message(for: .apiNotConfigured)
            return
        }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
        guard current.phase == .paired,
              current.recoveryCompletedAt != nil || current.recoveryID == nil,
              let account = current.credentialAccount,
              let memberID = current.memberID,
              current.peerParticipantID != nil
        else {
            record(PairingError.stateUnavailable, operation: operation)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            var credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
            let requestID: UUID
            let proofSecret: Data
            if current.pendingOperation == "recoveryCreate",
               let saved = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)),
               let savedSecret = credential.enrollmentSecret {
                requestID = saved
                proofSecret = savedSecret
            } else {
                requestID = UUID()
                proofSecret = PairingCrypto.makeDeviceRecoveryProofSecret()
                credential.enrollmentSecret = proofSecret
                try PairingKeychainStore.save(
                    credential,
                    lifecycleToken: lifecycleToken
                )
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "recoveryCreate"
                current.pendingCancelRevokesWholeSpace = nil
                current.pendingKeyEnvelope = nil
                current.pendingApprovalSignature = nil
                current.lastUpdatedAt = .now
                current.lastError = nil
                current = try persist(current, operation: operation)
            }
            let proofPublicKey = try PairingCrypto.deviceRecoveryProofPublicKey(
                for: proofSecret
            ).base64URLEncodedString()
            try SharingLifecycleGate.validate(lifecycleToken)
            let descriptor = try await api.createDeviceRecovery(
                state: current,
                proofPublicKey: proofPublicKey,
                clientRequestID: requestID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            current.recoveryID = descriptor.recoveryID
            current.recoveryExpiresAt = descriptor.expiresAt
            current.recoveryMembershipRevision = descriptor.membershipRevision
            current.recoveryKeyEpoch = descriptor.keyEpoch
            current.recoveryDeviceID = nil
            current.recoveryPreviousTargetAgreementPublicKey = descriptor.target.agreementPublicKey
            current.recoveryPreviousTargetSigningPublicKey = descriptor.target.signingPublicKey
            current.recoveryCandidateAgreementPublicKey = nil
            current.recoveryCandidateSigningPublicKey = nil
            current.recoveryTranscript = nil
            current.recoveryTranscriptHash = nil
            current.recoveryVerificationPhrase = nil
            current.recoveryApprovalSubmittedAt = nil
            current.recoveryCompletedAt = nil
            current.recoveryWasLocalDeviceReplacement = nil
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.lastUpdatedAt = .now
            current.lastError = nil
            current = try persist(current, operation: operation)
            recoveryInvitationCode = try PairingDeviceRecoveryCode(
                recoveryID: descriptor.recoveryID,
                proofSecret: proofSecret
            ).code
            operationCompletionMessage =
                "追加コードを作りました。追加するiPhoneへ送ってください。"
        } catch {
            record(error, operation: operation)
        }
    }

    func joinDeviceRecovery() async {
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
            let code: PairingDeviceRecoveryCode
            let descriptor: PairingDeviceRecoveryDescriptor
            let credential: PairingCredential
            let requestID: UUID
            let deviceID: String
            if current.phase == .claimingRecovery,
               let account = current.credentialAccount,
               let savedRequestID = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)),
               let savedDeviceID = current.recoveryDeviceID {
                credential = try PairingKeychainStore.load(
                    account: account,
                    installationMarker: current.installationMarker
                )
                guard let proofSecret = credential.enrollmentSecret else {
                    throw PairingError.malformedCredential
                }
                guard let recoveryID = current.recoveryID else {
                    throw PairingError.stateUnavailable
                }
                code = try PairingDeviceRecoveryCode(
                    recoveryID: recoveryID,
                    proofSecret: proofSecret
                )
                descriptor = try recoveryDescriptor(
                    from: current,
                    targetCredential: credential
                )
                requestID = savedRequestID
                deviceID = savedDeviceID
            } else {
                guard current.phase == .unpaired else {
                    throw PairingError.stateUnavailable
                }
                code = try PairingDeviceRecoveryCode(code: enteredRecoveryCode)
                try SharingLifecycleGate.validate(lifecycleToken)
                descriptor = try await api.deviceRecoveryDescriptor(
                    recoveryID: code.recoveryID
                )
                try SharingLifecycleGate.validate(lifecycleToken)
                guard let participantID = Data(
                    base64URLString: descriptor.target.participantID
                ), participantID.count == 16,
                      let targetRole = descriptor.target.pairingRole
                else { throw PairingError.invalidServerResponse }
                var generated = PairingCrypto.makeCredential(
                    installationMarker: current.installationMarker,
                    includesInvitationSecret: false,
                    includesRoomKey: false
                )
                generated.participantID = participantID
                generated.enrollmentSecret = code.proofSecret
                credential = generated
                requestID = UUID()
                deviceID = PairingCrypto.randomData(count: 16).base64URLEncodedString()
                current.phase = .claimingRecovery
                current.role = targetRole
                current.credentialAccount = credential.account
                current.participantID = descriptor.target.participantID
                current.spaceID = descriptor.spaceID
                current.memberID = descriptor.target.memberID
                current.peerMemberID = descriptor.peer.memberID
                current.peerParticipantID = descriptor.peer.participantID
                current.peerAgreementPublicKey = descriptor.peer.agreementPublicKey
                current.peerSigningPublicKey = descriptor.peer.signingPublicKey
                current.dailyBoundaryMinuteUTC = descriptor.dailyBoundaryMinuteUTC
                current.recoveryID = descriptor.recoveryID
                current.recoveryExpiresAt = descriptor.expiresAt
                current.recoveryMembershipRevision = descriptor.membershipRevision
                current.recoveryKeyEpoch = descriptor.keyEpoch
                current.recoveryDeviceID = deviceID
                current.recoveryPreviousTargetAgreementPublicKey =
                    descriptor.target.agreementPublicKey
                current.recoveryPreviousTargetSigningPublicKey =
                    descriptor.target.signingPublicKey
                current.recoveryCandidateAgreementPublicKey = try PairingCrypto
                    .agreementPublicKey(for: credential).base64URLEncodedString()
                current.recoveryCandidateSigningPublicKey = try PairingCrypto
                    .signingPublicKey(for: credential).base64URLEncodedString()
                current.recoveryTranscript = nil
                current.recoveryTranscriptHash = nil
                current.recoveryVerificationPhrase = nil
                current.recoveryApprovalSubmittedAt = nil
                current.recoveryCompletedAt = nil
                current.recoveryWasLocalDeviceReplacement = nil
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "recoveryClaim"
                current.pendingCancelRevokesWholeSpace = nil
                current.lastUpdatedAt = .now
                current.lastError = nil
                current = try persistInitialCredential(
                    credential,
                    state: current,
                    operation: operation
                )
            }
            try SharingLifecycleGate.validate(lifecycleToken)
            let result = try await api.claimDeviceRecovery(
                code: code,
                descriptor: descriptor,
                deviceID: deviceID,
                clientRequestID: requestID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            try applyDeviceRecoveryClaim(result, to: &current)
            current.phase = .pendingRecoveryApproval
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.lastUpdatedAt = .now
            current.lastError = nil
            current = try persist(current, operation: operation)
            enteredRecoveryCode = ""
            hasConfirmedRecoveryPhrase = false
            operationCompletionMessage =
                "iPhone追加の確認を始めました。両方のiPhoneで12語を比べてください。"
        } catch {
            record(error, operation: operation)
        }
    }

    func refreshDeviceRecovery(isManual: Bool = true) async {
        guard let api else { return }
        if isManual { clearTransientOperationFeedback() }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
        guard let account = current.credentialAccount,
              let recoveryID = current.recoveryID
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            var credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
            if current.phase == .paired {
                if current.recoveryCandidateAgreementPublicKey == nil {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    if let claim = try await api.pendingDeviceRecovery(
                        state: current,
                        credential: credential
                    ) {
                        try SharingLifecycleGate.validate(lifecycleToken)
                        try applyDeviceRecoveryClaim(claim, to: &current)
                        current.lastUpdatedAt = .now
                        current.lastError = nil
                        current = try persist(current, operation: operation)
                        hasConfirmedRecoveryPhrase = false
                        operationCompletionMessage =
                            "追加するiPhoneから確認が届きました。12語を比べてください。"
                    } else if let expiresAt = current.recoveryExpiresAt,
                              Date() >= expiresAt.addingTimeInterval(
                                PairingProtocol.maximumClockSkewSeconds
                              ) {
                        try clearExpiredSponsorRecovery(
                            credential: &credential,
                            state: &current,
                            lifecycleToken: lifecycleToken
                        )
                        current = try persist(current, operation: operation)
                        operationCompletionMessage =
                            "追加コードの期限が切れました。相手側のまどや既存のiPhoneは解除されていません。必要なら新しいコードを作れます。"
                    } else if isManual {
                        manualCheckSucceeded = true
                        manualCheckCompletedAt = .now
                        manualCheckMessage = "まだ追加するiPhoneから確認は届いていません。"
                    }
                    return
                }
                try SharingLifecycleGate.validate(lifecycleToken)
                let result = try await api.sponsorDeviceRecoveryStatus(
                    state: current,
                    credential: credential
                )
                try SharingLifecycleGate.validate(lifecycleToken)
                guard result.recoveryID == recoveryID,
                      result.transcriptData.base64URLEncodedString()
                        == current.recoveryTranscript,
                      result.transcriptHash == current.recoveryTranscriptHash
                else { throw PairingError.transcriptMismatch }
                if result.state == "active" {
                    // Enrollment adds another device to the same participant.
                    // Keep the participant's original naming identity as the
                    // canonical key so every already-connected iPhone can
                    // continue to verify the same encrypted window name.
                    guard current.peerMemberID == result.credential.memberID,
                          current.peerParticipantID == result.credential.participantID
                    else { throw PairingError.transcriptMismatch }
                    current.recoveryCompletedAt = result.recoveredAt ?? .now
                    current.recoveryWasLocalDeviceReplacement = false
                    current.pendingClientRequestID = nil
                    current.pendingOperation = nil
                    current.pendingKeyEnvelope = nil
                    current.pendingApprovalSignature = nil
                    current.lastUpdatedAt = .now
                    current.lastError = nil
                    credential.enrollmentSecret = nil
                    try PairingKeychainStore.save(
                        credential,
                        lifecycleToken: lifecycleToken
                    )
                    current = try persist(current, operation: operation)
                    recoveryInvitationCode = nil
                    operationCompletionMessage =
                        "相手のiPhoneを追加しました。すでに使っているiPhoneも引き続き使えます。"
                    NotificationCenter.default.post(
                        name: .sharingMediaSyncRequested,
                        object: nil
                    )
                } else if result.state == "expired" {
                    try clearExpiredSponsorRecovery(
                        credential: &credential,
                        state: &current,
                        lifecycleToken: lifecycleToken
                    )
                    current = try persist(current, operation: operation)
                    operationCompletionMessage =
                        "追加コードの期限が切れました。相手側のまどや既存のiPhoneは解除されていません。必要なら新しいコードを作れます。"
                } else if isManual {
                    if result.state == "approvedAwaitingCompletion" {
                        current.recoveryApprovalSubmittedAt =
                            current.recoveryApprovalSubmittedAt ?? .now
                        current.lastUpdatedAt = .now
                        current = try persist(current, operation: operation)
                    }
                    manualCheckSucceeded = true
                    manualCheckCompletedAt = .now
                    manualCheckMessage = result.state == "approvedAwaitingCompletion"
                        ? "承認済みです。追加するiPhoneで完了するのを待っています。"
                        : "まだ12語の確認と承認を待っています。"
                }
                return
            }

            if current.pendingOperation == "recoveryComplete",
               let requestID = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)),
               let hash = current.recoveryTranscriptHash {
                guard credential.roomKey?.count == 32 else {
                    throw PairingError.malformedCredential
                }
                try SharingLifecycleGate.validate(lifecycleToken)
                let latest = try await api.deviceRecoveryStatus(
                    recoveryID: recoveryID,
                    credential: credential
                )
                try SharingLifecycleGate.validate(lifecycleToken)
                try validateDeviceRecoveryStatus(latest, against: current)
                if latest.state == "expired" {
                    try await resetLocalPairing(operation: operation)
                    operationCompletionMessage =
                        "追加を完了できなかったため、このiPhoneの追加だけを取り消しました。接続済みのまどや既存のiPhoneは解除されていません。"
                    return
                }
                let completed: PairingDeviceRecoveryStatusResult
                if latest.state == "active" {
                    completed = latest
                } else {
                    guard latest.state == "approvedAwaitingCompletion" else {
                        throw PairingError.invalidServerResponse
                    }
                    completed = try await api.completeDeviceRecovery(
                        recoveryID: recoveryID,
                        transcriptHash: hash,
                        clientRequestID: requestID,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                }
                try finishLocalDeviceRecovery(completed, state: &current)
                current = try persist(current, operation: operation)
                recoveryInvitationCode = nil
                operationCompletionMessage =
                    "このiPhoneをまどに追加しました。すでに使っているiPhoneも引き続き使えます。"
                NotificationCenter.default.post(name: .sharingMediaSyncRequested, object: nil)
                return
            }

            try SharingLifecycleGate.validate(lifecycleToken)
            let result = try await api.deviceRecoveryStatus(
                recoveryID: recoveryID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            try validateDeviceRecoveryStatus(result, against: current)
            if result.state == "approvedAwaitingCompletion" {
                guard let envelopeValue = result.keyEnvelope,
                      let envelope = Data(base64URLString: envelopeValue),
                      let algorithm = result.envelopeAlgorithm,
                      let signatureValue = result.approvalSignature,
                      let signature = Data(base64URLString: signatureValue),
                      let peerSigningValue = current.peerSigningPublicKey,
                      let peerSigning = Data(base64URLString: peerSigningValue),
                      let peerAgreementValue = current.peerAgreementPublicKey,
                      let peerAgreement = Data(base64URLString: peerAgreementValue),
                      let hashValue = current.recoveryTranscriptHash,
                      let hash = Data(base64URLString: hashValue),
                      let deviceID = current.recoveryDeviceID,
                      let revision = current.recoveryMembershipRevision,
                      let keyEpoch = current.recoveryKeyEpoch,
                      let targetMemberID = current.memberID
                else { throw PairingError.invalidServerResponse }
                let approvalTranscript = try PairingCrypto.deviceRecoveryApprovalTranscript(
                    recoveryID: recoveryID,
                    spaceID: result.spaceID,
                    targetMemberID: targetMemberID,
                    deviceID: deviceID,
                    membershipRevision: revision,
                    keyEpoch: keyEpoch,
                    transcriptHash: hashValue,
                    envelopeAlgorithm: algorithm,
                    keyEnvelope: envelopeValue
                )
                guard try PairingCrypto.verifySignature(
                    signature,
                    for: approvalTranscript,
                    publicKey: peerSigning
                ) else { throw PairingError.transcriptMismatch }
                let roomKey = try PairingCrypto.openDeviceRecoveryRoomKeyEnvelope(
                    envelope,
                    peerAgreementPublicKey: peerAgreement,
                    transcript: result.transcriptData,
                    transcriptHash: hash,
                    credential: credential
                )
                credential.roomKey = roomKey
                credential.enrollmentSecret = nil
                credential.deviceID = current.recoveryDeviceID
                try PairingKeychainStore.save(
                    credential,
                    lifecycleToken: lifecycleToken
                )
                let completionID = UUID()
                current.phase = .recoveryAwaitingCompletion
                current.pendingClientRequestID = completionID.uuidString
                current.pendingOperation = "recoveryComplete"
                current.pendingKeyEnvelope = nil
                current.pendingApprovalSignature = nil
                current.lastUpdatedAt = .now
                current.lastError = nil
                current = try persist(current, operation: operation)
                try SharingLifecycleGate.validate(lifecycleToken)
                let completed = try await api.completeDeviceRecovery(
                    recoveryID: recoveryID,
                    transcriptHash: hashValue,
                    clientRequestID: completionID,
                    credential: credential
                )
                try SharingLifecycleGate.validate(lifecycleToken)
                try finishLocalDeviceRecovery(completed, state: &current)
                current = try persist(current, operation: operation)
                operationCompletionMessage =
                    "このiPhoneをまどに追加しました。すでに使っているiPhoneも引き続き使えます。"
                NotificationCenter.default.post(name: .sharingMediaSyncRequested, object: nil)
            } else if result.state == "expired" {
                try await resetLocalPairing(operation: operation)
                operationCompletionMessage =
                    "追加コードの期限が切れたため、このiPhoneの追加だけを取り消しました。接続済みのまどや既存のiPhoneは解除されていません。"
            } else if isManual {
                manualCheckSucceeded = true
                manualCheckCompletedAt = .now
                manualCheckMessage = "接続済みのiPhoneで12語を確認し、承認してください。"
            }
        } catch {
            record(error, operation: operation)
            if isManual {
                manualCheckSucceeded = false
                manualCheckCompletedAt = .now
                manualCheckMessage =
                    "追加状態を確認できませんでした。接続情報は消さず、もう一度確認できます。"
            }
        }
    }

    func approveDeviceRecoveryAfterPhraseConfirmation() async {
        clearTransientOperationFeedback()
        guard hasConfirmedRecoveryPhrase else {
            record(PairingError.approvalNotConfirmed)
            return
        }
        guard let api else { return }
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        var current = operation.expectedState
        let lifecycleToken = operation.lifecycleToken
        guard current.phase == .paired,
              let account = current.credentialAccount,
              let memberID = current.memberID,
              let recoveryID = current.recoveryID,
              let targetMemberID = current.peerMemberID,
              let deviceID = current.recoveryDeviceID,
              let revision = current.recoveryMembershipRevision,
              let keyEpoch = current.recoveryKeyEpoch,
              let transcriptValue = current.recoveryTranscript,
              let transcript = Data(base64URLString: transcriptValue),
              let hashValue = current.recoveryTranscriptHash,
              let hash = Data(base64URLString: hashValue),
              let candidateAgreementValue = current.recoveryCandidateAgreementPublicKey,
              let candidateAgreement = Data(base64URLString: candidateAgreementValue)
        else {
            record(PairingError.stateUnavailable, operation: operation)
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
            if current.pendingOperation == "recoveryApprove",
               let saved = current.pendingClientRequestID.flatMap(UUID.init(uuidString:)),
               let envelope = current.pendingKeyEnvelope,
               let signature = current.pendingApprovalSignature {
                requestID = saved
                envelopeValue = envelope
                signatureValue = signature
            } else {
                requestID = UUID()
                envelopeValue = try PairingCrypto.makeDeviceRecoveryRoomKeyEnvelope(
                    roomKey: roomKey,
                    peerAgreementPublicKey: candidateAgreement,
                    transcript: transcript,
                    transcriptHash: hash,
                    credential: credential
                ).base64URLEncodedString()
                let approvalTranscript = try PairingCrypto.deviceRecoveryApprovalTranscript(
                    recoveryID: recoveryID,
                    spaceID: current.spaceID ?? "",
                    targetMemberID: targetMemberID,
                    deviceID: deviceID,
                    membershipRevision: revision,
                    keyEpoch: keyEpoch,
                    transcriptHash: hashValue,
                    envelopeAlgorithm: PairingProtocol.roomKeyEnvelopeAlgorithm,
                    keyEnvelope: envelopeValue
                )
                signatureValue = try PairingCrypto.sign(
                    approvalTranscript,
                    credential: credential
                ).base64URLEncodedString()
                current.pendingClientRequestID = requestID.uuidString
                current.pendingOperation = "recoveryApprove"
                current.pendingKeyEnvelope = envelopeValue
                current.pendingApprovalSignature = signatureValue
                current.lastUpdatedAt = .now
                current = try persist(current, operation: operation)
            }
            try SharingLifecycleGate.validate(lifecycleToken)
            try await api.approveDeviceRecovery(
                recoveryID: recoveryID,
                targetMemberID: targetMemberID,
                deviceID: deviceID,
                membershipRevision: revision,
                keyEpoch: keyEpoch,
                transcriptHash: hashValue,
                keyEnvelope: envelopeValue,
                approvalSignature: signatureValue,
                clientRequestID: requestID,
                memberID: memberID,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            current.pendingClientRequestID = nil
            current.pendingOperation = nil
            current.pendingKeyEnvelope = nil
            current.pendingApprovalSignature = nil
            current.recoveryApprovalSubmittedAt = .now
            current.lastUpdatedAt = .now
            current.lastError = nil
            current = try persist(current, operation: operation)
            operationCompletionMessage =
                "iPhoneの追加を承認しました。追加するiPhoneで更新してください。"
        } catch {
            record(error, operation: operation)
        }
    }

    /// Abandons only the not-yet-activated additional credential on this
    /// iPhone. The existing space and the still-connected peer are untouched;
    /// the short-lived server capability expires independently.
    func abandonLocalDeviceRecovery() async {
        clearTransientOperationFeedback()
        let operation: PairingOperation
        do { operation = try beginOperation() }
        catch { record(error); return }
        guard [.claimingRecovery, .pendingRecoveryApproval]
            .contains(operation.expectedState.phase)
        else {
            record(PairingError.stateUnavailable, operation: operation)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await resetLocalPairing(operation: operation)
            operationCompletionMessage =
                "このiPhoneの追加を取り消しました。接続済みのまどや既存のiPhoneは解除されていません。"
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
                "共有を解除しました。このiPhoneの共有鍵と一時的な届いた写真を削除しました。写真アプリへ保存した思い出は残ります。"
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

    private nonisolated static func serverConfirmsPairingIsGone(
        _ error: PairingError
    ) -> Bool {
        guard case let .requestRejected(status, code, _) = error else { return false }
        return status == 410 && code == "sharing_revoked"
    }

#if DEBUG
    nonisolated static func runtimeServerConfirmsPairingIsGone(
        _ error: PairingError
    ) -> Bool {
        serverConfirmsPairingIsGone(error)
    }
#endif

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

    private func recoveryDescriptor(
        from state: PairingState,
        targetCredential: PairingCredential
    ) throws -> PairingDeviceRecoveryDescriptor {
        guard let recoveryID = state.recoveryID,
              let expiresAt = state.recoveryExpiresAt,
              let revision = state.recoveryMembershipRevision,
              let keyEpoch = state.recoveryKeyEpoch,
              let spaceID = state.spaceID,
              let boundary = state.dailyBoundaryMinuteUTC,
              let targetMemberID = state.memberID,
              let targetParticipantID = state.participantID,
              let targetRole = state.role,
              let previousAgreement = state.recoveryPreviousTargetAgreementPublicKey,
              let previousSigning = state.recoveryPreviousTargetSigningPublicKey,
              let peerMemberID = state.peerMemberID,
              let peerParticipantID = state.peerParticipantID,
              let peerAgreement = state.peerAgreementPublicKey,
              let peerSigning = state.peerSigningPublicKey
        else { throw PairingError.stateUnavailable }
        guard targetParticipantID == targetCredential.participantIDString else {
            throw PairingError.malformedCredential
        }
        return PairingDeviceRecoveryDescriptor(
            recoveryID: recoveryID,
            state: "awaitingClaim",
            createdAt: nil,
            expiresAt: expiresAt,
            membershipRevision: revision,
            keyEpoch: keyEpoch,
            spaceID: spaceID,
            dailyBoundaryMinuteUTC: boundary,
            target: PairingDeviceRecoveryIdentity(
                memberID: targetMemberID,
                participantID: targetParticipantID,
                role: targetRole == .inviter ? "owner" : "invitee",
                agreementPublicKey: previousAgreement,
                signingPublicKey: previousSigning,
                state: "active"
            ),
            peer: PairingDeviceRecoveryIdentity(
                memberID: peerMemberID,
                participantID: peerParticipantID,
                role: targetRole == .inviter ? "invitee" : "owner",
                agreementPublicKey: peerAgreement,
                signingPublicKey: peerSigning,
                state: "active"
            )
        )
    }

    private func applyDeviceRecoveryClaim(
        _ result: PairingDeviceRecoveryClaimResult,
        to current: inout PairingState
    ) throws {
        guard result.descriptor.recoveryID == current.recoveryID,
              result.descriptor.spaceID == current.spaceID,
              result.descriptor.expiresAt == current.recoveryExpiresAt,
              result.descriptor.membershipRevision == current.recoveryMembershipRevision,
              result.descriptor.keyEpoch == current.recoveryKeyEpoch,
              result.credential.memberID
                == (current.phase == .paired ? current.peerMemberID : current.memberID),
              result.credential.participantID
                == (current.phase == .paired ? current.peerParticipantID : current.participantID)
        else { throw PairingError.transcriptMismatch }
        let localHash = PairingCrypto.sha256(result.transcriptData)
        guard localHash.base64URLEncodedString() == result.transcriptHash else {
            throw PairingError.transcriptMismatch
        }
        current.recoveryDeviceID = result.deviceID
        current.recoveryCandidateAgreementPublicKey = result.credential.agreementPublicKey
        current.recoveryCandidateSigningPublicKey = result.credential.signingPublicKey
        current.recoveryTranscript = result.transcriptData.base64URLEncodedString()
        current.recoveryTranscriptHash = result.transcriptHash
        current.recoveryVerificationPhrase = PairingCrypto.verificationPhrase(for: localHash)
        current.recoveryApprovalSubmittedAt = nil
    }

    private func finishLocalDeviceRecovery(
        _ result: PairingDeviceRecoveryStatusResult,
        state current: inout PairingState
    ) throws {
        guard result.state == "active",
              result.recoveryID == current.recoveryID,
              result.spaceID == current.spaceID,
              result.membershipRevision == current.recoveryMembershipRevision,
              result.keyEpoch == current.recoveryKeyEpoch,
              result.transcriptData.base64URLEncodedString() == current.recoveryTranscript,
              result.transcriptHash == current.recoveryTranscriptHash,
              result.credential.memberID == current.memberID,
              result.credential.participantID == current.participantID,
              result.credential.pairingRole == current.role,
              result.peer.memberID == current.peerMemberID,
              result.peer.participantID == current.peerParticipantID,
              result.previousTargetSigningPublicKey
                == current.recoveryPreviousTargetSigningPublicKey,
              let recoveredDeviceID = current.recoveryDeviceID,
              let recoveredAt = result.recoveredAt
        else { throw PairingError.transcriptMismatch }
        current.phase = .paired
        current.localMomentDeviceID = recoveredDeviceID
        current.peerAgreementPublicKey = result.peer.agreementPublicKey
        current.peerSigningPublicKey = result.peer.signingPublicKey
        current.recoveryCandidateAgreementPublicKey = result.credential.agreementPublicKey
        current.recoveryCandidateSigningPublicKey = result.credential.signingPublicKey
        current.recoveryCompletedAt = recoveredAt
        current.recoveryWasLocalDeviceReplacement = true
        current.localDeviceIsAdditional = true
        current.canonicalParticipantSigningPublicKey =
            current.recoveryPreviousTargetSigningPublicKey
        current.pendingClientRequestID = nil
        current.pendingOperation = nil
        current.pendingCancelRevokesWholeSpace = nil
        current.pendingKeyEnvelope = nil
        current.pendingApprovalSignature = nil
        current.lastUpdatedAt = .now
        current.lastError = nil
        hasConfirmedRecoveryPhrase = false
    }

    private func validateDeviceRecoveryStatus(
        _ result: PairingDeviceRecoveryStatusResult,
        against current: PairingState
    ) throws {
        guard result.recoveryID == current.recoveryID,
              result.spaceID == current.spaceID,
              result.membershipRevision == current.recoveryMembershipRevision,
              result.keyEpoch == current.recoveryKeyEpoch,
              result.transcriptData.base64URLEncodedString() == current.recoveryTranscript,
              result.transcriptHash == current.recoveryTranscriptHash,
              result.credential.memberID == current.memberID,
              result.credential.participantID == current.participantID,
              result.credential.agreementPublicKey
                == current.recoveryCandidateAgreementPublicKey,
              result.credential.signingPublicKey
                == current.recoveryCandidateSigningPublicKey,
              result.peer.memberID == current.peerMemberID,
              result.peer.participantID == current.peerParticipantID,
              result.peer.agreementPublicKey == current.peerAgreementPublicKey,
              result.peer.signingPublicKey == current.peerSigningPublicKey,
              result.previousTargetSigningPublicKey
                == current.recoveryPreviousTargetSigningPublicKey
        else { throw PairingError.transcriptMismatch }
    }

    private func clearExpiredSponsorRecovery(
        credential: inout PairingCredential,
        state current: inout PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        credential.enrollmentSecret = nil
        try PairingKeychainStore.save(
            credential,
            lifecycleToken: lifecycleToken
        )
        current.recoveryID = nil
        current.recoveryExpiresAt = nil
        current.recoveryMembershipRevision = nil
        current.recoveryKeyEpoch = nil
        current.recoveryDeviceID = nil
        current.recoveryPreviousTargetAgreementPublicKey = nil
        current.recoveryPreviousTargetSigningPublicKey = nil
        current.recoveryCandidateAgreementPublicKey = nil
        current.recoveryCandidateSigningPublicKey = nil
        current.recoveryTranscript = nil
        current.recoveryTranscriptHash = nil
        current.recoveryVerificationPhrase = nil
        current.recoveryApprovalSubmittedAt = nil
        current.recoveryCompletedAt = nil
        current.recoveryWasLocalDeviceReplacement = nil
        current.pendingClientRequestID = nil
        current.pendingOperation = nil
        current.pendingCancelRevokesWholeSpace = nil
        current.pendingKeyEnvelope = nil
        current.pendingApprovalSignature = nil
        current.lastUpdatedAt = .now
        current.lastError = nil
        recoveryInvitationCode = nil
        hasConfirmedRecoveryPhrase = false
    }

    private func applyOwnerStatus(
        _ result: PairingStatusResult,
        to current: inout PairingState
    ) throws {
        if let transcript = result.transcript,
           let hash = result.transcriptHash {
            try applyTranscript(transcript, hash: hash, to: &current)
        }
        if result.state == "active", let peer = result.peer {
            try applyCurrentPeer(peer, to: &current)
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

    private func applyCurrentPeer(
        _ peer: PairingMemberIdentity,
        to current: inout PairingState
    ) throws {
        _ = try peer.validated()
        guard peer.memberID == current.peerMemberID,
              peer.participantID == current.peerParticipantID
        else { throw PairingError.transcriptMismatch }
        current.peerAgreementPublicKey = peer.agreementPublicKey
        current.peerSigningPublicKey = peer.signingPublicKey
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

    private static func isLocalWindowNameDraft(_ state: PairingState) -> Bool {
        state.phase == .unpaired
            || (state.role == .inviter
                && state.spaceID == nil
                && [.creatingInvitation, .failed].contains(state.phase))
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
        bestEffortBindCredentialDeviceID(
            for: committed,
            lifecycleToken: operation.lifecycleToken
        )
        try? SharingLifecycleGate.withValidatedToken(operation.lifecycleToken) {
            try PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked(
                spaceID: committed.spaceID,
                credentialAccount: committed.credentialAccount
            )
        }
        reloadPrivateWindowCatalog()
        let becamePaired = previous.phase != .paired && committed.phase == .paired
        let acceptedMediaNow = previous.mediaSharingConsentVersion
            != PairingMediaSharingConsent.currentVersion
            && committed.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion
        if (becamePaired || acceptedMediaNow),
           committed.pendingOperation == nil,
           committed.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
           committed.mediaSharingConsentAcceptedAt != nil {
            NotificationCenter.default.post(name: .sharingMediaSyncRequested, object: nil)
            Task {
                await MomentPushSubscriptionService.shared
                    .reconcileRegistration()
            }
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
        bestEffortBindCredentialDeviceID(
            for: committed,
            lifecycleToken: operation.lifecycleToken
        )
        reloadPrivateWindowCatalog()
        return committed
    }

    private func persistCreatedInvitationPromotingDraftName(
        _ value: PairingState,
        operation: PairingOperation
    ) throws -> PairingState {
        let committed = try PairingStateStore
            .saveCreatedInvitationAndPromoteDraftName(
                try value.validated(),
                expected: operation.expectedState,
                lifecycleToken: operation.lifecycleToken
            )
        operation.expectedState = committed
        state = committed
        bestEffortBindCredentialDeviceID(
            for: committed,
            lifecycleToken: operation.lifecycleToken
        )
        windowDisplayName = resolvedWindowDisplayName(
            pairing: committed,
            validating: operation.lifecycleToken
        )
        reloadPrivateWindowCatalog()
        return committed
    }

    private func bestEffortBindCredentialDeviceID(
        for state: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) {
        guard state.phase == .paired,
              let account = state.credentialAccount,
              let deviceID = state.resolvedLocalMomentDeviceID
        else { return }
        do {
            var credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: state.installationMarker
            )
            guard credential.deviceID != deviceID else { return }
            credential.deviceID = deviceID
            try PairingKeychainStore.save(
                credential,
                lifecycleToken: lifecycleToken
            )
        } catch {
            SharedLog.app.warning(
                "pairing",
                "Could not bind the local device selector to its credential"
            )
        }
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

    private func restoreRecoveryInvitationCodeIfAvailable(
        from state: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        guard state.phase == .paired,
              state.recoveryCompletedAt == nil,
              let account = state.credentialAccount,
              let recoveryID = state.recoveryID
        else { return }
        try SharingLifecycleGate.validate(lifecycleToken)
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: state.installationMarker
        )
        guard let proofSecret = credential.enrollmentSecret else { return }
        recoveryInvitationCode = try PairingDeviceRecoveryCode(
            recoveryID: recoveryID,
            proofSecret: proofSecret
        ).code
    }

    private func bestEffortScrubConsumedInvitationSecret(
        for state: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) {
        if state.recoveryCompletedAt == nil,
           state.recoveryID != nil || state.pendingOperation == "recoveryCreate"
                || state.pendingOperation == "recoveryClaim" {
            return
        }
        let isConsumedPhase: Bool
        switch state.phase {
        case .pendingApproval, .approvalRequired, .awaitingCompletion, .paired:
            isConsumedPhase = true
        case .claimingRecovery, .pendingRecoveryApproval, .recoveryAwaitingCompletion:
            isConsumedPhase = false
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
        recoveryInvitationCode = nil
        enteredInvitationCode = ""
        enteredRecoveryCode = ""
        hasConfirmedPhrase = false
        hasConfirmedRecoveryPhrase = false
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
        if let retryable = error as? PairingInstallationGuard.RetryableBootstrapError {
            return retryable.errorDescription
                ?? "共有の状態を一時的に確認できませんでした。もう一度お試しください。"
        }
        if let pairingError = error as? PairingError {
            return message(for: pairingError)
        }
        if let catalogError = error as? PrivateWindowCatalogStore.Error {
            switch catalogError {
            case .windowLimitReached:
                return "初期版では、まどは合計3個までです。"
            case .setupWindowAlreadyExists:
                return "先に、設定中のまどを完了してください。"
            default:
                break
            }
        }
        if error is URLError {
            return "通信を完了できませんでした。接続を確認して、もう一度お試しください。"
        }
        return "共有の状態を確認できませんでした。時間をおいて、もう一度お試しください。"
    }

    private nonisolated static func isRetryableBootstrapCompletionError(
        _ error: Error
    ) -> Bool {
        if error is PairingKeychainStore.RetryableReadError
            || error is PairingStateStore.LoadError
            || error is DecodingError
            || error is SharingLifecycleGate.Error
            || error is SharingSecureFile.Error {
            return true
        }
        if let pairingError = error as? PairingError {
            switch pairingError {
            case .stateUnavailable, .keychainUnavailable:
                return true
            default:
                return false
            }
        }
        if let dailySharingError = error as? DailySharingError {
            switch dailySharingError {
            case .stateUnavailable, .stateChanged:
                return true
            default:
                return false
            }
        }
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain
            || value.domain == NSPOSIXErrorDomain
            || value.domain == NSOSStatusErrorDomain
    }

    #if DEBUG
    nonisolated static func runtimeTestIsRetryableBootstrapCompletionError(
        _ error: Error
    ) -> Bool {
        isRetryableBootstrapCompletionError(error)
    }
    #endif

    private static func message(for error: PairingError) -> String {
        error.errorDescription
            ?? "共有の処理を完了できませんでした。状態を確認して、もう一度お試しください。"
    }
}
