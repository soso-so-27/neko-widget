import Foundation

enum OnboardingPartialScanRecovery {
    static func message(hasPreliminaryResult: Bool, error: String?) -> String? {
        guard hasPreliminaryResult, let error,
              !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return error
    }

    static func showsProgress(hasFinalResult: Bool, hasPreliminaryResult: Bool, error: String?) -> Bool {
        !hasFinalResult && message(hasPreliminaryResult: hasPreliminaryResult, error: error) == nil
    }

    /// The count appears with the first cat. 「いま 0枚」 over an empty grid
    /// read as "nothing found" while the newest photos had no cat (11/10).
    static func showsCount(hasPreliminaryResult: Bool, displayedCount: Int) -> Bool {
        hasPreliminaryResult && displayedCount > 0
    }
}

/// The onboarding is deliberately limited to these moments. Adding a case
/// changes the product flow, so the standalone verifier locks the count and
/// order. `plusOffer` (ADR-027) is appended so persisted indices keep their
/// meaning. Since 11/10 the first run no longer moves to it: the Widget guide
/// ends the first run, and the first Plus offer comes later
/// (`FirstPlusOfferPolicy`). A first run saved on that page still resumes it.
enum OnboardingPresentationPage: Int, CaseIterable, Identifiable, Sendable {
    case purpose
    case photoPermission
    case scanResult
    case widgetGuide
    /// The skippable Plus page. Reached only by resuming a first run saved
    /// on it before 11/10; nothing routes to it any more.
    case plusOffer

    var id: Int { rawValue }
}

/// UserDefaults keys and the migration version for the first-run flow.
///
/// The resume index is separate from completion so an interrupted first run
/// can continue without marking any later page as seen. Replaying the Widget
/// guide never writes either value.
enum OnboardingPresentationPersistence {
    static let currentCompletedVersion = 1
    static let completedVersionKey = "onboarding.completedVersion"
    static let resumePageIndexKey = "onboarding.resumePageIndex.v1"

    static func requiresPresentation(completedVersion: Int) -> Bool {
        completedVersion < currentCompletedVersion
    }

    /// The step that ends the first run, whichever way it ends: the Widget
    /// guide, a found photo's 「あとで」, no Photos access, or a link (11/12:
    /// only the Widget guide counted, so most people never got the first
    /// Plus offer).
    static func endsFirstRun(from previousCompletedVersion: Int, to completedVersion: Int) -> Bool {
        requiresPresentation(completedVersion: previousCompletedVersion)
            && !requiresPresentation(completedVersion: completedVersion)
    }
}

/// The 写真 tab is remembered as the last tab when the first run ends, so the
/// second opening returns to the photos the person just met instead of the
/// アルバム tab (11/12). `MainTabView` reads the same key with @AppStorage.
enum FirstRunTabMemory {
    static let lastTabKey = "navigation.lastTab.v1"
    static let photosTab = "photos"

    static func rememberPhotosTab(defaults: UserDefaults = .standard) {
        defaults.set(photosTab, forKey: lastTabKey)
    }
}

/// WidgetKit lookup results are intentionally modeled separately from the
/// first-run flow. The Home reminder is shown only when WidgetKit has
/// positively confirmed that the Widget is absent. Settings remains the
/// always-available recovery path when lookup is pending or unavailable.
enum WidgetInstallationState: Equatable, Sendable {
    case unknown
    case checking
    case installed
    case notInstalled
    case unavailable

    var shouldOfferPlacementGuide: Bool {
        self == .notInstalled
    }
}

/// Base copy from `docs/オンボーディング原稿.md`, plus the release-mode
/// privacy variant. Keeping it outside the SwiftUI view makes both modes
/// independently verifiable.
enum OnboardingPresentationCopy {
    /// Page one has one job: the Photos permission. People come from the
    /// site knowing what the app is, so it says what happens next, answers
    /// the one worry (the photos stay on the iPhone), and asks. No feature list.
    static let purposeTitle = "iPhoneの中の猫の写真を、ぜんぶ見つけます。"
    static let purposeBody = "写真はiPhoneの中だけで探します。外には送りません。"
    static let purposeAction = "猫を探す"
    static let purposeFootnote = ""

