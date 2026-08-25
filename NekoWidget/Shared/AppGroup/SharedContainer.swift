import Foundation

/// One device-local slot for an independently paired private window.
///
/// `localWindowID` is deliberately unrelated to the relay's opaque `spaceID`.
/// The latter is filled only after pairing, while the local ID is safe to use
/// in App Group paths and persisted Widget configuration before a peer joins.
struct PrivateWindowCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    let localWindowID: String
    var displayName: String
    var spaceID: String?
    var credentialAccount: String?
    let createdAt: Date
    var updatedAt: Date

    var id: String { localWindowID }

    func validated() throws -> Self {
        guard let uuid = UUID(uuidString: localWindowID),
              uuid.uuidString.lowercased() == localWindowID.lowercased(),
              PrivateWindowDisplayName.isValid(displayName),
              spaceID == nil || spaceID.map(Self.isOpaqueIdentifier) == true,
              credentialAccount == nil
                || credentialAccount.flatMap(UUID.init(uuidString:)) != nil,
              createdAt > Date(timeIntervalSince1970: 0),
              updatedAt >= createdAt
        else { throw PrivateWindowCatalogStore.Error.invalidCatalog }
        return self
    }

    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
        }
    }
}

struct PrivateWindowCatalogState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumWindowCount = 20

    var schemaVersion: Int = Self.schemaVersion
    var storageRevision: Int = 0
    var activeWindowID: String
    var windows: [PrivateWindowCatalogEntry]
    /// Crash-resumable marker for the one-time Build 40 `sharing/` move. The
    /// catalog is committed first; readers keep using the legacy directory
    /// until the destination exists, then bootstrap clears this marker.
    var pendingLegacyMigrationWindowID: String?

    func validated() throws -> Self {
        let pairedSpaceIDs = windows.compactMap(\.spaceID)
        let credentialAccounts = windows.compactMap(\.credentialAccount)
        guard schemaVersion == Self.schemaVersion,
              storageRevision >= 0,
              (1...Self.maximumWindowCount).contains(windows.count),
              Set(windows.map(\.localWindowID)).count == windows.count,
              Set(pairedSpaceIDs).count == pairedSpaceIDs.count,
              Set(credentialAccounts).count == credentialAccounts.count,
              windows.contains(where: { $0.localWindowID == activeWindowID }),
              pendingLegacyMigrationWindowID == nil
                || pendingLegacyMigrationWindowID == activeWindowID
        else { throw PrivateWindowCatalogStore.Error.invalidCatalog }
        _ = try windows.map { try $0.validated() }
        return self
    }
}

/// One bounded location that may still contain the authoritative pairing
/// document after a crash or a legacy-directory migration conflict. The type
/// deliberately carries paths only; PairingState and Keychain validation stay
/// in the containing app and are never linked into Widget/Share targets.
struct PrivateWindowRecoveryLocation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case catalogWindow(localWindowID: String)
        case legacy
        case quarantine
    }

    let kind: Kind
    let sharingDirectoryURL: URL
}

