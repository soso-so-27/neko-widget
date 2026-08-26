import Darwin
import Foundation

/// Binds sharing credentials to this installation. Keychain items can survive
/// app deletion, so the Keychain alone must never be treated as proof that the
/// current installation is authorized to reuse a room key.
enum PairingInstallationGuard {
    private struct WindowCleanupScope: Codable {
        static let schemaVersion = 1
        var schemaVersion: Int = Self.schemaVersion
        let localWindowID: String

        func validated() throws -> Self {
            guard schemaVersion == Self.schemaVersion,
                  let uuid = UUID(uuidString: localWindowID),
                  uuid.uuidString.lowercased() == localWindowID.lowercased()
            else { throw PairingError.stateUnavailable }
            return self
        }
    }
    private static let markerFileName = "sharing-installation-marker.v1"

    private struct PairedRecoveryCandidate {
        let location: PrivateWindowRecoveryLocation
        let state: PairingState
    }

    private enum PairedRecoveryDiscovery {
        case none
        case ambiguous
        case unique(PairedRecoveryCandidate)
    }

    private enum ActiveWindowSelectionPlan {
        case stored(PairingState)
        case recover(PairedRecoveryCandidate)
        case initializeEmpty
    }

    enum RetryableBootstrapReason: String, Equatable, Sendable {
        case installationMarkerReadUnavailable =
            "installation-marker-read-unavailable"
        case lifecycleStateUnavailable = "lifecycle-state-unavailable"
        case pairingStateProtectedDataUnavailable =
            "pairing-state-protected-data-unavailable"
        case pairingStateReadUnavailable = "pairing-state-read-unavailable"
        case privateWindowMigrationUnavailable =
            "private-window-migration-unavailable"
        case keychainProtectedDataUnavailable =
            "keychain-protected-data-unavailable"
        case keychainUnavailable = "keychain-unavailable"
    }

    struct RetryableBootstrapError: LocalizedError, Equatable, Sendable {
        let reason: RetryableBootstrapReason

        var errorDescription: String? {
            switch reason {
            case .privateWindowMigrationUnavailable:
                return "共有データの更新を完了できませんでした。データは削除せず保護しています。時間をおいて、もう一度お試しください。"
            default:
                return "共有の状態を一時的に確認できませんでした。iPhoneのロックを解除したまま、もう一度お試しください。"
            }
        }
    }

    enum PairingStateLoadFailureDisposition: Equatable, Sendable {
        case failClosed
        case retryable(RetryableBootstrapReason)
    }

    struct BootstrapResult: Sendable {
        let state: PairingState
        let lifecycleToken: SharingLifecycleGate.Token
        let invalidatedPreviousInstallation: Bool
    }

    static func bootstrap() throws -> BootstrapResult {
        try SharingLifecycleGate.withExclusive {
            try bootstrapWhileLocked()
        }
    }

    /// Pairing screens are MainActor-isolated. Lifecycle cleanup may briefly
    /// wait for another process's short mutation lock, so perform that wait off
    /// the UI executor and publish only the final value back to the view model.
    static func bootstrapAsync() async throws -> BootstrapResult {
        try await Task.detached(priority: .userInitiated) {
            try bootstrap()
        }.value
    }

    /// A build whose selected configuration is fully disabled has no authority
    /// to retain an earlier room. Unlike a user-requested unlink, this reset
    /// deliberately has no expected-state CAS: stale paired state, orphaned
    /// Keychain items and an interrupted prior cleanup must all converge to the
    /// same unpaired installation before any relay client can be constructed.
    @discardableResult
    static func resetLocalSharingForDisabledConfiguration() throws -> PairingState {
        try SharingLifecycleGate.withExclusive {
            // Local-only cleanup does not need to preserve room identity. Do
            // not let an unavailable or malformed ordinary-container marker
            // prevent the App Group tombstone from being published first. A
            // later enabled build treats a missing/mismatched marker as another
            // reason to clean before it can reuse any sharing capability.
            let existingMarker = try? readLocalMarker()
            let marker = existingMarker ?? UUID().uuidString
            if existingMarker == nil {
                try? writeLocalMarker(marker)
            }
            return try performCleanupWhileLocked(
                marker: marker,
                message: nil,
                removeAllWindows: true
            )
        }
    }