    // The promise is said once, on page one (and on Home's card for anyone
    // who skipped). Page two is the windows and the Photos dialog only: its
    // own title repeated page one (11/10).
    static let permissionAction = "写真へのアクセスを許可"
    static let permissionSkipAction = "あとで"

    /// Page three shows the cats as they are found: a grid that fills, a count,
    /// and the one next step (place the Widget). From the first cat the title
    /// says 「見つかりました」 and the count reads 「32枚」 with 「まだ探しています」
    /// under it until the scan is final (11/12: most people left before the
    /// title ever changed). Before the first cat it shows no count: 「いま 0枚」
    /// read as a failure (11/10).
    static let scanTitle = "猫を探しています"
    static let scanFoundTitle = "猫の写真が見つかりました"
    static let scanBodyLines = [
        "アプリを開いている間、新しい写真から順に探します。"
    ]
    /// Said under the count until the scan is final, once a cat was found
    /// and the title already says so (11/12).
    static let scanStillSearching = "まだ探しています"
    static let scanWidgetAction = "ウィジェットを置く"
    /// The quiet way past the Widget: straight into the 写真 tab.
    static let scanContinueAction = "あとで"

    /// No cat in the photos (11/12): said plainly, with the one next step
    /// that fits. It never blames access the person already gave.
    static let scanZeroTitle = "猫の写真は見つかりませんでした"
    static let scanZeroBody = "猫の写真を撮ると、ここに出ます。"
    static let scanZeroLimitedBody = "猫の写真を追加で選ぶと、ここに出ます。"
    static let scanZeroLimitedAction = "写真を追加で選ぶ"
    static let scanZeroStartAction = "はじめる"
    /// The official window, so the Widget has a cat to show meanwhile.
    static let scanZeroNowaAction = "のわのまどを見る"

    static let widgetTitleLines = [
        "ホーム画面に、",
        "猫写真をひとつ。"
    ]
    static let widgetBody = "見つけた猫写真を、ホーム画面でも楽しめます。\n置き方は下のとおりです。"
    static let widgetModernPlacementSteps = [
        "ホーム画面の何もないところを長押し",
        "左上の「編集」→「ウィジェットを追加」",
        "「ねこのまど」を探し、好きな大きさで追加"
    ]
    static let widgetLegacyPlacementSteps = [
        "ホーム画面の何もないところを長押し",
        "左上の「＋」をタップ",
        "「ねこのまど」を探し、好きな大きさで追加"
    ]
    /// The last step when the guide is opened from 設定 (11/12): how to change
    /// what the placed Widget shows.
    static let widgetChangeSourceStep = "出す写真を変えるには、ウィジェットを長押しして「ウィジェットを編集」→「表示する写真」。まども選べます。"
    /// Said under the steps (11/10): place first, then come back.
    static let widgetReturnHint = "追加してアプリへ戻ると、自動で確認します。"
    /// 11/12: the button checks nothing, so it says the person goes out to
    /// the Home Screen, not that the Widget is placed.
    static let widgetAction = "ホーム画面で置いてきます"
    /// The last step of the guide, in the Widget's own words: its tag reads
    /// 「タップで、きょうの1枚」 (NekoWidgetView), never 「札」.
    static let widgetCloudyStep = "置いたら、そのままくもりのまどです。「タップで、きょうの1枚」を押すと、きょうの写真が出ます。"
    static let widgetLaterAction = "あとで"

    /// The first run's last screen once WidgetKit sees the Widget (11/10):
    /// one state, one sentence, one button. Plus is not offered here.
    static let widgetPlacedTitle = "置けました"
    static let widgetPlacedBody = "ホーム画面の「タップで、きょうの1枚」を押すと、きょうの写真が出ます。"
    static let widgetPlacedAction = "写真を見る"

