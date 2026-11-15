import Foundation

/// Presentation-only name for an invite-only private window. It is never an
/// identifier, key input, plaintext server field, or
/// admission binding. The relay may retain only its bounded encrypted record.
/// All targets share this policy so a malformed App Group value falls back to
/// a neutral name instead of entering Widget or Share Extension UI.
enum PrivateWindowDisplayName {
    static let fallback = "新しいまど"
    static let maximumUTF8ByteCount = 64

    static func normalized(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value == normalized(value)
            && value.utf8.count <= maximumUTF8ByteCount
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    static func resolved(_ storedValue: String?) -> String {
        guard let storedValue, isValid(storedValue) else { return fallback }
        return storedValue
    }
}

enum WidgetImageVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case small
    case medium
    case large

    var pixelWidth: Int {
        switch self {
        case .small:
            return 500
        case .medium:
            return 1_050
        case .large:
            return 1_050
        }
    }

    var pixelHeight: Int {
        switch self {
        case .small:
            return 500
        case .medium:
            return 500
        case .large:
            return 1_100
        }
    }

    /// Per-family compressed budgets keep the higher-resolution canvases from
    /// regressing into visible JPEG blocks without allowing retained timeline
    /// generations to grow without bound.
    var maximumJPEGByteCount: Int {
        switch self {
        case .small:
            return 100 * 1_024
        case .medium:
            return 200 * 1_024
        case .large:
            return 220 * 1_024
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
    /// Optional during the rolling upgrade from Build 10. Sharing refuses to
    /// infer a plan when these fields are absent and asks the app to rebuild.
    var rendererVersion: String?
    var sourcePixelSize: WidgetSourcePixelSize?
    var renderPlans: WidgetRenderPlans?
    var sourceModificationDate: Date?

    init(
        localIdentifier: String,
        cacheFilename: String,
        cacheFilenames: WidgetCacheFilenames? = nil,
        scheduledDate: Date,
        rendererVersion: String? = nil,
        sourcePixelSize: WidgetSourcePixelSize? = nil,
        renderPlans: WidgetRenderPlans? = nil,
        sourceModificationDate: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.cacheFilename = cacheFilename
        self.cacheFilenames = cacheFilenames
        self.scheduledDate = scheduledDate
        self.rendererVersion = rendererVersion
        self.sourcePixelSize = sourcePixelSize
        self.renderPlans = renderPlans
        self.sourceModificationDate = sourceModificationDate
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

/// A personal rotation contains each available photo once. In particular,
/// manifests from older apps may pad a short library out to 20 slots: keeping
/// those copies can repeat the first photo at the cycle boundary and give
/// some photos more time than others. Keep the first scheduled copy, including
/// its exact cache files and date; the provider owns the time-based looping.
enum PersonalWidgetRotationPolicy {
    static func orderedUniqueItems(
        from items: [WidgetManifestItem]
    ) -> [WidgetManifestItem] {
        var identifiers = Set<String>()
        return Array(items.sorted { $0.scheduledDate < $1.scheduledDate }
            .filter { identifiers.insert($0.localIdentifier).inserted }
            .prefix(20))
    }
}

/// One privacy-minimized family Widget publication. `momentID` is the opaque
/// local lookup key required by the private-memory and heart controls. It never
/// leaves the App Group container and is not a participant, room, PhotoKit, or
/// cryptographic identifier. `sourceDigest` keeps cache generations stable and
/// is the only value serialized into the Widget's private App Intent.
struct FamilyWidgetManifestItem: Codable, Equatable, Sendable {
    /// Received photos are a device-local cache, not permanent storage. Keep
    /// the Widget on the same absolute 90-day boundary as the inbox even when
    /// the host app is not launched often enough to prune its files.
    static let maximumDisplayDuration: TimeInterval = 90 * 24 * 60 * 60

    var sourceDigest: String
    /// Optional keeps manifests written before Widget actions decodable. A
    /// missing or malformed value hides both controls without hiding the photo.
    var momentID: String? = nil
    var cacheFilenames: WidgetCacheFilenames
    var receivedAt: Date
    var freshUntil: Date
    /// Optional keeps manifests written before Widget heart-expiry scheduling
    /// decodable. New manifests copy the relay access deadline exactly.
    var heartExpiresAt: Date?
    /// Optional, device-local text for this exact received photo. Older
    /// extensions ignore it; older manifests decode it as nil. Never put this
    /// text in a URL, App Intent parameter, notification, or diagnostic log.
    var caption: String? = nil

    var displayUntil: Date {
        receivedAt.addingTimeInterval(Self.maximumDisplayDuration)
    }

    var validHeartExpiry: Date? {
        guard let heartExpiresAt,
              heartExpiresAt > receivedAt,
              heartExpiresAt <= displayUntil
        else { return nil }
        return heartExpiresAt
    }

    var hasValidBookmarkTarget: Bool {
        guard let momentID else { return false }
        return Self.isOpaqueIdentifier(momentID)
    }

    static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 95
        }
    }
}

/// Family output has a separate schema and file from the personal manifest so
/// an older extension can never interpret a received family photo as a local
/// PhotoKit asset.
struct FamilyWidgetManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    var item: FamilyWidgetManifestItem?
    /// Optional keeps schema-v1 manifests written before named windows
    /// decodable. Older extensions ignore this unknown key during rollout.
    var windowDisplayName: String? = nil
    var generatedAt: Date

    static let empty = FamilyWidgetManifest(
        item: nil,
        windowDisplayName: nil,
        generatedAt: .distantPast
    )
}

/// Each widget family records the filenames referenced by the timeline it
/// handed to WidgetKit. The app retains those leased files even when rebuilds
/// are coalesced and the manifest on disk has already advanced.
struct WidgetTimelineLease: Codable, Equatable, Sendable {
    var cacheFilenames: [String]
    var recordedAt: Date
}

/// What the app last learned about this iPhone's photos, for the words a
/// personal Widget shows when it has no photo (11/14). Optional and additive:
/// no value (the app has not run yet, or an older app) keeps 「写真を準備して
/// います」, and an older extension never reads the key.
enum WidgetLibraryStatus: String, Sendable {
    case photoAccessNeeded
    case noCatPhotos

