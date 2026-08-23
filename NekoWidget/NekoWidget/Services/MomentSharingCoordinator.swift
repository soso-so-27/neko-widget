import Foundation

enum MomentSynchronizationNotice: Equatable, Sendable {
    case inboundModerationDisabled
    case inboundModerationUnavailable
}

/// The host app owns all relay I/O. Share Extension direct-send is hard
/// disabled, so one process-wide queue serializes the AppViewModel and
/// FamilyWindow coordinator instances. Every caller keeps its own cancellation
/// context and receives a turn, so a user-requested refresh cannot be dropped
/// or inherit cancellation from an earlier pass.
private final class MomentSynchronizationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func shouldBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isCancelled
    }
}

private actor MomentProcessSynchronizationGate {
#if DEBUG
    private struct RuntimePendingObserver {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }
#endif

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
#if DEBUG
    private var runtimePendingObservers: [RuntimePendingObserver] = []
#endif

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
#if DEBUG
            let observers = runtimePendingObservers.filter {
                $0.expectedCount <= waiters.count
            }
            runtimePendingObservers.removeAll {
                $0.expectedCount <= waiters.count
            }
            for observer in observers {
                observer.continuation.resume()
            }
#endif
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        // Keep the permit held while handing it directly to the oldest waiter.
        // A new caller must queue behind that reserved turn.
        let next = waiters.removeFirst()
        next.resume()
    }

