import Foundation

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

    func validate(at now: Date) throws {
        guard schemaVersion == 1, channelID == Self.sourceID,
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
    let photoID: String?
    var id: String { photoID ?? OfficialWindowCatalog.sourceID }

    init(photoID: String? = nil) { self.photoID = photoID }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "nekowidget", parts.host == "official-window",
              parts.path.isEmpty, parts.fragment == nil, parts.user == nil,
              parts.password == nil, parts.port == nil else { return nil }
        let items = parts.queryItems ?? []
        guard items.count <= 1, items.allSatisfy({ $0.name == "photo" }),
              items.isEmpty || items.first?.value.map(OfficialWindowCatalog.isIdentifier) == true
        else { return nil }
        photoID = items.first?.value
    }

    var url: URL? {
        guard photoID.map(OfficialWindowCatalog.isIdentifier) ?? true else { return nil }
        var parts = URLComponents()
        parts.scheme = "nekowidget"
        parts.host = "official-window"
        parts.queryItems = photoID.map { [URLQueryItem(name: "photo", value: $0)] }
        return parts.url
    }
}
