"""Source contracts only; the existing XCTest supplies actual navigation evidence."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
TESTS = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")

class WidgetRelatedAlbumNavigationContracts(unittest.TestCase):
    def setUp(self):
        self.case = TESTS.split("func testWidgetURLPersonalPhotoOpensRelatedAlbumAndReturnsToOriginal()", 1)[1].split("    @MainActor", 1)[0]

    def test_tile_identity_is_independent_of_swiftui_element_type(self):
        self.assertIn('foreground(app.descendants(matching: .any).matching(\n            identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3"', self.case)

    def test_selector_retains_single_foreground_match(self):
        self.assertIn('$0.exists && $0.isHittable }.count == 1', self.case)
        self.assertIn('matches.count == 1 ? matches.first : nil', self.case)
        self.assertNotIn('firstMatch', self.case)

    def test_distinct_photo_and_original_return_are_still_verified(self):
        self.assertIn('XCTAssertNotEqual(relatedDate, originalDate', self.case)
        self.assertIn('Closing related photos must retain the original Widget photo', self.case)
        self.assertIn('closeWidgetPhotoOnce(in: app)', self.case)
        self.assertIn('Foreground element changed before use', self.case)

if __name__ == "__main__":
    unittest.main()
