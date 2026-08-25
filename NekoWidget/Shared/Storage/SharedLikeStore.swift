import Darwin
import Foundation

struct SharedLikeRecord: Codable, Equatable, Sendable {
    var localIdentifier: String
    var isLiked: Bool
    var likedAt: Date?
    var changedAt: Date
    /// True only for a Photos asset created by the explicit received-memory
    /// import. Optional keeps every pre-ADR-021 record byte-compatible.
    var isReceivedMemoryImport: Bool? = nil
}

struct SharedLikeMutation: Equatable, Sendable {
    var previousIsLiked: Bool
    var record: SharedLikeRecord
}

struct SharedLikeEvent: Codable, Equatable, Sendable {
    var id: String
    var sequence: Int
    var localIdentifier: String
    var previousIsLiked: Bool
    var isLiked: Bool
    var changedAt: Date
    var changedAtEpochMilliseconds: Int64
    var source: String
}

struct SharedLikeMeasurementSnapshot: Codable, Equatable, Sendable {
    var startedAt: Date?
    var baselineLikedCount: Int
    var events: [SharedLikeEvent]
    var retentionDays: Int
    var maximumEventCount: Int
    var droppedEventCount: Int

    static let empty = SharedLikeMeasurementSnapshot(
        startedAt: nil,
        baselineLikedCount: 0,
        events: [],
        retentionDays: 30,
        maximumEventCount: 1_000,
        droppedEventCount: 0
    )
}

struct SharedLikeStateSnapshot: Equatable, Sendable {
    var records: [String: SharedLikeRecord]
    var isInteractionReady: Bool
}

private struct SharedLikeStoreFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var records: [String: SharedLikeRecord]
    var updatedAt: Date
    var migrationCompletedAt: Date?
    var measurementStartedAt: Date?
    var measurementBaselineLikedCount: Int
    var events: [SharedLikeEvent]
    var measurementDroppedEventCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
        case updatedAt
        case migrationCompletedAt
        case measurementStartedAt
        case measurementBaselineLikedCount
        case events
        case measurementDroppedEventCount
    }

    static let empty = SharedLikeStoreFile(
        schemaVersion: 2,
        records: [:],
        updatedAt: .distantPast,
        migrationCompletedAt: nil,
        measurementStartedAt: nil,
        measurementBaselineLikedCount: 0,
        events: [],
        measurementDroppedEventCount: 0
    )

    init(
        schemaVersion: Int,
        records: [String: SharedLikeRecord],
        updatedAt: Date,
        migrationCompletedAt: Date?,
        measurementStartedAt: Date?,
        measurementBaselineLikedCount: Int,
        events: [SharedLikeEvent],
        measurementDroppedEventCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.updatedAt = updatedAt
        self.migrationCompletedAt = migrationCompletedAt
        self.measurementStartedAt = measurementStartedAt
        self.measurementBaselineLikedCount = measurementBaselineLikedCount
        self.events = events
        self.measurementDroppedEventCount = measurementDroppedEventCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        records = try container.decodeIfPresent(
            [String: SharedLikeRecord].self,
            forKey: .records
        ) ?? [:]
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        migrationCompletedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .migrationCompletedAt
        )
        measurementStartedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .measurementStartedAt
        )
        if migrationCompletedAt == nil, let measurementStartedAt {
            migrationCompletedAt = measurementStartedAt
        }
        measurementBaselineLikedCount = try container.decodeIfPresent(
            Int.self,
            forKey: .measurementBaselineLikedCount
        ) ?? 0
        events = try container.decodeIfPresent(
            [SharedLikeEvent].self,
            forKey: .events
        ) ?? []
        measurementDroppedEventCount = try container.decodeIfPresent(
            Int.self,
            forKey: .measurementDroppedEventCount
        ) ?? 0
    }
}

/// Lightweight decode used by WidgetKit. Unknown `events` are skipped instead
/// of materializing the one-week ledger in the extension process.
private struct SharedLikeStateFile: Decodable {
    var records: [String: SharedLikeRecord]
    var migrationCompletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case records
        case migrationCompletedAt
        case measurementStartedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent(
            [String: SharedLikeRecord].self,
            forKey: .records
        ) ?? [:]
        migrationCompletedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .migrationCompletedAt
        )
        if migrationCompletedAt == nil {
            migrationCompletedAt = try container.decodeIfPresent(
                Date.self,
                forKey: .measurementStartedAt
            )
        }
    }
}

enum SharedLikeStoreError: LocalizedError {
    case appGroupUnavailable(String)
    case lockOpenFailed(Int32)
    case lockFailed(Int32)
    case measurementNotInitialized

