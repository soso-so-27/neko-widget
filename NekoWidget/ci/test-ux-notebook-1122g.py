"""11/22 (A6): 家族の手帳's way in, and its first state.

- The entrance is the last row of the cat's card on この子 (after
  「この子のこと」), not a button in the bar of 「この子のこと」 (one place;
  nobody found the button). 設定 keeps its row for a notebook that exists.
- The row's value is only a state already in memory, nothing before a
  notebook; it is in the card, so with no cat there is no row.
- A notebook made from a cat's page starts with that cat, through the
  chooser's own path (sharePersonalCats), after creating succeeds.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


HOME_CARE = read("NekoWidget/Views/CatHomeCareView.swift")
CARE = read("NekoWidget/Views/CatCareView.swift")
DETAIL = read("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")
SETTINGS = read("NekoWidget/Views/SettingsView.swift")
REVIEW_UI = read("NekoWidgetUITests/ReviewScreenshotUITests.swift")


class Entrance(unittest.TestCase):
    def test_row_after_this_cat_in_the_card(self):
        card = section(HOME_CARE, "struct CatHomeCareCard: View {", "private struct Entry {")
        about = card.index('CatHomeCareRow(title: "この子のこと", value: nil)')
        self.assertLess(about, card.index("CatHomeFamilyNotebookRow(cat: links.cat)"))
        row = section(HOME_CARE, "private struct CatHomeFamilyNotebookRow: View {", "/// A row like 設定's")
        self.assertIn('CatHomeCareRow(title: "家族の手帳", value: value)', row)
        self.assertIn('.accessibilityIdentifier("cat-home-care-family-notebook")', row)
        self.assertIn("if Version1.familyNotebook || model.hasFamily || awaitsApproval {", row)
        self.assertIn("FamilyNotebookView(startingCat: subject)", row)
        # Nothing before a notebook; nothing stored (the card's own rule).
        self.assertIn("return awaitsApproval ? CatHomeCareCore.Value(text: \"待っています\") : nil", row)
        self.assertIn("sharing.state == .pendingApproval", row)

    def test_no_button_in_the_bar_of_this_cats_page(self):
        for text in (CARE, DETAIL, NOTEBOOK):
            self.assertNotIn("FamilyNotebookButton", text)
            self.assertNotIn("cat-care-family-notebook", text)
        # 設定 keeps its row (the place to manage a notebook that exists).
        self.assertIn('.accessibilityIdentifier("settings-family-notebook")', SETTINGS)
        self.assertIn(".sheet(isPresented: $showsFamilyNotebook) { FamilyNotebookView() }", SETTINGS)

    def test_review_capture_opens_it_from_the_row(self):
        self.assertIn('["cat-home-care-family-notebook"]', REVIEW_UI)
        self.assertNotIn("cat-care-family-notebook", REVIEW_UI)


class FirstCat(unittest.TestCase):
    def test_the_cat_goes_in_after_creating_succeeds(self):
        view = section(NOTEBOOK, "struct FamilyNotebookView: View {", "/// Who is in the family, and what they wrote lately")
        self.assertIn("var startingCat: CatCareSubject? = nil", view)
        created = section(view, "FamilyNotebookNameView {", ".sheet(isPresented: $showsCats)")
        self.assertLess(created.index("if await sharing.perform({ try await sharing.service.createFamily(operationID: $0) }) {"),
                        created.index("putsInStartingCat = startingCat != nil"))
        self.assertIn(".task(id: putsInStartingCat && model.hasFamily) {", view)
        put = section(view, "private func putIn(_ subject: CatCareSubject) async {", "\n    }\n")
        # The chooser's own path, only once real sharing is on, never twice.
        self.assertIn("try await model.sharePersonalCats([record.catID])", put)
        self.assertIn("CatCareStore.shared.ensureRecord(for: subject)", put)
        self.assertIn("!model.familyCats.contains(where: { $0.toolID == record.catID })", put)
        self.assertIn("guard model.isReal, CatCareStore.shared.canSave,", put)
        # A failure leaves the notebook as made: no undo, no alert.
        self.assertNotIn("endPrototypeFamily", put)
        self.assertNotIn("failure =", put)
        # The chooser is unchanged and still the way to add cats.
        self.assertIn('Label("手帳に入れる猫を選ぶ", systemImage: "checklist")', NOTEBOOK)
        self.assertIn("if !rest.isEmpty { try await model.sharePersonalCats(rest) }", NOTEBOOK)


if __name__ == "__main__":
    unittest.main()
