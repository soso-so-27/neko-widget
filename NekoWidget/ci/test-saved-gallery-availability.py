"""Static presentation contracts; Swift/iOS execution requires an Apple host."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "NekoWidget/Views/LikedPhotosView.swift").read_text(encoding="utf-8")
GALLERY = SOURCE[SOURCE.index("struct SavedMemoriesGalleryView: View {"):]

class SavedGalleryAvailabilityTests(unittest.TestCase):
    def test_denied_unknown_and_unavailable_are_distinct_from_zero_saved(self):
        states = GALLERY[GALLERY.index("private var emptyGalleryState:"):GALLERY.index("private var unavailableSavedPhotosBanner:")]
        self.assertLess(states.index("if !hasPhotoAccess"), states.index("else if savedStateReadFailed"))
        self.assertLess(states.index("else if savedStateReadFailed"), states.index("else if unavailableSavedPhotoCount > 0"))
        self.assertLess(states.index("saved-memories-photos-unavailable"), states.index("saved-memories-empty"))
        for identifier in ["saved-memories-photo-access-unavailable", "saved-memories-state-read-failed", "saved-memories-photos-unavailable", "saved-memories-empty"]:
            self.assertIn(identifier, states)

    def test_partial_unavailability_retains_grid_and_denied_access_hides_actions(self):
        body = GALLERY[GALLERY.index("var body: some View"):GALLERY.index("private var emptyGalleryState:")]
        self.assertIn("if !hasPhotoAccess || photos.isEmpty", body)
        self.assertIn("if savedStateReadFailed || unavailableSavedPhotoCount > 0", body)
        self.assertIn("ForEach(PhotoLibraryGridRow.rows(photos))", body)
        self.assertIn("if hasPhotoAccess && !photos.isEmpty", body)
        self.assertIn("if hasPhotoAccess && isSelectingForExport", body)
        self.assertIn("selectedExportIdentifiers.formIntersection(available)", body)
        self.assertIn("photoBookExportTask?.cancel()", body)

    def test_scope_position_is_optional_and_existing_callers_keep_defaults(self):
        self.assertIn('readingPositionKey: String? = nil', GALLERY)
        self.assertIn('unavailableSavedPhotoCount: Int = 0', GALLERY)
        self.assertIn('hasPhotoAccess: Bool = true', GALLERY)
        self.assertIn('savedStateReadFailed: Bool = false', GALLERY)
        self.assertIn('section: isEmbedded ? (readingPositionKey ?? "favorites") : nil', GALLERY)
        self.assertIn('self.unavailableSavedPhotoCount = max(0, unavailableSavedPhotoCount)', GALLERY)

if __name__ == "__main__":
    unittest.main()