/// Device-local catalog for multiple private windows.
///
/// Mutations are performed only while the existing sharing lifecycle flock is
/// held. Reads are atomic and fail closed: a present but malformed catalog can
/// never silently fall back to Build 40's `sharing/` and expose another room.
enum PrivateWindowCatalogStore {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidCatalog
        case windowLimitReached
        case unknownWindow
        case conflictingLegacyMigration
    }

    static func load() throws -> PrivateWindowCatalogState? {
        guard let url = SharedContainer.privateWindowCatalogURL else {
            throw Error.invalidCatalog
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            guard SharingFileReadFailureClassifier.disposition(error) == .missing else {
                throw error
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PrivateWindowCatalogState.self, from: data)
                .validated()
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidCatalog
        }
    }

    static func activeEntry() -> PrivateWindowCatalogEntry? {
        guard let state = try? load() else { return nil }
        return state.windows.first { $0.localWindowID == state.activeWindowID }
    }

    /// The first catalog slot owns the one Build 40 `sharing/` directory that
    /// was migrated during bootstrap. Catalog entries are append-only during
    /// ordinary window creation, so this is the only stable destination for a
    /// legacy Widget configuration whose persisted source ID is just
    /// `family-window`. Never substitute the currently active slot: doing so
    /// would silently retarget an existing Home Screen Widget.
    static func legacyWidgetEntry() -> PrivateWindowCatalogEntry? {
        guard let state = try? load() else { return nil }
        return state.windows.first
    }

    static func widgetEntries() -> [PrivateWindowCatalogEntry] {
        guard let state = try? load() else { return [] }
        return state.windows.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.localWindowID < $1.localWindowID
        }
    }

    /// Enumerates only the closed set of locations owned by the private-window
    /// migration. Callers still have to decode PairingState, bind it to the
    /// ordinary-container installation marker, and prove its exact Keychain
    /// account before any location can become active.
    static func recoveryLocationsWhileLifecycleLocked() throws
        -> [PrivateWindowRecoveryLocation] {
        guard let catalog = try load() else { throw Error.invalidCatalog }
        let fileManager = FileManager.default
        var locations: [PrivateWindowRecoveryLocation] = []

        for entry in catalog.windows {
            guard let directory = SharedContainer.windowSharingDirectoryURL(
                localWindowID: entry.localWindowID
            ) else { throw Error.invalidCatalog }
            if fileManager.fileExists(atPath: directory.path) {
                guard recoveryLocationIsOrdinaryDirectory(directory) else {
                    throw Error.conflictingLegacyMigration
                }
                locations.append(
                    PrivateWindowRecoveryLocation(
                        kind: .catalogWindow(localWindowID: entry.localWindowID),
                        sharingDirectoryURL: directory
                    )
                )
            }
        }

        if let legacy = SharedContainer.legacySharingCacheDirectoryURL,
           fileManager.fileExists(atPath: legacy.path) {
            guard recoveryLocationIsOrdinaryDirectory(legacy) else {
                throw Error.conflictingLegacyMigration
            }
            locations.append(
                PrivateWindowRecoveryLocation(
                    kind: .legacy,
                    sharingDirectoryURL: legacy
                )
            )
        }

        if let quarantineRoot = SharedContainer
            .privateWindowLegacySharingQuarantineDirectoryURL,
           fileManager.fileExists(atPath: quarantineRoot.path) {
            guard recoveryLocationIsOrdinaryDirectory(quarantineRoot) else {
                throw Error.conflictingLegacyMigration
            }
            let quarantined = try fileManager.contentsOfDirectory(
                at: quarantineRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            // Recovery work must remain bounded even if a previous build was
            // repeatedly interrupted by a late extension writer.
            guard quarantined.count <= 64 else {
                throw Error.conflictingLegacyMigration
            }
            for directory in quarantined {
                guard UUID(uuidString: directory.lastPathComponent) != nil,
                      recoveryLocationIsOrdinaryDirectory(directory)
                else { throw Error.conflictingLegacyMigration }
                locations.append(
                    PrivateWindowRecoveryLocation(
                        kind: .quarantine,
                        sharingDirectoryURL: directory
                    )
                )
            }
        }

        var seen = Set<String>()
        return locations.filter {
            seen.insert($0.sharingDirectoryURL.standardizedFileURL.path).inserted
        }
    }

    /// Promotes one already-authenticated recovery location. No directory is
    /// merged or deleted: a pre-existing target is atomically moved into the
    /// same protected quarantine first, so every interruption is recoverable by
    /// running the bounded scan again.
    @discardableResult
    static func promoteRecoveryLocationWhileLifecycleLocked(
        _ location: PrivateWindowRecoveryLocation,
        targetLocalWindowID: String,
        spaceID: String,
        credentialAccount: String,
        now: Date = .now
    ) throws -> PrivateWindowCatalogEntry {
        guard var state = try load() else { throw Error.invalidCatalog }
        guard try recoveryLocationsWhileLifecycleLocked().contains(location) else {
            throw Error.conflictingLegacyMigration
        }
        guard state.activeWindowID == targetLocalWindowID else {
            throw Error.conflictingLegacyMigration
        }

        guard let targetIndex = state.windows.firstIndex(where: {
            $0.localWindowID == targetLocalWindowID
        }) else { throw Error.unknownWindow }
        switch location.kind {
        case let .catalogWindow(localWindowID):
            guard localWindowID == targetLocalWindowID else {
                throw Error.conflictingLegacyMigration
            }
        case .legacy:
            let legacyTargetWindowID = state.pendingLegacyMigrationWindowID
                ?? state.windows.first?.localWindowID
            guard legacyTargetWindowID == targetLocalWindowID else {
                throw Error.conflictingLegacyMigration
            }
        case .quarantine:
            break
        }

        let existingEntry = state.windows[targetIndex]
        guard (existingEntry.spaceID == nil || existingEntry.spaceID == spaceID),
              (existingEntry.credentialAccount == nil
                || existingEntry.credentialAccount == credentialAccount)
        else { throw Error.conflictingLegacyMigration }
        var validatedEntry = existingEntry
        validatedEntry.spaceID = spaceID
        validatedEntry.credentialAccount = credentialAccount
        validatedEntry.updatedAt = max(validatedEntry.updatedAt, now)
        _ = try validatedEntry.validated()

        guard let destination = SharedContainer.windowSharingDirectoryURL(
            localWindowID: existingEntry.localWindowID
        ) else { throw Error.invalidCatalog }
        let source = location.sharingDirectoryURL
        if source.standardizedFileURL != destination.standardizedFileURL {
            let fileManager = FileManager.default
            guard recoveryLocationIsOrdinaryDirectory(source),
                  let quarantineRoot = SharedContainer
                    .privateWindowLegacySharingQuarantineDirectoryURL
            else { throw Error.conflictingLegacyMigration }
            try fileManager.createDirectory(
                at: quarantineRoot,
                withIntermediateDirectories: true
            )
            try SharingSecureFile.enforceProtectionAndBackupExclusion(quarantineRoot)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard recoveryLocationIsOrdinaryDirectory(destination) else {
                    throw Error.conflictingLegacyMigration
                }
                let displaced = quarantineRoot.appendingPathComponent(
                    UUID().uuidString.lowercased(),
                    isDirectory: true
                )
                guard !fileManager.fileExists(atPath: displaced.path) else {
                    throw Error.conflictingLegacyMigration
                }
                do {
                    try fileManager.moveItem(at: destination, to: displaced)
                } catch {
                    throw Error.conflictingLegacyMigration
                }
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                try SharingSecureFile.enforceProtectionAndBackupExclusion(destination)
            } catch {
                // The source and any displaced target remain in the bounded
                // quarantine and are rediscovered on the next bootstrap.
                throw Error.conflictingLegacyMigration
            }
        }

        state.windows[targetIndex] = validatedEntry
        state.activeWindowID = validatedEntry.localWindowID
        if state.pendingLegacyMigrationWindowID == validatedEntry.localWindowID {
            state.pendingLegacyMigrationWindowID = nil
        }
        state.storageRevision += 1
        try saveWhileLifecycleLocked(state)
        return validatedEntry
    }

    /// Called by installation bootstrap while it already owns the lifecycle
    /// lock. The first commit makes the migration resumable; the subsequent
    /// same-volume move is atomic and never merges two room directories.
    @discardableResult
    static func bootstrapLegacyMigrationWhileLifecycleLocked(
        now: Date = .now
    ) throws -> PrivateWindowCatalogState {
        if var existing = try load() {
            try resumeLegacyMigrationIfNeeded(&existing)
            try quarantineReappearedLegacySharingIfNeeded(&existing)
            return existing
        }

        let localWindowID = UUID().uuidString.lowercased()
        let legacyExists = SharedContainer.legacySharingCacheDirectoryURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let entry = PrivateWindowCatalogEntry(
            localWindowID: localWindowID,
            displayName: PrivateWindowDisplayName.fallback,
            spaceID: nil,
            credentialAccount: nil,
            createdAt: now,
            updatedAt: now
        )
        var state = PrivateWindowCatalogState(
            activeWindowID: localWindowID,
            windows: [entry],
            pendingLegacyMigrationWindowID: legacyExists ? localWindowID : nil
        )
        try saveWhileLifecycleLocked(state)
        try resumeLegacyMigrationIfNeeded(&state)
        return state
    }

    @discardableResult
    static func createAndActivateWhileLifecycleLocked(
        now: Date = .now
    ) throws -> PrivateWindowCatalogEntry {
        var state = try bootstrapLegacyMigrationWhileLifecycleLocked(now: now)
        guard state.windows.count < PrivateWindowCatalogState.maximumWindowCount else {
            throw Error.windowLimitReached
        }
        let entry = PrivateWindowCatalogEntry(
            localWindowID: UUID().uuidString.lowercased(),
            displayName: PrivateWindowDisplayName.fallback,
            spaceID: nil,
            credentialAccount: nil,
            createdAt: now,
            updatedAt: now
        )
        state.windows.append(entry)
        state.activeWindowID = entry.localWindowID
        state.storageRevision += 1
        try saveWhileLifecycleLocked(state)
        guard let directory = SharedContainer.windowSharingDirectoryURL(
            localWindowID: entry.localWindowID
        ) else { throw Error.invalidCatalog }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return entry
    }

    @discardableResult
    static func activateWhileLifecycleLocked(
        localWindowID: String,
        now: Date = .now
    ) throws -> PrivateWindowCatalogEntry {
        var state = try bootstrapLegacyMigrationWhileLifecycleLocked(now: now)
        guard let index = state.windows.firstIndex(where: {
            $0.localWindowID == localWindowID
        }) else { throw Error.unknownWindow }
        if state.activeWindowID != localWindowID {
            state.activeWindowID = localWindowID
            state.windows[index].updatedAt = max(state.windows[index].updatedAt, now)
            state.storageRevision += 1
            try saveWhileLifecycleLocked(state)
        }
        return state.windows[index]
    }

    static func updateActiveMetadataWhileLifecycleLocked(
        displayName: String? = nil,
        spaceID: String?,
        credentialAccount: String?,
        now: Date = .now
    ) throws {
        guard var state = try load(),
              let index = state.windows.firstIndex(where: {
                  $0.localWindowID == state.activeWindowID
              })
        else { throw Error.invalidCatalog }
        if let displayName {
            guard PrivateWindowDisplayName.isValid(displayName) else {
                throw Error.invalidCatalog
            }
            state.windows[index].displayName = displayName
        }
        state.windows[index].spaceID = spaceID
        state.windows[index].credentialAccount = credentialAccount
        state.windows[index].updatedAt = max(state.windows[index].updatedAt, now)
        state.storageRevision += 1
        try saveWhileLifecycleLocked(state)
    }

    /// Full installation invalidation is the only operation that removes all
    /// windows. Ordinary unlink/revoke clears only the active slot.
    @discardableResult
    static func resetAllWhileLifecycleLocked(now: Date = .now) throws
        -> PrivateWindowCatalogState {
        if let directory = SharedContainer.privateWindowsDirectoryURL,
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        if let legacy = SharedContainer.legacySharingCacheDirectoryURL,
           FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.removeItem(at: legacy)
        }
        if let catalog = SharedContainer.privateWindowCatalogURL,
           FileManager.default.fileExists(atPath: catalog.path) {
            try FileManager.default.removeItem(at: catalog)
        }
        return try bootstrapLegacyMigrationWhileLifecycleLocked(now: now)
    }

    private static func resumeLegacyMigrationIfNeeded(
        _ state: inout PrivateWindowCatalogState
    ) throws {
        guard let pendingID = state.pendingLegacyMigrationWindowID,
              let legacy = SharedContainer.legacySharingCacheDirectoryURL,
              let destination = SharedContainer.windowSharingDirectoryURL(
                  localWindowID: pendingID
              )
        else { return }
        let fileManager = FileManager.default
        var legacyExists = fileManager.fileExists(atPath: legacy.path)
        var destinationExists = fileManager.fileExists(atPath: destination.path)
        if legacyExists && destinationExists {
            try quarantineLegacySharingIfSafe(
                legacy,
                authoritativeDestination: destination
            )
            legacyExists = fileManager.fileExists(atPath: legacy.path)
            destinationExists = fileManager.fileExists(atPath: destination.path)
        }
        if legacyExists {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: destination)
        } else if !destinationExists {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        }
        state.pendingLegacyMigrationWindowID = nil
        state.storageRevision += 1
        try saveWhileLifecycleLocked(state)
    }

    /// An older Widget or Share Extension can finish one already-started file
    /// operation after the host app has atomically moved Build 40's `sharing/`
    /// directory. That late writer recreates the legacy path even though the
    /// catalog migration has already committed. Keeping both paths blocks all
    /// future bootstrap attempts; merging them would be worse because they may
    /// contain independent room authorities.
    ///
    /// Recover only when the destination is already authoritative and the
    /// source is provably the same paired installation, or when the source has
    /// no pairing state and contains only known replaceable cache/temporary
    /// entries. The complete source is atomically moved to protected quarantine
    /// storage. It is never merged into, or deleted in favour of, the active
    /// window.
    private static func quarantineReappearedLegacySharingIfNeeded(
        _ state: inout PrivateWindowCatalogState
    ) throws {
        guard state.pendingLegacyMigrationWindowID == nil,
              let legacyOwnerWindowID = state.windows.first?.localWindowID,
              let legacy = SharedContainer.legacySharingCacheDirectoryURL,
              let destination = SharedContainer.windowSharingDirectoryURL(
                  localWindowID: legacyOwnerWindowID
              )
        else { return }
        let fileManager = FileManager.default
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        guard legacyExists else { return }
        guard destinationExists else { throw Error.conflictingLegacyMigration }
        try quarantineLegacySharingIfSafe(
            legacy,
            authoritativeDestination: destination
        )
        state.storageRevision += 1
        try saveWhileLifecycleLocked(state)
    }

    /// Minimal JSON projection shared by the app, Widget, and Share Extension.
    /// The extensions intentionally do not link host-only PairingCore/Keychain
    /// code, so migration compares only the complete room-authority identity.
    private struct LegacyPairingDocument: Decodable {
        let schemaVersion: Int
        let installationMarker: String
        let phase: String
        let role: String?
        let credentialAccount: String?
        let participantID: String?
        let spaceID: String?
        let memberID: String?
        let localMomentDeviceID: String?
        let peerMemberID: String?
        let peerParticipantID: String?
        let recoveryWasLocalDeviceReplacement: Bool?
        let recoveryDeviceID: String?
    }

    private struct LegacyPairingIdentity: Equatable {
        let installationMarker: String
        let role: String
        let credentialAccount: String
        let participantID: String
        let spaceID: String
        let memberID: String
        let localMomentDeviceID: String
        let peerMemberID: String
        let peerParticipantID: String

        init?(_ state: LegacyPairingDocument) {
            let resolvedLocalMomentDeviceID = state.localMomentDeviceID
                ?? (state.recoveryWasLocalDeviceReplacement == true
                    ? state.recoveryDeviceID
                    : state.memberID)
            guard state.schemaVersion == 1,
                  UUID(uuidString: state.installationMarker) != nil,
                  state.phase == "paired",
                  let role = state.role,
                  role == "inviter" || role == "invitee",
                  let credentialAccount = state.credentialAccount,
                  UUID(uuidString: credentialAccount) != nil,
                  let participantID = state.participantID,
                  let spaceID = state.spaceID,
                  let memberID = state.memberID,
                  let localMomentDeviceID = resolvedLocalMomentDeviceID,
                  let peerMemberID = state.peerMemberID,
                  let peerParticipantID = state.peerParticipantID,
                  [participantID, spaceID, memberID, localMomentDeviceID,
                   peerMemberID, peerParticipantID].allSatisfy(
                      Self.isOpaqueIdentifier
                   )
            else { return nil }
            installationMarker = state.installationMarker
            self.role = role
            self.credentialAccount = credentialAccount
            self.participantID = participantID
            self.spaceID = spaceID
            self.memberID = memberID
            self.localMomentDeviceID = localMomentDeviceID
            self.peerMemberID = peerMemberID
            self.peerParticipantID = peerParticipantID
        }

        private static func isOpaqueIdentifier(_ value: String) -> Bool {
            guard (8...128).contains(value.utf8.count) else { return false }
            return value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45
                    || $0 == 95
            }
        }
    }

    private static let replaceableLegacyEntryNames: Set<String> = [
        "family-widget-cache",
        "family-widget-cache-history.v1.json",
        "family-widget-manifest.v1.json",
        "moment-handoff"
    ]

    private static func quarantineLegacySharingIfSafe(
        _ legacy: URL,
        authoritativeDestination destination: URL,
        quarantineRoot explicitQuarantineRoot: URL? = nil
    ) throws {
        let sourcePairing = try validatedPairingIdentity(in: legacy)
        let destinationPairing = try validatedPairingIdentity(in: destination)
        let entryNames = try Set(
            FileManager.default.contentsOfDirectory(
                atPath: legacy.path
            )
        )

        let identitiesMatch: Bool
        if let sourcePairing, let destinationPairing {
            identitiesMatch = sourcePairing == destinationPairing
        } else {
            identitiesMatch = false
        }
        let isReplaceableStray = sourcePairing == nil
            && legacyEntriesAreReplaceable(entryNames)
            && legacyTemporaryArtifactsAreSafelyQuarantinable(
                in: legacy,
                entryNames: entryNames
            )
        guard identitiesMatch || isReplaceableStray else {
            throw Error.conflictingLegacyMigration
        }

        guard let quarantineRoot = explicitQuarantineRoot
            ?? SharedContainer.privateWindowLegacySharingQuarantineDirectoryURL
        else { throw Error.conflictingLegacyMigration }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: quarantineRoot,
            withIntermediateDirectories: true
        )
        // Enforce the same protection boundary before the atomic rename. The
        // source already held sharing data, but re-validating it prevents a
        // late writer from downgrading attributes before quarantine.
        try SharingSecureFile.enforceProtectionAndBackupExclusion(legacy)
        try SharingSecureFile.enforceProtectionAndBackupExclusion(quarantineRoot)
        let quarantine = quarantineRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: quarantine.path) else {
            throw Error.conflictingLegacyMigration
        }
        do {
            try fileManager.moveItem(at: legacy, to: quarantine)
        } catch {
            throw Error.conflictingLegacyMigration
        }
    }

    private static func validatedPairingIdentity(in directory: URL) throws
        -> LegacyPairingIdentity? {
        let url = directory.appendingPathComponent(
            "pairing-state.json",
            isDirectory: false
        )
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            guard SharingFileReadFailureClassifier.disposition(error) == .missing
            else { throw Error.conflictingLegacyMigration }
            return nil
        }
        let decoder = JSONDecoder()
        do {
            let document = try decoder.decode(
                LegacyPairingDocument.self,
                from: data
            )
            guard let identity = LegacyPairingIdentity(document) else {
                throw Error.conflictingLegacyMigration
            }
            return identity
        } catch {
            throw Error.conflictingLegacyMigration
        }
    }

    private static func legacyEntriesAreReplaceable(_ entryNames: Set<String>)
        -> Bool {
        entryNames.allSatisfy {
            replaceableLegacyEntryNames.contains($0)
                || $0.hasPrefix(".sharing-secure-")
        }
    }

    private static func legacyTemporaryArtifactsAreSafelyQuarantinable(
        in legacy: URL,
        entryNames: Set<String>
    ) -> Bool {
        if entryNames.contains("moment-handoff") {
            let handoff = legacy.appendingPathComponent(
                "moment-handoff",
                isDirectory: true
            )
            guard SharedContainer
                .legacyMomentShareHandoffDirectoryIsSafelyQuarantinable(handoff)
            else { return false }
        }
        return true
    }

    private static func recoveryLocationIsOrdinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

