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

    // B1: the way without Plus, only without Plus and while not saving here;
    // 11/24: and only after the Plus screen was closed without buying.
    func testProfileTransferOnlyWithoutPlusAndWhileOff() {
        XCTAssertTrue(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: false, enabled: false, plusDeclined: true))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: false, enabled: false, plusDeclined: false))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: true, enabled: false, plusDeclined: true))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: false, enabled: true, plusDeclined: true))
        XCTAssertFalse(AppRecordSettingsRules.offersProfileTransfer(hasPlusHere: true, enabled: true, plusDeclined: true))
    }

    // 11/24: after the Apple sign-in the screen goes on by itself.
    func testStartGoesOnBySignInAlone() {
        let unlinked = ManagedPreservationMembership(linked: false, status: .unknown)
        let linked = ManagedPreservationMembership(linked: true, status: .active)
        let ended = ManagedPreservationMembership(linked: true, status: .expired)
        func step(_ membership: ManagedPreservationMembership?, enabled: Bool = false, plus: Bool = false,
                  checking: Bool = false, offers: Bool = true, offered: Bool = false) -> AppRecordSettingsRules.StartStep {
            AppRecordSettingsRules.startStep(membership: membership, enabled: enabled, hasPlusHere: plus,
                                             plusChecking: checking, offersPlus: offers, plusOffered: offered)
        }
        XCTAssertEqual(step(nil), .wait)
        // Plus here: linked, then saving starts.
        XCTAssertEqual(step(unlinked, plus: true), .link)
        XCTAssertEqual(step(linked, plus: true), .enable)
        // Saved before: what was saved comes back, also after Plus ended.
        XCTAssertEqual(step(linked), .enable)
        XCTAssertEqual(step(ended), .enable)
        XCTAssertEqual(step(ended, enabled: true), .stop)
        // No Plus: the Plus screen opens once, never while Plus is still being checked.
        XCTAssertEqual(step(unlinked), .offerPlus)
        XCTAssertEqual(step(unlinked, checking: true), .wait)
        XCTAssertEqual(step(unlinked, offered: true), .stop)
        XCTAssertEqual(step(unlinked, offers: false), .stop)
    }

    // 11/24: off — one state, one sentence, one button; never P01 or 連携.
    func testOffStateIsOneStateOneLineOneButton() {
        typealias Rules = AppRecordSettingsRules
        let signIn = Rules.offState(signedIn: false, working: false, linkStop: nil, needsPlus: false)
        XCTAssertEqual(signIn, .init(title: "自動保存はオフです", line: "この子のこととメモを自動で保存して、新しいiPhoneに戻せます。",
                                     action: .signIn))
        XCTAssertEqual(Rules.offState(signedIn: true, working: true, linkStop: nil, needsPlus: false),
                       .init(title: "保存を始めています…", line: nil, action: .none))
        XCTAssertEqual(Rules.offState(signedIn: true, working: false, linkStop: nil, needsPlus: true),
                       .init(title: "自動保存はオフです", line: "保存にはPlusが必要です。", action: .plus))
        XCTAssertEqual(Rules.offState(signedIn: true, working: false, linkStop: nil, needsPlus: false).action, .start)
        // A link that stopped outranks working: the contact page is the one button.
        XCTAssertEqual(Rules.offState(signedIn: true, working: true, linkStop: .usedElsewhere, needsPlus: false),
                       .init(title: "このPlusはほかの保存で使われています", line: "購入し直さずに、お問い合わせください。",
                             action: .contact))
        XCTAssertEqual(Rules.offState(signedIn: true, working: false, linkStop: .plusUnconfirmed, needsPlus: false),
                       .init(title: "Plusを確かめられません", line: "購入し直さずに、お問い合わせください。", action: .contact))
        XCTAssertEqual(Rules.linkStop(.membershipLinkConflict), .usedElsewhere)
        XCTAssertEqual(Rules.linkStop(.billingIdentityUnavailable), .plusUnconfirmed)
        XCTAssertNil(Rules.linkStop(.membershipLinkExpired))
        XCTAssertNil(Rules.linkStop(nil))
        for error: ManagedPreservationError in [.membershipLinkConsent, .membershipLinkConflict, .membershipLinkExpired,
                                                .billingIdentityUnavailable, .billingIdentityChanged] {
            XCTAssertFalse(error.errorDescription!.contains("連携"))
            XCTAssertFalse(error.errorDescription!.contains("設定の「お問い合わせ」"))
        }
        XCTAssertFalse(AppRecordBindingError.destination.errorDescription!.contains("P01"))
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

    // 11/24: 「オン・今日 8:02」 on the 自動保存 row; just 「オン」 without a known time.
    func testAutoSaveRowShowsWhenItLastSaved() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = date(2026, 11, 24, 12, 0)
        XCTAssertEqual(AutoSaveRowWords.on(lastSaved: nil, now: now, calendar: calendar), "オン")
        XCTAssertEqual(AutoSaveRowWords.on(lastSaved: date(2026, 11, 24, 8, 2), now: now, calendar: calendar), "オン・今日 8:02")
        XCTAssertEqual(AutoSaveRowWords.on(lastSaved: date(2026, 11, 23, 21, 10), now: now, calendar: calendar), "オン・昨日 21:10")
        XCTAssertEqual(AutoSaveRowWords.on(lastSaved: date(2026, 11, 20, 9, 0), now: now, calendar: calendar), "オン・11月20日")
        XCTAssertEqual(AutoSaveRowWords.on(lastSaved: date(2025, 12, 31, 9, 0), now: now, calendar: calendar), "オン・2025年12月31日")
        // A clock set back never shows a time in the future.
        XCTAssertEqual(AutoSaveRowWords.on(lastSaved: date(2026, 11, 25, 9, 0), now: now, calendar: calendar), "オン")
    }

    // A1: one wording for what 自動保存 keeps.
    func testSavedContentsWording() {
        XCTAssertEqual(AutoSaveWording.contents, "この子のこととメモ")
    }
}
