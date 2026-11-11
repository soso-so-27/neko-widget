import AppIntents
import Foundation
import WidgetKit

struct RevealCloudyWindowIntent: AppIntent {
    static var title: LocalizedStringResource = "まどのくもりを晴らす"
    static var isDiscoverable = false
    static var openAppWhenRun = false
    @Parameter(title: "表示") var selectionID: String
    @Parameter(title: "まど") var scopeID: String
    @Parameter(title: "写真") var photoID: String

    init() { selectionID = ""; scopeID = ""; photoID = "" }
    init(selection: CloudyWindowSelection) {
        selectionID = selection.id
        scopeID = selection.scopeID
        photoID = selection.photoID
    }

    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget") }
        // Old entries refresh only; they cannot reveal tomorrow's photo.
        // The daily photo is free for everyone (11/11): no membership gate.
        _ = try? CloudyWindowStore.shared.reveal(selectionID: selectionID, scopeID: scopeID, photoID: photoID,
            allowsSelection: true, selectionValidUntil: nil)
        return .result()
    }
}

/// A tap on a cloudy window outside the 「タップで きょうの 1 枚」 capsule.
/// Without it WidgetKit opens the app on the last screen (11/5). Only the
/// capsule reveals (11/3), so this does nothing and never opens the app.
struct CloudyWindowIdleTapIntent: AppIntent {
    static var title: LocalizedStringResource = "くもりのまど"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}
