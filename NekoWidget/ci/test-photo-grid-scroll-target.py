"""Static selector contracts, not Simulator navigation evidence."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOME = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(encoding="utf-8")
MAIN = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
UI = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")

class PhotoGridScrollTargetTests(unittest.TestCase):
    def test_photo_scroll_is_identified_separately_from_cat_picker(self):
        self.assertIn('ScrollView(.horizontal)', MAIN)
        self.assertIn('.accessibilityIdentifier("photos-cat-picker")', MAIN)
        self.assertIn('.accessibilityIdentifier("photo-library-all-scroll")', HOME)

    def test_paging_gestures_target_photo_collection(self):
        case = UI.split('func testPhotoGridRevealsFollowingBatchesAndKeepsReturnPosition()', 1)[1].split('    @MainActor', 1)[0]
        self.assertIn('let photoList = app.scrollViews["photo-library-all-scroll"]', case)
        self.assertIn('photoList.swipeUp()', case)
        self.assertNotIn('scrollViews.firstMatch', case)
        self.assertIn('for number in [25, 49]', case)
        self.assertIn('Returning preserves the opened row', case)
        self.assertIn('target.isHittable', case)
        self.assertIn('number) / 50', case)

if __name__ == "__main__":
    unittest.main()
