"""Static album layout contracts. Native verifier and SwiftUI require Apple tools."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

def read(name):
    return (ROOT / name).read_text(encoding="utf-8")

def block(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

class AlbumShelfLayoutTests(unittest.TestCase):
    def test_one_selected_photo_collection_and_no_memo_or_movie_hero(self):
        source = read("NekoWidget/Views/LikedPhotosView.swift")
        hero = block(source, "private var featuredPhotoRecommendation:", "@ViewBuilder private func recommendationLink")
        self.assertIn("case .highlight, .month: true", hero)
        self.assertIn("case .memo, .movie: false", hero)
        self.assertIn("recommendedHighlights.first.map(AlbumRecommendationItem.highlight)", hero)
        self.assertIn("hasPeriodCollections ? months.first.map(AlbumRecommendationItem.month)", hero)
        self.assertNotIn("ForEach", hero)
        self.assertNotIn("ScrollView(.horizontal)", hero)
        self.assertIn('accessibilityIdentifier("albums-pickup-cover")', hero)
        self.assertIn("featuredContent: featuredPhotoRecommendation == nil ? nil", source)

    def test_all_secondary_themes_keep_routes_and_february_22_is_in_date_archive(self):
        source = read("NekoWidget/Views/LikedPhotosView.swift")
        explore = block(source, "private func timeAlbums", "private func albumLink")
        self.assertIn("AlbumShelfLayoutPolicy.secondaryThemes(in: sections)", explore)
        self.assertIn("ForEach(secondary)", explore)
        self.assertIn("NavigationLink(value: route(for: album.id))", explore)
        self.assertIn("AlbumShelfLayoutPolicy.dateAlbums(in: sections)", explore)
        self.assertIn('periodShelf(dates, title: "日付から探す")', explore)
        self.assertIn('periodShelf(lifePeriods, title: "年齢・暮らした時期", compact: true)', explore)
        self.assertIn("!periods.isEmpty || !dates.isEmpty", explore)
        self.assertIn("hasPeriodCollections ? AnyView(reflectionShelf)", source)
        routes = read("NekoWidget/Views/MainTabView.swift")
        self.assertIn("case .memoryNotes:", routes)
        self.assertIn("PhotoMemoryNotesListView(photos: memoryNotePhotos", routes)
        self.assertIn("PhotoMemoryNoteDetailView(recordID: identifier", routes)

    def test_theme_photos_use_existing_pipeline_and_accessibility_layout(self):
        source = read("NekoWidget/Views/LikedPhotosView.swift")
        card = block(source, "private struct AlbumThemeEntry:", "private struct AlbumCatalogEntry:")
        self.assertIn("PhotoAssetImageView(", card)
        self.assertIn("album.coverPhoto.localIdentifier", card)
        self.assertIn("Text(album.countLabel)", card)
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 1 : 2", source)
        native = read("ci/verify-album-grouping.swift")
        self.assertIn("try verifyAlbumShelfPreservesSparseAndSecondaryCollections()", native)
        self.assertIn("Set(reached) == Set(input.flatMap", native)

if __name__ == "__main__":
    unittest.main()
