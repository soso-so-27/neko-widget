"""Source contracts for the 写真 tab's reading position (11/8 memo return).

Not native scroll evidence: MomentDeliveryComposerUITests.
testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto checks the real list.
Back from 「スクロール確認 8」 the memo list showed 13-16, because
1. the reappearing list (same scroll view, offset kept) was scrolled to the
   saved top row, and
2. that top row was the first row the lazy stack had made, rows above the
   screen, instead of the first row still on screen.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOME = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(encoding="utf-8")
NOTES = (ROOT / "NekoWidget/Views/PhotoMemoryNoteLibraryView.swift").read_text(encoding="utf-8")


def block(source, marker):
    if source.count(marker) != 1:
        raise AssertionError(f"Expected one {marker}")
    start = source.index(marker)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker}")


def code(source):
    """Drop // comments so a comment cannot satisfy or break a contract."""
    return re.sub(r"//[^\n]*", "", source)


def validate(home=HOME, notes=NOTES):
    restoration = code(block(home, "private struct PhotoLibraryPositionRestoration:"))
    appear = block(restoration, ".onAppear {")
    # A list coming back (Back from a memo or photo) keeps its native offset.
    guard = appear.find("guard !tracker.hasAppeared else {")
    marked = appear.find("tracker.hasAppeared = true")
    restore = appear.find("restore(saved, with: proxy)")
    if not 0 <= guard < marked < restore:
        raise AssertionError("Only the first appearance of a list may restore")
    early = block(appear, "guard !tracker.hasAppeared else {")
    if "restore(" in early or "scrollTo" in early or "return" not in early:
        raise AssertionError("A reappearing list must return without moving")
    if "save(" in appear or "defaults" in appear:
        raise AssertionError("Appearing must not write UserDefaults")
    if ".environment(\\.photoLibraryReadingTop, readingTop)" not in restoration:
        raise AssertionError("Rows need the visible top of their list")
    if "{ $0.safeAreaInsets.top } action: { readingTop = $0 }" not in restoration:
        raise AssertionError("The visible top is the list's top inset")

    tracker = code(block(home, "final class PhotoLibraryRowTracker {"))
    report = block(tracker, "private func report()")
    if "!passed.contains(id)" not in report or "rendered" not in report:
        raise AssertionError("The top row is the first made row not yet past the top")
    if "visible.min" in report:
        raise AssertionError("The first made row is not the top row")
    if "report()" in block(tracker, "func disappear("):
        raise AssertionError("Rows leaving with the whole list must not move the place")
    move = block(tracker, "func move(")
    if "passed.insert(id)" not in move or "passed.remove(id)" not in move or "report()" not in move:
        raise AssertionError("A row crossing the top updates the top row")
    if "defaults" in tracker or "save(" in tracker:
        raise AssertionError("The tracker runs while scrolling and must not write UserDefaults")

    row = code(block(home, "private struct PhotoLibraryReadingRow:"))
    if "$0.frame(in: .scrollView).midY <= top" not in row or "tracker.move(id, isPast: isPast)" not in row:
        raise AssertionError("Rows report only their flip past the visible top")
    if "onGeometryChange(for: Bool.self)" not in row:
        raise AssertionError("Report a Bool so scrolling does not redraw rows")
    if "@State" in row or "defaults" in row:
        raise AssertionError("Rows keep no state while scrolling")

    remember = code(block(home, "static func remember("))
    if "defaults" in remember or "save(" in remember:
        raise AssertionError("Scrolling keeps the place in memory only")

    # The memo page is one of these lists.
    reading = code(block(notes, "@ViewBuilder private var readingList: some View"))
    if ".restoringPhotoLibraryPosition(section: positionSection," not in reading:
        raise AssertionError("The memo list restores its place")
    if ".photoLibraryReadingRow(item.id, index: index)" not in code(notes):
        raise AssertionError("Memo rows report their place")


def top_row(rows, rendered, passed):
    """The rule in PhotoLibraryRowTracker.report(), for the example below."""
    candidates = [index for index, row in enumerate(rows) if row in rendered and row not in passed]
    return rows[min(candidates)] if candidates else None


class ReturnPositionContracts(unittest.TestCase):
    def test_shipping_source(self):
        validate()

    def test_mutations_fail(self):
        appear_guard = "guard !tracker.hasAppeared else {"
        for source in (
            HOME.replace(appear_guard, "guard true else {", 1),
            HOME.replace("tracker.userScrolled = false\n                            PhotoLibraryReadingPosition.diagnose(\"reappear",
                         "restore(PhotoLibraryReadingPosition.identifier(for: section), with: proxy)\n                            PhotoLibraryReadingPosition.diagnose(\"reappear", 1),
            HOME.replace("!passed.contains(id) && ", "", 1),
            HOME.replace("rendered[id] = nil\n", "rendered[id] = nil\n        report()\n", 1),
            HOME.replace("$0.frame(in: .scrollView).midY <= top", "true", 1),
            HOME.replace("tracker.move(id, isPast: isPast)", "_ = isPast", 1),
            HOME.replace("unsaved[section] = identifier", "defaults.set(identifier, forKey: section)", 1),
        ):
            with self.subTest(), self.assertRaises(AssertionError):
                validate(source, NOTES)

    def test_made_rows_above_the_screen_are_not_the_top(self):
        rows = [f"note-{label}" for label in range(24, 0, -1)]
        # Rows 16-9 still made above the screen; row 12 is the first on it.
        rendered = set(rows[8:22])
        passed = set(rows[8:12])
        self.assertEqual(top_row(rows, rendered, set()), "note-16")
        self.assertEqual(top_row(rows, rendered, passed), "note-12")


if __name__ == "__main__":
    unittest.main()