    /// Page two, when the app's own records could not be read: the Photos
    /// request cannot start, so the button tries the loading again (11/10).
    static let loadFailedTitle = "読み込めませんでした"
    static let loadFailedAction = "もう一度"

}

/// Pure reducer for first-run navigation and Settings replay.
///
/// The caller persists `resumePageIndex` and `completedVersion` only while
/// `mode == .firstRun`. A Widget-guide replay is intentionally isolated: it
/// opens page four and dismisses without changing first-run progress.
struct OnboardingPresentationState: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case firstRun
        case widgetGuideReplay
    }

    let mode: Mode
    /// Whether a first run saved on the Plus page may resume there. The
    /// caller passes the product configuration. No transition leads to the
    /// Plus page any more (11/10: it showed before the cat on the Home Screen).
    let offersPlus: Bool
    private(set) var currentPage: OnboardingPresentationPage?
    private(set) var resumePageIndex: Int
    private(set) var completedVersion: Int

    init(
        persistedResumePageIndex: Int = 0,
        persistedCompletedVersion: Int = 0,
        offersPlus: Bool = false
    ) {
        mode = .firstRun
        self.offersPlus = offersPlus
        completedVersion = max(0, persistedCompletedVersion)
        resumePageIndex = Self.clampedPageIndex(persistedResumePageIndex,
            lastPage: offersPlus ? .plusOffer : .widgetGuide)
        if completedVersion >= OnboardingPresentationPersistence.currentCompletedVersion {
            currentPage = nil
        } else {
            currentPage = OnboardingPresentationPage(rawValue: resumePageIndex)
        }
    }

    private init(
        widgetGuideReplayWithPersistedResumePageIndex resumePageIndex: Int,
        persistedCompletedVersion completedVersion: Int
    ) {
        mode = .widgetGuideReplay
        offersPlus = false
        currentPage = .widgetGuide
        self.resumePageIndex = Self.clampedPageIndex(resumePageIndex, lastPage: .plusOffer)
        self.completedVersion = max(0, completedVersion)
    }

    static func widgetGuideReplay(
        persistedResumePageIndex: Int,
        persistedCompletedVersion: Int
    ) -> Self {
        Self(
            widgetGuideReplayWithPersistedResumePageIndex: persistedResumePageIndex,
            persistedCompletedVersion: persistedCompletedVersion
        )
    }

    var isPresented: Bool { currentPage != nil }

    var isFirstRunComplete: Bool {
        completedVersion >= OnboardingPresentationPersistence.currentCompletedVersion
    }

    /// Continues in the fixed four-page order. Permission and scan work is
    /// performed by the caller before it invokes this transition.
    mutating func advance() {
        guard let currentPage else { return }

        if mode == .widgetGuideReplay {
            self.currentPage = nil
            return
        }

        switch currentPage {
        case .purpose:
            routeFirstRun(to: .photoPermission)
        case .photoPermission:
            routeFirstRun(to: .scanResult)
        case .scanResult:
            routeFirstRun(to: .widgetGuide)
        case .widgetGuide, .plusOffer:
            // 11/10: the Widget guide (or its 「置けました」) ends the first
            // run. Plus is offered later, once, by FirstPlusOfferPolicy.
            completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
            self.currentPage = nil
        }
    }

    /// "あとで" on the Plus page: one tap enters the app. Nothing is bought,
    /// and nothing about Photos access or the scan depends on this choice.
    mutating func skipPlusOffer() {
        guard mode == .firstRun, currentPage == .plusOffer else { return }
        completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
        currentPage = nil
    }

    /// "あとで" enters the app without Photos access. Widget placement depends
    /// on an available photo, so presenting it after this choice would teach an
    /// action the user cannot verify. Home is the persistent recovery point for
    /// granting access later.
    mutating func skipPhotoPermission() {
        guard mode == .firstRun, currentPage == .photoPermission else { return }
        completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
        self.currentPage = nil
    }

    /// Joined from an invitation link while the first run was open, on any
    /// page: the guide ends and the まど tab opens the joined window. Photos
    /// and the widget stay reachable from their own places (11/6: after
    /// joining from the first page, the guide stayed).
    mutating func finishForInvitation() {
        guard mode == .firstRun, currentPage != nil else { return }
        completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
        currentPage = nil
    }

    /// A Widget cannot demonstrate its value until at least one cat photo is
    /// available. Finish the first run on the scan page and let Photos remain
    /// the recovery point instead of teaching an empty Widget setup.
    mutating func completeWithoutWidgetPhoto() {
        guard mode == .firstRun, currentPage == .scanResult else { return }
        completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
        self.currentPage = nil
    }

    /// An interrupted first run may resume on the scan page after Photos
    /// access has been revoked in Settings. Route back to the permission page
    /// instead of leaving the user on a scan that can never start.
    mutating func reconcilePhotoAuthorization(isReadable: Bool) {
        guard mode == .firstRun,
              currentPage == .scanResult,
              !isReadable else { return }
        routeFirstRun(to: .photoPermission)
    }

    /// "あとで" completes the Widget handoff: the first run ends (never on
    /// the Plus page, 11/10). In a Settings replay it simply dismisses the
    /// guide without touching saved first-run progress.
    mutating func skipWidgetGuide() {
        guard currentPage == .widgetGuide else { return }
        if mode == .widgetGuideReplay {
            currentPage = nil
        } else {
            completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
            currentPage = nil
        }
    }

    private mutating func routeFirstRun(to page: OnboardingPresentationPage) {
        currentPage = page
        resumePageIndex = page.rawValue
    }

    private static func clampedPageIndex(_ value: Int, lastPage: OnboardingPresentationPage) -> Int {
        min(max(0, value), lastPage.rawValue)
    }
}

