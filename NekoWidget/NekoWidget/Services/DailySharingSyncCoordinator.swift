import Foundation
import UIKit

/// Host-app synchronization for Phase 2. The Widget still reads only the
/// existing personal cache; received encrypted canonicals are adopted as a
/// verified generation but are not rendered until Phase 3.
actor DailySharingSyncCoordinator {
    private let configuration: SharingAPIConfiguration
    private let api: (any DailySharingAPIClientProtocol)?
    private let canonicalBuilder: CanonicalPreviewBuilder
    private var isSynchronizing = false
    private var needsAnotherPass = false
    private var retryTask: Task<Void, Never>?
    private var retryTaskToken: UUID?
    private var scheduledRetryAt: Date?

    init(
        configuration: SharingAPIConfiguration = .current,
        api: (any DailySharingAPIClientProtocol)? = nil,
        canonicalBuilder: CanonicalPreviewBuilder = CanonicalPreviewBuilder()
    ) {
        self.configuration = configuration
        self.canonicalBuilder = canonicalBuilder
        if let api {
            self.api = api
        } else if configuration.isMediaAvailable {
            self.api = try? URLSessionDailySharingAPIClient(configuration: configuration)
        } else {
            self.api = nil
        }
    }

#if DEBUG
    /// Runtime smoke seam that deliberately invokes the production local-first
    /// promotion and same-pass server fallback implementation. Generated test
    /// ciphertext only; no alternate staging implementation is permitted.
    func runtimeSelfTestPromoteOwnCommittedGeneration(
        _ current: SharingCurrentGeneration,
        outbound: OutboundSharingGeneration,
        state: inout DailySharingState,
        spaceID: String,
        memberID: String,
        roomKey: Data,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        try await promoteOwnCommittedGenerationIfAvailable(
            current,
            outbound: outbound,
            state: &state,
            spaceID: spaceID,
            memberID: memberID,
            roomKey: roomKey,
            credential: credential,
            api: api,
            lease: lease
        )
    }

    func runtimeSelfTestVerifiedInboundGenerationIsIntact(
        _ highWater: InboundSharingHighWater,
        spaceID: String,
        roomKey: Data,
        lease: DailySharingStateStore.SyncLease
    ) throws -> Bool {
        try verifiedInboundGenerationIsIntact(
            highWater,
            spaceID: spaceID,
            roomKey: roomKey,
            lease: lease
        )
    }

    /// Runs the production heartbeat loop against an intentionally shortened
    /// lease. A competing acquisition after the synthetic expiry must still
    /// observe the renewed owner; this keeps the runtime gate well below 90s.
    func runtimeSelfTestLeaseHeartbeat(
        spaceID: String,
        memberID: String,
        lifecycleToken: SharingLifecycleGate.Token,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        try await whileLeaseHeld(
            lease,
            // Preserve the production 1:3 heartbeat-to-expiry ratio while
            // scaling the generated test from 30s/90s to 1s/3s.
            heartbeatInterval: .seconds(1)
        ) {
            try DailySharingStateStore.runtimeSelfTestShortenSyncLease(
                lease,
                // ISO-8601 state encoding is whole-second on supported OSes;
                // keep enough headroom for that rounding and scheduler jitter.
                duration: 3
            )
            try await Task.sleep(for: .seconds(4))
            let acquisition = try DailySharingStateStore.acquireSyncLease(
                spaceID: spaceID,
                memberID: memberID,
                lifecycleToken: lifecycleToken
            )
            switch acquisition {
            case .busy:
                break
            case .acquired(let unexpected):
                unexpected.release()
                throw DailySharingError.stateChanged
            }
        }
    }

    /// Drives the production mutation-deadline scheduler, authenticated GET
    /// reconciliation, and resulting terminal/reprepare transition. The
    /// caller inspects the committed state; the independent inbound schedule
    /// must remain byte-for-byte unchanged.
    func runtimeSelfTestDriveOutboundDeadlineReconciliation(
        expectedReason: DailySharingOutboundReconcileReason,
        state: inout DailySharingState,
        spaceID: String,
        memberID: String,
        roomKey: Data,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        let inboundRetry = state.inboundRetry
        try scheduleOutboundRetry(
            error: DailySharingError.retryableServer(retryAfterSeconds: nil),
            intent: .mutation,
            state: &state,
            lease: lease
        )
        guard state.outboundRetryIntent == .reconcileOnly,
              state.outboundReconcileReason == expectedReason
        else { throw DailySharingError.stateUnavailable }
        // The runtime calls reconciliation directly; do not let the in-memory
        // timer re-enter the actor while its mock generation request awaits.
        retryTask?.cancel()
        retryTask = nil
        retryTaskToken = nil
        scheduledRetryAt = nil
        let disposition = try await reconcileOutbound(
            state: &state,
            spaceID: spaceID,
            memberID: memberID,
            roomKey: roomKey,
            credential: credential,
            api: api,
            lease: lease
        )
        try applyOutboundReconciliation(
            reason: expectedReason,
            disposition: disposition,
            state: &state,
            lease: lease
        )
        retryTask?.cancel()
        retryTask = nil
        retryTaskToken = nil
        scheduledRetryAt = nil
        needsAnotherPass = false
        guard state.inboundRetry == inboundRetry else {
            throw DailySharingError.stateUnavailable
        }
    }

    /// Exercises the same bounded-loop continuation persistence used by
    /// `synchronize`. Existing Retry-After/deadline reconciliation evidence
    /// must remain exact even when several handled passes request continuation.
    func runtimeSelfTestPersistContinuationAfterPassLimit(
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        try applyContinuationAfterPassLimit(state: &state, lease: lease)
        retryTask?.cancel()
        retryTask = nil
        retryTaskToken = nil
        scheduledRetryAt = nil
    }

    /// Drives the production pre-await reservation marker and response
    /// transition with an injected clock for the crash/day-boundary gate.
    func runtimeSelfTestReserveFrozenGeneration(
        state: inout DailySharingState,
        boundaryMinuteUTC: Int,
        now: Date,
        memberID: String,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws -> Bool {
        try await reserveFrozenGeneration(
            state: &state,
            boundaryMinuteUTC: boundaryMinuteUTC,
            currentLocalDayKey: Self.dayKey(
                now: now,
                boundaryMinuteUTC: boundaryMinuteUTC
            ),
            now: now,
            memberID: memberID,
            credential: credential,
            api: api,
            lease: lease
        )
    }

    func runtimeSelfTestDiscardStaleUnsentFrozen(
        state: inout DailySharingState,
        currentLocalDayKey: Int,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        try discardStaleUnsentFrozenIfNeeded(
            state: &state,
            currentLocalDayKey: currentLocalDayKey,
            lease: lease
        )
    }

    static func runtimeSelfTestHighWaterMatchesSummary(
        _ highWater: InboundSharingHighWater,
        sourceID: String,
        publisherMemberID: String,
        summary: SharingSourceSummary.Current
    ) -> Bool {
        highWaterMatchesSummary(
            highWater,
            sourceID: sourceID,
            publisherMemberID: publisherMemberID,
            summary: summary
        )
    }

    /// Returns true only for a strictly newer authenticated descriptor. An
    /// exact descriptor returns false; rollback and same-revision equivocation
    /// throw through the production comparator.
    static func runtimeSelfTestCurrentReplacementIsStrictlyNewer(
        original: SharingCurrentGeneration,
        replacement: SharingCurrentGeneration
    ) throws -> Bool {
        try currentReplacementRelation(from: original, to: replacement) == .strictlyNewer
    }
#endif

    func synchronize(trigger: String) async {
        guard configuration.isMediaAvailable, api != nil else { return }
        if isSynchronizing {
            needsAnotherPass = true
            return
        }
        isSynchronizing = true
        defer { isSynchronizing = false }
        var passCount = 0
        repeat {
            passCount += 1
            needsAnotherPass = false
            await performOnePass(trigger: trigger)
        } while needsAnotherPass && passCount < 3
        if needsAnotherPass {
            await persistContinuationAfterPassLimit()
            needsAnotherPass = false
        }
    }

    /// A malformed/churning server must not turn handled progress into an
    /// unbounded foreground loop. Preserve a bounded durable wake so normal
    /// convergence can continue without waiting for another scene transition.
    private func persistContinuationAfterPassLimit() async {
        do {
            let bootstrap = try PairingInstallationGuard.bootstrap()
            let pairing = try bootstrap.state.validated()
            guard pairing.phase == .paired,
                  let spaceID = pairing.spaceID,
                  let memberID = pairing.memberID
            else { return }
            let acquisition = try DailySharingStateStore.acquireSyncLease(
                spaceID: spaceID,
                memberID: memberID,
                lifecycleToken: bootstrap.lifecycleToken
            )
            guard case .acquired(let lease) = acquisition else {
                if case .busy(let retryAt) = acquisition {
                    scheduleBusyLeaseRetry(at: retryAt)
                }
                return
            }
            defer { lease.release() }
            var state = try DailySharingStateStore.load(
                spaceID: spaceID,
                memberID: memberID,
                lease: lease
            )
            try applyContinuationAfterPassLimit(state: &state, lease: lease)
        } catch {
            SharedLog.app.warning(
                "sharing-media",
                "Sharing continuation could not be persisted after the pass limit",
                metadata: SharedLog.errorMetadata(error, category: .sharingMedia)
            )
        }
    }

    private func applyContinuationAfterPassLimit(
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        // A persisted retry is already the authoritative continuation. Never
        // shorten Retry-After, erase reconcileOnly, or rewrite its reason just
        // because three handled foreground passes completed quickly.
        if state.outboundRetry != nil {
            scheduleNextRetry(for: state)
            return
        }
        // `needsAnotherPass` can also be raised by inbound activation/cleanup.
        // Do not manufacture an outbound mutation slot when no outbound work
        // exists; preserve and schedule the independent inbound slot instead.
        guard state.outbound != nil else {
            scheduleNextRetry(for: state)
            return
        }
        state.outboundRetry = DailySharingRetrySchedule(
            attemptCount: 1,
            nextRetryAt: Date().addingTimeInterval(30)
        )
        state.outboundRetryIntent = .mutation
        state.outboundReconcileReason = nil
        state = try save(state, lease: lease)
        scheduleNextRetry(for: state)
    }

    private func performOnePass(trigger: String) async {
        var cleanupExpectation: (
            state: PairingState,
            token: SharingLifecycleGate.Token
        )?
        do {
            guard let api else { return }
            let bootstrap = try PairingInstallationGuard.bootstrap()
            let pairing = try bootstrap.state.validated()
            cleanupExpectation = (pairing, bootstrap.lifecycleToken)
            guard pairing.phase == .paired,
                  pairing.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
                  pairing.mediaSharingConsentAcceptedAt != nil,
                  let account = pairing.credentialAccount,
                  let spaceID = pairing.spaceID,
                  let memberID = pairing.memberID
            else { return }
            let acquisition = try DailySharingStateStore.acquireSyncLease(
                spaceID: spaceID,
                memberID: memberID,
                lifecycleToken: bootstrap.lifecycleToken
            )
            guard case .acquired(let lease) = acquisition else {
                // Preserve both persisted retry domains and independently wake
                // after a live/crashed process's bounded record expires.
                if case .busy(let retryAt) = acquisition {
                    scheduleBusyLeaseRetry(at: retryAt)
                }
                return
            }
            defer { lease.release() }
            let credential = try PairingKeychainStore.load(
                account: account,
                installationMarker: pairing.installationMarker
            )
            guard let roomKey = credential.roomKey, roomKey.count == 32 else {
                throw PairingError.malformedCredential
            }
            var state = try DailySharingStateStore.load(
                spaceID: spaceID,
                memberID: memberID,
                lease: lease
            )
            if state.storageRevision == 0 {
                state = try save(state, lease: lease)
            }
            try lease.renew()
            state = try DailySharingStateStore.activateDueInbound(
                expectedState: state,
                lease: lease,
                now: .now
            )
            let passStartedAt = Date()
            scheduleNextRetry(for: state)
            let outboundIsDue = state.outboundRetry.map {
                $0.nextRetryAt <= passStartedAt
            } ?? true
            let inboundIsDue = state.inboundRetry.map {
                $0.nextRetryAt <= passStartedAt
            } ?? true

            if outboundIsDue, state.outboundRetryIntent == .reconcileOnly {
                do {
                    let reconcileReason = state.outboundReconcileReason
                        ?? .uncertainOutcome
                    let disposition: ReconcileDisposition
                    if state.outbound?.generationID != nil {
                        disposition = try await reconcileOutbound(
                            state: &state,
                            spaceID: spaceID,
                            memberID: memberID,
                            roomKey: roomKey,
                            credential: credential,
                            api: api,
                            lease: lease
                        )
                    } else {
                        disposition = .finished
                    }
                    try applyOutboundReconciliation(
                        reason: reconcileReason,
                        disposition: disposition,
                        state: &state,
                        lease: lease
                    )
                } catch {
                    if Self.isRemoteRevocation(error) {
                        throw error
                    } else if Self.isRetryable(error) {
                        try scheduleOutboundRetry(
                            error: error,
                            intent: .reconcileOnly,
                            state: &state,
                            lease: lease
                        )
                    } else {
                        clearOutboundRetry(in: &state)
                        state = try save(state, lease: lease)
                        SharedLog.app.warning(
                            "sharing-media",
                            "Outbound reconciliation stopped after a non-retryable response",
                            metadata: SharedLog.errorMetadata(
                                error,
                                category: .sharingMedia
                            )
                        )
                    }
                }
            } else if outboundIsDue {
                do {
                    try await publishIfNeeded(
                        state: &state,
                        pairing: pairing,
                        credential: credential,
                        api: api,
                        lease: lease
                    )
                } catch {
                    SharedLog.app.warning(
                        "sharing-media",
                        "Daily publish retained the previous verified generation",
                        metadata: SharedLog.errorMetadata(
                            error,
                            category: .sharingMedia,
                            additional: ["trigger": trigger]
                        )
                    )
                    if Self.isRemoteRevocation(error) {
                        throw error
                    } else if let dailyError = error as? DailySharingError,
                       dailyError == .waitingForReconciliation {
                        // The exact GET-only wake was persisted before throw.
                    } else if let reason = Self.outboundReconcileReason(error) {
                        try persistReconciliationWake(
                            at: .now,
                            reason: reason,
                            useBackoff: true,
                            state: &state,
                            lease: lease
                        )
                    } else if Self.isRetryable(error) {
                        try scheduleOutboundRetry(
                            error: error,
                            intent: .mutation,
                            state: &state,
                            lease: lease
                        )
                    } else if state.outboundRetry != nil {
                        clearOutboundRetry(in: &state)
                        state = try save(state, lease: lease)
                    }
                }
                // A successful due attempt consumes only the outbound slot.
                if let retry = state.outboundRetry,
                   state.outboundRetryIntent == .mutation,
                   retry.nextRetryAt <= passStartedAt {
                    clearOutboundRetry(in: &state)
                    state = try save(state, lease: lease)
                }
            }

            // Reload after a CAS race or an outbound save before starting the
            // independent inbound path. No network await holds the file lock.
            state = try DailySharingStateStore.load(
                spaceID: spaceID,
                memberID: memberID,
                lease: lease
            )
            if inboundIsDue {
                do {
                    try await receiveCurrentSources(
                        state: &state,
                        pairing: pairing,
                        credential: credential,
                        api: api,
                        lease: lease
                    )
                    if state.inboundRetry != nil {
                        clearInboundRetry(in: &state)
                        state = try save(state, lease: lease)
                    }
                } catch {
                    SharedLog.app.warning(
                        "sharing-media",
                        "Inbound sync retained the previous verified generation",
                        metadata: SharedLog.errorMetadata(
                            error,
                            category: .sharingMedia,
                            additional: ["trigger": trigger]
                        )
                    )
                    if Self.isRemoteRevocation(error) {
                        throw error
                    } else if Self.isRetryable(error) {
                        try scheduleInboundRetry(
                            error: error,
                            state: &state,
                            lease: lease
                        )
                    } else if state.inboundRetry != nil {
                        clearInboundRetry(in: &state)
                        state = try save(state, lease: lease)
                    }
                }
            }
            scheduleNextRetry(for: state)
        } catch {
            if Self.isRemoteRevocation(error) {
                do {
                    // The lease's defer runs when the `do` scope exits before
                    // this catch executes. Purging after release prevents a
                    // Widget/app writer from retaining a stale room key/cache.
                    guard let cleanupExpectation else { return }
                    try await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                        expectedState: cleanupExpectation.state,
                        lifecycleToken: cleanupExpectation.token
                    )
                } catch {
                    SharedLog.app.error(
                        "sharing-media",
                        "Remote revocation was confirmed but local purge failed",
                        metadata: SharedLog.errorMetadata(
                            error,
                            category: .sharingMedia
                        )
                    )
                }
                return
            }
            SharedLog.app.warning(
                "sharing-media",
                "Daily sharing synchronization skipped",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .sharingMedia,
                    additional: ["trigger": trigger]
                )
            )
        }
    }

    /// Persists the "request may have reached the server" evidence before the
    /// await. A frozen set without this marker is safe to discard at a local
    /// day boundary; a marked set must keep its exact idempotency request until
    /// the authenticated response or a terminal server conflict is observed.
    private func reserveFrozenGeneration(
        state: inout DailySharingState,
        boundaryMinuteUTC boundary: Int,
        currentLocalDayKey today: Int,
        now: Date,
        memberID: String,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws -> Bool {
        guard var outbound = state.outbound,
              outbound.phase == .frozen,
              outbound.generationID == nil,
              let requestID = UUID(uuidString: outbound.reserveClientRequestID)
        else { throw DailySharingError.stateUnavailable }

        if outbound.reserveAttemptedAt == nil {
            outbound.reserveAttemptedAt = now
            outbound.reserveAttemptBoundaryMinuteUTC = boundary
            state.outbound = outbound
            // Commit before the network await. A process kill after the server
            // reserve now reloads this exact request ID, media set, and boundary
            // evidence instead of treating it as an unsent stale freeze.
            state = try save(state, lease: lease)
        }
        guard let attemptedAt = outbound.reserveAttemptedAt,
              outbound.reserveAttemptBoundaryMinuteUTC == boundary,
              Self.dayKey(now: attemptedAt, boundaryMinuteUTC: boundary)
                == outbound.localDayKey
        else { throw DailySharingError.stateUnavailable }

        let result: SharingReserveResult
        do {
            result = try await whileLeaseHeld(lease) {
                try await api.reserveGeneration(
                    mediaIDs: outbound.media.map(\.frozen.mediaID),
                    clientRequestID: requestID,
                    memberID: memberID,
                    credential: credential
                )
            }
        } catch let error as PairingError {
            if Self.isPreviousGenerationCleanupPending(error) {
                // The server's deletion worker owns this bounded wait. Retain
                // the marker and exact idempotency payload.
                throw DailySharingError.retryableServer(retryAfterSeconds: 10 * 60)
            }
            guard case let .requestRejected(status, code, _) = error,
                  status == 409,
                  code == "daily_generation_exists"
            else { throw error }

            state.outbound = nil
            let nearBoundary = Self.secondsSinceBoundary(
                now: now,
                boundaryMinuteUTC: boundary
            ) <= 360 || Self.secondsUntilNextBoundary(
                now: now,
                boundaryMinuteUTC: boundary
            ) <= 360
            if nearBoundary {
                // The server/device day may still differ. Refreeze only after
                // the bounded skew window and do not terminalize either day.
                state.outboundRetry = DailySharingRetrySchedule(
                    attemptCount: 1,
                    nextRetryAt: Self.clockSkewRetryDate(
                        now: now,
                        boundaryMinuteUTC: boundary
                    )
                )
                state.outboundRetryIntent = .mutation
                state.outboundReconcileReason = nil
            } else {
                // A marked request from an older local day has reached a
                // server-confirmed terminal conflict. Complete only that old
                // trigger window; never skip today's fresh Widget snapshot.
                let completedDay = outbound.localDayKey == today
                    ? today : outbound.localDayKey
                state.lastCompletedLocalDayKey = max(
                    state.lastCompletedLocalDayKey ?? completedDay,
                    completedDay
                )
                clearOutboundRetry(in: &state)
                if completedDay != today { needsAnotherPass = true }
            }
            state = try save(state, lease: lease)
            scheduleNextRetry(for: state)
            return false
        }

        guard result.publisherMemberID == memberID,
              abs(result.shareDayKey - outbound.localDayKey) <= 1
        else { throw PairingError.invalidServerResponse }
        if result.shareDayKey < outbound.localDayKey {
            guard result.shareDayKey == outbound.localDayKey - 1,
                  Self.secondsSinceBoundary(
                    now: attemptedAt,
                    boundaryMinuteUTC: boundary
                  ) <= 360
            else { throw PairingError.invalidServerResponse }
            // The request was durably initiated just after the client crossed
            // its boundary while the server still owned the preceding day.
            state.outbound = nil
            state.outboundRetry = DailySharingRetrySchedule(
                attemptCount: 1,
                nextRetryAt: Self.clockSkewRetryDate(
                    now: now,
                    boundaryMinuteUTC: boundary
                )
            )
            state.outboundRetryIntent = .mutation
            state.outboundReconcileReason = nil
            state = try save(state, lease: lease)
            scheduleNextRetry(for: state)
            return false
        }
        if result.shareDayKey > outbound.localDayKey {
            guard result.shareDayKey == outbound.localDayKey + 1,
                  Self.secondsUntilNextBoundary(
                    now: attemptedAt,
                    boundaryMinuteUTC: boundary
                  ) <= 360
            else { throw PairingError.invalidServerResponse }
            // Bind the relabel to the persisted pre-await boundary evidence,
            // not the response time. An idempotent response recovered hours
            // later therefore remains valid without widening the skew window.
            outbound.localDayKey = result.shareDayKey
        }
        outbound.reserveAttemptedAt = nil
        outbound.reserveAttemptBoundaryMinuteUTC = nil
        outbound.sourceID = result.sourceID
        outbound.generationID = result.generationID
        outbound.serverShareDayKey = result.shareDayKey
        outbound.draftExpiresAt = result.expiresAt
        outbound.descriptorClientRequestID = UUID().uuidString.lowercased()
        outbound.phase = .reserved
        state.ownSourceID = result.sourceID
        state.outbound = outbound
        state = try save(state, lease: lease)
        return true
    }

    private func discardStaleUnsentFrozenIfNeeded(
        state: inout DailySharingState,
        currentLocalDayKey today: Int,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        guard let frozen = state.outbound,
              frozen.generationID == nil,
              frozen.reserveAttemptedAt == nil,
              frozen.localDayKey != today
        else { return }
        // This exact frozen set was never sent, so it is safe to discard and
        // rebuild from the active Widget manifest. A marked set is retained
        // across the boundary because its server outcome is uncertain.
        state.outbound = nil
        state = try save(state, lease: lease)
    }

    private func publishIfNeeded(
        state: inout DailySharingState,
        pairing: PairingState,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        guard let boundary = pairing.dailyBoundaryMinuteUTC,
              let roomKey = credential.roomKey,
              let memberID = pairing.memberID,
              let spaceID = pairing.spaceID
        else { throw PairingError.stateUnavailable }
        var today = Self.dayKey(now: .now, boundaryMinuteUTC: boundary)

        if state.outbound?.generationID != nil {
            let disposition = try await reconcileOutbound(
                state: &state,
                spaceID: spaceID,
                memberID: memberID,
                roomKey: roomKey,
                credential: credential,
                api: api,
                lease: lease
            )
            if disposition == .finished {
                // Reconciliation can cross the daily boundary. Recompute the
                // gate before deciding whether this foreground pass is done.
                today = Self.dayKey(now: .now, boundaryMinuteUTC: boundary)
                if state.lastCompletedLocalDayKey == today
                    || state.lastPublishedDayKey == today {
                    return
                }
            }
        }
        try discardStaleUnsentFrozenIfNeeded(
            state: &state,
            currentLocalDayKey: today,
            lease: lease
        )
        try deferMutationsNearDeadlineIfNeeded(state: &state, lease: lease)

        if state.outbound == nil {
            guard state.lastCompletedLocalDayKey != today,
                  state.lastPublishedDayKey != today
            else { return }
            guard let manifestURL = SharedContainer.widgetManifestURL,
                  FileManager.default.fileExists(atPath: manifestURL.path)
            else { throw DailySharingError.invalidLocalManifest }
            let manifest = try AtomicJSON.read(WidgetManifest.self, from: manifestURL)
            state.outbound = try DailyManifestFreezer.freeze(manifest, localDayKey: today, now: .now)
            state = try save(state, lease: lease)
        }

        guard var outbound = state.outbound else { return }
        if outbound.phase == .frozen {
            let reserved = try await reserveFrozenGeneration(
                state: &state,
                boundaryMinuteUTC: boundary,
                currentLocalDayKey: today,
                now: .now,
                memberID: memberID,
                credential: credential,
                api: api,
                lease: lease
            )
            guard reserved else { return }
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .reserved {
            var repairedLocalReservation = false
            for index in outbound.media.indices {
                let item = outbound.media[index]
                guard let filename = item.ciphertextFilename,
                      let expectedSize = item.ciphertextSize,
                      let expectedHash = item.ciphertextSHA256
                else { continue }
                do {
                    let data = try DailySharingStateStore.readOutboundCiphertext(
                        filename: filename,
                        maximumBytes: DailySharingProtocol.maximumMediaCiphertextBytes,
                        lease: lease
                    )
                    guard data.count == expectedSize,
                          PairingCrypto.sha256(data).base64URLEncodedString() == expectedHash
                    else { throw DailySharingError.stateUnavailable }
                } catch let error as DailySharingError where error == .stateUnavailable {
                    // Descriptors have not been frozen, so no server-visible
                    // ciphertext identity exists yet. Rebuild just this local
                    // canonical with a fresh nonce and retain the generation.
                    try? DailySharingStateStore.removeOutboundCiphertext(
                        filename: filename,
                        lease: lease
                    )
                    outbound.media[index].binding = nil
                    outbound.media[index].canonicalJPEGPlaintextSHA256 = nil
                    outbound.media[index].ciphertextFilename = nil
                    outbound.media[index].ciphertextSize = nil
                    outbound.media[index].ciphertextSHA256 = nil
                    outbound.media[index].uploadVerified = false
                    repairedLocalReservation = true
                }
            }
            if repairedLocalReservation {
                state.outbound = outbound
                state = try save(state, lease: lease)
            }
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .reserved,
           outbound.media.contains(where: { $0.ciphertextFilename == nil }) {
            guard let sourceID = outbound.sourceID,
                  let generationID = outbound.generationID,
                  let shareDayKey = outbound.serverShareDayKey
            else { throw DailySharingError.stateUnavailable }
            for index in outbound.media.indices where outbound.media[index].ciphertextFilename == nil {
                try Task.checkCancellation()
                let frozen = outbound.media[index].frozen
                let preview = try await whileLeaseHeld(lease) {
                    try await canonicalBuilder.build(
                        CanonicalPreviewRequest(
                            localIdentifier: frozen.localIdentifier,
                            sourceModificationDate: frozen.sourceModificationDate,
                            sourcePixelSize: frozen.sourcePixelSize,
                            renderPlans: frozen.renderPlans
                        )
                    )
                }
                let bindingHash = try preview.binding.bindingHash()
                let aad = try DailySharingCrypto.mediaAAD(
                    spaceID: spaceID,
                    sourceID: sourceID,
                    publisherMemberID: memberID,
                    generationID: generationID,
                    shareDayKey: shareDayKey,
                    mediaID: frozen.mediaID,
                    mediaBindingHash: bindingHash
                )
                let ciphertext = try DailySharingCrypto.sealMedia(
                    preview.jpeg,
                    roomKey: roomKey,
                    aad: aad
                )
                let ciphertextHash = PairingCrypto.sha256(ciphertext).base64URLEncodedString()
                // Random AEAD output never shares a filename with a competing
                // process. Only the CAS winner publishes its filename; a loser
                // removes exactly its own unreferenced object.
                let filename = "\(generationID)-\(frozen.mediaID)-\(ciphertextHash).enc"
                try lease.renew()
                try DailySharingStateStore.writeOutboundCiphertext(
                    ciphertext,
                    filename: filename,
                    lease: lease
                )
                outbound.media[index].binding = preview.binding
                outbound.media[index].canonicalJPEGPlaintextSHA256 = preview.plaintextSHA256
                    .base64URLEncodedString()
                outbound.media[index].ciphertextFilename = filename
                outbound.media[index].ciphertextSize = ciphertext.count
                outbound.media[index].ciphertextSHA256 = ciphertextHash
                state.outbound = outbound
                do {
                    state = try save(state, lease: lease)
                } catch {
                    try? DailySharingStateStore.removeOutboundCiphertext(
                        filename: filename,
                        lease: lease
                    )
                    throw error
                }
                outbound = try requireOutbound(state)
            }
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .reserved {
            guard let generationID = outbound.generationID,
                  let requestID = outbound.descriptorClientRequestID.flatMap(UUID.init(uuidString:))
            else { throw DailySharingError.stateUnavailable }
            try await whileLeaseHeld(lease) {
                try await api.freezeDescriptors(
                    generationID: generationID,
                    media: outbound.media,
                    clientRequestID: requestID,
                    memberID: memberID,
                    credential: credential
                )
            }
            outbound.phase = .descriptorsFrozen
            state.outbound = outbound
            state = try save(state, lease: lease)
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .descriptorsFrozen {
            guard let generationID = outbound.generationID else {
                throw DailySharingError.stateUnavailable
            }
            for index in outbound.media.indices where !outbound.media[index].uploadVerified {
                let item = outbound.media[index]
                guard let filename = item.ciphertextFilename,
                      let size = item.ciphertextSize,
                      let hash = item.ciphertextSHA256
                else { throw DailySharingError.stateUnavailable }
                let ciphertext: Data
                do {
                    ciphertext = try DailySharingStateStore.readOutboundCiphertext(
                        filename: filename,
                        maximumBytes: DailySharingProtocol.maximumMediaCiphertextBytes,
                        lease: lease
                    )
                    guard ciphertext.count == size,
                          PairingCrypto.sha256(ciphertext).base64URLEncodedString() == hash
                    else { throw DailySharingError.stateUnavailable }
                } catch let error as DailySharingError where error == .stateUnavailable {
                    // The server has frozen this exact hash. Re-encryption would
                    // create a different object and violate immutable retry, so
                    // abandon only this unpublished day and keep old current.
                    let localDay = outbound.localDayKey
                    state.lastCompletedLocalDayKey = localDay
                    state.outbound = nil
                    clearOutboundRetry(in: &state)
                    state = try save(state, lease: lease)
                    try? DailySharingStateStore.removeOutboundCiphertexts(
                        for: generationID,
                        lease: lease
                    )
                    return
                }
                try await whileLeaseHeld(lease) {
                    try await api.uploadMedia(
                        generationID: generationID,
                        mediaID: item.frozen.mediaID,
                        ciphertext: ciphertext,
                        expectedSHA256: hash,
                        memberID: memberID,
                        credential: credential
                    )
                }
                outbound.media[index].uploadVerified = true
                state.outbound = outbound
                state = try save(state, lease: lease)
                outbound = try requireOutbound(state)
            }
            outbound.phase = .mediaUploaded
            state.outbound = outbound
            state = try save(state, lease: lease)
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .mediaUploaded, outbound.prepare == nil {
            if outbound.pendingPrepareClientRequestID == nil {
                outbound.pendingPrepareClientRequestID = UUID().uuidString.lowercased()
                state.outbound = outbound
                state = try save(state, lease: lease)
                outbound = try requireOutbound(state)
            }
            guard let generationID = outbound.generationID,
                  let requestID = outbound.pendingPrepareClientRequestID.flatMap(UUID.init(uuidString:))
            else { throw DailySharingError.stateUnavailable }
            let result = try await whileLeaseHeld(lease) {
                try await api.prepare(
                    generationID: generationID,
                    clientRequestID: requestID,
                    memberID: memberID,
                    credential: credential
                )
            }
            outbound.prepare = PreparedSharingAttempt(
                clientRequestID: requestID.uuidString.lowercased(),
                attemptID: result.attemptID,
                attemptRevision: result.attemptRevision,
                reservedRevision: result.reservedRevision,
                rotationAnchorUTC: result.rotationAnchorUTC,
                prepareExpiresAt: result.prepareExpiresAt
            )
            outbound.pendingPrepareClientRequestID = nil
            outbound.phase = .prepared
            state.outbound = outbound
            state = try save(state, lease: lease)
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .prepared,
           outbound.prepare?.manifestCiphertextFilename == nil {
            guard let generationID = outbound.generationID,
                  let sourceID = outbound.sourceID,
                  let shareDayKey = outbound.serverShareDayKey,
                  var prepare = outbound.prepare
            else { throw DailySharingError.stateUnavailable }
            let manifest = try sharedManifest(from: outbound)
            let aad = try DailySharingCrypto.manifestAAD(
                spaceID: spaceID,
                sourceID: sourceID,
                publisherMemberID: memberID,
                generationID: generationID,
                shareDayKey: shareDayKey,
                prepareAttemptID: prepare.attemptID,
                prepareAttemptRevision: prepare.attemptRevision,
                reservedRevision: prepare.reservedRevision,
                rotationAnchorUTC: prepare.rotationAnchorUTC,
                itemCount: outbound.media.count
            )
            // A new prepare attempt always reaches this branch with no stored
            // ciphertext, producing a fresh nonce. Retries of the same attempt
            // read the exact bytes persisted below.
            let ciphertext = try DailySharingCrypto.sealManifest(
                try manifest.encoded(),
                roomKey: roomKey,
                aad: aad
            )
            let ciphertextHash = PairingCrypto.sha256(ciphertext).base64URLEncodedString()
            let filename = "\(generationID)-\(prepare.attemptID)-\(ciphertextHash)-manifest.enc"
            try lease.renew()
            try DailySharingStateStore.writeOutboundCiphertext(
                ciphertext,
                filename: filename,
                lease: lease
            )
            prepare.manifestCiphertextFilename = filename
            prepare.manifestCiphertextSize = ciphertext.count
            prepare.manifestCiphertextSHA256 = ciphertextHash
            prepare.commitClientRequestID = UUID().uuidString.lowercased()
            outbound.prepare = prepare
            state.outbound = outbound
            do {
                state = try save(state, lease: lease)
            } catch {
                try? DailySharingStateStore.removeOutboundCiphertext(
                    filename: filename,
                    lease: lease
                )
                throw error
            }
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .prepared {
            guard let generationID = outbound.generationID,
                  let prepare = outbound.prepare,
                  let filename = prepare.manifestCiphertextFilename,
                  let size = prepare.manifestCiphertextSize,
                  let hash = prepare.manifestCiphertextSHA256
            else { throw DailySharingError.stateUnavailable }
            let ciphertext: Data
            do {
                ciphertext = try DailySharingStateStore.readOutboundCiphertext(
                    filename: filename,
                    maximumBytes: DailySharingProtocol.maximumManifestCiphertextBytes,
                    lease: lease
                )
                guard ciphertext.count == size,
                      PairingCrypto.sha256(ciphertext).base64URLEncodedString() == hash
                else { throw DailySharingError.stateUnavailable }
            } catch let error as DailySharingError where error == .stateUnavailable {
                // The prepare binds this exact random nonce/hash. Until the
                // attempt expires we may neither re-encrypt nor assume upload
                // success; reconcile at expiry, then either observe the server
                // object or create a fresh prepare/manifest safely.
                try persistReconciliationWake(
                    at: Date(timeIntervalSince1970: TimeInterval(prepare.prepareExpiresAt + 1)),
                    reason: .prepareDeadline,
                    state: &state,
                    lease: lease
                )
                throw DailySharingError.waitingForReconciliation
            }
            do {
                try await whileLeaseHeld(lease) {
                    try await api.uploadManifest(
                        generationID: generationID,
                        attemptID: prepare.attemptID,
                        ciphertext: ciphertext,
                        expectedSHA256: hash,
                        memberID: memberID,
                        credential: credential
                    )
                }
            } catch let error as PairingError where Self.isExpiredPrepare(error) {
                outbound.phase = .mediaUploaded
                outbound.prepare = nil
                outbound.pendingPrepareClientRequestID = UUID().uuidString.lowercased()
                state.outbound = outbound
                state = try save(state, lease: lease)
                try? DailySharingStateStore.removeOutboundCiphertext(
                    filename: filename,
                    lease: lease
                )
                needsAnotherPass = true
                return
            }
            outbound.phase = .manifestUploaded
            state.outbound = outbound
            state = try save(state, lease: lease)
        }

        outbound = try requireOutbound(state)
        if outbound.phase == .manifestUploaded {
            outbound.phase = .committing
            state.outbound = outbound
            state = try save(state, lease: lease)
            outbound = try requireOutbound(state)
        }
        if outbound.phase == .committing {
            guard let generationID = outbound.generationID,
                  let sourceID = outbound.sourceID,
                  let shareDayKey = outbound.serverShareDayKey,
                  let prepare = outbound.prepare
            else { throw DailySharingError.stateUnavailable }
            do {
                let result = try await whileLeaseHeld(lease) {
                    try await api.commit(
                        generationID: generationID,
                        expectedSourceID: sourceID,
                        expectedShareDayKey: shareDayKey,
                        prepare: prepare,
                        memberID: memberID,
                        credential: credential
                    )
                }
                let committedCurrent = try currentGeneration(
                    from: outbound,
                    publisherMemberID: memberID,
                    sourceID: result.sourceID,
                    generationID: result.generationID,
                    shareDayKey: result.shareDayKey,
                    revision: result.revision,
                    attemptID: result.attemptID,
                    attemptRevision: result.attemptRevision,
                    reservedRevision: result.reservedRevision,
                    rotationAnchorUTC: result.rotationAnchorUTC
                )
                try await promoteOwnCommittedGenerationIfAvailable(
                    committedCurrent,
                    outbound: outbound,
                    state: &state,
                    spaceID: spaceID,
                    memberID: memberID,
                    roomKey: roomKey,
                    credential: credential,
                    api: api,
                    lease: lease
                )
                state.ownSourceID = result.sourceID
                state.lastCompletedLocalDayKey = outbound.localDayKey
                state.lastPublishedDayKey = result.shareDayKey
                state.lastPublishedRevision = result.revision
                state.outbound = nil
                state.lastSyncAt = .now
                state = try save(state, lease: lease)
                try? DailySharingStateStore.removeOutboundCiphertexts(
                    for: generationID,
                    lease: lease
                )
                let completionDay = Self.dayKey(
                    now: .now,
                    boundaryMinuteUTC: boundary
                )
                if outbound.localDayKey < completionDay {
                    needsAnotherPass = true
                }
            } catch let error as PairingError where Self.isExpiredPrepare(error) {
                // Server-confirmed expiry is the only condition that permits a
                // fresh prepare request/nonce. Unknown transport outcomes keep
                // the byte-identical committing payload.
                outbound.phase = .mediaUploaded
                outbound.prepare = nil
                outbound.pendingPrepareClientRequestID = UUID().uuidString.lowercased()
                state.outbound = outbound
                state = try save(state, lease: lease)
                if let filename = prepare.manifestCiphertextFilename {
                    try? DailySharingStateStore.removeOutboundCiphertext(
                        filename: filename,
                        lease: lease
                    )
                }
                needsAnotherPass = true
                return
            }
        }
    }

    private enum ReconcileDisposition {
        case unchanged
        case updated
        case finished
    }

    /// Applies the durable transition after the authenticated generation GET.
    /// Keeping this separate from network transport lets the DEBUG runtime
    /// gate exercise the exact production deadline/reconcile state machine.
    private func applyOutboundReconciliation(
        reason: DailySharingOutboundReconcileReason,
        disposition: ReconcileDisposition,
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        if disposition == .finished {
            clearOutboundRetry(in: &state)
            state = try save(state, lease: lease)
            needsAnotherPass = true
        } else if reason == .generationDayExpired
            || (reason == .draftDeadline
                && (state.outbound?.draftExpiresAt.map({
                    $0 <= Int(Date().timeIntervalSince1970)
                }) ?? true)) {
            try terminalizeUncommittedOutbound(state: &state, lease: lease)
            needsAnotherPass = true
        } else if reason == .draftDeadline,
                  let deadline = state.outbound?.draftExpiresAt {
            try persistReconciliationWake(
                at: Date(timeIntervalSince1970: TimeInterval(deadline + 1)),
                reason: .draftDeadline,
                state: &state,
                lease: lease
            )
        } else if reason == .prepareDeadline,
                  let prepare = state.outbound?.prepare {
            let nowUnix = Int(Date().timeIntervalSince1970)
            if prepare.prepareExpiresAt > nowUnix {
                try persistReconciliationWake(
                    at: Date(timeIntervalSince1970: TimeInterval(
                        prepare.prepareExpiresAt + 1
                    )),
                    reason: .prepareDeadline,
                    state: &state,
                    lease: lease
                )
            } else if let draftExpiresAt = state.outbound?.draftExpiresAt,
                      draftExpiresAt > nowUnix,
                      var resumable = state.outbound {
                let obsoleteManifest = resumable.prepare?.manifestCiphertextFilename
                resumable.phase = .mediaUploaded
                resumable.prepare = nil
                resumable.pendingPrepareClientRequestID = UUID().uuidString.lowercased()
                state.outbound = resumable
                let attempt = min((state.outboundRetry?.attemptCount ?? 0) + 1, 10_000)
                let timing = Self.retryTiming(
                    error: DailySharingError.retryableServer(retryAfterSeconds: nil),
                    attempt: attempt
                )
                state.outboundRetry = DailySharingRetrySchedule(
                    attemptCount: attempt,
                    nextRetryAt: Date().addingTimeInterval(timing.delay)
                )
                state.outboundRetryIntent = .mutation
                state.outboundReconcileReason = nil
                state = try save(state, lease: lease)
                if let obsoleteManifest {
                    try? DailySharingStateStore.removeOutboundCiphertext(
                        filename: obsoleteManifest,
                        lease: lease
                    )
                }
            } else {
                try terminalizeUncommittedOutbound(state: &state, lease: lease)
                needsAnotherPass = true
            }
        } else {
            // Reconciliation established the exact live server phase. Resume
            // with the durable ladder; persistent conflicts cannot ping-pong.
            let attempt = min((state.outboundRetry?.attemptCount ?? 0) + 1, 10_000)
            let timing = Self.retryTiming(
                error: DailySharingError.retryableServer(retryAfterSeconds: nil),
                attempt: attempt
            )
            state.outboundRetry = DailySharingRetrySchedule(
                attemptCount: attempt,
                nextRetryAt: Date().addingTimeInterval(timing.delay)
            )
            state.outboundRetryIntent = .mutation
            state.outboundReconcileReason = nil
            state = try save(state, lease: lease)
        }
    }

    /// An authenticated GET proved that the generation never committed, while
    /// the persisted reason proves mutation can no longer make safe progress.
    /// Retain the previous current generation and stop retrying this local day.
    private func terminalizeUncommittedOutbound(
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        let generationID = state.outbound?.generationID
        if let localDayKey = state.outbound?.localDayKey {
            state.lastCompletedLocalDayKey = max(
                state.lastCompletedLocalDayKey ?? localDayKey,
                localDayKey
            )
        }
        state.outbound = nil
        clearOutboundRetry(in: &state)
        state = try save(state, lease: lease)
        if let generationID {
            try? DailySharingStateStore.removeOutboundCiphertexts(
                for: generationID,
                lease: lease
            )
        }
    }

    /// Reconstructs the local exact-retry phase from the publisher-only GET.
    /// This closes response-loss/crash windows without minting new nonces or
    /// replacing the frozen daily set.
    private func reconcileOutbound(
        state: inout DailySharingState,
        spaceID: String,
        memberID: String,
        roomKey: Data,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws -> ReconcileDisposition {
        guard var outbound = state.outbound,
              let generationID = outbound.generationID,
              let sourceID = outbound.sourceID,
              let shareDayKey = outbound.serverShareDayKey,
              let draftExpiresAt = outbound.draftExpiresAt
        else { return .unchanged }

        let remote: SharingGenerationResume
        do {
            remote = try await whileLeaseHeld(lease) {
                try await api.generation(
                    generationID: generationID,
                    expectedPublisherMemberID: memberID,
                    memberID: memberID,
                    credential: credential
                )
            }
        } catch let error as PairingError {
            if case let .requestRejected(status, code, _) = error,
               status == 404,
               code == "generation_not_found" {
                let localDay = outbound.localDayKey
                state.lastCompletedLocalDayKey = localDay
                state.outbound = nil
                state = try save(state, lease: lease)
                try? DailySharingStateStore.removeOutboundCiphertexts(
                    for: generationID,
                    lease: lease
                )
                return .finished
            }
            throw error
        }

        guard remote.sourceID == sourceID,
              remote.publisherMemberID == memberID,
              remote.generationID == generationID,
              remote.shareDayKey == shareDayKey,
              remote.expiresAt == draftExpiresAt,
              remote.itemCount == outbound.media.count,
              remote.media.map(\.mediaID) == outbound.media.map(\.frozen.mediaID)
        else { throw PairingError.invalidServerResponse }

        let original = outbound
        switch remote.state {
        case "reserved":
            guard outbound.phase == .reserved,
                  remote.media.allSatisfy({
                      $0.state == "reserved"
                        && $0.ciphertextSize == nil
                        && $0.ciphertextSHA256 == nil
                  })
            else { throw PairingError.invalidServerResponse }

        case "uploading":
            guard [.reserved, .descriptorsFrozen, .mediaUploaded].contains(outbound.phase)
            else { throw PairingError.invalidServerResponse }
            for index in outbound.media.indices {
                let local = outbound.media[index]
                let server = remote.media[index]
                guard let localSize = local.ciphertextSize,
                      let localHash = local.ciphertextSHA256,
                      server.ciphertextSize == localSize,
                      server.ciphertextSHA256 == localHash,
                      server.state == "expected" || server.state == "verified",
                      !local.uploadVerified || server.state == "verified"
                else { throw PairingError.invalidServerResponse }
                outbound.media[index].uploadVerified = server.state == "verified"
            }
            outbound.phase = outbound.media.allSatisfy(\.uploadVerified)
                ? .mediaUploaded : .descriptorsFrozen

        case "prepared":
            guard [.mediaUploaded, .prepared, .manifestUploaded, .committing]
                .contains(outbound.phase),
                  remote.media.allSatisfy({ $0.state == "verified" })
            else { throw PairingError.invalidServerResponse }
            for (local, server) in zip(outbound.media, remote.media) {
                guard local.uploadVerified,
                      local.ciphertextSize == server.ciphertextSize,
                      local.ciphertextSHA256 == server.ciphertextSHA256
                else { throw PairingError.invalidServerResponse }
            }
            guard let attemptID = remote.attemptID,
                  let attemptRevision = remote.attemptRevision,
                  let reservedRevision = remote.reservedRevision,
                  let rotationAnchorUTC = remote.rotationAnchorUTC,
                  let prepareExpiresAt = remote.prepareExpiresAt
            else { throw PairingError.invalidServerResponse }
            var localPrepare: PreparedSharingAttempt
            if let existing = outbound.prepare {
                guard existing.attemptID == attemptID,
                      existing.attemptRevision == attemptRevision,
                      existing.reservedRevision == reservedRevision,
                      existing.rotationAnchorUTC == rotationAnchorUTC,
                      existing.prepareExpiresAt == prepareExpiresAt
                else { throw PairingError.invalidServerResponse }
                localPrepare = existing
            } else {
                guard let requestID = outbound.pendingPrepareClientRequestID,
                      UUID(uuidString: requestID) != nil
                else { throw PairingError.invalidServerResponse }
                localPrepare = PreparedSharingAttempt(
                    clientRequestID: requestID,
                    attemptID: attemptID,
                    attemptRevision: attemptRevision,
                    reservedRevision: reservedRevision,
                    rotationAnchorUTC: rotationAnchorUTC,
                    prepareExpiresAt: prepareExpiresAt
                )
            }
            if let serverManifest = remote.manifest {
                guard localPrepare.manifestCiphertextSize == serverManifest.ciphertextSize,
                      localPrepare.manifestCiphertextSHA256 == serverManifest.ciphertextSHA256,
                      localPrepare.manifestCiphertextFilename != nil,
                      localPrepare.commitClientRequestID != nil
                else { throw PairingError.invalidServerResponse }
                outbound.phase = outbound.phase == .committing ? .committing : .manifestUploaded
            } else {
                guard outbound.phase != .manifestUploaded,
                      outbound.phase != .committing
                else { throw PairingError.invalidServerResponse }
                outbound.phase = .prepared
            }
            outbound.pendingPrepareClientRequestID = nil
            outbound.prepare = localPrepare

        case "committed":
            let fetched = try await whileLeaseHeld(lease) {
                try await api.current(
                    sourceID: sourceID,
                    eTag: nil,
                    memberID: memberID,
                    credential: credential
                )
            }
            guard case let .current(current, _) = fetched,
                  current.sourceID == sourceID,
                  current.publisherMemberID == memberID,
                  current.generationID == generationID,
                  current.shareDayKey == shareDayKey,
                  current.media.map(\.mediaID) == outbound.media.map(\.frozen.mediaID),
                  let localPrepare = outbound.prepare,
                  current.attemptID == localPrepare.attemptID,
                  current.attemptRevision == localPrepare.attemptRevision,
                  current.reservedRevision == localPrepare.reservedRevision,
                  current.rotationAnchorUTC == localPrepare.rotationAnchorUTC,
                  current.manifest.ciphertextSize == localPrepare.manifestCiphertextSize,
                  current.manifest.ciphertextSHA256 == localPrepare.manifestCiphertextSHA256
            else { throw PairingError.invalidServerResponse }
            for (local, server) in zip(outbound.media, current.media) {
                guard local.ciphertextSize == server.ciphertextSize,
                      local.ciphertextSHA256 == server.ciphertextSHA256
                else { throw PairingError.invalidServerResponse }
            }
            try await promoteOwnCommittedGenerationIfAvailable(
                current,
                outbound: outbound,
                state: &state,
                spaceID: spaceID,
                memberID: memberID,
                roomKey: roomKey,
                credential: credential,
                api: api,
                lease: lease
            )
            state.ownSourceID = sourceID
            state.lastCompletedLocalDayKey = outbound.localDayKey
            state.lastPublishedDayKey = current.shareDayKey
            state.lastPublishedRevision = current.revision
            state.outbound = nil
            state.lastSyncAt = .now
            state = try save(state, lease: lease)
            try? DailySharingStateStore.removeOutboundCiphertexts(
                for: generationID,
                lease: lease
            )
            return .finished

        default:
            throw PairingError.invalidServerResponse
        }

        if outbound != original {
            state.outbound = outbound
            state = try save(state, lease: lease)
            return .updated
        }
        return .unchanged
    }

    private func receiveCurrentSources(
        state: inout DailySharingState,
        pairing: PairingState,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        guard let roomKey = credential.roomKey,
              let memberID = pairing.memberID,
              let peerMemberID = pairing.peerMemberID,
              let spaceID = pairing.spaceID
        else { throw PairingError.stateUnavailable }
        let sources = try await whileLeaseHeld(lease) {
            try await api.listSources(
                expectedPublisherMemberIDs: [memberID, peerMemberID],
                memberID: memberID,
                credential: credential
            )
        }
        var knownSourceByPublisher = Dictionary(
            uniqueKeysWithValues: state.inboundHighWaterBySource.values.map {
                ($0.publisherMemberID, $0.sourceID)
            }
        )
        if let ownSourceID = state.ownSourceID {
            if let knownOwn = knownSourceByPublisher[memberID], knownOwn != ownSourceID {
                throw PairingError.invalidServerResponse
            }
            knownSourceByPublisher[memberID] = ownSourceID
        }
        for source in sources {
            if let knownSourceID = knownSourceByPublisher[source.publisherMemberID],
               knownSourceID != source.sourceID {
                throw PairingError.invalidServerResponse
            }
            knownSourceByPublisher[source.publisherMemberID] = source.sourceID
            guard let summary = source.current else {
                state = try DailySharingStateStore.expireInboundPresentation(
                    expectedState: state,
                    sourceID: source.sourceID,
                    lease: lease
                )
                continue
            }
            let existing = state.inboundHighWaterBySource[source.sourceID]
            if let existing {
                guard existing.publisherMemberID == source.publisherMemberID else {
                    throw PairingError.invalidServerResponse
                }
            }
            let exactExistingDescriptor = existing.map {
                Self.highWaterMatchesSummary(
                    $0,
                    sourceID: source.sourceID,
                    publisherMemberID: source.publisherMemberID,
                    summary: summary
                )
            } == true
            let exactExisting: Bool
            if exactExistingDescriptor, let existing {
                exactExisting = try verifiedInboundGenerationIsIntact(
                    existing,
                    spaceID: spaceID,
                    roomKey: roomKey,
                    lease: lease
                )
            } else {
                exactExisting = false
            }
            let eTag = exactExisting ? "\"nw1-\(source.sourceID)-\(summary.revision)\"" : nil
            guard let resolved = try await fetchCurrentWithOneSnapshotRefresh(
                source: source,
                summary: summary,
                eTag: eTag,
                expectedPublisherMemberIDs: [memberID, peerMemberID],
                memberID: memberID,
                credential: credential,
                api: api,
                lease: lease
            ) else {
                state = try DailySharingStateStore.expireInboundPresentation(
                    expectedState: state,
                    sourceID: source.sourceID,
                    lease: lease
                )
                continue
            }
            let effectiveSummary = resolved.summary
            let fetched = resolved.fetch
            switch fetched {
            case .notModified:
                // A 304 is meaningful only for the exact effective summary.
                // In particular, a current_unavailable refresh may have moved
                // to a newer generation and its second request has no ETag.
                guard exactExisting,
                      let existing,
                      Self.highWaterMatchesSummary(
                        existing,
                        sourceID: source.sourceID,
                        publisherMemberID: source.publisherMemberID,
                        summary: effectiveSummary
                      )
                else { throw PairingError.invalidServerResponse }
                continue
            case let .current(current, _):
                guard current.publisherMemberID == source.publisherMemberID else {
                    throw PairingError.invalidServerResponse
                }
                _ = try Self.currentRelation(
                    current,
                    to: effectiveSummary,
                    sourceID: source.sourceID
                )
                if let existing {
                    guard existing.accepts(
                        publisherMemberID: current.publisherMemberID,
                        shareDayKey: current.shareDayKey,
                        revision: current.revision,
                        generationID: current.generationID,
                        prepareAttemptID: current.attemptID,
                        prepareAttemptRevision: current.attemptRevision,
                        reservedRevision: current.reservedRevision,
                        rotationAnchorUTC: current.rotationAnchorUTC,
                        uniqueMediaCount: current.uniqueMediaCount,
                        manifestCiphertextSize: current.manifest.ciphertextSize,
                        manifestHash: current.manifest.ciphertextSHA256
                    ) else { throw PairingError.invalidServerResponse }
                    if current.shareDayKey == existing.shareDayKey,
                       current.revision == existing.revision {
                        let intact: Bool
                        if exactExisting {
                            intact = true
                        } else {
                            intact = try verifiedInboundGenerationIsIntact(
                                existing,
                                spaceID: spaceID,
                                roomKey: roomKey,
                                lease: lease
                            )
                        }
                        if intact { continue }
                    }
                }
                do {
                    try await adopt(
                        current,
                        state: &state,
                        spaceID: spaceID,
                        memberID: memberID,
                        roomKey: roomKey,
                        credential: credential,
                        api: api,
                        lease: lease
                    )
                } catch where Self.isSupersededSnapshot(error) {
                    let refreshed = try await whileLeaseHeld(lease) {
                        try await api.current(
                            sourceID: source.sourceID,
                            eTag: nil,
                            memberID: memberID,
                            credential: credential
                        )
                    }
                    guard case let .current(replacement, _) = refreshed,
                          replacement.sourceID == source.sourceID,
                          replacement.publisherMemberID == source.publisherMemberID
                    else { throw PairingError.invalidServerResponse }
                    let relation = try Self.currentReplacementRelation(
                        from: current,
                        to: replacement
                    )
                    guard relation == .strictlyNewer else {
                        throw DailySharingError.retryableServer(retryAfterSeconds: 30)
                    }
                    if let highWater = state.inboundHighWaterBySource[source.sourceID] {
                        guard highWater.accepts(
                            publisherMemberID: replacement.publisherMemberID,
                            shareDayKey: replacement.shareDayKey,
                            revision: replacement.revision,
                            generationID: replacement.generationID,
                            prepareAttemptID: replacement.attemptID,
                            prepareAttemptRevision: replacement.attemptRevision,
                            reservedRevision: replacement.reservedRevision,
                            rotationAnchorUTC: replacement.rotationAnchorUTC,
                            uniqueMediaCount: replacement.uniqueMediaCount,
                            manifestCiphertextSize: replacement.manifest.ciphertextSize,
                            manifestHash: replacement.manifest.ciphertextSHA256
                        ) else { throw PairingError.invalidServerResponse }
                    }
                    do {
                        try await adopt(
                            replacement,
                            state: &state,
                            spaceID: spaceID,
                            memberID: memberID,
                            roomKey: roomKey,
                            credential: credential,
                            api: api,
                            lease: lease
                        )
                    } catch where Self.isSupersededSnapshot(error) {
                        throw DailySharingError.retryableServer(retryAfterSeconds: 30)
                    }
                }
            }
        }
        state.lastSyncAt = .now
        state = try save(state, lease: lease)
    }

    private func fetchCurrentWithOneSnapshotRefresh(
        source: SharingSourceSummary,
        summary: SharingSourceSummary.Current,
        eTag: String?,
        expectedPublisherMemberIDs: Set<String>,
        memberID: String,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws -> (summary: SharingSourceSummary.Current, fetch: SharingCurrentFetch)? {
        do {
            let fetch = try await whileLeaseHeld(lease) {
                try await api.current(
                    sourceID: source.sourceID,
                    eTag: eTag,
                    memberID: memberID,
                    credential: credential
                )
            }
            return (summary, fetch)
        } catch where Self.isCurrentUnavailable(error) {
            let refreshedSources = try await whileLeaseHeld(lease) {
                try await api.listSources(
                    expectedPublisherMemberIDs: expectedPublisherMemberIDs,
                    memberID: memberID,
                    credential: credential
                )
            }
            guard let refreshed = refreshedSources.first(
                where: { $0.sourceID == source.sourceID }
            ), refreshed.publisherMemberID == source.publisherMemberID
            else { throw PairingError.invalidServerResponse }
            guard let refreshedSummary = refreshed.current else { return nil }
            _ = try Self.summaryReplacementRelation(
                from: summary,
                to: refreshedSummary
            )
            do {
                let fetch = try await whileLeaseHeld(lease) {
                    try await api.current(
                        sourceID: source.sourceID,
                        eTag: nil,
                        memberID: memberID,
                        credential: credential
                    )
                }
                return (refreshedSummary, fetch)
            } catch where Self.isCurrentUnavailable(error) {
                throw DailySharingError.retryableServer(retryAfterSeconds: 30)
            }
        }
    }

    private func adopt(
        _ current: SharingCurrentGeneration,
        state: inout DailySharingState,
        spaceID: String,
        memberID: String,
        roomKey: Data,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        let candidate = try inboundDownloadDraft(for: current)
        state = try DailySharingStateStore.beginInboundDownload(
            expectedState: state,
            candidate: candidate,
            lease: lease
        )
        guard let draft = state.inboundDownloadBySource[current.sourceID]
        else { throw DailySharingError.stateUnavailable }

        let storedManifest = try DailySharingStateStore.readInboundDraftManifest(
            draft,
            lease: lease
        )
        let manifestCiphertext: Data
        if let storedManifest {
            manifestCiphertext = storedManifest
        } else {
            manifestCiphertext = try await whileLeaseHeld(lease) {
                try await api.downloadManifest(
                    current: current,
                    memberID: memberID,
                    credential: credential
                )
            }
        }
        try await validateAndStageInbound(
            current: current,
            state: &state,
            spaceID: spaceID,
            roomKey: roomKey,
            manifestCiphertext: manifestCiphertext,
            manifestWasStored: storedManifest != nil,
            lease: lease,
            mediaProvider: { descriptor, draft in
                if let staged = try DailySharingStateStore.readInboundDraftMedia(
                    draft,
                    media: InboundDownloadMedia(
                        mediaID: descriptor.mediaID,
                        ciphertextSize: descriptor.ciphertextSize,
                        ciphertextSHA256: descriptor.ciphertextSHA256
                    ),
                    lease: lease
                ) {
                    return (staged, true)
                }
                let downloaded = try await self.whileLeaseHeld(lease) {
                    try await api.downloadMedia(
                        current: current,
                        descriptor: descriptor,
                        memberID: memberID,
                        credential: credential
                    )
                }
                return (downloaded, false)
            }
        )
    }

    private func inboundDownloadDraft(
        for current: SharingCurrentGeneration
    ) throws -> InboundDownloadDraft {
        let stagingIdentity = Data(try PairingCrypto.sha256(
            PairingCanonicalEncoder.encode([
                "NW1.INBOUND-DRAFT",
                String(DailySharingProtocol.version),
                current.sourceID,
                current.generationID,
                current.attemptID,
                String(current.revision),
                current.manifest.ciphertextSHA256
            ])
        ).prefix(16)).base64URLEncodedString()
        return InboundDownloadDraft(
            sourceID: current.sourceID,
            publisherMemberID: current.publisherMemberID,
            shareDayKey: current.shareDayKey,
            revision: current.revision,
            generationID: current.generationID,
            prepareAttemptID: current.attemptID,
            prepareAttemptRevision: current.attemptRevision,
            reservedRevision: current.reservedRevision,
            rotationAnchorUTC: current.rotationAnchorUTC,
            uniqueMediaCount: current.uniqueMediaCount,
            manifestCiphertextSize: current.manifest.ciphertextSize,
            manifestCiphertextSHA256: current.manifest.ciphertextSHA256,
            media: current.media.map {
                InboundDownloadMedia(
                    mediaID: $0.mediaID,
                    ciphertextSize: $0.ciphertextSize,
                    ciphertextSHA256: $0.ciphertextSHA256
                )
            },
            stagingDirectoryName: ".download-\(stagingIdentity)",
            manifestVerified: false,
            completedMediaIDs: [],
            startedAt: .now
        )
    }

    /// A 304 is safe only after verifying the entire local ciphertext
    /// inventory against an authenticated manifest. This catches file loss,
    /// bit corruption, and unexpected extra files before ETag can hide them.
    private func verifiedInboundGenerationIsIntact(
        _ highWater: InboundSharingHighWater,
        spaceID: String,
        roomKey: Data,
        lease: DailySharingStateStore.SyncLease
    ) throws -> Bool {
        do {
            guard let manifestCiphertext = try DailySharingStateStore
                .readVerifiedInboundObject(
                    highWater: highWater,
                    filename: "manifest.enc",
                    expectedSize: highWater.manifestCiphertextSize,
                    expectedSHA256: highWater.manifestCiphertextSHA256,
                    lease: lease
                )
            else { return false }
            let aad = try DailySharingCrypto.manifestAAD(
                spaceID: spaceID,
                sourceID: highWater.sourceID,
                publisherMemberID: highWater.publisherMemberID,
                generationID: highWater.generationID,
                shareDayKey: highWater.shareDayKey,
                prepareAttemptID: highWater.prepareAttemptID,
                prepareAttemptRevision: highWater.prepareAttemptRevision,
                reservedRevision: highWater.reservedRevision,
                rotationAnchorUTC: highWater.rotationAnchorUTC,
                itemCount: highWater.uniqueMediaCount
            )
            let manifest = try DailySharedManifest.decodeValidated(
                DailySharingCrypto.openManifest(
                    manifestCiphertext,
                    roomKey: roomKey,
                    aad: aad
                )
            )
            guard manifest.media.count == highWater.uniqueMediaCount else { return false }
            var filenames: Set<String> = ["manifest.enc"]
            for media in manifest.media {
                let filename = "\(media.mediaID).enc"
                filenames.insert(filename)
                guard try DailySharingStateStore.readVerifiedInboundObject(
                    highWater: highWater,
                    filename: filename,
                    expectedSize: media.ciphertextSize,
                    expectedSHA256: media.ciphertextSHA256,
                    lease: lease
                ) != nil else { return false }
            }
            return try DailySharingStateStore.verifiedInboundDirectoryHasExactFileSet(
                highWater: highWater,
                expectedFilenames: filenames,
                lease: lease
            )
        } catch let error as DailySharingError where error == .stateChanged {
            throw error
        } catch {
            SharedLog.app.warning(
                "sharing-media",
                "Verified inbound cache failed local integrity recheck",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .sharingMedia,
                    additional: [
                        "source": highWater.sourceID,
                        "generation": highWater.generationID,
                    ]
                )
            )
            return false
        }
    }

    private func validateAndStageInbound(
        current: SharingCurrentGeneration,
        state: inout DailySharingState,
        spaceID: String,
        roomKey: Data,
        manifestCiphertext: Data,
        manifestWasStored: Bool,
        lease: DailySharingStateStore.SyncLease,
        mediaProvider: (
            SharingCurrentGeneration.MediaDescriptor,
            InboundDownloadDraft
        ) async throws -> (data: Data, wasStored: Bool)
    ) async throws {
        guard var draft = state.inboundDownloadBySource[current.sourceID]
        else { throw DailySharingError.stateUnavailable }
        guard manifestCiphertext.count == current.manifest.ciphertextSize,
              PairingCrypto.sha256(manifestCiphertext).base64URLEncodedString()
                == current.manifest.ciphertextSHA256
        else { throw PairingError.invalidServerResponse }
        let aad = try DailySharingCrypto.manifestAAD(
            spaceID: spaceID,
            sourceID: current.sourceID,
            publisherMemberID: current.publisherMemberID,
            generationID: current.generationID,
            shareDayKey: current.shareDayKey,
            prepareAttemptID: current.attemptID,
            prepareAttemptRevision: current.attemptRevision,
            reservedRevision: current.reservedRevision,
            rotationAnchorUTC: current.rotationAnchorUTC,
            itemCount: current.uniqueMediaCount
        )
        let manifest = try DailySharedManifest.decodeValidated(
            DailySharingCrypto.openManifest(manifestCiphertext, roomKey: roomKey, aad: aad)
        )
        guard manifest.media.count == current.uniqueMediaCount,
              manifest.media.map(\.mediaID) == current.media.map(\.mediaID)
        else { throw PairingError.invalidServerResponse }
        if !manifestWasStored || !draft.manifestVerified {
            state = try DailySharingStateStore.stageVerifiedInboundManifest(
                manifestCiphertext,
                expectedState: state,
                sourceID: current.sourceID,
                lease: lease
            )
            guard let refreshed = state.inboundDownloadBySource[current.sourceID]
            else { throw DailySharingError.stateUnavailable }
            draft = refreshed
        }

        for (manifestMedia, descriptor) in zip(manifest.media, current.media) {
            guard manifestMedia.ciphertextSize == descriptor.ciphertextSize,
                  manifestMedia.ciphertextSHA256 == descriptor.ciphertextSHA256
            else { throw PairingError.invalidServerResponse }
            let provided = try await mediaProvider(descriptor, draft)
            if provided.wasStored, draft.completedMediaIDs.contains(descriptor.mediaID) {
                continue
            }
            let data = provided.data
            guard data.count == descriptor.ciphertextSize,
                  PairingCrypto.sha256(data).base64URLEncodedString()
                    == descriptor.ciphertextSHA256
            else { throw PairingError.invalidServerResponse }
            let bindingHash = try manifestMedia.binding.bindingHash()
            let mediaAAD = try DailySharingCrypto.mediaAAD(
                spaceID: spaceID,
                sourceID: current.sourceID,
                publisherMemberID: current.publisherMemberID,
                generationID: current.generationID,
                shareDayKey: current.shareDayKey,
                mediaID: descriptor.mediaID,
                mediaBindingHash: bindingHash
            )
            let plaintext = try DailySharingCrypto.openMedia(
                data,
                roomKey: roomKey,
                aad: mediaAAD
            )
            try autoreleasepool {
                try CanonicalPreviewBuilder.validateReceivedJPEG(
                    plaintext,
                    binding: manifestMedia.binding,
                    expectedPlaintextSHA256: manifestMedia.canonicalJPEGPlaintextSHA256
                )
            }
            // Commit one authenticated ciphertext and its completion marker at
            // a time. Plain JPEG bytes leave this autorelease scope and are
            // never persisted; a later failure resumes at the next media ID.
            state = try DailySharingStateStore.stageVerifiedInboundMedia(
                data,
                mediaID: descriptor.mediaID,
                expectedState: state,
                sourceID: current.sourceID,
                lease: lease
            )
            guard let refreshed = state.inboundDownloadBySource[current.sourceID]
            else { throw DailySharingError.stateUnavailable }
            draft = refreshed
        }
        try lease.renew()
        state = try DailySharingStateStore.finalizeInboundDownload(
            expectedState: state,
            sourceID: current.sourceID,
            lease: lease,
            now: .now
        )
    }

    private func currentGeneration(
        from outbound: OutboundSharingGeneration,
        publisherMemberID: String,
        sourceID: String,
        generationID: String,
        shareDayKey: Int,
        revision: Int,
        attemptID: String,
        attemptRevision: Int,
        reservedRevision: Int,
        rotationAnchorUTC: Int
    ) throws -> SharingCurrentGeneration {
        guard outbound.sourceID == sourceID,
              outbound.generationID == generationID,
              outbound.serverShareDayKey == shareDayKey,
              let prepare = outbound.prepare,
              prepare.attemptID == attemptID,
              prepare.attemptRevision == attemptRevision,
              prepare.reservedRevision == reservedRevision,
              prepare.rotationAnchorUTC == rotationAnchorUTC,
              let manifestSize = prepare.manifestCiphertextSize,
              let manifestHash = prepare.manifestCiphertextSHA256
        else { throw PairingError.invalidServerResponse }
        let media = try outbound.media.map { item -> SharingCurrentGeneration.MediaDescriptor in
            guard let size = item.ciphertextSize,
                  let hash = item.ciphertextSHA256
            else { throw DailySharingError.stateUnavailable }
            return SharingCurrentGeneration.MediaDescriptor(
                mediaID: item.frozen.mediaID,
                ciphertextSize: size,
                ciphertextSHA256: hash
            )
        }
        return SharingCurrentGeneration(
            sourceID: sourceID,
            publisherMemberID: publisherMemberID,
            generationID: generationID,
            shareDayKey: shareDayKey,
            revision: revision,
            attemptID: attemptID,
            attemptRevision: attemptRevision,
            reservedRevision: reservedRevision,
            rotationAnchorUTC: rotationAnchorUTC,
            uniqueMediaCount: media.count,
            manifest: SharingCurrentGeneration.ObjectDescriptor(
                ciphertextSize: manifestSize,
                ciphertextSHA256: manifestHash
            ),
            media: media
        )
    }

    private func promoteOwnCommittedGeneration(
        _ current: SharingCurrentGeneration,
        outbound: OutboundSharingGeneration,
        state: inout DailySharingState,
        spaceID: String,
        roomKey: Data,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        state = try DailySharingStateStore.beginInboundDownload(
            expectedState: state,
            candidate: inboundDownloadDraft(for: current),
            lease: lease
        )
        guard let draft = state.inboundDownloadBySource[current.sourceID],
              let prepare = outbound.prepare,
              let manifestFilename = prepare.manifestCiphertextFilename
        else { throw DailySharingError.stateUnavailable }
        let storedManifest = try DailySharingStateStore.readInboundDraftManifest(
            draft,
            lease: lease
        )
        let manifestCiphertext: Data
        if let storedManifest {
            manifestCiphertext = storedManifest
        } else {
            manifestCiphertext = try DailySharingStateStore.readOutboundCiphertext(
                filename: manifestFilename,
                maximumBytes: DailySharingProtocol.maximumManifestCiphertextBytes,
                lease: lease
            )
        }
        try await validateAndStageInbound(
            current: current,
            state: &state,
            spaceID: spaceID,
            roomKey: roomKey,
            manifestCiphertext: manifestCiphertext,
            manifestWasStored: storedManifest != nil,
            lease: lease,
            mediaProvider: { descriptor, draft in
                let persistedDescriptor = InboundDownloadMedia(
                    mediaID: descriptor.mediaID,
                    ciphertextSize: descriptor.ciphertextSize,
                    ciphertextSHA256: descriptor.ciphertextSHA256
                )
                if let staged = try DailySharingStateStore.readInboundDraftMedia(
                    draft,
                    media: persistedDescriptor,
                    lease: lease
                ) {
                    return (staged, true)
                }
                guard let item = outbound.media.first(
                    where: { $0.frozen.mediaID == descriptor.mediaID }
                ), let filename = item.ciphertextFilename
                else { throw DailySharingError.stateUnavailable }
                return (
                    try DailySharingStateStore.readOutboundCiphertext(
                        filename: filename,
                        maximumBytes: DailySharingProtocol.maximumMediaCiphertextBytes,
                        lease: lease
                    ),
                    false
                )
            }
        )
    }

    /// Local promotion is a bandwidth optimization, never a liveness gate.
    /// Once the authenticated commit/current descriptor proves publication,
    /// missing or corrupt local retry files fall back to the ordinary inbound
    /// downloader in this same pass. Any partial verified draft is retained and
    /// resumed media-by-media. Lease loss/cancellation still aborts immediately.
    private func promoteOwnCommittedGenerationIfAvailable(
        _ current: SharingCurrentGeneration,
        outbound: OutboundSharingGeneration,
        state: inout DailySharingState,
        spaceID: String,
        memberID: String,
        roomKey: Data,
        credential: PairingCredential,
        api: any DailySharingAPIClientProtocol,
        lease: DailySharingStateStore.SyncLease
    ) async throws {
        do {
            try await promoteOwnCommittedGeneration(
                current,
                outbound: outbound,
                state: &state,
                spaceID: spaceID,
                roomKey: roomKey,
                lease: lease
            )
        } catch {
            if error is CancellationError
                || (error as? DailySharingError) == .stateChanged {
                throw error
            }
            SharedLog.app.warning(
                "sharing-media",
                "Own committed generation will be recovered from the server",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .sharingMedia,
                    additional: ["generation": current.generationID]
                )
            )
            // Do not depend on the independent inbound retry schedule: the
            // outbound ciphertext is deleted immediately after this returns.
            // Recover this exact authenticated current descriptor now, using
            // the same persistent per-object draft/resume path as peer media.
            try await adopt(
                current,
                state: &state,
                spaceID: spaceID,
                memberID: memberID,
                roomKey: roomKey,
                credential: credential,
                api: api,
                lease: lease
            )
        }
    }

    private func sharedManifest(from outbound: OutboundSharingGeneration) throws -> DailySharedManifest {
        let values = try outbound.media.map { item -> DailySharedManifestMedia in
            guard let binding = item.binding,
                  let size = item.ciphertextSize,
                  let ciphertextHash = item.ciphertextSHA256,
                  let plaintextHash = item.canonicalJPEGPlaintextSHA256
            else { throw DailySharingError.stateUnavailable }
            return DailySharedManifestMedia(
                mediaID: item.frozen.mediaID,
                binding: binding,
                ciphertextSize: size,
                ciphertextSHA256: ciphertextHash,
                canonicalJPEGPlaintextSHA256: plaintextHash
            )
        }
        return try DailySharedManifest(media: values, slots: outbound.slotMediaIDs).validated()
    }

    private func requireOutbound(_ state: DailySharingState) throws -> OutboundSharingGeneration {
        guard let outbound = state.outbound else { throw DailySharingError.stateUnavailable }
        return try outbound.validated()
    }

    private func save(
        _ state: DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws -> DailySharingState {
        try DailySharingStateStore.save(
            state,
            expectedStorageRevision: state.storageRevision,
            lease: lease
        )
    }

    private func whileLeaseHeld<Value>(
        _ lease: DailySharingStateStore.SyncLease,
        heartbeatInterval: Duration = .seconds(30),
        operation: () async throws -> Value
    ) async throws -> Value {
        try lease.renew()
        let heartbeat = Task { () -> Bool in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    return true
                }
                do {
                    try lease.renew()
                } catch {
                    // The in-flight network/PhotoKit operation may finish, but
                    // its result is rejected below. This closes the window in
                    // which another process could take a 90-second lease.
                    return false
                }
            }
            return true
        }
        do {
            let value = try await operation()
            heartbeat.cancel()
            let heartbeatStayedOwner = await heartbeat.value
            guard heartbeatStayedOwner else { throw DailySharingError.stateChanged }
            try lease.renew()
            return value
        } catch {
            heartbeat.cancel()
            _ = await heartbeat.value
            throw error
        }
    }

    private func scheduleOutboundRetry(
        error: Error,
        intent: DailySharingOutboundRetryIntent,
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        let attempt = min((state.outboundRetry?.attemptCount ?? 0) + 1, 10_000)
        let timing = Self.retryTiming(error: error, attempt: attempt)
        var date = Date().addingTimeInterval(timing.delay)
        var persistedIntent = intent
        let relevantExpiry = intent == .mutation
            ? state.outbound?.prepare?.prepareExpiresAt ?? state.outbound?.draftExpiresAt
            : nil
        if let relevantExpiry {
            let retryDeadline = Date(
                timeIntervalSince1970: TimeInterval(relevantExpiry - 60)
            )
            if date > retryDeadline || retryDeadline <= .now {
                let afterExpiry = Date(
                    timeIntervalSince1970: TimeInterval(relevantExpiry + 1)
                )
                date = max(
                    afterExpiry,
                    timing.retryAfterDelay.map { Date().addingTimeInterval($0) } ?? afterExpiry
                )
                persistedIntent = .reconcileOnly
            }
        }
        state.outboundRetry = DailySharingRetrySchedule(
            attemptCount: attempt,
            nextRetryAt: date
        )
        state.outboundRetryIntent = persistedIntent
        if persistedIntent == .reconcileOnly {
            state.outboundReconcileReason = intent == .mutation
                ? (state.outbound?.prepare == nil
                    ? .draftDeadline : .prepareDeadline)
                : state.outboundReconcileReason ?? .uncertainOutcome
        } else {
            state.outboundReconcileReason = nil
        }
        state = try save(state, lease: lease)
        scheduleNextRetry(for: state)
    }

    private func scheduleInboundRetry(
        error: Error,
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        let attempt = min((state.inboundRetry?.attemptCount ?? 0) + 1, 10_000)
        let timing = Self.retryTiming(error: error, attempt: attempt)
        state.inboundRetry = DailySharingRetrySchedule(
            attemptCount: attempt,
            nextRetryAt: Date().addingTimeInterval(timing.delay)
        )
        state = try save(state, lease: lease)
        scheduleNextRetry(for: state)
    }

    static func retryTiming(
        error: Error,
        attempt: Int
    ) -> (delay: TimeInterval, retryAfterDelay: TimeInterval?) {
        let baseDelays: [TimeInterval] = [30, 2 * 60, 5 * 60, 15 * 60, 60 * 60, 6 * 60 * 60]
        let index = min(attempt - 1, baseDelays.count - 1)
        let genericDelay = baseDelays[index] * Double.random(in: 0.8...1.2)
        let retryAfterDelay: TimeInterval?
        if let dailyError = error as? DailySharingError,
           case let .retryableServer(retryAfterSeconds) = dailyError,
           let retryAfterSeconds {
            retryAfterDelay = TimeInterval(min(max(retryAfterSeconds, 1), 6 * 60 * 60))
        } else {
            retryAfterDelay = nil
        }
        return (max(genericDelay, retryAfterDelay ?? 0), retryAfterDelay)
    }

    private func deferMutationsNearDeadlineIfNeeded(
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        guard var outbound = state.outbound,
              let draftExpiresAt = outbound.draftExpiresAt
        else { return }
        let now = Int(Date().timeIntervalSince1970)
        if let prepare = outbound.prepare {
            if prepare.prepareExpiresAt <= now {
                // The old attempt can no longer commit. Keep verified media,
                // mint a new persisted prepare idempotency key, and re-seal
                // only the manifest under the next server anchor.
                outbound.phase = .mediaUploaded
                outbound.prepare = nil
                outbound.pendingPrepareClientRequestID = UUID().uuidString.lowercased()
                state.outbound = outbound
                state = try save(state, lease: lease)
            } else if prepare.prepareExpiresAt - now <= 60 {
                try persistReconciliationWake(
                    at: Date(timeIntervalSince1970: TimeInterval(prepare.prepareExpiresAt + 1)),
                    reason: .prepareDeadline,
                    state: &state,
                    lease: lease
                )
                throw DailySharingError.waitingForReconciliation
            }
        }
        if draftExpiresAt - now <= 60 {
            try persistReconciliationWake(
                at: Date(timeIntervalSince1970: TimeInterval(draftExpiresAt + 1)),
                reason: .draftDeadline,
                state: &state,
                lease: lease
            )
            throw DailySharingError.waitingForReconciliation
        }
    }

    private func persistReconciliationWake(
        at date: Date,
        reason: DailySharingOutboundReconcileReason,
        useBackoff: Bool = false,
        state: inout DailySharingState,
        lease: DailySharingStateStore.SyncLease
    ) throws {
        let existingAttempt = state.outboundRetry?.attemptCount ?? 0
        let attempt = useBackoff
            ? min(existingAttempt + 1, 10_000)
            : max(1, existingAttempt)
        let backoffDate: Date
        if useBackoff {
            let timing = Self.retryTiming(
                error: DailySharingError.retryableServer(retryAfterSeconds: nil),
                attempt: attempt
            )
            backoffDate = Date().addingTimeInterval(timing.delay)
        } else {
            backoffDate = .distantPast
        }
        state.outboundRetry = DailySharingRetrySchedule(
            attemptCount: attempt,
            nextRetryAt: max(
                max(date, backoffDate),
                Date().addingTimeInterval(1)
            )
        )
        state.outboundRetryIntent = .reconcileOnly
        state.outboundReconcileReason = reason
        state = try save(state, lease: lease)
        scheduleNextRetry(for: state)
    }

    private func clearOutboundRetry(in state: inout DailySharingState) {
        state.outboundRetry = nil
        state.outboundRetryIntent = nil
        state.outboundReconcileReason = nil
    }

    private func clearInboundRetry(in state: inout DailySharingState) {
        state.inboundRetry = nil
    }

    private func scheduleNextRetry(for state: DailySharingState) {
        let next = [state.outboundRetry?.nextRetryAt, state.inboundRetry?.nextRetryAt]
            .compactMap { $0 }
            .min()
        guard let next else {
            retryTask?.cancel()
            retryTask = nil
            retryTaskToken = nil
            scheduledRetryAt = nil
            return
        }
        scheduleRetry(at: max(next, Date().addingTimeInterval(0.05)))
    }

    private func scheduleRetry(at date: Date) {
        if let scheduledRetryAt,
           abs(scheduledRetryAt.timeIntervalSince(date)) < 0.5,
           retryTask != nil {
            return
        }
        retryTask?.cancel()
        let token = UUID()
        retryTaskToken = token
        scheduledRetryAt = date
        retryTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            await self?.retryTimerFired(token: token)
        }
    }

    /// A busy logical lease is independent of the two persisted retry domains.
    /// Never postpone an already scheduled earlier domain wake while arranging
    /// crash-lease recovery.
    private func scheduleBusyLeaseRetry(at date: Date) {
        if let scheduledRetryAt,
           scheduledRetryAt <= date,
           retryTask != nil {
            return
        }
        scheduleRetry(at: date)
    }

    private func retryTimerFired(token: UUID) async {
        guard retryTaskToken == token else { return }
        // Detach the fired timer before entering synchronize. A pass may
        // schedule the other independent retry slot without cancelling the
        // Task that is currently executing it.
        retryTask = nil
        retryTaskToken = nil
        scheduledRetryAt = nil
        let isForeground = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isForeground else { return }
        await synchronize(trigger: "retry")
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let dailyError = error as? DailySharingError,
           case .retryableServer = dailyError {
            return true
        }
        guard let value = error as? URLError else { return false }
        switch value.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func dayKey(now: Date, boundaryMinuteUTC: Int) -> Int {
        let shifted = Int(now.timeIntervalSince1970) - boundaryMinuteUTC * 60
        return shifted / 86_400
    }

    static func secondsSinceBoundary(now: Date, boundaryMinuteUTC: Int) -> Int {
        let shifted = Int(now.timeIntervalSince1970) - boundaryMinuteUTC * 60
        let remainder = shifted % 86_400
        return remainder >= 0 ? remainder : remainder + 86_400
    }

    static func clockSkewRetryDate(
        now: Date,
        boundaryMinuteUTC: Int
    ) -> Date {
        let unix = Int(now.timeIntervalSince1970)
        let day = dayKey(now: now, boundaryMinuteUTC: boundaryMinuteUTC)
        let boundary = day * 86_400 + boundaryMinuteUTC * 60
        return Date(timeIntervalSince1970: TimeInterval(max(unix + 1, boundary + 360)))
    }

    static func secondsUntilNextBoundary(
        now: Date,
        boundaryMinuteUTC: Int
    ) -> Int {
        86_400 - secondsSinceBoundary(now: now, boundaryMinuteUTC: boundaryMinuteUTC)
    }

    private static func isExpiredPrepare(_ error: PairingError) -> Bool {
        guard case let .requestRejected(status, code, _) = error else { return false }
        return status == 409 && code == "prepare_expired"
    }

    private static func isPreviousGenerationCleanupPending(_ error: PairingError) -> Bool {
        guard case let .requestRejected(status, code, _) = error else { return false }
        return status == 409 && code == "previous_generation_cleanup_pending"
    }

    /// These server-confirmed phase conflicts make mutation retry unsafe. Keep
    /// the reason durable so GET reconciliation can distinguish a terminal day
    /// from an exact live phase that may resume with bounded backoff.
    private static func outboundReconcileReason(
        _ error: Error
    ) -> DailySharingOutboundReconcileReason? {
        guard let pairingError = error as? PairingError,
              case let .requestRejected(status, code, _) = pairingError,
              status == 409,
              let code
        else { return nil }
        switch code {
        case "generation_day_expired": return .generationDayExpired
        case "upload_closed": return .uploadClosed
        case "invalid_generation_state": return .invalidGenerationState
        case "commit_conflict": return .commitConflict
        default: return nil
        }
    }

    static func isRemoteRevocation(_ error: Error) -> Bool {
        guard let pairingError = error as? PairingError,
              case let .requestRejected(status, code, _) = pairingError
        else { return false }
        return (status == 401 && code == "invalid_authentication")
            || (status == 410 && code == "sharing_revoked")
    }

    private static func isSupersededSnapshot(_ error: Error) -> Bool {
        guard let pairingError = error as? PairingError,
              case let .requestRejected(status, code, _) = pairingError,
              status == 404
        else { return false }
        return code == "manifest_not_found" || code == "media_not_found"
    }

    private static func isCurrentUnavailable(_ error: Error) -> Bool {
        guard let pairingError = error as? PairingError,
              case let .requestRejected(status, code, _) = pairingError
        else { return false }
        return status == 404 && code == "current_unavailable"
    }

    private enum CurrentSnapshotRelation: Equatable {
        case exact
        case strictlyNewer
    }

    private static func highWaterMatchesSummary(
        _ highWater: InboundSharingHighWater,
        sourceID: String,
        publisherMemberID: String,
        summary: SharingSourceSummary.Current
    ) -> Bool {
        highWater.sourceID == sourceID
            && highWater.publisherMemberID == publisherMemberID
            && highWater.shareDayKey == summary.shareDayKey
            && highWater.revision == summary.revision
            && highWater.generationID == summary.generationID
            && highWater.rotationAnchorUTC == summary.rotationAnchorUTC
            && highWater.uniqueMediaCount == summary.uniqueMediaCount
    }

    private static func summaryReplacementRelation(
        from original: SharingSourceSummary.Current,
        to replacement: SharingSourceSummary.Current
    ) throws -> CurrentSnapshotRelation {
        let exact = original.generationID == replacement.generationID
            && original.shareDayKey == replacement.shareDayKey
            && original.revision == replacement.revision
            && original.rotationAnchorUTC == replacement.rotationAnchorUTC
            && original.uniqueMediaCount == replacement.uniqueMediaCount
        if exact { return .exact }
        guard replacement.shareDayKey > original.shareDayKey,
              replacement.revision > original.revision
        else { throw PairingError.invalidServerResponse }
        return .strictlyNewer
    }

    private static func currentRelation(
        _ current: SharingCurrentGeneration,
        to summary: SharingSourceSummary.Current,
        sourceID: String
    ) throws -> CurrentSnapshotRelation {
        guard current.sourceID == sourceID else {
            throw PairingError.invalidServerResponse
        }
        let exact = current.generationID == summary.generationID
            && current.shareDayKey == summary.shareDayKey
            && current.revision == summary.revision
            && current.rotationAnchorUTC == summary.rotationAnchorUTC
            && current.uniqueMediaCount == summary.uniqueMediaCount
        if exact { return .exact }
        guard current.shareDayKey > summary.shareDayKey,
              current.revision > summary.revision
        else { throw PairingError.invalidServerResponse }
        return .strictlyNewer
    }

    private static func currentReplacementRelation(
        from original: SharingCurrentGeneration,
        to replacement: SharingCurrentGeneration
    ) throws -> CurrentSnapshotRelation {
        guard original.sourceID == replacement.sourceID,
              original.publisherMemberID == replacement.publisherMemberID
        else { throw PairingError.invalidServerResponse }
        if sameCurrentIdentity(original, replacement) { return .exact }
        // Revision is source-monotonic and the share day is monotonic. Requiring
        // both axes to advance rejects rollback, one-axis ambiguity, and every
        // same-revision descriptor/hash equivocation even on a first sync with
        // no local high-water state yet.
        guard replacement.shareDayKey > original.shareDayKey,
              replacement.revision > original.revision
        else { throw PairingError.invalidServerResponse }
        return .strictlyNewer
    }

    private static func sameCurrentIdentity(
        _ lhs: SharingCurrentGeneration,
        _ rhs: SharingCurrentGeneration
    ) -> Bool {
        lhs.sourceID == rhs.sourceID
            && lhs.publisherMemberID == rhs.publisherMemberID
            && lhs.generationID == rhs.generationID
            && lhs.shareDayKey == rhs.shareDayKey
            && lhs.revision == rhs.revision
            && lhs.attemptID == rhs.attemptID
            && lhs.attemptRevision == rhs.attemptRevision
            && lhs.reservedRevision == rhs.reservedRevision
            && lhs.rotationAnchorUTC == rhs.rotationAnchorUTC
            && lhs.uniqueMediaCount == rhs.uniqueMediaCount
            && lhs.manifest.ciphertextSize == rhs.manifest.ciphertextSize
            && lhs.manifest.ciphertextSHA256 == rhs.manifest.ciphertextSHA256
            && lhs.media.count == rhs.media.count
            && zip(lhs.media, rhs.media).allSatisfy { pair in
                let (left, right) = pair
                return left.mediaID == right.mediaID
                    && left.ciphertextSize == right.ciphertextSize
                    && left.ciphertextSHA256 == right.ciphertextSHA256
            }
    }
}