    static func resetLocalSharingForDisabledConfigurationAsync() async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try resetLocalSharingForDisabledConfiguration()
        }.value
    }

    /// Creates another independent local slot without touching the currently
    /// paired window or its Keychain account. The global lifecycle epoch is
    /// bumped first so a foreground/background result from the previous slot
    /// cannot commit through the newly selected paths.
    static func createAndActivatePrivateWindow() throws -> BootstrapResult {
        try SharingLifecycleGate.withExclusive {
            try finishPendingCleanupBeforeWindowSelectionWhileLocked()
            guard let marker = try readLocalMarker() else {
                throw PairingError.installationChanged
            }
            _ = try PrivateWindowCatalogStore
                .bootstrapLegacyMigrationWhileLifecycleLocked()
            _ = try SharingLifecycleGate.bumpEpochWhileLocked()
            try DailySharingStateStore.revokeAllSyncLeasesWhileLifecycleLocked()
            _ = try PrivateWindowCatalogStore.createAndActivateWhileLifecycleLocked()
            let state = PairingState.unpaired(installationMarker: marker)
            try PairingStateStore.saveWhileLifecycleLocked(state)
            guard let committed = try PairingStateStore.load() else {
                throw PairingError.stateUnavailable
            }
            return BootstrapResult(
                state: committed,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: false
            )
        }
    }

    static func createAndActivatePrivateWindowAsync() async throws -> BootstrapResult {
        try await Task.detached(priority: .userInitiated) {
            try createAndActivatePrivateWindow()
        }.value
    }

    /// Selects an existing catalog slot. A missing target is never replaced
    /// with a different catalog slot. It may resume its own authenticated
    /// migration copy, or become unpaired only when the target is provably an
    /// empty slot left by an interrupted explicit creation.
    static func activatePrivateWindow(localWindowID: String) throws -> BootstrapResult {
        try SharingLifecycleGate.withExclusive {
            try finishPendingCleanupBeforeWindowSelectionWhileLocked()
            guard let marker = try readLocalMarker() else {
                throw PairingError.installationChanged
            }
            _ = try PrivateWindowCatalogStore
                .bootstrapLegacyMigrationWhileLifecycleLocked()
            let plan = try selectionPlanWhileLocked(
                targetLocalWindowID: localWindowID,
                installationMarker: marker,
                rejectInstallationMarkerMismatch: true
            )
            _ = try SharingLifecycleGate.bumpEpochWhileLocked()
            try DailySharingStateStore.revokeAllSyncLeasesWhileLifecycleLocked()
            _ = try PrivateWindowCatalogStore.activateWhileLifecycleLocked(
                localWindowID: localWindowID
            )
            let state: PairingState
            switch plan {
            case let .stored(expected):
                guard let committed = try PairingStateStore.load(),
                      committed == expected
                else {
                    throw deferredBootstrapError(
                        reason: .privateWindowMigrationUnavailable
                    )
                }
                state = committed
            case let .recover(candidate):
                state = try promotePairedRecoveryCandidateWhileLocked(
                    candidate,
                    targetLocalWindowID: localWindowID,
                    invalidateLifecycle: false
                )
            case .initializeEmpty:
                let empty = PairingState.unpaired(installationMarker: marker)
                try PairingStateStore.saveWhileLifecycleLocked(empty)
                guard let committed = try PairingStateStore.load() else {
                    throw PairingError.stateUnavailable
                }
                state = committed
            }
            try? PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked(
                spaceID: state.spaceID,
                credentialAccount: state.credentialAccount
            )
            return BootstrapResult(
                state: state,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: false
            )
        }
    }

    static func activatePrivateWindowAsync(
        localWindowID: String
    ) async throws -> BootstrapResult {
        try await Task.detached(priority: .userInitiated) {
            try activatePrivateWindow(localWindowID: localWindowID)
        }.value
    }

    private static func bootstrapWhileLocked() throws -> BootstrapResult {
        let cleanupRequired: Bool
        do {
            cleanupRequired = try SharingLifecycleGate.cleanupRequiredWhileLocked()
        } catch {
            throw deferredBootstrapError(reason: .lifecycleStateUnavailable)
        }
        if cleanupRequired {
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap reset",
                metadata: ["sharingFailureReason": "cleanup-resume-required"]
            )
            let existingMarker = try readLocalMarkerForBootstrap()
            let marker = existingMarker ?? UUID().uuidString
            if existingMarker == nil { try writeLocalMarker(marker) }
            let cleanupScope = try readWindowCleanupScopeWhileLocked()
            if let cleanupScope {
                guard let catalog = try PrivateWindowCatalogStore.load(),
                      catalog.windows.contains(where: {
                          $0.localWindowID == cleanupScope.localWindowID
                      })
                else {
                    throw deferredBootstrapError(
                        reason: .pairingStateReadUnavailable
                    )
                }
                // A previous build could commit another active-window choice
                // after publishing this scoped cleanup intent but before the
                // interrupted deletion resumed. Restore the exact scoped slot
                // first so every path-based credential/cache mutation remains
                // confined to that window. The durable tombstone and epoch
                // continue to block network work throughout the recovery.
                if catalog.activeWindowID != cleanupScope.localWindowID {
                    _ = try PrivateWindowCatalogStore
                        .activateWhileLifecycleLocked(
                            localWindowID: cleanupScope.localWindowID
                        )
                }
            }
            let reset = try performCleanupWhileLocked(
                marker: marker,
                message: "共有の削除処理を完了しました。もう一度招待できます。",
                removeAllWindows: cleanupScope == nil
            )
            return BootstrapResult(
                state: reset,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: true
            )
        }
        let existingState = try? PairingStateStore.load()
        guard let marker = try readLocalMarkerForBootstrap() else {
            // A missing ordinary-container marker means first install or
            // reinstall. In both cases all App Group/Keychain remnants are
            // untrusted and must be removed before any network operation.
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap reset",
                metadata: ["sharingFailureReason": "installation-marker-missing"]
            )
            let newMarker = UUID().uuidString
            try writeLocalMarker(newMarker)
            let state = try performCleanupWhileLocked(
                marker: newMarker,
                message: nil,
                removeAllWindows: true
            )
            return BootstrapResult(
                state: state,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: existingState != nil
            )
        }

        do {
            _ = try SharingLifecycleGate.currentEpochWhileLocked()
        } catch SharingLifecycleGate.Error.corrupted {
            do {
                _ = try SharingLifecycleGate.recoverCorruptedEpochWhileLocked()
                SharedLog.app.warning(
                    "pairing",
                    "Pairing lifecycle epoch recovered without changing credentials",
                    metadata: ["sharingFailureReason": "lifecycle-state-recovered"]
                )
            } catch {
                throw deferredBootstrapError(reason: .lifecycleStateUnavailable)
            }
        } catch {
            // Availability is not proof of corruption. Preserve the credential
            // and retry after Data Protection/App Group access recovers.
            throw deferredBootstrapError(reason: .lifecycleStateUnavailable)
        }

        // Build 40 and earlier had one `sharing/` directory. Move it into the
        // first catalog slot before resolving PairingState. The catalog commit
        // and directory move are crash-resumable and never merge two rooms.
        do {
            _ = try PrivateWindowCatalogStore
                .bootstrapLegacyMigrationWhileLifecycleLocked()
        } catch {
            // Build 62 could leave the authoritative legacy room beside a
            // cache-only destination. Recover only when exactly one fully
            // validated room also proves its exact Keychain account, then
            // require the ordinary migration bootstrap to succeed again.
            guard let catalog = try PrivateWindowCatalogStore.load() else {
                throw deferredBootstrapError(
                    reason: .privateWindowMigrationUnavailable
                )
            }
            let discovery = try discoverPairedRecoveryCandidateWhileLocked(
                installationMarker: marker,
                targetLocalWindowID: catalog.activeWindowID
            )
            guard case let .unique(candidate) = discovery else {
                throw deferredBootstrapError(
                    reason: .privateWindowMigrationUnavailable
                )
            }
            _ = try promotePairedRecoveryCandidateWhileLocked(
                candidate,
                targetLocalWindowID: catalog.activeWindowID,
                invalidateLifecycle: true
            )
            do {
                _ = try PrivateWindowCatalogStore
                    .bootstrapLegacyMigrationWhileLifecycleLocked()
            } catch {
                throw deferredBootstrapError(
                    reason: .privateWindowMigrationUnavailable
                )
            }
        }

        let state = try loadOrRecoverActiveStateWhileLocked(
            installationMarker: marker
        )

        guard state.installationMarker == marker else {
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap reset",
                metadata: ["sharingFailureReason": "installation-marker-mismatch"]
            )
            let reset = try performCleanupWhileLocked(
                marker: marker,
                message: nil,
                removeAllWindows: true
            )
            return BootstrapResult(
                state: reset,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: true
            )
        }

        // Initial pairing binds its candidate Keychain account into this exact
        // catalog slot before writing the secret. If the process stopped before
        // PairingState committed, an authoritative unpaired state proves only
        // that exact candidate is orphaned. Reclaim it without issuing a broad
        // service query that could delete credentials for another window.
        if state.phase == .unpaired, state.credentialAccount == nil,
           let catalog = try PrivateWindowCatalogStore.load(),
           let activeEntry = catalog.windows.first(where: {
               $0.localWindowID == catalog.activeWindowID
           }),
           let candidateAccount = activeEntry.credentialAccount {
            do {
                try PairingKeychainStore.delete(account: candidateAccount)
                try PrivateWindowCatalogStore
                    .updateActiveMetadataWhileLifecycleLocked(
                        spaceID: state.spaceID,
                        credentialAccount: nil
                    )
            } catch let error as PairingError {
                switch error {
                case .keychainUnavailable:
                    throw deferredBootstrapError(reason: .keychainUnavailable)
                default:
                    throw error
                }
            }
        }

        if let account = state.credentialAccount {
            do {
                _ = try PairingKeychainStore.load(
                    account: account,
                    installationMarker: marker
                )
            } catch let error as PairingKeychainStore.RetryableReadError {
                throw deferredBootstrapError(
                    reason: error.reason == .protectedDataUnavailable
                        ? .keychainProtectedDataUnavailable
                        : .keychainUnavailable
                )
            } catch let error as PairingError {
                let resetMessage: String
                switch error {
                case .malformedCredential:
                    SharedLog.app.warning(
                        "pairing",
                        "Pairing bootstrap reset",
                        metadata: [
                            "sharingFailureReason": "credential-missing-or-malformed"
                        ]
                    )
                    resetMessage = error.errorDescription
                        ?? "保存されている共有鍵を確認できません。再招待が必要です。"
                case .installationChanged:
                    SharedLog.app.warning(
                        "pairing",
                        "Pairing bootstrap reset",
                        metadata: [
                            "sharingFailureReason": "credential-installation-mismatch"
                        ]
                    )
                    resetMessage = error.errorDescription
                        ?? "保存されている共有鍵を確認できません。再招待が必要です。"
                default:
                    // A Keychain access failure is not proof that the item is
                    // absent. Preserve both the credential and PairingState.
                    throw deferredBootstrapError(reason: .keychainUnavailable)
                }
                let reset = try performCleanupWhileLocked(
                    marker: marker,
                    message: resetMessage
                )
                return BootstrapResult(
                    state: reset,
                    lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                    invalidatedPreviousInstallation: true
                )
            } catch {
                // Credential decoding is normalized to malformedCredential by
                // PairingKeychainStore. Anything else is availability-unknown
                // and therefore retryable rather than destructive.
                throw deferredBootstrapError(reason: .keychainUnavailable)
            }
        }
        try? PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked(
            spaceID: state.spaceID,
            credentialAccount: state.credentialAccount
        )
        return BootstrapResult(
            state: state,
            lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
            invalidatedPreviousInstallation: false
        )
    }

    /// Window selection must never move the active path away from a durable
    /// scoped-cleanup intent. Resume the interrupted cleanup under the same
    /// lifecycle lock before a create/switch operation is allowed to mutate
    /// the catalog. This also heals the mismatch produced by older builds.
    private static func finishPendingCleanupBeforeWindowSelectionWhileLocked()
        throws {
        guard try SharingLifecycleGate.cleanupRequiredWhileLocked() else {
            return
        }
        _ = try bootstrapWhileLocked()
        guard try !SharingLifecycleGate.cleanupRequiredWhileLocked() else {
            throw deferredBootstrapError(reason: .lifecycleStateUnavailable)
        }
    }

    /// Pure failure classification. Decode/validation failures prove that the
    /// persisted state cannot safely authorize sharing. File access failures,
    /// including Data Protection, preserve the state for a later retry.
    static func pairingStateLoadFailureDisposition(
        _ error: Error
    ) -> PairingStateLoadFailureDisposition {
        if error is DecodingError || error is PairingStateStore.LoadError {
            return .failClosed
        }
        return .retryable(
            isProtectedDataReadFailure(error)
                ? .pairingStateProtectedDataUnavailable
                : .pairingStateReadUnavailable
        )
    }

    /// Resolves the active catalog slot without treating another independently
    /// paired catalog window as a recovery source. Missing state becomes a new
    /// unpaired document only when the target is structurally empty and every
    /// other retained location is either empty or fully understood.
    private static func loadOrRecoverActiveStateWhileLocked(
        installationMarker: String
    ) throws -> PairingState {
        guard let catalog = try PrivateWindowCatalogStore.load() else {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }
        let targetLocalWindowID = catalog.activeWindowID
        let plan = try selectionPlanWhileLocked(
            targetLocalWindowID: targetLocalWindowID,
            installationMarker: installationMarker,
            rejectInstallationMarkerMismatch: false
        )
        switch plan {
        case let .stored(state):
            return state
        case let .recover(candidate):
            return try promotePairedRecoveryCandidateWhileLocked(
                candidate,
                targetLocalWindowID: targetLocalWindowID,
                invalidateLifecycle: true
            )
        case .initializeEmpty:
            let empty = PairingState.unpaired(
                installationMarker: installationMarker
            )
            try PairingStateStore.saveWhileLifecycleLocked(empty)
            guard let committed = try PairingStateStore.load() else {
                throw PairingError.stateUnavailable
            }
            return committed
        }
    }

    /// Performs a read-only selection preflight. `activatePrivateWindow` calls
    /// this before changing the catalog's active ID or lifecycle epoch, so a
    /// malformed/missing target cannot partially switch the application.
    private static func selectionPlanWhileLocked(
        targetLocalWindowID: String,
        installationMarker: String,
        rejectInstallationMarkerMismatch: Bool
    ) throws -> ActiveWindowSelectionPlan {
        guard let catalog = try PrivateWindowCatalogStore.load(),
              catalog.windows.contains(where: {
                  $0.localWindowID == targetLocalWindowID
              })
        else {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }

        let storedState: PairingState?
        let storedStateWasInvalid: Bool
        do {
            storedState = try PairingStateStore.load(
                localWindowID: targetLocalWindowID
            )
            storedStateWasInvalid = false
        } catch {
            switch pairingStateLoadFailureDisposition(error) {
            case .failClosed:
                storedState = nil
                storedStateWasInvalid = true
            case let .retryable(reason):
                throw deferredBootstrapError(reason: reason)
            }
        }

        if let storedState {
            if storedState.installationMarker != installationMarker {
                if rejectInstallationMarkerMismatch {
                    throw PairingError.installationChanged
                }
                return .stored(storedState)
            }
            guard storedState.phase == .unpaired else {
                return .stored(storedState)
            }
            switch try discoverPairedRecoveryCandidateWhileLocked(
                installationMarker: installationMarker,
                targetLocalWindowID: targetLocalWindowID
            ) {
            case .none:
                return .stored(storedState)
            case .ambiguous:
                throw deferredBootstrapError(
                    reason: .privateWindowMigrationUnavailable
                )
            case let .unique(candidate):
                return .recover(candidate)
            }
        }

        switch try discoverPairedRecoveryCandidateWhileLocked(
            installationMarker: installationMarker,
            targetLocalWindowID: targetLocalWindowID
        ) {
        case .ambiguous:
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        case let .unique(candidate):
            return .recover(candidate)
        case .none:
            guard !storedStateWasInvalid,
                  try targetCanInitializeUnpairedWhileLocked(
                      targetLocalWindowID: targetLocalWindowID
                  )
            else {
                throw deferredBootstrapError(
                    reason: .privateWindowMigrationUnavailable
                )
            }
            return .initializeEmpty
        }
    }

    /// Searches only the selected catalog slot and migration storage that can
    /// be proved to target that same slot. Another catalog window is never an
    /// implicit fallback. Zero or multiple candidates do not mutate storage.
    private static func discoverPairedRecoveryCandidateWhileLocked(
        installationMarker: String,
        targetLocalWindowID: String
    ) throws -> PairedRecoveryDiscovery {
        guard let catalog = try PrivateWindowCatalogStore.load(),
              catalog.windows.contains(where: {
                  $0.localWindowID == targetLocalWindowID
              })
        else {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }
        let locations: [PrivateWindowRecoveryLocation]
        do {
            locations = try PrivateWindowCatalogStore
                .recoveryLocationsWhileLifecycleLocked()
        } catch {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }

        var candidates: [PairedRecoveryCandidate] = []
        for location in locations {
            switch location.kind {
            case let .catalogWindow(localWindowID)
                where localWindowID != targetLocalWindowID:
                continue
            case .legacy:
                let legacyTarget = catalog.pendingLegacyMigrationWindowID
                    ?? catalog.windows.first?.localWindowID
                if legacyTarget != targetLocalWindowID { continue }
            default:
                break
            }
            if let candidate = try pairedRecoveryCandidate(
                at: location,
                installationMarker: installationMarker
            ), recoveryLocation(
                location,
                targets: targetLocalWindowID,
                candidateState: candidate.state,
                catalog: catalog
            ) {
                candidates.append(candidate)
            }
        }
        switch candidates.count {
        case 0:
            return .none
        case 1:
            guard let candidate = candidates.first else { return .none }
            return .unique(candidate)
        default:
            guard recoveryStatesHaveSingleAuthority(
                candidates.map(\.state)
            )
            else { return .ambiguous }

            // Build 63 can quarantine the same authenticated room more than
            // once when an older Widget or Share Extension recreates the
            // legacy directory after migration. Physical copies are not
            // separate authorities: every candidate above has independently
            // proved the same installation marker, Keychain account, room key
            // and immutable member/peer identity. Prefer the highest persisted
            // revision, then the newest timestamp; location and path are only
            // deterministic tie-breakers. The unused copies remain quarantined
            // and are never merged or deleted here.
            guard let preferred = candidates.min(by: {
                recoveryCandidateIsPreferred(
                    $0,
                    over: $1,
                    targetLocalWindowID: targetLocalWindowID
                )
            }) else { return .none }
            SharedLog.app.info(
                "pairing",
                "Equivalent paired recovery copies coalesced"
            )
            return .unique(preferred)
        }
    }

    private static func recoveryCandidateIsPreferred(
        _ lhs: PairedRecoveryCandidate,
        over rhs: PairedRecoveryCandidate,
        targetLocalWindowID: String
    ) -> Bool {
        let lhsRevision = lhs.state.storageRevision ?? 0
        let rhsRevision = rhs.state.storageRevision ?? 0
        if lhsRevision != rhsRevision { return lhsRevision > rhsRevision }
        if lhs.state.lastUpdatedAt != rhs.state.lastUpdatedAt {
            return lhs.state.lastUpdatedAt > rhs.state.lastUpdatedAt
        }

        func rank(_ location: PrivateWindowRecoveryLocation) -> Int {
            switch location.kind {
            case let .catalogWindow(localWindowID):
                return localWindowID == targetLocalWindowID ? 0 : 3
            case .legacy:
                return 1
            case .quarantine:
                return 2
            }
        }

        let lhsRank = rank(lhs.location)
        let rhsRank = rank(rhs.location)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.location.sharingDirectoryURL.standardizedFileURL.path
            < rhs.location.sharingDirectoryURL.standardizedFileURL.path
    }

    private static func recoveryStatesHaveSingleAuthority(
        _ states: [PairingState]
    ) -> Bool {
        guard let first = states.first else { return false }
        return states.dropFirst().allSatisfy {
            sameRecoveryAuthority($0, first)
        }
    }

    private static func promotePairedRecoveryCandidateWhileLocked(
        _ candidate: PairedRecoveryCandidate,
        targetLocalWindowID: String,
        invalidateLifecycle: Bool
    ) throws -> PairingState {
        guard let spaceID = candidate.state.spaceID,
              let credentialAccount = candidate.state.credentialAccount
        else {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }

        do {
            if invalidateLifecycle {
                _ = try SharingLifecycleGate.bumpEpochWhileLocked()
                try DailySharingStateStore
                    .revokeAllSyncLeasesWhileLifecycleLocked()
            }
            _ = try PrivateWindowCatalogStore
                .promoteRecoveryLocationWhileLifecycleLocked(
                    candidate.location,
                    targetLocalWindowID: targetLocalWindowID,
                    spaceID: spaceID,
                    credentialAccount: credentialAccount
                )
            // A quarantined source can carry its pre-recovery logical lease
            // into the destination. The epoch already rejects its owner; this
            // second bounded revoke removes the moved stale lease record.
            try DailySharingStateStore
                .revokeAllSyncLeasesWhileLifecycleLocked()
        } catch {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }

        let recovered: PairingState
        do {
            guard let state = try PairingStateStore.load() else {
                throw PairingError.stateUnavailable
            }
            recovered = state
        } catch {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }
        guard recovered.phase == .paired,
              sameRecoveryAuthority(recovered, candidate.state)
        else {
            throw deferredBootstrapError(
                reason: .privateWindowMigrationUnavailable
            )
        }
        SharedLog.app.info(
            "pairing",
            "Paired sharing state recovered"
        )
        return recovered
    }

    private static func recoveryLocation(
        _ location: PrivateWindowRecoveryLocation,
        targets targetLocalWindowID: String,
        candidateState: PairingState,
        catalog: PrivateWindowCatalogState
    ) -> Bool {
        guard let target = catalog.windows.first(where: {
            $0.localWindowID == targetLocalWindowID
        }) else { return false }
        switch location.kind {
        case let .catalogWindow(localWindowID):
            return localWindowID == targetLocalWindowID
        case .legacy:
            let legacyTarget = catalog.pendingLegacyMigrationWindowID
                ?? catalog.windows.first?.localWindowID
            return legacyTarget == targetLocalWindowID
        case .quarantine:
            if catalog.pendingLegacyMigrationWindowID == targetLocalWindowID {
                return true
            }
            if let spaceID = target.spaceID,
               let credentialAccount = target.credentialAccount {
                return candidateState.spaceID == spaceID
                    && candidateState.credentialAccount == credentialAccount
            }
            // Build 63 could move the original Build 40 owner into quarantine
            // before committing that first catalog entry's metadata. With
            // multiple windows, the append-only first slot is still the sole
            // legacy owner, but only while it is also the explicitly active
            // target. Never use this rule to switch to another catalog slot.
            guard catalog.activeWindowID == targetLocalWindowID,
                  catalog.windows.first?.localWindowID == targetLocalWindowID
            else { return catalog.windows.count == 1 }
            // If the authenticated state already belongs to a different,
            // metadata-bound catalog entry, it is not the first slot's legacy
            // recovery even though both happen to share the quarantine root.
            let belongsToAnotherCatalogWindow = catalog.windows.contains {
                $0.localWindowID != targetLocalWindowID
                    && $0.spaceID == candidateState.spaceID
                    && $0.credentialAccount == candidateState.credentialAccount
            }
            return !belongsToAnotherCatalogWindow
        }
    }

    private static func pairedRecoveryCandidate(
        at location: PrivateWindowRecoveryLocation,
        installationMarker: String
    ) throws -> PairedRecoveryCandidate? {
        guard let state = try validatedRecoveryState(at: location),
              state.phase == .paired,
              state.installationMarker == installationMarker,
              let credential = try recoveryCredential(for: state),
              try credentialMatchesRecoveryState(credential, state: state)
        else { return nil }
        return PairedRecoveryCandidate(location: location, state: state)
    }

    private static func validatedRecoveryState(
        at location: PrivateWindowRecoveryLocation
    ) throws -> PairingState? {
        let stateURL = location.sharingDirectoryURL.appendingPathComponent(
            "pairing-state.json",
            isDirectory: false
        )
        let data: Data
        do {
            data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
        } catch {
            if SharingFileReadFailureClassifier.disposition(error) == .missing {
                return nil
            }
            throw deferredBootstrapError(
                reason: isProtectedDataReadFailure(error)
                    ? .pairingStateProtectedDataUnavailable
                    : .pairingStateReadUnavailable
            )
        }
        guard SharingSecureFile.hasRequiredProtectionAndBackupExclusion(
                  location.sharingDirectoryURL
              ),
              SharingSecureFile.hasRequiredProtectionAndBackupExclusion(stateURL)
        else { return nil }

        let state: PairingState
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(PairingState.self, from: data)
                .validated()
        } catch {
            return nil
        }
        return state
    }

    private static func recoveryCredential(
        for state: PairingState
    ) throws -> PairingCredential? {
        guard let credentialAccount = state.credentialAccount else {
            return nil
        }
        do {
            return try PairingKeychainStore.load(
                account: credentialAccount,
                installationMarker: state.installationMarker
            )
        } catch let error as PairingKeychainStore.RetryableReadError {
            throw deferredBootstrapError(
                reason: error.reason == .protectedDataUnavailable
                    ? .keychainProtectedDataUnavailable
                    : .keychainUnavailable
            )
        } catch let error as PairingError {
            switch error {
            case .malformedCredential, .installationChanged:
                return nil
            default:
                throw deferredBootstrapError(reason: .keychainUnavailable)
            }
        } catch {
            throw deferredBootstrapError(reason: .keychainUnavailable)
        }
    }

    /// Proves that the Keychain item is the local authority described by the
    /// pairing document, not merely an item stored under the same account UUID.
    private static func credentialMatchesRecoveryState(
        _ credential: PairingCredential,
        state: PairingState
    ) throws -> Bool {
        guard credential.account == state.credentialAccount,
              credential.installationMarker == state.installationMarker,
              credential.participantIDString == state.participantID
        else { return false }

        if let resolvedDeviceID = state.resolvedLocalMomentDeviceID {
            if let credentialDeviceID = credential.deviceID {
                guard credentialDeviceID == resolvedDeviceID else { return false }
            }
            // Build 41/61 recovery credentials can predate the deviceID
            // backfill even though their paired state already resolves to a
            // recovered/additional device. The account, installation marker,
            // participant and room-key-bearing Keychain item remain the
            // stable authority in that legacy shape. When deviceID is present
            // it is always required to match exactly.
        }

        guard state.phase == .paired else { return true }
        guard credential.roomKey != nil else { return false }
        let agreementPublicKey = try PairingCrypto
            .agreementPublicKey(for: credential)
            .base64URLEncodedString()
        let signingPublicKey = try PairingCrypto
            .signingPublicKey(for: credential)
            .base64URLEncodedString()

        if let invitationID = state.invitationID,
           let enrollmentID = state.enrollmentID,
           let spaceID = state.spaceID,
           let dailyBoundaryMinuteUTC = state.dailyBoundaryMinuteUTC,
           let memberID = state.memberID,
           let peerMemberID = state.peerMemberID,
           let peerParticipantID = state.peerParticipantID,
           let peerAgreementPublicKey = state.peerAgreementPublicKey,
           let peerSigningPublicKey = state.peerSigningPublicKey,
           let role = state.role,
           let encodedTranscript = state.transcript.flatMap({
               Data(base64URLString: $0)
           }) {
            let local = PairingMemberIdentity(
                memberID: memberID,
                participantID: credential.participantIDString,
                agreementPublicKey: agreementPublicKey,
                signingPublicKey: signingPublicKey
            )
            let peer = PairingMemberIdentity(
                memberID: peerMemberID,
                participantID: peerParticipantID,
                agreementPublicKey: peerAgreementPublicKey,
                signingPublicKey: peerSigningPublicKey
            )
            let transcript = PairingVerificationTranscript(
                spaceID: spaceID,
                invitationID: invitationID,
                enrollmentID: enrollmentID,
                dailyBoundaryMinuteUTC: dailyBoundaryMinuteUTC,
                inviter: role == .inviter ? local : peer,
                invitee: role == .inviter ? peer : local
            )
            return try transcript.canonicalData() == encodedTranscript
        }

        // A paired recovery/additional-device state from Build 41/61 may not
        // retain the original invitation transcript. Do not use
        // recoveryCandidate* as a fallback: a recovered iPhone can later
        // sponsor another iPhone, and those fields then describe the new
        // candidate rather than this installation. The Keychain lookup was
        // already scoped by account and installation marker above, and we
        // additionally bound participantID, room-key presence, and deviceID
        // whenever the legacy credential has one.
        return true
    }

    private static func targetCanInitializeUnpairedWhileLocked(
        targetLocalWindowID: String
    ) throws -> Bool {
        guard let catalog = try PrivateWindowCatalogStore.load(),
              let target = catalog.windows.first(where: {
                  $0.localWindowID == targetLocalWindowID
              }),
              target.spaceID == nil,
              target.credentialAccount == nil
        else { return false }
        let locations = try PrivateWindowCatalogStore
            .recoveryLocationsWhileLifecycleLocked()
        let targetLocation = locations.first {
            if case let .catalogWindow(localWindowID) = $0.kind {
                return localWindowID == targetLocalWindowID
            }
            return false
        }
        if let targetLocation {
            guard try recoveryDirectoryIsSafeForUnpairedInitialization(
                targetLocation.sharingDirectoryURL
            )
            else { return false }
        } else {
            guard let targetDirectory = SharedContainer.windowSharingDirectoryURL(
                localWindowID: targetLocalWindowID
            ), try recoveryDirectoryIsAbsentOrSafeForUnpairedInitialization(
                targetDirectory
            )
            else { return false }
        }

        // Another catalog slot is an independent user-selected authority. Its
        // files and Keychain availability cannot decide whether this empty
        // target may initialize. Only migration storage that can belong to the
        // selected target is inspected conservatively below.
        for location in locations {
            switch location.kind {
            case .catalogWindow:
                continue
            case .legacy:
                let legacyTarget = catalog.pendingLegacyMigrationWindowID
                    ?? catalog.windows.first?.localWindowID
                if legacyTarget != targetLocalWindowID {
                    continue
                }
            case .quarantine:
                if let state = try? validatedRecoveryState(at: location),
                   !recoveryLocation(
                       location,
                       targets: targetLocalWindowID,
                       candidateState: state,
                       catalog: catalog
                   ) {
                    continue
                }
            }
            guard try recoveryDirectoryIsSafeForUnpairedInitialization(
                location.sharingDirectoryURL
            ) else { return false }
        }
        return true
    }

    private static let maximumSafeAtomicResidueCount = 16
    private static let maximumSafeAtomicResidueBytes = 4 * 1_024 * 1_024
    private static let maximumSafeAtomicResidueTotalBytes = 16 * 1_024 * 1_024

    /// Treats only bounded, fully protected AtomicJSON crash inodes as empty.
    /// They contain no committed filename/authority and are overwritten by no
    /// recovery path. Unknown entries, directories and symlinks remain a
    /// retryable ambiguity and are preserved untouched.
    private static func recoveryDirectoryIsSafeForUnpairedInitialization(
        _ directory: URL
    ) throws -> Bool {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: []
            )
        } catch {
            throw deferredBootstrapError(
                reason: isProtectedDataReadFailure(error)
                    ? .pairingStateProtectedDataUnavailable
                    : .pairingStateReadUnavailable
            )
        }
        guard entries.count <= maximumSafeAtomicResidueCount else { return false }
        guard !entries.isEmpty else { return true }
        guard SharingSecureFile.hasRequiredProtectionAndBackupExclusion(directory)
        else { return false }

        var totalBytes = 0
        for entry in entries {
            let name = entry.lastPathComponent
            let prefix = ".sharing-secure-"
            guard name.hasPrefix(prefix),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let values = try? entry.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maximumSafeAtomicResidueBytes,
                  SharingSecureFile.hasRequiredProtectionAndBackupExclusion(entry)
            else { return false }
            totalBytes += fileSize
            guard totalBytes <= maximumSafeAtomicResidueTotalBytes else {
                return false
            }
        }
        return true
    }

    private static func recoveryDirectoryIsAbsentOrSafeForUnpairedInitialization(
        _ directory: URL
    ) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return true }
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]), values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        return try recoveryDirectoryIsSafeForUnpairedInitialization(directory)
    }

