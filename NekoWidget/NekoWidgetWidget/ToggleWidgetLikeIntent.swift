import AppIntents
import Foundation
import WidgetKit

struct ToggleWidgetLikeIntent: AppIntent {
    static var title: LocalizedStringResource = "猫の写真の好きを切り替える"
    static var description = IntentDescription(
        "表示中の猫の写真を好きに追加、または好きから解除します。"
    )
    // Build 6 uses this intent only as the widget's private interaction. It is
    // deliberately not offered as a Siri or Shortcuts action.
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "写真ID")
    var localIdentifier: String

    @Parameter(title: "現在の好き状態")
    var fallbackIsLiked: Bool

    init() {
        localIdentifier = ""
        fallbackIsLiked = false
    }

    init(localIdentifier: String, fallbackIsLiked: Bool) {
        self.localIdentifier = localIdentifier
        self.fallbackIsLiked = fallbackIsLiked
    }

    func perform() async throws -> some IntentResult {
        guard !localIdentifier.isEmpty else {
            SharedLog.widget.warning(
                "like",
                "Widget like intent ignored an empty photo identifier"
            )
            return .result()
        }

        let changedAt = Date()
        do {
            let mutation = try SharedLikeStore.toggle(
                localIdentifier: localIdentifier,
                fallbackIsLiked: fallbackIsLiked,
                at: changedAt,
                source: "interactive-widget"
            )
            SharedLog.widget.info(
                "like",
                "Widget like state changed",
                metadata: [
                    "action": mutation.record.isLiked ? "liked" : "unliked",
                    "asset": SharedLog.shortHash(localIdentifier),
                    "changedAt": Self.timestamp(changedAt),
                    "liked": "\(mutation.record.isLiked)",
                    "previousLiked": "\(mutation.previousIsLiked)",
                    "source": "interactive-widget"
                ]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        } catch {
            SharedLog.widget.error(
                "like",
                "Widget like state change failed",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .widgetLike,
                    additional: [
                        "asset": SharedLog.shortHash(localIdentifier),
                        "source": "interactive-widget",
                    ]
                )
            )
            // Keep the previous entry visible when persistence fails. Returning
            // the error lets WidgetKit end the invalidated state as a failure
            // instead of reloading a falsely-unliked timeline.
            throw error
        }
        return .result()
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
