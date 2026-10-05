"""Source contracts; not a replacement for native scroll/render checks."""
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
HOME = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(encoding="utf-8")
VM = (ROOT / "NekoWidget/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")
class ReadingControls(unittest.TestCase):
    def test_scoped_return_drops_stale_callback(self):
        self.assertIn('userInfo: ["section": section]', HOME)
        self.assertIn('generation == restorationGeneration', HOME)
        self.assertIn('.onChange(of: self.section)', HOME)
    def test_month_jump_preserves_collection(self):
        jump = HOME.split('private func moveToMonth(', 1)[1].split('@ViewBuilder', 1)[0]
        self.assertIn('index + 24', jump)
        self.assertIn('PhotoLibraryGridRow.identifier(containing:', jump)
        self.assertIn('section: readingPositionKey ?? "all"', jump)
    def test_partial_failure_keeps_photos_and_retry(self):
        self.assertIn('if !catPhotos.isEmpty {', HOME)
        self.assertIn('scan.hasFailed || scan.hasDeferredAssets || scan.isScanning || scan.isPaused', HOME)
        self.assertIn('.disabled(scan.isScanning)', HOME)
        method = VM.split('func rescan() async {', 1)[1].split('func suspendScan()', 1)[0]
        self.assertLess(method.index('isManualRescanRequestPending = true'), method.index('await saveSnapshot'))
        self.assertIn('defer { isManualRescanRequestPending = false }', method)
    def test_reselecting_current_mode_preserves_scoped_position_owner(self):
        main=(ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
        selection=main.split('func select(_ section: PhotoLibrarySection)',1)[1].split('func resolveInitialSelection',1)[0]
        self.assertIn('if selection != section',selection)
        self.assertIn('hasResolvedSelection = true',selection)
    def test_saved_metadata_is_published_separately(self):
        self.assertIn('@Published private(set) var savedPhotoIdentifiers', VM)
        self.assertIn('savedPhotoStateReadFailed = true', VM)
        self.assertIn('savedPhotoStateReadFailed = false', VM)
if __name__ == "__main__":
    unittest.main()
