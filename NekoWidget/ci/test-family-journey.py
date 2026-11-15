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
                      "                      store.allowsAutomaticBillingCheck() else { continue }", recheck)
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
        self.assertIn("model.hasFamily || FamilyNotebookSharing.awaitingApproval", auto)
        # An app from before 11/15 left no mark: one read settles it.
        self.assertIn("|| FamilyNotebookSharing.awaitingApprovalUnknown)", auto)
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
        self.assertIn("private var showsFamilyNotebookRow: Bool { familyNotebook.hasFamily || awaitsFamilyApproval }", SETTINGS)
        self.assertEqual(SETTINGS.count('Text("参加を待っています")'), 1)

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
        self.assertIn("case .requestsOnly:\n                        await sharing.refreshRequests()", auto)
        self.assertNotIn("Task.sleep(for: .seconds(pending ? 5 : 20))", NOTEBOOK)
        self.assertIn(".refreshable { if !sharing.isWorking { await sharing.refresh(reportsFailure: true) } }", NOTEBOOK)

    def test_join_name_field_says_whose_name(self):
        join = section(NOTEBOOK, "struct FamilyNotebookJoinView: View {", "struct FamilyNotebookNameView: View {")
        field = section(join, 'Text("あなたの名前")', '.accessibilityIdentifier("family-notebook-display-name")')
        self.assertIn("TextField(", field)
        self.assertLess(join.index('"family-notebook-display-name"'), join.index('Text("家族に表示されます。")'))
        self.assertIn('Text("あなたの名前")', section(SETUP, "private var applySection: some View {", "\n    }\n"))


TRANSPORT = read("NekoWidget/Services/GroupWindowTransport.swift")
KEYS = read("NekoWidget/Services/FamilyNotebookKeyCoordinator.swift")
DELIVERY = read("ci/verify-family-notebook-key-delivery.swift")


class CallBudget1115qTests(unittest.TestCase):
    """1115q: automatic checks could pass the relay's limits (120 a minute per
    address for the まど and the notebook, 10 for billing). One schedule,
    backoff while keys do not move, a per-iPhone budget, 429 pauses."""

    def test_transport_budget_is_30_a_minute_for_automatic_calls_only(self):
        send = section(TRANSPORT, "func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {", "enum GroupHTTPRequest")
        self.assertLess(send.index("try SharingAutoCallBudget.admitIfAutomatic()"), send.index("session.bytes(for: request)"))
        self.assertIn('SharingAutoCallBudget.noteReply(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))', send)
        self.assertIn("static let perMinute = 30", TRANSPORT)
        self.assertIn("static let rateLimitedPause: TimeInterval = 60", TRANSPORT)
        self.assertIn("@TaskLocal static var isAutomatic = false", TRANSPORT)
        self.assertIn("guard isAutomatic else { return }", section(TRANSPORT, "static func admitIfAutomatic(", "\n    }\n"))
        self.assertIn("max(Self.rateLimitedPause, retryAfter ?? 0)", TRANSPORT)

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
        self.assertIn("await SharingAutoCallBudget.$isAutomatic.withValue(true) {", auto)
        self.assertIn("FamilyAutoCheckPolicy.next(situation(now: Date()))", auto)
        self.assertIn("SharingAutoCallBudget.shared.pausedUntil()", auto)
        # The まど's waiting lists are automatic too.
        setup = read("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertEqual(setup.count("SharingAutoCallBudget.$isAutomatic.withValue(true)"), 2)

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
        self.assertIn("static let automaticCeiling = 5", POLICY)
        loop = section(STORE, "private func runServerConfirmationRechecks(first: [Duration]) {", "private func finishServerConfirmationRechecks()")
        self.assertIn("store.allowsAutomaticBillingCheck() else { continue }", loop)
        self.assertIn("entitlementReads.record(at: Date())\n            let response = try await fetchAuthoritativeEntitlement()", STORE)
        self.assertIn("transactionPosts.record(at: Date())", STORE)
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


class RegistrationTests(unittest.TestCase):
    def test_native_tests_are_in_the_test_target(self):
        self.assertIn("path = FamilyJourneyTests.swift;", PROJECT)
        self.assertEqual(PROJECT.count("C1FA3A110000000000000001"), 2)
        self.assertEqual(PROJECT.count("C1FA3A110000000000000002"), 3)
        self.assertIn("final class FamilyJourneyTests: XCTestCase", TESTS)
        self.assertIn("python3 ci/test-family-journey.py\n", read("ci/run-quick-ios-checks.sh"))


if __name__ == "__main__":
    unittest.main()
