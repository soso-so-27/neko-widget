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
}

/// The onboarding is deliberately limited to these moments. Adding a case
/// changes the product flow, so the standalone verifier locks the count and
/// order. `plusOffer` (ADR-027) is appended so persisted indices keep their
/// meaning, and it is reachable only when the caller says Plus is offered.
enum OnboardingPresentationPage: Int, CaseIterable, Identifiable, Sendable {
    case purpose
    case photoPermission
    case scanResult
    case widgetGuide
    /// The last, skippable page introducing Plus. It follows the Widget guide
    /// only; skipping Photos access or finishing without a photo never shows it.
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
    static let purposeTitle = "このiPhoneの中の猫を、全部見つけます。"
    static let purposeBody = "写真はiPhoneの中だけで探します。外には送りません。"
    static let purposeAction = "猫を探す"
    static let purposeFootnote = ""

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

    /// Page three shows the cats as they are found: a grid that fills, a count,
    /// and the one next step (place the Widget). The count reads 「いま 32枚」
    /// while the scan runs and 「128枚」 once it is final.
    static let scanTitle = "猫を探しています"
    static let scanFoundTitle = "猫の写真が見つかりました"
    static let scanBodyLines = [
        "アプリを開いている間、新しい写真から順に調べます。"
    ]
    static let scanCountLead = "いま"
    static let scanWidgetAction = "まどを置く"
    static let scanContinueAction = "写真を見る"

    static let widgetTitleLines = [
        "ホーム画面に、",
        "猫写真をひとつ。"
    ]
    static let widgetBody = "見つけた猫写真を、自分のホーム画面でも楽しめます。\n追加はホーム画面で行います。"
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
    /// Whether the skippable Plus page ends the first run. The caller passes
    /// the product configuration; while Plus is not offered the flow is the
    /// original four pages.
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
        case .widgetGuide:
            if offersPlus {
                routeFirstRun(to: .plusOffer)
            } else {
                completedVersion = OnboardingPresentationPersistence.currentCompletedVersion
                self.currentPage = nil
            }
        case .plusOffer:
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

    /// "あとで" completes the Widget handoff: the first run ends, or moves to
    /// the optional Plus page when it is offered. In a Settings replay it
    /// simply dismisses the guide without touching saved first-run progress.
    mutating func skipWidgetGuide() {
        guard currentPage == .widgetGuide else { return }
        if mode == .widgetGuideReplay {
            currentPage = nil
        } else if offersPlus {
            routeFirstRun(to: .plusOffer)
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

// Invitation receivers post this only after their own route validation and
// staging. No invitation token, URL, or participant identity is carried here.
extension Notification.Name {
    static let onboardingInvitationReceived = Notification.Name("OnboardingInvitationReceived")
}
