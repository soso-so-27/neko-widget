import AppIntents
import Foundation
import WidgetKit

struct ToggleWidgetLikeIntent: AppIntent {
    static var title: LocalizedStringResource = "写真の思い出状態を切り替える"
    static var description = IntentDescription(
        "表示中の写真を思い出に追加、または思い出から外します。"
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

/// The received-photo memory mark is private even though its user-facing name
/// now matches the personal-library collection. It never creates a relay
/// request or notifies the other participant.
struct ToggleFamilyWidgetBookmarkIntent: AppIntent {
    static var title: LocalizedStringResource = "届いた写真を思い出へ取り込む"
    static var description = IntentDescription(
        "写真アプリへの取り込みを確認するため、ねこのまどを開きます。"
    )
    static var isDiscoverable = false
    static var openAppWhenRun = true

    @Parameter(title: "表示写真キー")
    var sourceDigest: String

    init() {
        sourceDigest = ""
    }

    init(sourceDigest: String) {
        self.sourceDigest = sourceDigest
    }

    func perform() async throws -> some IntentResult {
        guard let momentID = FamilyWidgetActionTargetResolver.momentID(
            forSourceDigest: sourceDigest
        ) else {
            SharedLog.widget.warning(
                "bookmark",
                "Stale or invalid Family Widget bookmark action was ignored",
                metadata: ["source": SharedLog.shortHash(sourceDigest)]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            return .result()
        }

        SharedLog.widget.info(
            "bookmark",
            "Family Widget opened the host app for memory import",
            metadata: ["source": SharedLog.shortHash(sourceDigest)]
        )
        return .result()
    }

}

/// Queues the same fixed, idempotent wire reaction used by the app. The
/// compatibility name remains `paw` internally, while the Widget truthfully
/// presents the user action as a heart. Relay I/O is still owned by the host
/// app, so the Widget changes to a pending clock until a foreground/background
/// synchronization commits it.
struct SendFamilyWidgetHeartIntent: AppIntent {
    static var title: LocalizedStringResource = "ハートを送信待ちに追加"
    static var description = IntentDescription(
        "表示中の届いた写真に、1回だけハートを送信待ちとして追加します。"
    )
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "表示写真キー")
    var sourceDigest: String

    init() {
        sourceDigest = ""
    }

    init(sourceDigest: String) {
        self.sourceDigest = sourceDigest
    }

    func perform() async throws -> some IntentResult {
        guard let momentID = FamilyWidgetActionTargetResolver.momentID(
            forSourceDigest: sourceDigest
        ) else {
            SharedLog.widget.warning(
                "reaction",
                "Stale or invalid Family Widget heart action was ignored",
                metadata: ["source": SharedLog.shortHash(sourceDigest)]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            return .result()
        }

        do {
            let lifecycleToken = try SharingLifecycleGate.issueToken()
            let item = try MomentSharingStateStore.queuePaw(
                momentID: momentID,
                now: Date(),
                validating: lifecycleToken
            )
            SharedLog.widget.info(
                "reaction",
                "Family Widget heart queued",
                metadata: [
                    "phase": item.phase.rawValue,
                    "source": SharedLog.shortHash(sourceDigest),
                ]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        } catch {
            SharedLog.widget.error(
                "reaction",
                "Family Widget heart could not be queued",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .widgetLike,
                    additional: ["source": SharedLog.shortHash(sourceDigest)]
                )
            )
            throw error
        }
        return .result()
    }
}

/// Resolves only the currently published received image. An intent from a
/// stale Widget generation fails closed instead of changing another photo.
/// The opaque moment ID stays in App Group storage and is never an App Intent
/// parameter.
private enum FamilyWidgetActionTargetResolver {
    static func momentID(forSourceDigest sourceDigest: String) -> String? {
        guard sourceDigest.utf8.count == 64,
              sourceDigest.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }),
              let url = SharedContainer.familyWidgetManifestURL,
              let manifest = try? AtomicJSON.read(FamilyWidgetManifest.self, from: url),
              manifest.schemaVersion == FamilyWidgetManifest.schemaVersion,
              let item = manifest.item,
              item.sourceDigest == sourceDigest,
              item.hasValidBookmarkTarget
        else { return nil }
        return item.momentID
    }
}
