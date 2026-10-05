"""Static cross-process synchronization contracts; iOS runtime checks need macOS."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

def block(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

class SharedLikeBrowserSyncTests(unittest.TestCase):
    def test_sync_notifies_canonical_changes_even_if_scan_already_updated_snapshot(self):
        source = (ROOT / "NekoWidget/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")
        sync = block(source, "private func synchronizeSharedLikes(", "private func refreshLikeInteractionState()")
        self.assertIn("let confirmedChanges = records.values.filter", sync)
        self.assertIn("sharedLikeRecords[$0.localIdentifier]?.isLiked != $0.isLiked", sync)
        self.assertLess(sync.index("let confirmedChanges"), sync.index("sharedLikeRecords = records"))
        publication = sync.index("for record in confirmedChanges")
        self.assertGreater(publication, sync.index("snapshot = updatedSnapshot"))
        self.assertIn("name: .confirmedMemorySavedStateChanged", sync[publication:])
        self.assertIn("isSaved: record.isLiked", sync[publication:])
        # This publication is outside changedCount > 0: a scan may already have
        # updated the snapshot while an open browser retains its override.
        self.assertGreater(publication, sync.index("let sharedLikedCount"))

    def test_failed_read_cannot_publish_an_empty_or_optimistic_saved_value(self):
        source = (ROOT / "NekoWidget/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")
        sync = block(source, "private func synchronizeSharedLikes(", "private func refreshLikeInteractionState()")
        self.assertLess(sync.index("try SharedLikeStore.readAll()"), sync.index("let confirmedChanges"))
        self.assertNotIn("confirmedMemorySavedStateChanged", sync[sync.index("} catch {"):])

    def test_browser_consumes_confirmed_values_for_both_save_and_unsave(self):
        source = (ROOT / "NekoWidget/Views/LikedPhotosView.swift").read_text(encoding="utf-8")
        self.assertIn("confirmedMemorySavedStates[change.localIdentifier] = change.isSaved", source)
        self.assertIn("confirmedMemorySavedStates[selectedPhoto.localIdentifier]", source)

if __name__ == "__main__":
    unittest.main()