#if DEBUG
    static func runtimeTestRecoveryStatesHaveSingleAuthority(
        _ states: [PairingState]
    ) -> Bool {
        recoveryStatesHaveSingleAuthority(states)
    }

    static func runtimeTestRecoveryDirectoryIsSafeForUnpairedInitialization(
        _ directory: URL
    ) -> Bool {
        (try? recoveryDirectoryIsSafeForUnpairedInitialization(directory)) == true
    }

    static func runtimeTestTargetCanInitializeUnpairedWhileLocked(
        localWindowID: String
    ) -> Bool {
        (try? targetCanInitializeUnpairedWhileLocked(
            targetLocalWindowID: localWindowID
        )) == true
    }

    static func runtimeTestCredentialMatchesRecoveryState(
        _ credential: PairingCredential,
        state: PairingState
    ) -> Bool {
        (try? credentialMatchesRecoveryState(credential, state: state)) == true
    }
#endif

    private static func sameRecoveryAuthority(
        _ lhs: PairingState,
        _ rhs: PairingState
    ) -> Bool {
        lhs.installationMarker == rhs.installationMarker
            && lhs.role == rhs.role
            && lhs.credentialAccount == rhs.credentialAccount
            && lhs.participantID == rhs.participantID
            && lhs.spaceID == rhs.spaceID
            && lhs.memberID == rhs.memberID
            && lhs.resolvedLocalMomentDeviceID == rhs.resolvedLocalMomentDeviceID
            && lhs.dailyBoundaryMinuteUTC == rhs.dailyBoundaryMinuteUTC
            && (lhs.localDeviceIsAdditional ?? false) ==
                (rhs.localDeviceIsAdditional ?? false)
            && lhs.canonicalParticipantSigningPublicKey
                == rhs.canonicalParticipantSigningPublicKey
            && lhs.peerMemberID == rhs.peerMemberID
            && lhs.peerParticipantID == rhs.peerParticipantID
            && lhs.peerAgreementPublicKey == rhs.peerAgreementPublicKey
            && lhs.peerSigningPublicKey == rhs.peerSigningPublicKey
    }

    private static func isProtectedDataReadFailure(
        _ error: Error,
        recursionDepth: Int = 0
    ) -> Bool {
        guard recursionDepth < 4 else { return false }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain,
           value.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if value.domain == NSPOSIXErrorDomain,
           value.code == Int(EACCES) || value.code == Int(EPERM) {
            return true
        }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
            return isProtectedDataReadFailure(
                underlying,
                recursionDepth: recursionDepth + 1
            )
        }
        return false
    }

    private static func deferredBootstrapError(
        reason: RetryableBootstrapReason
    ) -> RetryableBootstrapError {
        switch reason {
        case .installationMarkerReadUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: [
                    "sharingFailureReason": "installation-marker-read-unavailable"
                ]
            )
        case .lifecycleStateUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: [
                    "sharingFailureReason": "lifecycle-state-unavailable"
                ]
            )
        case .pairingStateProtectedDataUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: [
                    "sharingFailureReason": "pairing-state-protected-data-unavailable"
                ]
            )
        case .pairingStateReadUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: [
                    "sharingFailureReason": "pairing-state-read-unavailable"
                ]
            )
        case .privateWindowMigrationUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: [
                    "sharingFailureReason":
                        "private-window-migration-unavailable"
                ]
            )
        case .keychainProtectedDataUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: [
                    "sharingFailureReason": "keychain-protected-data-unavailable"
                ]
            )
        case .keychainUnavailable:
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap deferred",
                metadata: ["sharingFailureReason": "keychain-unavailable"]
            )
        }
        return RetryableBootstrapError(reason: reason)
    }

    /// Called only after an authenticated sharing endpoint proves this member
    /// was revoked or physically removed. The sync lease must already have
    /// been released by the caller. Preserve the ordinary-container marker so
    /// this is a clean re-pair, while deleting every room capability and all
    /// shared-media ciphertext before publishing the unpaired state.
    static func resetAfterRemoteRevocation(
        expectedState: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let marker = try readLocalMarker(),
                  let fresh = try PairingStateStore.load(),
                  marker == expectedState.installationMarker,
                  samePairingIdentity(fresh, expectedState)
            else { return }
            _ = try performCleanupWhileLocked(
                marker: marker,
                message: "共有が解除されたため、もう一度招待してください。"
            )
        }
    }

    static func resetAfterRemoteRevocationAsync(
        expectedState: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try resetAfterRemoteRevocation(
                expectedState: expectedState,
                lifecycleToken: lifecycleToken
            )
        }.value
    }

    private static func samePairingIdentity(
        _ lhs: PairingState,
        _ rhs: PairingState
    ) -> Bool {
        lhs.installationMarker == rhs.installationMarker
            && lhs.credentialAccount == rhs.credentialAccount
            && lhs.spaceID == rhs.spaceID
            && lhs.memberID == rhs.memberID
            && lhs.participantID == rhs.participantID
            && lhs.credentialAccount != nil
            && lhs.spaceID != nil
            && lhs.memberID != nil
            && lhs.participantID != nil
    }

    @discardableResult
    static func resetLocalSharing(
        expectedState: PairingState,
        lifecycleToken: SharingLifecycleGate.Token,
        message: String? = nil
    ) throws -> PairingState {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let marker = try readLocalMarker(),
                  let state = try PairingStateStore.load(),
                  state.installationMarker == marker,
                  state == expectedState
            else { throw PairingError.stateUnavailable }
            return try performCleanupWhileLocked(marker: marker, message: message)
        }
    }

    static func resetLocalSharingAsync(
        expectedState: PairingState,
        lifecycleToken: SharingLifecycleGate.Token,
        message: String? = nil
    ) async throws -> PairingState {
        try await Task.detached(priority: .userInitiated) {
            try resetLocalSharing(
                expectedState: expectedState,
                lifecycleToken: lifecycleToken,
                message: message
            )
        }.value
    }

    /// Caller holds the stable lifecycle flock. Publishing the tombstone,
    /// incrementing the epoch, and removing the logical lease happen before
    /// any credential/cache deletion. An in-flight result therefore fails its
    /// next renew/commit even if this cleanup is interrupted and later resumed.
    private static func performCleanupWhileLocked(
        marker: String,
        message: String?,
        removeAllWindows: Bool = false
    ) throws -> PairingState {
        // This is one crash-recoverable transaction. A scoped intent is
        // durable before the tombstone; no destructive mutation starts until
        // the tombstone exists, and it is cleared only after unpaired state.
        let scopedEntry: PrivateWindowCatalogEntry?
        if removeAllWindows {
            scopedEntry = nil
            try deleteWindowCleanupScopeWhileLocked()
        } else {
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let entry = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  })
            else { throw PairingError.stateUnavailable }
            scopedEntry = entry
            try writeWindowCleanupScopeWhileLocked(
                WindowCleanupScope(localWindowID: entry.localWindowID)
            )
        }
        try SharingLifecycleGate.markCleanupRequired()
        _ = try SharingLifecycleGate.bumpEpochWhileLocked()
        try DailySharingStateStore.revokeAllSyncLeasesWhileLifecycleLocked()
        let activeState: PairingState?
        let activeCredentialAccount: String?
        if removeAllWindows {
            activeState = nil
            activeCredentialAccount = nil
        } else {
            // Read availability failures are retryable and never destructive.
            // Positive schema/integrity corruption is different: the valid
            // catalog still identifies one exact local slot and its exact
            // Keychain account, so isolate that slot without re-reading the
            // corrupt bytes forever or touching another window.
            do {
                activeState = try PairingStateStore.load()
            } catch PairingStateStore.LoadError.invalidState {
                activeState = nil
            } catch {
                throw error
            }
            activeCredentialAccount = activeState?.credentialAccount
                ?? scopedEntry?.credentialAccount
            guard let activeWindowID = scopedEntry?.localWindowID
            else { throw PairingError.stateUnavailable }
            let binding: Data?
            if let activeState,
               let spaceID = activeState.spaceID,
               let participantID = activeState.participantID {
                binding = try MomentShareHandoffStore.makeBindingSHA256(
                    installationMarker: activeState.installationMarker,
                    spaceID: spaceID,
                    participantID: participantID
                )
            } else {
                binding = nil
            }
            try MomentShareHandoffStore.revokeAdmissionWhileLifecycleLocked(
                localWindowID: activeWindowID,
                bindingSHA256: binding
            )
        }
        if removeAllWindows {
            try PairingKeychainStore.deleteAllSharingCredentials()
        } else if let activeCredentialAccount {
            try PairingKeychainStore.delete(account: activeCredentialAccount)
        }
        try? PairingStateStore.delete()
        try purgeSharedCache(removeAllWindows: removeAllWindows)
        if removeAllWindows {
            _ = try PrivateWindowCatalogStore.resetAllWhileLifecycleLocked()
        }
        var reset = PairingState.unpaired(installationMarker: marker)
        reset.lastError = message
        try PairingStateStore.saveWhileLifecycleLocked(reset)
        try? PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked(
            spaceID: nil,
            credentialAccount: nil
        )
        try SharingLifecycleGate.clearCleanupRequired()
        try deleteWindowCleanupScopeWhileLocked()
        // Return the exact decoded value (not the pre-encoding Date value), so
        // the first CAS after reset compares against the bytes on disk.
        guard let committed = try PairingStateStore.load() else {
            throw PairingError.stateUnavailable
        }
        return committed
    }

    private static func readWindowCleanupScopeWhileLocked() throws
        -> WindowCleanupScope? {
        guard let url = SharedContainer.sharingCleanupScopeURL else {
            throw PairingError.stateUnavailable
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try JSONDecoder().decode(WindowCleanupScope.self, from: data)
                .validated()
        } catch {
            guard SharingFileReadFailureClassifier.disposition(error) == .missing
            else { throw PairingError.stateUnavailable }
            return nil
        }
    }

    private static func writeWindowCleanupScopeWhileLocked(
        _ scope: WindowCleanupScope
    ) throws {
        guard let url = SharedContainer.sharingCleanupScopeURL else {
            throw PairingError.stateUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(
            try encoder.encode(try scope.validated()),
            to: url
        )
    }

    private static func deleteWindowCleanupScopeWhileLocked() throws {
        guard let url = SharedContainer.sharingCleanupScopeURL else {
            throw PairingError.stateUnavailable
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            guard SharingFileReadFailureClassifier.disposition(error) == .missing
            else { throw error }
        }
    }

    private static func markerURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("NekoWidget", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(markerFileName, isDirectory: false)
    }

    private static func readLocalMarker() throws -> String? {
        let url = try markerURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard SharingFileReadFailureClassifier.disposition(error) == .missing else {
                throw error
            }
            return nil
        }
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        let value = decoded
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private static func readLocalMarkerForBootstrap() throws -> String? {
        do {
            return try readLocalMarker()
        } catch {
            throw deferredBootstrapError(reason: .installationMarkerReadUnavailable)
        }
    }

    private static func writeLocalMarker(_ marker: String) throws {
        let url = try markerURL()
        try SharingSecureFile.write(Data(marker.utf8), to: url)
    }

    private static func purgeSharedCache(removeAllWindows: Bool = false) throws {
        var firstError: Error?
        let directories: [URL] = {
            if removeAllWindows {
                return [
                    SharedContainer.privateWindowsDirectoryURL,
                    SharedContainer.legacySharingCacheDirectoryURL,
                ].compactMap { $0 }
            }
            return [SharedContainer.sharingCacheDirectoryURL].compactMap { $0 }
        }()
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            // These directories are deliberately narrower than the App Group
            // root. They cannot remove personal photo scans, likes, or logs.
            do { try FileManager.default.removeItem(at: directory) }
            catch { if firstError == nil { firstError = error } }
        }
        for name in [
            "NekoWidgetMomentHandoffModeration",
            "NekoWidgetMomentInboundModeration"
        ] {
            let moderationDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: moderationDirectory.path) {
                do {
                    try FileManager.default.removeItem(at: moderationDirectory)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
    }
}
