"""Scoped-navigation source contracts; native/PhotoKit checks remain required."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/"NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
BROWSER=(ROOT/"NekoWidget/Views/LikedPhotosView.swift").read_text(encoding="utf-8")
def method(start,end):
    return MAIN.split(start,1)[1].split(end,1)[0]
class ScopeBoundaries(unittest.TestCase):
    def test_widget_entry_has_independent_context(self):
        detail=method('private func photoDetail(', '/// Related albums')
        self.assertIn('fromNote',detail)
        self.assertNotIn('selectedTab == .photos',detail)
        self.assertIn('libraryContext',detail)
    def test_sheet_restriction_is_explicit_not_global_tab(self):
        for start,end in [('private func currentDayPhotos(', 'private var unavailableRediscoveryView'),
                          ('private func scopedCatPhotos(', 'private func scopedLifeReference')]:
            section=method(start,end)
            self.assertIn('relatedPhotoUsesLibraryScope',section)
            self.assertNotIn('selectedTab == .photos',section)
    def test_cat_metadata_survives_photo_permission_revocation(self):
        root=(ROOT/"NekoWidget/App/AppRootView.swift").read_text(encoding="utf-8")
        self.assertIn('photoLibraryAssignments: viewModel.catHouseholdIdentity.map',root)
        self.assertIn('photoLibraryProfileNames: viewModel.catHouseholdIdentity.map',root)
        self.assertIn('registeredProfileIdentifiers: photoLibraryRegisteredIdentifiers',MAIN)
    def test_unassigned_cannot_expand_related_navigation(self):
        self.assertIn('photoRediscoveryEnabled',BROWSER)
        self.assertIn('if rediscoveryEnabled, openRelatedAlbum != nil',BROWSER)
        self.assertEqual(BROWSER.count('if rediscoveryEnabled, let photo = selectedPhoto, let date = photo.creationDate,'),2)
        self.assertIn('libraryPhotos: photoLibraryBrowserPhotos',MAIN)
if __name__=="__main__": unittest.main()
