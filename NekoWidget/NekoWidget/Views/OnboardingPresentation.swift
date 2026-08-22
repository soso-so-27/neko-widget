import Foundation

/// The onboarding is deliberately limited to these five moments. Adding a
/// case changes the product flow, so the standalone verifier locks the count
/// and order.
enum OnboardingPresentationPage: Int, CaseIterable, Identifiable, Sendable {
    case purpose
    case photoPermission
    case scanResult
    case widgetGuide
    case pawLike

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
        "うちの子の写真は、",
        "撮るだけ撮って",
        "見ていないことが多い。",
        "このアプリは、その中から",
        "猫だけを自動で選んで、",
        "毎日ちがう1枚を",
        "ホーム画面に出します。"
    ]
    static let purposeAction = "はじめる"

    static let permissionTitleLines = [
        "うちの子を探すために、",
        "写真を読ませてください。"
    ]
    static func permissionPrivacyLines(isMediaAvailable: Bool) -> [String] {
        if isMediaAvailable {
            return [
                "・解析はすべてこの端末の中で行います",
                "・写真共有は別に同意した後、選んだ縮小1枚だけを暗号化して送ります",
                "・原本の自動送信・削除・変更はしません"
            ]
        }
        return [
            "・写真は端末の外に出ません",
            "・解析はすべてこの端末の中で行います",
            "・写真を消したり変更したりしません"
        ]
    }

    static func homePermissionBody(isMediaAvailable: Bool) -> String {
        if isMediaAvailable {
            return "解析はこの端末内で行います。写真共有は別に同意した後、選んだ縮小1枚だけを暗号化して送ります。原本の自動送信・削除・変更はしません。あとからここで許可できます。"
        }
        return "写真は端末の外に出さず、変更や削除もしません。あとからここで許可できます。"
    }
    static let permissionLimitedAccessNote = "「すべての写真」がおすすめです。「選択した写真のみ」でも動きます。"
    static let permissionAction = "写真へのアクセスを許可"
    static let permissionSkipAction = "あとで（スキップ）"

    static let scanTitle = "うちの子を探しています"
    static let scanBodyLines = [
        "新しい写真から先に見ています。",
        "全部の集計は、",
        "次にひらいたときに続きます。"
    ]
    static let resultLeadLines = [
        "あなたのカメラロールに",
        "うちの子の写真は"
    ]
    static let resultCountSuffix = "枚"
    static let resultClosing = "ありました"
    static let resultOldestLead = "一番古い1枚は"

    static let widgetTitleLines = [
        "ホーム画面に、",
        "うちの子の窓をひとつ。"
    ]
    static let widgetAction = "わかった"
    static let widgetLaterAction = "あとで見る（設定からいつでも開けます）"

    static let pawTitleLines = [
        "気に入った1枚は、",
        "肉球を押しておいてください。"
    ]
    static let pawBody = "押した写真は「これ好き」に溜まります。"
    static let pawAction = "はじめる"
}

struct OnboardingWidgetGuideStepPresentation: Equatable, Identifiable, Sendable {
    let id: Int
    let imageAssetName: String
    let caption: String
}

extension OnboardingWidgetGuideStepPresentation {
    /// Four static screenshots with overlaid arrows. The asset names are the
    /// stable contract used by the SwiftUI page and the asset catalogue.
    static let all: [Self] = [
        Self(
            id: 1,
            imageAssetName: "onboarding-widget-step-1",
            caption: "ホーム画面の何もないところを長押し"
        ),
        Self(
            id: 2,
            imageAssetName: "onboarding-widget-step-2",
            caption: "左上の「＋」をタップ"
        ),
        Self(
            id: 3,
            imageAssetName: "onboarding-widget-step-3",
            caption: "「ねこのまど」を探す"
        ),
        Self(
            id: 4,
            imageAssetName: "onboarding-widget-step-4",
            caption: "好きな大きさを選んで追加"
        )
    ]
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

    /// Continues in the fixed five-page order. Permission and scan work is
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
            routeFirstRun(to: .pawLike)
        case .pawLike:
            completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
            self.currentPage = nil
        }
    }

    /// Skipping Photos permission must not end onboarding. It jumps directly
    /// to the product-critical Widget instructions.
    mutating func skipPhotoPermission() {
        guard mode == .firstRun, currentPage == .photoPermission else { return }
        routeFirstRun(to: .widgetGuide)
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

    /// "あとで見る" still lets a first-time user see the final paw page. In a
    /// Settings replay it simply dismisses the guide without touching saved
    /// first-run progress.
    mutating func skipWidgetGuide() {
        guard currentPage == .widgetGuide else { return }
        if mode == .widgetGuideReplay {
            currentPage = nil
        } else {
            routeFirstRun(to: .pawLike)
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
