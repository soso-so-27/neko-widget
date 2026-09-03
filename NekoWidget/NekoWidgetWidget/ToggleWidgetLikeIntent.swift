import AppIntents
import CryptoKit
import Foundation
import WidgetKit

struct ToggleWidgetLikeIntent: AppIntent {
    static var title: LocalizedStringResource = "写真を思い出に残す"
    static var description = IntentDescription(
        "表示中の写真を思い出に残します。解除はアプリで確認して行います。"
    )
    // Build 6 uses this intent only as the widget's private interaction. It is
    // deliberately not offered as a Siri or Shortcuts action.
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "写真ID")
    var localIdentifier: String

    // Keep the parameter name so buttons rendered by an older timeline remain
    // decodable. The add-only action intentionally ignores its value.
    @Parameter(title: "以前の状態（互換用）")
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
            // This action is deliberately add-only. A stale Widget can still
            // show the unsaved control after the app has saved the photo; a
            // toggle would then silently remove the canonical memory.
            let mutation = try SharedLikeStore.set(
                localIdentifier: localIdentifier,
                isLiked: true,
                at: changedAt,
                source: "interactive-widget"
            )
            SharedLog.widget.info(
                "like",
                "Widget memory saved",
                metadata: [
                    "action": "liked",
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
                "Widget memory save failed",
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
    static var title: LocalizedStringResource = "届いた写真を取り込んで残す"
    static var description = IntentDescription(
        "写真アプリへの取り込みを確認するため、ねこのまどを開きます。"
    )
    static var isDiscoverable = false
    static var openAppWhenRun = true

    @Parameter(title: "表示写真キー")
    var sourceDigest: String

    /// Optional preserves decoding of a button archived by an older Widget.
    /// An absent value fails closed instead of targeting the currently active
    /// window, whose selection may have changed since that view was rendered.
    @Parameter(title: "まどキー")
    var localWindowID: String?

    init() {
        sourceDigest = ""
        localWindowID = nil
    }

    init(sourceDigest: String, localWindowID: String) {
        self.sourceDigest = sourceDigest
        self.localWindowID = localWindowID
    }

    func perform() async throws -> some IntentResult {
        guard let localWindowID,
              let momentID = FamilyWidgetActionTargetResolver.momentID(
                  forSourceDigest: sourceDigest,
                  localWindowID: localWindowID
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
/// app. The action therefore opens the host after it durably queues the heart;
/// the ordinary authenticated foreground synchronization commits it without
/// sharing room credentials with the Widget Extension.
struct SendFamilyWidgetHeartIntent: AppIntent {
    static var title: LocalizedStringResource = "ハートを送信待ちに追加"
    static var description = IntentDescription(
        "表示中の届いた写真に、1回だけハートを送信待ちとして追加します。"
    )
    static var isDiscoverable = false
    static var openAppWhenRun = true

    @Parameter(title: "表示写真キー")
    var sourceDigest: String

    @Parameter(title: "まど")
    var localWindowID: String?

    init() {
        sourceDigest = ""
        localWindowID = nil
    }

    init(sourceDigest: String) {
        self.sourceDigest = sourceDigest
        localWindowID = nil
    }

    init(sourceDigest: String, localWindowID: String) {
        self.sourceDigest = sourceDigest
        self.localWindowID = localWindowID
    }

    func perform() async throws -> some IntentResult {
        guard let localWindowID,
              let momentID = FamilyWidgetActionTargetResolver.momentID(
                  forSourceDigest: sourceDigest,
                  localWindowID: localWindowID
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

/// Resolves the exact received image rendered by WidgetKit. The active manifest
/// covers the newest generation; a short, bounded cache history covers an older
/// timeline that can remain visible after a second photo arrives. Every match
/// is revalidated against the active private window and inbox before mutation.
private enum FamilyWidgetActionTargetResolver {
    private struct RetainedGeneration: Codable {
        let sourceDigest: String
        let cacheFilenames: WidgetCacheFilenames
        let generatedAt: Date
    }

    private struct RetainedHistory: Codable {
        let generations: [RetainedGeneration]
    }

    private static let maximumGenerationCount = 4

    static func momentID(
        forSourceDigest sourceDigest: String,
        localWindowID: String
    ) -> String? {
        guard let uuid = UUID(uuidString: localWindowID) else { return nil }
        let canonicalWindowID = uuid.uuidString.lowercased()
        guard canonicalWindowID == localWindowID.lowercased(),
              PrivateWindowCatalogStore.activeEntry()?.localWindowID.lowercased()
                == canonicalWindowID,
              isLowercaseSourceDigest(sourceDigest),
              let url = SharedContainer.familyWidgetManifestURL(
                  localWindowID: canonicalWindowID
              ),
              let historyURL = SharedContainer.familyWidgetCacheHistoryURL(
                  localWindowID: canonicalWindowID
              )
        else { return nil }

        let currentMomentID: String? = {
            guard let manifest = try? AtomicJSON.read(
                    FamilyWidgetManifest.self,
                    from: url
                  ),
                  manifest.schemaVersion == FamilyWidgetManifest.schemaVersion,
                  let item = manifest.item,
                  item.sourceDigest == sourceDigest,
                  item.hasValidBookmarkTarget
            else { return nil }
            return item.momentID
        }()

        let isRetainedGeneration: Bool = {
            guard let history = try? AtomicJSON.read(
                    RetainedHistory.self,
                    from: historyURL
                  ),
                  history.generations.count <= maximumGenerationCount
            else { return false }
            let now = Date()
            let cutoff = now.addingTimeInterval(-12 * 60 * 60)
            let futureLimit = now.addingTimeInterval(5 * 60)
            let digests = history.generations.map(\.sourceDigest)
            guard Set(digests).count == digests.count,
                  history.generations.allSatisfy({ generation in
                      isLowercaseSourceDigest(generation.sourceDigest)
                          && generation.cacheFilenames
                            == expectedCacheFilenames(generation.sourceDigest)
                          && generation.generatedAt >= cutoff
                          && generation.generatedAt <= futureLimit
                  })
            else { return false }
            return history.generations.contains { $0.sourceDigest == sourceDigest }
        }()

        guard currentMomentID != nil || isRetainedGeneration,
              let lifecycleToken = try? SharingLifecycleGate.issueToken()
        else { return nil }
        return try? MomentSharingStateStore.withStateWhileLifecycleLocked(
            validating: lifecycleToken
        ) { state in
            guard PrivateWindowCatalogStore.activeEntry()?.localWindowID.lowercased()
                    == canonicalWindowID
            else { return nil }
            let matches = state.inbox.filter {
                ($0.state == .available || $0.state == .acknowledged)
                    && $0.localJPEGFileName != nil
                    && familySourceDigest($0) == sourceDigest
            }
            guard matches.count == 1,
                  let target = matches.first,
                  currentMomentID == nil
                    || currentMomentID == target.id
                    || isRetainedGeneration
            else { return nil }
            return target.id
        }
    }

    private static func isLowercaseSourceDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func expectedCacheFilenames(
        _ sourceDigest: String
    ) -> WidgetCacheFilenames {
        WidgetCacheFilenames(
            small: "family-small-\(sourceDigest).jpg",
            medium: "family-medium-\(sourceDigest).jpg",
            large: "family-large-\(sourceDigest).jpg"
        )
    }

    private static func familySourceDigest(_ item: MomentInboxItem) -> String {
        let identity = [
            "family-widget-v3-cat-focused-full-bleed",
            item.id,
            String(item.committedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            String(item.receivedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
