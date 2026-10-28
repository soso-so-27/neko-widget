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
        let enforced = PersonalWidgetMembershipStore.isEnforced
        let membership = PersonalWidgetMembershipStore.read()
        guard !enforced || membership != nil else { return .result() }
        // Old entries refresh only; they cannot reveal tomorrow's photo.
        _ = try? CloudyWindowStore.shared.reveal(selectionID: selectionID, scopeID: scopeID, photoID: photoID,
            allowsSelection: PersonalWidgetMembershipStore.allowsSelection(),
            selectionValidUntil: enforced ? membership?.validUntil : nil)
        return .result()
    }
}
