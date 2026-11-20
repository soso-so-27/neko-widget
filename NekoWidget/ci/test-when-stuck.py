"""Source contracts for the 11/14 「困ったとき」 review (A1-A11).

One state, one sentence, one button; a cause is named only when the code
knows it. Native behaviour: NekoWidgetTests WhenStuckTests.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


class WidgetStuckWordsTests(unittest.TestCase):
    def test_a1_personal_widget_names_only_known_causes(self):
        shared = read("Shared/Models/WidgetManifest.swift")
        stuck = section(shared, "enum WidgetStuckState", "\n}\n")
        for title, subtitle in (
            ("写真を準備しています", "アプリを開くと始まります"),
            ("写真の許可が必要です", "タップしてアプリを開く"),
            ("猫の写真がまだありません", "猫の写真を撮ると、ここに出ます"),
            ("いまは出せません", "アプリを開くと、また出ます"),
        ):
            self.assertIn(f'"{title}"', stuck)
            self.assertIn(f'"{subtitle}"', stuck)
        # The status is optional: no value keeps "being prepared".
        self.assertIn("case nil: return unreadable ? .unreadable : .preparing", stuck)
        status = section(shared, "enum WidgetLibraryStatus", "\n}\n")
        self.assertIn('static let defaultsKey = "widgetLibraryStatus.v1"', status)
        self.assertIn("flatMap(Self.init(rawValue:))", status)
        # WidgetManifest.swift is compiled alone by CI verifiers.
        self.assertNotIn("SharedContainer", shared)

        provider = read("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        self.assertIn("WidgetLibraryStatus.read(from:", provider)
        self.assertNotIn("emptyStateReason: .needsApp)]", provider)
        view = read("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn('.accessibilityLabel("\\(emptyStateTitle)。\\(emptyStateSubtitle)")', view)
        self.assertIn("photoContent.widgetURL(entry.photoURL)", view)
        self.assertIn("state.title", view)
        self.assertIn("state.subtitle", view)
        entry = read("NekoWidgetWidget/NekoWidgetEntry.swift")
        # A tap still opens the app (the photo tab) for every stuck state.
        self.assertIn("guard emptyStateReason != .sourceUnavailable else { return PhotosTabRoute.url }", entry)
        self.assertIn("guard let localIdentifier else { return PhotosTabRoute.url }", entry)

        app = read("NekoWidget/ViewModels/AppViewModel.swift")
        writer = section(app, "private func publishWidgetLibraryStatus(", "private func setError(")
        self.assertIn("!hasCatPhotos && scanState.isComplete ? .noCatPhotos : nil", writer)
        self.assertIn("value = .photoAccessNeeded", writer)
        self.assertIn("model.publishWidgetLibraryStatus(hasCatPhotos: hasCatPhotos)", app)

    def test_a2_reveal_failure_is_said_and_cleared(self):
        intent = read("NekoWidgetWidget/RevealCloudyWindowIntent.swift")
        self.assertNotIn("try? CloudyWindowStore.shared.reveal", intent)
        self.assertIn("CloudyWindowRevealFailure.record(scopeID: scopeID, selectionID: selectionID", intent)
        self.assertIn("CloudyWindowRevealFailure.clear(in: defaults)", intent)
        provider = read("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        cloudy = section(provider, "private func cloudyTimeline(", "private func personalRediscoveryTimeline(")
        self.assertIn("planned.isCloudy, CloudyWindowRevealFailure.matches(", cloudy)
        self.assertIn(".stuck(.revealFailed", cloudy)
        app = read("NekoWidget/App/NekoWidgetApp.swift")
        self.assertIn("CloudyWindowRevealFailure.clear(in:", app)
        shared = read("Shared/Models/WidgetManifest.swift")
        self.assertIn('case .revealFailed: return "晴らせませんでした"', shared)
        # Only the tag reveals (11/3).
        view = read("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertEqual(view.count("RevealCloudyWindowIntent(selection:"), 1)

    def test_a8_deleted_cat_window(self):
        shared = read("Shared/Models/WidgetManifest.swift")
        self.assertIn('case .catRemoved: return "この子の写真は出せなくなりました"', shared)
        self.assertIn('case .catRemoved: return "長押しして、別の写真を選んでください"', shared)
        provider = read("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        self.assertIn(".stuck(.catRemoved", provider)
        # Real ended windows keep their words.
        view = read("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn('return "このまどは終わりました"', view)
        self.assertIn('return "長押しして、別のまどを選んでください"', view)


class AppWordsTests(unittest.TestCase):
    def test_a3_alert_and_fallback(self):
        root = read("NekoWidget/App/AppRootView.swift")
        alert = section(root, ".alert(item: $presentedError)", ".sheet(")
        self.assertIn("title: Text(error.message)", alert)
        self.assertNotIn('"うまくいきませんでした"', alert)
        self.assertIn('Text("閉じる")', alert)
        app = read("NekoWidget/ViewModels/AppViewModel.swift")
        messages = section(app, "static func userFacingMessage(for error: Error) -> String {", "private func logCandidateAuthorityUnavailable")
        self.assertIn('return "うまくいきませんでした。もう一度お試しください。"', messages)
        self.assertIn("設定の「お問い合わせ」からお知らせください。", messages)
        self.assertNotIn("App Storeでアプリを最新にしてください", messages)
        # Photo access only for the authorization error; storage only for a write.
        self.assertEqual(messages.count("写真へのアクセス"), 2)  # both in photoAccessDenied
        self.assertEqual(messages.count("空き容量"), 1)
        self.assertNotIn("setError(NekoWidgetError.noCatPhotos)", app)

    def test_a4_a5_confirmations(self):
        restore = "写真アプリの写真は消えません。設定の「写真の表示と整理」→「外した写真」から戻せます。"
        for path, count in (("NekoWidget/Views/CatProfilePhotoCurationViews.swift", 2),
                            ("NekoWidget/Views/LikedPhotosView.swift", 2),
                            ("NekoWidget/Views/GrowthAlbumView.swift", 1)):
            self.assertEqual(read(path).count(restore), count, path)
        settings = read("NekoWidget/Views/SettingsView.swift")
        self.assertIn('Label("写真の表示と整理"', settings)
        self.assertIn('"外した写真",', settings)
        for path in ("NekoWidget/Views/PhotoMemoryNoteView.swift", "NekoWidget/Views/PhotoMemoryNoteLibraryView.swift",
                     "NekoWidget/Views/VeterinaryVisitView.swift", "NekoWidget/Views/CareHandoffView.swift",
                     "NekoWidget/Views/CatCareView.swift", "NekoWidget/Views/PhotoDetailComponents.swift"):
            self.assertIn("元に戻せません。", read(path), path)

    def test_a6_a7_a9_a10(self):
        self.assertIn("保存したときと同じApple Accountか、確かめてください。",
                      read("NekoWidget/Views/ManagedPreservationView.swift"))
        contract = read("NekoWidget/Services/FamilyNotebookSharingContract.swift")
        self.assertIn('case .notAvailableYet: "いまは、まだ使えません。"', contract)
        self.assertIn('case .notAllowed: "いまは、この操作はできません。"', contract)
        for gone in ("試作のため", "もう一度サインインしてください。"):
            self.assertNotIn(gone, contract)
        self.assertIn("スクリーンタイムなどの制限で、写真を読み込めません。制限を変えると、読み込めます。",
                      read("NekoWidget/Views/PhotoPermissionView.swift"))
        settings = read("NekoWidget/Views/SettingsView.swift")
        self.assertIn('"CFBundleVersion"', settings)
        self.assertIn('.accessibilityLabel("ねこのまど バージョン \\(appVersion)、ビルド \\(appBuild)")', settings)

    def test_a11_unreachable_words_are_gone(self):
        for path in ("NekoWidget/Views/GroupWindowView.swift", "NekoWidgetShareExtension/GroupShareComposer.swift"):
            self.assertNotIn("センシティブな内容の警告", read(path), path)
        self.assertNotIn("checkIsOff", read("NekoWidget/Views/GroupWindowSetupView.swift"))
        pairing = read("NekoWidget/Views/PairingPresentation.swift")
        self.assertNotIn("診断情報をサポートに送ってください", pairing)
        self.assertNotIn("FailedPairingRecovery", pairing)


class DeadEnds1120Tests(unittest.TestCase):
    """11/20: every wait ends in a state with a way on. Native behaviour of
    the pure rules: NekoWidgetTests WhenStuckTests (testSaveFailure...,
    testShowcaseLaunchRequest..., testGroupWidgetEnded...)."""

    def test_1_failed_start_offers_the_first_runs_retry_on_the_photo_tab(self):
        home = read("NekoWidget/Views/HomeView.swift")
        state = section(home, "private var startupLoadFailedState: some View {", "@ViewBuilder")
        self.assertIn("Label(OnboardingPresentationCopy.loadFailedTitle", state)
        self.assertIn("Button(OnboardingPresentationCopy.loadFailedAction", state)
        self.assertIn("action: rescan)", state)
        self.assertLess(home.index("if scan.startupLoadFailed {"), home.index("emptyPhotoState\n"))
        root = read("NekoWidget/App/AppRootView.swift")
        self.assertIn("startupLoadFailed: viewModel.startupLoadFailed",
                      section(root, "private func scanPresentation(", "switch state.resultKind"))
        app = read("NekoWidget/ViewModels/AppViewModel.swift")
        rescan = section(app, "    func rescan() async {", "settings.analysisRevision += 1")
        # The retry runs the start again; it never resets or deletes records.
        self.assertIn("if startupLoadFailed {\n                await retryStartup()", rescan)
        retry = section(app, "    func retryStartup() async {", "\n    }\n")
        self.assertIn("await start()", retry)
        for gone in ("remove", "delete", "reset"):
            self.assertNotIn(gone, retry.lower())

    def test_2_long_online_save_failure_is_shown_but_retried_as_before(self):
        saving = read("NekoWidget/Services/AppRecordPersistence.swift")
        report = section(saving, "    private func report(_ error: Error) {",
                         "\n    private static func isConnectionFailure(")
        self.assertIn("retriesByItself = transient && !failureStreak.needsAttention(now: Date())", report)
        self.assertIn("AppRecordNetworkPath.shared.isOnline", report)
        # The retry schedule is computed before, and does not read the streak.
        schedule = section(report, "let transient = Self.isConnectionFailure(error)", "failing = true")
        self.assertNotIn("failureStreak", schedule)
        self.assertIn("transientFailures == 1 ? 5 : transientFailures == 2 ? 15 : 60", schedule)
        streak = section(saving, "struct AppRecordFailureStreak", "final class AppRecordNetworkPath")
        self.assertIn("static let onlineSpan: TimeInterval = 6 * 60 * 60", streak)
        self.assertIn("static let serverAnswerSpan: TimeInterval = 30 * 60", streak)
        self.assertIn("guard lastWasOnline else { return false }", streak)
        # Reading the network state contacts nothing.
        path = section(saving, "final class AppRecordNetworkPath", "@MainActor")
        self.assertIn("NWPathMonitor()", path)
        self.assertNotIn("URLSession", path)
        self.assertEqual(saving.count("; failureStreak = AppRecordFailureStreak()"), 3)

    def test_3_showcase_request_expires(self):
        intent = read("NekoWidgetWidget/OpenShowcaseIntent.swift")
        request = section(intent, "enum ShowcaseLaunchRequest {", "enum ShowcaseWidgetRoute")
        self.assertIn("static let lifetime: TimeInterval = 120", request)
        self.assertIn("defaults.removeObject(forKey: legacyKey)", request)
        self.assertIn("defaults?.set(Date().timeIntervalSince1970, forKey: key)", request)
        self.assertNotIn("UUID()", request)

    def test_4_group_widget_ends_only_when_the_app_saw_it(self):
        provider = read("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        group = section(provider, "private func groupEntry(", "private func familyEntry(")
        self.assertLess(group.index("GroupWidgetCache.missingEntry(windowID: windowID) == .ended"),
                        group.index("emptyStateReason: .sourceUnavailable"))
        self.assertIn("emptyStateReason: .needsApp)", group)
        intent = read("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift")
        self.assertIn("GroupWidgetCache.missingEntry(windowID: groupWindowID) == .ended", intent)
        cache = read("Shared/Sharing/GroupWidgetCache.swift")
        self.assertIn("var listedWindowIDs: [String]? = nil", cache)
        self.assertIn("var endedWindowIDs: [String]? = nil", cache)
        self.assertNotIn("Catalog(entries: entries())", cache)
        remove = section(cache, "static func remove(windowID: String) throws {", "\n    }\n")
        self.assertIn("catalog.endedWindowIDs = Array(ended.suffix(maximumEndedWindows))", remove)
        # The background refresh keeps the same list as the まど tab.
        service = read("NekoWidget/Services/MomentBackgroundRefreshService.swift")
        refresh = section(service, "func refreshWidgetPhotos(windowID: String? = nil) async {", "func receive(")
        self.assertIn("GroupWidgetCache.keepOnly(windowIDs: Set(windows.map(\\.id)))", refresh)

    def test_6_widget_reload_does_not_wait_for_the_cloudy_window(self):
        app = read("NekoWidget/ViewModels/AppViewModel.swift")
        rebuild = section(app, "private func performRebuildWidgetCache(", "if result.hasMore {")
        self.assertLess(rebuild.index("cloudyFailure = error"), rebuild.index("reloadAllWidgetTimelines()"))
        rounds = section(app, "personalReplenishmentTask = Task(priority: .utility)", "} catch { return } // Next")
        self.assertLess(rounds.index("if batch.addedCount > 0 { added = true }"),
                        rounds.index("try self.synchronizeCloudyWindowMetadata()"))

    def test_8_a_mado_notification_tap_always_lands_somewhere(self):
        service = read("NekoWidget/Services/MomentBackgroundRefreshService.swift")
        receive = section(service, "func receive(_ route: GroupNotificationRoute, open: Bool) async -> Bool {",
                          "\n    }\n}")
        self.assertEqual(receive.count("GroupWindowOpenInbox.shared.openList()"), 2)
        self.assertLess(receive.index("client.acceptsNotification("),
                        receive.index("GroupWindowOpenInbox.shared.open(windowID:"))
        window = read("NekoWidget/Views/GroupWindowView.swift")
        inbox = section(window, "final class GroupWindowOpenInbox", "final class GroupWindowListNavigation")
        self.assertIn("func openList() {", inbox)
        tab = read("NekoWidget/Views/MainTabView.swift")
        self.assertIn(".onChange(of: groupWindowOpenInbox.listRequested, initial: true)", tab)

    def test_9_proof_camera_asks_like_the_vet_camera(self):
        care = read("NekoWidget/Views/CatCareView.swift")
        self.assertIn("cameraBlocked = await VeterinaryCapture.cameraBlockedReason()", care)
        self.assertIn("if cameraBlocked == nil { showsCamera = true }", care)
        self.assertIn('Button("設定を開く")', care)
        self.assertNotIn("PHPhotoLibrary", care)
        capture = read("NekoWidget/Views/VeterinaryCapture.swift")
        camera = section(capture, "static func cameraBlockedReason() async -> String? {", "\n    }\n")
        self.assertNotIn("PHPhotoLibrary", camera)
        self.assertIn('"カメラを使うには、設定でカメラを許可してください。"', camera)
        self.assertIn("if let camera = await cameraBlockedReason() { return camera }", capture)

    def test_11_12_15_spinners_end(self):
        app = read("NekoWidget/ViewModels/AppViewModel.swift")
        refresh = section(app, "    func refreshPhotoSourceAlbums() async {",
                          "let managedAlbum = snapshot.albumLocalIdentifier")
        self.assertIn("widgetPhotoLibraryLoadSucceeded = false", refresh)
        official = read("NekoWidget/Views/OfficialWindowView.swift")
        load = section(official, "    private func refresh(interactive: Bool = false) async {",
                       "let previousPhotos = photos")
        self.assertIn("hasCheckedFeed = true\n            return", load)
        window = read("NekoWidget/Views/GroupWindowView.swift")
        deletion = section(window, "struct GroupIdentityDeletionView: View {", "private func delete() async {")
        self.assertNotIn("try? await client.identityDeletion()", deletion)
        self.assertIn("readFailed = true", deletion)
        self.assertLess(deletion.index("if readFailed {"), deletion.index("record.completedAt != nil"))


if __name__ == "__main__":
    unittest.main()
