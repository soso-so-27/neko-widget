"""Source contracts for the 「この子」 page's 「これからのこと」 (approved 11/14,
「猫を大切にできるページ」).

The page is only what helps take care of the cat: the hero, the five round
buttons, one card 「これからのこと」 with four rows always in this order
(誕生日, ワクチン, 病院, 体重), and 「この子のこと」 as its last row with no count
(11/14: was a box of its own; the card is that row alone for a departed cat
or one with nothing to show). The name on the photo is the cat menu, so the
name is not shown twice.
The photos, 「1年前のきょう」 and the list of past records left the page.
Every value is read from what is already in memory; nothing is stored and no
schedule is worked out. Native behaviour of the words and boundaries:
NekoWidgetTests CatHomeCareTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


HOME = read("NekoWidget/Views/CatHomeView.swift")
VIEW = read("NekoWidget/Views/CatHomeCareView.swift")
CORE = read("NekoWidget/Views/CatHomeCareCore.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
VET = read("NekoWidget/Views/VeterinaryVisitView.swift")
FIXTURE = read("NekoWidget/App/AppStoreScreenshotFixture.swift")
REVIEW = read("NekoWidgetUITests/ReviewScreenshotUITests.swift")
STORE_SHOTS = read("NekoWidgetUITests/AppStoreScreenshotUITests.swift")
COLLECT = read("ci/collect-review-screenshots.py")
QUICK = read("ci/run-quick-ios-checks.sh")
PROJECT = read("NekoWidget.xcodeproj/project.pbxproj")
TESTS = read("NekoWidgetTests/CatHomeCareTests.swift")


def block(source, marker):
    if source.count(marker) != 1:
        raise AssertionError(f"Expected one {marker!r}")
    start = source.index(marker)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker!r}")


class PageOrder(unittest.TestCase):
    def test_card_sits_under_the_buttons_with_the_about_row_inside(self):
        page = block(HOME, "private struct CatHomePage: View {")
        order = ["CatHomeToolBar(", "if searching { CatHomeSearchingLine(cat: cat) }",
                 "CatHomeCareCard(rows: care, links: careLinks)"]
        self.assertEqual([page.index(item) for item in order], sorted(page.index(item) for item in order))
        # 11/14: no box of its own under the card; the card is there for
        # every cat (a departed cat's card is 「この子のこと」 alone).
        self.assertNotIn("CatHomeAboutCard", HOME)
        self.assertNotIn("if let care { CatHomeCareCard(", page)
        self.assertIn("carePage: AnyView(carePage(cat))", HOME)
        self.assertLess(page.index("if !facts.departed {"), page.index("CatHomeToolBar("))
        self.assertIn(".padding(.bottom, 32)", page)
        # The top controls still scroll with the hero.
        self.assertIn(".overlay(alignment: .top) { topBar.padding(.top, metrics.topInset) }", page)

    def test_departed_cats_have_no_card(self):
        care = block(HOME, "private func care(for cat: CatHomeCat, record: CatCareRecord?, facts: CatHomeFacts)")
        self.assertIn("guard !facts.departed else { return nil }", care)
        self.assertIn("vetMemos: states.vetMemos(for: cat, record: record)", care)

    def test_removed_blocks_are_gone(self):
        for source in (HOME, VIEW, CORE):
            for gone in ("CatHomeRecords", "CatHomeYearsAgo", "CatHomePhotoStrip", "CatHomeBirthdayCard",
                         "yearsAgo", "PhotoMemoryNoteStore", "profilePhotos", "もっと見る", "さいきんの写真",
                         "1年前のきょう", "birthdaySoonDays", "progressText"):
                self.assertNotIn(gone, source, gone)
        for identifier in ('"cat-home-birthday"', '"cat-home-years-ago"', '"cat-home-photos"', '"cat-home-records"',
                           '"cat-home-records-more"', '"cat-home-photos-all"'):
            self.assertNotIn(identifier, HOME + VIEW + REVIEW)
        tools = block(HOME, "struct CatHomeTools {")
        for gone in ("showPhotos", "memoPhoto", "vetMemo"):
            self.assertNotIn(gone, tools)
        self.assertNotIn("openPhotoLibrary(for:", MAIN)
        self.assertNotIn("VeterinaryPastVisitSheet", MAIN + VET)


class Card(unittest.TestCase):
    def test_four_rows_always_in_this_order_with_identifiers(self):
        entries = block(VIEW, "private var entries: [Entry] {")
        order = ['id: "birthday", title: "誕生日"', 'id: "vaccine", title: "ワクチン"',
                 'id: "vet", title: "病院"', 'id: "weight", title: "体重"']
        self.assertEqual([entries.index(item) for item in order], sorted(entries.index(item) for item in order))
        card = block(VIEW, "struct CatHomeCareCard: View {")
        # 11/14: no heading. With real data most rows read 「前回…」.
        self.assertNotIn('Text("これからのこと")', card)
        self.assertNotIn('.isHeader', card)
        self.assertIn('.accessibilityIdentifier("cat-home-care")', card)
        self.assertIn('.accessibilityIdentifier("cat-home-care-" + entry.id)', card)
        self.assertIn("guard let rows else { return [] }", block(VIEW, "private var entries: [Entry] {"))

    def test_rows_are_settings_rows_without_icons(self):
        row = block(VIEW, "private struct CatHomeCareRow: View {")
        self.assertIn("ToolChevron()", row)
        self.assertNotIn("Image(systemName:", row)
        self.assertIn("typeSize.isAccessibilitySize", row)
        self.assertIn("case .quiet: Color.secondary", row)
        self.assertIn("case .soon: Color.primary", row)
        self.assertIn("case .unfinished: Color.orange", row)

    def test_each_row_opens_where_it_is_written(self):
        link = block(VIEW, "@ViewBuilder private func link(_ entry: Entry) -> some View {")
        self.assertIn("Button { editsDates = true } label: { row }", link)
        self.assertIn("NavigationLink(value: CatHomeRoute(tool: .vet, catID: links.cat.id)) { row }", link)
        self.assertIn('CatHomeCareListPage(kind: entry.id == "weight" ? .weight : .vaccination, catID: catID)', link)
        self.assertIn("NavigationLink { links.carePage } label: { row }", link)
        card = block(VIEW, "struct CatHomeCareCard: View {")
        self.assertIn("CatProfileLifeReferenceEditor(profile: profile, save: links.saveLifeDates)", card)
        self.assertIn("saveLifeDates: actions.updateLifeDates", HOME)

    def test_which_cats_get_which_rows(self):
        make = block(VIEW, "static func make(hasProfile: Bool, record: CatCareRecord?, birthday: CatCareDay?,")
        self.assertIn("guard hasProfile || record != nil else {", make)
        self.assertIn("return vetMemos.isEmpty ? nil : CatHomeCareRows(vet: vet)", make)

    def test_the_vet_state_has_one_place(self):
        button = block(HOME, "private struct CatHomeToolButton: View {")
        self.assertNotIn(".fill(state.color)", button)
        self.assertIn('.accessibilityLabel(state.map { "\\(tool.title)、\\($0.text)" } ?? tool.title)', button)
        bar = block(HOME, "private struct CatHomeToolBar: View {")
        self.assertIn('if tool == .vet && vetUnfinished { return (text: "書きかけ", color: Color.orange) }', bar)

    def test_about_row_is_the_cards_last_row_with_no_count(self):
        card = block(VIEW, "struct CatHomeCareCard: View {")
        about = 'NavigationLink { links.carePage } label: { CatHomeCareRow(title: "この子のこと", value: nil) }'
        self.assertIn(about, card)
        # After the four rows, a divider only when there are rows above it.
        self.assertLess(card.index("ForEach(Array(shown.enumerated())"), card.index(about))
        self.assertIn("if !shown.isEmpty { Divider().padding(.leading, 16) }", card)
        self.assertIn('.accessibilityIdentifier(links.cat.profile != nil ? "tools-cat-\\(links.cat.id)"', card)
        self.assertIn(': "tools-family-cat-\\(links.cat.id)")', card)
        self.assertNotIn("あと", card)
        # The same row as the others: the same weight, no value.
        row = block(VIEW, "private struct CatHomeCareRow: View {")
        self.assertIn("let value: CatHomeCareCore.Value?", row)
        self.assertIn('.accessibilityLabel(value.map { "\\(title)、\\($0.text)" } ?? title)', row)
        self.assertNotIn(".headline", row)


class NameIsTheCatMenu(unittest.TestCase):
    """11/14: the big name on the photo opens the cat menu; no capsule."""

    def test_the_top_bar_is_settings_only(self):
        bar = block(HOME, "private var topBar: some View {")
        self.assertNotIn("Menu", bar)
        self.assertNotIn("Capsule", HOME)
        self.assertIn('.accessibilityIdentifier("tools-settings-button")', bar)
        self.assertNotIn("current: nil", HOME)

    def test_the_name_is_the_menu(self):
        hero = block(HOME, "private struct CatHomeHero: View {")
        menu = block(hero, "private var nameMenu: some View {")
        self.assertIn("Menu { menu } label: {", menu)
        self.assertIn("HStack(alignment: .firstTextBaseline", menu)
        self.assertIn(".font(.system(size: min(nameSize, 84), weight: .heavy))", menu)
        self.assertIn(".minimumScaleFactor(0.5)", menu)
        self.assertIn('Image(systemName: "chevron.down")', menu)
        self.assertIn(".font(.system(size: (min(nameSize, 84) * 0.28).rounded(), weight: .semibold))", menu)
        self.assertIn(".foregroundStyle(.white.opacity(0.85))", menu)
        self.assertIn(".fixedSize()", menu)
        self.assertIn(".frame(minHeight: 44)", menu)
        self.assertIn('.accessibilityLabel("猫を切り替える")', menu)
        self.assertIn(".accessibilityValue(cat.name)", menu)
        self.assertIn('.accessibilityIdentifier("tools-cat-menu")', menu)
        # The name is drawn once, inside the menu.
        self.assertEqual(hero.count("Text(cat.name)"), 1)

    def test_the_summary_is_read_once_and_the_menu_on_its_own(self):
        hero = block(HOME, "private struct CatHomeHero: View {")
        body = block(hero, "var body: some View {")
        self.assertIn("ZStack(alignment: .bottomLeading) {", body)
        self.assertLess(body.index("photoLayer"), body.index("words"))
        self.assertLess(body.index(".accessibilityElement(children: .ignore)"), body.index("words"))
        self.assertIn(".accessibilityLabel(facts.spoken)", body)
        self.assertIn(".accessibilityAddTraits(.isHeader)", body)
        self.assertEqual(body.count(".accessibilityElement("), 1)
        words = block(hero, "private var words: some View {")
        self.assertEqual(words.count(".accessibilityHidden(true)"), 2)

    def test_the_items_are_the_same(self):
        items = block(HOME, "private func catMenuItems(_ cats: [CatHomeCat], current: CatHomeCat) -> some View {")
        self.assertIn("ForEach(cats) { cat in", items)
        self.assertIn('.accessibilityIdentifier("tools-cat-menu-\\(cat.id)")', items)
        self.assertIn('Button { addsCat = true } label: { Label("この子を追加", systemImage: "plus") }', items)
        self.assertIn('.accessibilityIdentifier("tools-cat-profiles")', items)
        self.assertIn("catMenu: AnyView(catMenuItems(cats, current: cat)),", HOME)


class Words(unittest.TestCase):
    def test_values_use_real_data_only(self):
        for word in ('"きょう"', '"次は \\(due.month)月ごろ"', '"次は \\(due.year)年\\(due.month)月ごろ"',
                     '"前回 "', '"書きかけ"', '"次は "', "ToolEmptyValue.unset", "ToolEmptyValue.unwritten",
                     "ToolEmptyValue.none", '"\\(birthday.month)月\\(birthday.day)日（あと\\(days)日）"'):
            self.assertIn(word, CORE, word)
        self.assertIn("static let soonDays = 7", CORE)
        self.assertIn("static let vaccinationGraceDays = 60", CORE)
        # Never a worked-out schedule from the last vaccination.
        vaccination = block(CORE, "static func vaccination(_ vaccinations: [CatCareVaccination], today: CatCareDay) -> Value {")
        self.assertNotIn("givenOn.year + 1", vaccination)
        self.assertNotIn("byAdding: .year", CORE)

    def test_hero_line_on_the_day(self):
        self.assertIn('"きょうで\\(years)歳"', CORE)
        self.assertIn('"きょうは誕生日"', CORE)
        self.assertIn('"うちに来て \\(years)年"', CORE)
        facts = block(HOME, "struct CatHomeFacts {")
        self.assertIn("CatHomeCareCore.heroDayLine(", facts)
        # The farewell line comes first and returns before the day's words.
        self.assertLess(facts.index('line: "旅立った日　" + day'), facts.index("CatHomeCareCore.heroDayLine("))

    def test_nothing_new_is_stored_and_no_screen_code_in_core(self):
        for source in (VIEW, CORE):
            for stored in ("@AppStorage", "UserDefaults", "FileManager", "write("):
                self.assertNotIn(stored, source, stored)
        self.assertNotIn("import SwiftUI", CORE)


class Loading(unittest.TestCase):
    def test_vet_memos_come_from_the_tool_states_after_drawing(self):
        states = block(HOME, "final class CatHomeToolStates: ObservableObject {")
        self.assertIn("await Task.yield()", states)
        self.assertIn("try? await VeterinaryVisitStore.shared.visits()", states)
        self.assertIn("CatHomeCareCore.VetMemo($0)", states)
        self.assertIn('.filter { $0.contains("/VeterinaryVisits") }', states)
        self.assertIn(".onAppear { Task { await states.refresh() } }", HOME)
        self.assertNotIn("PhotoAssetImageView", VIEW)


class Registration(unittest.TestCase):
    def test_files_are_in_the_app_and_test_targets(self):
        for name, build, ref in (("CatHomeCareView.swift", "7A11120E0000000000000001", "7A11120E0000000000000002"),
                                 ("CatHomeCareCore.swift", "7A11120F0000000000000001", "7A11120F0000000000000002")):
            self.assertEqual(PROJECT.count(f"/* {name} in Sources */"), 2, name)
            self.assertEqual(PROJECT.count(f"path = {name};"), 1, name)
            self.assertIn(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};",
                          PROJECT)
            self.assertEqual(PROJECT.count(f"\t\t\t\t{ref} /* {name} */,\n"), 1, name)
        self.assertNotIn("CatHomeRecords", PROJECT)
        self.assertEqual(PROJECT.count("path = CatHomeCareTests.swift;"), 1)
        self.assertIn("C1E0A7E00000000000000001 /* CatHomeCareTests.swift in Sources */ = "
                      "{ isa = PBXBuildFile; fileRef = C1E0A7E00000000000000002; };", PROJECT)
        for test in ("testBirthdayCountsDaysAndTurnsTextColourWithinSevenDays", "testFebruary29BirthdayIsMarch1InOtherYears",
                     "testVaccinationNextDueAndItsTextColourWindow", "testVetNextVisitDayWithinSevenDaysAndOnTheDay",
                     "testWeightNewestWithItsDay", "testHeroLineFebruary29", "testRowsForEachKindOfCat"):
            self.assertIn(f"func {test}()", TESTS)
        self.assertIn("python3 ci/test-cat-home-care.py", QUICK)


class Captures(unittest.TestCase):
    def test_review_captures_and_fixture(self):
        self.assertNotIn("10e_cat_home_records", REVIEW + COLLECT)
        self.assertIn('"--app-store-screenshot-cat-care", "--cat-home-care-fixture"', REVIEW)
        self.assertIn('["cat-home-care-vet"]', REVIEW)
        # The App Store captures never get the fixture.
        self.assertNotIn("--cat-home-care-fixture", STORE_SHOTS)
        seed = block(FIXTURE, "static func seedCatHomeCareIfRequested() async {")
        self.assertIn("guard showsCatHomeCare,", seed)
        self.assertIn("!visits.contains(where: { $0.catID == catID })", seed)
        self.assertNotIn("PhotoMemoryNoteStore", seed)
        self.assertIn("await AppStoreScreenshotFixture.seedCatHomeCareIfRequested()", FIXTURE)


if __name__ == "__main__":
    unittest.main()
