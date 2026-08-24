import Foundation

@main
enum OnboardingPresentationVerifier {
    static func main() throws {
        try verifiesExactlyFivePagesInTheApprovedOrder()
        try verifiesApprovedJapaneseCopy()
        try verifiesOrdinaryFirstRunTransitions()
        try verifiesPermissionSkipRoutesToWidgetGuide()
        try verifiesWidgetGuideSkipStillReachesFinalPage()
        try verifiesRevokedPhotoAccessReturnsToPermission()
        try verifiesResumeProgressIsClamped()
        try verifiesCompletionVersionOne()
        try verifiesWidgetGuideReplayIsNonDestructive()
        try verifiesWidgetPlacementRecoveryPolicy()
        print("Onboarding presentation verifier passed")
    }

    private static func verifiesExactlyFivePagesInTheApprovedOrder() throws {
        try require(
            OnboardingPresentationPage.allCases == [
                .purpose,
                .photoPermission,
                .scanResult,
                .widgetGuide,
                .pawLike
            ],
            "onboarding stopped being the approved five-page flow"
        )
        try require(
            OnboardingWidgetGuideStepPresentation.all.count == 4,
            "Widget guide stopped using four static screenshots"
        )
    }

    private static func verifiesApprovedJapaneseCopy() throws {
        try require(
            OnboardingPresentationCopy.purposeBodyLines == [
                "猫の写真は、",
                "撮るだけ撮って",
                "見ていないことが多い。",
                "このアプリは、その中から",
                "猫だけを自動で選んで、",
                "毎日ちがう1枚を",
                "ホーム画面に出します。"
            ],
            "page-one product promise changed"
        )
        try require(
            OnboardingPresentationCopy.purposeAction == "はじめる",
            "page-one action changed"
        )
        try require(
            OnboardingPresentationCopy.permissionTitleLines == [
                "このiPhoneの猫写真を探すために、",
                "写真を読ませてください。"
            ],
            "Photos permission request changed"
        )
        try require(
            OnboardingPresentationCopy.permissionPrivacyLines(isMediaAvailable: false) == [
                "・解析はすべてこの端末の中で行います",
                "・開発者のサーバーへ写真を自動送信しません",
                "・写真を消したり変更したりしません"
            ],
            "Photos permission privacy promise changed"
        )
        try require(
            OnboardingPresentationCopy.permissionPrivacyLines(isMediaAvailable: true) == [
                "・解析はすべてこの端末の中で行います",
                "・写真共有は別に同意した後、選んだ縮小1枚だけを暗号化して送ります",
                "・原本の自動送信・削除・変更はしません"
            ],
            "media-enabled Photos permission privacy promise changed"
        )
        try require(
            OnboardingPresentationCopy.homePermissionBody(isMediaAvailable: false)
                == "解析はこの端末内で行い、開発者のサーバーへ写真を自動送信しません。写真の変更や削除もしません。あとからここで許可できます。"
                && OnboardingPresentationCopy.homePermissionBody(isMediaAvailable: true)
                == "解析はこの端末内で行います。写真共有は別に同意した後、選んだ縮小1枚だけを暗号化して送ります。原本の自動送信・削除・変更はしません。あとからここで許可できます。",
            "Home Photos permission privacy promise changed"
        )
        try require(
            OnboardingPresentationCopy.permissionLimitedAccessNote
                == "「すべての写真」がおすすめです。「選択した写真のみ」でも動きます。",
            "limited Photos access support disappeared"
        )
        try require(
            OnboardingPresentationCopy.permissionAction == "写真へのアクセスを許可",
            "Photos permission action changed"
        )
        try require(
            OnboardingPresentationCopy.permissionSkipAction == "あとで（スキップ）",
            "Photos permission stopped offering the approved skip action"
        )
        try require(
            OnboardingPresentationCopy.scanTitle == "このiPhoneの猫写真を探しています",
            "scan title changed"
        )
        try require(
            OnboardingPresentationCopy.scanBodyLines == [
                "新しい写真から先に見ています。",
                "全部の集計は、",
                "次にひらいたときに続きます。"
            ],
            "scan manuscript copy changed"
        )
        try require(
            OnboardingPresentationCopy.resultLeadLines == [
                "このiPhoneで見つけた",
                "猫写真は"
            ],
            "scan-result lead changed"
        )
        try require(
            OnboardingPresentationCopy.resultCountSuffix == "枚"
                && OnboardingPresentationCopy.resultClosing == "ありました"
                && OnboardingPresentationCopy.resultOldestLead == "一番古い1枚は",
            "scan-result count or oldest-photo copy changed"
        )
        try require(
            OnboardingPresentationCopy.widgetTitleLines == [
                "ホーム画面に、",
                "猫写真のウィジェットをひとつ。"
            ],
            "Widget guide promise changed"
        )
        try require(
            OnboardingPresentationCopy.widgetAction == "わかった",
            "Widget guide primary action changed"
        )
        try require(
            OnboardingPresentationCopy.widgetLaterAction
                == "あとで見る（設定からいつでも開けます）",
            "Widget guide no longer promises a Settings return path"
        )
        try require(
            OnboardingWidgetGuideStepPresentation.all.map(\.caption) == [
                "ホーム画面の何もないところを長押し",
                "左上の「＋」をタップ",
                "「ねこのまど」を探す",
                "好きな大きさを選んで追加"
            ],
            "Widget installation steps changed"
        )
        try require(
            OnboardingPresentationCopy.pawTitleLines == [
                "気に入った1枚は、",
                "肉球を押しておいてください。"
            ],
            "paw-page title changed"
        )
        try require(
            OnboardingPresentationCopy.pawBody
                == "押した写真は「これ好き」に溜まります。",
            "paw explanation changed"
        )
        try require(
            OnboardingPresentationCopy.pawAction == "はじめる",
            "paw-page action changed"
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
        try require(state.currentPage == .pawLike, "Widget guide did not lead to paw explanation")

        state.advance()
        try require(!state.isPresented, "final action did not dismiss onboarding")
        try require(state.isFirstRunComplete, "final action did not complete onboarding")
    }

    private static func verifiesPermissionSkipRoutesToWidgetGuide() throws {
        var state = OnboardingPresentationState(persistedResumePageIndex: 1)
        try require(state.currentPage == .photoPermission, "permission resume setup failed")
        state.skipPhotoPermission()
        try require(
            state.currentPage == .widgetGuide,
            "permission skip bypassed the product-critical Widget guide"
        )
        try require(state.resumePageIndex == 3, "permission skip progress was not resumable")
    }

    private static func verifiesWidgetGuideSkipStillReachesFinalPage() throws {
        var state = OnboardingPresentationState(persistedResumePageIndex: 3)
        state.skipWidgetGuide()
        try require(
            state.currentPage == .pawLike,
            "first-run Widget skip did not preserve the final product lesson"
        )
        try require(
            state.completedVersion == 0,
            "skipping the Widget guide prematurely completed onboarding"
        )
        state.advance()
        try require(state.isFirstRunComplete, "final action did not complete a skipped guide flow")
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
        try require(aboveRange.currentPage == .pawLike, "oversized progress was not clamped")
        try require(aboveRange.resumePageIndex == 4, "oversized persisted index survived")

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
            persistedResumePageIndex: 4,
            persistedCompletedVersion: 1
        )
        try require(completedReplay.mode == .widgetGuideReplay, "replay mode was lost")
        try require(completedReplay.currentPage == .widgetGuide, "replay did not open page four")
        completedReplay.advance()
        try require(!completedReplay.isPresented, "replay action did not dismiss the guide")
        try require(completedReplay.completedVersion == 1, "replay cleared completion")
        try require(completedReplay.resumePageIndex == 4, "replay rewound progress")

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
