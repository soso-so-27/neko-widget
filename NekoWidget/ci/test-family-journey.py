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
A5. One press on the family notebook's 「招待リンクを送る」 makes the link and opens
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
        self.assertEqual(family.count('Label("招待リンクを送る"'), 1)
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


STORE = read("NekoWidget/Services/PlusPurchaseStore.swift")
POLICY = read("NekoWidget/Services/SharingAutoCheckPolicy.swift")
OFFER_VIEW = read("NekoWidget/Views/MembershipOfferView.swift")
SHARING = read("NekoWidget/Services/FamilyNotebookSharing.swift")
ACCESS = read("NekoWidget/Services/MembershipAccessContext.swift")


class PurchaseWaitAndFamilyPause1115Tests(unittest.TestCase):
    """11/15 (TestFlight 378): bought from the family notebook, the screen
    waited until 「購入を復元」 by hand, the button was below the fold, and
    「Plusを確認できました。」 stood under 「共有が止まっています」."""

    def test_server_confirmation_is_asked_again_by_itself(self):
        purchase = section(STORE, "    func purchase(\n", "    /// 11/15 (TestFlight 378)")
        self.assertEqual(purchase.count("recheckServerConfirmationAfterPurchase()"), 2)
        recheck = section(STORE, "private func recheckServerConfirmationAfterPurchase() {", "    /// AppStore.sync")
        # Bounded, and only the server's answer can grant: the same re-check
        # as 「購入を復元」, never a purchase, AppStore.sync or a local grant.
        self.assertIn("let delay = delays.isEmpty ? Self.serverConfirmationFollowUpInterval : delays.removeFirst()", recheck)
        self.assertIn("await store.refreshAfterForegroundEntry()", recheck)
        self.assertIn("guard !store.isPurchasing, !store.isRestoring,\n"
                      "                          store.allowsAutomaticBillingCheck() else { continue }", recheck)
        for forbidden in ("AppStore.sync", "product.purchase", "entitlementState =", "canStartNewPurchase = true",
                          "repeat {", "grantsPlus = true"):
            self.assertNotIn(forbidden, recheck)
        self.assertIn("store.awaitingServerConfirmation = true", recheck)
        self.assertIn("serverConfirmationRecheckTask?.cancel()", section(STORE, "    func stop() {", "\n    }\n"))
        # 11/15 (second fix): then every 30 s until 10 minutes after the
        # purchase, only in front, wherever the person is; one loop at a time.
        self.assertIn("static let serverConfirmationFollowUpInterval = PlusConfirmationSchedule.followUpInterval", STORE)
        self.assertIn("static let serverConfirmationWindow = PlusConfirmationSchedule.window", STORE)
        self.assertIn("static let followUpInterval: Duration = .seconds(30)", POLICY)
        self.assertIn("static let window: TimeInterval = 10 * 60", POLICY)
        self.assertIn("serverConfirmationDeadline = Date().addingTimeInterval(Self.serverConfirmationWindow)", recheck)
        self.assertIn("guard let deadline = store.serverConfirmationDeadline, Date() < deadline,", recheck)
        self.assertIn("guard store.isInFront else { store.serverConfirmationRecheckTask = nil; return }", recheck)
        self.assertIn("UIApplication.shared.applicationState == .active", recheck)
        loop = section(STORE, "private func runServerConfirmationRechecks(first: [Duration]) {", "private func finishServerConfirmationRechecks()")
        self.assertLess(loop.index("serverConfirmationRecheckTask?.cancel()"), loop.index("serverConfirmationRecheckTask = Task"))
        resume = section(STORE, "func resumeServerConfirmationRechecksIfDue() {", "\n    }\n")
        self.assertIn("guard serverConfirmationRecheckTask == nil, let deadline = serverConfirmationDeadline,", resume)
        self.assertEqual(STORE.count("serverConfirmationRecheckTask = Task"), 1)
        app = read("NekoWidget/App/NekoWidgetApp.swift")
        active = section(app, "guard newPhase == .active else { return }", "membershipNow = .now")
        self.assertLess(active.index("await plusPurchases.refreshOnForegroundEntry()"),
                        active.index("plusPurchases.resumeServerConfirmationRechecksIfDue()"))
        # Confirmed later: the family's paused box is read again by itself.
        check = section(NOTEBOOK, "private struct FamilyNotebookOpeningCheck: ViewModifier {", "extension View {")
        self.assertIn(".onChange(of: purchases.entitlementState.permitsPersonalPlus) { _, plus in", check)
        self.assertIn("refreshAfterPlusChange(reportsFailure: false)", check)

    def test_waiting_sheet_goes_on_once_plus_is_confirmed(self):
        sheet = section(OFFER, "struct MembershipOfferSheet: View {", "enum PlusPurchaseContinuation {")
        self.assertIn("awaitsConfirmation = result == .waiting && !model.isMember", sheet)
        change = section(sheet, ".onChange(of: model.isMember) { _, member in", "private var offerScreen: some View {")
        self.assertIn("guard member, awaitsConfirmation, !showsStarted else { return }", change)
        self.assertIn("completePurchase()", change)
        # A restore finishes the sheet itself, so it is not finished twice.
        restore = section(sheet, "onRestore: {", "onClose:")
        self.assertLess(restore.index("awaitsConfirmation = false"), restore.index("await model.restore()"))
        # Membership still comes only from the store's server-confirmed state.
        self.assertIn("isMember = purchases.entitlementState.permitsPersonalPlus", OFFER)

    def test_restore_stands_under_the_line_that_asks_for_it(self):
        self.assertIn('var asksForRestore: Bool { !isMember && (message?.contains("「購入を復元」") ?? false) }', OFFER)
        self.assertIn("restoreNearMessage: model.asksForRestore", OFFER)
        actions = section(OFFER_VIEW, "    private var actions: some View {", "    private var reassurance: some View {")
        self.assertLess(actions.index('"membership-offer-message"'), actions.index("if restoreNearMessage {"))
        self.assertLess(actions.index("if restoreNearMessage {"), actions.index('"membership-offer-manage"'))
        footer = section(OFFER_VIEW, "@ViewBuilder private var footerLinkContent: some View {", "\n    }\n")
        self.assertIn("if !restoreNearMessage { restoreButton }", footer)
        # One 「購入を復元」 on the screen, the sheet's own (it finishes the sheet).
        self.assertEqual(OFFER_VIEW.count("restoreButton\n"), 1)
        self.assertEqual(OFFER_VIEW.count("if !restoreNearMessage { restoreButton }"), 1)
        self.assertNotIn("MembershipRestoreButton(", OFFER_VIEW)

    def test_family_is_read_again_after_plus_and_never_says_found_while_stopped(self):
        after = section(SHARING, "func refreshAfterPlusChange(reportsFailure: Bool = true) async -> Bool {", "\n    }\n")
        self.assertIn("while refreshing {", after)
        self.assertIn("return await refresh(reportsFailure: reportsFailure)", after)
        self.assertIn("guard !refreshing else { return false }", SHARING)
        dismiss = section(NOTEBOOK, ".sheet(isPresented: $showsPlusOffer, onDismiss: {", "MembershipOfferSheet(model: .live()")
        self.assertIn("if bought { await sharing.refreshAfterPlusChange() } else { await sharing.refresh() }", dismiss)
        paused = section(NOTEBOOK, "private func pausedSection(_ pause: FamilySharingPause) -> some View {", "} footer: {")
        self.assertEqual(paused.count("showsFound: false"), 2)
        self.assertEqual(paused.count("Task { await recheckFamilyAfterPlus() }"), 2)
        self.assertEqual(paused.count("familyAwaitsPlusLine"), 2)
        # The check and its line are one row, so rows do not come and go mid-check.
        self.assertEqual(paused.count(
            "VStack(alignment: .leading, spacing: 8) {\n                        MembershipRestoreButton("), 2)
        self.assertNotIn("Plusを確認できました", NOTEBOOK)
        recheck = section(NOTEBOOK, "private func recheckFamilyAfterPlus() async {", "@ViewBuilder private var familyAwaitsPlusLine")
        self.assertIn("guard await sharing.refreshAfterPlusChange() else { return }", recheck)
        self.assertIn("PlusPurchaseContinuation.familyStillAwaitsPlus(", recheck)
        self.assertIn('static let familyAwaitsPlus = "家族の手帳には、まだPlusが届いていません。少しおいて、もう一度確かめてください。"',
                      NOTEBOOK)
        button = section(ACCESS, "struct MembershipRestoreButton: View {", "private func restore() {")
        self.assertIn("if showsFound {", button)
        self.assertIn("showsFound: Bool = true", button)
        self.assertIn("testFamilySaysItHasNotSeenThePlusOnlyWhileItStillStops", TESTS)
        self.assertIn("testRestoreStandsUnderTheLineThatAsksForIt", TESTS)
        self.assertIn("testServerConfirmationIsAskedAgainAFewTimesWithinTwoMinutes", TESTS)


SETTINGS = read("NekoWidget/Views/SettingsView.swift")


