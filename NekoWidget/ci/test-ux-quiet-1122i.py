"""11/22 (quieter screens): what a screen shows only when it is needed.

1. The tools' top: no sentence of what the page makes and no 「書き始めた日」;
   the cat's name only with two or more cats and no cat menu in the bar
   (ToolCatNameHeader, one shared rule).
2. An empty row shows nothing at the side (no 「未記入」, no 「なし」 for
   nothing added); VoiceOver still hears the word. Choices in 「この子のこと」
   show only ⌃⌄ until one is chosen (ToolChoiceRow).
3. 「この子のこと」 has no progress ring line at the top.
4. 病院で見せる: no footer under 「新しい診察メモを始める」; the notes stay.
5. The same name for the same thing: 「この子のこと」 in 預ける and 避難,
   「PDFで渡す」, 「避難メモを作る」.
6. 避難: one checklist, on 「いま避難する」, with everything 「持ち出すもの」
   had (saved checks, 期限, 最後に見直した日, editing, starting over).
7. No 「1 / 8」 under the photo's date; 「使う写真」 and 「出さない写真」.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


PARTS = read("NekoWidget/Views/ToolRowParts.swift")
CARE_VIEW = read("NekoWidget/Views/CatCareView.swift")
VET = read("NekoWidget/Views/VeterinaryVisitView.swift")
HANDOFF = read("NekoWidget/Views/CareHandoffView.swift")
LOST = read("NekoWidget/Views/CatPreparednessView.swift")
EVAC = read("NekoWidget/Views/EvacuationPreparationView.swift")
BROWSER = read("NekoWidget/Views/LikedPhotosView.swift")
SETTINGS = read("NekoWidget/Views/SettingsView.swift")
CURATION = read("NekoWidget/Views/CatCandidateCurationView.swift")
STORE = read("NekoWidget/Services/EvacuationStore.swift")
PLAN = read("NekoWidget/Services/EvacuationPlan.swift")
REVIEW_UI = read("NekoWidgetUITests/ReviewScreenshotUITests.swift")
PERMISSION_UI = read("NekoWidgetUITests/PhotoPermissionUITests.swift")

ALL_VIEWS = (CARE_VIEW, VET, HANDOFF, LOST, EVAC)


class ToolTop(unittest.TestCase):
    def test_no_purpose_sentence_anywhere(self):
        for text in ALL_VIEWS:
            self.assertNotIn("ToolPurpose", text)
        for sentence in ("先生に見せる診察メモを作ります。", "預ける人に渡すお世話メモを作ります。",
                         "探すためのチラシを作ります。", "災害のときに持ち出すものと、猫の避難メモを用意します。",
                         "持ち物を確かめて、猫と一緒に避難します。", "避難所で見せる、この子の避難メモを作ります。"):
            for text in ALL_VIEWS:
                self.assertNotIn(sentence, text)

    def test_one_rule_for_the_name(self):
        header = section(PARTS, "struct ToolCatNameHeader: View {", "/// A choice in a row")
        self.assertIn("catCount >= 2 && !menuInBar", header)
        self.assertIn("if name != nil || detail != nil {", header)
        self.assertIn('Label(name, systemImage: "cat")', header)
        # Every row-list tool uses it, with the app's cats as the count.
        self.assertIn("showsCatName: ToolCatNameHeader.showsName(catCount: profiles.count, menuInBar: menuInBar),", VET)
        self.assertIn("showsName: ToolCatNameHeader.showsName(catCount: profiles.count, menuInBar: !menuHidden),", HANDOFF)
        self.assertIn("ToolCatNameHeader(name: ToolCatNameHeader.showsName(catCount: profiles.count, menuInBar: !menuHidden)", LOST)
        menu = section(VET, "private var menuInBar: Bool {", "private var menuName: String {")
        self.assertIn("guard fixedStripCat == nil else { return false }", menu)
        self.assertIn(".count > 1", menu)

    def test_vet_keeps_only_the_finished_mark(self):
        self.assertNotIn("書き始めた日", VET)
        self.assertNotIn('"vet-started-day"', VET)
        header = section(VET, "@ViewBuilder private func headerSections(", "// MARK: Rows (11/12)")
        self.assertIn('detail: visit.completedAt != nil ? "診察済み" : nil)', header)


class EmptyRows(unittest.TestCase):
    def test_value_row_hides_the_empty_word_and_speaks_it(self):
        row = section(PARTS, "struct ToolValueRow: View {", "/// The word an empty row no longer shows")
        self.assertIn("ToolEmptyValue.isEmptyMarker(value, filled: filled, problem: problem) ? nil : value", row)
        self.assertIn("if let side {", row)
        self.assertIn(".modifier(ToolEmptyValueSpoken(word: side == nil ? value : nil))", row)
        words = section(PARTS, "enum ToolEmptyValue {", "\n}\n")
        self.assertIn("!filled && !problem && (value == unwritten || value == none)", words)
        spoken = section(PARTS, "struct ToolEmptyValueSpoken: ViewModifier {", "\n}\n")
        self.assertIn("content.accessibilityValue(word)", spoken)

    def test_counts_and_answers_stay(self):
        # A count and a chosen answer are filled, so they are shown.
        self.assertIn('return ("\\(ready) / \\(needed.count)", true, false)', EVAC)
        self.assertIn('value: "\\(pastVisits.count + detachedPhotos.count)件", filled: true)', VET)
        self.assertIn('filled: choice != .unknown, problem: issues["collar"] != nil)', LOST)
        self.assertIn('Text(verbatim: over ? "長すぎます', PARTS)

    def test_choices_show_only_the_chevrons_until_chosen(self):
        choice = section(PARTS, "struct ToolChoiceRow<Value: Hashable>: View {", "/// The words a row shows")
        self.assertIn("if chosen {", choice)
        self.assertIn('Image(systemName: "chevron.up.chevron.down")', choice)
        self.assertIn(".accessibilityValue(chosen ? current : ToolEmptyValue.unset)", choice)
        self.assertIn(".pickerStyle(.inline)", choice)
        for identifier in ("cat-care-sex", "cat-care-neutered", "cat-care-indoor", "cat-care-microchip-status",
                           "cat-care-conditions-status", "cat-care-allergy-status", "cat-care-vet-status"):
            self.assertIn(f'.accessibilityIdentifier("{identifier}")', CARE_VIEW)
        self.assertEqual(CARE_VIEW.count("ToolChoiceRow(title: "), 7)
        self.assertNotIn("Picker(selection: $draft.", CARE_VIEW)
        self.assertNotIn("choiceTint", CARE_VIEW)

    def test_evacuation_cat_page_has_no_empty_words(self):
        self.assertNotIn("特徴は未記入", EVAC)
        self.assertIn("if let features = CatCareSummary.features(catCareRecord(cat), legacy: cat.features) {", EVAC)
        self.assertIn('if cat.photos["withOwner"] != nil { Text("あり") }', EVAC)


class CatCareTop(unittest.TestCase):
    def test_no_ring_line(self):
        detail = section(CARE_VIEW, "struct CatCareDetailView: View {", "/// A written item of 「この子のこと」")
        self.assertNotIn("progressSection", detail)
        self.assertNotIn('"cat-care-next-hint"', detail)
        self.assertNotIn("CatCareRing(", detail)
        # The tools' row keeps saying what each tool still needs.
        folded = section(CARE_VIEW, "private func foldedLabel(", "@ViewBuilder")
        self.assertIn('"あと\\(missing.count)つ"', folded)


class VetNotes(unittest.TestCase):
    def test_footer_gone_and_notes_kept(self):
        self.assertNotIn("始めると、いまのメモは「これまでの診察メモ」に入ります。", VET)
        self.assertIn("飼い主の記録をまとめたもので、医療の判断ではありません。", VET)
        self.assertIn('ToolImportantInformation(text: "災害のときは、まず自分と家族の安全を守ってください。")', EVAC)
        # VoiceOver still hears where the memo went.
        self.assertIn('AccessibilityNotification.Announcement("いまのメモは、これまでの診察メモに入りました").post()', VET)


class SameNames(unittest.TestCase):
    def test_this_cat_is_named_once(self):
        self.assertNotIn('Text("この子について")', HANDOFF)
        self.assertIn('ToolCatCareSection(title: "この子のこと"', HANDOFF)
        hub = section(EVAC, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        self.assertIn('ToolValueRow(title: "この子のこと", systemImage: "cat", value: catsState,', hub)
        self.assertNotIn('"猫の情報"', EVAC)
        self.assertEqual(EVAC.count('.navigationTitle("この子のこと")'), 3)

    def test_pdf_buttons(self):
        book = section(EVAC, "private var bookButton: some View {", "private struct EvacuationSaveNotice")
        self.assertIn('Label("避難メモを作る", systemImage: "doc.text")', book)
        self.assertIn('WorkingLabel(title: "避難メモを作る"', book)
        display = section(EVAC, "private struct EvacuationDisplayView: View {", "private struct EvacuationActivitySheet")
        self.assertIn('Label("PDFで渡す", systemImage: "doc.richtext")', display)
        self.assertIn('Label("画像で渡す", systemImage: "photo")', display)
        self.assertIn('"PDFを作って渡す" : "画像を作って渡す"', display)
        self.assertNotIn('Label("印刷用のPDF', EVAC)


class OneChecklist(unittest.TestCase):
    def test_hub_has_no_second_list(self):
        hub = section(EVAC, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        self.assertNotIn('"evacuation-packing-open"', EVAC)
        self.assertNotIn("EvacuationPackingView", EVAC)
        self.assertEqual(hub.count("ToolValueRow(title:"), 2)
        # The list's state sits at the side of 「いま避難する」, so 期限 still shows on the hub.
        now_row = section(hub, 'NavigationLink { EvacuationNowView(profiles: profiles, store: store) } label: {',
                          '.accessibilityIdentifier("evacuation-now-open")')
        self.assertIn("EvacuationChecklistState(state: packingState)", now_row)
        state = section(EVAC, "private struct EvacuationChecklistState: View {", "\n}\n")
        self.assertIn("if !ToolEmptyValue.isEmptyMarker(state.value, filled: state.filled, problem: state.problem) {", state)
        self.assertIn("state.problem ? Color.red : Color.secondary", state)
        # The half-year review opens the one checklist.
        self.assertIn(".navigationDestination(isPresented: $openPacking) { EvacuationNowView(profiles: profiles, store: store) }", EVAC)

    def test_now_has_everything_the_list_had(self):
        now = section(EVAC, "private struct EvacuationNowView: View {", "/// 環境省「人とペットの災害対策ガイドライン」")
        for needle in ("store.update { $0.toggleCarried(item.id) }",
                       "store.plan.carriedIDs.contains(item.id)",
                       "EvacuationExpiryLine(item: item)",
                       'Text("最後に見直した日：',
                       'NavigationLink("リストと置き場所を編集") { EvacuationSuppliesEditor(store: store) }',
                       'Button("チェックをやり直す") { resetRequested = true }',
                       "store.update { $0.clearChecks() }",
                       '.task { store.followCatsAndMedicines() }',
                       '"evacuation-now-count"',
                       '.toolChrome()'):
            self.assertIn(needle, now)
        self.assertNotIn("takenIDs", now)
        # Saved data is untouched: the checks and items are the plan's own.
        self.assertIn("var carriedIDs: Set<UUID> = []", PLAN)
        self.assertIn("@Published var takenIDs: Set<UUID> = []", STORE)

    def test_ui_tests_follow(self):
        self.assertNotIn('"evacuation-packing-open"', REVIEW_UI + PERMISSION_UI)
        self.assertIn('app.buttons["evacuation-supplies-edit"]', REVIEW_UI)
        self.assertIn('"evacuation-now-supply-"', PERMISSION_UI)
        self.assertIn('app.buttons["PDFを作って渡す"]', PERMISSION_UI)


class PhotoScreens(unittest.TestCase):
    def test_no_position_under_the_date(self):
        title = section(BROWSER, "private func titleDate(_ photo: PhotoPresentation) -> some View {", "\n    }\n")
        self.assertNotIn('"photo-browser-position"', title)
        self.assertNotIn("detail.joined", title)
        self.assertIn('.accessibilityHint([context, position].compactMap { $0 }.joined(separator: "、"))', title)

    def test_photo_settings_names(self):
        self.assertIn('LabeledContent("使う写真", value: sourceSummary)', SETTINGS)
        self.assertIn('"出さない写真",', SETTINGS)
        self.assertIn('.navigationTitle("使う写真")', CURATION)
        self.assertIn('.navigationTitle(showsSourceSettings ? "写真の整理" : "出さない写真")', CURATION)
        for text in (SETTINGS, CURATION, BROWSER):
            self.assertNotIn("写真の対象", text)
            self.assertNotIn("「外した写真」", text)
        self.assertIn('app.navigationBars["使う写真"]', PERMISSION_UI)
        self.assertIn('app.navigationBars["出さない写真"]', PERMISSION_UI)


if __name__ == "__main__":
    unittest.main()
