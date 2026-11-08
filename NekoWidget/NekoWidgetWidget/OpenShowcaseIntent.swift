import AppIntents
import Foundation

/// A one-shot navigation request. The shared value contains no photo or cat data.
enum ShowcaseLaunchRequest {
    private static let key = "showcase.openRequest.v1"
    static let notification = Notification.Name("showcase.openRequested")

    static var hasPending: Bool {
        UserDefaults(suiteName: SharedContainer.appGroupIdentifier)?
            .string(forKey: key) != nil
    }

    static func request() {
        UserDefaults(suiteName: SharedContainer.appGroupIdentifier)?
            .set(UUID().uuidString, forKey: key)
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
