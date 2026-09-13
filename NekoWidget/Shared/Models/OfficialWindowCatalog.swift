import Foundation

/// The build-owned registry defines which public windows the app offers.
/// Unknown but well-formed source IDs remain identifiable without falling back
/// to the legacy feed; discovery does not create definitions from remote data.
struct PublicWindowDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let subtitle: String
    let endpoint: URL?

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

    func validate(at now: Date, expectedChannelID: String = Self.sourceID) throws {
        guard schemaVersion == 1, Self.isIdentifier(expectedChannelID), channelID == expectedChannelID,
              generatedAt <= now.addingTimeInterval(300), validUntil > now,
              validUntil > generatedAt,
              validUntil.timeIntervalSince(generatedAt) <= Self.maximumLifetime,
              photos.count <= 60, Set(photos.map(\.id)).count == photos.count,
              enabled || photos.isEmpty else { throw OfficialWindowError.invalidCatalog }
        for photo in photos {
            guard Self.isIdentifier(photo.id), Self.isIdentifier(photo.catID),
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
