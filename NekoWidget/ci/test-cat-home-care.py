"""Source contracts for the 「この子」 page's 「これからのこと」 (approved 11/14,
「猫を大切にできるページ」).

The page is only what helps take care of the cat: the hero, the five round
buttons, one card with 誕生日, ワクチン, 病院, 体重 in this order, each only
when something is written for it (11/14: never 未設定・未記入・なし on the
page), and 「この子のこと」 always as its last row with no count
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
    def test_only_rows_with_data_in_this_order_with_identifiers(self):
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
        for row in ("birthday", "vaccination", "vet", "weight"):
            self.assertIn(f"if let value = rows.{row} {{", entries)
        # この子のこと always, after the rows.
        about = 'NavigationLink { links.carePage } label: { CatHomeCareRow(title: "この子のこと", value: nil) }'
        self.assertLess(card.index("ForEach(Array(shown.enumerated())"), card.index(about))

    def test_no_empty_wording_on_the_page(self):
        # Not in code (the comments say why they are gone).
        for word in ("ToolEmptyValue", '"未設定"', '"未記入"', '"なし"'):
            self.assertNotIn(word, CORE + VIEW, word)
        for name in ("birthday(_ birthday: CatCareDay?, today: CatCareDay) -> Value? {",
                     "vaccination(_ vaccinations: [CatCareVaccination], today: CatCareDay) -> Value? {",
                     "vet(_ memos: [VetMemo], today: CatCareDay, calendar: Calendar = .nekoGregorian) -> Value? {",
                     "weight(_ weights: [CatCareWeight], today: CatCareDay) -> Value? {"):
            self.assertIn("static func " + name, CORE)
        make = block(VIEW, "static func make(hasProfile: Bool, record: CatCareRecord?, birthday: CatCareDay?,")
        self.assertIn("return rows == CatHomeCareRows() ? nil : rows", make)

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
        self.assertIn("return vet.map { CatHomeCareRows(vet: $0) }", make)

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
        # 11/14 (owner, on device): a Menu whose label was the big name showed
        # the system's lifted rectangle around it when tapped. The name is now
        # plain text and the menu is a small round chevron button after it,
        # so the system highlight is a small circle.
        hero = block(HOME, "private struct CatHomeHero: View {")
        menu = block(hero, "private var menuButton: some View {")
        self.assertIn("Menu { menu } label: {", menu)
        self.assertIn('Image(systemName: "chevron.down")', menu)
        self.assertIn("let circle = min(menuCircle, 40)", menu)
        self.assertIn("let target = max(circle, 44)", menu)
        self.assertIn(".background(.ultraThinMaterial, in: Circle())", menu)
        self.assertIn(".contentShape(Circle())", menu)
        self.assertIn(".contentShape(.contextMenuPreview, Circle().inset(by: (target - circle) / 2))", menu)
        self.assertNotIn("Rectangle()", menu)
        self.assertNotIn("Text(cat.name)", menu)
        self.assertIn(".menuStyle(.button)", menu)
        self.assertIn(".buttonStyle(.plain)", menu)
        self.assertIn(".menuIndicator(.hidden)", menu)
        self.assertIn('.accessibilityLabel("猫を切り替える")', menu)
        self.assertIn(".accessibilityValue(cat.name)", menu)
        self.assertIn('.accessibilityIdentifier("tools-cat-menu")', menu)
        self.assertIn("@ScaledMetric(relativeTo: .body) private var menuCircle: CGFloat = 30", hero)
        # The name is drawn once, as plain text the photo's summary reads.
        self.assertEqual(hero.count("Text(cat.name)"), 1)
        name = block(hero, "private func nameText(_ fit: CatHomeHeroLayout.NameFit, maxWidth: CGFloat) -> some View {")
        self.assertIn(".font(.system(size: CGFloat(fit.size), weight: .heavy))", name)
        self.assertIn(".accessibilityHidden(true)", name)
        self.assertNotIn("Menu", name)
        self.assertNotIn("nameMenu", HOME)

    def test_the_chevron_sits_on_the_middle_of_the_name(self):
        # Centred on the glyphs of the name's last line, not on its baseline.
        hero = block(HOME, "private struct CatHomeHero: View {")
        row = block(hero, "private func nameRow(_ fit: CatHomeHeroLayout.NameFit, maxWidth: CGFloat) -> some View {")
        self.assertIn("let gap = max((size * 0.12).rounded(), 6)", row)
        self.assertIn("HStack(alignment: .lastTextBaseline, spacing: gap) {", row)
        # Two lines: just after the end of the last line (measured with TextKit).
        self.assertIn("ZStack(alignment: Alignment(horizontal: .leading, vertical: .lastTextBaseline)) {", row)
        self.assertIn(".alignmentGuide(.leading) { _ in -(last + gap) }", row)
        self.assertEqual(row.count("centred(menuButton, size: size)"), 2)
        centred = block(hero, "private func centred<Content: View>(_ content: Content, size: CGFloat) -> some View {")
        self.assertIn(".alignmentGuide(.lastTextBaseline) { dimensions in", centred)
        self.assertIn("dimensions[VerticalAlignment.center] + size * CGFloat(CatHomeHeroLayout.glyphCentre)", centred)
        last = block(hero, "private func lastLineWidth(size: CGFloat, maxWidth: CGFloat) -> CGFloat {")
        self.assertIn("container.maximumNumberOfLines = 2", last)
        self.assertIn("container.lineFragmentPadding = 0", last)
        self.assertNotIn("firstTextBaseline", hero)
        self.assertIn("static let glyphCentre = 0.36", CORE)

    def test_names_of_any_length_fit_the_ladder(self):
        # 11/14: at most 62% of the photo's width; 56 → 48 → 40 → 34 (scaled
        # by Dynamic Type up to 1.5×), then two lines at the smallest.
        hero = block(HOME, "private struct CatHomeHero: View {")
        words = block(hero, "private var words: some View {")
        self.assertIn("(metrics.width * CGFloat(CatHomeHeroLayout.nameWidthShare)).rounded(.down)", words)
        self.assertIn("let fit = nameFit(maxWidth: nameWidth)", words)
        fit = block(hero, "private func nameFit(maxWidth: CGFloat) -> CatHomeHeroLayout.NameFit {")
        self.assertIn("CatHomeHeroLayout.nameFit(scale: Double(scale), maxWidth: Double(maxWidth))", fit)
        # iPhone SE: the ladder does not grow with the text size (45_home_text_ax3).
        self.assertIn("metrics.heroHeight < CatHomeHeroLayout.shortHero ? min(nameSize / 56, 1) : nameSize / 56", fit)
        self.assertIn("static let shortHero: CGFloat = 320", CORE)
        self.assertIn("UIFont.systemFont(ofSize: CGFloat(size), weight: .heavy)", fit)
        name = block(hero, "private func nameText(_ fit: CatHomeHeroLayout.NameFit, maxWidth: CGFloat) -> some View {")
        self.assertIn("text.lineLimit(1).fixedSize()", name)
        self.assertIn("text.lineLimit(2)", name)
        self.assertIn(".frame(width: maxWidth, alignment: .leading)", name)
        self.assertNotIn("minimumScaleFactor(0.5)", hero)
        for pinned in ("static let nameLadder: [Double] = [56, 48, 40, 34]", "static let nameScaleCap = 1.5",
                       "static let nameWidthShare = 0.62", "return NameFit(size: size, lines: 1)",
                       "return NameFit(size: sizes.last ?? nameLadder[nameLadder.count - 1], lines: 2)"):
            self.assertIn(pinned, CORE)
        # The line wraps to two lines before it shrinks, never below 0.85.
        self.assertIn(".lineLimit(typeSize.isAccessibilitySize ? 3 : 2)", words)
        self.assertIn(".minimumScaleFactor(0.85)", words)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", words)
        self.assertIn("func testNameLadderKeepsShortNamesAtFiftySix()", TESTS)
        self.assertIn("func testNameLadderScalesWithTextSizeUpToTheCap()", TESTS)

    def test_dots_cap_at_seven(self):
        hero = block(HOME, "private struct CatHomeHero: View {")
        words = block(hero, "private var words: some View {")
        self.assertIn("CatHomePageDots(count: pageCount, current: pageIndex)", words)
        self.assertIn("static let maxDots = 7", CORE)
        self.assertIn("ForEach(CatHomeHeroLayout.dots(count: count, current: current), id: \\.index) { dot in", HOME)
        self.assertIn("func testPageDotsCapAtSevenWithShrinkingEnds()", TESTS)

    def test_pages_are_cards_only_while_they_move(self):
        # 11/14: at rest exactly as before; while moving, each page scales to
        # 0.92 at most with continuous corners up to 32 painted in the page
        # background (no clip, no opacity, no blur); Reduce Motion: none.
        pager = block(HOME, "private func pager(_ cats: [CatHomeCat], current: CatHomeCat, metrics: CatHomeMetrics) -> some View {")
        self.assertIn(".modifier(CatHomeCardWhileMoving(enabled: !reduceMotion && cats.count > 1))", pager)
        self.assertIn(".scrollTransition(.interactive, axis: .horizontal) { content, phase in", pager)
        self.assertIn("content.scaleEffect(phase.isIdentity || reduceMotion", pager)
        self.assertIn("? 1 : 1 - shrink * CGFloat(min(abs(phase.value), 1)))", pager)
        for gone in (".opacity(", ".blur(", ".offset(", "rotation"):
            self.assertNotIn(gone, pager)
        self.assertIn(".scrollTargetBehavior(.paging)", pager)
        self.assertIn(".scrollPosition(id: $pageID)", pager)
        self.assertIn(".scrollDisabled(cats.count < 2)", pager)
        card = block(HOME, "private struct CatHomeCardWhileMoving: ViewModifier {")
        self.assertIn("static let shrink: CGFloat = 0.08", card)
        self.assertIn("static let radius: CGFloat = 32", card)
        self.assertIn("CatHomeCardCorners(radius: Self.radius * progress)", card)
        self.assertIn(".fill(Color(.systemGroupedBackground), style: FillStyle(eoFill: true))", card)
        self.assertIn(".allowsHitTesting(false)", card)
        self.assertIn("return moved < 0.01 ? 0 : (moved * 100).rounded() / 100", card)
        self.assertNotIn(".mask", card)
        self.assertNotIn(".clipShape", card)
        corners = block(HOME, "private struct CatHomeCardCorners: Shape {")
        self.assertIn("guard radius > 0 else { return Path() }", corners)
        self.assertIn("style: .continuous", corners)
        self.assertIn("@Environment(\\.accessibilityReduceMotion) private var reduceMotion", HOME)

    def test_a_settled_page_change_ticks_once(self):
        pager = block(HOME, "private func pager(_ cats: [CatHomeCat], current: CatHomeCat, metrics: CatHomeMetrics) -> some View {")
        self.assertIn(".sensoryFeedback(.selection, trigger: pageID) { old, new in", pager)
        self.assertIn("old != nil && new != nil && old != new", pager)
        # The page is still kept once the pages rest.
        self.assertIn("try? await Task.sleep(for: .milliseconds(700))", HOME)

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
                     '"前回 "', '"書きかけ"', '"次は "',
                     '"\\(birthday.month)月\\(birthday.day)日（あと\\(days)日）"'):
            self.assertIn(word, CORE, word)
        self.assertIn("static let soonDays = 7", CORE)
        self.assertIn("static let vaccinationGraceDays = 60", CORE)
        # Never a worked-out schedule from the last vaccination.
        vaccination = block(CORE, "static func vaccination(_ vaccinations: [CatCareVaccination], today: CatCareDay) -> Value? {")
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

    def test_stress_captures_are_synthetic_and_debug_only(self):
        # 11/14: the この子 page under stress for the designer, light, dark and SE.
        test = block(REVIEW, "func test14CatHomeStress() {")
        for name in ("40_home_name_1", "40_home_name_30", "41_home_menu_open", "41b_home_menu_open_1cat",
                     "42_home_cats_8", "43_home_photo_bright", "43_home_photo_portrait_small",
                     "44_home_rows_long_values", "44_home_searching", "44_home_departed",
                     "45_home_text_ax3", "46_home_mid_swipe"):
            self.assertIn(f'shot("{name}", app)', test)
            self.assertIn(f'"{name}"', COLLECT)
        self.assertIn("STRESS_SCREENS", COLLECT.split("SE_SCREENS = (", 1)[1].split("EXPECTED", 1)[0])
        stress = FIXTURE.split("enum CatHomeStress {", 1)[1]
        self.assertTrue(FIXTURE.startswith("#if DEBUG"))
        self.assertTrue(FIXTURE.rstrip().endswith("#endif"))
        self.assertIn("CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument)", stress)
        # Code-drawn cats only; one ID range per scenario.
        self.assertIn("makeCatIllustration(variant:", stress)
        self.assertNotIn("OwnerStoreCaptureFixture", stress)
        self.assertIn('String(format: "C47E%04X-0000-4000-8000-%012X", scenario & 0xFFFF, index)', stress)
        self.assertIn("await AppStoreScreenshotFixture.CatHomeStress.seedIfRequested()", FIXTURE)


if __name__ == "__main__":
    unittest.main()
