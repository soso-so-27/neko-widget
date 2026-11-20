import AppIntents
import Foundation
import WidgetKit

struct RevealCloudyWindowIntent: AppIntent {
    static var title: LocalizedStringResource = "まどのくもりを晴らす"
    static var isDiscoverable = false
    static var openAppWhenRun = false
    /// 11/20: on a locked iPhone (StandBy, the Lock Screen) the tag asks to
    /// unlock first, so someone else cannot clear the day's photo. Unlocked,
    /// the tap clears at once as before.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
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
        // Every tap reloads, also one that cleared nothing (an old entry, a
        // replaced selection, Photos access gone): the Widget then shows the
        // state as it is now instead of staying as it was.
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget") }
        // Old entries refresh only; they cannot reveal tomorrow's photo.
        // The daily photo is free for everyone (11/11): no membership gate.
        let defaults = UserDefaults(suiteName: SharedContainer.appGroupIdentifier)
        do {
            try CloudyWindowStore.shared.reveal(selectionID: selectionID, scopeID: scopeID, photoID: photoID,
                allowsSelection: true, selectionValidUntil: nil)
            CloudyWindowRevealFailure.clear(in: defaults)
        } catch {
            // Not saved: the reloaded timeline says so for this photo (11/14).
            // Only a thrown save counts; an old entry's tap stays a refresh.
            CloudyWindowRevealFailure.record(scopeID: scopeID, selectionID: selectionID, in: defaults)
        }
        return .result()
    }
}

/// A tap on a cloudy window outside the 「タップで、きょうの1枚」 capsule.
/// Without it WidgetKit opens the app on the last screen (11/5). Only the
/// capsule reveals (11/3), so this does nothing and never opens the app.
struct CloudyWindowIdleTapIntent: AppIntent {
    static var title: LocalizedStringResource = "くもりのまど"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}

/// 11/20: the heart under a group window's photo is not sent from a locked
/// iPhone by someone else either; unlocked, it is sent at once as before.
/// Declared here so the heart intent's own file stays as it is.
extension SendGroupWidgetHeartIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
}
