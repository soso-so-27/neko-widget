"""Source contracts only; the existing XCTest supplies actual navigation evidence."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
TESTS = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
MAIN = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")

class WidgetRelatedAlbumNavigationContracts(unittest.TestCase):
    def setUp(self):
        self.case = TESTS.split("func testWidgetURLPersonalPhotoOpensRelatedAlbumAndReturnsToOriginal()", 1)[1].split("    @MainActor", 1)[0]

    def test_tile_identity_is_independent_of_swiftui_element_type(self):
        self.assertIn('foreground(app.descendants(matching: .any).matching(\n            identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3"', self.case)

    def test_selector_retains_single_foreground_match(self):
        self.assertIn('$0.exists && $0.isHittable }.count == 1', self.case)
        self.assertIn('matches.count == 1 ? matches.first : nil', self.case)
        self.assertNotIn('firstMatch', self.case)

    def test_direct_destinations_pass_the_installed_hosts_action(self):
        direct = MAIN.split('func widgetPhotoDestination(', 1)[1].split('private func relatedAlbumsSheet', 1)[0]
        self.assertEqual(direct.count('openRelatedAlbumOverride: openRelatedAlbum'), 2)
        self.assertEqual(direct.count('sheet: relatedAlbumsSheet) { openRelatedAlbum in'), 2)
        host = MAIN.split('private struct PhotoRelatedAlbumsHost', 1)[1].split('private struct PhotoRelatedAlbumsSheet', 1)[0]
        self.assertIn('content({ route = $0 })', host)
        self.assertIn('.sheet(item: $route, content: sheet)', host)
        self.assertNotIn('self.content = content()', host)

    def test_nearest_browser_environment_keeps_normal_route_fallback(self):
        detail = MAIN.split('private func photoDetail(', 1)[1].split('private func relatedAlbums(', 1)[0]
        self.assertIn('openRelatedAlbumOverride: OpenPhotoRelatedAlbum? = nil', detail)
        self.assertIn('.environment(\\.openPhotoRelatedAlbum, openRelatedAlbumOverride', detail)
        self.assertIn('libraryContext ? openPhotoLibraryRelatedAlbum', detail)
        self.assertIn('relatedPhotoUsesLibraryScope = false; relatedPhotoRoute = $0', detail)

    def test_distinct_photo_and_original_return_are_still_verified(self):
        self.assertIn('_ = try foreground(closeRelated)', self.case)
        self.assertLess(self.case.index('_ = try foreground(closeRelated)'),
                        self.case.index('curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3'))
        self.assertIn('XCTAssertNotEqual(relatedDate, originalDate', self.case)
        self.assertIn('Closing related photos must retain the original Widget photo', self.case)
        self.assertIn('closeWidgetPhotoOnce(in: app)', self.case)
        self.assertIn('Foreground element changed before use', self.case)

    def test_widget_route_is_never_replaced_by_the_cold_start_tab(self):
        # 11/8: a Widget link that opens 「この写真は開けません」 kept no route
        # mark, so the start-tab policy could move the app to the last tab.
        route = MAIN.split('.onChange(of: deepLinkSelection, initial: true)', 1)[1]
        route = route.split('.onChange(of: deepLinkedFamilyWindowIsPresented', 1)[0]
        self.assertIn('didApplyInitialTab = true', route)
        self.assertLess(route.index('didApplyInitialTab = true'), route.index('guard !excludedCatCandidateIdentifiers'))
        self.assertEqual(route.count('selectedTab = .photos'), 2)
        self.assertNotIn('MainTabStartupPolicy', route)
        start = MAIN.split('guard !didApplyInitialTab else { return }', 1)[1].split('@StateObject', 1)[0]
        self.assertIn('MainTabStartupPolicy.selection(', start)

if __name__ == "__main__":
    unittest.main()
