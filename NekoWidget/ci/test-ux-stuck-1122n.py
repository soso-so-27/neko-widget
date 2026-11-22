"""11/22 (when something goes wrong): what happened and what to do next,
with no false alarm and no button that cannot help.

1. まど's daily photo limit is a quiet notice: not red, no 「もう一度」, and the
   photo is not kept for 「もう一度届ける」 (its sealed copy is discarded).
2. A sensitive photo: one sentence in the app and the share sheet, no retry.
3. No connection: one sentence across the まど, the family notebook, のわのまど
   (network failures only) and the share sheet. The まど shows one retry:
   the unsent row's 「もう一度届ける」, not the line's 「もう一度」 as well.
4. Plus price not loaded: 「料金を確認できません。」 above 「もう一度読み込む」.
5. No setup words (App Group, Signing & Capabilities) on screen.
6. 「写真へのアクセスを許可していません。」 (also after it was turned off).
7. The gear's auto-save mark is a symbol, not a colour dot.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")
SHARE = read("NekoWidgetShareExtension/GroupShareComposer.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")
CONTRACT = read("NekoWidget/Services/FamilyNotebookSharingContract.swift")
OFFICIAL = read("NekoWidget/Views/OfficialWindowView.swift")
PLUS = read("NekoWidget/Services/PlusRenewalPresentation.swift")
ERROR = read("Shared/Models/NekoWidgetError.swift")
SETTINGS = read("NekoWidget/Views/SettingsView.swift")

OFFLINE = "接続できません。電波のあるところで、もう一度お試しください。"
SENSITIVE = "センシティブな内容が含まれている可能性があります。別の写真を選んでください。"


class DailyLimitIsANotice(unittest.TestCase):
    def test_limit_words_are_a_notice(self):
        self.assertIn("static func isDailyLimitNotice(_ message: String) -> Bool {", SETUP)
        self.assertIn("message == dailyPhotoLimitMessage || message == dailyHeartLimitMessage", SETUP)
        self.assertIn("var messageIsNotice: Bool { message.map(GroupWindowPresentation.isDailyLimitNotice) ?? false }",
                      WINDOW)

    def test_the_line_is_quiet_and_has_no_retry(self):
        line = section(WINDOW, "private func screenMessage(_ message: String) -> some View {", "var body: some View {")
        self.assertIn('model.messageIsNotice ? "clock" : "exclamationmark.triangle"', line)
        self.assertIn(".foregroundStyle(model.messageIsNotice ? Color.secondary : Color.red)", line)
        self.assertNotIn(".foregroundStyle(.red)", line)
        self.assertLess(line.index("if model.messageOffersReload {"), line.index('title: "もう一度"'))
        # The photo's own delivery sheet says the limit quietly too.
        self.assertIn('Label(message, systemImage: model.messageIsNotice ? "clock" : "exclamationmark.triangle")\n'
                      "                                .foregroundStyle(model.messageIsNotice ? Color.secondary : Color.red)",
                      WINDOW)

    def test_the_photo_is_not_kept_to_resend(self):
        deliver = section(WINDOW, "func deliver(_ prepared: PreparedPhoto, memo: String) async {",
                          "static func deliveryMessage(")
        limit = section(deliver, "if error as? GroupClientError == .dailyLimit {", "} else if !(error is GroupSubscriptionError) {")
        self.assertIn("await client.discardPendingDelivery(operationID: prepared.operationID)", limit)
        self.assertNotIn("failedDelivery = FailedDelivery", limit)
        # The server's limit stays; no counter on screen.
        self.assertIn('static let dailyPhotoLimitMessage = "きょうはここまでです。あした、また届けられます。"', SETUP)


class SensitivePhoto(unittest.TestCase):
    def test_one_sentence_everywhere(self):
        self.assertIn(f'case .hidden: return "{SENSITIVE}"', WINDOW)
        self.assertIn(f'return "{SENSITIVE}"', SHARE)
        self.assertNotIn("センシティブな内容が含まれている可能性があるため", WINDOW)

    def test_no_reload_after_a_picked_photo_check(self):
        # Only a failed read of the window offers 「もう一度」.
        self.assertIn("message != nil && message == reloadMessage && (failedDelivery == nil || window == nil)", WINDOW)
        self.assertEqual(WINDOW.count("reloadMessage = message"), 2)
        sync_catch = section(WINDOW, "            message = GroupWindowPresentation.message(for: error)\n            reloadMessage = message",
                             "morePhotosComing = false")
        self.assertTrue(sync_catch)
        self.assertIn("catch { message = GroupWindowPresentation.message(for: error); reloadMessage = message }", WINDOW)
        for prepare_start in ("func prepare(_ item: PhotosPickerItem) async -> PreparedPhoto? {",
                              "func prepare(localIdentifier: String) async -> PreparedPhoto? {"):
            prepare = section(WINDOW, prepare_start, "return PreparedPhoto(")
            self.assertNotIn("reloadMessage", prepare)
            self.assertNotIn("failedDelivery", prepare)


class OneOfflineSentence(unittest.TestCase):
    def test_mado_and_share_sheet(self):
        self.assertIn(f'case .offline:\n            return "{OFFLINE}"', SETUP)
        offline = section(SHARE, "case GroupClientError.offline:", "default:")
        self.assertIn(f'return "{OFFLINE}"', offline)
        # A genuinely unknown outcome keeps its own words.
        self.assertIn('return "届けられたか確認できませんでした。少し待ってから、もう一度お試しください。"', SHARE)
        # The 届ける sentence names the right button and stays.
        self.assertIn("インターネットにつながらず、届けられませんでした。つながったら「もう一度届ける」を押してください。", WINDOW)

    def test_family_notebook(self):
        self.assertIn(f'case .offline: "{OFFLINE}"', CONTRACT)
        self.assertNotIn("インターネットにつながっていません", CONTRACT)
        self.assertNotIn('Label("つながりませんでした"', NOTEBOOK)
        words = section(NOTEBOOK, "enum FamilyNotebookOfflineText {", "\n}")
        self.assertIn('static let title = "接続できません。"', words)
        self.assertIn('static let next = "電波のあるところで、もう一度お試しください。"', words)
        self.assertIn("static let sentence = title + next", words)
        self.assertEqual(NOTEBOOK.count("Label(FamilyNotebookOfflineText.title, systemImage: \"wifi.exclamationmark\")"), 2)
        self.assertEqual(NOTEBOOK.count("Text(FamilyNotebookOfflineText.next)"), 2)

    def test_nowa_only_for_network_failures(self):
        self.assertIn(f'static let offlineMessage = "{OFFLINE}"', OFFICIAL)
        check = section(OFFICIAL, "static func isOffline(_ error: Error) -> Bool {", "\n    }")
        self.assertIn("guard let error = error as? URLError else { return false }", check)
        self.assertIn(".notConnectedToInternet", check)
        self.assertIn("setFeedback(OfficialWindowStatusPresentation.isOffline(error)\n"
                      "                            ? OfficialWindowStatusPresentation.offlineMessage\n"
                      '                            : "新しい写真を読み込めませんでした。少し待ってから、もう一度お試しください。", failed: true)',
                      OFFICIAL)

    def test_one_retry_on_the_mado_after_a_failed_send(self):
        # A waiting photo hides the line's 「もう一度」; its row keeps 「もう一度届ける」.
        self.assertIn("(failedDelivery == nil || window == nil)", WINDOW)
        row = section(WINDOW, "private func failedDeliveryRow(", "private var sendBar: some View {")
        self.assertIn('"もう一度届ける"', row)


class SmallerWords(unittest.TestCase):
    def test_plus_price(self):
        self.assertIn('static let unavailableMessage = "料金を確認できません。"', PLUS)
        self.assertNotIn("時間をおいて開き直して", PLUS)

    def test_no_setup_words(self):
        self.assertNotIn("Signing & Capabilities", ERROR)
        self.assertNotIn('"App Group', ERROR)
        self.assertIn('return "うまくいきませんでした。アプリを開き直してください。"', ERROR)
        self.assertIn("case appGroupUnavailable(String)", ERROR)

    def test_photo_access_footer(self):
        self.assertIn('Text("写真へのアクセスを許可していません。")', SETTINGS)
        self.assertNotIn("まだ写真へのアクセスを許可していません。", SETTINGS)


class GearMark(unittest.TestCase):
    def test_symbol_not_dot(self):
        gear = section(SETTINGS, "struct SettingsGearIcon: View {", "struct AutoSaveSettingsRow: View {")
        self.assertNotIn("Circle().fill(Color.orange)", gear)
        self.assertIn('Image(systemName: "exclamationmark.circle.fill")', gear)
        self.assertIn(".foregroundStyle(.white, .orange)", gear)
        self.assertIn('.accessibilityValue(stopped ? "自動保存が止まっています" : "")', gear)


if __name__ == "__main__":
    unittest.main()
