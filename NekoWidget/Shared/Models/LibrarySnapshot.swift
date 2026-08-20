import Foundation

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