#if DEBUG
    func runtimeWaitUntilPendingRequestCount(_ expectedCount: Int) async {
        guard waiters.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            runtimePendingObservers.append(
                RuntimePendingObserver(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }
#endif
}

private let momentProcessSynchronizationGate = MomentProcessSynchronizationGate()

private func runMomentProcessSynchronization(
    request: MomentSynchronizationRequest,
    operation: @escaping @Sendable () async -> MomentSynchronizationNotice?
) async -> MomentSynchronizationNotice? {
    await momentProcessSynchronizationGate.acquire()
    let notice: MomentSynchronizationNotice?
    if request.shouldBegin() {
        notice = await operation()
    } else {
        notice = nil
    }
    await momentProcessSynchronizationGate.release()
    return notice
}

actor MomentSharingCoordinator {
    private struct Authorization: Sendable {
        let state: PairingState
        let credential: PairingCredential
        let lifecycleToken: SharingLifecycleGate.Token
    }

    private let configuration: SharingAPIConfiguration
    private let moderation: any MomentModerating
    private let handoffProcessor: MomentShareHandoffProcessor
    private var latestSynchronizationNotice: MomentSynchronizationNotice?

    init(
        configuration: SharingAPIConfiguration = .current,
        moderation: any MomentModerating = MomentModerationService()
    ) {
        self.configuration = configuration
        self.moderation = moderation
        handoffProcessor = MomentShareHandoffProcessor(moderation: moderation)
    }

    func synchronize(trigger: String) async {
        let request = MomentSynchronizationRequest()
        let notice = await withTaskCancellationHandler {
            await runMomentProcessSynchronization(request: request) { [self] in
                await performSynchronization(trigger: trigger)
                return await synchronizationNotice()
            }
        } onCancel: {
            request.cancel()
        }
        latestSynchronizationNotice = notice
    }

    private func performSynchronization(trigger: String) async {
        latestSynchronizationNotice = nil

        // Disabling media/handoff must also revoke any previously published
        // Share Extension admission and physically remove staged plaintext.
        // Bootstrap first so a reinstall cleanup wins before App Group state
        // is inspected or retained.
        guard configuration.isMediaAvailable else {
            do {
                let bootstrap = try PairingInstallationGuard.bootstrap()
                try handoffProcessor.revokeAdmissions(
                    lifecycleToken: bootstrap.lifecycleToken
                )
                try purgeInboundModerationTemporaryFiles(
                    validating: bootstrap.lifecycleToken
                )
                try MomentSharingStateStore.pruneLocalHistory()
            } catch {
                SharedLog.app.warning(
                    "moment-sharing",
                    "Disabled moment handoff cleanup deferred",
                    metadata: ["trigger": String(trigger.prefix(32))]
                )
            }
            if configuration.isAvailable {
                await synchronizeWindowNameWithoutMedia(trigger: trigger)
            }
            return
        }

        var authorization: Authorization?
        do {
            let loadedAuthorization = try loadAuthorization()
            authorization = loadedAuthorization
            try purgeInboundModerationTemporaryFiles(
                validating: loadedAuthorization.lifecycleToken
            )
            let resumeNow = Date()
            let markerUntil: Date?
            do {
                markerUntil = try MomentShareHandoffStore
                    .reportOnlyHandoffDeadline(
                        validating: loadedAuthorization.lifecycleToken,
                        now: resumeNow
                    )
            } catch {
                // Marker existence already keeps the Extension fail-closed.
                // Recover its bounded deadline from valid local state or the
                // protected inode anchor so corrupt bytes cannot retain keys,
                // evidence, or ciphertext indefinitely.
                guard let recoveredUntil = await recoverReportOnlyBoundary(
                    authorization: loadedAuthorization,
                    now: resumeNow
                ) else { return }
                markerUntil = recoveredUntil
            }
            if let markerUntil {
                guard !MomentSharingProtocol.isReportOnlyWindowClosed(
                    until: markerUntil,
                    now: resumeNow
                ) else {
                    try await PairingInstallationGuard
                        .resetAfterRemoteRevocationAsync(
                            expectedState: loadedAuthorization.state,
                            lifecycleToken: loadedAuthorization.lifecycleToken
                        )
                    return
                }
                // A transient disk error here leaves the already-durable
                // marker in place. Defer and retry without deleting report
                // evidence that is still inside its bounded safety window.
                try handoffProcessor.enterReportOnlyMode(
                    until: markerUntil,
                    lifecycleToken: loadedAuthorization.lifecycleToken,
                    now: resumeNow
                )
            }
            // Installation bootstrap must win before any sharing-state read or
            // pruning. A reinstall with stale/corrupt App Group data is purged
            // by loadAuthorization rather than being blocked by that data.
            try MomentSharingStateStore.pruneLocalHistory()
            let localSharingState = try MomentSharingStateStore.load()
            if let reportOnlyUntil = localSharingState.reportOnlyUntil,
               MomentSharingProtocol.isReportOnlyWindowClosed(
                   until: reportOnlyUntil
               ) {
                try await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: loadedAuthorization.state,
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
                return
            }
            let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
            if let reportOnlyUntil = localSharingState.reportOnlyUntil {
                if !MomentSharingProtocol.isReportOnlyWindowClosed(
                    until: reportOnlyUntil
                ) {
                    // Upgrade state written by an older build to the durable
                    // Extension marker before any network await. This closes
                    // the window in which a stale admission could still stage
                    // plaintext while safety reports are being retried.
                    guard await establishReportOnlyBoundary(
                        until: reportOnlyUntil,
                        authorization: loadedAuthorization
                    ) else { return }
                    let reported = try await sendReportOutbox(
                        api: api,
                        authorization: loadedAuthorization
                    )
                    if reported > 0 {
                        SharedLog.app.info(
                            "moment-sharing",
                            "Pending safety reports synchronized",
                            metadata: ["reports": "\(reported)"]
                        )
                    }
                    return
                }
            }
            let reported = try await sendReportOutbox(
                api: api,
                authorization: loadedAuthorization
            )
            let handedOff: Int
            if configuration.isShareExtensionHandoffAvailable {
                handedOff = try await handoffProcessor.refreshAdmissionsAndDrain(
                    pairing: loadedAuthorization.state,
                    credential: loadedAuthorization.credential,
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
            } else {
                try handoffProcessor.revokeAdmissions(
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
                handedOff = 0
            }
            let sent = try await sendOutbox(
                api: api,
                pairing: loadedAuthorization.state,
                credential: loadedAuthorization.credential,
                lifecycleToken: loadedAuthorization.lifecycleToken
            )
            let received = try await receiveChanges(
                api: api,
                pairing: loadedAuthorization.state,
                credential: loadedAuthorization.credential,
                lifecycleToken: loadedAuthorization.lifecycleToken
            )
            // Keep presentation metadata behind the photo pipeline. A stalled
            // or unavailable name endpoint must not delay delivery, ACKs, or
            // the photo change cursor.
            let windowNameChanged = await synchronizeWindowNameBestEffort(
                api: api,
                authorization: loadedAuthorization,
                trigger: trigger
            )
            SharedLog.app.info(
                "moment-sharing",
                "Moment synchronization completed",
                metadata: [
                    "trigger": String(trigger.prefix(32)),
                    "handedOff": "\(handedOff)",
                    "sent": "\(sent)",
                    "received": "\(received)",
                    "windowNameChanged": "\(windowNameChanged)"
                ]
            )
        } catch {
            latestSynchronizationNotice = Self.synchronizationNotice(for: error)
            if let authorization,
               let momentError = error as? MomentSharingError,
               case let .reportOnly(until) = momentError {
                _ = await establishReportOnlyBoundary(
                    until: until,
                    authorization: authorization
                )
            } else if let authorization, Self.requiresLocalRevocationReset(error) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
            } else if let authorization,
                      let momentError = error as? MomentSharingError,
                      case .stateUnavailable = momentError {
                await handleStateUnavailable(authorization: authorization)
            }
            SharedLog.app.warning(
                "moment-sharing",
                "Moment synchronization deferred",
                metadata: ["trigger": String(trigger.prefix(32))]
            )
        }
    }

    func synchronizationNotice() -> MomentSynchronizationNotice? {
        latestSynchronizationNotice
    }

    func report(
        inboxItem: MomentInboxItem,
        reason: MomentReportReason,
        consentAcceptedAt: Date
    ) async throws {
        guard configuration.isMediaAvailable,
              let moderationKeyID = configuration.moderationKeyID,
              let moderationPublicKey = configuration.moderationPublicKey,
              let fileName = inboxItem.localJPEGFileName,
              let receivedDirectory = SharedContainer.momentSharingReceivedDirectoryURL
        else { throw MomentSharingError.featureDisabled }
        let authorization = try loadAuthorization()
        let directActionNow = Date()
        let markerUntil: Date?
        do {
            markerUntil = try MomentShareHandoffStore.reportOnlyHandoffDeadline(
                validating: authorization.lifecycleToken,
                now: directActionNow
            )
        } catch {
            // A corrupt marker must not make reporting permanently
            // unavailable. Rebuild the bounded boundary while its existence
            // continues to keep normal Extension capture fail-closed.
            guard let recoveredUntil = await recoverReportOnlyBoundary(
                authorization: authorization,
                now: directActionNow
            ) else { throw MomentSharingError.notPaired }
            markerUntil = recoveredUntil
        }
        if let markerUntil {
            guard !MomentSharingProtocol.isReportOnlyWindowClosed(
                until: markerUntil,
                now: directActionNow
            ) else {
                try await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
                throw MomentSharingError.notPaired
            }
            guard await establishReportOnlyBoundary(
                until: markerUntil,
                authorization: authorization,
                now: directActionNow
            ) else { throw MomentSharingError.notPaired }
        }
        try MomentSharingStateStore.pruneLocalHistory()
        if let reportOnlyUntil = try MomentSharingStateStore.load().reportOnlyUntil {
            if MomentSharingProtocol.isReportOnlyWindowClosed(
                until: reportOnlyUntil
            ) {
                try await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
                throw MomentSharingError.notPaired
            }
            // Direct menu actions can run before the next foreground sync.
            // Upgrade an older state-only report window to the same durable
            // Extension gate before preparing or uploading report evidence.
            guard await establishReportOnlyBoundary(
                until: reportOnlyUntil,
                authorization: authorization
            ) else { throw MomentSharingError.notPaired }
        }
        guard let reporterParticipantID = authorization.state.memberID,
              inboxItem.senderParticipantID != reporterParticipantID
        else { throw MomentSharingError.invalidPayload }
        let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
        try SharingLifecycleGate.validate(authorization.lifecycleToken)

        var item: MomentReportOutboxItem
        if let existing = try MomentSharingStateStore.load().reportOutbox.first(where: {
            $0.momentID == inboxItem.id
        }) {
            guard existing.reason == reason else { throw MomentSharingError.stateUnavailable }
            guard existing.phase != .deliveryResultUnknown else {
                throw MomentSharingError.requestRejected(
                    status: 409,
                    code: "report_result_unknown",
                    message: "通報結果を確認できません。重複送信を避けるため、この端末からは再送しません。"
                )
            }
            item = existing
        } else {
            let jpeg = try Data(
                contentsOf: receivedDirectory.appendingPathComponent(fileName)
            )
            let prepared = try MomentReportCrypto.prepare(
                canonicalJPEG: jpeg,
                momentID: inboxItem.id,
                reporterParticipantID: reporterParticipantID,
                reason: reason,
                capturedAt: inboxItem.capturedAt,
                reportedAt: consentAcceptedAt,
                moderationKeyID: moderationKeyID,
                moderationPublicKey: moderationPublicKey
            )
            item = try MomentSharingStateStore.enqueueReport(
                momentID: inboxItem.id,
                reason: reason,
                prepared: prepared,
                reporterConsentAcceptedAt: consentAcceptedAt,
                validating: authorization.lifecycleToken
            )
        }

        do {
            item = try await transmitReportRecoveringExpired(
                item,
                api: api,
                authorization: authorization
            )
        } catch let error as MomentSharingError {
            if case let .reportOnly(until) = error {
                _ = await establishReportOnlyBoundary(
                    until: until,
                    authorization: authorization
                )
                throw error
            }
            if Self.requiresLocalRevocationReset(error)
                || Self.isReportWindowClosed(error) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
            }
            throw error
        }
        if item.phase == .committed {
            try finalizeCommittedReport(item, authorization: authorization)
        }
    }

    private func sendReportOutbox(
        api: URLSessionMomentSharingAPIClient,
        authorization: Authorization
    ) async throws -> Int {
        let snapshot = try MomentSharingStateStore.load().reportOutbox
        var committedCount = 0
        for candidate in snapshot {
            do {
                let current = try MomentSharingStateStore.load().reportOutbox.first(where: {
                    $0.id == candidate.id
                }) ?? candidate
                if current.phase == .deliveryResultUnknown { continue }
                let wasAlreadyCommitted = current.phase == .committed
                let needsFinalization = try committedReportNeedsFinalization(current)
                if wasAlreadyCommitted && !needsFinalization {
                    continue
                }
                let transmitted: MomentReportOutboxItem
                if wasAlreadyCommitted {
                    transmitted = current
                } else {
                    transmitted = try await transmitReportRecoveringExpired(
                        current,
                        api: api,
                        authorization: authorization
                    )
                }
                if transmitted.phase == .committed {
                    try finalizeCommittedReport(transmitted, authorization: authorization)
                    if !wasAlreadyCommitted { committedCount += 1 }
                }
            } catch let error where Self.requiresLocalRevocationReset(error) {
                throw error
            } catch let error as MomentSharingError {
                if case .reportOnly = error { throw error }
                if Self.isReportWindowClosed(error) { throw error }
                // The user already approved this encrypted report copy. Keep
                // it bounded on disk and retry idempotently on next foreground
                // rather than making safety depend on reopening the menu.
                continue
            } catch {
                continue
            }
        }
        return committedCount
    }

    private func finalizeCommittedReport(
        _ item: MomentReportOutboxItem,
        authorization: Authorization
    ) throws {
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
        try MomentSharingStateStore.removeReportCiphertext(for: item)
        let hasLocalSafetyEvidence = try MomentSharingStateStore.load().inbox.contains {
            $0.id == item.momentID
                && ($0.state == .blocked || $0.state == .revoked)
                && $0.localJPEGFileName != nil
        }
        guard hasLocalSafetyEvidence else { return }
        _ = try MomentSharingStateStore.mutate(
            validating: authorization.lifecycleToken
        ) { state in
            guard let index = state.inbox.firstIndex(where: {
                $0.id == item.momentID
                    && ($0.state == .blocked || $0.state == .revoked)
            }) else { return }
            guard let fileName = state.inbox[index].localJPEGFileName,
                  let directory = SharedContainer.momentSharingReceivedDirectoryURL
            else { return }
            let url = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw MomentSharingError.stateUnavailable
            }
            // Clear the durable reference only after deletion is verified. If
            // the state write fails, the next idempotent finalization sees the
            // still-present filename, observes the already-missing inode, and
            // completes without orphaning plaintext.
            state.inbox[index].localJPEGFileName = nil
        }
    }

    private func committedReportNeedsFinalization(
        _ item: MomentReportOutboxItem
    ) throws -> Bool {
        let ciphertextExists: Bool
        if let directory = SharedContainer.momentSharingCiphertextDirectoryURL {
            ciphertextExists = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(item.ciphertextFileName).path
            )
        } else {
            ciphertextExists = false
        }
        if ciphertextExists { return true }
        return try MomentSharingStateStore.load().inbox.contains {
            $0.id == item.momentID
                && ($0.state == .blocked || $0.state == .revoked)
                && $0.localJPEGFileName != nil
        }
    }

    private func transmitReportRecoveringExpired(
        _ item: MomentReportOutboxItem,
        api: URLSessionMomentSharingAPIClient,
        authorization: Authorization
    ) async throws -> MomentReportOutboxItem {
        do {
            return try await transmitReport(
                item,
                api: api,
                authorization: authorization
            )
        } catch let error as MomentSharingError where Self.isExpiredReservation(error) {
            guard try MomentSharingStateStore.recoverExpiredReportReservation(
                itemID: item.id,
                validating: authorization.lifecycleToken
            ),
            let recovered = try MomentSharingStateStore.load().reportOutbox.first(where: {
                $0.id == item.id
            }) else { throw error }
            return try await transmitReport(
                recovered,
                api: api,
                authorization: authorization
            )
        }
    }

    private func transmitReport(
        _ initialItem: MomentReportOutboxItem,
        api: URLSessionMomentSharingAPIClient,
        authorization: Authorization
    ) async throws -> MomentReportOutboxItem {
        var item = initialItem
        if item.phase == .prepared {
            let prepared = MomentPreparedReport(
                ciphertext: try MomentSharingStateStore.readReportCiphertext(for: item),
                ciphertextSHA256: item.ciphertextSHA256,
                moderationKeyID: item.moderationKeyID
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            let reservation = try await api.reserveReport(
                momentID: item.momentID,
                reason: item.reason,
                prepared: prepared,
                clientRequestID: item.id,
                reporterConsentAcceptedAt: item.reporterConsentAcceptedAt,
                pairingState: authorization.state,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            item = try mutateReportOutbox(
                item.id,
                expected: .prepared,
                lifecycleToken: authorization.lifecycleToken
            ) { value in
                value.serverReportID = reservation.reportID
                switch reservation.state {
                case .reserved: value.phase = .reserved
                case .uploaded: value.phase = .uploaded
                case .committed: value.phase = .committed
                }
            }
        }
        if item.phase == .reserved {
            guard let reportID = item.serverReportID else {
                throw MomentSharingError.stateUnavailable
            }
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            try await api.uploadReport(
                reportID: reportID,
                ciphertext: try MomentSharingStateStore.readReportCiphertext(for: item),
                pairingState: authorization.state,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            item = try mutateReportOutbox(
                item.id,
                expected: .reserved,
                lifecycleToken: authorization.lifecycleToken
            ) { $0.phase = .uploaded }
        }
        if item.phase == .uploaded {
            guard let reportID = item.serverReportID else {
                throw MomentSharingError.stateUnavailable
            }
            item = try mutateReportOutbox(
                item.id,
                expected: .uploaded,
                lifecycleToken: authorization.lifecycleToken
            ) {
                $0.phase = .committing
                $0.commitStartedAt = .now
            }
        }
        if item.phase == .committing {
            guard let reportID = item.serverReportID else {
                throw MomentSharingError.stateUnavailable
            }
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            _ = try await api.commitReport(
                reportID: reportID,
                clientRequestID: item.commitRequestID,
                pairingState: authorization.state,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            item = try mutateReportOutbox(
                item.id,
                expected: .committing,
                lifecycleToken: authorization.lifecycleToken
            ) { $0.phase = .committed }
        }
        return item
    }

    /// Blocking is a hard stop in the two-person v1. The server revokes both
    /// directions, then this device destroys the old room key instead of
    /// pretending it can continue without completing a key-epoch rotation.
    func blockAndLeave(participantID: String) async throws {
        guard configuration.isMediaAvailable else {
            throw MomentSharingError.featureDisabled
        }
        let authorization = try loadAuthorization()
        let state = authorization.state
        guard state.memberID != participantID
        else { throw MomentSharingError.notPaired }
        let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
        do {
            _ = try await api.block(
                participantID: participantID,
                clientRequestID: UUID(),
                pairingState: state,
                credential: authorization.credential
            )
        } catch let error as MomentSharingError {
            if case let .reportOnly(until) = error {
                _ = await establishReportOnlyBoundary(
                    until: until,
                    authorization: authorization
                )
            } else if Self.requiresLocalRevocationReset(error) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: state,
                    lifecycleToken: authorization.lifecycleToken
                )
            }
            throw error
        }
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
        _ = try await PairingInstallationGuard.resetLocalSharingAsync(
            expectedState: state,
            lifecycleToken: authorization.lifecycleToken,
            message: "この相手をブロックし、まどを解除しました。"
        )
    }

    func discardFailedOutbox() throws {
        let lifecycleToken = try loadLocalLifecycleToken()
        try MomentSharingStateStore.discardFailedOutbox(
            validating: lifecycleToken
        )
    }

    func discardPendingOutbox() throws {
        let lifecycleToken = try loadLocalLifecycleToken()
        try MomentSharingStateStore.discardPendingOutbox(
            validating: lifecycleToken
        )
    }

    func discardPendingPreparations() throws {
        let lifecycleToken = try loadLocalLifecycleToken()
        _ = try handoffProcessor.discardCancellableCaptures(
            lifecycleToken: lifecycleToken
        )
    }

    func dismissOutgoingOutcome(id: UUID) throws {
        let lifecycleToken = try loadLocalLifecycleToken()
        try MomentSharingStateStore.dismissOutgoingOutcome(
            id: id,
            validating: lifecycleToken
        )
    }

    func clearOutgoingOutcomes() throws {
        let lifecycleToken = try loadLocalLifecycleToken()
        try MomentSharingStateStore.clearOutgoingOutcomes(
            validating: lifecycleToken
        )
        try MomentShareHandoffStore.clearTerminalOutcomes(
            validating: lifecycleToken
        )
    }

    /// Local deletion must remain available even if the room credential is
    /// missing or damaged. Installation bootstrap is the authorization
    /// boundary; no room key or network client is needed to remove local data.
    private func loadLocalLifecycleToken() throws -> SharingLifecycleGate.Token {
        let bootstrap = try PairingInstallationGuard.bootstrap()
        try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
        return bootstrap.lifecycleToken
    }

    private func loadAuthorization() throws -> Authorization {
        // Every host-app network entry first proves that the ordinary app
        // container still owns the persisted App Group/Keychain state. This
        // removes the reinstall window where stale credentials could be used
        // before a pairing screen had a chance to bootstrap.
        let bootstrap = try PairingInstallationGuard.bootstrap()
        let state = bootstrap.state
        guard state.phase == .paired,
              let account = state.credentialAccount
        else { throw MomentSharingError.notPaired }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: state.installationMarker
        )
        guard credential.roomKey?.count == 32 else {
            throw MomentSharingError.notPaired
        }
        try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
        return Authorization(
            state: state,
            credential: credential,
            lifecycleToken: bootstrap.lifecycleToken
        )
    }

    private func synchronizeWindowNameWithoutMedia(trigger: String) async {
        var authorization: Authorization?
        do {
            let loaded = try loadAuthorization()
            authorization = loaded
            let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
            let changed = try await synchronizeWindowName(
                api: api,
                authorization: loaded
            )
            if changed {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .momentSharingPresentationNeedsRefresh,
                        object: nil
                    )
                }
            }
        } catch let error as MomentSharingError where error == .notPaired {
            return
        } catch {
            if let authorization, Self.requiresLocalRevocationReset(error) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
            }
            SharedLog.app.warning(
                "window-name-sync",
                "Encrypted window name synchronization deferred",
                metadata: ["trigger": String(trigger.prefix(32))]
            )
        }
    }

    /// Name sync is deliberately best effort in the media path. A corrupt,
    /// unavailable, or not-yet-deployed name endpoint must never prevent photo
    /// upload, download, safety analysis, acknowledgement, or cursor progress.
    private func synchronizeWindowNameBestEffort(
        api: any PrivateWindowNameAPIClientProtocol,
        authorization: Authorization,
        trigger: String
    ) async -> Bool {
        do {
            let changed = try await synchronizeWindowName(
                api: api,
                authorization: authorization
            )
            if changed {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .momentSharingPresentationNeedsRefresh,
                        object: nil
                    )
                }
            }
            return changed
        } catch let error where Self.requiresLocalRevocationReset(error) {
            try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                expectedState: authorization.state,
                lifecycleToken: authorization.lifecycleToken
            )
            return false
        } catch {
            SharedLog.app.warning(
                "window-name-sync",
                "Encrypted window name synchronization deferred",
                metadata: ["trigger": String(trigger.prefix(32))]
            )
            return false
        }
    }

    private func synchronizeWindowName(
        api: any PrivateWindowNameAPIClientProtocol,
        authorization: Authorization
    ) async throws -> Bool {
        let pairing = authorization.state
        let credential = authorization.credential
        let lifecycleToken = authorization.lifecycleToken
        try SharingLifecycleGate.validate(lifecycleToken)
        guard pairing.phase == .paired,
              let role = pairing.role,
              let spaceID = pairing.spaceID,
              let ownerMemberID = role == .inviter
                ? pairing.memberID
                : pairing.peerMemberID,
              let roomKey = credential.roomKey,
              roomKey.count == 32
        else { throw MomentSharingError.notPaired }

        let ownerSigningPublicKey: Data
        if role == .inviter {
            ownerSigningPublicKey = try PairingCrypto.signingPublicKey(for: credential)
        } else {
            guard let encoded = pairing.peerSigningPublicKey,
                  let decoded = Data(base64URLString: encoded),
                  decoded.count == 32
            else { throw MomentSharingError.invalidPayload }
            ownerSigningPublicKey = decoded
        }

        let remote = try await api.currentWindowName(
            pairingState: pairing,
            credential: credential
        )
        try SharingLifecycleGate.validate(lifecycleToken)
        var changed = false
        if let remote {
            let payload = try remote.preparedPayload(spaceID: spaceID)
            let displayName = try PrivateWindowNameCrypto.open(
                payload,
                roomKey: roomKey,
                ownerSigningPublicKey: ownerSigningPublicKey
            )
            if try PrivateWindowNameSyncStore.recordAccepted(
                payload,
                pairing: pairing,
                validating: lifecycleToken
            ) {
                let before = PrivateWindowPresentationStore.resolvedDisplayName(
                    pairing: pairing,
                    validating: lifecycleToken
                )
                let applied = try PrivateWindowPresentationStore.applySynchronizedOwnerName(
                    displayName: displayName,
                    ownerRevision: payload.context.ownerRevision,
                    pairing: pairing,
                    validating: lifecycleToken
                )
                changed = applied.displayName != before
            }
        }

        guard role == .inviter else { return changed }
        let local = try PrivateWindowPresentationStore.load(
            pairing: pairing,
            validating: lifecycleToken
        )
        let localRevision = local?.storageRevision ?? 0
        let localDisplayName = local?.displayName ?? PrivateWindowDisplayName.fallback
        if let remote, remote.ownerRevision >= localRevision { return changed }
        if remote == nil,
           let floor = try PrivateWindowNameSyncStore.load(
            pairing: pairing,
            validating: lifecycleToken
           )?.acceptedOwnerRevision,
           floor >= localRevision {
            // A previously accepted record disappearing is a rollback, not an
            // invitation to recreate an older local value.
            throw MomentSharingError.invalidPayload
        }

        let staged: (payload: PrivateWindowNamePreparedPayload, clientRequestID: UUID)
        if let existing = try PrivateWindowNameSyncStore.pending(
            ownerRevision: localRevision,
            pairing: pairing,
            validating: lifecycleToken
        ) {
            staged = existing
        } else {
            let prepared = try PrivateWindowNameCrypto.prepare(
                displayName: localDisplayName,
                context: PrivateWindowNameCiphertextContext(
                    spaceID: spaceID,
                    ownerMemberID: ownerMemberID,
                    ownerRevision: localRevision,
                    keyEpoch: 1
                ),
                roomKey: roomKey,
                ownerCredential: credential
            )
            staged = try PrivateWindowNameSyncStore.stagePending(
                prepared,
                clientRequestID: UUID(),
                pairing: pairing,
                validating: lifecycleToken
            )
        }
        try SharingLifecycleGate.validate(lifecycleToken)
        let committed = try await api.putWindowName(
            staged.payload,
            clientRequestID: staged.clientRequestID,
            pairingState: pairing,
            credential: credential
        )
        try SharingLifecycleGate.validate(lifecycleToken)
        let committedPayload = try committed.preparedPayload(spaceID: spaceID)
        let committedName = try PrivateWindowNameCrypto.open(
            committedPayload,
            roomKey: roomKey,
            ownerSigningPublicKey: ownerSigningPublicKey
        )
        guard try PrivateWindowNameSyncStore.recordAccepted(
            committedPayload,
            pairing: pairing,
            validating: lifecycleToken
        ) else { return changed }
        let before = PrivateWindowPresentationStore.resolvedDisplayName(
            pairing: pairing,
            validating: lifecycleToken
        )
        let applied = try PrivateWindowPresentationStore.applySynchronizedOwnerName(
            displayName: committedName,
            ownerRevision: committedPayload.context.ownerRevision,
            pairing: pairing,
            validating: lifecycleToken
        )
        return changed || applied.displayName != before
    }

    private func sendOutbox(
        api: URLSessionMomentSharingAPIClient,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try SharingLifecycleGate.validate(lifecycleToken)
        var sentCount = 0
        let snapshot = try MomentSharingStateStore.load()
        for candidate in snapshot.outbox where
            candidate.phase != .committed
                && candidate.phase != .deliveryResultUnknown
                && candidate.phase != .failed {
            if let retryAt = candidate.nextRetryAt, retryAt > .now { continue }
            do {
                var item = try currentOutboxItem(candidate.id)
                if item.phase == .prepared {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let reservation = try await api.reserve(
                        item: item,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    item = try mutateOutbox(
                        item.id,
                        expected: .prepared,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .reserved
                        value.serverMomentID = reservation.momentID
                        value.uploadExpiresAt = reservation.uploadExpiresAt
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                }
                if item.phase == .reserved {
                    guard let momentID = item.serverMomentID else {
                        throw MomentSharingError.stateUnavailable
                    }
                    let ciphertext = try MomentSharingStateStore.readCiphertext(for: item)
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try await api.upload(
                        momentID: momentID,
                        ciphertext: ciphertext,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    item = try mutateOutbox(
                        item.id,
                        expected: .reserved,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .uploaded
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                }
                if item.phase == .uploaded {
                    guard let momentID = item.serverMomentID else {
                        throw MomentSharingError.stateUnavailable
                    }
                    item = try mutateOutbox(
                        item.id,
                        expected: .uploaded,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .committing
                        value.commitStartedAt = .now
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                }
                if item.phase == .committing {
                    guard let momentID = item.serverMomentID else {
                        throw MomentSharingError.stateUnavailable
                    }
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let commit = try await api.commit(
                        momentID: momentID,
                        clientRequestID: item.context.clientRequestID,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    item = try mutateOutbox(
                        item.id,
                        expected: .committing,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .committed
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                        value.committedAt = commit.committedAt
                        value.unreceivedExpiresAt = commit.unreceivedExpiresAt
                        value.recipientCount = commit.recipientCount
                    }
                    try MomentSharingStateStore.removeCiphertext(for: item)
                    sentCount += 1
                }
            } catch let error where Self.requiresLocalRevocationReset(error) {
                throw error
            } catch let error as MomentSharingError {
                if case .reportOnly = error { throw error }
                // The relay checks an existing idempotent commit response
                // before returning reservation_expired. This response therefore
                // proves the old lease did not commit and is safe to re-reserve,
                // even when the durable local phase had already become
                // `.committing` before a crash or long suspension.
                if Self.isExpiredReservation(error) {
                    _ = try MomentSharingStateStore.recoverExpiredReservation(
                        itemID: candidate.id,
                        validating: lifecycleToken
                    )
                    continue
                }
                if (try? currentOutboxItem(candidate.id).phase) == .committing {
                    // A commit request may already have succeeded before its
                    // response became unusable. Never rewrite that ambiguity
                    // as a permanent local failure; retry the same idempotency
                    // key until the relay can confirm the committed record.
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                    continue
                }
                if Self.isReservationRetryLimit(error) {
                    try MomentSharingStateStore.markOutboxFailed(
                        itemID: candidate.id,
                        code: "reservation-retry-limit",
                        validating: lifecycleToken
                    )
                    continue
                }
                if MomentSendFailurePolicy.isPermanentOutboxFailure(error) {
                    try MomentSharingStateStore.markOutboxFailed(
                        itemID: candidate.id,
                        code: Self.safeErrorCode(error),
                        validating: lifecycleToken
                    )
                    continue
                }
                do {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                } catch {
                    throw MomentSharingError.stateUnavailable
                }
            } catch {
                do {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                } catch {
                    throw MomentSharingError.stateUnavailable
                }
            }
        }
        return sentCount
    }

    private func receiveChanges(
        api: any MomentSharingAPIClientProtocol,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try SharingLifecycleGate.validate(lifecycleToken)
        guard let spaceID = pairing.spaceID,
              let localMemberID = pairing.memberID,
              let roomKey = credential.roomKey
        else { throw MomentSharingError.notPaired }
        var receivedCount = 0
        var pageCount = 0
        while pageCount < 5 {
            pageCount += 1
            let state = try MomentSharingStateStore.load()
            let requestedCursor = state.changeCursor
            var processedCursor = requestedCursor
            try SharingLifecycleGate.validate(lifecycleToken)
            let result = try await api.changes(
                after: requestedCursor,
                pairingState: pairing,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            if result.changes.isEmpty {
                if result.nextCursor != state.changeCursor {
                    _ = try MomentSharingStateStore.advanceChangeCursor(
                        expected: requestedCursor,
                        next: result.nextCursor,
                        validating: lifecycleToken
                    )
                }
                break
            }
            for change in result.changes {
                switch try MomentDeliveryActionPolicy.action(
                    changeType: change.type,
                    deliveryState: change.deliveryState
                ) {
                case .revokeWithoutDownload:
                    try revokeInboxMoment(change, lifecycleToken: lifecycleToken)
                case .download:
                    guard change.senderParticipantID != localMemberID else {
                        break
                    }
                    if try MomentSharingStateStore.load().inbox.contains(where: {
                        $0.id == change.momentID
                            && ($0.state == .acknowledged || $0.state == .revoked)
                    }) {
                        break
                    }
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let ciphertext = try await api.download(
                        momentID: change.momentID,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    guard ciphertext.count == change.ciphertextSize,
                          PairingCrypto.sha256(ciphertext) == change.ciphertextSHA256,
                          change.keyEpoch == 1
                    else { throw MomentSharingError.invalidPayload }
                    let context = MomentRequestContext(
                        spaceID: spaceID,
                        senderParticipantID: change.senderParticipantID,
                        senderDeviceID: change.senderParticipantID,
                        clientRequestID: UUID(),
                        clientMomentID: change.clientMomentID,
                        kind: change.kind,
                        keyEpoch: change.keyEpoch
                    )
                    let opened = try MomentCrypto.open(
                        MomentPreparedPayload(
                            context: context,
                            ciphertext: ciphertext,
                            ciphertextSHA256: change.ciphertextSHA256,
                            moderationVersion: MomentSharingProtocol.moderationVersion
                        ),
                        spaceGenerationKey: roomKey
                    )
                    try MomentCanonicalPreviewBuilder.validateReceived(
                        opened.jpeg,
                        pixelWidth: opened.manifest.pixelWidth,
                        pixelHeight: opened.manifest.pixelHeight,
                        expectedPlaintextSHA256: opened.manifest.plaintextSHA256
                    )
                    let inbox = try await storeReceived(
                        change: change,
                        jpeg: opened.jpeg,
                        manifest: opened.manifest,
                        lifecycleToken: lifecycleToken
                    )
                    guard inbox.state != .revoked else { break }
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let acknowledgement = try await api.acknowledge(
                        momentID: change.momentID,
                        ciphertextSHA256: change.ciphertextSHA256,
                        clientRequestID: UUID(),
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
                        guard let index = state.inbox.firstIndex(where: { $0.id == inbox.id }) else {
                            throw MomentSharingError.stateUnavailable
                        }
                        guard state.inbox[index].state != .revoked else { return }
                        if state.inbox[index].state == .available {
                            state.inbox[index].state = .acknowledged
                        }
                        state.inbox[index].acknowledgedAt = acknowledgement.acknowledgedAt
                        state.inbox[index].accessExpiresAt = acknowledgement.accessExpiresAt
                    }
                    receivedCount += 1
                }
                guard try MomentSharingStateStore.advanceChangeCursor(
                    expected: processedCursor,
                    next: change.cursor,
                    validating: lifecycleToken
                ) else { return receivedCount }
                processedCursor = change.cursor
            }
            // The API uses a fixed page size of 100. A full page may have a
            // following page even when `nextCursor` equals the last processed
            // change (which is also our persisted cursor).
            guard result.changes.count == 100,
                  result.nextCursor != requestedCursor
            else { break }
        }
        return receivedCount
    }

#if DEBUG
    /// Exercises the same process-wide serial queue without touching
    /// pairing, network, Keychain, or photo state.
    func runtimeTestJoinProcessSynchronization(
        operation: @escaping @Sendable () async -> MomentSynchronizationNotice?
    ) async -> MomentSynchronizationNotice? {
        let request = MomentSynchronizationRequest()
        let notice = await withTaskCancellationHandler {
            await runMomentProcessSynchronization(
                request: request,
                operation: operation
            )
        } onCancel: {
            request.cancel()
        }
        latestSynchronizationNotice = notice
        return notice
    }

    func runtimeTestWaitUntilProcessSynchronizationIsPending(
        count: Int = 1
    ) async {
        await momentProcessSynchronizationGate.runtimeWaitUntilPendingRequestCount(count)
    }

    /// Generated-data simulator coverage for the download → moderation → ACK
    /// → cursor boundary. Release builds keep the receive primitive private.
    func runtimeTestReceiveChanges(
        api: any MomentSharingAPIClientProtocol,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try await receiveChanges(
            api: api,
            pairing: pairing,
            credential: credential,
            lifecycleToken: lifecycleToken
        )
    }
#endif

    private func storeReceived(
        change: MomentChange,
        jpeg: Data,
        manifest: MomentEncryptedManifest,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> MomentInboxItem {
        let fileName = "\(change.momentID).jpg"
        let moderationInput = try prepareInboundModerationInput(
            jpeg,
            validating: lifecycleToken
        )
        defer { try? FileManager.default.removeItem(at: moderationInput) }
        let moderationError: MomentSharingError?
        do {
            try await moderation.requireSafeImage(at: moderationInput)
            moderationError = nil
        } catch let error as MomentSharingError {
            do {
                try SharingLifecycleGate.validate(lifecycleToken)
            } catch {
                throw MomentSharingError.stateUnavailable
            }
            moderationError = error
        } catch {
            do {
                try SharingLifecycleGate.validate(lifecycleToken)
            } catch {
                throw MomentSharingError.stateUnavailable
            }
            moderationError = .moderationUnavailable
        }
        let state = try MomentInboundModerationPolicy.inboxState(
            after: moderationError
        )

        let item = try MomentInboxItem(
            id: change.momentID,
            senderParticipantID: change.senderParticipantID,
            kind: change.kind,
            keyEpoch: change.keyEpoch,
            localJPEGFileName: fileName,
            capturedAt: manifest.capturedAt,
            captureDateIsMissing: manifest.captureDateIsMissing,
            committedAt: change.committedAt,
            receivedAt: .now,
            state: state,
            accessExpiresAt: change.accessExpiresAt
        ).validated()
        // Final file publication and monotonic inbox mutation share the
        // lifecycle flock. A revoke/unlink either wins first or observes the
        // complete publication; no late download can recreate visible data.
        return try MomentSharingStateStore.publishReceivedJPEG(
            item,
            jpeg: jpeg,
            validating: lifecycleToken
        )
    }

    private func revokeInboxMoment(
        _ change: MomentChange,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        let tombstone = try MomentInboxItem(
            id: change.momentID,
            senderParticipantID: change.senderParticipantID,
            kind: change.kind,
            keyEpoch: change.keyEpoch,
            localJPEGFileName: nil,
            capturedAt: nil,
            captureDateIsMissing: true,
            committedAt: change.committedAt,
            receivedAt: .now,
            state: .revoked,
            accessExpiresAt: change.accessExpiresAt
        ).validated()
        try MomentSharingStateStore.revokeInbox(
            tombstone: tombstone,
            validating: lifecycleToken
        )
    }

    private func prepareInboundModerationInput(
        _ jpeg: Data,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> URL {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            let directory = Self.inboundModerationTemporaryDirectory
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try MomentShareHandoffProcessor
                .enforceCompleteProtectionAndBackupExclusion(directory)
            // Moment relay I/O is process-serialized. Any prior inode here is
            // therefore crash residue, not another live analyzer input.
            try purgeInboundModerationTemporaryFilesWhileLifecycleLocked()
            let url = directory.appendingPathComponent(
                ".inbound-\(UUID().uuidString.lowercased()).jpg",
                isDirectory: false
            )
            try MomentShareHandoffProcessor.writeCompleteProtected(jpeg, to: url)
            return url
        }
    }

    private func purgeInboundModerationTemporaryFiles(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try purgeInboundModerationTemporaryFilesWhileLifecycleLocked()
        }
    }

    private func purgeInboundModerationTemporaryFilesWhileLifecycleLocked() throws {
        let directory = Self.inboundModerationTemporaryDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for file in files where file.lastPathComponent.hasPrefix(".inbound-") {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private static var inboundModerationTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "NekoWidgetMomentInboundModeration",
            isDirectory: true
        )
    }

    private func currentOutboxItem(_ id: UUID) throws -> MomentOutboxItem {
        guard let value = try MomentSharingStateStore.load().outbox.first(where: { $0.id == id })
        else { throw MomentSharingError.stateUnavailable }
        return value
    }

    @discardableResult
    private func mutateOutbox(
        _ id: UUID,
        expected phase: MomentOutboxPhase,
        lifecycleToken: SharingLifecycleGate.Token,
        operation: (inout MomentOutboxItem) throws -> Void
    ) throws -> MomentOutboxItem {
        var result: MomentOutboxItem?
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == id }),
                  state.outbox[index].phase == phase
            else { throw MomentSharingError.stateUnavailable }
            try operation(&state.outbox[index])
            state.outbox[index].updatedAt = .now
            result = state.outbox[index]
        }
        guard let result else { throw MomentSharingError.stateUnavailable }
        return result
    }

    private func recordRetry(
        for id: UUID,
        error: Error,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == id }) else { return }
            state.outbox[index].attemptCount += 1
            let exponent = min(state.outbox[index].attemptCount - 1, 6)
            state.outbox[index].nextRetryAt = Date().addingTimeInterval(
                min(3_600, 30 * pow(2, Double(exponent)))
            )
            state.outbox[index].lastErrorCode = Self.safeErrorCode(error)
            state.outbox[index].updatedAt = .now
        }
    }

    @discardableResult
    private func mutateReportOutbox(
        _ id: UUID,
        expected phase: MomentReportOutboxPhase,
        lifecycleToken: SharingLifecycleGate.Token,
        operation: (inout MomentReportOutboxItem) throws -> Void
    ) throws -> MomentReportOutboxItem {
        var result: MomentReportOutboxItem?
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.reportOutbox.firstIndex(where: { $0.id == id }),
                  state.reportOutbox[index].phase == phase
            else { throw MomentSharingError.stateUnavailable }
            try operation(&state.reportOutbox[index])
            state.reportOutbox[index].updatedAt = .now
            result = state.reportOutbox[index]
        }
        guard let result else { throw MomentSharingError.stateUnavailable }
        return result
    }

    private nonisolated static func safeErrorCode(_ error: Error) -> String {
        if let error = error as? MomentSharingError {
            switch error {
            case .featureDisabled: return "feature-disabled"
            case .notPaired: return "not-paired"
            case .consentRequired: return "consent-required"
            case .moderationDisabled: return "moderation-disabled"
            case .moderationUnavailable: return "moderation-unavailable"
            case .sensitiveContent: return "sensitive-content"
            case .invalidPayload: return "invalid-payload"
            case .payloadTooLarge: return "payload-too-large"
            case .outboxFull: return "outbox-full"
            case .stateUnavailable: return "state-unavailable"
            case .reportOnly: return "report-only"
            case .retryableServer: return "retryable-server"
            case let .requestRejected(status, code, _):
                return "http-\(status)-\((code ?? "rejected").prefix(48))"
            }
        }
        return "unknown"
    }

    private nonisolated static func synchronizationNotice(
        for error: Error
    ) -> MomentSynchronizationNotice? {
        guard let momentError = error as? MomentSharingError else { return nil }
        switch momentError {
        case .moderationDisabled:
            return .inboundModerationDisabled
        case .moderationUnavailable:
            return .inboundModerationUnavailable
        default:
            return nil
        }
    }

    private nonisolated static func requiresLocalRevocationReset(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        // Moment/report routes use 410 only for an expired upload lease or a
        // terminal authorization boundary. A well-formed
        // reservation_expired response is recoverable; every other or
        // undecodable 410 must fail closed and clear local authorization.
        return status == 410 && code != "reservation_expired"
    }

    /// Establishes the durable report-only marker/state boundary. If the
    /// cross-store state write cannot finish, the fallback must still commit
    /// the marker and remove all handoff plaintext; an admission-only purge is
    /// not durable enough. Only when that marker fallback also fails do we
    /// tear down the entire local pairing.
    private func establishReportOnlyBoundary(
        until: Date,
        authorization: Authorization,
        now: Date = .now
    ) async -> Bool {
        do {
            try handoffProcessor.enterReportOnlyMode(
                until: until,
                lifecycleToken: authorization.lifecycleToken,
                now: now
            )
            return true
        } catch {
            do {
                try handoffProcessor.establishReportOnlyHandoffGate(
                    until: until,
                    lifecycleToken: authorization.lifecycleToken,
                    now: now
                )
                return true
            } catch {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
                return false
            }
        }
    }

    /// Repairs a marker whose protected payload is unreadable without making
    /// it a permanent retention or reporting blocker. A valid local state
    /// deadline wins. If state was never committed (marker-first crash), the
    /// protected inode's fixed creation/modification anchor supplies a local
    /// maximum window. When neither source is trustworthy, full reset is the
    /// only bounded fail-closed recovery.
    private func recoverReportOnlyBoundary(
        authorization: Authorization,
        now: Date
    ) async -> Date? {
        // Bounded cleanup remains available even while the marker is corrupt.
        // Failure is non-fatal here because a valid report window may still
        // preserve safety evidence needed by the direct report path.
        try? MomentSharingStateStore.pruneLocalHistory(now: now)

        var recoveredUntil: Date?
        if let state = try? MomentSharingStateStore.load(),
           let stateUntil = state.reportOnlyUntil {
            if MomentSharingProtocol.isReportOnlyWindowClosed(
                until: stateUntil,
                now: now
            ) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
                return nil
            }
            recoveredUntil = try? MomentSharingProtocol.boundedReportOnlyUntil(
                stateUntil,
                receivedAt: now
            )
        }

        if recoveredUntil == nil {
            do {
                recoveredUntil = try MomentShareHandoffStore
                    .reportOnlyHandoffRecoveryDeadline(
                        validating: authorization.lifecycleToken,
                        now: now
                    )
            } catch {
                recoveredUntil = nil
            }
        }

        guard let recoveredUntil,
              !MomentSharingProtocol.isReportOnlyWindowClosed(
                  until: recoveredUntil,
                  now: now
              )
        else {
            try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                expectedState: authorization.state,
                lifecycleToken: authorization.lifecycleToken
            )
            return nil
        }
        guard await establishReportOnlyBoundary(
            until: recoveredUntil,
            authorization: authorization,
            now: now
        ) else { return nil }
        return recoveredUntil
    }

    private func revokeHandoffOrReset(
        authorization: Authorization
    ) async {
        do {
            try handoffProcessor.revokeAdmissions(
                lifecycleToken: authorization.lifecycleToken
            )
        } catch {
            try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                expectedState: authorization.state,
                lifecycleToken: authorization.lifecycleToken
            )
        }
    }

    private func handleStateUnavailable(
        authorization: Authorization
    ) async {
        do {
            if try MomentSharingStateStore.isPersistedStateDefinitelyCorrupt(
                validating: authorization.lifecycleToken
            ) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
                return
            }
        } catch {
            // An unreadable protected file can be transient while the device
            // is locked or storage is unavailable. Preserve evidence and let
            // a later foreground sync retry instead of treating I/O as proof
            // of corruption.
        }
        await revokeHandoffOrReset(authorization: authorization)
    }

    private nonisolated static func isExpiredReservation(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        return status == 410 && code == "reservation_expired"
    }

    private nonisolated static func isReservationRetryLimit(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        return status == 429 && code == "reservation_retry_limit_exceeded"
    }

    private nonisolated static func isReportWindowClosed(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else { return false }
        return status == 410 && code == "report_window_closed"
    }
}
