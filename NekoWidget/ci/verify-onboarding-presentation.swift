import Foundation

@main
enum OnboardingPresentationVerifier {
    static func main() throws {
        try verifiesPagesInTheApprovedOrder()
        try verifiesPlusOfferIsTheLastSkippablePage()
        try verifiesApprovedJapaneseCopy()
        try verifiesOrdinaryFirstRunTransitions()
        try verifiesPermissionSkipEntersTheApp()
        try verifiesScanWithoutPhotoEntersTheApp()
        try verifiesWidgetGuideSkipCompletesFirstRun()
        try verifiesRevokedPhotoAccessReturnsToPermission()
        try verifiesResumeProgressIsClamped()
        try verifiesCompletionVersionOne()
        try verifiesWidgetGuideReplayIsNonDestructive()
        try verifiesWidgetPlacementRecoveryPolicy()
        try verifiesPartialScanFailureRetainsResultAndStopsProgress()
        try verifiesScanCountStartsWithTheFirstCat()
        try verifiesFirstPlusOfferComesLaterOnce()
        try verifiesEveryWayOutOfTheFirstRunCountsForTheFirstOffer()
        try verifiesFirstRunRemembersThePhotosTab()
        print("Onboarding presentation verifier passed")
    }

    private static func verifiesPartialScanFailureRetainsResultAndStopsProgress() throws {
        let error = "The photo scan stopped."
        try require(OnboardingPartialScanRecovery.message(hasPreliminaryResult: true, error: error) == error,
                    "a partial result hid its scan failure")
        try require(!OnboardingPartialScanRecovery.showsProgress(hasFinalResult: false,
            hasPreliminaryResult: true, error: error), "a failed partial scan still looked active")
        try require(OnboardingPartialScanRecovery.showsProgress(hasFinalResult: false,
            hasPreliminaryResult: true, error: nil), "a normal partial scan lost its progress")
        try require(!OnboardingPartialScanRecovery.showsProgress(hasFinalResult: true,
            hasPreliminaryResult: true, error: nil), "a completed scan showed active progress")
        for blank in ["", " \n "] {
            try require(OnboardingPartialScanRecovery.message(hasPreliminaryResult: true, error: blank) == nil,
                        "blank scan error produced a failure banner")
        }
        try require(OnboardingPartialScanRecovery.message(hasPreliminaryResult: false, error: error) == nil,
                    "the no-result failure became a partial-result screen")
    }

    /// 11/10: 「いま 0枚」 over an empty grid read as a failure.
    private static func verifiesScanCountStartsWithTheFirstCat() throws {
        try require(!OnboardingPartialScanRecovery.showsCount(hasPreliminaryResult: true, displayedCount: 0),
                    "the scan showed 「いま 0枚」")
        try require(OnboardingPartialScanRecovery.showsCount(hasPreliminaryResult: true, displayedCount: 1),
                    "the first cat did not show the count")
        try require(!OnboardingPartialScanRecovery.showsCount(hasPreliminaryResult: false, displayedCount: 3),
                    "a count showed before any result")
    }

    /// 11/10: the first Plus offer is not part of the first run. It comes
    /// once, on a later opening, after a cloudy window was cleared or from the
    /// next day, with a Widget placed, and never with another prompt or screen.
    private static func verifiesFirstPlusOfferComesLaterOnce() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let ended = ISO8601DateFormatter().date(from: "2026-11-10T01:00:00Z")!  // 10:00 JST
        let sameDay = ended.addingTimeInterval(3 * 3_600)
        let nextDay = ended.addingTimeInterval(20 * 3_600)                     // 06:00 JST the next day
        func due(dueSince: Date? = ended, shown: Bool = false, activeSince: Date? = sameDay, now: Date = sameDay,
                 cleared: Bool = true, offered: Bool = true, placed: Bool = true,
                 prompted: Bool = false, presented: Bool = false) -> Bool {
            FirstPlusOfferPolicy.isDue(dueSince: dueSince, shown: shown, activeSince: activeSince, now: now,
                hasClearedCloudyWindow: cleared, plusIsOffered: offered, widgetPlaced: placed,
                promptedThisLaunch: prompted, otherScreenPresented: presented, calendar: calendar)
        }
        try require(due(), "a later opening after clearing the window did not offer Plus")
        try require(!due(activeSince: ended.addingTimeInterval(-60)),
                    "Plus was offered in the opening that ended the first run (on return from placing)")
        try require(!due(cleared: false), "Plus came the same day before the window was ever cleared")
        try require(due(activeSince: nextDay, now: nextDay, cleared: false), "Plus did not come from the next day")
        try require(!due(shown: true), "the first Plus offer came twice")
        try require(!due(dueSince: nil), "Plus was offered before the first run ended")
        try require(!due(placed: false), "Plus was offered while no Widget is placed")
        try require(!due(offered: false), "Plus was offered to a member or an unconfigured build")
        try require(!due(prompted: true), "Plus shared a launch with the review prompt")
        try require(!due(presented: true), "Plus stacked over another screen")
        try require(FirstPlusOfferPolicy.dueSinceKey == "plusOffer.first.dueSince.v1"
                    && FirstPlusOfferPolicy.shownKey == "plusOffer.first.shown.v1", "first Plus offer keys changed")