class FamilyJoinAfterApproval1115Tests(unittest.TestCase):
    """11/15 (TestFlight 378, two iPhones): the approved person stayed in
    「参加を待っている人」, the person let in never saw the notebook, the
    invite link took long, requests showed late, and the name field read as
    the notebook's name."""

    def test_answered_request_leaves_the_list(self):
        refresh = section(SHARING, "func refresh(reportsFailure: Bool = false) async -> Bool {", "func refreshAfterPlusChange(")
        self.assertIn("let nextRequests = next.membership == nil ? [] : try await real.pendingRequests()", refresh)
        self.assertNotIn("syncing ? requests", refresh)
        decide = section(NOTEBOOK, "private func decide(_ request: FamilyNotebookJoinRequest, approve: Bool) {", "\n    }\n")
        self.assertIn("sharing.forgetRequest(request.id)", decide)
        # A second press on a stale row finds it gone; it never approves twice.
        service = read("NekoWidget/Services/ProductionFamilyNotebookSharingService.swift")
        again = section(service, "func decide(requestID: UUID, approve: Bool, operationID: UUID) async throws {", "struct FamilyNotebookJoinRequest")
        self.assertIn("guard let request = result.requests.first(where: { $0.requestID == requestID }) else { throw FamilySharingError.staleRoster }", again)
        perform = section(SHARING, "func perform(readsAfter: Bool = true", "func forgetRequest(")
        self.assertIn("if readsAfter { await refreshAfterChange() }", perform)
        self.assertIn("while refreshing {", section(SHARING, "private func refreshAfterChange() async {", "\n    }\n"))

    def test_person_let_in_learns_it_when_the_app_opens(self):
        self.assertIn('static let key = "familyNotebookAwaitingApproval"', SHARING)
        refresh = section(SHARING, "func refresh(reportsFailure: Bool = false) async -> Bool {", "func refreshAfterPlusChange(")
        self.assertIn("case .pendingApproval, .waitingForKeys: Self.noteAwaitingApproval(true)", refresh)
        self.assertIn("case .notInFamily, .inFamily: Self.noteAwaitingApproval(false)", refresh)
        check = section(NOTEBOOK, "private struct FamilyNotebookOpeningCheck: ViewModifier {", "extension View {")
        # 1115q: coming to the front only tells the one schedule.
        self.assertIn("FamilyNotebookAutoCheck.shared.setActive(active)", check)
        auto = section(SHARING, "final class FamilyNotebookAutoCheck {", "/// 11/15: this iPhone asked to join")
        self.assertIn("FamilyAutoCheckPolicy.eligible(.init(real: model.isReal, hasFamily: model.hasFamily,", auto)
        self.assertIn("awaitingApproval: FamilyNotebookSharing.awaitingApproval,", auto)
        self.assertIn("e.real && (e.hasFamily || e.awaitingApproval || e.awaitingApprovalUnknown", POLICY)
        # An app from before 11/15 left no mark: one read settles it.
        self.assertIn("awaitingApprovalUnknown: FamilyNotebookSharing.awaitingApprovalUnknown,", auto)
        # 11/20: a launch that read nothing yet reads once when this iPhone has an identity.
        self.assertIn("|| (e.unreadThisLaunch && e.hasIdentity)) || e.resumeProbeDue", POLICY)
        self.assertIn("unreadThisLaunch: unreadThisLaunch, hasIdentity: hasNotebookIdentity == true,", auto)
        self.assertIn("hasNotebookIdentity = await real.hasLocalIdentity()", auto)
        self.assertIn("UserDefaults.standard.object(forKey: FamilyNotebookAwaitingApproval.key) == nil", SHARING)
        self.assertIn("await sharing.refresh()", auto)
        self.assertIn("model.applyFamilyWrites()", auto)
        # Key passes go on while they move, waiting goes on every 30 s.
        self.assertIn("keysMove: real?.needsAnotherPass == true", auto)
        self.assertIn("static let keyBackoff: [TimeInterval] = [5, 10, 20, 40, 60]", POLICY)
        self.assertIn("static let awaitingInterval: TimeInterval = 30", POLICY)
        # Two synthetic iPhones: approval before the newcomer registers still ends readable.
        delivery = read("ci/verify-family-notebook-key-delivery.swift")
        self.assertIn("try await approvedBeforeNewcomerRegisters(directory: directory, endpoint: endpoint)", delivery)
        late = section(delivery, "private static func approvedBeforeNewcomerRegisters(", "\n    }\n}")
        order = ["confirmApprovedAddition", "_ = try await opens(a)", "let waiting = try await opens(b)",
                 "_ = try await opens(a)\n        let bDevice", "guard let joined = try await opens(b), joined.ready"]
        self.assertEqual(sorted(order, key=late.index), order)
        self.assertIn("ci/verify-family-notebook-key-delivery.swift", read("ci/run-quick-ios-checks.sh"))
        # Nothing about Photos decides it.
        for photos in ("PHPhotoLibrary", "authorizationStatus", "PhotoAuthorization"):
            self.assertNotIn(photos, check)
        self.assertIn(".familyNotebookOpeningCheck()", ROOT_VIEW)
        # 設定 keeps the one way to the notebook while waiting.
        self.assertIn("@AppStorage(FamilyNotebookAwaitingApproval.key) private var awaitsFamilyApproval = false", SETTINGS)
        self.assertIn("private var showsFamilyNotebookRow: Bool { familyNotebook.hasFamily || awaitsFamilyApproval || awaitsRecoveredNotebook }", SETTINGS)
        # 11/19 (UI/UX 整理): the row says the wait it is in, in the notebook's words.
        self.assertNotIn("参加を待っています", SETTINGS)
        self.assertIn("? FamilyNotebookWords.receiving : FamilyNotebookWords.awaitingApproval)", SETTINGS)

    def test_invite_link_opens_without_the_whole_family_read(self):
        family = section(NOTEBOOK, "struct FamilyNotebookInviteView: View {", "enum FamilyInviteSendTap")
        self.assertIn("await sharing.perform(readsAfter: false) { made = try await service.createInvitation(operationID: $0) }", family)
        self.assertEqual(NOTEBOOK.count("readsAfter: false"), 1)
        self.assertIn("if creating { ProgressView() }", family)

    def test_requests_are_read_every_20_seconds_while_open(self):
        # 1115q: the list only, every 20 s; the whole family every 60 s.
        self.assertIn("static let requestsInterval: TimeInterval = 20", POLICY)
        self.assertIn("static let notebookFullInterval: TimeInterval = 60", POLICY)
        auto = section(SHARING, "final class FamilyNotebookAutoCheck {", "/// 11/15: this iPhone asked to join")
        self.assertIn("case .requestsOnly:\n                    await sharing.refreshRequests()", auto)
        self.assertNotIn("Task.sleep(for: .seconds(pending ? 5 : 20))", NOTEBOOK)
        self.assertIn(".refreshable { if !sharing.isWorking { await sharing.refresh(reportsFailure: true) } }", NOTEBOOK)

    def test_join_name_field_says_whose_name(self):
        join = section(NOTEBOOK, "struct FamilyNotebookJoinView: View {", "struct FamilyNotebookNameView: View {")
        field = section(join, 'Text("あなたの名前")', '.accessibilityIdentifier("family-notebook-display-name")')
        self.assertIn("TextField(", field)
        self.assertLess(join.index('"family-notebook-display-name"'), join.index('Text("家族に表示されます。")'))
        self.assertIn('Text("あなたの名前")', section(SETUP, "private var applySection: some View {", "\n    }\n"))


TRANSPORT = read("NekoWidget/Services/GroupWindowTransport.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")
KEYS = read("NekoWidget/Services/FamilyNotebookKeyCoordinator.swift")
DELIVERY = read("ci/verify-family-notebook-key-delivery.swift")


