import Foundation

struct WidgetManifestItem: Codable, Identifiable, Equatable, Sendable {
    var localIdentifier: String
    var cacheFilename: String
    var scheduledDate: Date

    var id: String { "\(localIdentifier)-\(scheduledDate.timeIntervalSince1970)" }
}

struct WidgetManifest: Codable, Equatable, Sendable {
    var items: [WidgetManifestItem]
    var generatedAt: Date

    static let empty = WidgetManifest(items: [], generatedAt: .distantPast)
}

/// The extension records the filenames it actually handed to WidgetKit. The
/// app retains this one leased generation even when many rebuilds are coalesced
/// and the manifest on disk has already advanced.
struct WidgetTimelineLease: Codable, Equatable, Sendable {
    var cacheFilenames: [String]
    var recordedAt: Date
}
