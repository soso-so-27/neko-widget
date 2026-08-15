import Foundation

struct LibrarySnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var assets: [AssetRecord]
    var scanState: ScanState
    var settings: AppSettings
    var albumLocalIdentifier: String?
    var updatedAt: Date

    static let empty = LibrarySnapshot(
        schemaVersion: 1,
        assets: [],
        scanState: .idle,
        settings: .default,
        albumLocalIdentifier: nil,
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
