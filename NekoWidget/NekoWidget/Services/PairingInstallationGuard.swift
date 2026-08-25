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

    enum RetryableBootstrapReason: String, Equatable, Sendable {
        case installationMarkerReadUnavailable =
            "installation-marker-read-unavailable"
        case lifecycleStateUnavailable = "lifecycle-state-unavailable"
        case pairingStateProtectedDataUnavailable =
            "pairing-state-protected-data-unavailable"
        case pairingStateReadUnavailable = "pairing-state-read-unavailable"
        case keychainProtectedDataUnavailable =
            "keychain-protected-data-unavailable"
        case keychainUnavailable = "keychain-unavailable"
    }

    struct RetryableBootstrapError: LocalizedError, Equatable, Sendable {
        let reason: RetryableBootstrapReason

        var errorDescription: String? {
            "共有の状態を一時的に確認できませんでした。iPhoneのロックを解除したまま、もう一度お試しください。"
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

    /// Selects an existing catalog slot. Missing or malformed target state is
    /// never substituted with another room; a genuinely new empty slot gets a
    /// fresh unpaired state bound to the current installation marker.
    static func activatePrivateWindow(localWindowID: String) throws -> BootstrapResult {
        try SharingLifecycleGate.withExclusive {
            guard let marker = try readLocalMarker() else {
                throw PairingError.installationChanged
            }
            _ = try PrivateWindowCatalogStore
                .bootstrapLegacyMigrationWhileLifecycleLocked()
            _ = try SharingLifecycleGate.bumpEpochWhileLocked()
            try DailySharingStateStore.revokeAllSyncLeasesWhileLifecycleLocked()
            _ = try PrivateWindowCatalogStore.activateWhileLifecycleLocked(
                localWindowID: localWindowID
            )
            let state: PairingState
            if let stored = try PairingStateStore.load() {
                guard stored.installationMarker == marker else {
                    throw PairingError.installationChanged
                }
                state = stored
            } else {
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
                      catalog.activeWindowID == cleanupScope.localWindowID
                else {
                    throw deferredBootstrapError(
                        reason: .pairingStateReadUnavailable
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
            throw deferredBootstrapError(reason: .pairingStateReadUnavailable)
        }

        let loadedState: PairingState?
        do {
            loadedState = try PairingStateStore.load()
        } catch {
            switch pairingStateLoadFailureDisposition(error) {
            case .failClosed:
                SharedLog.app.warning(
                    "pairing",
                    "Pairing bootstrap reset",
                    metadata: ["sharingFailureReason": "pairing-state-invalid"]
                )
                let reset = try performCleanupWhileLocked(marker: marker, message: nil)
                return BootstrapResult(
                    state: reset,
                    lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                    invalidatedPreviousInstallation: true
                )
            case let .retryable(reason):
                throw deferredBootstrapError(reason: reason)
            }
        }

        guard let state = loadedState else {
            // Orphaned Keychain items have no non-secret state binding them to
            // a space. Delete only this app's sharing service.
            SharedLog.app.warning(
                "pairing",
                "Pairing bootstrap reset",
                metadata: ["sharingFailureReason": "pairing-state-missing"]
            )
            let state = try performCleanupWhileLocked(marker: marker, message: nil)
            return BootstrapResult(
                state: state,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: false
            )
        }

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
