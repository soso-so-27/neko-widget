import Foundation

actor LibraryStore {
    private static let groupedAlbumSnapshotSchemaVersion = 2
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
            Self.groupedAlbumSnapshotSchemaVersion
        )
        if value.albumUsage == nil {
            value.albumUsage = .empty
        }
        value.updatedAt = .now
        try AtomicJSON.write(value, to: snapshotURL)
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

        if isGroupedAlbumSchemaUpgrade {
            value.schemaVersion = groupedAlbumSnapshotSchemaVersion
            didChange = true
        }
        if value.albumUsage == nil {
            value.albumUsage = .empty
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

        if didChange {
            value.updatedAt = .now
        }
        return (value, didChange)
    }
}