#if DEBUG
    static func runtimeTestLegacyEntriesAreReplaceable(
        _ entryNames: Set<String>
    ) -> Bool {
        legacyEntriesAreReplaceable(entryNames)
    }

    static func runtimeTestLegacyPairingIdentitiesMatch(
        _ lhs: Data,
        _ rhs: Data
    ) -> Bool {
        let decoder = JSONDecoder()
        guard let lhsDocument = try? decoder.decode(
                  LegacyPairingDocument.self,
                  from: lhs
              ),
              let rhsDocument = try? decoder.decode(
                  LegacyPairingDocument.self,
                  from: rhs
              ),
              let lhs = LegacyPairingIdentity(lhsDocument),
              let rhs = LegacyPairingIdentity(rhsDocument)
        else { return false }
        return lhs == rhs
    }

    static func runtimeTestQuarantineLegacySharingIfSafe(
        _ legacy: URL,
        authoritativeDestination destination: URL,
        quarantineRoot: URL
    ) throws {
        try quarantineLegacySharingIfSafe(
            legacy,
            authoritativeDestination: destination,
            quarantineRoot: quarantineRoot
        )
    }
#endif

    private static func saveWhileLifecycleLocked(
        _ value: PrivateWindowCatalogState
    ) throws {
        guard let url = SharedContainer.privateWindowCatalogURL else {
            throw Error.invalidCatalog
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try SharingSecureFile.write(
                try encoder.encode(try value.validated()),
                to: url
            )
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidCatalog
        }
    }
}