    var errorDescription: String? {
        switch self {
        case let .appGroupUnavailable(identifier):
            return "App Group \(identifier) is unavailable."
        case let .lockOpenFailed(code):
            return "The shared like lock could not be opened (errno \(code))."
        case let .lockFailed(code):
            return "The shared like lock could not be acquired (errno \(code))."
        case .measurementNotInitialized:
            return "Open the app once to migrate existing likes before using the widget button."
        }
    }
}

/// The canonical like store shared by the app and WidgetKit extension.
///
/// A separate file is intentional. `LibrarySnapshot` is rewritten by scans and
/// contains much more than user state, so toggling a flag in that file from the
/// extension could lose either a scan result or a recent tap. All mutations of
/// this store are serialized across processes with a stable lock file, while
/// the JSON payload itself is atomically replaced.
enum SharedLikeStore {
    /// The one-week Like experiment was withdrawn on 2026-08-17 because its
    /// result would not change a product decision. This shared store is built
    /// into both the app and Widget extension, so keep the stop switch here.
    /// Persisted measurement fields remain readable for export and migration.
    private static let recordsMeasurementEvents = false

    private static let measurementRetentionDays = 30
    private static let maximumMeasurementEventCount = 1_000
    /// `flock` coordinates the app and extension as separate processes, but it
    /// does not serialize two callers that already share a process. Keep both
    /// layers so rapid App Intent or app-side mutations cannot overlap.
    private static let processLock = NSLock()

    static func readAll() throws -> [String: SharedLikeRecord] {
        try withExclusiveLock {
            try readUnlocked().records
        }
    }

    static func stateSnapshot() throws -> SharedLikeStateSnapshot {
        try withExclusiveLock {
            guard let url = SharedContainer.likesURL else {
                throw SharedLikeStoreError.appGroupUnavailable(
                    SharedContainer.appGroupIdentifier
                )
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return SharedLikeStateSnapshot(
                    records: [:],
                    isInteractionReady: false
                )
            }
            let file = try AtomicJSON.read(SharedLikeStateFile.self, from: url)
            return SharedLikeStateSnapshot(
                records: file.records,
                isInteractionReady: file.migrationCompletedAt != nil
            )
        }
    }

    static func record(for localIdentifier: String) throws -> SharedLikeRecord? {
        try withExclusiveLock {
            try readUnlocked().records[localIdentifier]
        }
    }

    static func measurementSnapshot() throws -> SharedLikeMeasurementSnapshot {
        try withExclusiveLock {
            var file = try readUnlocked()
            let originalEventCount = file.events.count
            let originalDroppedCount = file.measurementDroppedEventCount
            pruneEvents(in: &file, relativeTo: .now)
            if file.events.count != originalEventCount
                || file.measurementDroppedEventCount != originalDroppedCount {
                file.updatedAt = .now
                try writeUnlocked(file)
            }
            return SharedLikeMeasurementSnapshot(
                startedAt: file.measurementStartedAt,
                baselineLikedCount: file.measurementBaselineLikedCount,
                events: file.events,
                retentionDays: measurementRetentionDays,
                maximumEventCount: maximumMeasurementEventCount,
                droppedEventCount: file.measurementDroppedEventCount
            )
        }
    }

    /// Imports v1–Build 5 likes without allowing an old snapshot to resurrect
    /// an explicit Build 6 unlike tombstone. Existing shared records always win.
    @discardableResult
    static func mergeLegacyLikes(
        _ records: [SharedLikeRecord],
        at date: Date = .now
    ) throws -> [String: SharedLikeRecord] {
        try withExclusiveLock {
            var file = try readUnlocked()
            var didChange = false
            for record in records where file.records[record.localIdentifier] == nil {
                file.records[record.localIdentifier] = record
                file.updatedAt = max(file.updatedAt, record.changedAt)
                didChange = true
            }
            if file.migrationCompletedAt == nil {
                file.migrationCompletedAt = date
                file.schemaVersion = 2
                file.updatedAt = max(file.updatedAt, date)
                didChange = true
            }
            if didChange {
                try writeUnlocked(file)
            }
            return file.records
        }
    }

    /// Makes the v2 store independently writable before an irreversible
    /// received-photo import. A later personal-library scan can still merge
    /// every missing legacy record; existing imported records and explicit
    /// unlike tombstones remain authoritative.
    static func ensureInitialized(at date: Date = .now) throws {
        _ = try mergeLegacyLikes([], at: date)
    }

