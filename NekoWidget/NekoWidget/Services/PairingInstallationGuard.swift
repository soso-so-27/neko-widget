import Foundation

/// Binds sharing credentials to this installation. Keychain items can survive
/// app deletion, so the Keychain alone must never be treated as proof that the
/// current installation is authorized to reuse a room key.
enum PairingInstallationGuard {
    private static let markerFileName = "sharing-installation-marker.v1"

    struct BootstrapResult {
        let state: PairingState
        let invalidatedPreviousInstallation: Bool
    }

    static func bootstrap() throws -> BootstrapResult {
        let existingState = try? PairingStateStore.load()
        guard let marker = try readLocalMarker() else {
            // A missing ordinary-container marker means first install or
            // reinstall. In both cases all App Group/Keychain remnants are
            // untrusted and must be removed before any network operation.
            try PairingKeychainStore.deleteAllSharingCredentials()
            try? PairingStateStore.delete()
            try purgeSharedCache()

            let newMarker = UUID().uuidString
            try writeLocalMarker(newMarker)
            let state = PairingState.unpaired(installationMarker: newMarker)
            try PairingStateStore.save(state)
            return BootstrapResult(
                state: state,
                invalidatedPreviousInstallation: existingState != nil
            )
        }

        let loadedState: PairingState?
        do {
            loadedState = try PairingStateStore.load()
        } catch {
            try PairingKeychainStore.deleteAllSharingCredentials()
            try? PairingStateStore.delete()
            try purgeSharedCache()
            let reset = PairingState.unpaired(installationMarker: marker)
            try PairingStateStore.save(reset)
            return BootstrapResult(state: reset, invalidatedPreviousInstallation: true)
        }

        guard let state = loadedState else {
            // Orphaned Keychain items have no non-secret state binding them to
            // a space. Delete only this app's sharing service.
            try PairingKeychainStore.deleteAllSharingCredentials()
            let state = PairingState.unpaired(installationMarker: marker)
            try PairingStateStore.save(state)
            return BootstrapResult(state: state, invalidatedPreviousInstallation: false)
        }

        guard state.installationMarker == marker else {
            try PairingKeychainStore.deleteAllSharingCredentials()
            try? PairingStateStore.delete()
            try purgeSharedCache()
            let reset = PairingState.unpaired(installationMarker: marker)
            try PairingStateStore.save(reset)
            return BootstrapResult(state: reset, invalidatedPreviousInstallation: true)
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
                try PairingKeychainStore.deleteAllSharingCredentials()
                try? PairingStateStore.delete()
                try purgeSharedCache()
                var reset = PairingState.unpaired(installationMarker: marker)
                reset.lastError = PairingError.malformedCredential.localizedDescription
                try PairingStateStore.save(reset)
                return BootstrapResult(state: reset, invalidatedPreviousInstallation: true)
            }
        }
        return BootstrapResult(state: state, invalidatedPreviousInstallation: false)
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
        try Data(marker.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
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
