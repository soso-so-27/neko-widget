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
            "serverDisabledTitle": "機種変更の確認はいま使えません",
            "noRootsTitle": "引き継げる本人がまだ見つかりません",
            "syncAction": "このiPhoneの本人情報を同期する",
            "syncSaved": "このiPhoneで同期の準備ができました。",
            "syncFailed": "本人情報を同期できませんでした。",
            "retry": "もう一度",
            "foundTitle": "前の iPhone のまどがあります",
            "foundMessage": "この iPhone でも続けますか。",
            "continueButton": "続ける",
            "notNow": "今はしない",
            "waitingTitle": "もう少しで見られます",
            "waitingMessage": "前の iPhone でアプリを開くと、続きが届きます。",
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
            "keepDevice": "やめる",
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

    def test_live_connection_is_internal_and_tap_only(self):
        # The real P3 client is enabled only by the internal test screen, after a tap.
        live = ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift"
        text = live.read_text(encoding="utf-8")
        self.assertEqual(internal.selected_source(text).strip(), "")
        for path, source in internal.InternalPresentationBoundaryTests().sources().items():
            for token in ("GroupRecoveryLiveModel", "GroupRecoveryLiveScreen", "GroupRecoveryAdapter(",
                          "GroupRecoveryLiveBuilder", "GroupRecoverySyntheticSession", "GroupRecoveryClient("):
                with self.subTest(path=path, token=token):
                    self.assertNotIn(token, source)
        code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
        self.assertEqual(code.count("enabled: true"), 1)
        self.assertEqual(code.count("SharingPersonAction.run"), 1)
        self.assertNotIn("SharingPersonAction.automatic", code)
        self.assertIn("let catalog = try await client.catalog()", code)
        # Each root has its own journal and Keychain namespace; nothing is removed locally.
        self.assertIn('namespace + ".recovery-journal." + scope', code)
        self.assertIn('namespace + ".recovery." + scope', code)
        # The only removal is forwarding the person's 3-iPhone choice to the relay.
        self.assertEqual(code.count(".remove("), 1)
        self.assertIn("try await base.remove(device, operationID: operationID)", code)
        self.assertIsNone(re.search(r"(journal|secrets|store|Keychain\w*)\S*\.remove", code))
        view = VIEW.read_text(encoding="utf-8")
        self.assertIn("GroupRecoveryLiveScreen(model: .connected())", internal.selected_source(view, {"INTERNAL_PRESENTATION"}))
        self.assertIn("GroupRecoverySheet(rootChoice: adapter.rootChoice, items: adapter.items, handler: adapter)", view)
        project = (ROOT / "NekoWidget.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        for name in ("GroupRecoveryAdapter.swift", "GroupRecoveryLiveSession.swift"):
            self.assertEqual(project.count(name + " in Sources */ ="), 1)
            self.assertEqual(project.count(name + " in Sources */,"), 1)
        probe = (ROOT / "ci/run-group-recovery-client-checks.sh").read_text(encoding="utf-8")
        self.assertIn("NekoWidget/Services/GroupRecoveryLiveSession.swift", probe)

    def test_new_iphone_receives_keys_on_the_same_operation(self):
        # P5 (Codex 1117c/1117d): one bounded page from nextAfterEpoch on the saved
        # Draft, ready only from finishKeyDelivery, and waiting kept on failure.
        live = (ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift").read_text(encoding="utf-8")
        code = "\n".join(line.split("//", 1)[0] for line in live.splitlines())
        self.assertIn("base.client.receiveKeys(draft(id), identity: base.identity, status: registration, afterEpoch: afterEpoch)", code)
        self.assertIn("base.client.finishKeyDelivery(draft(id), identity: base.identity)", code)
        self.assertIn("page = try await source.receive(id, status: status, afterEpoch: cursor[id] ?? 0)", code)
        self.assertIn('case "recoveryCommitted": self = .finish', code)
        self.assertIn('case "needsParticipationProof": self = .needsProof', code)
        self.assertIn("return .needsOriginalDeviceOrInvitation(operationID: id)", code)
        self.assertIn("GroupRecoveryKeyDeliverySession(base: base, source: GroupRecoveryClientKeySource(base: base))", code)
        delivery = code.split("actor GroupRecoveryKeyDeliverySession", 1)[1].split("actor GroupRecoverySyntheticKeySource", 1)[0]
        # The relay's words never open a まど here; only the verified install does.
        self.assertNotIn(".ready(", delivery)
        for token in ("write(", "createOnly", "Keychain", "URLRequest", "Transport", "while ", "repeat "):
            with self.subTest(token=token):
                self.assertNotIn(token, delivery)
        # States of the original iPhone are not shown on the new one.
        for path in (PRESENTATION, VIEW, ROOT / "NekoWidget/Services/GroupRecoveryAdapter.swift",
                     ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift"):
            text = "\n".join(line.split("//", 1)[0] for line in path.read_text(encoding="utf-8").splitlines())
            for token in ('"noPendingDevice"', '"outsideParticipation"', '"keyNotHeld"', '"waitingForKeys"'):
                with self.subTest(path=path.name, token=token):
                    self.assertNotIn(token, text)
        # Waiting: one state, one sentence, no button, no percentage or count.
        found, block = words()
        self.assertEqual(found["waitingMessage"], "前の iPhone でアプリを開くと、続きが届きます。")
        for token in ("%", "％", "枚", "件", "割", "残り"):
            with self.subTest(token=token):
                self.assertNotIn(token, found["waitingTitle"] + found["waitingMessage"])
        # Checking again is automatic, spaced by the existing gap, bounded, and
        # only for a まど that waits for its keys.
        adapter = (ROOT / "NekoWidget/Services/GroupRecoveryAdapter.swift").read_text(encoding="utf-8")
        self.assertIn("SharingPersonAction.automatic { try await session.run(.queryStatus(id)) }", adapter)
        self.assertIn("every interval: Duration = .seconds(SharingForegroundGap.seconds)", adapter)
        self.assertIn("static let waitingCheckLimit = 30", adapter)
        self.assertIn("while waitingChecks < Self.waitingCheckLimit, !dismissed {", adapter)
        self.assertIn("if case .registeredWaitingForKeys(let id, _) = item.state { return id }", adapter)
        self.assertNotIn("SharingPersonAction.run", adapter)
        view = VIEW.read_text(encoding="utf-8")
        self.assertEqual(view.count(".task { await adapter.keepCheckingWaiting() }"), 1)
        self.assertNotIn("keepCheckingWaiting", internal.selected_source(view))
        # The capture is synthetic and DEBUG only.
        self.assertIn("GroupRecoveryKeysFixture()", internal.selected_source(view, {"DEBUG"}))
        self.assertNotIn("GroupRecoveryKeysFixture", internal.selected_source(view, {"INTERNAL_PRESENTATION"}))
        self.assertIn('requested == "keys-waiting"', view)
        shots = (ROOT / "NekoWidgetUITests/ReviewScreenshotUITests.swift").read_text(encoding="utf-8")
        self.assertIn('stateScreenshot("92o_recovery_keys_waiting", "keys-waiting", "group-recovery-screen")', shots)
        for path, source in internal.InternalPresentationBoundaryTests().sources().items():
            for token in ("GroupRecoveryKeyDeliverySession", "GroupRecoverySyntheticKeySource", "GroupRecoveryClientKeySource",
                          "keepCheckingWaiting", "receiveKeys(", "finishKeyDelivery("):
                with self.subTest(path=path, token=token):
                    self.assertNotIn(token, source)

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
