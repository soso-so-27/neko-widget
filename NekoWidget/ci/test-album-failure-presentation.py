"""Source wiring checks; native behavioral/UI verifiers require macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


class AlbumFailurePresentationTests(unittest.TestCase):
    def test_source_loss_reaches_album_and_existing_photo_recovery(self):
        main = read("NekoWidget/Views/MainTabView.swift")
        view = read("NekoWidget/Views/LikedPhotosView.swift")
        album = between(main, "private func albumsView(", "private func albumCatalogDestination(")
        self.assertIn("isPhotoSourceUnavailable: photoSourceStatus == .unavailable", album)
        recovery = between(album, "recoverPhotoSource: {", "albumSections:")
        for action in ["openPhotosOverride?()", "photoLibrarySelection.select(.all)",
                       "photosPath = NavigationPath()", "selectedTab = .photos"]:
            self.assertIn(action, recovery)
        root = between(view, "    var body: some View {\n        ScrollView {\n        Group {", "private var catNavigation:")
        self.assertIn("if isPhotoSourceUnavailable {", root)
        self.assertIn("Button(action: recoverPhotoSource)", root)
        self.assertIn("} else if hasPhotoAccess {", root)
        self.assertIn("if !isPhotoSourceUnavailable &&", root)

    def test_memo_failure_does_not_publish_empty_success_or_freeze(self):
        view = read("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn(".task(id: memoRetryRevision)", view)
        load = between(view, ".task(id: memoRetryRevision)", ".onChange(of: isPreparingAlbums)")
        self.assertNotIn("try?", load)
        self.assertIn("didLoadMemos = false", load)
        success, failure = load.split("} catch {", 1)
        self.assertIn("memoRecords = records", success)
        self.assertIn("didLoadMemos = true", success)
        self.assertIn("freezeRecommendations(allowAppend: true)", success)
        self.assertIn("memoLoadFailed = true", failure)
        self.assertIn("guard !Task.isCancelled", failure)
        self.assertNotIn("memoRecords =", failure)
        self.assertNotIn("didLoadMemos = true", failure)
        self.assertNotIn("freezeRecommendations", failure)
        freeze = between(view, "private func freezeRecommendations(", "    var body: some View {\n        ScrollView {\n        Group {")
        self.assertIn("guard didLoadMemos", freeze)
        self.assertIn("distinctRecommendations(featuredRecommendations + proposedRecommendations)", freeze)
        self.assertIn("memoRetryRevision &+= 1", view)

    def test_terminal_scan_failure_is_projected_without_promoting_provisional_results(self):
        root = read("NekoWidget/App/AppRootView.swift")
        scan = between(root, "private func scanPresentation(", "private var settingsPresentation:")
        self.assertIn("hasFailed: state.phase == .failed", scan)
        self.assertIn("case .provisional:", scan)
        self.assertIn("presentation.preliminaryCatAssets = records.count", scan)
        model = read("NekoWidget/Views/AppPresentationModels.swift")
        self.assertIn("!hasFailed && isGroupedAlbumUpgrade", model)
        view = read("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn("if scan.hasFailed {", view)
        self.assertIn('accessibilityIdentifier("albums-scan-failed")', view)
        native = read("ci/verify-album-grouping.swift")
        self.assertIn("try verifyGroupedScanFailurePresentation()", native)


if __name__ == "__main__":
    unittest.main()
