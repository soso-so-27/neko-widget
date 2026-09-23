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

enum ShowcaseOpenTarget: String, AppEnum {
    case prepared

    static var typeDisplayRepresentation = TypeDisplayRepresentation("見せる写真")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .prepared: DisplayRepresentation(title: "うちのこ")
    ]
}

struct OpenShowcaseIntent: OpenIntent {
    static var title: LocalizedStringResource = "うちのこを見せる"
    static var description = IntentDescription("準備した猫の写真だけを開きます。")

    @Parameter(title: "開く写真") var target: ShowcaseOpenTarget

    init() { target = .prepared }
    init(target: ShowcaseOpenTarget) { self.target = target }

    func perform() async throws -> some IntentResult {
        ShowcaseLaunchRequest.request()
        return .result()
    }
}
