#!/usr/bin/env python3
"""11/23a: the inspection 「出しすぎと手順」, the fixes the owner approved.
Too much on screen: the album shelf and its book pages, the field counter,
「この子のこと」's notes, the 自動保存 screen while off. Too many steps: まどに
届ける, the lost-cat contact, the family notebook's invitation. (The 病院 and
体重 rows of the この子 tab are pinned in ci/test-cat-home-care.py.) Source pins."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


ALBUM = read("NekoWidget/Views/AlbumPrototypeView.swift")
PARTS = read("NekoWidget/Views/ToolRowParts.swift")
CARE = read("NekoWidget/Views/CatCareView.swift")
LOST = read("NekoWidget/Views/CatPreparednessView.swift")
MANAGED = read("NekoWidget/Views/ManagedPreservationView.swift")
NOTE = read("NekoWidget/Views/PhotoNoteInput.swift")
SAVE = read("NekoWidget/Services/AppRecordPersistence.swift")
WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")


class AlbumTests(unittest.TestCase):
    def test_the_shelf_leaves_out_the_cover_month_and_past_works_wait(self):
        shelf = section(ALBUM, "    private var yearShelf: some View {", "    private static let slotSize")
        self.assertIn("ForEach((1...12).filter { $0 != leadMonth }, id: \\.self) { month in", shelf)
        self.assertIn("let leadMonth = heroYear == nil ? letters.first.flatMap", shelf)
        # 「これまでの作品」 only with a work the cover and the shelf do not show.
        self.assertIn("if hasPastWorks {", shelf)
        self.assertIn("letters.contains { $0.yearNumber != year } || !pastYears.isEmpty || !movies.isEmpty", shelf)
        self.assertIn('.accessibilityIdentifier("album-prototype-shelf")', shelf)

    def test_a_book_has_no_title_or_page_count_on_top_of_its_cover(self):
        self.assertNotIn('Text(verbatim: "\\(letter.monthNumber)月の作品")\n                        .font(.system(.footnote', ALBUM)
        self.assertNotIn('Text(verbatim: "\\(year)年の作品")\n                        .font(.system(.footnote', ALBUM)
        number = section(ALBUM, "struct BookPageNumber: View {", "\n}\n")
        # Not drawn; still VoiceOver's handle for turning.
        self.assertIn(".foregroundStyle(.clear)", number)
        self.assertIn(".accessibilityAdjustableAction", number)


class FieldCountTests(unittest.TestCase):
    def test_one_rule_past_eight_tenths(self):
        rule = section(PARTS, "enum FieldCount {", "\n}\n")
        self.assertIn("static func isShown(_ count: Int, limit: Int) -> Bool { count * 10 > limit * 8 }", rule)
        counter = section(PARTS, "struct ToolFieldCounter: View {", "enum FieldCount {")
        self.assertIn("if FieldCount.isShown(count, limit: limit) {", counter)
        for source, call in ((LOST, "FieldCount.isShown(text.wrappedValue.count, limit: limit)"),
                             (LOST, "FieldCount.isShown(message.count, limit: LostCatText.foundMessageLimit)"),
                             (MANAGED, "FieldCount.isShown(coordinator.editedText.count, limit: 500)"),
                             (NOTE, "FieldCount.isShown(text.count, limit: maximumCharacters)")):
            self.assertIn(call, source)


class CatCareTests(unittest.TestCase):
    def test_the_date_note_only_before_a_date(self):
        footer = section(CARE, "    private var basicsFooter: String {", "    // MARK: Rows")
        self.assertIn("profile.lifeReference != nil || !hasLifeDate", footer)
        self.assertIn("private var hasLifeDate: Bool {", footer)

    def test_no_summary_line_or_check_mark(self):
        self.assertNotIn("summaryLine", CARE)
        header = section(CARE, "private func partHeader(", "private static func rowLabel(")
        self.assertNotIn("checkmark", header)

    def test_shared_household_note_with_two_cats(self):
        household = section(CARE, "private var householdSection: some View {", "private var vetPicker: some View {")
        self.assertIn('if catCount >= 2 { Text("ほかの猫とも共通です。") }', household)


class AutosaveOffTests(unittest.TestCase):
    def test_export_and_account_wait_for_something_saved(self):
        sections = section(SAVE, "@ViewBuilder private var settingsSections: some View {", "if let profileTransfer {")
        self.assertIn("authentication.accountDeletionState == nil && hasSavedSomething {", sections)
        self.assertIn("if (authentication.isSignedIn && hasSavedSomething) || authentication.accountDeletionState != nil {",
                      sections)
        saved = section(SAVE, "private var hasSavedSomething: Bool {", "\n    }\n")
        for part in ("persistence.enabled", "startedHere", "plusEnded", "authentication.membership?.linked == true",
                     "(authentication.usage?.productQuota?.usage?.records.saved ?? 0) > 0"):
            self.assertIn(part, saved)
        self.assertIn("func hasStartedHere() -> Bool {", SAVE)


class DeliveryTests(unittest.TestCase):
    def test_done_closes_by_itself(self):
        step = section(WINDOW, "private struct GroupLibraryDeliveryStep: View {", "private struct GroupLibraryDeliveryChosenWindow: View {")
        task = section(step, ".task(id: model.sendCompleted) {", "\n        }\n")
        self.assertIn("guard model.sendCompleted, !UIAccessibility.isVoiceOverRunning else { return }", task)
        self.assertIn("try? await Task.sleep(for: .milliseconds(1200))", task)
        self.assertIn("close()", task)
        # 「閉じる」 stays.
        self.assertIn('Button("閉じる", action: close).buttonStyle(.borderedProminent)', step)

    def test_the_last_window_is_chosen_with_two_or_more(self):
        sheet = section(WINDOW, "struct GroupLibraryDeliverySheet: View {", "enum GroupLibraryDeliveryMemory {")
        choose = section(sheet, "private func chooseLastWindow() {", "var body: some View {")
        self.assertIn("openWindows.count > 1, path.isEmpty", choose)
        self.assertIn("path = [last]", choose)
        self.assertIn("!choseLastWindow", choose)
        # Called after the last list is shown and after it is read again.
        self.assertEqual(sheet.count("chooseLastWindow()\n"), 2)


class LostContactTests(unittest.TestCase):
    def test_the_contact_starts_filled_and_stays_the_persons(self):
        contact = section(LOST, "private func fillContact(", "private func catCareTarget(")
        self.assertIn("guard draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,", contact)
        self.assertIn('!stamped.editedBy.hasPrefix("import:")', contact)
        load = section(LOST, "private func load(_ identity:", "private func switchTo(")
        self.assertIn("saved = fillContact(saved, key: identity)", load)


class NotebookInviteTests(unittest.TestCase):
    def test_a_new_notebook_opens_its_invitation(self):
        self.assertIn("invitesAfterCreate = true", NOTEBOOK)
        task = section(NOTEBOOK, ".task(id: invitesAfterCreate && model.hasFamily", "\n        }\n")
        self.assertIn("!puttingInStartingCat", task)
        self.assertIn("shownMembership?.canInvite == true", task)
        self.assertIn("invites = true", task)


if __name__ == "__main__":
    unittest.main()
