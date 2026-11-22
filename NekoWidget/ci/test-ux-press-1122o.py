"""11/22 (easy to press, a clear answer): what a person does every day.

1. この子: the page dots are buttons. A dot goes to its cat's page, the 「＋」
   to the add page, with the same page move; each dot is pressed in a
   22 x 44 area while it stays small. VoiceOver: the cat's name, and
   「この子を追加」 for the 「＋」. The ⌄ menu from five cats is unchanged.
2. まど: a double-tap that sends a heart shows a big white ♥ over the photo
   (0.6 -> 1.0 and out, 0.7 s; only a fade with Reduce Motion); not when it
   takes the heart back or cannot send. In the photo's page, ♥ that sends
   shows the same over the photo. The haptics are unchanged.
3. 44pt areas: 「写真を変える」, the footnote 「外す」 and the ⓧ of
   「次に確かめる日」 (also .secondary, not .tertiary).
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


HOME = read("NekoWidget/Views/CatHomeView.swift")
WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
GROWTH = read("NekoWidget/Views/GrowthAlbumView.swift")
SHOWCASE = read("NekoWidget/Views/ShowcasePhotoView.swift")
LOST = read("NekoWidget/Views/CatPreparednessView.swift")


class PageDots(unittest.TestCase):
    def setUp(self):
        self.dots = section(HOME, "private struct CatHomePageDots: View {", "\n}\n")

    def test_each_dot_is_a_button_to_its_page(self):
        self.assertIn("Button { go(dot.index) } label: {", self.dots)
        self.assertIn(".buttonStyle(.plain)", self.dots)
        self.assertIn("var go: (_ page: Int) -> Void = { _ in }", HOME)
        self.assertIn("pageActions.go = { page in go(to: page) }", HOME)
        go = section(HOME, "private func go(to page: Int) {", "\n    }\n")
        self.assertIn("guard page >= 0, page <= cats.count else { return }", go)
        self.assertIn("withAnimation(reduceMotion ? nil : .snappy) { pageID = Self.addPageID }", go)
        self.assertIn("show(cats[page].id)", go)

    def test_the_hit_area_is_larger_than_the_dot(self):
        self.assertIn("static let hitWidth: CGFloat = 22", self.dots)
        self.assertIn("static let hitHeight: CGFloat = 44", self.dots)
        self.assertIn(".frame(width: Self.hitWidth, height: Self.hitHeight)", self.dots)
        self.assertIn(".contentShape(Rectangle())", self.dots)
        # The row keeps its 6pt height, so the name above does not move.
        self.assertIn(".padding(.vertical, -(Self.hitHeight - 6) / 2)", self.dots)
        self.assertIn(".frame(height: 6)", self.dots)
        self.assertIn("let side = 6 * CGFloat(dot.scale)", self.dots)

    def test_voiceover_reads_each_dot(self):
        self.assertIn(".accessibilityLabel(label(dot.index))", self.dots)
        self.assertIn('if index == count - 1 { return "この子を追加" }', self.dots)
        self.assertIn("return names[index]", self.dots)
        self.assertIn(".accessibilityAddTraits(dot.index == current ? .isSelected : [])", self.dots)
        hero = section(HOME, "private struct CatHomeHero: View {", "private func nameRow(")
        words = section(hero, "private var words: some View {", "\n    }\n")
        self.assertIn("CatHomePageDots(count: pageCount, current: pageIndex, names: pageNames, go: go)", words)
        self.assertIn("pageNames: cats.map(\\.name),", HOME)
        self.assertIn("lhs.pageNames == rhs.pageNames", HOME)

    def test_the_menu_from_five_cats_is_unchanged(self):
        self.assertIn("static let menuMinimumCats = 5", HOME)
        self.assertIn("menuCats: cats.count >= Self.menuMinimumCats", HOME)


class HeartBurst(unittest.TestCase):
    def setUp(self):
        self.burst = section(WINDOW, "private struct GroupHeartBurst: View {", "\n}\n")
        self.tile = section(WINDOW, "private struct GroupPhotoTile: View {", "private struct GroupHeartBurst: View {")
        self.detail = section(WINDOW, "private struct GroupPhotoDetail: View {", "private struct GroupPhotoPage: View {")

    def test_the_burst(self):
        self.assertIn('Image(systemName: "heart.fill")', self.burst)
        self.assertIn(".foregroundStyle(.white)", self.burst)
        self.assertIn(".shadow(", self.burst)
        self.assertIn("Frame(scale: reduceMotion ? 1 : 0.6)", self.burst)
        self.assertIn("SpringKeyframe(1, duration: 0.3", self.burst)
        self.assertIn("LinearKeyframe(0, duration: 0.3)", self.burst)
        self.assertIn("@Environment(\\.accessibilityReduceMotion) private var reduceMotion", self.burst)
        self.assertIn(".allowsHitTesting(false)", self.burst)
        self.assertIn(".accessibilityHidden(true)", self.burst)

    def test_tile_double_tap_shows_it_only_when_sending(self):
        self.assertIn(".onTapGesture(count: 2) { doubleTapHeart() }", self.tile)
        self.assertIn(".overlay { GroupHeartBurst(trigger: heartBursts) }", self.tile)
        tap = section(self.tile, "private func doubleTapHeart() {", "\n    }\n")
        self.assertIn("let sends = canHeart && !model.myHeartIsActive(entry.id)", tap)
        self.assertIn("if sends { heartBursts &+= 1 }", tap)
        # The haptic is unchanged.
        self.assertIn(".sensoryFeedback(.impact(weight: .light), trigger: heartsSentHere)", self.tile)

    def test_detail_heart_shows_it_over_the_photo(self):
        self.assertIn(".overlay { GroupHeartBurst(trigger: heartBursts) }", self.detail)
        self.assertIn("if model.acceptsHearts(entry.id) && !model.myHeartIsActive(entry.id) { heartBursts &+= 1 }",
                      self.detail)
        self.assertIn(".sensoryFeedback(.impact(weight: .light), trigger: mine) { _, sent in sent }", self.detail)


class ArrivedHearts(unittest.TestCase):
    """4. Hearts that arrived at this person's own photo since its ♡ count was
    last shown on this iPhone: one bounce of the ♡ (none with Reduce Motion),
    no haptic. The counts are kept per まど in UserDefaults, for its own photos
    only, written with markSeen (never while scrolling)."""

    def setUp(self):
        self.tile = section(WINDOW, "private struct GroupPhotoTile: View {", "private struct GroupHeartBurst: View {")

    def test_the_tile_bounces_once_for_its_own_photo(self):
        self.assertIn("private var arrivedHeartsCount: Int? { entry.isOwn && model.showedStored ? heartCount : nil }",
                      self.tile)
        self.assertIn(".onChange(of: arrivedHeartsCount, initial: true) { _, count in", self.tile)
        self.assertIn("guard let count, model.takeArrivedHearts(entry.id, count: count), !reduceMotion else { return }",
                      self.tile)
        self.assertIn(".symbolEffect(.bounce, value: arrivedHeartBounces)", self.tile)
        # No haptic for hearts this person did not send.
        self.assertNotIn("trigger: arrivedHeartBounces", self.tile)

    def test_the_model_compares_with_the_last_count_shown(self):
        take = section(WINDOW, "func takeArrivedHearts(_ photoID: String, count: Int) -> Bool {", "\n    }\n")
        self.assertIn("guard showedStored else { return false }", take)
        self.assertIn("return last.map { count > $0 } ?? false", take)
        self.assertIn("@Published private(set) var showedStored = false", WINDOW)
        save = section(WINDOW, "func saveHeartsShown() {", "\n    }\n")
        self.assertIn("guard heartsShownChanged else { return }", save)
        self.assertIn("let own = Set(entries.lazy.filter(\\.isOwn).map(\\.id))", save)
        seen = section(WINDOW, "private func markSeen() {", "\n    }\n")
        self.assertIn("model.saveHeartsShown()", seen)

    def test_the_store_is_safe_when_missing(self):
        self.assertNotIn("UserDefaults", WINDOW)
        store = section(read("NekoWidget/Services/GroupWindowLocalPhotoStore.swift"), "enum GroupHeartsShown {", "\n}\n")
        self.assertIn('"groupWindow.heartsShown.v1." + windowID', store)
        self.assertIn("as? [String: Int] ?? [:]", store)
        self.assertIn("removeObject(forKey: key(windowID))", store)


class TapTargets(unittest.TestCase):
    def test_growth_replace(self):
        menu = section(GROWTH, 'Label("写真を変える"', ".buttonStyle(.plain)")
        self.assertIn(".frame(minHeight: 44)", menu)
        self.assertIn(".contentShape(Rectangle())", menu)

    def test_showcase_remove_unavailable(self):
        row = section(SHOWCASE, 'Text("表示できない写真は省いています")', "showcase-preparation-remove-unavailable")
        self.assertIn(".frame(minWidth: 44, minHeight: 44)", row)
        self.assertIn(".contentShape(Rectangle())", row)
        self.assertIn('.accessibilityLabel("表示できない写真を外す")', row)

    def test_next_check_clear(self):
        row = section(LOST, "@ViewBuilder private var nextCheckRow: some View {", '"lost-cat-next-check"')
        self.assertIn(".frame(width: 44, height: 44)", row)
        self.assertIn(".foregroundStyle(.secondary)", row)
        self.assertNotIn(".tertiary", row)
        self.assertIn('.accessibilityLabel("次に確かめる日を消す")', row)


if __name__ == "__main__":
    unittest.main()