/// URLs shared by the application and its WidgetKit extension.
///
/// Both targets must carry the same `AppGroupIdentifier` Info.plist value and
/// the matching App Group entitlement. The fallback keeps local development
/// deterministic, but it does not replace the entitlement.
enum SharedContainer {
    /// Legacy Share Extension handoff files were bounded by the v2 encrypted
    /// object's 1 MiB ceiling. Keep this validation dependency-free because
    /// `SharedContainer` is also compiled in isolation by extensions and CI.
    private static let maximumLegacyMomentHandoffFileBytes = 1_024 * 1_024

    static var appGroupIdentifier: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured
        }
        return "group.com.example.nekowidget"
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("library-snapshot.json", isDirectory: false)
    }

    /// Canonical cross-process state for likes created by either the app or an
    /// interactive widget. Keeping this separate from the scan snapshot avoids
    /// a widget read/modify/write racing with a long-running library scan.
    static var likesURL: URL? {
        containerURL?.appendingPathComponent("liked-assets.json", isDirectory: false)
    }

    /// `flock` operates on this stable inode while `liked-assets.json` can be
    /// atomically replaced. Both the app and extension must use the same lock.
    static var likesLockURL: URL? {
        containerURL?.appendingPathComponent("liked-assets.lock", isDirectory: false)
    }

    /// User curation is independent from scanner checkpoints. A source change
    /// can replace every AssetRecord, so exclusions must not live only inside
    /// the library snapshot.
    static var catCandidateCurationURL: URL? {
        containerURL?.appendingPathComponent(
            "cat-candidate-curation.json",
            isDirectory: false
        )
    }

    static var widgetManifestURL: URL? {
        containerURL?.appendingPathComponent("widget-manifest.json", isDirectory: false)
    }

    /// Build 4 used one global lease. Keep reading it during migration so a
    /// timeline created by the older extension cannot lose its cache files.
    static var legacyWidgetTimelineLeaseURL: URL? {
        containerURL?.appendingPathComponent("widget-timeline-lease.json", isDirectory: false)
    }

    static func widgetTimelineLeaseURL(for variant: WidgetImageVariant) -> URL? {
        containerURL?.appendingPathComponent(
            "widget-timeline-lease-\(variant.rawValue).json",
            isDirectory: false
        )
    }

    static var allWidgetTimelineLeaseURLs: [URL] {
        let familyURLs = WidgetImageVariant.allCases.compactMap {
            widgetTimelineLeaseURL(for: $0)
        }
        if let legacyWidgetTimelineLeaseURL {
            return familyURLs + [legacyWidgetTimelineLeaseURL]
        }
        return familyURLs
    }

    static var widgetCacheDirectoryURL: URL? {
        containerURL?.appendingPathComponent("widget-cache", isDirectory: true)
    }

    /// A family photo is never mixed into the personal PhotoKit manifest.
    /// Keeping this below `sharing/` also makes unlink/reinstall cleanup remove
    /// the family Widget output together with every other sharing artifact.
    static var familyWidgetManifestURL: URL? {
        familyWidgetManifestURL(localWindowID: nil)
    }

    static func familyWidgetManifestURL(localWindowID: String?) -> URL? {
        sharingCacheDirectoryURL(localWindowID: localWindowID)?.appendingPathComponent(
            "family-widget-manifest.v1.json",
            isDirectory: false
        )
    }

    /// Shared by the app target and Widget extension because the App Intent
    /// entity is compiled into both. The manifest is presentation-only; a
    /// missing, old, or malformed value always resolves to the neutral name.
    static func familyWidgetWindowDisplayName() -> String {
        familyWidgetWindowDisplayName(localWindowID: nil)
    }

    static func familyWidgetWindowDisplayName(localWindowID: String?) -> String {
        guard let url = familyWidgetManifestURL(localWindowID: localWindowID),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            if let localWindowID,
               let entry = PrivateWindowCatalogStore.widgetEntries().first(where: {
                   $0.localWindowID == localWindowID
               }) {
                return PrivateWindowDisplayName.resolved(entry.displayName)
            }
            return PrivateWindowCatalogStore.activeEntry()?.displayName
                ?? PrivateWindowDisplayName.fallback
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(FamilyWidgetManifest.self, from: data),
              manifest.schemaVersion == FamilyWidgetManifest.schemaVersion
        else { return PrivateWindowDisplayName.fallback }
        return PrivateWindowDisplayName.resolved(manifest.windowDisplayName)
    }

    static var familyWidgetCacheHistoryURL: URL? {
        familyWidgetCacheHistoryURL(localWindowID: nil)
    }

    static func familyWidgetCacheHistoryURL(localWindowID: String?) -> URL? {
        sharingCacheDirectoryURL(localWindowID: localWindowID)?.appendingPathComponent(
            "family-widget-cache-history.v1.json",
            isDirectory: false
        )
    }

    static var familyWidgetCacheDirectoryURL: URL? {
        familyWidgetCacheDirectoryURL(localWindowID: nil)
    }

    static func familyWidgetCacheDirectoryURL(localWindowID: String?) -> URL? {
        sharingCacheDirectoryURL(localWindowID: localWindowID)?.appendingPathComponent(
            "family-widget-cache",
            isDirectory: true
        )
    }

    static var logsDirectoryURL: URL? {
        containerURL?.appendingPathComponent("diagnostic-logs", isDirectory: true)
    }

    /// Non-secret sharing state. Private keys and the room key live in the
    /// App Group-backed Keychain access group, never in this directory.
    static var pairingStateURL: URL? {
        sharingCacheDirectoryURL?
            .appendingPathComponent("pairing-state.json", isDirectory: false)
    }

    /// Local presentation only. The display name is deliberately separate
    /// from PairingState so a rename cannot invalidate an in-flight pairing
    /// CAS, and it is deliberately below `sharing/` so unlink/reinstall cleanup
    /// removes it with every other artifact for the old private window.
    static var privateWindowPresentationURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "window-presentation.v1.json",
            isDirectory: false
        )
    }

    /// Encrypted-name ordering and retry metadata is kept separate from the
    /// Build 32 presentation file. An older writer can therefore replace its
    /// local label without erasing the rollback floor or an ambiguous PUT.
    static var privateWindowNameSyncStateURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "window-name-sync.v1.json",
            isDirectory: false
        )
    }

    static var sharingCacheDirectoryURL: URL? {
        sharingCacheDirectoryURL(localWindowID: nil)
    }

    /// Build 40 and earlier stored exactly one room here. Keep this explicit
    /// path for the crash-resumable migration and for old Widget readers that
    /// run before the host app has created a catalog.
    static var legacySharingCacheDirectoryURL: URL? {
        containerURL?.appendingPathComponent("sharing", isDirectory: true)
    }

    static var privateWindowsDirectoryURL: URL? {
        containerURL?.appendingPathComponent("private-windows.v1", isDirectory: true)
    }

    /// Preserves a conflicting late legacy writer without ever making it an
    /// active room authority. Full installation cleanup removes the enclosing
    /// private-windows subtree, including these bounded recovery artifacts.
    static var privateWindowLegacySharingQuarantineDirectoryURL: URL? {
        privateWindowsDirectoryURL?.appendingPathComponent(
            "legacy-sharing-quarantine",
            isDirectory: true
        )
    }

    static var privateWindowCatalogURL: URL? {
        containerURL?.appendingPathComponent(
            "private-window-catalog.v1.json",
            isDirectory: false
        )
    }

    static func windowDirectoryURL(localWindowID: String) -> URL? {
        guard let uuid = UUID(uuidString: localWindowID),
              uuid.uuidString.lowercased() == localWindowID.lowercased()
        else { return nil }
        return privateWindowsDirectoryURL?.appendingPathComponent(
            uuid.uuidString.lowercased(),
            isDirectory: true
        )
    }

    static func windowSharingDirectoryURL(localWindowID: String) -> URL? {
        windowDirectoryURL(localWindowID: localWindowID)?.appendingPathComponent(
            "sharing",
            isDirectory: true
        )
    }

    static func sharingCacheDirectoryURL(localWindowID: String?) -> URL? {
        if let localWindowID {
            return windowSharingDirectoryURL(localWindowID: localWindowID)
        }
        guard let catalogURL = privateWindowCatalogURL else { return nil }
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            return legacySharingCacheDirectoryURL
        }
        guard let catalog = try? PrivateWindowCatalogStore.load(),
              let destination = windowSharingDirectoryURL(
                  localWindowID: catalog.activeWindowID
              )
        else {
            // Present-but-invalid catalog is authority ambiguity. Never fall
            // back to a potentially unrelated Build 40 room.
            return nil
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        if catalog.pendingLegacyMigrationWindowID == catalog.activeWindowID,
           let legacy = legacySharingCacheDirectoryURL,
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return destination
    }

    /// Stable synchronization metadata deliberately lives outside `sharing/`.
    /// A privacy purge may unlink the entire ciphertext subtree without ever
    /// replacing the lifecycle-lock inode held by another process.
    static var sharingControlDirectoryURL: URL? {
        containerURL?.appendingPathComponent("sharing-control", isDirectory: true)
    }

    static var sharingLifecycleLockURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "lifecycle.lock",
            isDirectory: false
        )
    }

    static var sharingCleanupRequiredURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "cleanup-required.v1",
            isDirectory: false
        )
    }

    static var sharingCleanupScopeURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "cleanup-window-scope.v1.json",
            isDirectory: false
        )
    }

    /// Monotonic authorization epoch for all sharing media mutations. A purge
    /// increments this value before deleting credentials/cache so an operation
    /// that started with an older room key can never publish its result later.
    static var sharingLifecycleStateURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "lifecycle-state.v1.json",
            isDirectory: false
        )
    }

    static var dailySharingStateURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "daily-media-state.json",
            isDirectory: false
        )
    }

    static var dailySharingLockURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "daily-media-state.lock",
            isDirectory: false
        )
    }

    /// A short, renewable cross-process lease serializes the network sync
    /// performed by the host app and (from Phase 3) the Widget extension.
    /// This is deliberately separate from `dailySharingLockURL`: the state
    /// lock is held only for atomic file mutations and never across awaits.
    static var dailySharingSyncLeaseURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "daily-media-sync-lease.json",
            isDirectory: false
        )
    }

    static var dailySharingSyncLeaseLockURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "daily-media-sync-lease.lock",
            isDirectory: false
        )
    }

    static var sharingOutboundDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("outbound", isDirectory: true)
    }

    static var sharingInboundDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("inbound", isDirectory: true)
    }

    static var momentSharingStateURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "moment-sharing-state.v1.json",
            isDirectory: false
        )
    }

    static var momentSharingCiphertextDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("moments", isDirectory: true)
    }

    static var momentSharingReceivedDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("received-moments", isDirectory: true)
    }

    /// Short-lived, capture-only handoff from the Share Extension to the host
    /// app. It is shared by all local windows so the extension can present a
    /// verified destination picker without changing the app's active window.
    /// Every capture remains bound to one admission/window binding, and full
    /// installation cleanup removes the enclosing private-windows subtree.
    static var momentShareHandoffDirectoryURL: URL? {
        privateWindowsDirectoryURL?.appendingPathComponent(
            "moment-handoff.v2",
            isDirectory: true
        )
    }

    /// Preserves a late handoff writer from an older app/extension process.
    /// Quarantined plaintext is never merged into the active v2 ledger and is
    /// removed by handoff revocation or full-installation sharing cleanup.
    static var momentShareHandoffLegacyQuarantineDirectoryURL: URL? {
        privateWindowsDirectoryURL?.appendingPathComponent(
            "moment-handoff-legacy-quarantine",
            isDirectory: true
        )
    }

    /// Build 40 and the first single-window catalog build stored handoff input
    /// below that window's `sharing/` directory. The v2 store moves exactly
    /// one such directory atomically before using the global multi-window
    /// catalog. Multiple legacy sources are authority ambiguity and fail
    /// closed rather than being merged.
    static var legacyMomentShareHandoffDirectoryURLs: [URL] {
        var candidates: [URL] = []
        if let legacy = legacySharingCacheDirectoryURL {
            candidates.append(
                legacy.appendingPathComponent("moment-handoff", isDirectory: true)
            )
        }
        if let catalog = try? PrivateWindowCatalogStore.load() {
            for entry in catalog.windows {
                if let sharing = windowSharingDirectoryURL(
                    localWindowID: entry.localWindowID
                ) {
                    candidates.append(
                        sharing.appendingPathComponent(
                            "moment-handoff",
                            isDirectory: true
                        )
                    )
                }
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// A legacy handoff directory is eligible for quarantine only when it has
    /// the closed, bounded on-disk shape produced by the Share Extension and
    /// every file has the expected Data Protection and backup-exclusion
    /// attributes. Contents are deliberately not trusted or promoted here.
    static func legacyMomentShareHandoffDirectoryIsSafelyQuarantinable(
        _ directory: URL
    ) -> Bool {
        guard isOrdinaryDirectory(directory),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [
                      .isDirectoryKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                      .isExcludedFromBackupKey
                  ],
                  options: []
              ),
              entries.count <= 12
        else { return false }

        for entry in entries {
            switch entry.lastPathComponent {
            case "admissions.v1.plist":
                guard isProtectedNoBackupFile(
                    entry,
                    maximumBytes: 64 * 1_024,
                    protection: .afterFirstUnlock
                ) else { return false }
            case "outcomes.v1.plist":
                guard isProtectedNoBackupFile(
                    entry,
                    maximumBytes: 128 * 1_024,
                    protection: .whileUnlocked
                ) else { return false }
            case "captures":
                guard legacyMomentCaptureDirectoryIsSafelyQuarantinable(entry)
                else { return false }
            default:
                if entry.lastPathComponent.hasPrefix(".sharing-secure-") {
                    guard isProtectedNoBackupFile(
                        entry,
                        maximumBytes: 64 * 1_024,
                        protection: .afterFirstUnlock
                    ) else { return false }
                } else if entry.lastPathComponent.hasPrefix(
                    ".moment-handoff-secure-"
                ) {
                    guard isProtectedNoBackupFile(
                        entry,
                        maximumBytes: maximumLegacyMomentHandoffFileBytes,
                        protection: .whileUnlocked
                    ) else { return false }
                } else {
                    return false
                }
            }
        }
        return true
    }

    private enum LegacyHandoffProtection {
        case afterFirstUnlock
        case whileUnlocked
    }

    private static func legacyMomentCaptureDirectoryIsSafelyQuarantinable(
        _ directory: URL
    ) -> Bool {
        guard isOrdinaryDirectory(directory),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                      .isExcludedFromBackupKey
                  ],
                  options: []
              ),
              entries.count <= 80
        else { return false }
        let suffix = ".capture.v1.plist"
        return entries.allSatisfy { entry in
            let name = entry.lastPathComponent
            let hasCaptureName: Bool
            if name.hasSuffix(suffix) {
                hasCaptureName = UUID(
                    uuidString: String(name.dropLast(suffix.count))
                ) != nil
            } else {
                hasCaptureName = name.hasPrefix(".moment-handoff-secure-")
            }
            return hasCaptureName
                && isProtectedNoBackupFile(
                    entry,
                    maximumBytes: maximumLegacyMomentHandoffFileBytes,
                    protection: .whileUnlocked
                )
        }
    }

    private static func isOrdinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isProtectedNoBackupFile(
        _ url: URL,
        maximumBytes: Int,
        protection: LegacyHandoffProtection
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .isExcludedFromBackupKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        values.isExcludedFromBackup == true,
        let fileSize = values.fileSize,
        (0...maximumBytes).contains(fileSize)
        else { return false }
#if targetEnvironment(simulator)
        return true
#else
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let fileProtection = attributes[.protectionKey] as? FileProtectionType
        else { return false }
        switch protection {
        case .afterFirstUnlock:
            return fileProtection == .completeUntilFirstUserAuthentication
        case .whileUnlocked:
            return fileProtection == .complete
        }
#endif
    }

    /// A terminal, pairing-scoped fail-closed marker written before a
    /// report-only transition removes handoff input. It deliberately lives
    /// beside (not inside) `moment-handoff/`, so purging that directory cannot
    /// accidentally re-enable the Share Extension. Full pairing cleanup
    /// removes the enclosing `sharing/` subtree before a new pairing begins.
    static var momentShareHandoffReportOnlyMarkerURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "moment-handoff-report-only.v1",
            isDirectory: false
        )
    }

    static var momentShareHandoffAdmissionsURL: URL? {
        momentShareHandoffDirectoryURL?.appendingPathComponent(
            "admissions.v1.plist",
            isDirectory: false
        )
    }

    static var momentShareHandoffOutcomesURL: URL? {
        momentShareHandoffDirectoryURL?.appendingPathComponent(
            "outcomes.v1.plist",
            isDirectory: false
        )
    }

    static var momentShareHandoffCapturesDirectoryURL: URL? {
        momentShareHandoffDirectoryURL?.appendingPathComponent(
            "captures",
            isDirectory: true
        )
    }
}
