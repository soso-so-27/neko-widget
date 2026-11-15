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


if __name__ == "__main__":
    unittest.main()
