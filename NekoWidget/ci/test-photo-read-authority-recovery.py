"""Static regression contracts; Swift/PhotoKit runtime checks need macOS."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def read(path):
    return (ROOT / path).read_text(encoding="utf-8")
def block(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]
class PhotoReadAuthorityRecoveryTests(unittest.TestCase):
    def test_resolution_stops_shared_widget_before_async_work(self):
        source = read("NekoWidget/ViewModels/AppViewModel.swift")
        invalidation = block(source, "private func invalidateReadablePhotoProjection()", "private func updatePhotoReadAuthority()")
        self.assertIn("suspendPersonalWidgetAuthority()", invalidation)
        self.assertIn("WidgetCenter.shared.reloadAllTimelines()", invalidation)
        self.assertIn("let authorized = canPresentPhotoCandidates && catIdentityLoadState == .ready", source)
        self.assertGreaterEqual(source.count("await reconcilePersonalWidgetReadAuthority()"), 3)
        self.assertIn("await widgetCacheBuilder.prunePersonalCache(expectedRevision: revision)", source)
    def test_cleanup_uses_current_locked_revision_and_personal_jpegs(self):
        source = read("NekoWidget/Services/WidgetCacheBuilder.swift")
        cleanup = block(source, "func prunePersonalCache", "func clearPersonal")
        self.assertIn("withProtectedCacheFiles(expectedRevision: expectedRevision)", cleanup)
        self.assertIn("Set($0.allCacheFilenames).isSubset(of: protected)", cleanup)
        self.assertLess(cleanup.index("AtomicJSON.write"), cleanup.index("removeItem"))
        self.assertIn('"jpg", "jpeg"', cleanup)
        self.assertNotIn("family", cleanup.lower())
    def test_memory_detail_separates_permission_from_saved_membership(self):
        source = read("NekoWidget/Views/MainTabView.swift")
        detail = block(source, "private func memoryDetailView", "private var unavailablePersonalPhotoView")
        self.assertIn("readablePhotoIdentifiers?.contains(localIdentifier)", detail)
        self.assertIn("let initialPhoto = photo(for: localIdentifier)", detail)
        self.assertIn("photos: selectedTab == .photos ? photoLibraryLikedPhotos : likedPhotos", detail)
        self.assertNotIn("let initialPhoto = likedPhotos.first", detail)
        self.assertIn(".id(photoPresentationVersion.sourceResolutionRevision)", detail)
        root = read("NekoWidget/App/AppRootView.swift")
        self.assertIn("readablePhotoIdentifiers: Set(readableSnapshot.assets.map", root)
        self.assertIn("sourceSnapshot: readableSnapshot", root)
    def test_failed_scan_precedes_waiting_empty_state(self):
        source = read("NekoWidget/Views/HomeView.swift")
        empty = source[source.index("private var emptyPhotoState:"):]
        self.assertLess(empty.index("if scan.hasFailed"), empty.index("else if"))
        self.assertIn('accessibilityIdentifier("photo-hub-scan-failed")', empty)
        self.assertIn("rescan", empty)
if __name__ == "__main__":
    unittest.main()