    static let defaultsKey = "widgetLibraryStatus.v1"

    static func read(from defaults: UserDefaults?) -> Self? {
        defaults?.string(forKey: defaultsKey).flatMap(Self.init(rawValue:))
    }

    /// Writes only a change, so a repeated call costs one read.
    @discardableResult
    static func write(_ value: Self?, to defaults: UserDefaults?) -> Bool {
        guard let defaults, read(from: defaults) != value else { return false }
        if let value {
            defaults.set(value.rawValue, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        return true
    }
}

/// A cloudy window whose tag tap could not be saved (11/14). The next
/// timeline says so for that one selection, instead of staying cloudy without
/// a word. Cleared by the next saved reveal and whenever the app is opened.
enum CloudyWindowRevealFailure {
    static let defaultsKey = "cloudyWindowRevealFailure.v1"

    static func record(scopeID: String, selectionID: String, in defaults: UserDefaults?) {
        defaults?.set(["scope": scopeID, "selection": selectionID], forKey: defaultsKey)
    }

    static func matches(scopeID: String, selectionID: String, in defaults: UserDefaults?) -> Bool {
        guard let value = defaults?.dictionary(forKey: defaultsKey) as? [String: String] else { return false }
        return value["scope"] == scopeID && value["selection"] == selectionID
    }

    /// Returns whether a failure was stored.
    @discardableResult
    static func clear(in defaults: UserDefaults?) -> Bool {
        guard let defaults, defaults.object(forKey: defaultsKey) != nil else { return false }
        defaults.removeObject(forKey: defaultsKey)
        return true
    }
}

/// The words of a personal or cloudy Widget with no photo to show (11/14):
/// one state, one line of what to do, and only a cause the app knows.
enum WidgetStuckState: Equatable, Sendable {
    /// The app has not run yet, or has not finished the first look.
    case preparing
    case photoAccessNeeded
    case noCatPhotos
    /// The plan or the photo's image could not be read.
    case unreadable
    /// The tag tap on a cloudy window could not be saved.
    case revealFailed
    /// A cat's own cloudy window whose cat was deleted.
    case catRemoved

    /// The personal photo source. A known cause comes first; an unreadable
    /// plan says only that it cannot be shown now.
    static func personal(status: WidgetLibraryStatus?, unreadable: Bool) -> Self {
        switch status {
        case .photoAccessNeeded: return .photoAccessNeeded
        case .noCatPhotos: return .noCatPhotos
        case nil: return unreadable ? .unreadable : .preparing
        }
    }

    var title: String {
        switch self {
        case .preparing: return "写真を準備しています"
        case .photoAccessNeeded: return "写真の許可が必要です"
        case .noCatPhotos: return "猫の写真がまだありません"
        case .unreadable: return "いまは出せません"
        case .revealFailed: return "晴らせませんでした"
        case .catRemoved: return "この子の写真は出せなくなりました"
        }
    }

    var subtitle: String {
        switch self {
        case .preparing: return "アプリを開くと始まります"
        case .photoAccessNeeded, .revealFailed: return "タップしてアプリを開く"
        case .noCatPhotos: return "猫の写真を撮ると、ここに出ます"
        case .unreadable: return "アプリを開くと、また出ます"
        case .catRemoved: return "長押しして、別の写真を選んでください"
        }
    }
}
