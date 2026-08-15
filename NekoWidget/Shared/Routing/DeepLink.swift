import Foundation

struct DeepLink: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case photo(localIdentifier: String)
    }

    private static let scheme = "nekowidget"
    let destination: Destination

    private init(destination: Destination) {
        self.destination = destination
    }

    var url: URL? {
        switch destination {
        case let .photo(localIdentifier):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "photo"
            components.queryItems = [URLQueryItem(name: "id", value: localIdentifier)]
            return components.url
        }
    }

    static func photo(localIdentifier: String) -> URL? {
        DeepLink(destination: .photo(localIdentifier: localIdentifier)).url
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "photo",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let identifier = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !identifier.isEmpty else {
            return nil
        }
        self.init(destination: .photo(localIdentifier: identifier))
    }
}
