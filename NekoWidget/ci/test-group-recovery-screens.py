"""機種変更の画面（1115）：文・入口・通信の境目を固定する。

文は GroupRecoveryWords の 1 か所だけ。状態 1 つ＋ 1 文＋ボタンで、仕組みの言葉は書かない。
発行が OFF の間、通常の版にはどこにも入口がない（内部試験の版の見本だけ）。
ボタンが何を呼ぶかは ci/verify-group-recovery-presentation.swift が固定する。
"""
from pathlib import Path
import importlib.util
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PRESENTATION = ROOT / "NekoWidget/Views/GroupRecoveryPresentation.swift"
VIEW = ROOT / "NekoWidget/Views/GroupRecoveryView.swift"

spec = importlib.util.spec_from_file_location("internal_presentation", Path(__file__).with_name("test-internal-presentation.py"))
internal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(internal)


def words():
    text = PRESENTATION.read_text(encoding="utf-8")
    block = text.split("enum GroupRecoveryWords {", 1)[1].split("\n}\n", 1)[0]
    return dict(re.findall(r'static let (\w+) = "([^"]*)"', block)), block


class GroupRecoveryScreenTests(unittest.TestCase):
    def test_words_are_fixed(self):
        found, _ = words()
        self.assertEqual(found, {
            "entry": "前の iPhone のまど",
            "unnamedWindow": "まど",
            "checkingTitle": "確認しています",
            "unavailableTitle": "つながりませんでした",
            "retry": "もう一度",
            "foundTitle": "前の iPhone のまどがあります",
            "foundMessage": "この iPhone でも続けますか。",
            "continueButton": "続ける",
            "notNow": "今はしない",
            "waitingTitle": "もう少しで見られます",
            "waitingMessage": "前の iPhone か、メンバーがアプリを開くと、続きが見られます。",
            "noProviderTitle": "前の写真は開けません",
            "noProviderMessage": "新しく続けることはできます。まどの名前は付け直します。",
            "freshContinue": "新しく続ける",
            "freshNameHeader": "まどの名前",
            "freshNamePlaceholder": "例：実家のまど",
            "needsOriginalTitle": "前の iPhone が必要です",
            "needsOriginalMessage": "前の iPhone でアプリを一度開くか、もう一度招待してもらってください。",
            "deviceLimitTitle": "使える iPhone は 3 台までです",
            "deviceLimitMessage": "外す iPhone を選んでください。",
            "removeDevice": "外す",
            "removeDeviceMessage": "外した iPhone では、この人として入っているまどと家族の手帳が見られなくなります。",
            "revokedTitle": "このまどには戻れません",
            "chooseTitle": "どちらを使いますか",
            "choose": "こちらを使う",
            "inNothing": "まだどこにも入っていない",
            "familyNotebook": "家族の手帳",
        })

    def test_no_mechanism_or_forever_words(self):
        _, block = words()
        for word in ("鍵", "暗号", "署名", "サーバー", "世代", "root", "ルート", "復号", "永久", "ずっと", "無料",
                     "端末", "operation", "登録待ち"):
            with self.subTest(word=word):
                self.assertNotIn(word, re.sub(r"//[^\n]*", "", block))

    def test_screen_words_live_in_one_place(self):
        # The always-built part of the View has no Japanese literal of its own.
        public_view = internal.selected_source(VIEW.read_text(encoding="utf-8"))
        code = "\n".join(line.split("//", 1)[0] for line in public_view.splitlines())
        self.assertEqual(re.findall(r'"[^"\n]*[぀-ヿ一-鿿][^"\n]*"', code), [])
        presentation = PRESENTATION.read_text(encoding="utf-8")
        outside = presentation.split("enum GroupRecoveryWords {", 1)[0] + presentation.split("enum GroupRecoveryWords {", 1)[1].split("\n}\n", 1)[1]
        outside = "\n".join(line.split("//", 1)[0] for line in outside.splitlines())
        self.assertEqual(re.findall(r'"[^"\n]*[぀-ヿ一-鿿][^"\n]*"', outside), [])

    def test_no_entry_in_the_public_build(self):
        sources = internal.InternalPresentationBoundaryTests().sources()
        view_key = str(VIEW.relative_to(ROOT))
        for path, source in sources.items():
            if path == view_key:
                continue
            for token in ("GroupRecoveryEntryRow", "GroupRecoverySheet", "GroupRecoveryStateView",
                          "GroupRecoveryGallery", "GroupRecoveryFixtureRoot", "settings-group-recovery-gallery"):
                with self.subTest(path=path, token=token):
                    self.assertNotIn(token, source)
        public_view = sources[view_key]
        for token in ("GroupRecoveryGallery", "GroupRecoverySamples", "GroupRecoveryFixtureRoot"):
            self.assertNotIn(token, public_view)

    def test_internal_build_has_the_sample_entry(self):
        for defines in ({"INTERNAL_PRESENTATION"}, {"DEBUG"}):
            settings = internal.selected_source((ROOT / "NekoWidget/Views/SettingsView.swift").read_text(encoding="utf-8"), defines)
            self.assertIn('NavigationLink("機種変更の画面（見本）") { GroupRecoveryGallery() }', settings)
        app = (ROOT / "NekoWidget/App/NekoWidgetApp.swift").read_text(encoding="utf-8")
        debug_only = internal.selected_source(app, {"DEBUG"})
        self.assertIn("GroupRecoveryFixtureRoot()", debug_only)
        self.assertNotIn("GroupRecoveryFixtureRoot", internal.selected_source(app, {"INTERNAL_PRESENTATION"}))

    def test_screens_do_no_network_and_mark_person_actions(self):
        for path in (PRESENTATION, VIEW):
            text = path.read_text(encoding="utf-8")
            for token in ("URLSession", "URLRequest", "Transport", "GroupWindowClient", "SharingAutoCallBudget",
                          "SecItem", "Keychain", "UserDefaults"):
                with self.subTest(path=path.name, token=token):
                    self.assertNotIn(token, text)
        presentation = PRESENTATION.read_text(encoding="utf-8")
        self.assertNotIn("import SwiftUI", presentation)
        # The Codex type decides what is sent.
        self.assertIn("state.freshGenerationChoice(confirmedPastUnavailable: true, newName: trimmed)", presentation)
        self.assertIn(".send(.perform(state.nextAction))", presentation)
        view = VIEW.read_text(encoding="utf-8")
        self.assertIn("Task { await SharingPersonAction.run { await handler.handle(command) } }", view)
        self.assertEqual(view.count("SharingPersonAction.run"), 1)
        # Existing parts, not a new look.
        self.assertIn(".nekoPrimaryButton()", view)
        self.assertIn("ContentUnavailableView {", view)
        self.assertIn("SheetCloseButton", view)

    def test_verifier_and_tests_run_in_quick_checks(self):
        quick = (ROOT / "ci/run-quick-ios-checks.sh").read_text(encoding="utf-8")
        self.assertIn("python3 ci/test-group-recovery-screens.py", quick)
        compile_line = quick.split('"$RUNNER_TEMP/group-recovery-presentation"\n', 1)[0].rsplit("xcrun ", 1)[1]
        for source in ("Shared/Sharing/GroupWindowCore.swift", "NekoWidget/Services/GroupWindowContract.swift",
                       "NekoWidget/Views/GroupRecoveryPresentation.swift", "ci/verify-group-recovery-presentation.swift"):
            self.assertIn(source, compile_line)
        project = (ROOT / "NekoWidget.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        for name in ("GroupRecoveryPresentation.swift", "GroupRecoveryView.swift"):
            self.assertEqual(project.count(name + " in Sources */ ="), 1)
            self.assertEqual(project.count(name + " in Sources */,"), 1)


if __name__ == "__main__":
    unittest.main()