        let suite = "first-plus-offer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        FirstPlusOfferPolicy.noteFirstRunEnded(now: ended, defaults: defaults)
        FirstPlusOfferPolicy.noteFirstRunEnded(now: nextDay, defaults: defaults)
        try require(FirstPlusOfferPolicy.dueSince(defaults: defaults) == ended, "ending twice moved the offer later")
        FirstPlusOfferPolicy.noteShown(defaults: defaults)
        try require(defaults.bool(forKey: FirstPlusOfferPolicy.shownKey), "the shown offer was not remembered")
        let resumedSuite = "first-plus-offer-resumed-\(UUID().uuidString)"
        let resumed = UserDefaults(suiteName: resumedSuite)!
        defer { resumed.removePersistentDomain(forName: resumedSuite) }
        FirstPlusOfferPolicy.noteShown(defaults: resumed)
        FirstPlusOfferPolicy.noteFirstRunEnded(now: ended, defaults: resumed)
        try require(FirstPlusOfferPolicy.dueSince(defaults: resumed) == nil,
                    "a person who saw the first run's Plus page was offered it again")
    }

    /// 11/12: the first Plus offer does not depend on how the first run
    /// ended. The Widget guide, 「あとで」 on the scan page (a found photo no
    /// longer ends it), skipping Photos access, and joining from a link all
    /// end it the same way; a Settings replay never does.
    private static func verifiesEveryWayOutOfTheFirstRunCountsForTheFirstOffer() throws {
        func ends(_ state: OnboardingPresentationState) -> Bool {
            OnboardingPresentationPersistence.endsFirstRun(from: 0, to: state.completedVersion)
        }
        var guide = OnboardingPresentationState(persistedResumePageIndex: 3)
        guide.advance()
        var guideLater = OnboardingPresentationState(persistedResumePageIndex: 3)
        guideLater.skipWidgetGuide()
        var scanLater = OnboardingPresentationState(persistedResumePageIndex: 2)
        scanLater.completeWithoutWidgetPhoto()
        var noAccess = OnboardingPresentationState(persistedResumePageIndex: 1)
        noAccess.skipPhotoPermission()
        var invited = OnboardingPresentationState(persistedResumePageIndex: 0)
        invited.finishForInvitation()
        for (name, state) in [("the Widget guide", guide), ("the guide's later", guideLater),
                              ("the scan page's later", scanLater), ("no Photos access", noAccess),
                              ("an invitation", invited)] {
            try require(ends(state), "ending through \(name) did not count for the first Plus offer")
        }
        var scanning = OnboardingPresentationState(persistedResumePageIndex: 2)
        try require(!ends(scanning), "the scan page counted as the end before anything was chosen")
        scanning.advance()
        try require(!ends(scanning), "opening the Widget guide counted as the end of the first run")
        var replay = OnboardingPresentationState.widgetGuideReplay(
            persistedResumePageIndex: 3, persistedCompletedVersion: 1)
        replay.advance()
        try require(!OnboardingPresentationPersistence.endsFirstRun(from: 1, to: replay.completedVersion),
                    "a Settings replay ended the first run again")
    }

    /// 11/12: the second opening starts in the 写真 tab, not アルバム. The key
    /// is the one MainTabView reads (MainTabStartupPolicy maps "photos").
    private static func verifiesFirstRunRemembersThePhotosTab() throws {
        try require(FirstRunTabMemory.lastTabKey == "navigation.lastTab.v1"
                    && FirstRunTabMemory.photosTab == "photos", "the remembered tab no longer matches MainTabView")
        let suite = "first-run-tab-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("memories", forKey: FirstRunTabMemory.lastTabKey)
        FirstRunTabMemory.rememberPhotosTab(defaults: defaults)
        try require(defaults.string(forKey: FirstRunTabMemory.lastTabKey) == "photos",
                    "ending the first run did not remember the 写真 tab")
    }

    private static func verifiesPagesInTheApprovedOrder() throws {
        try require(
            OnboardingPresentationPage.allCases == [
                .purpose,
                .photoPermission,
                .scanResult,
                .widgetGuide,
                .plusOffer
            ],
            "onboarding stopped being the approved flow (four pages and the optional Plus page)"
        )
        try require(OnboardingPresentationPage.widgetGuide.rawValue == 3,
                    "persisted Widget-guide progress changed meaning")
    }

    /// 11/10: the first run never moves to the Plus page. Placing the Widget
    /// (and coming back) or 「あとで」 ends the first run; Plus comes later,
    /// once (FirstPlusOfferPolicy). A first run saved on the Plus page before
    /// 11/10 still resumes it, and one tap on 「あとで」 enters the app.
    private static func verifiesPlusOfferIsTheLastSkippablePage() throws {
        var state = OnboardingPresentationState(offersPlus: true)
        state.advance()
        state.advance()
        state.advance()
        try require(state.currentPage == .widgetGuide, "Plus moved ahead of the Widget guide")
        state.advance()
        try require(!state.isPresented && state.isFirstRunComplete,
                    "returning from the Widget placement still led to the Plus page")
        try require(state.resumePageIndex == OnboardingPresentationPage.widgetGuide.rawValue,
                    "the first run recorded the Plus page as seen")

        var resumed = OnboardingPresentationState(persistedResumePageIndex: 4, offersPlus: true)
        try require(resumed.currentPage == .plusOffer, "a first run saved on the Plus page lost it")
        resumed.skipPlusOffer()
        try require(!resumed.isPresented && resumed.isFirstRunComplete, "one tap on later did not enter the app")

        var afterPurchase = OnboardingPresentationState(persistedResumePageIndex: 4, offersPlus: true)
        try require(afterPurchase.currentPage == .plusOffer, "Plus page progress was discarded")
        afterPurchase.advance()
        try require(!afterPurchase.isPresented && afterPurchase.isFirstRunComplete,
                    "finishing the Plus page did not enter the app")

        var widgetLater = OnboardingPresentationState(persistedResumePageIndex: 3, offersPlus: true)
        widgetLater.skipWidgetGuide()
        try require(!widgetLater.isPresented && widgetLater.isFirstRunComplete,
                    "Widget later led to the Plus page instead of the app")

        var permissionSkip = OnboardingPresentationState(persistedResumePageIndex: 1, offersPlus: true)
        permissionSkip.skipPhotoPermission()
        try require(!permissionSkip.isPresented && permissionSkip.isFirstRunComplete,
                    "skipping Photos access was followed by a Plus page")

        var noPhoto = OnboardingPresentationState(persistedResumePageIndex: 2, offersPlus: true)
        noPhoto.completeWithoutWidgetPhoto()
        try require(!noPhoto.isPresented && noPhoto.isFirstRunComplete,
                    "a scan without photos was followed by a Plus page")

        let unconfigured = OnboardingPresentationState(persistedResumePageIndex: 4)
        try require(unconfigured.currentPage == .widgetGuide && unconfigured.resumePageIndex == 3,
                    "an unconfigured build resumed on the Plus page")

        var plusSkipElsewhere = OnboardingPresentationState(persistedResumePageIndex: 3, offersPlus: true)
        plusSkipElsewhere.skipPlusOffer()
        try require(plusSkipElsewhere.currentPage == .widgetGuide && !plusSkipElsewhere.isFirstRunComplete,
                    "the Plus skip acted outside its own page")

        var replay = OnboardingPresentationState.widgetGuideReplay(
            persistedResumePageIndex: 4, persistedCompletedVersion: 1)
        replay.skipWidgetGuide()
        try require(!replay.isPresented && replay.resumePageIndex == 4 && replay.completedVersion == 1,
                    "a Settings replay showed the Plus page or changed progress")
    }

    private static func verifiesApprovedJapaneseCopy() throws {
        try require(
            OnboardingPresentationCopy.purposeTitle == "iPhoneの中の猫の写真を、ぜんぶ見つけます。"
                && OnboardingPresentationCopy.purposeBody == "写真はiPhoneの中だけで探します。外には送りません。",
            "page-one promise changed"
        )
        try require(
            OnboardingPresentationCopy.purposeAction == "猫を探す",
            "page-one action changed"
        )
        try require(
            OnboardingPresentationCopy.purposeFootnote.isEmpty,
            "page-one grew a footnote again"
        )
        // 11/10: page two has no title of its own; it repeated page one.
        // The privacy promise is said once (page one, purposeBody); page two
        // no longer repeats it as bullets or a limited-access note (11/8).
        try require(
            !OnboardingPresentationCopy.purposeBody.isEmpty
                && OnboardingPresentationCopy.purposeBody.contains("iPhoneの中だけ"),
            "the one Photos privacy promise disappeared"
        )
        try require(
            OnboardingPresentationCopy.permissionAction == "写真へのアクセスを許可",
            "Photos permission action changed"
        )
        try require(
            OnboardingPresentationCopy.permissionSkipAction == "あとで",
            "Photos permission stopped offering the approved skip action"
        )
        try require(
            OnboardingPresentationCopy.scanTitle == "猫を探しています"
                && OnboardingPresentationCopy.scanFoundTitle == "猫の写真が見つかりました"
                && OnboardingPresentationCopy.scanStillSearching == "まだ探しています",
            "scan title changed"
        )
        // 11/12: no cat is said plainly, with one next step; never 「アクセスを確かめて」.
        try require(
            OnboardingPresentationCopy.scanZeroTitle == "猫の写真は見つかりませんでした"
                && OnboardingPresentationCopy.scanZeroBody == "猫の写真を撮ると、ここに出ます。"
                && OnboardingPresentationCopy.scanZeroLimitedBody == "猫の写真を追加で選ぶと、ここに出ます。"
                && OnboardingPresentationCopy.scanZeroLimitedAction == "写真を追加で選ぶ"
                && OnboardingPresentationCopy.scanZeroStartAction == "はじめる"
                && OnboardingPresentationCopy.scanZeroNowaAction == "のわのまどを見る",
            "the no-cat result changed"
        )
        try require(
            !(OnboardingPresentationCopy.scanZeroBody + OnboardingPresentationCopy.scanZeroLimitedBody)
                .contains("アクセス"),
            "the no-cat result blamed Photos access again"
        )
        try require(
            OnboardingPresentationCopy.scanWidgetAction == "ウィジェットを置く",
            "scan page stopped offering Widget placement"
        )
        try require(
            OnboardingPresentationCopy.scanBodyLines == [
                "アプリを開いている間、新しい写真から順に探します。"
            ],
            "scan manuscript copy changed"
        )
        try require(
            OnboardingPresentationCopy.scanContinueAction == "あとで",
            "scan page stopped offering a non-blocking continuation"
        )
        try require(
            OnboardingPresentationCopy.widgetTitleLines == [
                "ホーム画面に、",
                "猫写真をひとつ。"
            ],
            "Widget guide promise changed"
        )
        try require(
            OnboardingPresentationCopy.widgetBody
                == "見つけた猫写真を、ホーム画面でも楽しめます。\n置き方は下のとおりです。",
            "Widget guide stopped explaining the Home Screen handoff"
        )
        try require(
            OnboardingPresentationCopy.widgetModernPlacementSteps == [
                "ホーム画面の何もないところを長押し",
                "左上の「編集」→「ウィジェットを追加」",
                "「ねこのまど」を探し、好きな大きさで追加"
            ],
            "modern Widget installation steps changed"
        )
        try require(
            OnboardingPresentationCopy.widgetLegacyPlacementSteps == [
                "ホーム画面の何もないところを長押し",
                "左上の「＋」をタップ",
                "「ねこのまど」を探し、好きな大きさで追加"
            ],
            "legacy Widget installation steps changed"
        )
        try require(
            OnboardingPresentationCopy.widgetChangeSourceStep
                == "出す写真を変えるには、ウィジェットを長押しして「ウィジェットを編集」→「表示する写真」。まども選べます。",
            "Widget guide stopped saying how to change what the Widget shows"
        )
        try require(
            OnboardingPresentationCopy.widgetReturnHint
                == "追加してアプリへ戻ると、自動で確認します。",
            "Widget guide stopped explaining automatic confirmation"
        )
        try require(
            OnboardingPresentationCopy.widgetAction == "ホーム画面で置いてきます",
            "Widget guide primary action changed (it checks nothing, so it must not say 「置きました」)"
        )
        // 11/12: the Widget's tag reads 「タップで きょうの 1 枚」; the app uses
        // those words, never 「札」.
        try require(
            OnboardingPresentationCopy.widgetCloudyStep
                == "置いたら、そのままくもりのまどです。「タップで きょうの 1 枚」を押すと、きょうの写真が出ます。",
            "the guide's last step changed"
        )
        try require(
            !(OnboardingPresentationCopy.widgetCloudyStep + OnboardingPresentationCopy.widgetPlacedBody).contains("札"),
            "the app said 「札」, a word the Widget never shows"
        )
        try require(
            OnboardingPresentationCopy.widgetPlacedTitle == "置けました"
                && OnboardingPresentationCopy.widgetPlacedBody
                    == "ホーム画面の「タップで きょうの 1 枚」を押すと、きょうの写真が出ます。"
                && OnboardingPresentationCopy.widgetPlacedAction == "写真を見る",
            "the one 「置けました」 screen changed"
        )
        try require(
            OnboardingPresentationCopy.loadFailedTitle == "読み込めませんでした"
                && OnboardingPresentationCopy.loadFailedAction == "もう一度",
            "a failed start stopped offering one retry"
        )
        try require(
            OnboardingPresentationCopy.widgetLaterAction
                == "あとで",
            "Widget guide later action changed"
        )
    }

    private static func verifiesOrdinaryFirstRunTransitions() throws {
        var state = OnboardingPresentationState()
        try require(state.currentPage == .purpose, "first run did not begin at page one")

        state.advance()
        try require(state.currentPage == .photoPermission, "page one did not lead to permission")
        state.advance()
        try require(state.currentPage == .scanResult, "permission did not lead to scan/result")
        state.advance()
        try require(state.currentPage == .widgetGuide, "scan/result did not lead to Widget guide")
        state.advance()
        try require(!state.isPresented, "Widget guide action did not dismiss onboarding")
        try require(state.isFirstRunComplete, "Widget guide action did not complete onboarding")
    }

    private static func verifiesPermissionSkipEntersTheApp() throws {
        var state = OnboardingPresentationState(persistedResumePageIndex: 1)
        try require(state.currentPage == .photoPermission, "permission resume setup failed")
        state.skipPhotoPermission()
        try require(
            !state.isPresented,
            "permission skip kept presenting instructions that require Photos access"
        )
        try require(
            state.isFirstRunComplete,
            "permission skip did not enter the app"
        )
        try require(
            state.resumePageIndex == OnboardingPresentationPage.photoPermission.rawValue,
            "permission skip rewrote the last page the user actually saw"
        )
    }

    private static func verifiesScanWithoutPhotoEntersTheApp() throws {
        var state = OnboardingPresentationState(persistedResumePageIndex: 2)
        try require(state.currentPage == .scanResult, "scan resume setup failed")
        state.completeWithoutWidgetPhoto()
        try require(
            !state.isPresented,
            "scan without a usable photo kept teaching Widget placement"
        )
        try require(
            state.isFirstRunComplete,
            "scan without a usable photo did not enter the app"
        )
        try require(
            state.resumePageIndex == OnboardingPresentationPage.scanResult.rawValue,
            "photo-less scan completion rewrote the last page the user saw"
        )
    }

    private static func verifiesWidgetGuideSkipCompletesFirstRun() throws {
        var state = OnboardingPresentationState(persistedResumePageIndex: 3)
        state.skipWidgetGuide()
        try require(
            !state.isPresented,
            "first-run Widget skip did not enter the app"
        )
        try require(
            state.isFirstRunComplete,
            "first-run Widget skip did not complete onboarding"
        )
    }

    private static func verifiesRevokedPhotoAccessReturnsToPermission() throws {
        var state = OnboardingPresentationState(persistedResumePageIndex: 2)
        state.reconcilePhotoAuthorization(isReadable: false)
        try require(
            state.currentPage == .photoPermission,
            "a resumed scan stayed active without readable Photos access"
        )
        try require(state.resumePageIndex == 1, "authorization recovery was not resumable")

        state.advance()
        state.reconcilePhotoAuthorization(isReadable: true)
        try require(
            state.currentPage == .scanResult,
            "readable Photos access incorrectly rewound the scan page"
        )
    }

    private static func verifiesResumeProgressIsClamped() throws {
        let belowRange = OnboardingPresentationState(persistedResumePageIndex: -20)
        try require(belowRange.currentPage == .purpose, "negative progress was not clamped")
        try require(belowRange.resumePageIndex == 0, "negative persisted index survived")

        let aboveRange = OnboardingPresentationState(persistedResumePageIndex: 200)
        try require(aboveRange.currentPage == .widgetGuide, "oversized progress was not clamped")
        try require(aboveRange.resumePageIndex == 3, "oversized persisted index survived")

        let middle = OnboardingPresentationState(persistedResumePageIndex: 3)
        try require(middle.currentPage == .widgetGuide, "valid resume progress was discarded")
    }

    private static func verifiesCompletionVersionOne() throws {
        try require(
            OnboardingPresentationPersistence.currentCompletedVersion == 1,
            "first onboarding release is not completion version one"
        )
        try require(
            OnboardingPresentationPersistence.requiresPresentation(completedVersion: 0),
            "an incomplete first run stopped presenting onboarding"
        )
        try require(
            !OnboardingPresentationPersistence.requiresPresentation(completedVersion: 1),
            "completed version one relaunched onboarding"
        )
        try require(
            OnboardingPresentationPersistence.completedVersionKey
                == "onboarding.completedVersion",
            "completion persistence key changed"
        )
        try require(
            OnboardingPresentationPersistence.resumePageIndexKey
                == "onboarding.resumePageIndex.v1",
            "resume persistence key changed"
        )

        let completed = OnboardingPresentationState(
            persistedResumePageIndex: 0,
            persistedCompletedVersion: 1
        )
        try require(!completed.isPresented, "completed version one relaunched onboarding")
        try require(completed.isFirstRunComplete, "version one was not recognized as complete")
    }

    private static func verifiesWidgetGuideReplayIsNonDestructive() throws {
        var completedReplay = OnboardingPresentationState.widgetGuideReplay(
            persistedResumePageIndex: 3,
            persistedCompletedVersion: 1
        )
        try require(completedReplay.mode == .widgetGuideReplay, "replay mode was lost")
        try require(completedReplay.currentPage == .widgetGuide, "replay did not open page four")
        completedReplay.advance()
        try require(!completedReplay.isPresented, "replay action did not dismiss the guide")
        try require(completedReplay.completedVersion == 1, "replay cleared completion")
        try require(completedReplay.resumePageIndex == 3, "replay rewound progress")

        var interruptedReplay = OnboardingPresentationState.widgetGuideReplay(
            persistedResumePageIndex: 1,
            persistedCompletedVersion: 0
        )
        interruptedReplay.skipWidgetGuide()
        try require(!interruptedReplay.isPresented, "replay later-action did not dismiss")
        try require(interruptedReplay.completedVersion == 0, "replay falsely completed first run")
        try require(interruptedReplay.resumePageIndex == 1, "replay changed interrupted progress")
    }

    private static func verifiesWidgetPlacementRecoveryPolicy() throws {
        try require(
            !WidgetInstallationState.installed.shouldOfferPlacementGuide,
            "Home reminder remained visible for a confirmed Widget installation"
        )
        try require(
            WidgetInstallationState.notInstalled.shouldOfferPlacementGuide,
            "Home reminder disappeared after WidgetKit confirmed absence"
        )
        for state in [
            WidgetInstallationState.unknown,
            .checking,
            .unavailable,
        ] {
            try require(
                !state.shouldOfferPlacementGuide,
                "Home reminder appeared before Widget absence was confirmed"
            )
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}
