import Foundation

/// Shared by the app and Widget. Distribution intent, not receipt environment,
/// controls internal-only UI; public TestFlight and App Review use sandbox too.
enum InternalBuildPresentationAvailability {
    static var isAvailable: Bool {
#if DEBUG
        !CommandLine.arguments.contains("--review-public-presentation")
#else
        (Bundle.main.object(forInfoDictionaryKey: "SharingReleaseMode") as? String) == "media-staging"
#endif
    }
}

/// The build-owned registry defines which public windows the app offers.
/// Unknown but well-formed source IDs remain identifiable without falling back
/// to the legacy feed; discovery does not create definitions from remote data.
struct PublicWindowDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let subtitle: String
    let endpoint: URL?
    let catID: String?

    init(id: String, displayName: String, subtitle: String, endpoint: URL?, catID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.endpoint = endpoint
        self.catID = catID
    }

    var widgetSourceID: String {
        id == OfficialWindowCatalog.sourceID ? id : "public-window:" + id
    }

    static func windowID(from sourceID: String) -> String? {
        if sourceID == OfficialWindowCatalog.sourceID { return sourceID }
        let prefix = "public-window:"
        guard sourceID.hasPrefix(prefix) else { return nil }
        let id = String(sourceID.dropFirst(prefix.count))
        return OfficialWindowCatalog.isIdentifier(id) ? id : nil
    }
}

/// Public, operator-curated content. No PhotoKit identifiers, private-window
/// IDs, authentication credentials, or automatic cat identification belong here.
struct OfficialCatPhoto: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let catID: String
    let catName: String
    let credit: String
    let caption: String?
    let photographedOn: String?
    let publishedAt: Date
    let expiresAt: Date
    let imageFilename: String
    let sha256: String
    let width: Int
    let height: Int

    func isAvailable(at date: Date) -> Bool {
        publishedAt <= date && date < expiresAt
    }
}

struct OfficialWindowCatalog: Codable, Equatable, Sendable {
    static let sourceID = "official-cats"
    static let displayName = "どこかの猫"
    static let maximumLifetime: TimeInterval = 48 * 60 * 60
    let schemaVersion: Int
    let channelID: String
    let enabled: Bool
    let generatedAt: Date
    let validUntil: Date
    let photos: [OfficialCatPhoto]

    func availablePhotos(at date: Date) -> [OfficialCatPhoto] {
        guard enabled, date < validUntil, generatedAt <= date.addingTimeInterval(300) else { return [] }
        return photos.filter { $0.isAvailable(at: date) }.sorted {
            $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt
        }
    }

    /// The internal black-cat window changes at 00:00 JST.
    /// Never fall back to yesterday when today's image has not arrived yet.
    func widgetPhotos(at date: Date,
                      blackCatDailyEnabled: Bool = InternalBuildPresentationAvailability.isAvailable) -> [OfficialCatPhoto] {
        let available = availablePhotos(at: date)
        if channelID == "black-cats", blackCatDailyEnabled {
            let start = Self.nextBlackCatCutover(after: date).addingTimeInterval(-86_400)
            guard let latest = available.first, latest.publishedAt >= start else { return [] }
            return [latest]
        }
        return available
    }

    func widgetDeadline(for photo: OfficialCatPhoto,
                        blackCatDailyEnabled: Bool = InternalBuildPresentationAvailability.isAvailable) -> Date {
        let expiry = min(photo.expiresAt, validUntil)
        if channelID == "black-cats", blackCatDailyEnabled {
            return min(expiry, Self.nextBlackCatCutover(after: photo.publishedAt))
        }
        return expiry
    }

    static func nextBlackCatCutover(after date: Date) -> Date {
        let day: TimeInterval = 86_400
        return Date(timeIntervalSince1970: (floor((date.timeIntervalSince1970 + 9 * 3_600) / day) + 1) * day - 9 * 3_600)
    }

