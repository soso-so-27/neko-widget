import XCTest
@testable import NekoWidget

/// 11/24: when 設定 and 自動保存 show a row, apart from the views.
/// Synthetic values only: no network, no purchase, no photos.
@MainActor
final class SettingsRulesTests: XCTestCase {
    private func future() -> Int64 { Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000) }

    // D1: 「Plusを始めると、保存が始まります。」 never next to saving the server allows.
    func testWaitsForPlusOnlyWhileSavingCannotHappen() {
        let unlinked = ManagedPreservationMembership(linked: false, status: .unknown)
        XCTAssertTrue(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: false, membership: unlinked,
                                                          hasPlusHere: false, entitlementChecking: false))
        let pilot = ManagedPreservationMembership(linked: false, status: .unknown, access: .pilot, pilotEndsAt: future())
        XCTAssertTrue(pilot.canSave)
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: false, membership: pilot,
                                                           hasPlusHere: false, entitlementChecking: false))
        // Not yet read, still checking, Plus here, ended, or not saving: never.
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: false, membership: nil,
                                                           hasPlusHere: false, entitlementChecking: false))
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: false, membership: unlinked,
                                                           hasPlusHere: false, entitlementChecking: true))
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: false, membership: unlinked,
                                                           hasPlusHere: true, entitlementChecking: false))
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: true, membership: unlinked,
                                                           hasPlusHere: false, entitlementChecking: false))
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: false, plusEnded: false, membership: unlinked,
                                                           hasPlusHere: false, entitlementChecking: false))
        let linked = ManagedPreservationMembership(linked: true, status: .active)
        XCTAssertFalse(AppRecordSettingsRules.waitsForPlus(enabled: true, plusEnded: false, membership: linked,
                                                           hasPlusHere: false, entitlementChecking: false))
    }

    // B1: the way without Plus, only without Plus and while not saving here.
    func testProfileTransferOnlyWithoutPlusAndWhileOff() {
        XCTAssertTrue(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: false, enabled: false))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: true, enabled: false))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: false, enabled: true))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: true, enabled: true))
    }

    // B3: 「ブロックした人」 only once someone is blocked or hidden.
    func testBlockedRowOnlyWithSomeoneHidden() {
        typealias Window = GroupWindowLocalPhotoStore.KnownWindow
        XCTAssertFalse(GroupHiddenMembersView.hasHiddenMembers([]))
        XCTAssertFalse(GroupHiddenMembersView.hasHiddenMembers([Window(id: "a", name: "まど"),
                                                                Window(id: "b", name: "まど", hiddenMembers: [])]))
        XCTAssertTrue(GroupHiddenMembersView.hasHiddenMembers([
            Window(id: "a", name: "まど"),
            Window(id: "b", name: "まど", hiddenMembers: [.init(id: "p", name: "みけ", blocked: true)]),
        ]))
    }

    // B2: the Plus note in 「アカウントとデータを消す」 never to someone without Plus.
    func testPlusNoteOnlyWhenPlusIsOrMayBeActive() {
        XCTAssertFalse(PlusCancelNote.isShown(.inactive))
        XCTAssertFalse(PlusCancelNote.isShown(.disabled))
        XCTAssertTrue(PlusCancelNote.isShown(.checking))
        XCTAssertTrue(PlusCancelNote.isShown(.indeterminate(lastServerConfirmed: nil)))
    }

    // A1: one wording for what 自動保存 keeps.
    func testSavedContentsWording() {
        XCTAssertEqual(AutoSaveWording.contents, "この子のこととメモ")
    }
}