    @discardableResult
    static func set(
        localIdentifier: String,
        isLiked: Bool,
        at date: Date = .now,
        source: String = "app"
    ) throws -> SharedLikeMutation {
        try mutate(
            localIdentifier: localIdentifier,
            fallbackIsLiked: false,
            at: date,
            source: source
        ) { _ in isLiked }
    }

    /// The fallback is used only for the first Build 6 interaction with a photo
    /// that has not yet been migrated from `LibrarySnapshot`. Once a record
    /// exists, the locked on-disk value is authoritative, including `false`.
    @discardableResult
    static func toggle(
        localIdentifier: String,
        fallbackIsLiked: Bool,
        at date: Date = .now,
        source: String
    ) throws -> SharedLikeMutation {
        try mutate(
            localIdentifier: localIdentifier,
            fallbackIsLiked: fallbackIsLiked,
            at: date,
            source: source
        ) { current in
            !current
        }
    }

    private static func mutate(
        localIdentifier: String,
        fallbackIsLiked: Bool,
        at date: Date,
        source: String,
        value: (Bool) -> Bool
    ) throws -> SharedLikeMutation {
        try withExclusiveLock {
            var file = try readUnlocked()
            let previous = file.records[localIdentifier]
            let previousIsLiked = previous?.isLiked ?? fallbackIsLiked
            guard file.migrationCompletedAt != nil else {
                throw SharedLikeStoreError.measurementNotInitialized
            }
            let isLiked = value(previousIsLiked)
            let record = SharedLikeRecord(
                localIdentifier: localIdentifier,
                isLiked: isLiked,
                likedAt: isLiked ? date : nil,
                changedAt: date,
                isReceivedMemoryImport:
                    previous?.isReceivedMemoryImport == true
                        || source == "received-memory"
            )
            file.records[localIdentifier] = record
            if recordsMeasurementEvents,
               file.measurementStartedAt != nil {
                let nextSequence = (file.events.last?.sequence
                    ?? file.measurementDroppedEventCount) + 1
                file.events.append(
                    SharedLikeEvent(
                        id: UUID().uuidString.lowercased(),
                        sequence: nextSequence,
                        localIdentifier: localIdentifier,
                        previousIsLiked: previousIsLiked,
                        isLiked: isLiked,
                        changedAt: date,
                        changedAtEpochMilliseconds: Int64(
                            (date.timeIntervalSince1970 * 1_000).rounded()
                        ),
                        source: source
                    )
                )
                pruneEvents(in: &file, relativeTo: date)
            }
            file.schemaVersion = 2
            file.updatedAt = date
            try writeUnlocked(file)
            return SharedLikeMutation(
                previousIsLiked: previousIsLiked,
                record: record
            )
        }
    }

    private static func pruneEvents(
        in file: inout SharedLikeStoreFile,
        relativeTo date: Date
    ) {
        let cutoff = date.addingTimeInterval(
            -TimeInterval(measurementRetentionDays) * 24 * 60 * 60
        )
        let beforeRetentionPrune = file.events.count
        file.events.removeAll { $0.changedAt < cutoff }
        file.measurementDroppedEventCount += beforeRetentionPrune - file.events.count
        if file.events.count > maximumMeasurementEventCount {
            let overflow = file.events.count - maximumMeasurementEventCount
            file.events.removeFirst(overflow)
            file.measurementDroppedEventCount += overflow
        }
    }

    private static func readUnlocked() throws -> SharedLikeStoreFile {
        guard let url = SharedContainer.likesURL else {
            throw SharedLikeStoreError.appGroupUnavailable(
                SharedContainer.appGroupIdentifier
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        return try AtomicJSON.read(SharedLikeStoreFile.self, from: url)
    }

    private static func writeUnlocked(_ file: SharedLikeStoreFile) throws {
        guard let url = SharedContainer.likesURL else {
            throw SharedLikeStoreError.appGroupUnavailable(
                SharedContainer.appGroupIdentifier
            )
        }
        try AtomicJSON.write(file, to: url)
    }

    private static func withExclusiveLock<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        processLock.lock()
        defer { processLock.unlock() }

        guard let lockURL = SharedContainer.likesLockURL else {
            throw SharedLikeStoreError.appGroupUnavailable(
                SharedContainer.appGroupIdentifier
            )
        }
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SharedLikeStoreError.lockOpenFailed(errno)
        }
        defer { Darwin.close(descriptor) }

        // `Darwin` exports both `struct flock` and the `flock()` function.
        // Calling the function without the module qualifier avoids Swift
        // resolving this expression as the struct initializer.
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SharedLikeStoreError.lockFailed(errno)
        }
        defer { flock(descriptor, LOCK_UN) }

        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: lockURL.path
        )
        return try operation()
    }
}
