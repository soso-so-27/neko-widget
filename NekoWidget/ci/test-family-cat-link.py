#!/usr/bin/env python3
"""11/15 (段 1): the same cat in the family notebook and on this iPhone.

The words people read, where they are asked, and what is never added
(settings, notifications, promises), fixed as source checks.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8").replace("\r\n", "\n")


HOME = read("NekoWidget/Views/CatHomeView.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")
CARE = read("NekoWidget/Views/CatCareView.swift")
LINK = read("NekoWidget/Services/FamilyNotebookCatLink.swift")
STORE = read("NekoWidget/Services/FamilyNotebookStore.swift")
CORE = read("NekoWidget/Services/FamilyNotebookCore.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
PROFILES = read("NekoWidget/Views/CatProfilesView.swift")


def block(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise AssertionError(f"Expected one {marker!r}")
    start = source.index(marker)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker!r}")


class Words(unittest.TestCase):
    def test_the_question(self):
        view = block(NOTEBOOK, "struct FamilyNotebookLinkQuestionView: View {")
        # A heading, one sentence, the cats with photos, one other answer.
        self.assertIn('.navigationTitle("家族の手帳の「" + cat.name + "」")', view)
        self.assertIn('Text("このiPhoneの子と同じですか。")', view)
        self.assertIn("CatProfileThumbnail(photo: profile.coverPhoto)", view)
        self.assertIn('Button("べつの子") { other() }', view)
        self.assertIn('.accessibilityLabel(profile.displayName + "と同じ子")', view)
        self.assertIn('Button("閉じる") { dismiss() }', view)

    def test_adding_a_cat_starts_with_the_family_cats(self):
        self.assertIn('.confirmationDialog("家族の手帳の子から選ぶ", isPresented: $choosesFamilyCat, titleVisibility: .visible)', HOME)
        self.assertIn('Button("新しい子を追加") { registeringFamilyCat = nil; addsCat = true }', HOME)
        # The family cat's name is in the usual registration.
        self.assertIn("initialName: registeringFamilyCat?.name", HOME)
        self.assertIn("CatProfileDraftPresentation(name: initialName ?? \"\"", PROFILES)

    def test_adding_to_the_notebook_asks_about_the_same_name(self):
        selection = block(NOTEBOOK, "struct FamilyNotebookCatSelectionView: View {")
        # 11/19 (UI/UX 整理): the same heading, sentence and answers as the
        # この子 tab's question.
        self.assertIn('"家族の手帳の「" + $0.family.name + "」"', selection)
        self.assertIn("Text(FamilyNotebookWords.sameChildQuestion)", selection)
        self.assertIn('static let sameChildQuestion = "このiPhoneの子と同じですか。"', NOTEBOOK)
        self.assertIn('Button("同じ子") { answer(question, same: true) }', selection)
        self.assertIn('Button("べつの子") { answer(question, same: false) }', selection)
        for old in ("と同じ子ですか。", "同じ子（つなぐ）", "べつの子（手帳に足す）"):
            self.assertNotIn(old, NOTEBOOK)
        self.assertIn('.navigationTitle("手帳に入れる猫")', selection)
        self.assertIn('Button("決める", action: add)', selection)
        self.assertNotIn("追加する猫を選ぶ\")", selection)
        # 「同じ子」 links instead of making a second family cat.
        add = block(selection, "private func add() {")
        self.assertIn("try await model.link(family, toProfile: profile)", add)
        self.assertIn("let rest = selected.subtracting(linkedCats.keys)", add)
        self.assertLess(add.index("model.link("), add.index("model.sharePersonalCats(rest)"))

    def test_the_page_without_a_photo(self):
        art = block(HOME, "private struct CatHomeNoPhotoArt: View {")
        self.assertIn('Image("Nowa-sit-up")', art)
        self.assertIn(".accessibilityHidden(true)", art)
        button = block(HOME, "private struct CatHomeChoosePhotoButton: View {")
        # 11/19 (UI/UX 整理): named for what it does, not 「写真を選ぶ」.
        self.assertIn('private var title: String { linksHere ? "このiPhoneの子とつなぐ" : "この子を追加" }', button)
        self.assertIn("Label(title, systemImage: linksHere ? \"link\" : \"plus\")", button)
        self.assertNotIn("写真を選ぶ", button)
        self.assertIn("linksHere: hasLinkCandidates(toolID: cat.id),", HOME)
        self.assertIn("frame(maxWidth: .infinity, minHeight: 44)", button)
        # One way in: the page's button goes to the same question or registration.
        choose = block(HOME, "private func choosePhoto(for cat: FamilyNotebookCatLink.Unlinked) {")
        self.assertIn("if linkCandidates(for: cat).isEmpty { register(cat) }", choose)
        self.assertIn("CatHomeLinkQuestion(cat: cat, registersOther: true)", choose)
        # 11/17: a photo the family delivered takes のわ's place; none: のわ.
        self.assertIn("if cat.profile?.coverPhoto == nil {\n                if let familyPhoto {", HOME)
        self.assertIn("} else {\n                    CatHomeNoPhotoArt(metrics: metrics)\n                }", HOME)

    def test_unlinking_is_in_the_cat_menu_only(self):
        self.assertIn('Button("家族の手帳とのつながりを外す", systemImage: "link") { confirmsUnlink = true }', CARE)
        self.assertIn('.confirmationDialog("家族の手帳とのつながりを外しますか？"', CARE)
        self.assertIn('Text("この子の写真と、書いたことの控えは、このiPhoneに残ります。")', CARE)
        self.assertEqual(sum(text.count("家族の手帳とのつながりを外す\"") for text in (HOME, NOTEBOOK, CARE)), 1)
        offered = block(NOTEBOOK, "func unlinkOffered(profile: String) -> Bool {")
        self.assertIn("answeredLinks.contains(key)", offered)

    def test_no_promises_settings_or_notifications(self):
        for text in (LINK, block(NOTEBOOK, "struct FamilyNotebookLinkQuestionView: View {"),
                     block(HOME, "private struct CatHomeChoosePhotoButton: View {")):
            for word in ("永久", "ずっと", "無料", "UNUserNotificationCenter", "Toggle("):
                self.assertNotIn(word, text)


class AskedOnce(unittest.TestCase):
    def test_never_as_the_app_opens(self):
        # From この子 and the notebook only, after the screen is still.
        self.assertNotIn("FamilyNotebookLinkQuestionView", ROOT_VIEW)
        self.assertNotIn("pendingLinkQuestion", ROOT_VIEW)
        task = HOME.split(".task(id: familyNotebook.unlinkedFamilyCats.map(\\.id)) {", 1)[1].split("}", 1)[0]
        self.assertIn("try? await Task.sleep(for: .milliseconds(900))", task)
        # 11/19 (UI/UX 整理): asked by the この子 tab only, not again by the notebook.
        self.assertNotIn("FamilyNotebookLinkAsk", NOTEBOOK)
        self.assertEqual(NOTEBOOK.count("pendingLinkQuestion(profiles:"), 1)

    def test_a_link_that_fails_says_so(self):
        # 11/19: it used to be dropped (`try?`).
        link = block(HOME, "private func link(_ cat: FamilyNotebookCatLink.Unlinked, to profile: String) {")
        self.assertNotIn("try?", link)
        self.assertIn("catch { linkFailed = true }", link)
        self.assertIn(".alert(FamilyNotebookWords.linkFailedTitle, isPresented: $linkFailed)", HOME)
        self.assertIn('static let linkFailedTitle = "つなげませんでした"', NOTEBOOK)
        self.assertIn('static let linkFailedMessage = "少し待ってから、もう一度お試しください。"', NOTEBOOK)

    def test_an_answer_is_kept_and_written_once(self):
        remember = block(NOTEBOOK, "func rememberLinkAnswer(_ cat: UUID, linked: Bool = false) {")
        self.assertIn("guard let key = answerKey(cat) else { return }", remember)
        self.assertIn("linkAnswers.remember(key, linked: linked)", remember)
        pending = block(NOTEBOOK, "func pendingLinkQuestion(profiles: [String]) -> FamilyNotebookCatLink.Unlinked? {")
        self.assertIn("closed: closedLinkQuestions", pending)
        unanswered = block(LINK, "static func firstUnanswered(")
        self.assertIn("!closed.contains(cat.id)", unanswered)
        # 「べつの子」 is remembered too (and kept in the Keychain); 「同じ子」 is not kept there.
        self.assertIn("familyNotebook.rememberLinkAnswer(question.cat.id)", HOME)
        link = block(NOTEBOOK, "func link(_ cat: UUID, toProfile profile: UUID) async throws {")
        self.assertIn("rememberLinkAnswer(cat, linked: true)", link)
        self.assertNotIn("rememberLinkAnswer(cat)" + chr(10), link)

    def test_answers_survive_deleting_the_app(self):
        # 11/20: a device-only Keychain copy, restored once per process before
        # any question is worked out (never while drawing).
        memory = read("NekoWidget/Services/FamilyNotebookKeyCoordinator.swift")
        self.assertIn('static let defaultsKey = "familyNotebook.catLinkAnswered.v1"', memory)
        self.assertIn("static let limit = 200", memory)
        refresh = block(NOTEBOOK, "private func refreshUnlinked() {")
        self.assertIn("linkAnswers.restore(checked: &linkAnswersChecked)", refresh)
        self.assertLess(refresh.index("linkAnswers.restore("), refresh.index("FamilyNotebookCatLink.unlinked("))

    def test_unlinked_cats_are_not_worked_out_while_drawing(self):
        self.assertIn("@Published private(set) var unlinkedCats: [FamilyNotebookCatLink.Unlinked] = []", NOTEBOOK)
        reload = block(NOTEBOOK, "private func reload() {")
        self.assertIn("refreshUnlinked()", reload)
        unlinked = block(NOTEBOOK, "var unlinkedFamilyCats: [FamilyNotebookCatLink.Unlinked] {")
        self.assertNotIn("FamilyNotebookCatLink.unlinked(", unlinked)


class Boundaries(unittest.TestCase):
    def test_the_notebook_items_and_sending_do_not_change(self):
        # The link is a local mapping: no field, no operation, no send.
        for word in ("profileLink", "linkedProfile", "sameCat"):
            self.assertNotIn(word, CORE)
        local = block(STORE, "func setLocalProfile(_ profile: UUID?, forFamilyCat cat: UUID) throws -> FamilyNotebookSnapshot {")
        self.assertNotIn("makeOperation", local)
        self.assertNotIn("outboxIDs", local)
        for word in ("URLSession", "SharingAutoCallBudget", "transport", "Transport"):
            self.assertNotIn(word, LINK)

    def test_name_alone_never_links(self):
        self.assertNotIn("sameName(", block(NOTEBOOK, "private func refreshUnlinked() {"))
        unlinked = block(LINK, "static func unlinked(")
        self.assertNotIn("name ==", unlinked)
        self.assertIn("mapping.profileID == nil", unlinked)

    def test_leaving_leaves_no_page_of_another_home(self):
        active = block(NOTEBOOK, "var activeFamilyCats: [FamilyCat] {")
        self.assertIn("return hasFamily ? familyCats : []", active)
        self.assertIn("let shared = familyNotebook.activeFamilyCats.filter { cat in", HOME)
        self.assertIn("guard !snapshot.sharingEnded else { return [] }", block(LINK, "static func unlinked("))

    def test_single_cat_rule_with_family_cats(self):
        single = block(IDENTITY, "var singleCatProfileID: UUID? {")
        self.assertIn("!CatSingleCatRule.familyCatsOutsideProfiles", single)
        self.assertIn("familyCatsOutsideProfiles: CatSingleCatRule.familyCatsOutsideProfiles", MODEL)
        switch = block(MODEL, "func setFamilyCatsOutsideProfiles(_ value: Bool) async {")
        self.assertIn("guard CatSingleCatRule.familyCatsOutsideProfiles != value else { return }", switch)
        self.assertIn("pinSingleCatPhotoBeforeAnotherProfile", switch)
        self.assertIn("familyNotebook.$unlinkedCats.map { !$0.isEmpty }.removeDuplicates()", ROOT_VIEW)


SHARING = read("NekoWidget/Services/FamilyNotebookSharing.swift")
BRIDGE = read("NekoWidget/Services/FamilyNotebookCatCareBridge.swift")
TABS = read("NekoWidget/Views/MainTabView.swift")


class ReadingTheFamily(unittest.TestCase):
    """11/16: what the joined iPhone wrote did not show on the creator's."""

    def test_one_way_to_save_for_every_family_cat(self):
        save = block(NOTEBOOK, "private func saveRealChanges(_ before: CatCareState, _ after: CatCareState) throws {")
        self.assertIn("FamilyNotebookCatCareBridge.localChanges(before, after, snapshot: snapshot)", save)
        self.assertIn("try store.applyLocalChanges(local.changes, author: writer())", save)
        changes = block(BRIDGE, "static func localChanges(")
        # Every cat of the notebook, linked or the family's own page.
        self.assertIn("compactMap(\\.toolCatID)", changes)
        self.assertNotIn("profileID", changes.split("let now")[0])

    def test_the_cat_pages_are_read_in_the_real_app(self):
        # The この子 tab of the app (MainTabView → CatHomeView).
        self.assertIn("NavigationStack {\n            toolsView\n        }", TABS)
        self.assertIn("CatHomeView(presentation: catProfilesPresentation", block(TABS, "private var toolsView: some View {"))
        self.assertIn(".familyNotebookToolSync(enabled: current.map { isFamilyCat(record(for: $0)) } ?? false)", HOME)
        self.assertIn("inFamilyNotebook: isFamilyCat(record),", HOME)
        page = block(HOME, "private struct CatHomePage: View {")
        self.assertIn(".familyNotebookPullToRead(enabled: inFamilyNotebook)", page)
        self.assertIn("lhs.inFamilyNotebook == rhs.inFamilyNotebook", HOME)
        # 「この子のこと」, wherever it opens from.
        detail = block(CARE, "struct CatCareDetailView: View {")
        self.assertIn(".familyNotebookPullToRead(enabled: sharedWithFamily)", detail)
        self.assertIn(".familyNotebookToolSync(enabled: sharedWithFamily)", detail)
        self.assertIn(".onChange(of: familyNotebook.familyWritesToCatCare) { _, _ in takeFamilyWrites() }", detail)

    def test_pulling_is_the_persons_one_read(self):
        pulled = block(SHARING, "func readPulled() async {")
        self.assertIn("guard FamilyNotebookPrototype.shared.isReal, FamilyNotebookPrototype.shared.hasFamily else { return }", pulled)
        self.assertIn("SharingPersonAction.run", pulled)
        modifier = block(NOTEBOOK, "private struct FamilyNotebookPullToRead: ViewModifier {")
        self.assertIn("content.refreshable { await FamilyNotebookSharing.shared.readPulled() }", modifier)
        # Nothing to pull outside the family; no words, no button.
        self.assertIn("} else {\n            content\n        }", modifier)
        self.assertNotIn("Text(", modifier)
        self.assertNotIn("Button", modifier)

    def test_writing_here_is_sent_soon_by_the_one_schedule(self):
        self.assertIn("func sendSoon() { wake(gap: FamilyAutoCheckPolicy.sendGap) }", SHARING)
        observer = NOTEBOOK.split("notebookObserver = NotificationCenter.default.addObserver(", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("queue: nil", observer)
        self.assertIn("Task { @MainActor in", observer)
        self.assertIn("self.snapshot?.outbox.isEmpty == false", observer)
        self.assertIn("FamilyNotebookAutoCheck.shared.sendSoon()", observer)
        # No loop of its own.
        self.assertEqual(SHARING.count("Task.sleep(for: .seconds(delay))"), 1)
        # Written, then the iPhone locked at once: one automatic pass on leaving.
        self.assertIn("else { loop?.cancel(); loop = nil; sleeping = false; sendBeforeLeaving() }", SHARING)
        leaving = block(SHARING, "private func sendBeforeLeaving() {")
        self.assertIn("model.snapshot?.outbox.isEmpty == false", leaving)
        self.assertIn("SharingPersonAction.automatic", leaving)
        self.assertIn("beginBackgroundTask", leaving)

    def test_a_closed_notebook_does_not_hold_the_reads(self):
        self.assertIn(".onDisappear { FamilyNotebookAutoCheck.shared.holdsRedraw = false }", NOTEBOOK)



SYNC = read("NekoWidget/Services/FamilyNotebookSync.swift")
SERVICE = read("NekoWidget/Services/ProductionFamilyNotebookSharingService.swift")
SETTINGS = read("NekoWidget/Views/SettingsView.swift")


class SendingFailures(unittest.TestCase):
    """11/16: the joined iPhone's writing never reached the server, without a trace."""

    def test_a_failure_to_send_is_kept_not_dropped(self):
        loop = SYNC.split("for operation in try store.pendingOperations().filter({ !aside.contains($0.id) }).prefix(64) {", 1)[1]
        loop = loop.split("heldBack = aside.count", 1)[0]
        self.assertIn("} catch {", loop)
        self.assertIn("== .setAside else { throw error }", loop)
        self.assertIn("aside.insert(operation.id)", loop)
        # The service keeps the kind before the screens' error replaces it.
        self.assertIn("lastSend = .failed(FamilyNotebookSendFailure.kind(of: error).rawValue)", SERVICE)
        self.assertIn("throw error", SERVICE.split("lastSend = .failed(", 1)[1][:200])
        read_block = block(SHARING, "private func read(reportsFailure: Bool) async -> Bool {")
        self.assertIn("noteSend(); notedSend = true", read_block)
        self.assertIn("if !notedSend { noteSend() }", read_block)

    def test_only_the_kind_and_time_are_kept(self):
        failure = block(SYNC, "struct Failure: Codable, Equatable, Sendable {")
        self.assertIn("let kind: String", failure)
        self.assertIn("let at: Date", failure)
        self.assertEqual(failure.count("let "), 2)
        self.assertIn('"op:fnb-held:" + familyID.uuidString.lowercased()', SYNC)
        self.assertIn("JSONEncoder().encode(sorted)", SYNC)

    def test_the_line_and_its_one_button(self):
        notebook = block(NOTEBOOK, "private func notebook(_ membership: FamilyMembership?) -> some View {")
        self.assertIn("} else if sharing.showsUnsentLine {\n                unsentSection", notebook)
        section = block(NOTEBOOK, "private var unsentSection: some View {")
        self.assertIn('Label("家族に届けられていない書き込みがあります。"', section)
        self.assertIn('WorkingLabel(title: "もう一度", workingTitle: "もう一度", working: resending)', section)
        self.assertIn("await sharing.resendUnsent()", section)
        words = {w for w in __import__("re").findall(r'"([^"]*)"', section) if any(ord(c) > 127 for c in w)}
        self.assertEqual(words, {"家族に届けられていない書き込みがあります。", "もう一度", "コード："})
        # The code only when asked: the line held, or もう一度 did not get it sent.
        self.assertIn(".onLongPressGesture { showsSendCode = true }", section)
        self.assertIn("if sharing.showsUnsentLine { showsSendCode = true }", section)
        self.assertIn('Text("コード：" + sharing.sendCode)', section)
        self.assertIn("FamilyNotebookSendFailure.code(kind: sendHealth.last?.kind, unsent: unsentCount)", SHARING)

    def test_own_writing_not_sent_has_a_mark_without_words(self):
        note = block(NOTEBOOK, "struct FamilyNotebookNote: ViewModifier {")
        self.assertIn("} else if FamilyNotebookNote.waitsToBeSent(state, now: Date()) {", note)
        self.assertIn('Image(systemName: "icloud.slash")', note)
        self.assertIn("state.status == .pendingShared && now.timeIntervalSince(state.operation.editedAt) > 60", note)
        self.assertNotIn("Text(", note)
        resend = block(SHARING, "func resendUnsent() async {")
        self.assertIn("SharingPersonAction.run", resend)
        self.assertIn("retriesHeldOnce = true", resend)
        self.assertIn("let retryHeld = retriesHeldOnce", SERVICE)
        self.assertIn("retryHeld: retryHeld", SERVICE)

    def test_the_kind_shows_in_internal_builds_only(self):
        start = NOTEBOOK.index("private var sendDiagnosticsSection: some View {")
        before = NOTEBOOK[:start]
        self.assertTrue(before.rstrip().splitlines()[-3].strip().startswith("#if DEBUG || INTERNAL_PRESENTATION"))
        self.assertIn("#if DEBUG || INTERNAL_PRESENTATION\n            if model.isReal { sendDiagnosticsSection }", NOTEBOOK)

    def test_the_notebook_opens_from_the_app(self):
        self.assertIn(".sheet(isPresented: $showsFamilyNotebook) { FamilyNotebookView() }", ROOT_VIEW)
        self.assertIn(".sheet(isPresented: $showsFamilyNotebook) { FamilyNotebookView() }", SETTINGS)
        self.assertIn(".familyNotebookOpeningCheck()", ROOT_VIEW)

if __name__ == "__main__":
    unittest.main()