    func validate(at now: Date, expectedChannelID: String = Self.sourceID, expectedCatID: String? = nil) throws {
        guard schemaVersion == 1, Self.isIdentifier(expectedChannelID), channelID == expectedChannelID,
              expectedCatID.map(Self.isIdentifier) ?? true,
              generatedAt <= now.addingTimeInterval(300), validUntil > now,
              validUntil > generatedAt,
              validUntil.timeIntervalSince(generatedAt) <= Self.maximumLifetime,
              photos.count <= 60, Set(photos.map(\.id)).count == photos.count,
              enabled || photos.isEmpty else { throw OfficialWindowError.invalidCatalog }
        for photo in photos {
            guard Self.isIdentifier(photo.id), Self.isIdentifier(photo.catID),
                  expectedCatID.map({ photo.catID == $0 }) ?? true,
                  Self.isText(photo.catName, limit: 30), Self.isText(photo.credit, limit: 80),
                  photo.caption.map({ Self.isText($0, limit: 100, allowsNewlines: true) }) ?? true,
                  photo.photographedOn.map(Self.isCalendarDate) ?? true,
                  photo.publishedAt <= generatedAt, photo.expiresAt > photo.publishedAt,
                  photo.expiresAt.timeIntervalSince(photo.publishedAt) <= 14 * 24 * 60 * 60,
                  (1...2048).contains(photo.width), (1...2048).contains(photo.height),
                  Self.isSHA256(photo.sha256), photo.imageFilename == photo.sha256 + ".jpg"
            else { throw OfficialWindowError.invalidCatalog }
        }
    }

    static func isIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (97...102).contains($0) || (48...57).contains($0) }
    }

    private static func isText(_ text: String, limit: Int, allowsNewlines: Bool = false) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit
            && text.filter { $0 == "\n" }.count <= (allowsNewlines ? 2 : 0)
            && !text.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) && !(allowsNewlines && $0.value == 10)
            }
    }

    private static func isCalendarDate(_ text: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard text.count == 10, let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }
}

/// Public presentation metadata, fetched separately from the v1 photo catalog.
/// Only the current week and two preceding Mondays can name archive channels.
struct OfficialWeeklyThemeIndex: Codable, Equatable, Sendable {
    struct Theme: Codable, Equatable, Sendable {
        let name: String
        let weekStart: String
        let channelID: String

    }
    let schemaVersion: Int
    let generatedAt: Date
    let validUntil: Date
    let themes: [Theme]

    func validate(at now: Date) throws {
        guard schemaVersion == 1, generatedAt <= now.addingTimeInterval(300), validUntil > now,
              validUntil > generatedAt, validUntil.timeIntervalSince(generatedAt) <= OfficialWindowCatalog.maximumLifetime,
              (1...3).contains(themes.count) else { throw OfficialWindowError.invalidCatalog }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let day = calendar.startOfDay(for: now)
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        for (index, theme) in themes.enumerated() {
            let date = formatter.string(from: calendar.date(byAdding: .day, value: -7 * index, to: monday)!)
            guard theme.weekStart == date, !theme.name.isEmpty, theme.name.count <= 30,
                  theme.name == theme.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !theme.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }),
                  theme.channelID == (index == 0 ? "weekly-theme" : "weekly-theme-" + date.replacingOccurrences(of: "-", with: ""))
            else { throw OfficialWindowError.invalidCatalog }
        }
    }
}

enum OfficialWindowError: Error {
    case notConfigured, unavailableStorage, invalidCatalog, invalidImage, invalidResponse, subscriptionChanged
}

/// Keep the public route separate from the authenticated private-window router.
struct OfficialWindowRoute: Identifiable {
    let windowID: String
    let photoID: String?
    var id: String { windowID + "|" + (photoID ?? "") }

    init(windowID: String = OfficialWindowCatalog.sourceID, photoID: String? = nil) {
        self.windowID = windowID
        self.photoID = photoID
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "nekowidget",
              parts.path.isEmpty, parts.fragment == nil, parts.user == nil,
              parts.password == nil, parts.port == nil else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ $0.value.map(OfficialWindowCatalog.isIdentifier) == true })
        else { return nil }
        switch parts.host {
        case "official-window":
            guard items.count <= 1, items.allSatisfy({ $0.name == "photo" }) else { return nil }
            windowID = OfficialWindowCatalog.sourceID
        case "public-window":
            guard items.count <= 2, items.allSatisfy({ $0.name == "window" || $0.name == "photo" }),
                  let id = items.first(where: { $0.name == "window" })?.value else { return nil }
            windowID = id
        default:
            return nil
        }
        photoID = items.first(where: { $0.name == "photo" })?.value
    }

    var url: URL? {
        guard OfficialWindowCatalog.isIdentifier(windowID),
              photoID.map(OfficialWindowCatalog.isIdentifier) ?? true else { return nil }
        var parts = URLComponents()
        parts.scheme = "nekowidget"
        if windowID == OfficialWindowCatalog.sourceID {
            parts.host = "official-window"
            parts.queryItems = photoID.map { [URLQueryItem(name: "photo", value: $0)] }
        } else {
            parts.host = "public-window"
            parts.queryItems = [URLQueryItem(name: "window", value: windowID)]
                + (photoID.map { [URLQueryItem(name: "photo", value: $0)] } ?? [])
        }
        return parts.url
    }
}
