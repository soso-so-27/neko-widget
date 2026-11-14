"""Source contracts for the family journey (design review 11/14, section A).

A1. The first screen has one quiet line for people who installed from an
    invitation (not a button, no clipboard reader); the link still opens the
    join screen over the first run, and joining ends it.
A2. 「参加できました」 offers 「ホーム画面に置く」 under 「まどを開く」, and the
    members screen right after making a window has the same row; both open
    the one widget guide with the window's name, and put the window in the
    Widget's 「表示する写真」 first.
A3. Plus bought (or restored) from the create-window prompt makes the window
    with the names already typed; the family notebook's 「Plusを始めて再開する」
    takes over paying once bought, when the family allows it.
A4. 「24時間使えます。」 under the まど's and the family notebook's invite
    button (the server's 86400 seconds for both).
A5. One press on the family notebook's 「招待を送る」 makes the link and opens
    the share sheet.
A6. The 写真 tab with no cat photos points a まど member to the まど tab.

Native behaviour: NekoWidgetTests FamilyJourneyTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


ONBOARDING = read("NekoWidget/Views/OnboardingView.swift")
ONBOARDING_COPY = read("NekoWidget/Views/OnboardingPresentation.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")
WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
OFFICIAL = read("NekoWidget/Views/OfficialWindowView.swift")
OFFER = read("NekoWidget/Services/MembershipOfferModel.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")
HOME = read("NekoWidget/Views/HomeView.swift")
TABS = read("NekoWidget/Views/MainTabView.swift")
PROJECT = read("NekoWidget.xcodeproj/project.pbxproj")
TESTS = read("NekoWidgetTests/FamilyJourneyTests.swift")
GROUP_SERVER = read("SharingService/src/group-windows.ts")
NOTEBOOK_SERVER = read("SharingService/migrations/0055_family_notebook_admission.sql")


class InvitationLineTests(unittest.TestCase):
    def test_first_screen_has_one_quiet_line(self):
        self.assertIn('static let purposeInvitationLine = "招待を受けた方は、届いたリンクをもう一度開いてください。"',
                      ONBOARDING_COPY)
        purpose = section(ONBOARDING, "private struct OnboardingPurposePage: View", "struct OnboardingWindowMosaic: View")
        line = section(purpose, "Text(OnboardingPresentationCopy.purposeInvitationLine)",
                       '.accessibilityIdentifier("onboarding-purpose-invitation-line")')
        self.assertIn(".foregroundStyle(.secondary)", line)
        # Under the one main button, and not a button itself.
        self.assertLess(purpose.index('"onboarding-purpose-start"'), purpose.index("purposeInvitationLine"))
        self.assertNotIn("Button(OnboardingPresentationCopy.purposeInvitationLine", purpose)
        self.assertNotIn("UIPasteboard", ONBOARDING)

    def test_link_still_opens_the_join_screen_and_joining_ends_the_first_run(self):
        self.assertIn(".onChange(of: invitationInbox.pending?.id, initial: true)", ROOT_VIEW)
        dismiss = section(ROOT_VIEW, ".sheet(item: $onboardingInvitation, onDismiss: {",
                          "GroupInvitationJoinSheet(invitation: invitation)")
        self.assertIn("completeOnboardingForInvitation()", dismiss)


class WidgetPlacementTests(unittest.TestCase):
    def test_joined_screen_offers_the_guide_for_this_window(self):
        approved = section(SETUP, "private var approvedSection: some View {", "private func resultSection(")
        self.assertLess(approved.index('"group-join-open-window"'), approved.index('"group-join-place-widget"'))
        place = section(approved, "if let windowName = model.placementWindowName", '"group-join-place-widget"')
        self.assertIn("GroupWidgetCache.offerForPlacement(windowID: windowID, windowName: windowName)", place)
        self.assertIn("GroupWindowPresentation.placeOnHomeScreenAction", place)
        # The primary stays 「まどを開く」; this one is quieter.
        self.assertIn(".buttonStyle(.bordered)", place)
        join = section(SETUP, "struct GroupJoinView: View {", "private var nameSection: some View {")
        self.assertIn("OfficialWindowWidgetGuide(displayName: windowName)", join)

    def test_new_window_members_screen_has_one_row(self):
        self.assertIn('static let placeOnHomeScreenAction = "ホーム画面に置く"', SETUP)
        create = section(WINDOW, "struct GroupWindowCreateScreen: View {", "struct GroupWindowStandardsAgreement: View {")
        self.assertIn("offersWidgetPlacement: true", create)
        members = section(SETUP, "struct GroupWindowMembersView: View {", "private func membersSection(")
        self.assertIn("var offersWidgetPlacement = false", members)
        self.assertEqual(members.count('"group-window-place-widget"'), 1)
        self.assertIn("OfficialWindowWidgetGuide(displayName: window.name)", members)

    def test_one_guide_names_the_window(self):
        guide = section(OFFICIAL, "struct OfficialWindowWidgetGuide: View {", "struct OfficialWindowView: View {")
        self.assertIn("windowName: displayName", guide)
        offer = section(WINDOW, "@MainActor static func offerForPlacement(", "/// Chooses a window's home-screen photo again")
        self.assertIn("guard entry(windowID: windowID) == nil else { return }", offer)
        self.assertIn("photoID: nil, jpeg: nil", offer)


class PurchaseContinuesTests(unittest.TestCase):
    def test_prompt_purchase_makes_the_window(self):
        prompt = section(OFFER, "struct PlusOfferPrompt: View {", "struct PlusSettingsSection: View {")
        self.assertIn("if !finishedWithPlus { onDeclined?() } else { onPurchased?() }", prompt)
        create = section(WINDOW, "struct GroupWindowCreateScreen: View {", "struct GroupWindowStandardsAgreement: View {")
        self.assertIn("onPurchased: createAfterPromptPurchase)", create)
        after = section(create, "private func createAfterPromptPurchase() {", "var body: some View {")
        self.assertIn("PlusPurchaseContinuation.createsWindow(", after)
        self.assertIn("create()", after)
        # The making shows on the same button while membership re-reads.
        self.assertIn("!= .allowed, !model.isWorking {", create)
        self.assertIn('WorkingLabel(title: "作る", workingTitle: "作っています…", working: model.isWorking)', create)
        # The relay's own refusal still retries once by itself.
        self.assertIn("guard createsAfterPurchase, !retriedAfterPurchase else { return }", create)

    def test_family_flows_go_on_after_purchase(self):
        self.assertIn("if createsAfterPlus { createsAfterPlus = false; showsName = boughtPlus }", NOTEBOOK)
        self.assertIn("Button { claimsAfterPlus = true; showsPlusOffer = true } label: {", NOTEBOOK)
        claim = section(NOTEBOOK, "private func claimPayerAfterPurchase() async {", "/// Shown while new writing")
        self.assertIn("PlusPurchaseContinuation.claimsFamilyPayer(", claim)
        self.assertIn("sharing.service.claimPayer(operationID: $0)", claim)


class InvitationLifetimeTests(unittest.TestCase):
    def test_both_servers_say_24_hours(self):
        self.assertIn("expiresAt=actor.now+86400", GROUP_SERVER)
        self.assertIn("NEW.recorded_at,NEW.recorded_at+86400,'active' WHERE NEW.operation='invite'", NOTEBOOK_SERVER)
        self.assertIn('static let invitationLifetimeCaption = "24時間使えます。"', SETUP)

    def test_caption_sits_under_each_invite_button(self):
        invite = section(SETUP, "private func invitationSection(_ window: GroupWindow) -> some View {",
                         "private func renewAndShareInvitation() {")
        self.assertEqual(invite.count("GroupWindowPresentation.invitationLifetimeCaption"), 2)
        self.assertLess(invite.index('"group-window-share-invitation"'), invite.index("invitationLifetimeCaption"))
        renew = section(invite, '"group-window-renew-invitation"', '} else if let earlier')
        self.assertLess(renew.index("invitationLifetimeCaption"), renew.index("前に送ったリンクは使えなくなります。"))
        family = section(NOTEBOOK, "struct FamilyNotebookInviteView: View {", "enum FamilyInviteSendTap")
        self.assertLess(family.index('"family-notebook-send-invitation"'), family.index("invitationLifetimeCaption"))


class FamilyInviteOneTapTests(unittest.TestCase):
    def test_one_press_makes_and_shares(self):
        family = section(NOTEBOOK, "struct FamilyNotebookInviteView: View {", "struct FamilyNotebookJoinView: View {")
        self.assertNotIn("ShareLink(", family)
        self.assertEqual(family.count('Label("招待を送る"'), 1)
        send = section(family, "private func send() {", "enum FamilyInviteSendTap")
        self.assertIn("FamilyInviteSendTap.action(isCreating: creating, hasInvitation: hasInvitation)", send)
        self.assertLess(send.index("invitation = made"), send.index("sharesInvitation = true\n            }"))
        self.assertIn("completedUsage: .familyInviteShared", family)
        self.assertIn("message: FamilyNotebookInviteView.inviteMessage(cats: model.catNames)", family)
        self.assertIn("sharing.failure?.message", family)


class EmptyPhotosTests(unittest.TestCase):
    def test_member_without_photos_is_pointed_to_the_window_tab(self):
        empty = section(HOME, "private var emptyPhotoState: some View {", "\n    }\n\n}")
        member = section(empty, "PhotosEmptyStatePolicy.pointsToWindows(", '"photo-hub-empty-window-member"')
        self.assertIn("Text(PhotosEmptyStatePolicy.windowMemberLine)", member)
        self.assertEqual(member.count("Button("), 1)
        # Failure and a chosen cat come first; everyone else keeps the zero state.
        self.assertLess(empty.index("if scan.hasFailed"), empty.index("pointsToWindows"))
        self.assertLess(empty.index("pointsToWindows"), empty.index("OnboardingPresentationCopy.scanZeroBody"))
        self.assertIn('static let windowMemberLine = "まどに届いた写真は、まどのタブで見られます。"', HOME)
        self.assertIn("isWindowMember = !GroupWidgetCache.entries().isEmpty", HOME)
        self.assertIn("openWindows: showsMadoTab ? { selectedTab = .windows } : nil", TABS)


class RegistrationTests(unittest.TestCase):
    def test_native_tests_are_in_the_test_target(self):
        self.assertIn("path = FamilyJourneyTests.swift;", PROJECT)
        self.assertEqual(PROJECT.count("C1FA3A110000000000000001"), 2)
        self.assertEqual(PROJECT.count("C1FA3A110000000000000002"), 3)
        self.assertIn("final class FamilyJourneyTests: XCTestCase", TESTS)
        self.assertIn("python3 ci/test-family-journey.py\n", read("ci/run-quick-ios-checks.sh"))


if __name__ == "__main__":
    unittest.main()