class CallBudget1115qTests(unittest.TestCase):
    """1115q: automatic checks could pass the relay's limits (120 a minute per
    address for the まど and the notebook, 10 for billing). One schedule,
    backoff while keys do not move, a per-iPhone budget, 429 pauses."""

    def test_transport_budget_is_30_a_minute_for_automatic_calls_only(self):
        send = section(TRANSPORT, "func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {", "enum GroupHTTPRequest")
        # 1115s: every request passes the gate before the network.
        self.assertLess(send.index("return try await SharingAutoCallBudget.gated { replied in"), send.index("session.bytes(for: request)"))
        self.assertIn('replied(http.statusCode, http.value(forHTTPHeaderField: "Retry-After"))', send)
        self.assertIn("static let perMinute = 30", TRANSPORT)
        self.assertIn("static let devicePerMinute = 59", TRANSPORT)
        self.assertIn("static let rateLimitedPause: TimeInterval = 60", TRANSPORT)
        self.assertIn("max(Self.rateLimitedPause, retryAfter ?? 0)", TRANSPORT)
        self.assertIn('formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"', TRANSPORT)

    def test_one_schedule_for_the_notebook(self):
        # No loop of its own in the notebook, the tool or the opening check.
        notebook = section(NOTEBOOK, "struct FamilyNotebookView: View {", "extension FamilyNotebookView {")
        self.assertNotIn("Task.sleep", notebook)
        tool = section(NOTEBOOK, "private struct FamilyNotebookToolSyncModifier: ViewModifier {", "private struct FamilyNotebookOpeningCheck")
        self.assertNotIn("Task.sleep", tool)
        self.assertIn("FamilyNotebookAutoCheck.shared.appeared(.tool)", tool)
        self.assertNotIn("Task.sleep", section(NOTEBOOK, "private struct FamilyNotebookOpeningCheck: ViewModifier {", "extension View {"))
        self.assertIn("FamilyNotebookAutoCheck.shared.appeared(.notebook)", notebook)
        auto = section(SHARING, "final class FamilyNotebookAutoCheck {", "/// 11/15: this iPhone asked to join")
        self.assertEqual(auto.count("loop = Task"), 1)
        self.assertIn("if loop != nil && !sleeping { return }", auto)
        # 1115s: the schedule's calls carry no mark: automatic by default.
        # 1115v: automatic even when an operation's nudge started it.
        self.assertNotIn("SharingPersonAction.run", auto)
        self.assertIn("loop = Task { [weak self] in await SharingPersonAction.automatic {", auto)
        self.assertIn("FamilyAutoCheckPolicy.next(situation(now: Date()))", auto)
        self.assertIn("SharingAutoCallBudget.shared.pausedUntil()", auto)
        # The まど's waiting lists are automatic too.
        setup = read("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn("if !presentsSheet { await model.load(reportsFailure: false) }", setup)

    def test_backoff_and_waiting_on_others(self):
        nxt = section(POLICY, "static func next(_ s: Situation) -> Decision? {", "\n    }\n}")
        self.assertIn("if delay >= waitsOnOthers && !screen { return nil }", nxt)
        self.assertIn("static let wakeGap: TimeInterval = 20", POLICY)
        self.assertIn("static let nudgeGap: TimeInterval = 5", POLICY)
        self.assertIn("static let toolFullInterval: TimeInterval = 30", POLICY)
        # Key reads per pass: newest first, two at most.
        self.assertIn("static let keyReadsPerPass = 2", KEYS)
        self.assertIn("guard keyRequests < Self.keyReadsPerPass else { continue }", KEYS)
        self.assertIn("private(set) var observation", KEYS)

    def test_purchase_wait_fits_the_billing_limit(self):
        self.assertIn("static let firstMinuteDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(25)]", POLICY)
        self.assertIn("static let automaticCeiling = BillingCallBudget.automaticPerMinute", POLICY)
        loop = section(STORE, "private func runServerConfirmationRechecks(first: [Duration]) {", "private func finishServerConfirmationRechecks()")
        self.assertIn("store.allowsAutomaticBillingCheck() else { continue }", loop)
        self.assertEqual(STORE.count("noteBillingFailure(error)"), 2)
        self.assertIn("await plusPurchases.refreshOnForegroundEntry()", read("NekoWidget/App/NekoWidgetApp.swift"))

    def test_counted_on_a_synthetic_clock(self):
        for name in ("keysNeverArrive()", "notebookOpenAndReopened()", "awaitingApproval()", "purchaseWaits()",
                     "approvalToReading(directory: directory, endpoint: endpoint)"):
            self.assertIn(name, section(DELIVERY, "static func run(directory: URL, endpoint: URL) async throws {", "\n    }\n"))
        self.assertIn("try await CallBudgetChecks.run(directory: directory, endpoint: endpoint)", DELIVERY)
        self.assertIn("try check(bReadsAt! <= 30,", DELIVERY)
        self.assertIn("try check(after.0 <= 6 && after.1 <= 6,", DELIVERY)
        self.assertIn("NekoWidget/Services/SharingAutoCheckPolicy.swift", read("ci/run-quick-ios-checks.sh"))


APP_ROOT = read("NekoWidget/App/AppRootView.swift")
BACKGROUND = read("NekoWidget/Services/MomentBackgroundRefreshService.swift")
CLIENT = read("NekoWidget/Services/ProductionGroupWindowClient.swift")
WINDOW_VIEW = read("NekoWidget/Views/GroupWindowView.swift")
REPORTING = read("NekoWidget/Services/GroupReporting.swift")
SHARE = read("NekoWidgetShareExtension/GroupShareService.swift")


class DefaultAutomatic1115sTests(unittest.TestCase):
    """1115s: calls nobody marked passed the budget. Now every call is
    automatic unless the person's own action marks it."""

    def test_default_is_automatic(self):
        self.assertIn("@TaskLocal static var isPersonAction = false", TRANSPORT)
        self.assertNotIn("isAutomatic", TRANSPORT)
        admit = section(TRANSPORT, "    func admit(personAction: Bool, at now: Date = Date()) throws {", "\n    }\n")
        self.assertLess(admit.index("if personAction {"), admit.index("if let pausedUntil, now < pausedUntil"))
        self.assertIn("guard automatic.count(at: now) < automatic.limit, all.count(at: now) < all.limit else {", admit)
        self.assertIn("try budget.admit(personAction: isPersonAction, at: now)", TRANSPORT)
        # Only SharingPersonAction sets the mark.
        import glob
        sources = glob.glob(str(ROOT / "NekoWidget" / "**" / "*.swift"), recursive=True) + glob.glob(str(ROOT / "NekoWidgetShareExtension" / "*.swift"))
        setters = [path for path in sources if "$isPersonAction.withValue" in open(path, encoding="utf-8").read()]
        self.assertEqual([path.replace(chr(92), "/").split("/NekoWidget/", 1)[-1] for path in setters], ["NekoWidget/Services/GroupWindowTransport.swift"])
        # The one network transport; every relay client builds it.
        self.assertEqual(TRANSPORT.count("URLSession(configuration:"), 1)
        for path in ("NekoWidget/Services/FamilyNotebookServiceFactory.swift", "NekoWidget/Services/GroupReportingProvider.swift",
                     "NekoWidget/Services/ProductionGroupWindowClient.swift", "NekoWidgetShareExtension/GroupShareService.swift"):
            self.assertIn("GroupURLSessionTransport()", read(path), path)

    def test_automatic_ways_in_stay_unmarked_and_keep_a_20_second_gap(self):
        self.assertIn("static let seconds: TimeInterval = 20", TRANSPORT)
        for name, text in (("AppRootView", APP_ROOT), ("background refresh", section(BACKGROUND, "final class GroupAdmissionService", "func receive(")),
                           ("anchor receipts", section(CLIENT, "func backfillAnchorReceipts() async {", "\n    }\n"))):
            self.assertNotIn("SharingPersonAction", text, name)
        refresh = section(BACKGROUND, "func refresh(requestPermission: Bool = false, force: Bool = false) async {", "\n    }\n")
        self.assertIn("guard requestPermission || force || SharingForegroundGap.allows(since: lastRefreshAt) else { return }", refresh)
        self.assertIn("SharingForegroundGap.allows(since: lastAnchorBackfillAt)", CLIENT)
        self.assertIn("let windows = try await recentOrFreshWindows()", CLIENT)
        foreground = section(WINDOW_VIEW, ".onChange(of: scenePhase) { _, phase in", ".onReceive(")
        self.assertIn("SharingForegroundGap.allows(since: lastForegroundLoad)", foreground)
        self.assertNotIn("SharingPersonAction", foreground)
        # A notification tap opens the window with the person's one read.
        self.assertIn("SharingPersonAction.run({ try await client.window(id: route.windowID) })", BACKGROUND)

    def test_the_persons_own_ways_in_are_marked(self):
        marked = {
            "family operations": section(SHARING, "func perform(readsAfter: Bool = true", "private func refreshAfterChange()"),
            "family asked read": section(SHARING, "func refresh(reportsFailure: Bool = false) async -> Bool {", "private func read(reportsFailure: Bool)"),
            "invitation link": section(NOTEBOOK, "struct FamilyNotebookJoinView: View {", "struct FamilyNotebookNameView: View {"),
            "farewell preview": section(NOTEBOOK, "private func loadPreview() async {", "private func consent("),
            "farewell consent": section(NOTEBOOK, "private func consent(_ preview: FamilyFarewellPreview) async {", "private func revoke()"),
            "farewell revoke": section(NOTEBOOK, "    private func revoke() async {", "\n    }\n"),
            "まど open/pull": section(WINDOW_VIEW, "    func sync() async {", "\n"),
            "deliver": section(WINDOW_VIEW, "    func deliver(_ prepared: PreparedPhoto, memo: String) async {", "\n    }\n"),
            "retry delivery": section(WINDOW_VIEW, "    func retryFailedDelivery() async {", "\n    }\n"),
            "favorites": section(WINDOW_VIEW, "    func addToFavorites(", "\n    }\n"),
            "remove": section(WINDOW_VIEW, "    func remove(_ entry: GroupWindowLocalPhotoStore.Entry) async {", "\n    }\n"),
            "block sender": section(WINDOW_VIEW, "    func blockSender(of entry", "\n    }\n"),
            "forget": section(WINDOW_VIEW, "    func forgetFormerWindow() async {", "\n    }\n"),
            "photo window read": section(WINDOW_VIEW, "    func loadWindow() async {", "\n    }\n"),
            "heart": section(WINDOW_VIEW, "    func toggleHeart(_ photoID: String) async {", "\n    }\n"),
            "create まど": section(WINDOW_VIEW, "    func create(name: String, ownerName: String) async -> GroupWindow? {", "\n    }\n"),
            "report and block": section(REPORTING, "func run<Value>(windowID: String", "\n    }\n"),
            "members actions": section(SETUP, "    private func perform(", "\n    }\n"),
            "members read": section(SETUP, "    func load(reportsFailure: Bool = true) async {", "private func read(reportsFailure: Bool)"),
            "join apply": section(SETUP, "    func apply() async {", "\n    }\n"),
            "join resume": section(SETUP, "    func resume() async {", "\n    }\n"),
            "join cancel": section(SETUP, "    func cancel() async {", "\n    }\n"),
            "join pull": section(SETUP, "    func refresh(reportsFailure: Bool = false) async {", "private func check(reportsFailure: Bool)"),
            "share sheet": SHARE,
        }
        for name, text in marked.items():
            self.assertIn("SharingPersonAction.run", text, name)
        self.assertEqual(WINDOW_VIEW.count("await SharingPersonAction.run { await model.load() }"), 3)
        self.assertIn(".refreshable { await SharingPersonAction.run { await safety.refresh(windowID: windowID) } }", WINDOW_VIEW)

    def test_counted_at_the_real_gate(self):
        for name in ("unmarkedEntrancesAreHeld()", "foregroundEvery5Seconds()", "twoIPhonesOnOneAddress()"):
            self.assertIn(name, DELIVERY)
        self.assertIn("try await SharingAutoCallBudget.gated(meter.budget, at: { meter.clock.date })", DELIVERY)
        self.assertIn('"a call added later that nobody marked"', DELIVERY)
        self.assertIn("try check(afterBudget == 0,", DELIVERY)
        self.assertIn("try check(afterRateLimit == 0,", DELIVERY)
        self.assertIn("try check(together < 120,", DELIVERY)


APP = read("NekoWidget/App/NekoWidgetApp.swift")


class BillingGateAndReplyTime1115vTests(unittest.TestCase):
    """1115v: the 429 pause counted from the send, and billing calls that did
    not pass the purchase-wait schedule."""

    def test_pause_counts_from_the_reply(self):
        gated = section(TRANSPORT, "static func gated(", "\n    }\n")
        self.assertNotIn("let replyTime", gated)
        self.assertIn("noteReply(status: status, retryAfter: retryAfter, budget, at: now())", gated)
        self.assertIn("pauseCountsFromTheReply()", DELIVERY)
        self.assertIn("clock.seconds += 10          // the reply takes 10 s", DELIVERY)

    def test_one_billing_gate_at_the_send(self):
        self.assertIn("static let automaticPerMinute = 4", POLICY)
        self.assertIn("static let devicePerMinute = 8", POLICY)
        authority = section(STORE, "    private func refreshServerAuthority() async -> ServerAuthorityRefresh {", "            let response = try await fetchAuthoritativeEntitlement()")
        self.assertIn("guard billingBudget.admit(.entitlement, personAction: SharingAutoCallBudget.isPersonAction) else {", authority)
        record = section(STORE, "    private func recordVerifiedTransactionEvent(", "            acknowledgement = try await recordVerifiedTransactionEvent(event, billingAccountID)")
        self.assertIn("guard billingBudget.admit(.transaction, personAction: SharingAutoCallBudget.isPersonAction) else {\n            throw BillingCallDeferred()", record)
        # The only two places that reach the billing relay.
        self.assertEqual(STORE.count("try await fetchAuthoritativeEntitlement()"), 1)
        self.assertEqual(STORE.count("try await recordVerifiedTransactionEvent(event, billingAccountID)"), 1)

    def test_held_back_events_are_kept_and_never_finished(self):
        update = section(STORE, "    private func handleTransactionUpdate(", "    private func reconcileCurrentEntitlements()")
        held = section(update, "} catch is BillingCallDeferred {", "} catch {")
        self.assertIn("deferredUpdates.append(result)", held)
        self.assertIn("markServerConfirmationIndeterminate()", held)
        self.assertIn("scheduleDeferredBillingWork()", held)
        self.assertNotIn("finish()", held)
        self.assertLess(update.index("try await recordVerifiedTransactionEvent("), update.index("await transaction.finish()"))
        work = section(STORE, "private func scheduleDeferredBillingWork() {", "/// The one retry of a held authority read")
        self.assertIn("for update in updates { await store.handleTransactionUpdate(update) }", work)
        self.assertIn("store.retriesDeferredAuthorityRead = false", work)
        self.assertNotIn("grantsPlus = true", work)

    def test_long_lived_loops_are_automatic_and_taps_are_marked(self):
        for name in ("authorityExpiryTask", "deferredBillingTask", "serverConfirmationRecheckTask",
                     "storefrontUpdatesTask", "transactionUpdatesTask"):
            task = section(STORE, name + " = Task { @MainActor [weak self] in", "await SharingPersonAction.automatic {")
            self.assertLess(len(task), 160, name)  # the next lines of that Task
        model = read("NekoWidget/Services/MembershipOfferModel.swift")
        for signature in ("    func load() async {", "    func purchase() async -> MembershipOfferActionResult {",
                          "    func restore() async -> MembershipOfferActionResult {", "    func refresh() async {",
                          "    func refreshAfterSubscriptionManagement() async {"):
            body = section(model, signature, "\n    }\n")
            self.assertIn("SharingPersonAction.run", body, signature)
        handler = section(APP, ".onReceive(NotificationCenter.default.publisher(for: .membershipAccessRefreshRequested))", "membershipNow = .now")
        self.assertIn("await SharingPersonAction.run { await plusPurchases.refreshAfterForegroundEntry() }", handler)
        # Who may post it: only places right after the person's own step.
        import glob
        posters = sorted(path.replace(chr(92), "/").split("/NekoWidget/NekoWidget/", 1)[-1]
                         for path in glob.glob(str(ROOT / "NekoWidget" / "**" / "*.swift"), recursive=True)
                         if "post(name: .membershipAccessRefreshRequested" in open(path, encoding="utf-8").read())
        self.assertEqual(posters, ["Services/AppRecordPersistence.swift", "Services/MembershipAccessContext.swift",
                                   "Services/MembershipOfferModel.swift", "Views/FamilyNotebookView.swift",
                                   "Views/GroupWindowView.swift", "Views/MainTabView.swift",
                                   "Views/ManagedPreservationView.swift", "Views/OnboardingView.swift"])
        self.assertIn("SharingAutoCallBudget.$isPersonAction.withValue(false, operation: work)", TRANSPORT)

    def test_counted(self):
        self.assertIn("billingGate()", DELIVERY)
        self.assertIn('try check(afterRateLimit == 0, "billing:', DELIVERY)
        self.assertIn("testBillingGateHoldsAutomaticReadsAfter429ButNotTheTap", TESTS)


class RegistrationTests(unittest.TestCase):
    def test_native_tests_are_in_the_test_target(self):
        self.assertIn("path = FamilyJourneyTests.swift;", PROJECT)
        self.assertEqual(PROJECT.count("C1FA3A110000000000000001"), 2)
        self.assertEqual(PROJECT.count("C1FA3A110000000000000002"), 3)
        self.assertIn("final class FamilyJourneyTests: XCTestCase", TESTS)
        self.assertIn("python3 ci/test-family-journey.py\n", read("ci/run-quick-ios-checks.sh"))


    def test_one_family_null_does_not_end_the_notebook(self):
        # 11/18 (TestFlight 389): a bare `family: null` is not proof of leaving.
        service = read("NekoWidget/Services/ProductionFamilyNotebookSharingService.swift")
        load = section(service, "func loadState() async throws -> FamilySharingState {", "func loadPause()")
        self.assertIn("guard try context.observedOutsideFamily(now: now()) else { throw FamilySharingError.serviceUnavailable }", load)
        self.assertNotIn("confirmedOutsideFamily", service)
        self.assertIn("static let absenceConfirmationGap: TimeInterval = 60 * 60", service)
        # Reopening needs the verified roster of this same admission.
        self.assertIn("try context.resume(family: family.familyID, admittedGeneration: own.admittedGeneration, roster: material.current)", load)
        self.assertLess(load.index("try context.resume("), load.index("let store = try context.activate("))
        # Photo deliveries waiting before the end start again only from the
        # person's 「もう一度」, never by themselves after reopening.
        self.assertIn("photoRetries = [:]", load)
        self.assertNotIn("pendingDeliveries", load)
        self.assertNotIn("retryRepresentativePhoto", load)
        # Ended without proof: the one schedule still asks, at most hourly.
        auto = section(SHARING, "final class FamilyNotebookAutoCheck {", "/// 11/15: this iPhone asked to join")
        self.assertIn("resumeProbeDue: resumeProbeDue))", auto)
        self.assertIn(") || e.resumeProbeDue", POLICY)
        self.assertIn("static let resumeProbeGap: TimeInterval = 60 * 60", POLICY)
        # Own leaving and ending record a final reason.
        membership = read("NekoWidget/Services/FamilyNotebookMembershipClient.swift")
        self.assertEqual(membership.count("endSharing(reason: action == .dissolve ? .dissolved : .left)"), 1)
        self.assertEqual(membership.count("endSharing(reason: saved.intent.action == .dissolve ? .dissolved : .left)"), 1)


class FamilyPhotoReadOnNewAsset1119Tests(unittest.TestCase):
    """11/19: a photo delivered while the page was open is read at once."""

    def test_minute_is_per_photo_and_calls_while_reading_wait(self):
        care = read("NekoWidget/Views/CatCareView.swift")
        model = section(care, "final class FamilyRepresentativePhotos: ObservableObject {", "private func apply(")
        self.assertIn("func referencedAsset(of cat: UUID) -> UUID?", care)
        self.assertIn("private var readAt: [UUID: (asset: UUID, at: Date)] = [:]", model)
        # No reference: no minute used up; a new photo: at once; the same: a minute.
        self.assertIn("guard let asset = backend.referencedAsset(of: cat) else { due.append(cat); continue }", model)
        self.assertIn("if !force, let last = readAt[cat], last.asset == asset,", model)
        self.assertIn("now.timeIntervalSince(last.at) < Self.automaticGap { continue }", model)
        self.assertIn("static let automaticGap: TimeInterval = 60", model)
        self.assertNotIn("!reading else { return }", model)
        self.assertIn("next = queued; queued = nil", model)
        # 11/19 (TestFlight 392): the read is owned here, not by the page's
        # task, and only a photo that reached the screen counts as read.
        self.assertIn("let task = Task { @MainActor in await self.readAll(cats, force: force) }", model)
        self.assertIn("if let running = readTask {", model)
        self.assertNotIn("reading = true", model)
        once = model.split("private func readOnce(", 1)[1]
        self.assertLess(once.index("apply(load, to: cat)"), once.index("readAt[cat] = (asset: asset, at: now)"))
        self.assertEqual(once.count("readAt[cat] = "), 1)
        # Every backend answers from this iPhone's copy.
        factory = read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        self.assertEqual(factory.count("func referencedAsset(of cat: UUID) -> UUID?"), 2)
        service = read("NekoWidget/Services/ProductionFamilyNotebookSharingService.swift")
        asset = section(service, "func representativePhotoAsset(familyCatID: UUID) -> UUID? {", "func representativePhotos(")
        self.assertNotIn("await", asset)
        self.assertIn("?.reference.assetID", asset)


class FamilyPhotoCreatorAuto1119Tests(unittest.TestCase):
    """11/19: the notebook creator's key photo goes to the family by itself."""

    def setUp(self):
        self.care = read("NekoWidget/Views/CatCareView.swift")
        self.model = section(self.care, "final class FamilyRepresentativePhotos: ObservableObject {",
                             "/// A question about the family's photo")

    def test_no_delivery_screens_or_words_remain(self):
        for gone in ("FamilyPhotoDeliveryStatus", "FamilyPhotoDeliverSheet", "deliverItems", "installFixtureLine",
                     "family-photo-deliver", "family-photo-clear", "family-photo-retry", "family-photo-status",
                     "家族に写真を届ける", "家族に届けた写真", "届けています", "届けられませんでした",
                     "家族の手帳の写真が上限です", "keyPhotoPreview", "enum Line"):
            self.assertNotIn(gone, self.care, gone)
        menu = section(self.care, "struct FamilyPhotoMenuItems: View {", "/// The questions and the report sheet")
        self.assertIn("この写真を通報", menu)
        self.assertIn("の写真を表示しない", menu)
        self.assertNotIn("ownPhoto", menu)
        fixture = read("NekoWidget/App/AppStoreScreenshotFixture.swift")
        self.assertNotIn("--cat-home-stress-family-photo-line", fixture)
        self.assertNotIn("48i_family_photo_failed", read("NekoWidgetUITests/ReviewScreenshotUITests.swift"))
        self.assertNotIn("48i_family_photo_failed", read("ci/collect-review-screenshots.py"))

    def test_only_the_payer_writes_and_unchanged_is_local(self):
        sync = section(self.model, "func syncCreatorPhotos() async {", "private func syncOne(")
        self.assertIn("FamilyNotebookSharing.shared.state.membership?.role == .payer", sync)
        self.assertIn("backend.canWrite", sync)
        self.assertIn("notebook.linkedFamilyCat(profile: profile.uuidString)", sync)
        one = section(self.model, "private func syncOne(", "private func deliver(")
        # Unchanged: the copy and what this iPhone sent, no network.
        self.assertIn("if referenced, isMine(backend.author(of: cat)), sent[key] == photo { return }", one)
        self.assertIn("try await backend.clear(cat)", one)
        self.assertIn("catch FamilyNotebookPhotoFailure.limited", one)
        self.assertLess(one.index("if referenced, isMine("), one.index("try await deliver("))
        self.assertIn("static let retryBackoff: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]", self.model)

    def test_a_clear_needs_this_iphones_own_delivery(self):
        # 11/19 (機種変更): a new iPhone of the same person, with no key photo
        # chosen, never clears the family's photo; the record is presence only.
        # 11/20: a choice first seen with a photo (after 機種変更 or a
        # reinstall) that is now none is cleared; first seen as none returns
        # before the clear branch.
        one = section(self.model, "private func syncOne(", "private func deliver(")
        self.assertIn("if first == (photo ?? \"\") { return }", one)
        self.assertLess(one.index("if first == (photo ?? \"\") { return }"), one.index("try await backend.clear(cat)"))
        clear = one.split("} else {", 1)[1]
        guard = "guard sent[key] != nil || seen[key] != nil else { return }"
        self.assertIn(guard, clear)
        self.assertLess(clear.index(guard), clear.index("try await backend.clear(cat)"))
        self.assertIn("sent[key] = nil; seen[key] = nil", clear)
        self.assertNotIn("sent[key] == photo", clear)

    def test_triggers_are_automatic(self):
        app = read("NekoWidget/App/AppRootView.swift")
        hook = section(app, ".onChange(of: familyPhotoSyncKey, initial: true)", "\n        }\n")
        self.assertIn("guard scenePhase == .active, familyPhotoCreator else { return }", hook)
        self.assertNotIn("SharingPersonAction", hook)
        self.assertIn("Task { await FamilyRepresentativePhotos.shared.ownKeyPhotosChanged(keyPhotos) }", hook)
        self.assertIn("$0.keyPhotoLocalIdentifier", hook)
        key = section(app, "private var familyPhotoSyncKey: String {", "\n    }\n")
        for part in ("scenePhase == .active", "familyPhotoCreator", "familyPhotoLinks", "keyPhotoLocalIdentifier"):
            self.assertIn(part, key)
        auto = section(SHARING, "final class FamilyNotebookAutoCheck {", "/// 11/15: this iPhone asked to join")
        self.assertIn("await FamilyRepresentativePhotos.shared.syncCreatorPhotos()", auto)
        factory = read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        self.assertEqual(factory.count("var canWrite: Bool"), 2)
        self.assertIn("FamilyNotebookAutoCheck.shared.sendSoon()", factory)
        self.assertNotIn("refreshAfterPlusChange", section(factory, "func clear(_ cat: UUID) async throws {", "func report("))


class FamilyNotebookDeviceChange1119Tests(unittest.TestCase):
    """11/19 (機種変更 水準2): a new iPhone of the same person returns to the
    family notebook as another device of that person."""

    def test_identity_is_chosen_in_one_place(self):
        factory = read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        self.assertEqual(factory.count("FamilyNotebookIdentityChoice.load("), 1)
        self.assertEqual(factory.count("client.familyNotebookIdentity()"), 1)
        provider = section(factory, "return ProductionFamilyNotebookSharingService(provider: {", "}, billing: {")
        self.assertLess(provider.index("FamilyNotebookServiceFactory.recoveredIdentity(client)"),
                        provider.index("client.familyNotebookIdentity()"))
        self.assertIn("pinSync: FamilyNotebookServiceFactory.pinSync()", provider)
        # Only FamilyNotebookIdentityChoice reads the link.
        for path in (ROOT / "NekoWidget").rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            if "notebook-recovery-link" in text:
                self.assertEqual(path.name, "FamilyNotebookKeyCoordinator.swift")
        choice = section(KEYS, "enum FamilyNotebookIdentityChoice {", "/// The iCloud Keychain item of the pin")
        self.assertIn("recovered.registered", choice)
        self.assertIn("usualPersonID != link.personID", choice)
        self.assertIn("!link.familyIDs.isEmpty", choice)
        # 11/19 (入れ直し): with a link, the recovered device wins over a
        # leftover usual device of the same person, and registers itself first.
        self.assertIn("usualPersonID != link.personID || usualDeviceID != recoveredDeviceID", choice)
        # 11/20: a recovered device the relay said was taken off is never picked.
        self.assertIn("usualPersonID: usual, usualDeviceID: usualDevice, revocations: client.revocations)", factory)
        self.assertIn("try await reinstalledIPhoneRegistersItsNewDevice(directory: directory, endpoint: endpoint)", DELIVERY)
        self.assertIn("reinstall: the first write is the new device's registration", DELIVERY)

    def test_pin_is_synced_and_never_from_the_relay(self):
        save = section(KEYS, "private func save(_ value: Trust, createOnly: Bool = false) throws {", "/// 11/19 (機種変更 水準2): a new iPhone")
        self.assertIn("if let pin = value.pin { syncPin(pin) }", save)
        adopt = section(KEYS, "private func adoptSyncedPin(_ family: UUID) throws {", "/// Call only after validating")
        self.assertIn("pinSync.read(endpoint: endpoint, personID: identity.personID, family: family)", adopt)
        self.assertIn("createdHere: false, pin: pin", adopt)
        self.assertNotIn("network", adopt)
        prepare = section(KEYS, "func prepare(family: UUID) async throws -> FamilyNotebookKeyMaterial? {", "var currentState = try await state(family)")
        self.assertLess(prepare.index("try adoptSyncedPin(family)"), prepare.index("var trusted = try trust(family)"))
        stored = section(KEYS, "struct FamilyNotebookStoredPinSync: FamilyNotebookPinSync {", "enum FamilyNotebookIdentityChoice {")
        self.assertIn("saved.epoch >= pin.epoch { return }", stored)
        keychain = section(KEYS, "struct FamilyNotebookSyncedKeychainStore: GroupSecretStore {", "func remove(_ account: String)")
        self.assertIn("kSecAttrSynchronizable as String: true", keychain)
        self.assertIn("kSecAttrAccessibleWhenUnlocked", keychain)
        self.assertNotIn("ThisDeviceOnly", keychain)
        # The same access class as the person key's iCloud Keychain item.
        self.assertIn("kSecAttrAccessibleWhenUnlocked", read("NekoWidget/Services/RootSyncStore.swift"))
        for name in ("newIPhoneFromSyncedPin(directory: directory, endpoint: endpoint)", "identityChoice()"):
            self.assertIn("try await " + name if name.startswith("new") else "try " + name, DELIVERY)
        pinned = section(DELIVERY, "fileprivate static func newIPhoneFromSyncedPin(", "fileprivate static func identityChoice(")
        for step in ("pin: the creator's verified pin is synced next to the person key",
                     "pin: an older pin never replaces a newer one",
                     "a2-none", "a2-forged",
                     "pin: the new iPhone walked from epoch 1 to the current roster and synced it",
                     "pin: the person's other iPhone signed the new iPhone in without an approval",
                     "pin: the new iPhone has every past key"):
            self.assertIn(step, pinned)

    def test_owner_trial_way_back_forgets_only_the_recovered_device(self):
        # 11/19 (2台試験だけ): B's iPhone, used as A's new iPhone, back to B; the
        # next recovery registers a fresh device. Owner trial builds only.
        factory = read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        block = section(factory, "#if INTERNAL_PRESENTATION\n/// 11/19 (2台試験だけ)", "#endif\n")
        reset = section(block, "static func forgetRecovery() async throws -> String {", "\n    }\n}")
        self.assertIn("guard let trial = OwnerTwoDeviceTrialConfiguration.current,", reset)
        # Nothing on A's own iPhone; nothing created or registered.
        self.assertLess(reset.index("if try await client.existingPersonID() == trial.owner { return "),
                        reset.index(".remove("))
        for token in ("familyNotebookIdentity()", "deviceIdentity(", "write(", "RootSyncStore", "pinSync",
                      "FamilyNotebookSyncedKeychainStore", "SharingPersonAction", "notebook-recovery-link"):
            self.assertNotIn(token, reset)
        # This iPhone's own identity (the bare namespace) is never touched.
        self.assertNotIn("GroupKeychainStore(namespace: namespace)", reset)
        self.assertEqual(reset.count("GroupKeychainStore(namespace: namespace + "), 1)
        self.assertIn("GroupKeychainStore(namespace: namespace + FamilyNotebookServiceFactory.recoveryLinkSuffix)", reset)
        # 11/20: each recovered device goes through the function the identity
        # deletion uses (FamilySharingLocalData), one scope at a time.
        self.assertIn("for scope in scopes.sorted() {\n            try local.forgetRecoveredDevice(scope: scope, endpoint: endpoint)\n        }", reset)
        self.assertNotIn("removeAfterIdentityDeletion", reset)
        local = section(read("NekoWidget/Services/FamilyNotebookKeyCoordinator.swift"),
                        "struct FamilySharingLocalData {", "\n}\n")
        recovered = section(local, "func forgetRecoveredDevice(scope: String, endpoint: URL) throws {", "\n    }\n")
        for store in ('".recovery." + scope', '".recovery-journal." + scope'):
            self.assertIn("store(namespace + " + store + ")", recovered)
        self.assertIn("try forgetNotebook(scope: Self.notebookScope(endpoint: endpoint, personID: identity.personID,", recovered)
        self.assertIn('.appendingPathComponent("recovery-" + scope, isDirectory: true)', recovered)
        notebook = section(local, "func forgetNotebook(scope: String) throws {", "\n    }\n")
        self.assertIn('store(namespace + ".family." + scope)', notebook)
        self.assertIn('.appendingPathComponent("FamilyNotebook-v1", isDirectory: true)', notebook)
        for token in ("write(", "RootSyncStore", "pinSync", "SharingPersonAction"):
            self.assertNotIn(token, local)
        # The link goes first, then the notebook stops using the recovered identity.
        self.assertLess(reset.index("try links.remove(FamilyNotebookIdentityChoice.linkAccount)"),
                        reset.index("FamilyNotebookSharing.shared.restartSession()"))
        self.assertLess(reset.index("FamilyNotebookSharing.shared.restartSession()"), reset.index("for scope in scopes"))
        self.assertIn("FamilyRepresentativePhotos.forgetSyncRecords(family)", reset)
        # The same notebook scope as the provider's.
        self.assertIn("Data(endpoint.absoluteString.utf8), Data(personID.utf8), Data(deviceID.utf8)", local)
        self.assertIn("Data(endpoint.absoluteString.utf8), Data(identity.personID.utf8), Data(identity.deviceID.utf8)", factory)
        settings = read("NekoWidget/Views/SettingsView.swift")
        view = section(settings, "private struct OwnerTwoDeviceEnrollmentView: View {", "\n#endif")
        self.assertIn('Button("この端末をBに戻す", role: .destructive) { confirmsForget = true }', view)
        self.assertIn("try await FamilyNotebookOwnerTrialReset.forgetRecovery()", view)
        self.assertEqual(settings.count("FamilyNotebookOwnerTrialReset"), 1)
        records = section(read("NekoWidget/Views/CatCareView.swift"), "#if INTERNAL_PRESENTATION\n    /// 11/19 (the owner's two-device trial only)", "#endif")
        self.assertIn("static func forgetSyncRecords(_ family: UUID) {", records)

    def test_creators_new_iphone_never_overwrites_the_family_photo_first(self):
        # 11/19 (the creator with two iPhones): a photo by this person that this
        # iPhone never sent is replaced only after this iPhone's own choice changed.
        model = read("NekoWidget/Views/CatCareView.swift")
        one = section(model, "private func syncOne(", "private func deliver(")
        guard = section(one, "if sent[key] == nil {", "if let photo {")
        self.assertIn("if first == (photo ?? \"\") { return }", guard)
        self.assertIn("} else if referenced, isMine(backend.author(of: cat)) {\n                seen[key] = photo ?? \"\"\n                return", guard)
        self.assertLess(one.index("if sent[key] == nil {"), one.index("try await deliver("))
        self.assertIn("sent[key] = photo; seen[key] = nil", one)
        run = section(model, "private func runSync() async {", "private func syncOne(")
        self.assertIn("var sent = Self.sentPhotos(family), seen = Self.seenPhotos(family)", run)
        self.assertIn("if seen != seenBefore { Self.saveSeen(seen, family) }", run)
        self.assertIn('private static let seenKeyPrefix = "familyNotebook.creatorPhotos.seen.v1."', model)


class NotebookCleanup1119Tests(unittest.TestCase):
    """11/19 UI/UX 整理 (rounds 1 and 2): nothing looks broken, and each
    state is said one way in one place."""

    SHARING = read("NekoWidget/Services/FamilyNotebookSharing.swift")
    CONTRACT = read("NekoWidget/Services/GroupWindowContract.swift")
    DELEGATE = read("NekoWidget/Services/MomentBackgroundRefreshService.swift")
    PUSH = read("SharingService/src/family-notebook-push.ts")
    CARE = read("NekoWidget/Views/CatCareView.swift")

    def test_a_member_never_reads_the_left_copy_text(self):
        # The text was for a person who left; a member landed on it while the
        # first read ran (no family shown before, a failed read, the switch).
        self.assertNotIn("このiPhoneに残っている記録です", NOTEBOOK)
        self.assertNotIn("家族との共有を確認しています", NOTEBOOK)
        body = section(NOTEBOOK, "                if showsNotebook {", '            .navigationTitle("家族の手帳")')
        self.assertIn("notebook(shownMembership)", body)
        self.assertNotIn("case .checking where", body)
        self.assertIn("if sharing.readFailed { checkFailedView } else { ProgressView() }", body)
        shows = section(NOTEBOOK, "private var showsNotebook: Bool {", "\n    }")
        # In the family (not a left copy) and still checking: the notebook itself.
        self.assertIn("shownMembership != nil || (sharing.state == .checking && model.hasFamily)", shows)

    def test_what_needs_the_role_waits_for_it(self):
        notebook = section(NOTEBOOK, "private func notebook(_ membership: FamilyMembership?) -> some View {",
                           "    private var prototype:")
        self.assertIn("if membership?.canInvite == true && sharing.pause == nil {", notebook)
        self.assertIn("if let membership, membership.canLeave {", notebook)
        self.assertIn("if let membership, membership.canRemoveMember, !model.isMe(member) {", notebook)
        self.assertIn("} else if sharing.state == .checking && sharing.readFailed {\n                checkFailedSection", notebook)

    def test_the_family_as_shown_is_kept_after_every_read(self):
        read_ = section(self.SHARING, "private func read(reportsFailure: Bool) async -> Bool {", "    func restartSession()")
        self.assertIn("if let membership = next.membership { FamilyNotebookPrototype.shared.rememberShown(membership) }", read_)
        self.assertLess(read_.index("FamilyNotebookPrototype.shared.attachReal("), read_.index("rememberShown(membership)"))
        self.assertIn("if !readFailed { readFailed = true }", read_)
        self.assertIn("if readFailed { readFailed = false }", read_)
        restart = section(self.SHARING, "func restartSession() {", "\n    }")
        self.assertIn("readFailed = false", restart)

    def test_a_failed_read_says_one_line_and_one_button(self):
        failed = section(NOTEBOOK, "private var checkFailedSection: some View {", "private var recheckButton")
        self.assertIn('Label("つながりませんでした", systemImage: "wifi.exclamationmark")', failed)
        retry = section(NOTEBOOK, "private var recheckButton: some View {", '.accessibilityIdentifier("family-notebook-check-retry")')
        self.assertIn('WorkingLabel(title: "もう一度", workingTitle: "確認しています…", working: rechecking)', retry)
        self.assertIn("SharingPersonAction.run", retry)

    def test_taken_out_or_ended_is_said_once(self):
        self.assertIn('static let sharingEnded = "この手帳の共有は終わりました。"', NOTEBOOK)
        self.assertIn("endedJoinNotice ?? (model.showsEndedNotice ? FamilyNotebookWords.sharingEnded : nil)", NOTEBOOK)
        shows = section(NOTEBOOK, "var showsEndedNotice: Bool {", "\n    }")
        # Not this iPhone's own leaving or ending: only the directory's absence.
        self.assertIn("snapshot.endedReason == .absentFromDirectory", shows)
        self.assertIn("static let endedNoticeDays = 7", NOTEBOOK)
        # Written after a read, never while drawing.
        self.assertIn("if next == .notInFamily { FamilyNotebookPrototype.shared.noteEndedNotice() }", self.SHARING)
        self.assertEqual(NOTEBOOK.count("noteEndedNotice("), 1)

    def test_own_invitation_link_is_not_sent_toward_leaving(self):
        join = section(NOTEBOOK, "struct FamilyNotebookJoinView: View {", "struct FamilyNotebookNameView: View {")
        self.assertIn('static let alreadyInThisFamily = "もう家族の手帳に入っています。"', NOTEBOOK)
        self.assertIn("} else if inFamily && !otherFamilyLink {", join)
        self.assertIn('Text("手帳を開く")', join)
        # Only a link verified to be another family's says 「抜けると参加できます」.
        other = section(join, "private var otherFamilyLink: Bool {", "\n    }")
        self.assertIn("FamilyNotebookInvitationCapability(url: link).familyID", other)
        self.assertIn("return linked != own", other)
        self.assertLess(join.index("} else if inFamily && !otherFamilyLink {"),
                        join.index("FamilySharingError.alreadyInFamily.message"))

    def test_a_notification_tap_opens_the_notebook(self):
        route = section(self.CONTRACT, "enum FamilyNotebookNotificationRoute {", "\n}\n")
        self.assertIn('["family_join_requested", "family_join_approved"]', route)
        self.assertIn("FamilyNotebookNotificationRoute.matches(response.notification.request.content.userInfo)", self.DELEGATE)
        self.assertIn("FamilyNotebookOpenInbox.shared.opensNotebook = true", self.DELEGATE)
        self.assertIn(".onReceive(familyNotebookOpenInbox.$opensNotebook)", ROOT_VIEW)
        # The pushes say the notebook's words.
        self.assertIn("'家族の手帳に、参加を待っている人がいます。':'家族の手帳に参加できました。'", self.PUSH)
        self.assertNotIn("入りたい人", self.PUSH)

    def test_each_wait_is_said_one_way(self):
        self.assertIn('static let awaitingApproval = "家族が受け入れるのを待っています"', NOTEBOOK)
        self.assertIn('static let receiving = "家族の手帳を受け取っています"', NOTEBOOK)
        for old in ('"参加を待っています"', '"準備しています"', "家族が参加を受け入れると",
                    '"家族の手帳を受け取っています。"', '"家族が受け入れるのを待っています。"'):
            self.assertNotIn(old, NOTEBOOK)
        self.assertIn('ContentUnavailableView(FamilyNotebookWords.receiving, systemImage: "book.closed")', NOTEBOOK)

    def test_ending_is_in_one_place_with_its_own_words(self):
        notebook = section(NOTEBOOK, "private func notebook(_ membership: FamilyMembership?) -> some View {",
                           "    private var prototype:")
        self.assertIn('Button("家族の手帳から抜ける", role: .destructive)', notebook)
        self.assertIn('Button("家族の手帳を終わりにする", role: .destructive)', notebook)
        self.assertLess(notebook.index("家族の手帳から抜ける"), notebook.index("家族の手帳を終わりにする"))
        self.assertIn("if membership.canDissolve {", notebook)
        member = section(NOTEBOOK, "struct FamilyNotebookMemberView: View {", "    var body: some View {")
        self.assertNotIn("dissolve", member)
        self.assertIn('case .remove: "この人を手帳から外す"', member)
        self.assertIn('"\\(member.displayName)さんを家族の手帳から外しますか？"', member)
        self.assertNotIn("家族の共有をやめる", NOTEBOOK)
        self.assertIn('Button("この猫を手帳から外す")', read("NekoWidget/Views/FamilyNotebookSharedCatRow.swift"))
        self.assertIn('WorkingLabel(title: "この日付の共有をやめる"', NOTEBOOK)
        self.assertIn('static let dissolveDetail = "家族みんなの共有が終わります。書いたものは、それぞれのiPhoneに残ります。"',
                      NOTEBOOK)

    def test_paused_says_one_sentence(self):
        paused = section(NOTEBOOK, "static func pausedDetail(_ pause: FamilySharingPause) -> String {", "\n    }")
        for line in ('"だれか1人がPlusを始めると、また共有できます。"', '"Plusを続けると、家族みんなの共有が戻ります。"',
                     '"書いたものは消えません。Plusが戻ると、また共有できます。"'):
            self.assertIn(line, paused)
        for old in ("払っている人", "家族の共有に使っているPlus", "確認できないため"):
            self.assertNotIn(old, paused)
        self.assertNotIn("あなたのPlusで、家族みんなの共有が戻ります。", NOTEBOOK)
        self.assertIn('case .continueFamily: "家族の手帳を再開する"', OFFER)

    def test_report_says_where_the_answer_comes(self):
        self.assertIn('Text("返答は、家族の手帳の「通報への返答」に届きます。")', self.CARE)



class IdentityDeletionAndLeaving1120Tests(unittest.TestCase):
    def test_deletion_cleans_up_only_after_acceptance(self):
        # 11/20: 「まどと家族の手帳のデータを消す」: the rest of the sharing state
        # goes once the relay accepted (verify-identity-deletion-cleanup, S20).
        window = read("NekoWidget/Views/GroupWindowView.swift")
        view = section(window, "struct GroupIdentityDeletionView: View {", "private func refresh() async {")
        delete = section(view, "private func delete() async {", "} catch {")
        self.assertLess(delete.index("record = try await client.requestIdentityDeletion()"),
                        delete.index("await GroupIdentityDeletionLocalData.resumeIfNeeded()"))
        self.assertIn("if record?.acceptedAt != nil { await GroupIdentityDeletionLocalData.resumeIfNeeded() }", view)
        self.assertIn("await GroupIdentityDeletionLocalData.resumeIfNeeded()", ROOT_VIEW)
        factory = read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        local = section(factory, "enum GroupIdentityDeletionLocalData {", "\n}\n") + "\n"
        resume = section(local, "static func resumeIfNeeded() async {", "\n    }\n")
        self.assertLess(resume.index("guard await remove(record) else { return }"),
                        resume.index("try? await client.markIdentityDeletionLocalCleanupDone()"))
        remove = section(local, "static func remove(_ deletion: GroupIdentityDeletion, keepsSharedCopies: Bool = false) async -> Bool {", "\n    }\n")
        self.assertIn("guard deletion.acceptedAt != nil else { return false }", remove)
        # A record from before 11/20 removes nothing more; a running notebook
        # pass ends first; a removed copy's binding goes before the files.
        self.assertIn("guard let person = deletion.personID else { return true }", remove)
        self.assertLess(remove.index("await FamilyNotebookSharing.shared.stopForIdentityDeletion()"),
                        remove.index("local.removeAfterIdentityDeletion("))
        self.assertLess(remove.index("UserDefaults.standard.removeObject(forKey: FamilyNotebookLocalBinding.key)"),
                        remove.index("local.removeAfterIdentityDeletion("))
        # The shared copies only when no other identity (機種変更) remains.
        # 11/21: nor while the usual person remains after the recovered one went.
        self.assertIn("let othersRemain = outcome.otherIdentityRemains || keepsSharedCopies", remove)
        shared = section(remove, "if !othersRemain {", "\n        }\n")
        self.assertIn("for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }", shared)
        self.assertIn("local.removeSharedCopies(keychainCopies)", shared)
        self.assertNotIn("recoveryLinkSuffix", section(local, "static let keychainCopies", "]"))
        core = read("NekoWidget/Services/FamilyNotebookKeyCoordinator.swift")
        removal = section(core, "func removeAfterIdentityDeletion(", "\n    }\n")
        self.assertIn("guard scope == deleted else { result.otherIdentityRemains = true; continue }", removal)
        self.assertIn("link.personID == personID || link.scope == deleted", removal)
        self.assertNotIn('".family."', removal)
        for key in ("FamilyNotebookLocalBinding.key", "FamilyNotebookLocalBinding.legacyKey", "GroupDisplayName.rememberedKey",
                    "FamilyHiddenOperationsMemory.defaultsKey", "FamilyCatLinkAnswersMemory.defaultsKey",
                    "FamilyNotebookSharing.sendHealthKey", "FamilyNotebookAwaitingApproval.key"):
            self.assertIn(key, local)
        # The person's own records, photos, widgets, 保存 and purchases are not touched.
        for token in ("CatCareStore", "CareHandoffStore", "VeterinaryVisitStore", "AppRecordDataset", "FamilyNotebookBackup",
                      "PlusPurchaseStore", "ManagedPreservation", "WidgetCenter"):
            self.assertNotIn(token, local)
        # 11/20: the kept windows' list only for its choices, never a photo.
        self.assertEqual(local.count("GroupWindowLocalPhotoStore"), 1)
        self.assertIn("GroupWindowLocalPhotoStore.shared.forgetIdentityChoices()", local)
        client = read("NekoWidget/Services/ProductionGroupWindowClient.swift")
        request = section(client, "func requestIdentityDeletion() async throws -> GroupIdentityDeletion {", "\n    }\n")
        self.assertLess(request.index("if record.acceptedAt == nil {"), request.index("_ = removeGroupKeys()"))
        self.assertNotIn("try removeGroupKeys()", client)
        keys = section(client, "private func removeGroupKeys() -> Bool {", "\n    }\n")
        self.assertIn('account != Self.deletionAccount\n            && !account.hasPrefix("identity-deletion-history:")', keys)

    def test_deletion_leaves_no_outbox_journal_marks_or_window_choices(self):
        # 11/20 (after #1104): what was still left behind on this iPhone.
        factory = read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        local = section(factory, "enum GroupIdentityDeletionLocalData {", "\n}\n") + "\n"
        resume = section(local, "static func resumeIfNeeded() async {", "\n    }\n")
        # The outbox and journal: after the rest, and the clean-up is marked done only when they went.
        self.assertLess(resume.index("guard await remove(record) else { return }"),
                        resume.index("guard await client.removeDeletedIdentityTransport() else { return }"))
        self.assertLess(resume.index("guard await client.removeDeletedIdentityTransport() else { return }"),
                        resume.index("try? await client.markIdentityDeletionLocalCleanupDone()"))
        client = read("NekoWidget/Services/ProductionGroupWindowClient.swift")
        transport = section(client, "func removeDeletedIdentityTransport() -> Bool {", "\n    }\n")
        self.assertIn("guard let record = try? identityDeletion(), record.acceptedAt != nil else { return false }", transport)
        self.assertIn('guard try secrets.read("device-link") == nil else { return false }', transport)
        self.assertIn("record.personID == nil || current.personID != record.personID { return false }", transport)
        self.assertIn('for account in try operations.accounts(prefix: "op:") {', transport)
        self.assertIn('for file in files where file.pathExtension == "json" {', transport)
        # The journal database stays open: rows go, never the folder or its file.
        self.assertNotIn("removeItem(at: outboxDirectory", transport)
        self.assertNotIn("http-operations", transport)
        # UserDefaults: the person's own marks always; the shared ones only when no other identity remains.
        remove = section(local, "static func remove(_ deletion: GroupIdentityDeletion, keepsSharedCopies: Bool = false) async -> Bool {", "\n    }\n")
        self.assertLess(remove.index("local.removeAfterIdentityDeletion("),
                        remove.index("removeDefaults(prefixes: [personDefaultsPrefix(person)])"))
        self.assertLess(remove.index("removeDefaults(prefixes: [personDefaultsPrefix(person)])"),
                        remove.index("if !othersRemain {"))
        shared = section(remove, "if !othersRemain {", "\n        }\n")
        self.assertIn("for key in sharedDefaultsKeys { UserDefaults.standard.removeObject(forKey: key) }", shared)
        self.assertIn("removeDefaults(prefixes: sharedDefaultsPrefixes)", shared)
        self.assertIn("if !othersRemain, !(await GroupWindowLocalPhotoStore.shared.forgetIdentityChoices()) {", remove)
        self.assertLess(remove.index("FamilyNotebookSharing.shared.restartSession()"),
                        remove.index("GroupWindowLocalPhotoStore.shared.forgetIdentityChoices()"))
        self.assertIn('static func personDefaultsPrefix(_ personID: String) -> String { "familyNotebook.seen.v1." + personID + "." }', local)
        self.assertIn("static let sharedDefaultsKeys = [FamilyReportReplies.sentKey]", local)
        # The prefixes are the ones the app writes.
        notebook = read("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn('return "familyNotebook.seen.v1." + person + "." + id.uuidString.lowercased()', notebook)
        care = read("NekoWidget/Views/CatCareView.swift")
        photos = read("NekoWidget/Services/GroupWindowLocalPhotoStore.swift")
        for prefix, source_text, declaration in (
                ("familyNotebook.creatorPhotos.v1.", care, 'private static let sentKeyPrefix = "familyNotebook.creatorPhotos.v1."'),
                ("familyNotebook.creatorPhotos.seen.v1.", care, 'private static let seenKeyPrefix = "familyNotebook.creatorPhotos.seen.v1."'),
                ("group.pendingManagement.v1.", photos, 'private static func storageKey(_ windowID: String) -> String { "group.pendingManagement.v1." + windowID }')):
            self.assertIn(declaration, source_text)
            self.assertIn('"' + prefix + '"', section(local, "static let sharedDefaultsPrefixes = [", "]"))
        # windows.json: the choices and this identity's participant ID; the photos stay.
        forget = section(photos, "func forgetIdentityChoices() -> Bool {", "\n    }\n")
        self.assertIn("windows[index].hiddenMembers = nil", forget)
        self.assertIn("windows[index].myParticipantID = nil", forget)
        for token in ("removeItem", "loadIndex", "isRemoved", "GroupWindowKept"):
            self.assertNotIn(token, forget)
        verify = read("ci/verify-identity-deletion-cleanup.swift")
        self.assertIn("try await transportChecks(folder)", verify)

    def test_leaving_sends_what_waits_once_first(self):
        # 11/20: one send pass before leaving (S21); never when ending the family.
        service = read("NekoWidget/Services/ProductionFamilyNotebookSharingService.swift")
        exit_ = section(service, "private func exit(_ operation: UUID, dissolve: Bool) async throws -> FamilyExitResult {",
                        "func pendingRequests()")
        self.assertIn("if !dissolve, await sendBeforeLeaving(context, family: family.familyID, store: store) {", exit_)
        self.assertLess(exit_.index("await sendBeforeLeaving("), exit_.index("context.membership.leaveFamily("))
        self.assertIn("expectedGeneration: generation, operationID: operation, notebook: store)", exit_)
        send = section(exit_, "private func sendBeforeLeaving(", "\n    }\n")
        self.assertIn("guard (try? store.pendingOperations().isEmpty) == false else { return false }", send)
        self.assertEqual(send.count("sync.synchronize("), 1)
        self.assertIn("} catch {}", send)
        # 11/21: what waited before an unconfirmed end is kept and sent after it comes back.
        store = read("NekoWidget/Services/FamilyNotebookStore.swift")
        resume = section(store, "func resumeSharingAfterUnconfirmedEnd() throws -> FamilyNotebookSnapshot {", "\n    }\n")
        self.assertNotIn("state.outboxIDs = []", resume)


if __name__ == "__main__":
    unittest.main()
