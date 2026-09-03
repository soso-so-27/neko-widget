import Foundation

/// The onboarding is deliberately limited to these four moments. Adding a
/// case changes the product flow, so the standalone verifier locks the count
/// and order.
enum OnboardingPresentationPage: Int, CaseIterable, Identifiable, Sendable {
    case purpose
    case photoPermission
    case scanResult
    case widgetGuide

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
    static let purposeBodyLines = [
        "撮りためた猫写真が、",
        "毎日会える思い出に。",
        "猫だけを端末内で見つけて、",
        "自動アルバムとホーム画面へ。"
    ]
    static let purposeAction = "はじめる"

    static let permissionTitleLines = [
        "このiPhoneの猫の写真や動画を",
        "端末内で見つけます。"
    ]
    static func permissionPrivacyLines(isMediaAvailable: Bool) -> [String] {
        if isMediaAvailable {
            return [
                "・解析はすべてこの端末の中で行います",
                "・共有は別に同意した後、選んだ縮小写真1枚だけを送ります",
                "・写真や動画の自動送信・削除・変更はしません"
            ]
        }
        return [
            "・解析はすべてこの端末の中で行います",
            "・写真や動画を開発者のサーバーへ自動送信しません",
            "・写真や動画を消したり変更したりしません"
        ]
    }

    static func homePermissionBody(isMediaAvailable: Bool) -> String {
        if isMediaAvailable {
            return "解析はこの端末内で行います。共有は別に同意した後、選んだ縮小写真1枚だけを送ります。写真や動画の自動送信・削除・変更はしません。あとから許可できます。"
        }
        return "解析はこの端末内で行い、写真や動画を開発者のサーバーへ自動送信しません。変更や削除もしません。あとから許可できます。"
    }
    static let permissionLimitedAccessNote = "「すべての写真」がおすすめです。「選択した写真のみ」でも動きます。"
    static let permissionAction = "写真へのアクセスを許可"
    static let permissionSkipAction = "あとで（スキップ）"

    static let scanTitle = "このiPhoneの猫写真を探しています"
    static let scanBodyLines = [
        "新しい写真から先に見ています。",
        "全部の集計は、",
        "次にひらいたときに続きます。"
    ]
    static let scanContinueAction = "先に進む（スキャンは続きます）"
    static let resultLeadLines = [
        "このiPhoneで見つけた",
        "猫写真は"
    ]
    static let resultCountSuffix = "枚"
    static let resultClosing = "ありました"
    static let resultOldestLead = "一番古い1枚は"

    static let widgetTitleLines = [
        "ホーム画面に、",
        "猫写真のウィジェットをひとつ。"
    ]
    static let widgetBody = "追加はホーム画面で行います。"
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
    static let widgetReturnHint = "追加してアプリへ戻ると、自動で確認します。"
    static let widgetAction = "手順を確認した"
    static let widgetLaterAction = "あとで"

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
    private(set) var currentPage: OnboardingPresentationPage?
    private(set) var resumePageIndex: Int
    private(set) var completedVersion: Int

    init(
        persistedResumePageIndex: Int = 0,
        persistedCompletedVersion: Int = 0
    ) {
        mode = .firstRun
        completedVersion = max(0, persistedCompletedVersion)
        resumePageIndex = Self.clampedPageIndex(persistedResumePageIndex)
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
        currentPage = .widgetGuide
        self.resumePageIndex = Self.clampedPageIndex(resumePageIndex)
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
        case .widgetGuide:
            completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
            self.currentPage = nil
        }
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

    /// "あとで" completes the first-run handoff. In a Settings replay it
    /// simply dismisses the guide without touching saved first-run progress.
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

    private static func clampedPageIndex(_ value: Int) -> Int {
        let lastPageIndex = max(0, OnboardingPresentationPage.allCases.count - 1)
        return min(max(0, value), lastPageIndex)
    }
}
