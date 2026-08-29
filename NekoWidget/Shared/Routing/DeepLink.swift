import Foundation

struct DeepLink: Equatable, Sendable {
    enum FamilyWindowAction: String, Equatable, Sendable {
        case viewPhoto = "view-photo"
    }

    enum Destination: Equatable, Sendable {
        case photo(localIdentifier: String)
        case familyWindow(
            localWindowID: String?,
            sourceDigest: String?,
            action: FamilyWindowAction?
        )
    }

    private static let scheme = "nekowidget"
    let destination: Destination
    /// The start of the WidgetKit entry that opened the app. Older widget
    /// URLs do not carry this value, so it remains optional for compatibility.
    let shownAt: Date?

    private init(destination: Destination, shownAt: Date? = nil) {
        self.destination = destination
        self.shownAt = shownAt
    }

    var url: URL? {
        switch destination {
        case let .photo(localIdentifier):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "photo"
            var queryItems = [URLQueryItem(name: "id", value: localIdentifier)]
            if let shownAt {
                queryItems.append(
                    URLQueryItem(name: "shownAt", value: Self.iso8601String(shownAt))
                )
            }
            components.queryItems = queryItems
            return components.url
        case let .familyWindow(localWindowID, sourceDigest, action):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "family-window"
            var queryItems: [URLQueryItem] = []
            if let localWindowID {
                queryItems.append(URLQueryItem(name: "window", value: localWindowID))
            }
            if let sourceDigest {
                queryItems.append(URLQueryItem(name: "source", value: sourceDigest))
            }
            if let action {
                queryItems.append(URLQueryItem(name: "action", value: action.rawValue))
            }
            components.queryItems = queryItems.isEmpty ? nil : queryItems
            return components.url
        }
    }

    static func photo(localIdentifier: String, shownAt: Date? = nil) -> URL? {
        DeepLink(
            destination: .photo(localIdentifier: localIdentifier),
            shownAt: shownAt
        ).url
    }

    static func familyWindow() -> URL? {
        DeepLink(destination: .familyWindow(
            localWindowID: nil,
            sourceDigest: nil,
            action: nil
        )).url
    }

    static func familyWindow(localWindowID: String) -> URL? {
        guard let uuid = UUID(uuidString: localWindowID),
              uuid.uuidString.lowercased() == localWindowID.lowercased()
        else { return nil }
        return DeepLink(
            destination: .familyWindow(
                localWindowID: localWindowID.lowercased(),
                sourceDigest: nil,
                action: nil
            )
        ).url
    }

    static func familyWindow(localWindowID: String, sourceDigest: String) -> URL? {
        guard let uuid = UUID(uuidString: localWindowID),
              uuid.uuidString.lowercased() == localWindowID.lowercased(),
              Self.isLowercaseSHA256(sourceDigest)
        else { return nil }
        return DeepLink(
            destination: .familyWindow(
                localWindowID: localWindowID.lowercased(),
                sourceDigest: sourceDigest,
                action: nil
            )
        ).url
    }

    static func familyWindowPhoto(localWindowID: String, sourceDigest: String) -> URL? {
        guard let uuid = UUID(uuidString: localWindowID),
              uuid.uuidString.lowercased() == localWindowID.lowercased(),
              Self.isLowercaseSHA256(sourceDigest)
        else { return nil }
        return DeepLink(
            destination: .familyWindow(
                localWindowID: localWindowID.lowercased(),
                sourceDigest: sourceDigest,
                action: .viewPhoto
            )
        ).url
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        if host == "family-window" {
            guard components.path.isEmpty, components.fragment == nil else { return nil }
            let items = components.queryItems ?? []
            let names = items.map(\.name)
            guard items.count <= 3,
                  Set(names).count == names.count,
                  names.allSatisfy({
                      $0 == "window" || $0 == "source" || $0 == "action"
                  }),
                  items.allSatisfy({ $0.value != nil })
            else { return nil }
            let localWindowID: String?
            if let rawValue = items.first(where: { $0.name == "window" })?.value {
                guard let uuid = UUID(uuidString: rawValue),
                      uuid.uuidString.lowercased() == rawValue.lowercased()
                else { return nil }
                localWindowID = rawValue.lowercased()
            } else {
                localWindowID = nil
            }
            let sourceDigest = items.first(where: { $0.name == "source" })?.value
            let action: FamilyWindowAction?
            if let rawAction = items.first(where: { $0.name == "action" })?.value {
                guard let parsedAction = FamilyWindowAction(rawValue: rawAction) else {
                    return nil
                }
                action = parsedAction
            } else {
                action = nil
            }
            guard sourceDigest == nil || localWindowID != nil,
                  sourceDigest.map(Self.isLowercaseSHA256) ?? true,
                  action == nil || sourceDigest != nil
            else { return nil }
            self.init(destination: .familyWindow(
                localWindowID: localWindowID,
                sourceDigest: sourceDigest,
                action: action
            ))
            return
        }
        guard host == "photo",
              let identifier = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !identifier.isEmpty else {
            return nil
        }
        let shownAtValue = components.queryItems?
            .first(where: { $0.name == "shownAt" })?
            .value
        self.init(
            destination: .photo(localIdentifier: identifier),
            shownAt: shownAtValue.flatMap(Self.date(fromISO8601:))
        )
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(fromISO8601 value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
