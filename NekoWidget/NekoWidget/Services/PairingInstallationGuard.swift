import Foundation

/// Binds sharing credentials to this installation. Keychain items can survive
/// app deletion, so the Keychain alone must never be treated as proof that the
/// current installation is authorized to reuse a room key.
enum PairingInstallationGuard {
    private static let markerFileName = "sharing-installation-marker.v1"

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

    private static func bootstrapWhileLocked() throws -> BootstrapResult {
        if SharingLifecycleGate.isCleanupRequired {
            let marker = try readLocalMarker() ?? UUID().uuidString
            if try readLocalMarker() == nil { try writeLocalMarker(marker) }
            let reset = try performCleanupWhileLocked(
                marker: marker,
                message: "共有の削除処理を完了しました。もう一度招待できます。"
            )
            return BootstrapResult(
                state: reset,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: true
            )
        }
        let existingState = try? PairingStateStore.load()
        guard let marker = try readLocalMarker() else {
            // A missing ordinary-container marker means first install or
            // reinstall. In both cases all App Group/Keychain remnants are
            // untrusted and must be removed before any network operation.
            let newMarker = UUID().uuidString
            try writeLocalMarker(newMarker)
            let state = try performCleanupWhileLocked(marker: newMarker, message: nil)
            return BootstrapResult(
                state: state,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: existingState != nil
            )
        }

        do {
            _ = try SharingLifecycleGate.currentEpochWhileLocked()
        } catch {
            let reset = try performCleanupWhileLocked(
                marker: marker,
                message: "共有の保護状態を復旧しました。もう一度招待してください。"
            )
            return BootstrapResult(
                state: reset,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: true
            )
        }

        let loadedState: PairingState?
        do {
            loadedState = try PairingStateStore.load()
        } catch {
            let reset = try performCleanupWhileLocked(marker: marker, message: nil)
            return BootstrapResult(
                state: reset,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: true
            )
        }

        guard let state = loadedState else {
            // Orphaned Keychain items have no non-secret state binding them to
            // a space. Delete only this app's sharing service.
            let state = try performCleanupWhileLocked(marker: marker, message: nil)
            return BootstrapResult(
                state: state,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: false
            )
        }

        guard state.installationMarker == marker else {
            let reset = try performCleanupWhileLocked(marker: marker, message: nil)
            return BootstrapResult(
                state: reset,
                lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                invalidatedPreviousInstallation: true
            )
        }

        if state.phase == .unpaired, state.credentialAccount == nil {
            // create/join writes Keychain before publishing its state binding.
            // A crash between those two writes can therefore leave an orphan;
            // an explicitly unpaired state proves no sharing credential is live.
            try PairingKeychainStore.deleteAllSharingCredentials()
        }

        if let account = state.credentialAccount {
            do {
                _ = try PairingKeychainStore.load(
                    account: account,
                    installationMarker: marker
                )
            } catch {
                let reset = try performCleanupWhileLocked(
                    marker: marker,
                    message: PairingError.malformedCredential.localizedDescription
                )
                return BootstrapResult(
                    state: reset,
                    lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
                    invalidatedPreviousInstallation: true
                )
            }
        }
        return BootstrapResult(
            state: state,
            lifecycleToken: try SharingLifecycleGate.issueTokenWhileLocked(),
            invalidatedPreviousInstallation: false
        )
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
        message: String?
    ) throws -> PairingState {
        // This is one crash-recoverable transaction. The tombstone is always
        // first and is cleared only after an unpaired state is durable.
        try SharingLifecycleGate.markCleanupRequired()
        _ = try SharingLifecycleGate.bumpEpochWhileLocked()
        try DailySharingStateStore.revokeAllSyncLeasesWhileLifecycleLocked()
        try PairingKeychainStore.deleteAllSharingCredentials()
        try? PairingStateStore.delete()
        try purgeSharedCache()
        var reset = PairingState.unpaired(installationMarker: marker)
        reset.lastError = message
        try PairingStateStore.saveWhileLifecycleLocked(reset)
        try SharingLifecycleGate.clearCleanupRequired()
        // Return the exact decoded value (not the pre-encoding Date value), so
        // the first CAS after reset compares against the bytes on disk.
        guard let committed = try PairingStateStore.load() else {
            throw PairingError.stateUnavailable
        }
        return committed
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
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private static func writeLocalMarker(_ marker: String) throws {
        let url = try markerURL()
        try SharingSecureFile.write(Data(marker.utf8), to: url)
    }

    private static func purgeSharedCache() throws {
        guard let directory = SharedContainer.sharingCacheDirectoryURL,
              FileManager.default.fileExists(atPath: directory.path)
        else { return }
        // This directory is deliberately narrower than the App Group root. It
        // cannot remove the photo scan, personal likes, logs, or widget cache.
        try FileManager.default.removeItem(at: directory)
    }
}
