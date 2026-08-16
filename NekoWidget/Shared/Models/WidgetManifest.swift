import Foundation

enum WidgetImageVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case small
    case medium
    case large

    var pixelWidth: Int {
        switch self {
        case .small, .large:
            return 400
        case .medium:
            return 800
        }
    }

    var pixelHeight: Int {
        switch self {
        case .small:
            return 400
        case .medium:
            return 374
        case .large:
            return 420
        }
    }

    var maximumPixelDimension: Int {
        max(pixelWidth, pixelHeight)
    }

    var pixelDescription: String {
        "\(pixelWidth)x\(pixelHeight)"
    }
}

struct WidgetCacheFilenames: Codable, Equatable, Sendable {
    var small: String
    var medium: String
    var large: String

    func filename(for variant: WidgetImageVariant) -> String {
        switch variant {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var all: [String] { [small, medium, large] }
}

struct WidgetManifestItem: Codable, Identifiable, Equatable, Sendable {
    var localIdentifier: String
    /// Legacy/default filename retained so a build-4 widget can still read a
    /// manifest briefly while the build-5 app and extension are being updated.
    var cacheFilename: String
    var cacheFilenames: WidgetCacheFilenames?
    var scheduledDate: Date

    init(
        localIdentifier: String,
        cacheFilename: String,
        cacheFilenames: WidgetCacheFilenames? = nil,
        scheduledDate: Date
    ) {
        self.localIdentifier = localIdentifier
        self.cacheFilename = cacheFilename
        self.cacheFilenames = cacheFilenames
        self.scheduledDate = scheduledDate
    }

    func cacheFilename(for variant: WidgetImageVariant) -> String {
        cacheFilenames?.filename(for: variant) ?? cacheFilename
    }

    var allCacheFilenames: [String] {
        cacheFilenames?.all ?? [cacheFilename]
    }

    var id: String { "\(localIdentifier)-\(scheduledDate.timeIntervalSince1970)" }
}

struct WidgetManifest: Codable, Equatable, Sendable {
    var items: [WidgetManifestItem]
    var generatedAt: Date

    static let empty = WidgetManifest(items: [], generatedAt: .distantPast)
}

/// Each widget family records every filename in the generation it handed to
/// WidgetKit. The app retains those leased generations even when rebuilds are
/// coalesced and the manifest on disk has already advanced.
struct WidgetTimelineLease: Codable, Equatable, Sendable {
    var cacheFilenames: [String]
    var recordedAt: Date
}
