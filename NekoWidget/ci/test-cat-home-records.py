"""Source contracts for the 「この子」 page's records (approved 11/13, 「記録が並ぶ」).

Under the five buttons a cat's page gathers what already exists elsewhere:
「1年前のきょう」, 「さいきんの写真」 and 「{name}の記録」 (photo memos,
weights, finished vet memos, vaccinations), then 「この子のこと」 as one row.
Nothing new is stored. Each block shows only when it has something. The
records are read after the page is drawn, off the main thread, and kept per
cat. Native behaviour of the merge, order and words: NekoWidgetTests
CatHomeRecordsTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


HOME = read("NekoWidget/Views/CatHomeView.swift")
VIEW = read("NekoWidget/Views/CatHomeRecordsView.swift")
CORE = read("NekoWidget/Views/CatHomeRecordsCore.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
VET = read("NekoWidget/Views/VeterinaryVisitView.swift")
FIXTURE = read("NekoWidget/App/AppStoreScreenshotFixture.swift")
REVIEW = read("NekoWidgetUITests/ReviewScreenshotUITests.swift")
STORE_SHOTS = read("NekoWidgetUITests/AppStoreScreenshotUITests.swift")
COLLECT = read("ci/collect-review-screenshots.py")
PROJECT = read("NekoWidget.xcodeproj/project.pbxproj")
TESTS = read("NekoWidgetTests/CatHomeRecordsTests.swift")


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
    def test_records_sit_between_the_buttons_and_the_about_row(self):
        page = block(HOME, "private struct CatHomePage: View {")
        order = ["CatHomeToolBar(", "CatHomeSearchingLine(cat: cat)", "CatHomeRecordsSection(",
                 "CatHomeAboutCard(cat: cat, facts: facts, destination: carePage)"]
        self.assertEqual([page.index(item) for item in order], sorted(page.index(item) for item in order))
        # Departed cats keep their records and photos; only the tools go.
        self.assertLess(page.index("if !facts.departed {"), page.index("CatHomeToolBar("))
        self.assertGreater(page.index("CatHomeRecordsSection("), page.index("if searching { CatHomeSearchingLine"))
        self.assertIn(".catHomeRecordsLoading(records, cat: cat, record: record, photos: photos)", page)
        self.assertIn(".padding(.bottom, 32)", page)

    def test_blocks_in_order_and_each_only_when_it_has_something(self):
        section = block(VIEW, "struct CatHomeRecordsSection: View {")
        # A Group: an empty block takes no space and no gap in the page.
        self.assertIn("Group {", section)
        order = ["if let birthdayIn { CatHomeBirthdayCard(", "if let yearsAgo = snapshot?.yearsAgo {",
                 "if let profile = cat.profile, !photos.isEmpty {", "if let rows = snapshot?.rows, !rows.isEmpty {"]
        self.assertEqual([section.index(item) for item in order], sorted(section.index(item) for item in order))
        # No empty states, placeholders or 「あと○枚」.
        for text in ("まだ", "ありません", "ContentUnavailableView", "ProgressView", "あと\\(", "枚あります"):
            self.assertNotIn(text, VIEW, text)

    def test_identifiers(self):
        for identifier in ('"cat-home-birthday"', '"cat-home-years-ago"', '"cat-home-photos"',
                           '"cat-home-photo-\\(index)"', '"cat-home-records"', '"cat-home-record-\\(index)"',
                           '"cat-home-records-more"', '"cat-home-photos-all"'):
            self.assertIn(identifier, VIEW, identifier)
        card = block(HOME, "private struct CatHomeAboutCard: View {")
        self.assertIn('"tools-cat-\\(cat.id)" : "tools-family-cat-\\(cat.id)"', card)
        self.assertIn('CatHomeLine(title: "この子のこと", value: facts.progressText, emphasized: true)', card)


class TopControls(unittest.TestCase):
    def test_cat_menu_and_settings_scroll_with_the_page(self):
        # Not pinned over the page: on each page's content, at the top of the
        # photo, where the pinned bar rested (just under the status bar).
        self.assertNotIn(".overlay(alignment: .top) { topBar(cats, current: current) }", HOME)
        page = block(HOME, "private struct CatHomePage: View {")
        self.assertIn(".overlay(alignment: .top) { topBar.padding(.top, metrics.topInset) }", page)
        self.assertIn("topBar: AnyView(topBar(cats, current: cat)))", HOME)
        empty = block(HOME, "private struct CatHomeNoCatPage: View {")
        self.assertIn(".overlay(alignment: .top) { topBar.padding(.top, metrics.topInset) }", empty)
        self.assertIn("topBar: AnyView(topBar(cats, current: nil))", HOME)
        # UI tests go back to the top before tapping them.
        self.assertIn("for _ in 0..<8 where !menu.isHittable { app.swipeDown() }", REVIEW)


class Blocks(unittest.TestCase):
    def test_birthday_card_only_within_thirty_days(self):
        card = block(VIEW, "private struct CatHomeBirthdayCard: View {")
        self.assertIn('Image(systemName: "birthday.cake")', card)
        self.assertIn("static let birthdaySoonDays = 30", HOME)
        self.assertIn('"きょうは誕生日"', CORE)
        self.assertIn('"誕生日まで " + birthdayIn', CORE)

    def test_years_ago_card(self):
        card = block(VIEW, "private struct CatHomeYearsAgoCard: View {")
        self.assertIn("CatHomeThumbnail(identifier: item.photoIdentifier, side: 84, radius: 14)", card)
        self.assertIn(".lineLimit(2)", card)
        self.assertIn("case let .memo(recordID): return tools.memoPhoto(recordID)", card)
        self.assertIn("return photoDestination(profile.identifier, item.photoIdentifier)", card)
        self.assertIn('"\\(years)年前のきょう"', CORE)
        pick = block(CORE, "static func yearsAgo(")
        # The memo first, the photo only without one.
        self.assertLess(pick.index("for record in memos"), pick.index("for photo in photos"))

    def test_photo_strip(self):
        strip = block(VIEW, "private struct CatHomePhotoStrip: View {")
        self.assertIn("static let shown = 12", strip)
        self.assertIn("LazyHStack(spacing: 8)", strip)
        self.assertIn("side: 104, radius: 14", strip)
        self.assertIn('CatHomeBlockHeading(text: "さいきんの写真")', strip)
        self.assertIn('Text("\\(photos.count.formatted())枚")', strip)
        self.assertIn("Button { tools.showPhotos(profileID) }", strip)
        self.assertIn("photoDestination(profileID, photo.localIdentifier)", strip)
        # The cat's effective set: the 写真 tab's own per-cat photos.
        self.assertIn("profilePhotos: hasPhotoAccess ? profileAlbumPhotos : [:],", MAIN)
        self.assertIn("cat.profile.flatMap { tools.profilePhotos[$0.identifier] } ?? []", HOME)

    def test_thumbnails_are_square_cached_cells(self):
        thumb = block(VIEW, "private struct CatHomeThumbnail: View {")
        self.assertIn("PhotoAssetImageView(", thumb)
        self.assertIn("targetAspectRatio: 1", thumb)
        self.assertIn(".frame(width: side, height: side)", thumb)
        self.assertNotIn("showsFullImage: true", thumb)

    def test_records_card(self):
        card = block(VIEW, "private struct CatHomeRecordsCard: View {")
        self.assertIn("@State private var shown = CatHomeRecordsCore.firstRows", card)
        self.assertIn("Button { shown += CatHomeRecordsCore.moreRows }", card)
        self.assertIn('Text("もっと見る")', card)
        self.assertIn('CatHomeBlockHeading(text: "\\(cat.name)の記録")', card)
        self.assertIn("static let firstRows = 5", CORE)
        self.assertIn("static let moreRows = 20", CORE)
        # Where each row opens.
        self.assertIn("NavigationLink { tools.memoPhoto(recordID) }", card)
        self.assertIn("careList(.weight, label)", card)
        self.assertIn("careList(.vaccination, label)", card)
        self.assertIn("openedVisit = await model.visit(visitID)", card)
        self.assertIn(".sheet(item: $openedVisit, onDismiss: { model.refresh() }) { visit in", card)
        row = block(VIEW, "private struct CatHomeRecordRowView: View {")
        self.assertIn(".accessibilityLabel(row.spoken)", row)
        self.assertIn("@ScaledMetric(relativeTo: .subheadline) private var dateWidth: CGFloat = 74", row)
        self.assertIn("typeSize.isAccessibilitySize", row)
        lists = block(VIEW, "private struct CatHomeCareListPage: View {")
        self.assertIn("CatCareListView(kind: kind, catID: catID, editing: $editing)", lists)
        self.assertIn("CatCareListEntrySheet(editor: editor, catID: catID)", lists)

    def test_row_words(self):
        self.assertIn('"体重 " + value', CORE)
        self.assertIn('"病院　" + $0', CORE)
        self.assertIn('"ワクチン　" + name', CORE)
        self.assertIn('"次は\\($0.year)年\\($0.month)月ごろ"', CORE)
        self.assertIn('"前回より " + (change > 0 ? "+" : "\\u{2212}") + amount + "kg"', CORE)
        self.assertIn('"\\(day.month)月\\(day.day)日" : "\\(day.year)年\\(day.month)月\\(day.day)日"', CORE)
        # Finished vet memos only; the memo's day as the memo list dates it.
        self.assertIn("guard let finished = visit.completedAt", CORE)
        self.assertIn("note.context?.capturedAt ?? note.writtenAt ?? note.updatedAt", CORE)
        # No writer names (family-shared rows show what this iPhone has).
        self.assertNotIn("editedBy", block(CORE, "static func weightRows("))
        self.assertNotIn("members", CORE)


class Opening(unittest.TestCase):
    def test_tools_bring_the_screens_the_photo_tab_opens(self):
        tools = block(MAIN, "private var catHomeTools: CatHomeTools {")
        self.assertIn("showPhotos: { profileID in openPhotoLibrary(for: profileID) },", tools)
        self.assertIn("memoPhoto: { recordID in AnyView(memoriesDestination(for: .memoryNotePhoto(recordID))) },", tools)
        self.assertIn("VeterinaryPastVisitSheet(visit: visit, photos: memoryNotePhotos,", tools)
        switch = block(MAIN, "private func openPhotoLibrary(for profileID: String) {")
        for line in ("photoLibrarySelection.select(.all)", "photoLibraryProfileIdentifier = profileID",
                     "selectedTab = .photos"):
            self.assertIn(line, switch)
        sheet = block(VET, "struct VeterinaryPastVisitSheet: View {")
        self.assertIn("VeterinaryConsultationView(initialVisit: visit, photos: photos, noteStore: noteStore,", sheet)
        self.assertIn("NavigationStack {", sheet)


class Loading(unittest.TestCase):
    def test_read_after_drawing_off_the_main_thread_and_kept_per_cat(self):
        model = block(VIEW, "final class CatHomeRecordsModel: ObservableObject {")
        self.assertIn("@MainActor\nfinal class CatHomeRecordsModel", VIEW)
        self.assertIn("guard keys[key.cat] != key else { return }", model)
        self.assertIn("await Task.yield()", model)
        self.assertIn("Task.detached(priority: .userInitiated)", model)
        self.assertIn("try? await PhotoMemoryNoteStore.shared.records()", model)
        self.assertIn("try? await VeterinaryVisitStore.shared.visits()", model)
        # Again when either store saves, and when the tab appears again.
        self.assertIn('$0.contains("/PhotoMemoryNotes") || $0.contains("/VeterinaryVisits")', model)
        self.assertIn(".debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)", model)
        self.assertIn(".onAppear { records.refresh() }", HOME)
        self.assertIn("@StateObject private var records = CatHomeRecordsModel()", HOME)

    def test_nothing_new_is_stored(self):
        for source in (VIEW, CORE):
            for stored in ("@AppStorage", "UserDefaults", ".save(", "FileManager", "write("):
                self.assertNotIn(stored, source, stored)
        self.assertNotIn("import SwiftUI", CORE)


class Registration(unittest.TestCase):
    def test_files_are_in_the_app_and_test_targets(self):
        for name, build, ref in (("CatHomeRecordsView.swift", "7A11120E0000000000000001", "7A11120E0000000000000002"),
                                 ("CatHomeRecordsCore.swift", "7A11120F0000000000000001", "7A11120F0000000000000002")):
            self.assertEqual(PROJECT.count(f"/* {name} in Sources */"), 2, name)
            self.assertEqual(PROJECT.count(f"path = {name};"), 1, name)
            self.assertIn(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};",
                          PROJECT)
            self.assertEqual(PROJECT.count(f"\t\t\t\t{ref} /* {name} */,\n"), 1, name)
        self.assertEqual(PROJECT.count("path = CatHomeRecordsTests.swift;"), 1)
        self.assertIn("C1E0A7E00000000000000001 /* CatHomeRecordsTests.swift in Sources */ = "
                      "{ isa = PBXBuildFile; fileRef = C1E0A7E00000000000000002; };", PROJECT)
        for test in ("testMergesFourKindsNewestFirstAndOnlyThisCat", "testWeightChangeWords",
                     "testFebruary29CountsOnMarch1OfOtherYearsOnly", "testTheDayIsTheIPhonesTimeZoneDay",
                     "testDateWordsAndBirthday"):
            self.assertIn(f"func {test}()", TESTS)


class Captures(unittest.TestCase):
    def test_review_captures_and_fixture(self):
        self.assertIn('shot("10e_cat_home_records", app) {', REVIEW)
        self.assertIn('"10e_cat_home_records"', REVIEW[:REVIEW.index("private static let mike")])
        self.assertEqual(COLLECT.count('"10e_cat_home_records",'), 2)
        self.assertIn('"--app-store-screenshot-cat-care", "--cat-home-records-fixture"', REVIEW)
        # The App Store captures never get the records fixture.
        self.assertNotIn("--cat-home-records-fixture", STORE_SHOTS)
        seed = block(FIXTURE, "static func seedCatHomeRecordsIfRequested() async {")
        self.assertIn("guard showsCatHomeRecords,", seed)
        self.assertIn("!visits.contains(where: { $0.catID == catID })", seed)
        self.assertIn("expectedRevision: nil", seed)
        self.assertIn("await AppStoreScreenshotFixture.seedCatHomeRecordsIfRequested()", FIXTURE)


if __name__ == "__main__":
    unittest.main()
