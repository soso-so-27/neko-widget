import Foundation

actor LibraryStore {
    private static let groupedAlbumSnapshotSchemaVersion = 2
    private static let boundingBoxPostureSnapshotSchemaVersion = 3
    private let snapshotURL: URL

    init(snapshotURL: URL? = SharedContainer.snapshotURL) throws {
        guard let snapshotURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        self.snapshotURL = snapshotURL
    }

    func load() throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return Self.migratedGroupedAlbumSnapshot(.empty).snapshot
        }
        let decoded = try AtomicJSON.read(LibrarySnapshot.self, from: snapshotURL)
        let migration = Self.migratedGroupedAlbumSnapshot(decoded)
        if migration.didChange {
            try AtomicJSON.write(migration.snapshot, to: snapshotURL)
        }
        return migration.snapshot
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        var value = snapshot
        value.schemaVersion = max(
            value.schemaVersion,
            Self.boundingBoxPostureSnapshotSchemaVersion
        )
        let activeSettings = value.settings
        value.assets = value.assets.map {
            $0.migratedToBoundingBoxPostureAnalysis(
                synthesizingMissingTraits: snapshot.schemaVersion
                    >= Self.groupedAlbumSnapshotSchemaVersion
            ).migratedToAreaIndependentDetection(settings: activeSettings)
        }
        if value.albumUsage == nil {
            value.albumUsage = .empty
        }
        value.scanState.lastError = DiagnosticLogPrivacy.normalizedScanLastError(
            value.scanState.lastError
        )
        value.updatedAt = .now
        try AtomicJSON.write(value, to: snapshotURL)
    }

    /// Recovers only the opaque PhotoKit collection identifier when the full
    /// snapshot cannot be decoded. This lets startup fail closed without
    /// trusting settings, assets, or migration state from a damaged/newer
    /// payload. AtomicJSON guarantees ordinary writes are complete JSON; this
    /// fallback primarily covers a type/schema decode failure.
    func recoverAlbumLocalIdentifier() throws -> String? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return nil
        }
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: snapshotURL),
            options: []
        )
        guard let dictionary = object as? [String: Any],
              let identifier = dictionary["albumLocalIdentifier"] as? String,
              !identifier.isEmpty,
              identifier.utf8.count <= 1_024,
              !identifier.contains("\0") else {
            return nil
        }
        return identifier
    }

    /// Build 11 has valid cat detections and Widget output but no grouped-album
    /// traits. Preserve that detector fingerprint and its visible photos while
    /// marking only the missing secondary analysis for a resumable library pass.
    private static func migratedGroupedAlbumSnapshot(
        _ input: LibrarySnapshot
    ) -> (snapshot: LibrarySnapshot, didChange: Bool) {
        var value = input
        var didChange = false
        let isGroupedAlbumSchemaUpgrade =
            input.schemaVersion < groupedAlbumSnapshotSchemaVersion

        if input.schemaVersion < boundingBoxPostureSnapshotSchemaVersion {
            value.schemaVersion = boundingBoxPostureSnapshotSchemaVersion
            didChange = true
        }
        if value.albumUsage == nil {
            value.albumUsage = .empty
            didChange = true
        }
        let normalizedLastError = DiagnosticLogPrivacy.normalizedScanLastError(
            value.scanState.lastError
        )
        if value.scanState.lastError != normalizedLastError {
            value.scanState.lastError = normalizedLastError
            didChange = true
        }

        if isGroupedAlbumSchemaUpgrade {
            // Build 11 has no pose/face/location classification. Revisit the
            // complete visible library once so old no-cat decisions are also
            // reevaluated; screenshots/burst duplicates remain cheap metadata
            // exclusions inside the scanner. Existing cat/Widget records stay
            // visible until each replacement result is published.
            let needsUpgradePass = !value.assets.isEmpty
            if needsUpgradePass {
                value.scanState.requiresFullRescan = true
                value.scanState.purpose = .groupedAlbumUpgrade
                didChange = true
            } else if value.scanState.purpose == .groupedAlbumUpgrade {
                value.scanState.requiresFullRescan = false
                value.scanState.purpose = nil
                didChange = true
            }
        }

        let activeSettings = value.settings
        let migratedAssets = value.assets.map {
            $0.migratedToBoundingBoxPostureAnalysis(
                synthesizingMissingTraits: !isGroupedAlbumSchemaUpgrade
            ).migratedToAreaIndependentDetection(settings: activeSettings)
        }
        if migratedAssets != value.assets {
            value.assets = migratedAssets
            didChange = true
        }

        let postureSummary = PostureScanSummary(records: value.assets)
        if value.scanState.postureSummary != postureSummary {
            value.scanState.postureSummary = postureSummary
            didChange = true
        }

        // Build 16 resolves posture albums from already persisted detector
        // boxes. Never launch the retired animal-pose repair pass. A genuine
        // Build 11 grouped-album upgrade above still keeps its full-pass route
        // for face/location traits that cannot be reconstructed from storage.
        if value.scanState.purpose == .postureRepair {
            value.scanState.purpose = nil
            didChange = true
        }

        if didChange {
            value.updatedAt = .now
        }
        return (value, didChange)
    }
}