/// The first Plus offer (11/10). The first run no longer ends on Plus: the
/// person first meets their cat on the Home Screen. The offer comes once, on a
/// later opening of the app, after a cloudy window was cleared at least once
/// or from the next day, with a Widget placed and over the person's own cat.
/// How the first run ended does not matter (11/12). It never shares a launch
/// with the review prompt or the notification request, and waits while any
/// other screen is presented.
enum FirstPlusOfferPolicy {
    /// When the first run ended, by any path (seconds since 1970). Written
    /// once, when the first run ends; never while scrolling.
    static let dueSinceKey = "plusOffer.first.dueSince.v1"
    /// Set once the offer was shown (or the first run's own Plus page was).
    static let shownKey = "plusOffer.first.shown.v1"

    /// When the app last became active, in memory only. The opening that
    /// ended the first run started before `dueSince`, so it never qualifies.
    @MainActor static var activeSince: Date?
    /// One prompt per launch: this offer, the review prompt, or the
    /// notification request for album works, never two of them (11/12).
    @MainActor static var promptedThisLaunch = false

    static func isDue(dueSince: Date?, shown: Bool, activeSince: Date?, now: Date,
                      hasClearedCloudyWindow: Bool, plusIsOffered: Bool, widgetPlaced: Bool,
                      promptedThisLaunch: Bool, otherScreenPresented: Bool,
                      calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let dueSince, !shown, plusIsOffered, widgetPlaced, !promptedThisLaunch,
              !otherScreenPresented, let activeSince, activeSince > dueSince, now >= activeSince
        else { return false }
        return hasClearedCloudyWindow || !calendar.isDate(now, inSameDayAs: dueSince)
    }

    /// The first run ended (any path, 11/12): the offer becomes due. An
    /// earlier value is kept, so ending twice never moves it later.
    static func noteFirstRunEnded(now: Date = Date(), defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: dueSinceKey) == nil, !defaults.bool(forKey: shownKey) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: dueSinceKey)
    }

    static func noteShown(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)
    }

    static func dueSince(defaults: UserDefaults = .standard) -> Date? {
        guard defaults.object(forKey: dueSinceKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: dueSinceKey))
    }
}

extension Notification.Name {
    /// The onboarding Plus sheet closed: an invitation held behind it is offered (11/7).
    static let onboardingPlusSheetClosed = Notification.Name("OnboardingPlusSheetClosed")
}
