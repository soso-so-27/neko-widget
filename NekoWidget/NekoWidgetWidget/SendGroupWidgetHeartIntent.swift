import AppIntents
import Foundation
import WidgetKit

/// The heart under a group window's home-screen photo. Like the two-person
/// window's heart, the host app runs it in the background: only the app holds
/// the window's keys and signs the request. The Widget Extension never sends;
/// a misrouted extension run does nothing and keeps the photo as it is.
struct SendGroupWidgetHeartIntent: AppIntent {
    static var title: LocalizedStringResource = "ハートを送る"
    static var description = IntentDescription("表示中のまどの写真にハートを送ります。")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "まど")
    var windowID: String

    @Parameter(title: "写真")
    var photoID: String

    init() {
        windowID = ""
        photoID = ""
    }

    init(windowID: String, photoID: String) {
        self.windowID = windowID
        self.photoID = photoID
    }

    func perform() async throws -> some IntentResult {
        // Only the photo the app last handed to this Widget, never another.
        guard let cached = GroupWidgetCache.entry(windowID: windowID),
              cached.photoID == photoID
        else {
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            return .result()
        }
#if NEKO_HOST_APP
        if let client = GroupWindowClientProvider.production,
           (try? await client.setHeart(photoID: photoID, windowID: windowID,
                                       active: true, operationID: UUID())) != nil {
            try? GroupWidgetCache.markMyHeart(windowID: windowID, photoID: photoID)
        }
#endif
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        return .result()
    }
}

#if NEKO_HOST_APP
// Same host-process execution as SendFamilyWidgetHeartIntent on iOS 17–25.
@available(iOSApplicationExtension, unavailable)
extension SendGroupWidgetHeartIntent: ForegroundContinuableIntent {}
#endif
