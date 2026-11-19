"""機種変更の画面（1115）：文・入口・通信の境目を固定する。

文は GroupRecoveryWords の 1 か所だけ。状態 1 つ＋ 1 文＋ボタンで、仕組みの言葉は書かない。
11/19: 公開版の入口は 設定 → 家族とまど の 1 行だけ。サーバーの発行の gate が開いていると
確かめられたとき（GroupRecoveryAvailability）だけ出す。閉じているときは何も出さない。
見本の一覧は内部試験の版だけ。
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
            "entry": "前のiPhoneのまど",
            "settingsEntry": "前のiPhoneから引き継ぐ",
            "start": "引き継ぐ",
            "unnamedWindow": "まど",
            "checkingTitle": "確認しています",
            "unavailableTitle": "つながりませんでした",
            "serverDisabledTitle": "機種変更の確認はいま使えません",
            "noRootsTitle": "引き継げる本人がまだ見つかりません",
            "syncAction": "このiPhoneの本人情報を同期する",
            "syncSaved": "このiPhoneで同期の準備ができました。",
            "syncFailed": "本人情報を同期できませんでした。",
            "retry": "もう一度",
            "foundTitle": "前のiPhoneのまどがあります",
            "foundMessage": "このiPhoneでも続けますか。",
            "continueButton": "続ける",
            "notNow": "今はしない",
            "waitingTitle": "もう少しで見られます",
            "waitingMessage": "前のiPhoneでアプリを開くと、続きが届きます。",
            "noProviderTitle": "前の写真は開けません",
            "noProviderMessage": "新しく続けることはできます。まどの名前は付け直します。",
            "freshContinue": "新しく続ける",
            "freshNameHeader": "まどの名前",
            "freshNamePlaceholder": "例：実家のまど",
            "needsOriginalTitle": "前のiPhoneが必要です",
            "needsOriginalMessage": "前のiPhoneでアプリを一度開くか、もう一度招待してもらってください。",
            "deviceLimitTitle": "使えるiPhoneは3台までです",
            "deviceLimitMessage": "外すiPhoneを選んでください。",
            "removeDevice": "外す",
            "keepDevice": "やめる",
            "removeDeviceMessage": "外したiPhoneでは、この人として入っているまどと家族の手帳が見られなくなります。",
            "revokedTitle": "このまどには戻れません",
            "chooseTitle": "どちらを使いますか",
            "choose": "こちらを使う",
            "inNothing": "まだどこにも入っていない",
            "usedOnThisIPhone": "このiPhoneで使っていた",
            "familyNotebook": "家族の手帳",
            "notebookWaiting": "家族のiPhoneか、前のiPhoneで ねこのまど を開くと、このiPhoneに手帳が戻ります。",
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

    def test_public_entry_only_while_the_relay_is_open(self):
        sources = internal.InternalPresentationBoundaryTests().sources()
        view_key = str(VIEW.relative_to(ROOT))
        settings_key = str((ROOT / "NekoWidget/Views/SettingsView.swift").relative_to(ROOT))
        for path, source in sources.items():
            if path == view_key:
                continue
            for token in ("GroupRecoveryEntryRow", "GroupRecoverySheet", "GroupRecoveryStateView",
                          "GroupRecoveryGallery", "GroupRecoveryFixtureRoot", "settings-group-recovery-gallery"):
                with self.subTest(path=path, token=token):
                    self.assertNotIn(token, source)
            if path != settings_key:
                with self.subTest(path=path, token="GroupRecoveryLiveScreen"):
                    self.assertNotIn("GroupRecoveryLiveScreen", source)
        public_view = sources[view_key]
        for token in ("GroupRecoveryGallery", "GroupRecoverySamples", "GroupRecoveryFixtureRoot"):
            self.assertNotIn(token, public_view)
        # One row in 設定 → 家族とまど, shown only once the relay's gate answered open.
        settings = sources[settings_key]
        self.assertEqual(settings.count("GroupRecoveryLiveScreen(model: .connected())"), 1)
        row = settings.split("if deviceChangeOpen {", 1)[1].split("} header: {", 1)[0]
        self.assertIn("GroupRecoveryLiveScreen(model: .connected())", row)
        self.assertIn('Text("家族とまど")', settings.split("if deviceChangeOpen {", 1)[1])
        self.assertEqual(settings.count(".task { deviceChangeOpen = await GroupRecoveryAvailability.isOpen() }"), 1)
        self.assertEqual(settings.count("deviceChangeOpen = "), 2)
        self.assertIn("@State private var deviceChangeOpen = false", settings)
        live = (ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift").read_text(encoding="utf-8")
        availability = live.split("enum GroupRecoveryAvailability {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("guard SharingAPIConfiguration.groupRecoveryRuntimeEnabled else { return false }", availability)
        self.assertIn("case .off: return false", availability)
        self.assertIn("return gate.state == .on", availability)

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

    def test_live_connection_is_tap_only_besides_one_probe(self):
        # 11/19: the real client ships. It is enabled by the person's tap, or by
        # the one automatic probe that learns the relay's gate (no screen of its own).
        live = ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift"
        text = live.read_text(encoding="utf-8")
        public = internal.selected_source(text)
        for token in ("GroupRecoveryLiveModel", "GroupRecoveryLiveBuilder", "GroupRecoveryAvailability", "GroupRecoveryClient("):
            self.assertIn(token, public)
        for token in ("GroupRecoverySyntheticSession", "GroupRecoverySyntheticKeySource"):
            self.assertNotIn(token, public)
        code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
        self.assertEqual(code.count("enabled: true"), 2)
        self.assertEqual(code.count("SharingPersonAction.run"), 1)
        self.assertEqual(code.count("SharingPersonAction.automatic"), 1)
        availability = code.split("enum GroupRecoveryAvailability {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("try? await SharingPersonAction.automatic { try await client.probe() }", availability)
        self.assertIn("journal: GroupRecoveryNoStore(), enabled: true)", availability)
        self.assertIn("guard !probing, lastProbe.map", availability)
        self.assertNotIn("publishCurrentRoot", availability)
        self.assertIn("let catalog = try await client.catalog()", code)
        # Each root has its own journal and Keychain namespace; nothing is removed locally.
        self.assertIn('namespace + ".recovery-journal." + scope', code)
        self.assertIn('namespace + ".recovery." + scope', code)
        # The only removal is forwarding the person's 3-iPhone choice to the relay
        # (11/19: the notebook's row passes it on to the same base).
        self.assertEqual(code.count(".remove("), 2)
        self.assertEqual(code.count("try await base.remove(device, operationID: operationID)"), 2)
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
        self.assertEqual(found["waitingMessage"], "前のiPhoneでアプリを開くと、続きが届きます。")
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
        # 11/19: the waiting check ships with the screen.
        self.assertIn("keepCheckingWaiting", internal.selected_source(view))
        # The capture is synthetic and DEBUG only.
        self.assertIn("GroupRecoveryKeysFixture()", internal.selected_source(view, {"DEBUG"}))
        self.assertNotIn("GroupRecoveryKeysFixture", internal.selected_source(view, {"INTERNAL_PRESENTATION"}))
        self.assertIn('requested == "keys-waiting"', view)
        shots = (ROOT / "NekoWidgetUITests/ReviewScreenshotUITests.swift").read_text(encoding="utf-8")
        self.assertIn('stateScreenshot("92o_recovery_keys_waiting", "keys-waiting", "group-recovery-screen")', shots)
        # 11/19: the real key delivery ships; the synthetic source stays internal.
        public = internal.InternalPresentationBoundaryTests().sources()
        combined = "\n".join(public.values())
        for token in ("GroupRecoveryKeyDeliverySession", "GroupRecoveryClientKeySource", "receiveKeys(", "finishKeyDelivery("):
            self.assertIn(token, combined)
        for path, source in public.items():
            with self.subTest(path=path):
                self.assertNotIn("GroupRecoverySyntheticKeySource", source)

    def test_new_iphone_returns_to_the_family_notebook(self):
        # 11/19 (機種変更 水準2): the notebook is one row of the same screen; 続ける
        # links this iPhone and the waiting row is the existing waiting state.
        live = (ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift").read_text(encoding="utf-8")
        code = "\n".join(line.split("//", 1)[0] for line in live.splitlines())
        session = code.split("actor GroupRecoveryNotebookSession", 1)[1].split("// MARK: - P5", 1)[0]
        self.assertIn("case .submitSameOperation(let id) where id == operationID:\n            try await steps.confirm()", session)
        self.assertIn("guard try await steps.linked() else { return .notStarted(operationID: operationID) }", session)
        self.assertIn(": .registeredWaitingForKeys(operationID: operationID, deviceID: deviceID)", session)
        self.assertIn("items.append(.init(windowID: \"notebook-\" + family.uuidString.lowercased(), name: nil, state: state,", code)
        self.assertIn("builder.notebook = { context in GroupRecoveryLiveModel.notebookSteps(", code)
        steps = code.split("static func notebookSteps(", 1)[1].split("static func connected()", 1)[0]
        # The link is written after any registration, then the notebook restarts.
        self.assertIn("FamilyNotebookIdentityChoice.confirmLink(", steps)
        self.assertIn("client.familyNotebookIdentity()", steps)
        keys = (ROOT / "NekoWidget/Services/FamilyNotebookKeyCoordinator.swift").read_text(encoding="utf-8")
        confirm = keys.split("static func confirmLink(", 1)[1].split("\n    }\n", 1)[0]
        self.assertLess(confirm.index("try await register()"), confirm.index("account: linkAccount"))
        self.assertIn("restartSession()", steps)
        # 11/19 (TestFlight 392): ready only from a read of the recovered
        # identity that finished now; the state before the switch is not kept.
        self.assertIn("FamilyNotebookSharing.shared.restartSession()", steps)
        self.assertIn("guard await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false) else { return false }", steps)
        sharing = (ROOT / "NekoWidget/Services/FamilyNotebookSharing.swift").read_text(encoding="utf-8")
        restart = sharing.split("func restartSession() {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("?.restartSession()", restart)
        self.assertIn("state = .checking", restart)
        read = sharing.split("private func read(reportsFailure: Bool) async -> Bool {", 1)[1].split("\n    }\n", 1)[0]
        self.assertLess(read.index("restartPending == true { return false }"), read.index("let syncing = "))
        found, _ = words()
        self.assertEqual(found["notebookWaiting"], "家族のiPhoneか、前のiPhoneで ねこのまど を開くと、このiPhoneに手帳が戻ります。")
        presentation = PRESENTATION.read_text(encoding="utf-8")
        self.assertIn("return Self(title: GroupRecoveryWords.notebookWaiting, message: nil,", presentation)
        view = VIEW.read_text(encoding="utf-8")
        self.assertEqual(view.count("GroupRecoveryStateView(state: item.screenState"), 2)

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
