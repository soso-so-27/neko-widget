#!/usr/bin/env python3
"""11/22f: まど usability — the list's cards show each まど's newest photo
(A4), and right after 「作る」 the one thing to do is inviting (A5). Source pins."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")


class ListCardCoverTests(unittest.TestCase):
    def test_sync_can_receive_the_newest_photo_alone(self):
        self.assertIn("func sync(background: Bool) async { await sync(background: background, newestOnly: false) }", WINDOW)
        sync = section(WINDOW, "    func sync(background: Bool, newestOnly: Bool) async {", "    func updateHomeScreenPhoto()")
        self.assertIn("? (photos.max(by: { $0.createdAt < $1.createdAt }).map { [$0] } ?? [])", sync)
        self.assertIn("for photo in receiving {", sync)
        # The same receive path: moderation check, keep, Widget copy.
        loop = section(sync, "for photo in receiving {", "morePhotosComing = stopped")
        self.assertIn("await receive(photo, me: latest.myParticipantID)", loop)
        self.assertIn("await updateHomeScreenPhoto()", sync)

    def test_the_list_reads_each_window_in_the_background(self):
        model = section(WINDOW, "final class GroupWindowListModel: ObservableObject {", "struct GroupWindowCreateScreen: View {")
        load = section(model, "    func load() async {", "private func renewPendingKeys()")
        self.assertIn("renewPendingKeys()\n            refreshCovers()", load)
        covers = section(model, "    private func refreshCovers() {", "/// Set when the relay answers")
        self.assertIn("guard coverRefresh == nil else { return }", covers)
        self.assertIn("$0.state == .active && !GroupWindowPresentation.isPaused($0)", covers)
        self.assertIn("SharingForegroundGap.allows(since: Self.coverRefreshedAt[$0.id])", covers)
        self.assertIn("GroupWindowListNavigation.shared.openedWindow?.windowID != window.id", covers)
        self.assertIn("await SharingPersonAction.automatic { await model.sync(background: true, newestOnly: true) }", covers)
        self.assertIn("private static var coverRefreshedAt", model)

    def test_card_redraws_and_keeps_the_safety_filters(self):
        card = section(WINDOW, "private struct GroupWindowCard: View {", "private struct WindowCardEmptyCover: View {")
        self.assertIn("Task { await loadCover(); await loadNewMark() }", card)
        cover = section(card, "private func loadCover() async {", "\n}\n")
        self.assertIn("!$0.isHidden && !GroupSafety.shared.hasReported($0.id, in: window.id) && !withdrawn.contains($0.id)", cover)
        self.assertIn("GroupWidgetCache.withdrawnPhotoIDs(windowID: window.id)", cover)
        self.assertIn("cover = nil", cover)
        # Blocked and hidden people are left out by the store itself.
        self.assertIn("await store.entries(windowID: window.id)", cover)
        # The Widget copy the card reads first skips the same photos.
        home = section(WINDOW, "    func updateHomeScreenPhoto() async {", "    /// What happened to one photo of a sync.")
        self.assertIn("!$0.isHidden && !safety.hasReported($0.id, in: windowID) && !withdrawn.contains($0.id)", home)


class FirstInviteTests(unittest.TestCase):
    def test_create_opens_the_invitation_then_the_window(self):
        create = section(WINDOW, "struct GroupWindowCreateScreen: View {", "struct GroupWindowStandardsAgreement: View {")
        body = section(create, "    var body: some View {", "    private var form: some View {")
        self.assertLess(body.index("GroupWindowScreen(client: model.client, windowID: createdWindowID)"),
                        body.index("GroupWindowFirstInviteScreen(client: model.client, windowID: createdWindowID)"))
        self.assertIn("invitedOrLater = true", body)
        self.assertNotIn("GroupWindowMembersScreen(", body)

    def test_the_first_screen_has_one_primary_and_a_quiet_later(self):
        first = section(WINDOW, "struct GroupWindowFirstInviteScreen: View {", "// MARK: - People blocked")
        self.assertEqual(first.count(".buttonStyle(.borderedProminent)"), 1)
        self.assertIn('Label("招待リンクを送る", systemImage: "square.and.arrow.up")', first)
        self.assertIn('Button("あとで") { onDone() }', first)
        self.assertLess(first.index('"group-window-first-invite-send"'), first.index('"group-window-first-invite-later"'))
        self.assertIn("WindowCardEmptyCover()", first)
        # The existing invitation steps and sheet, no new server call.
        self.assertIn("GroupWindowMembersModel(client: client, windowID: windowID)", first)
        self.assertIn("await model.revokeInvitation()", first)
        self.assertIn("await model.createInvitation()", first)
        self.assertIn("GroupInvitationShareSheet(", first)
        self.assertIn("onCompleted: { sent = true }", first)
        self.assertIn(".sheet(item: $sharing, onDismiss: { if sent { onDone() } })", first)
        self.assertNotIn("placeOnHomeScreenAction", first)

    def test_share_sheet_reports_a_completed_share(self):
        sheet = section(WINDOW, "struct GroupInvitationShareSheet: UIViewControllerRepresentable {", "struct WorkingLabel: View {")
        self.assertIn("var onCompleted: (() -> Void)? = nil", sheet)
        self.assertIn("if completed { onCompleted?() }", sheet)
        self.assertLess(sheet.index("let onFinish: () -> Void"), sheet.index("var onCompleted"))

    def test_place_on_home_screen_stays_on_members(self):
        members = section(WINDOW, "    private var membersScreen: some View {", "/// The red error line")
        self.assertIn("offersWidgetPlacement: true", members)
        self.assertEqual(SETUP.count('"group-window-place-widget"'), 1)

    def test_orphan_message_is_gone_and_permission_timing_kept(self):
        self.assertNotIn("招待リンクは、まどの「メンバー」から作れます。", WINDOW)
        create = section(WINDOW, "    func create(name: String, ownerName: String) async -> GroupWindow? {", "struct GroupWindowCreateScreen: View {")
        self.assertIn("_ = try? await client.createInvitation(windowID: window.id", create)
        self.assertIn("Task { await GroupAdmissionService.shared.refresh(requestPermission: true) }", create)


if __name__ == "__main__":
    unittest.main()
