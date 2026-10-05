"""Source contracts for two observed Simulator failures; native rerun still required."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / "NekoWidget/Views/PhotoMemoryNoteLibraryView.swift").read_text(encoding="utf-8")
UI = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")

class MemoRowNavigationTests(unittest.TestCase):
    def test_plain_memo_link_has_a_hit_shape_without_thumbnail(self):
        row = VIEW.split("private func row(", 1)[1].split("struct PersonalArchivePhotosSection", 1)[0]
        self.assertIn(".contentShape(Rectangle())", row)
        denied = UI.split("func testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations()", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('unavailableMemo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()', denied)
        self.assertIn('memory-note-photo-unavailable', denied)
        self.assertIn('XCTAssertFalse(memoApp.buttons["memory-note-photo"].exists', denied)
        self.assertIn('Photo authority changes must preserve local memo text.', denied)

    def test_large_weight_fixture_reveals_the_matching_record(self):
        helper = UI.split("private func launchWeightMemo(", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('app.keyboards.firstMatch.waitForNonExistence', helper)
        self.assertIn('app.scrollViews["memory-notes-list"]', helper)
        self.assertIn('notesList.swipeUp(velocity: .slow)', helper)
        self.assertIn('row.exists && row.isHittable', helper)
        self.assertIn('食べる量が少なかった', helper)
        case = UI.split("func testVeterinaryWithoutPhotoKeepsUnknownMeasurementDayAtLargestText()", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('reading.staticTexts["むぎ · 測定日 不明"]', case)
        self.assertIn('XCTAssertFalse(reading.staticTexts["選んでいない別の猫の記録"].exists)', case)

if __name__ == "__main__":
    unittest.main()
