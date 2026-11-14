"""Source contracts for the 11/14 review of VoiceOver and large text
(読み上げと大きい文字).

VoiceOver turns a month's or the year's book from its page number (the
page curl cannot be dragged), moves between the cats on 「この子」 (and to
the page that adds one), opens a まど photo from its tile and hears who sent
it and when. Passing lines are read as they show, the date of a photo is read
once, and a removal is offered only for someone who can be removed. At the
accessibility text sizes the tile's name has a line of its own and the
Photos-off page scrolls; at the default size neither changes. The longest
name (20 characters) fits two lines on 「この子」 at the default text size.
Native behaviour of the words: NekoWidgetTests AccessibilitySpeechTests and
CatHomeCareTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


VIEWS = "NekoWidget/Views/"
ALBUM = read(VIEWS + "AlbumPrototypeView.swift")
HOME = read(VIEWS + "CatHomeView.swift")
CORE = read(VIEWS + "CatHomeCareCore.swift")
WINDOW = read(VIEWS + "GroupWindowView.swift")
SETUP = read(VIEWS + "GroupWindowSetupView.swift")
LIKED = read(VIEWS + "LikedPhotosView.swift")
OFFICIAL = read(VIEWS + "OfficialWindowView.swift")
PERMISSION = read(VIEWS + "PhotoPermissionView.swift")
DETAIL = read(VIEWS + "PhotoDetailComponents.swift")
HOME_PHOTOS = read(VIEWS + "HomeView.swift")
FAMILY = read(VIEWS + "FamilyNotebookView.swift")
TESTS = read("NekoWidgetTests/AccessibilitySpeechTests.swift")
PROJECT = read("NekoWidget.xcodeproj/project.pbxproj")
QUICK = read("ci/run-quick-ios-checks.sh")


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


class Books(unittest.TestCase):


    def test_the_page_number_turns_the_pages(self):
        number = block(ALBUM, "struct BookPageNumber: View {")
        self.assertIn('Text(verbatim: "\\(index + 1) / \\(count)")', number)
        self.assertIn(".accessibilityValue(BookPageAccess.value(index: index, count: count))", number)
        self.assertIn(".accessibilityAdjustableAction { direction in", number)
        self.assertIn(".accessibilityAction(named: Text(BookPageAccess.next))", number)
        self.assertIn(".accessibilityAction(named: Text(BookPageAccess.previous))", number)
        access = block(ALBUM, "enum BookPageAccess {")
        self.assertIn('static let label = "ページをめくる"', access)
        self.assertIn('"\\(count)ページ中\\(index + 1)ページ目"', access)
        # Both books use it; the curl itself is unchanged.
        self.assertEqual(ALBUM.count("BookPageNumber(index: $index, count: leaves.count, ink:"), 2)
        self.assertIn("UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)", ALBUM)

    def test_plus_on_the_shelf_reads_as_its_button(self):
        self.assertNotIn("Plusで見られます", ALBUM)
        self.assertIn('(workNeedsPlus ? "、Plusでひらく" : "")', ALBUM)


class CatPages(unittest.TestCase):
    def test_the_photo_says_which_cat_and_moves_between_them(self):
        self.assertIn('"\\(catCount)匹中\\(index + 1)匹目"', CORE)
        for word in ('static let previous = "前の子"', 'static let next = "次の子"',
                     'static let toAdd = "猫を追加するページへ"'):
            self.assertIn(word, CORE)
        hero = block(HOME, "private struct CatHomeHero: View {")
        self.assertIn("CatHomePageAccess.spoken(facts.spoken, index: pageIndex, catCount: pageCount - 1)", hero)
        self.assertIn("Button(action.name) { turn(action.by) }", hero)
        # The same move as a swipe: Reduce Motion, and the add page is never remembered.
        turn = block(HOME, "private func turn(from index: Int, by: Int) {")
        self.assertIn("withAnimation(reduceMotion ? nil : .snappy) { pageID = Self.addPageID }", turn)
        self.assertIn("show(cats[target].id)", turn)
        # Back from the add page.
        self.assertIn("previous: { pageActions.turn(cats.count, -1) }", HOME)
        self.assertIn("if let previous { Button(CatHomePageAccess.previous, action: previous) }", HOME)
        # The fast swipe stays: Equatable pages, every page built up front.
        self.assertIn("page(cat, index: index, cats: cats, metrics: metrics).equatable()", HOME)
        self.assertIn("static let eagerPages = 12", HOME)

    def test_voice_control_hears_the_word_on_the_button(self):
        button = block(HOME, "private struct CatHomeToolButton: View {")
        self.assertIn(".accessibilityInputLabels([Text(tool.shortTitle), Text(tool.title)])", button)

    def test_the_longest_name_has_a_two_line_floor(self):
        self.assertIn("static let twoLineFloor: Double = 22", CORE)
        self.assertIn("NameFit(size: (twoLineFloor * factor).rounded(), lines: 2)", CORE)


class WindowTiles(unittest.TestCase):
    def test_the_photo_opens_and_says_who_and_when(self):
        tile = block(WINDOW, "private struct GroupPhotoTile: View {")
        self.assertIn(".accessibilityAddTraits(.isButton)", tile)
        self.assertIn(".accessibilityAction(open)", tile)
        self.assertIn("day: GroupPhotoTileDate.text(entry.createdAt), reported: reported, hidden: entry.isHidden))", tile)
        # Nothing read on the container (.contain never reads its own label).
        self.assertNotIn(".accessibilityLabel(tileLabel)", WINDOW)
        self.assertNotIn('"大きく見る"', WINDOW)
        # The heart stays its own button and says whether it was sent.
        heart = block(tile, "private var heartButton: some View {")
        self.assertIn("GroupPhotoTileSpeech.heart(mine: model.myHeartIsActive(entry.id), canHeart: canHeart)", heart)
        self.assertIn('.accessibilityIdentifier("group-photo-tile-heart")', heart)

    def test_large_text_gives_the_name_its_own_line(self):
        tile = block(WINDOW, "private struct GroupPhotoTile: View {")
        self.assertIn("if typeSize.isAccessibilitySize {", tile)
        self.assertIn("senderName.lineLimit(2)", tile)
        self.assertIn("senderName.lineLimit(1)", tile)


class PassingLines(unittest.TestCase):
    def test_they_are_read_when_shown(self):
        self.assertIn('AccessibilityNotification.Announcement("見せる写真に追加しました").post()', LIKED)
        self.assertIn("if let message { AccessibilityNotification.Announcement(message).post() }", OFFICIAL)
        self.assertIn(".announcesWhenShown(model.actionMessage)", WINDOW)


class Members(unittest.TestCase):
    def test_remove_is_offered_only_when_possible(self):
        self.assertIn('if canRemove {\n                Button("外す")', SETUP)
        self.assertNotIn('.accessibilityAction(named: Text("外す"))', SETUP)


class Dates(unittest.TestCase):
    def test_the_date_is_read_once(self):
        self.assertEqual(LIKED.count('.accessibilityLabel("撮影日")'), 2)
        self.assertNotIn(".accessibilityLabel(spokenDate)", LIKED)
        self.assertNotIn('.accessibilityLabel("\\(album.title)、\\(GrowthAlbumOverviewCard.dateRange(for: album))")', LIKED)


class PhotosOff(unittest.TestCase):
    def test_scrolls_only_when_it_does_not_fit(self):
        body = block(PERMISSION, "struct PhotoPermissionView: View {")
        self.assertIn("ViewThatFits(in: .vertical) {\n            page\n            ScrollView { page }", body)
        self.assertEqual(PERMISSION.count(".accessibilityHidden(true)"), 2)


class Words(unittest.TestCase):
    def test_photos_read_as_cat_photos_without_how_to_tap(self):
        self.assertNotIn('))の猫写真"', HOME_PHOTOS)
        self.assertNotIn('"撮影日不明の猫写真"', HOME_PHOTOS)
        self.assertIn('"\\(creationDate.formatted(.dateTime.year().month().day()))の猫の写真"', HOME_PHOTOS)
        self.assertNotIn("2回タップ", DETAIL)
        self.assertGreaterEqual(FAMILY.count(".accessibilityHidden(true)"), 2)


class Registration(unittest.TestCase):
    def test_tests_are_built_and_run(self):
        self.assertIn("func testBookPageNumberReadsThePageAndTurnsWithinTheBook()", TESTS)
        self.assertEqual(PROJECT.count("path = AccessibilitySpeechTests.swift;"), 1)
        self.assertIn("C1A55E500000000000000001 /* AccessibilitySpeechTests.swift in Sources */", PROJECT)
        self.assertIn("python3 ci/test-a11y-voiceover-type.py", QUICK)


if __name__ == "__main__":
    unittest.main()
