import AppIntents
import Foundation
import WidgetKit

/// Personal-photo selection never opens the app. The shared store owns the
/// day, eligibility, idempotency and commit; an old entry only requests a fresh
/// rendering and cannot spend tomorrow's turn.
struct DailyPersonalPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "まどの写真をもう一枚"
    static var description = IntentDescription("このiPhoneの猫写真を1日に1回切り替えます。")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "表示要求") var tokenID: String
    @Parameter(title: "表示の作成日時") var createdAt: Date
    @Parameter(title: "操作の日付") var eligibilityDay: String
    @Parameter(title: "写真源") var sourceID: String
    @Parameter(title: "表示していた写真") var photoID: String
    @Parameter(title: "対象範囲") var scopeRevision: String
    @Parameter(title: "状態の更新のみ") var refreshOnly: Bool

    init() {
        tokenID = ""
        createdAt = .distantPast
        eligibilityDay = ""
        sourceID = "personal-library"
        photoID = ""
        scopeRevision = ""
        refreshOnly = true
    }

    init(token: PersonalRediscoveryEntryToken) {
        tokenID = token.id
        createdAt = token.createdAt
        eligibilityDay = token.eligibilityDay
        sourceID = token.sourceID
        photoID = token.photoID
        scopeRevision = token.scopeRevision
        refreshOnly = false
    }

    func perform() async throws -> some IntentResult {
        if !refreshOnly {
            let token = PersonalRediscoveryEntryToken(id: tokenID, createdAt: createdAt,
                eligibilityDay: eligibilityDay, sourceID: sourceID, photoID: photoID,
                scopeRevision: scopeRevision)
            do {
                _ = try PersonalRediscoveryStore.shared.perform(token: token,
                    operationID: UUID().uuidString, operationCreatedAt: Date())
            } catch {
                // The failed transaction cannot claim success in the entry.
                // Reload the canonical state, retaining the prior photo and
                // unused turn when the store did not commit a new selection.
                SharedLog.widget.error("timeline", "Personal photo turn could not be completed",
                    metadata: SharedLog.errorMetadata(error, category: .widgetTimeline))
            }
        }
        // State is durable before WidgetKit is asked to redraw. A used check
        // remains a refresh-only action; it never changes into an app link.
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        return .result()
    }
}
