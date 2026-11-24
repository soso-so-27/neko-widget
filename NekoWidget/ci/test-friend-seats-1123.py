#!/usr/bin/env python3
"""11/23 猫友のまど「席をとっておく」: the seats screen after 「作る」, the
on-device invite message, a young まど's one row, the first photo chosen
while waiting, 設定 without 「まどに招待する」 (11/24) and the join page. Source pins."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")
SETTINGS = read("NekoWidget/Views/SettingsView.swift")
PRESENTATION = section(SETUP, "enum GroupWindowPresentation {", "// MARK: - Members and invitation")
JOIN_PAGE = (REPO / "docs/join.html").read_text(encoding="utf-8")
PRIVACY = (REPO / "docs/privacy/index.html").read_text(encoding="utf-8")


class SeatsScreenTests(unittest.TestCase):
    def test_seats_use_the_member_cap_and_say_the_open_seats(self):
        first = section(WINDOW, "struct GroupWindowFirstInviteScreen: View {", "// MARK: - People blocked")
        self.assertIn("ForEach(0..<GroupWindowPresentation.memberLimit, id: \\.self)", first)
        self.assertNotIn("0..<6", first)
        self.assertIn('"group-window-seat-\\(index)"', first)
        self.assertIn("GroupMemberAvatar(name: people[index].displayName, size: 64)", first)
        self.assertIn("dash: [5, 4]", first)
        # An empty seat invites, the same as the button.
        self.assertEqual(first.count("Button(action: sendInvitation)"), 2)
        # 11/23: the button and the empty seat fit a family まど too.
        self.assertIn('.accessibilityLabel("招待する")', first)
        self.assertNotIn("猫友を招く", first)
        self.assertIn('"group-window-seats-open-line"', first)
        self.assertIn("static let memberLimit = 6", PRESENTATION)
        self.assertIn('"あと\\(count)人、無料で入れます"', PRESENTATION)
        self.assertIn("max(0, memberLimit - window.memberCount)", PRESENTATION)


class InviteMessageTests(unittest.TestCase):
    def test_message_is_made_here_with_the_cat_and_falls_back(self):
        message = section(PRESENTATION, "static func inviteMessage(windowName: String, catName: String?) -> String {",
                          "@MainActor static func inviteMessage(windowName: String) -> String {")
        self.assertIn('に席をとったよ。\\(cat)の写真を届け合おう。無料で入れるよ', message)
        # 11/23: fits a family まど too; it does not assume the invitee has a cat.
        self.assertNotIn('そっちの子', message)
        self.assertIn('catName.map { "うちの\\($0)" } ?? "うちの子"', message)
        self.assertIn('windowName.isEmpty ? "まど"', message)
        cat = section(PRESENTATION, "@MainActor static var ownCatName: String? {", "static func openSeats(")
        self.assertIn("CatCareStore.shared.state?.cats", cat)
        # Only the share sheet carries it: the link stays the URL alone.
        sheet = section(WINDOW, "struct GroupInvitationShareSheet: UIViewControllerRepresentable {", "struct WorkingLabel: View {")
        self.assertIn("UIActivityViewController(activityItems: [message, item], applicationActivities: nil)", sheet)
        self.assertNotIn("catName", read("NekoWidget/Services/GroupInvitationLink.swift"))


class YoungWindowRowTests(unittest.TestCase):
    def test_row_only_for_a_young_window_with_open_seats(self):
        self.assertIn("static let youngMemberLimit = 3", PRESENTATION)
        self.assertIn("static let youngPhotoLimit = 10", PRESENTATION)
        rule = section(PRESENTATION, "static func offersSeatsRow(", "static func memberCountText(")
        for needle in ("window.canManage", "window.state == .active", "!isPaused(window)", "openSeats(window) > 0",
                       "window.memberCount < youngMemberLimit", "photoCount < youngPhotoLimit"):
            self.assertIn(needle, rule)
        screen = section(WINDOW, "struct GroupWindowScreen: View {", "private struct GroupWindowContinueSheets")
        self.assertIn("if let window = model.shownWindow, !model.isFormer, showsSeatsRow(window) {", screen)
        self.assertIn("offersSeatsRow(window, photoCount: model.entries.count)", screen)
        self.assertIn('identifier: "group-window-seats-row"', screen)
        # The approved App Store screenshots stay as they are.
        self.assertIn("CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument)", screen)
        # Inviting stays on 「メンバー」.
        self.assertIn('"group-window-create-invitation"', SETUP)


class FirstPhotoWhileWaitingTests(unittest.TestCase):
    def test_choice_is_kept_here_and_offered_with_the_usual_confirmation(self):
        store = read("NekoWidget/Services/GroupWindowLocalPhotoStore.swift")
        memory = section(store, "enum GroupFirstPhotoMemory {", "\n}\n")
        self.assertIn('"groupWindow.firstPhoto.v1." + windowID', memory)
        self.assertNotIn("UserDefaults", WINDOW)
        row = section(WINDOW, "struct GroupFirstPhotoChoiceRow: View {", "struct GroupWindowScreen: View {")
        self.assertIn('"うちの子を1枚えらぶ"', row)
        self.assertIn('"group-join-choose-first-photo"', row)
        pending = section(SETUP, "private func pendingSection(", "private var approvedSection: some View {")
        self.assertIn("GroupFirstPhotoChoiceRow(windowID: windowID)", pending)
        offer = section(WINDOW, "private func offerFirstPhoto() {", "private func pausedCard(")
        self.assertIn("model.canSend", offer)
        self.assertIn("GroupFirstPhotoMemory.forget(windowID: model.windowID)", offer)
        # Never sent by itself: the same confirmation sheet as a picked cat photo.
        self.assertIn("libraryDelivery = GroupLibraryDeliveryRequest(localIdentifier: chosen)", offer)
        self.assertNotIn("deliver(", offer)
        # A request that ended forgets it.
        join = section(SETUP, "final class GroupJoinModel: ObservableObject {", "struct GroupJoinView: View {")
        self.assertIn("[Phase.rejected, .expired, .cancelled].contains(phase)", join)
        self.assertEqual(join.count("GroupFirstPhotoMemory.forget(windowID: windowID)"), 2)


class SettingsInviteTests(unittest.TestCase):
    def test_settings_only_recommends_and_inviting_stays_on_the_window(self):
        # 11/24 (owner): 設定 has no 「まどに招待する」; inviting is the まど's own 「招待する」.
        self.assertNotIn("まどに招待する", SETTINGS)
        self.assertNotIn('"settings-invite-friends"', SETTINGS)
        self.assertNotIn("GroupSeatsInviteButton(", SETTINGS)
        self.assertNotIn("windowWithOpenSeats", SETTINGS)
        self.assertNotIn("static func windowWithOpenSeats(", PRESENTATION)
        self.assertNotIn('猫友を招く', SETTINGS)
        self.assertIn("if let url = AppStoreListing.pageURL {", SETTINGS)
        self.assertIn('Text("ねこのまどを紹介する").foregroundStyle(Color.primary)', SETTINGS)
        self.assertIn('.accessibilityIdentifier("settings-recommend-app")', SETTINGS)
        self.assertIn("GroupSeatsInviteButton(client: model.client, windowID: model.windowID", WINDOW)


class JoinPageTests(unittest.TestCase):
    def test_one_picture_one_heading_two_buttons(self):
        self.assertIn("<h1>まどに、<br>席がとってあります</h1>", JOIN_PAGE)
        # 11/23: a まど is for family or cat friends alike.
        self.assertNotIn("猫友", JOIN_PAGE)
        self.assertIn("<p>参加は無料です。</p>", JOIN_PAGE)
        self.assertEqual(JOIN_PAGE.count("<svg"), 1)
        self.assertLess(JOIN_PAGE.index("App Store で入れる"), JOIN_PAGE.index(">アプリで開く<"))
        self.assertIsNone(re.search(r"<img\b|<ol\b", JOIN_PAGE))
        # The key explanation moved to the policy, one link away.
        self.assertIn('<a href="/privacy/">', JOIN_PAGE)
        self.assertNotIn("招待の鍵は", JOIN_PAGE)
        self.assertIn("招待の鍵は、リンクの「#」から後ろにあり、招待ページのサイトには送られません。", PRIVACY)
        self.assertIn("招待リンクは24時間使えます。", PRIVACY)


if __name__ == "__main__":
    unittest.main()
