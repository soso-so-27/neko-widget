import Foundation

/// Ephemeral PhotoKit authority. A missing result means unresolved/denied,
/// never an unrestricted library. Persisted scan records are kept separately.
struct LibraryReadablePhotoProjection: Sendable {
    private(set) var generation = 0
    private(set) var identifiers: Set<String>?
    private(set) var isUnrestricted = false

    var isResolved: Bool { isUnrestricted || identifiers != nil }

    mutating func allowFullLibrary() {
        invalidate()
        isUnrestricted = true
    }

    @discardableResult
    mutating func invalidate() -> Int {
        generation &+= 1
        identifiers = nil
        isUnrestricted = false
        return generation
    }

    @discardableResult
    mutating func resolve(_ identifiers: Set<String>, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.identifiers = identifiers
        return true
    }

    func contains(_ identifier: String) -> Bool {
        isUnrestricted || identifiers?.contains(identifier) == true
    }
}

/// In-memory UI generations, separate from the persistence/scan timestamp.
/// Advance at snapshot publication, never by comparing a library in View.body.
struct LibraryPhotoPresentationRevisions {
    private(set) var content = 0
    private(set) var removedPhotos = 0

    mutating func update(from previous: LibrarySnapshot, to next: LibrarySnapshot) {
        guard previous.assets != next.assets
            || previous.settings.analysisFingerprint != next.settings.analysisFingerprint else { return }
        content &+= 1
        // Content additions/edits can prepare behind the current album. A
        // removal or loss of cat eligibility must invalidate old cards at once.
        let nextCandidateIDs = Set(next.catAssets.map(\.localIdentifier))
        if previous.catAssets.contains(where: { !nextCandidateIDs.contains($0.localIdentifier) }) {
            removedPhotos &+= 1
        }
    }
}

struct LibrarySnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var assets: [AssetRecord]
    var scanState: ScanState
    var settings: AppSettings
    var albumLocalIdentifier: String?
    /// Optional so Build 11 snapshots decode without a bespoke migration.
    var albumUsage: AlbumUsageSummary?
    var updatedAt: Date

    static let empty = LibrarySnapshot(
        schemaVersion: 3,
        assets: [],
        scanState: .idle,
        settings: .default,
        albumLocalIdentifier: nil,
        albumUsage: nil,
        updatedAt: .now
    )

    var catAssets: [AssetRecord] {
        let fingerprint = settings.analysisFingerprint
        return assets.filter {
            $0.isCatCandidate && $0.analysisFingerprint == fingerprint
        }
    }

    var likedAssets: [AssetRecord] {
        assets
            .filter(\.liked)
            .sorted { ($0.likedAt ?? .distantPast) > ($1.likedAt ?? .distantPast) }
    }
}

struct AlbumUsageRecord: Codable, Equatable, Sendable {
    var key: String
    var group: String
    var openCount: Int
    var lastOpenedAt: Date
}

struct AlbumUsageSummary: Codable, Equatable, Sendable {
    static let maximumRecords = 64

    var schemaVersion = 1
    var records: [AlbumUsageRecord]

    static let empty = AlbumUsageSummary(records: [])

    mutating func recordOpen(key: String, group: String, at date: Date = .now) {
        if let index = records.firstIndex(where: { $0.key == key }) {
            if records[index].openCount < Int.max {
                records[index].openCount += 1
            }
            records[index].lastOpenedAt = date
            records[index].group = group
        } else {
            records.append(AlbumUsageRecord(
                key: key,
                group: group,
                openCount: 1,
                lastOpenedAt: date
            ))
        }
        records.sort {
            if $0.lastOpenedAt == $1.lastOpenedAt { return $0.key < $1.key }
            return $0.lastOpenedAt > $1.lastOpenedAt
        }
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
    }
}
