import AppIntents
import Foundation

/// A one-shot navigation request. The shared value contains no photo or cat data.
/// 11/20: only the time of the tap. A tap means something only for the launch
/// it caused, so a request older than `lifetime` is dropped, never kept for
/// days (it used to force the 写真 tab on every return and open the showcase
/// long after). A value from an older build (no time) is dropped too.
enum ShowcaseLaunchRequest {
    private static let legacyKey = "showcase.openRequest.v1"
    private static let key = "showcase.openRequest.v2"
    static let notification = Notification.Name("showcase.openRequested")
    /// Long enough to grant photo access right after the tap, no longer.
    static let lifetime: TimeInterval = 120

    /// Whether a tap at `requestedAt` still asks for the showcase at `now`.
    /// A time in the future beyond a small clock skew counts as stale.
    static func isLive(requestedAt: Date?, now: Date) -> Bool {
        guard let requestedAt else { return false }
        let age = now.timeIntervalSince(requestedAt)
        return age >= -10 && age <= lifetime
    }

    /// Drops an expired or old-format request as it is read.
    static var hasPending: Bool {
        guard let defaults = UserDefaults(suiteName: SharedContainer.appGroupIdentifier) else { return false }
        defaults.removeObject(forKey: legacyKey)
        let stored = defaults.object(forKey: key) as? Double
        guard isLive(requestedAt: stored.map(Date.init(timeIntervalSince1970:)), now: Date()) else {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return false
        }
        return true
    }

    static func request() {
        let defaults = UserDefaults(suiteName: SharedContainer.appGroupIdentifier)
        defaults?.removeObject(forKey: legacyKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func consume() -> Bool {
        guard let defaults = UserDefaults(suiteName: SharedContainer.appGroupIdentifier),
              hasPending else { return false }
        defaults.removeObject(forKey: key)
        return true
    }
}

/// The iOS 17 widget's link (round 2): Control Center and Siri need iOS 18.
/// It carries nothing but the screen, and only leaves the same one-shot request.
enum ShowcaseWidgetRoute {
    static let url = URL(string: "nekowidget://showcase")!

    static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "nekowidget"
            && components.host?.lowercased() == "showcase"
            && components.path.isEmpty
            && components.queryItems == nil
            && components.fragment == nil
            && components.user == nil
    }
}

enum ShowcaseOpenTarget: String, AppEnum {
    case prepared

    static var typeDisplayRepresentation = TypeDisplayRepresentation("見せる写真")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .prepared: DisplayRepresentation(title: "うちのこ")
    ]
}

struct OpenShowcaseIntent: OpenIntent {
    static var title: LocalizedStringResource = "写真を見せる"
    static var description = IntentDescription("自慢の9枚を開きます。")

    @Parameter(title: "開く写真") var target: ShowcaseOpenTarget

    init() { target = .prepared }
    init(target: ShowcaseOpenTarget) { self.target = target }

    func perform() async throws -> some IntentResult {
        ShowcaseLaunchRequest.request()
        return .result()
    }
}
