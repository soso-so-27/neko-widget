import Foundation

enum MomentSynchronizationNotice: Equatable, Sendable {
    case inboundModerationDisabled
    case inboundModerationUnavailable
}

private struct MomentSynchronizationRunResult: Sendable {
    let notice: MomentSynchronizationNotice?
    let succeeded: Bool
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
    operation: @escaping @Sendable () async -> MomentSynchronizationRunResult
) async -> MomentSynchronizationRunResult? {
    await momentProcessSynchronizationGate.acquire()
    let result: MomentSynchronizationRunResult?
    if request.shouldBegin() {
        result = await operation()
    } else {
        result = nil
    }
    await momentProcessSynchronizationGate.release()
    return result
}

private func runMomentProcessOperation<Value: Sendable>(
    request: MomentSynchronizationRequest,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    await momentProcessSynchronizationGate.acquire()
    do {
        guard request.shouldBegin() else { throw CancellationError() }
        let value = try await operation()
        await momentProcessSynchronizationGate.release()
        return value
    } catch {
        await momentProcessSynchronizationGate.release()
        throw error
    }
}

actor MomentSharingCoordinator {
    private struct Authorization: Sendable {
        let state: PairingState
        let credential: PairingCredential
        let lifecycleToken: SharingLifecycleGate.Token
    }

    /// Closed, non-sensitive categories persisted in diagnostic log messages.
    /// Never include relay-provided codes/messages or local paths here.
    private enum PairingResetReason: String, Sendable {
        case remoteAuthorizationTerminal = "remote-authorization-terminal"
        case reportOnlyWindowClosed = "report-only-window-closed"
    }

    private enum LocalSharingFailureReason: String, Sendable {
        case remoteAuthorizationTerminal = "remote-authorization-terminal"
        case stateCorrupt = "local-state-corrupt"
        case stateUnavailable = "local-state-unavailable"
        case reportOnlyBoundaryUnavailable = "report-only-boundary-unavailable"
        case handoffCleanupUnavailable = "handoff-cleanup-unavailable"
        case resourceGone = "resource-gone-nonterminal"
        case requestRejected = "request-rejected-nonterminal"
        case runtimeUnavailable = "runtime-unavailable"
    }

    /// Internal route provenance. The relay code is converted to this marker
    /// only inside the report outbox path, so a future non-report endpoint
    /// cannot trigger report-only credential cleanup by returning the same
    /// untrusted code string.
    private enum BackgroundSynchronizationTermination: Error, Sendable {
        case reportOnlyWindowClosed
    }

    private let configuration: SharingAPIConfiguration
    private let moderation: any MomentModerating
    private let handoffProcessor: MomentShareHandoffProcessor
    private var latestSynchronizationNotice: MomentSynchronizationNotice?
#if DEBUG
    private var runtimeNetworkClientConstructionCount = 0
#endif

    init(
        configuration: SharingAPIConfiguration = .current,
        moderation: any MomentModerating = MomentModerationService()
    ) {
        self.configuration = configuration
        self.moderation = moderation
        handoffProcessor = MomentShareHandoffProcessor(moderation: moderation)
    }

    private func makeNetworkClient() throws -> URLSessionMomentSharingAPIClient {
#if DEBUG
        runtimeNetworkClientConstructionCount += 1
#endif
        return try URLSessionMomentSharingAPIClient(configuration: configuration)
    }

    @discardableResult
    func synchronize(trigger: String) async -> Bool {
        let request = MomentSynchronizationRequest()
        let result = await withTaskCancellationHandler {
            await runMomentProcessSynchronization(request: request) { [self] in
                let succeeded = await performSynchronization(trigger: trigger)
                return MomentSynchronizationRunResult(
                    notice: await synchronizationNotice(),
                    succeeded: succeeded
                )
            }
        } onCancel: {
            request.cancel()
        }
        latestSynchronizationNotice = result?.notice
        return result?.succeeded ?? false
    }

    /// Runs only the encrypted presentation-name exchange and reports relay
    /// failures to the caller. Manual rename must not enqueue a complete photo
    /// pass, and unlike background refresh it must tell the person whether the
    /// other device can receive the new label.
    func synchronizeWindowNameForUser(trigger: String) async throws {
        let request = MomentSynchronizationRequest()
        try await withTaskCancellationHandler {
            try await runMomentProcessOperation(request: request) { [self] in
                try await performWindowNameSynchronizationForUser(trigger: trigger)
            }
        } onCancel: {
            request.cancel()
        }
    }

#if DEBUG
    func runtimeSynchronizeWindowName(
        api: any PrivateWindowNameAPIClientProtocol
    ) async throws {
        let authorization = try loadAuthorization()
        _ = try await synchronizeWindowName(
            api: api,
            authorization: authorization
        )
    }
#endif

    private func performWindowNameSynchronizationForUser(trigger: String) async throws {
        var authorization: Authorization?
        do {
            let loaded = try loadAuthorization()
            authorization = loaded
            if configuration.isShareExtensionHandoffAvailable {
                do {
                    try handoffProcessor.refreshAdmissionLabel(
                        pairing: loaded.state,
                        credential: loaded.credential,
                        lifecycleToken: loaded.lifecycleToken
                    )
                } catch {
                    SharedLog.app.warning(
                        "window-presentation",
                        "Share destination label refresh deferred"
                    )
                }
            }
            let api = try makeNetworkClient()
            _ = try await synchronizeWindowName(
                api: api,
                authorization: loaded
            )
            try SharingLifecycleGate.validate(loaded.lifecycleToken)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .momentSharingPresentationNeedsRefresh,
                    object: nil
                )
            }
            SharedLog.app.info(
                "window-name-sync",
                "Encrypted window name synchronized after an explicit save",
                metadata: ["trigger": String(trigger.prefix(32))]
            )
        } catch {
            if let authorization, Self.requiresLocalRevocationReset(error) {
                try? await resetLocalPairing(
                    authorization: authorization,
                    reason: .remoteAuthorizationTerminal
                )
            } else {
                Self.logNonterminalRequestRejection(error)
            }
            throw error
        }
    }

    private func performSynchronization(trigger: String) async -> Bool {
        latestSynchronizationNotice = nil

        // A local-only build must erase every capability and sharing artifact
        // inherited from an earlier enabled build. The reset writes its durable
        // cleanup tombstone before deleting credentials/cache and clears it only
        // after an unpaired state is committed. Any failure therefore remains
        // fail-closed here and is retried by the next launch/foreground sync.
        if configuration.requiresLocalSharingPurge {
            do {
                try await PairingInstallationGuard
                    .resetLocalSharingForDisabledConfigurationAsync()
                return true
            } catch {
                SharedLog.app.warning(
                    "moment-sharing",
                    "Disabled sharing purge deferred",
                    metadata: ["trigger": String(trigger.prefix(32))]
                )
                return false
            }
        }

        // Disabling media/handoff must also revoke any previously published
        // Share Extension admission and physically remove staged plaintext.
        // Bootstrap first so a reinstall cleanup wins before App Group state
        // is inspected or retained.
        guard configuration.isMediaAvailable else {
            var cleanupSucceeded = true
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
                cleanupSucceeded = false
                SharedLog.app.warning(
                    "moment-sharing",
                    "Disabled moment handoff cleanup deferred",
                    metadata: ["trigger": String(trigger.prefix(32))]
                )
            }
            if configuration.isAvailable {
                await synchronizeWindowNameWithoutMedia(trigger: trigger)
            }
            return cleanupSucceeded
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
                ) else { return false }
                markerUntil = recoveredUntil
            }
            if let markerUntil {
                guard !MomentSharingProtocol.isReportOnlyWindowClosed(
                    until: markerUntil,
                    now: resumeNow
                ) else {
                    try await resetLocalPairing(
                        authorization: loadedAuthorization,
                        reason: .reportOnlyWindowClosed
                    )
                    return true
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
                try await resetLocalPairing(
                    authorization: loadedAuthorization,
                    reason: .reportOnlyWindowClosed
                )
                return true
            }
            let api = try makeNetworkClient()
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
                    ) else { return false }
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
                    return true
                }
            }
            let reported = try await sendReportOutbox(
                api: api,
                authorization: loadedAuthorization
            )
            let handedOff: Int
            let sent: Int
            let received: Int
            var pawsSent = 0
            var pawsReceived = 0
            let hasCurrentMediaConsent =
                loadedAuthorization.state.mediaSharingConsentVersion
                    == PairingMediaSharingConsent.currentVersion
                && loadedAuthorization.state.mediaSharingConsentAcceptedAt != nil
            if !hasCurrentMediaConsent {
                // A recovered installation deliberately starts without photo
                // consent. Keep every media admission and operation disabled,
                // but do not treat that media-only boundary as a reason to
                // suppress the encrypted presentation-name exchange below.
                try handoffProcessor.revokeAdmissions(
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
                handedOff = 0
                sent = 0
                received = 0
            } else {
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
                sent = try await sendOutbox(
                    api: api,
                    pairing: loadedAuthorization.state,
                    credential: loadedAuthorization.credential,
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
                received = try await receiveChanges(
                    api: api,
                    pairing: loadedAuthorization.state,
                    credential: loadedAuthorization.credential,
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
                do {
                    pawsSent = try await sendPawOutbox(
                        api: api,
                        pairing: loadedAuthorization.state,
                        credential: loadedAuthorization.credential,
                        lifecycleToken: loadedAuthorization.lifecycleToken
                    )
                } catch {
                    if Self.requiresLocalRevocationReset(error) { throw error }
                    Self.logNonterminalRequestRejection(error)
                }
                do {
                    pawsReceived = try await receivePawChanges(
                        api: api,
                        pairing: loadedAuthorization.state,
                        credential: loadedAuthorization.credential,
                        lifecycleToken: loadedAuthorization.lifecycleToken
                    )
                } catch {
                    if Self.requiresLocalRevocationReset(error) { throw error }
                    Self.logNonterminalRequestRejection(error)
                }
                // Do not make a safely committed inbound photo (or a revoke)
                // wait for the independent window-name request before Home and
                // Widget publication. `receiveChanges` has already processed
                // the complete bounded change stream, including ACKs and
                // revocation tombstones, at this point.
                let inboundState = try MomentSharingStateStore.load(
                    validating: loadedAuthorization.lifecycleToken
                )
                if inboundState.inbox != localSharingState.inbox
                    || inboundState.pawOutbox != localSharingState.pawOutbox
                    || inboundState.receivedPaws != localSharingState.receivedPaws {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .momentSharingPresentationNeedsRefresh,
                            object: nil
                        )
                        NotificationCenter.default.post(
                            name: .momentSharingContentNeedsReload,
                            object: nil
                        )
                    }
                }
            }
            // Keep presentation metadata behind safety reports and every
            // consented photo operation. A stalled or unavailable name
            // endpoint must not delay delivery, ACKs, or cursor progress.
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
                    "pawsSent": "\(pawsSent)",
                    "pawsReceived": "\(pawsReceived)",
                    "windowNameChanged": "\(windowNameChanged)"
                ]
            )
            return true
        } catch {
            latestSynchronizationNotice = Self.synchronizationNotice(for: error)
            if error is BackgroundSynchronizationTermination {
                return true
            }
            if let authorization,
               let momentError = error as? MomentSharingError,
               case let .reportOnly(until) = momentError {
                _ = await establishReportOnlyBoundary(
                    until: until,
                    authorization: authorization
                )
            } else if let authorization, Self.requiresLocalRevocationReset(error) {
                do {
                    try await resetLocalPairing(
                        authorization: authorization,
                        reason: .remoteAuthorizationTerminal
                    )
                    return true
                } catch {
                    return false
                }
            } else if let authorization,
                      let momentError = error as? MomentSharingError,
                      case .stateUnavailable = momentError {
                await handleStateUnavailable(authorization: authorization)
            }
            Self.logSynchronizationDeferred(error: error, trigger: trigger)
            return false
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
                try await resetLocalPairing(
                    authorization: authorization,
                    reason: .reportOnlyWindowClosed
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
                try await resetLocalPairing(
                    authorization: authorization,
                    reason: .reportOnlyWindowClosed
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
        let api = try makeNetworkClient()
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
                try? await resetLocalPairing(
                    authorization: authorization,
                    reason: Self.isReportWindowClosed(error)
                        ? .reportOnlyWindowClosed
                        : .remoteAuthorizationTerminal
                )
            } else {
                Self.logNonterminalRequestRejection(error)
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
                if Self.isReportWindowClosed(error) {
                    try await resetLocalPairing(
                        authorization: authorization,
                        reason: .reportOnlyWindowClosed
                    )
                    throw BackgroundSynchronizationTermination.reportOnlyWindowClosed
                }
                Self.logNonterminalRequestRejection(error)
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
        let api = try makeNetworkClient()
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
                try? await resetLocalPairing(
                    authorization: authorization,
                    reason: .remoteAuthorizationTerminal
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
            let api = try makeNetworkClient()
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
                try? await resetLocalPairing(
                    authorization: authorization,
                    reason: .remoteAuthorizationTerminal
                )
            }
            SharedLog.app.warning(
                "window-name-sync",
                "Encrypted window name synchronization deferred",
                metadata: [
                    "sharingFailureReason": Self.localFailureReason(for: error).rawValue,
                    "trigger": String(trigger.prefix(32))
                ]
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
            try? await resetLocalPairing(
                authorization: authorization,
                reason: .remoteAuthorizationTerminal
            )
            return false
        } catch {
            SharedLog.app.warning(
                "window-name-sync",
                "Encrypted window name synchronization deferred",
                metadata: [
                    "sharingFailureReason": Self.localFailureReason(for: error).rawValue,
                    "trigger": String(trigger.prefix(32))
                ]
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

        try await requireWindowNameSynchronizationAllowed(
            authorization: authorization
        )

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
        let predecessorOwnerSigningPublicKey: Data?
        if role == .inviter,
           pairing.recoveryWasLocalDeviceReplacement == true,
           let encoded = pairing.recoveryPreviousTargetSigningPublicKey,
           let decoded = Data(base64URLString: encoded),
           decoded.count == 32 {
            predecessorOwnerSigningPublicKey = decoded
        } else {
            predecessorOwnerSigningPublicKey = nil
        }

        let remote = try await api.currentWindowName(
            pairingState: pairing,
            credential: credential
        )
        try SharingLifecycleGate.validate(lifecycleToken)
        var changed = false
        if let remote {
            let payload = try remote.preparedPayload(spaceID: spaceID)
            let displayName: String
            let requiresOwnerResign: Bool
            do {
                displayName = try PrivateWindowNameCrypto.open(
                    payload,
                    roomKey: roomKey,
                    ownerSigningPublicKey: ownerSigningPublicKey
                )
                requiresOwnerResign = false
            } catch {
                guard let predecessorOwnerSigningPublicKey else { throw error }
                displayName = try PrivateWindowNameCrypto.open(
                    payload,
                    roomKey: roomKey,
                    ownerSigningPublicKey: predecessorOwnerSigningPublicKey
                )
                requiresOwnerResign = true
            }
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
                if requiresOwnerResign {
                    // The recovered owner proves continuity by accepting the
                    // predecessor-signed value once, then increments the local
                    // revision so the same plaintext is re-encrypted and
                    // signed with the replacement device key below.
                    _ = try PrivateWindowPresentationStore.save(
                        displayName: displayName,
                        pairing: pairing,
                        validating: lifecycleToken
                    )
                    changed = true
                }
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

        // Build 33 staged UInt32-prefixed signature/AAD transcripts. The
        // relay correctly rejected them, but exact ambiguous retry would keep
        // resending those bytes forever after the UInt16 interoperability fix.
        // Only discard that pending envelope after the authenticated GET and
        // rollback-floor checks above; accepted floor/hash state is preserved.
        try PrivateWindowNameSyncStore.discardLegacyPendingAfterAuthoritativeRead(
            pairing: pairing,
            validating: lifecycleToken
        )

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
                ownerSigningPrivateKey: credential.signingPrivateKey
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

    /// A terminal safety window permits report delivery only. This guard is
    /// shared by foreground, media-disabled and explicit rename paths so none
    /// of them can issue a window-name GET/PUT while report-only authority is
    /// active. A closed boundary performs the same terminal local purge as the
    /// full synchronization path before returning no authority to the caller.
    private func requireWindowNameSynchronizationAllowed(
        authorization: Authorization,
        now: Date = .now
    ) async throws {
        let markerUntil: Date?
        do {
            markerUntil = try MomentShareHandoffStore.reportOnlyHandoffDeadline(
                validating: authorization.lifecycleToken,
                now: now
            )
        } catch {
            guard let recoveredUntil = await recoverReportOnlyBoundary(
                authorization: authorization,
                now: now
            ) else { throw MomentSharingError.notPaired }
            markerUntil = recoveredUntil
        }

        if let markerUntil {
            if MomentSharingProtocol.isReportOnlyWindowClosed(
                until: markerUntil,
                now: now
            ) {
                try await resetLocalPairing(
                    authorization: authorization,
                    reason: .reportOnlyWindowClosed
                )
                throw MomentSharingError.notPaired
            }
            guard await establishReportOnlyBoundary(
                until: markerUntil,
                authorization: authorization,
                now: now
            ) else { throw MomentSharingError.notPaired }
            throw MomentSharingError.reportOnly(until: markerUntil)
        }

        try MomentSharingStateStore.pruneLocalHistory(now: now)
        if let stateUntil = try MomentSharingStateStore.load().reportOnlyUntil {
            if MomentSharingProtocol.isReportOnlyWindowClosed(
                until: stateUntil,
                now: now
            ) {
                try await resetLocalPairing(
                    authorization: authorization,
                    reason: .reportOnlyWindowClosed
                )
                throw MomentSharingError.notPaired
            }
            guard await establishReportOnlyBoundary(
                until: stateUntil,
                authorization: authorization,
                now: now
            ) else { throw MomentSharingError.notPaired }
            throw MomentSharingError.reportOnly(until: stateUntil)
        }
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
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
                Self.logNonterminalRequestRejection(error)
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
                if Self.isNonterminalAuthenticationFailure(error) {
                    // `invalid_authentication` deliberately conflates missing
                    // credentials, malformed headers, and signature failures.
                    // It does not prove revocation, so preserve this exact
                    // encrypted item and retry with bounded backoff.
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
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

    private func sendPawOutbox(
        api: any MomentReactionAPIClientProtocol,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try SharingLifecycleGate.validate(lifecycleToken)
        let candidates = try MomentSharingStateStore.load(
            validating: lifecycleToken
        ).pawOutbox.filter { $0.phase == .pending || $0.phase == .committing }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.clientRequestID.uuidString < $1.clientRequestID.uuidString
            }
        var sentCount = 0
        for item in candidates {
            try Task.checkCancellation()
            try SharingLifecycleGate.validate(lifecycleToken)
            try MomentSharingStateStore.markPawCommitting(
                clientRequestID: item.clientRequestID,
                validating: lifecycleToken
            )
            let result: MomentPawSendResult
            do {
                result = try await api.sendPaw(
                    momentID: item.momentID,
                    clientRequestID: item.clientRequestID,
                    pairingState: pairing,
                    credential: credential
                )
            } catch {
                if Self.requiresLocalRevocationReset(error) { throw error }
                if Self.isPermanentPawRejection(error) {
                    try MomentSharingStateStore.discardRejectedPaw(
                        clientRequestID: item.clientRequestID,
                        validating: lifecycleToken
                    )
                    Self.logNonterminalRequestRejection(error)
                    continue
                }
                throw error
            }
            try SharingLifecycleGate.validate(lifecycleToken)
            try MomentSharingStateStore.markPawSent(
                clientRequestID: item.clientRequestID,
                momentID: result.momentID,
                reactionID: result.reactionID,
                validating: lifecycleToken
            )
            sentCount += 1
        }
        return sentCount
    }

    /// Discard only explicit, resource-specific rejections. Generic rate,
    /// nonce, authentication, conflict, and unknown failures keep the stable
    /// idempotency key because a fresh signed retry can still reconcile them.
    private nonisolated static func isPermanentPawRejection(_ error: Error) -> Bool {
        guard case let MomentSharingError.requestRejected(_, code, _) = error,
              let code
        else { return false }
        switch code {
        case "unsupported_protocol", "invalid_field", "invalid_content_length",
             "body_too_large", "unsupported_media_type", "invalid_json",
             "query_not_allowed", "active_member_required",
             "self_reaction_not_allowed", "moment_not_found",
             "reaction_not_allowed", "reaction_daily_quota_reached":
            return true
        default:
            return false
        }
    }

    private func receivePawChanges(
        api: any MomentReactionAPIClientProtocol,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try SharingLifecycleGate.validate(lifecycleToken)
        var insertedCount = 0
        var pageCount = 0
        while pageCount < 5 {
            pageCount += 1
            let state = try MomentSharingStateStore.load(
                validating: lifecycleToken
            )
            let requestedCursor = state.reactionCursor
            var processedCursor = requestedCursor
            let result = try await api.pawChanges(
                after: requestedCursor,
                pairingState: pairing,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            if result.changes.isEmpty {
                if result.nextCursor != requestedCursor {
                    _ = try MomentSharingStateStore.advanceReactionCursor(
                        expected: requestedCursor,
                        next: result.nextCursor,
                        validating: lifecycleToken
                    )
                }
                break
            }
            for change in result.changes {
                if try MomentSharingStateStore.recordReceivedPaw(
                    reactionID: change.reactionID,
                    momentID: change.momentID,
                    observedAt: .now,
                    validating: lifecycleToken
                ) {
                    insertedCount += 1
                }
                guard try MomentSharingStateStore.advanceReactionCursor(
                    expected: processedCursor,
                    next: change.cursor,
                    validating: lifecycleToken
                ) else { return insertedCount }
                processedCursor = change.cursor
            }
            guard result.changes.count == 100,
                  result.nextCursor != requestedCursor
            else { break }
        }
        return insertedCount
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
                        if change.deliveryState == "acknowledged" {
                            _ = try MomentSharingStateStore
                                .markRecipientDeliveryConfirmed(
                                    serverMomentID: change.momentID,
                                    clientMomentID: change.clientMomentID,
                                    // This is the sender device's local
                                    // observation time. The relay deliberately
                                    // does not expose the recipient's exact
                                    // activity timestamp.
                                    observedAt: .now,
                                    validating: lifecycleToken
                                )
                        }
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
    func runtimeNetworkClientConstructions() -> Int {
        runtimeNetworkClientConstructionCount
    }

    /// Exercises the same process-wide serial queue without touching
    /// pairing, network, Keychain, or photo state.
    func runtimeTestJoinProcessSynchronization(
        operation: @escaping @Sendable () async -> MomentSynchronizationNotice?
    ) async -> MomentSynchronizationNotice? {
        let request = MomentSynchronizationRequest()
        let result = await withTaskCancellationHandler {
            await runMomentProcessSynchronization(request: request) {
                MomentSynchronizationRunResult(
                    notice: await operation(),
                    succeeded: true
                )
            }
        } onCancel: {
            request.cancel()
        }
        latestSynchronizationNotice = result?.notice
        return result?.notice
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
            case let .requestRejected(_, code, _):
                switch code {
                case "moment_runtime_disabled": return "moment-runtime-disabled"
                case "report_result_unknown": return "request-rejected"
                case "report_window_closed": return "request-rejected"
                case "reservation_expired": return "reservation-expired"
                case "reservation_retry_limit_exceeded": return "reservation-retry-limit"
                default: return "request-rejected"
                }
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
        // Destroy the room credential only when the authenticated relay names
        // an authorization-wide terminal state. A resource-specific 410 (for
        // a reservation, report, moment, or presentation name), and especially
        // an undecodable/unknown 410, cannot prove that this pairing ended.
        return status == 410 && code == "sharing_revoked"
    }

    private nonisolated static func localFailureReason(
        for error: Error
    ) -> LocalSharingFailureReason {
        if requiresLocalRevocationReset(error) {
            return .remoteAuthorizationTerminal
        }
        guard let momentError = error as? MomentSharingError else {
            return .runtimeUnavailable
        }
        switch momentError {
        case .stateUnavailable:
            return .stateUnavailable
        case let .requestRejected(status, _, _):
            return status == 410 ? .resourceGone : .requestRejected
        default:
            return .runtimeUnavailable
        }
    }

#if DEBUG
    nonisolated static func runtimeRequiresLocalRevocationReset(
        _ error: Error
    ) -> Bool {
        requiresLocalRevocationReset(error)
    }

    nonisolated static func runtimeLocalFailureReason(_ error: Error) -> String {
        localFailureReason(for: error).rawValue
    }

    nonisolated static func runtimeIsNonterminalAuthenticationFailure(
        _ error: Error
    ) -> Bool {
        isNonterminalAuthenticationFailure(error)
    }
#endif

    private func resetLocalPairing(
        authorization: Authorization,
        reason: PairingResetReason
    ) async throws {
        SharedLog.app.warning(
            "moment-sharing",
            "Local pairing reset started after a terminal sharing boundary",
            metadata: ["sharingFailureReason": reason.rawValue]
        )
        do {
            try await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                expectedState: authorization.state,
                lifecycleToken: authorization.lifecycleToken
            )
            SharedLog.app.info(
                "moment-sharing",
                "Local pairing reset completed after a terminal sharing boundary",
                metadata: ["sharingFailureReason": reason.rawValue]
            )
        } catch {
            SharedLog.app.error(
                "moment-sharing",
                "Local pairing reset failed after a terminal sharing boundary",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .momentSharing,
                    additional: ["sharingFailureReason": reason.rawValue]
                )
            )
            throw error
        }
    }

    private nonisolated static func logSynchronizationDeferred(
        error: Error,
        trigger: String
    ) {
        SharedLog.app.warning(
            "moment-sharing",
            "Moment synchronization deferred without changing pairing credentials",
            metadata: SharedLog.errorMetadata(
                error,
                category: .momentSharing,
                additional: [
                    "sharingFailureReason": localFailureReason(for: error).rawValue,
                    "trigger": String(trigger.prefix(32))
                ]
            )
        )
    }

    private nonisolated static func logNonterminalRequestRejection(_ error: Error) {
        guard let momentError = error as? MomentSharingError,
              case .requestRejected = momentError,
              !requiresLocalRevocationReset(error)
        else { return }
        SharedLog.app.warning(
            "moment-sharing",
            "Relay request was rejected without changing pairing credentials",
            metadata: SharedLog.errorMetadata(
                error,
                category: .momentSharing,
                additional: [
                    "sharingFailureReason": localFailureReason(for: error).rawValue
                ]
            )
        )
    }

    /// Establishes the durable report-only marker/state boundary. If the
    /// cross-store state write cannot finish, the fallback must still commit
    /// the marker and remove all handoff plaintext. If local storage remains
    /// unavailable, stop admissions again and retry later without treating
    /// that I/O failure as proof that relay authorization ended.
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
                SharedLog.app.error(
                    "moment-sharing",
                    "Report-only boundary persistence deferred without changing pairing credentials",
                    metadata: [
                        "sharingFailureReason": LocalSharingFailureReason
                            .reportOnlyBoundaryUnavailable.rawValue
                    ]
                )
                suspendHandoffForLocalFailure(
                    authorization: authorization,
                    reason: .reportOnlyBoundaryUnavailable
                )
                return false
            }
        }
    }

    /// Repairs a marker whose protected payload is unreadable without making
    /// it a permanent retention or reporting blocker. A valid local state
    /// deadline wins. If state was never committed (marker-first crash), the
    /// protected inode's fixed creation/modification anchor supplies a local
    /// maximum window. When neither source is trustworthy, admissions remain
    /// stopped and recovery is retried without deleting the room credential.
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
                try? await resetLocalPairing(
                    authorization: authorization,
                    reason: .reportOnlyWindowClosed
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

        guard let recoveredUntil else {
            SharedLog.app.error(
                "moment-sharing",
                "Report-only boundary recovery deferred without changing pairing credentials",
                metadata: [
                    "sharingFailureReason": LocalSharingFailureReason
                        .reportOnlyBoundaryUnavailable.rawValue
                ]
            )
            suspendHandoffForLocalFailure(
                authorization: authorization,
                reason: .reportOnlyBoundaryUnavailable
            )
            return nil
        }
        guard !MomentSharingProtocol.isReportOnlyWindowClosed(
            until: recoveredUntil,
            now: now
        ) else {
            try? await resetLocalPairing(
                authorization: authorization,
                reason: .reportOnlyWindowClosed
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

    /// Moment state and Share Extension admissions are replaceable local
    /// stores; neither can prove that relay authorization ended. Stop new
    /// plaintext handoffs when possible, preserve the room credential, and let
    /// the next foreground pass retry. A transient cleanup failure is logged
    /// but must never be escalated into deleting the pairing key.
    private func suspendHandoffForLocalFailure(
        authorization: Authorization,
        reason: LocalSharingFailureReason
    ) {
        do {
            try handoffProcessor.revokeAdmissions(
                lifecycleToken: authorization.lifecycleToken
            )
            SharedLog.app.warning(
                "moment-sharing",
                "Share Extension handoff stopped after a local sharing failure",
                metadata: ["sharingFailureReason": reason.rawValue]
            )
        } catch {
            SharedLog.app.error(
                "moment-sharing",
                "Share Extension handoff cleanup deferred without changing pairing credentials",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .momentSharing,
                    additional: [
                        "sharingFailureReason": LocalSharingFailureReason
                            .handoffCleanupUnavailable.rawValue
                    ]
                )
            )
        }
    }

    private func handleStateUnavailable(
        authorization: Authorization
    ) async {
        let reason: LocalSharingFailureReason
        do {
            if try MomentSharingStateStore.isPersistedStateDefinitelyCorrupt(
                validating: authorization.lifecycleToken
            ) {
                reason = .stateCorrupt
            } else {
                reason = .stateUnavailable
            }
        } catch {
            // An unreadable protected file can be transient while the device
            // is locked or storage is unavailable. Preserve evidence and let
            // a later foreground sync retry instead of treating I/O as proof
            // of corruption.
            reason = .stateUnavailable
        }
        SharedLog.app.warning(
            "moment-sharing",
            "Local sharing state unavailable; pairing credentials retained for retry",
            metadata: ["sharingFailureReason": reason.rawValue]
        )
        suspendHandoffForLocalFailure(
            authorization: authorization,
            reason: reason
        )
    }

    private nonisolated static func isExpiredReservation(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        return status == 410 && code == "reservation_expired"
    }

    private nonisolated static func isNonterminalAuthenticationFailure(
        _ error: Error
    ) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else { return false }
        return status == 401 && code == "invalid_authentication"
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
