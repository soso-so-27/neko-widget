"""Source contracts for 確かな猫 / たぶん猫 (11/14).

After the cat line moved to 0.5 (11/13), an otter photo became the cover of
「昔と最近」 and 「2020年」. The stored best cat confidence now has two tiers:

- 確かな猫: >= AppSettings.confidentCatThreshold (0.7, the old line), or a
  photo the user vouched for (saved, included for a cat, key photo, linked
  album). A detected record with no stored confidence (0) is an old record
  that passed 0.7, so it counts as 確かな猫.
- たぶん猫: 0.5 ..< 0.7.

Every place where the app chooses photos by itself uses 確かな猫 first and
falls back to たぶん猫 only when there are not enough. Lists the user browses
and every count keep both tiers, unchanged. Nothing is rescanned; the
widget-side tier travels as optional keys older builds ignore.

Native behaviour: NekoWidgetTests ConfidentCatPickTests (in
CatThresholdTests.swift), ci/verify-personal-rediscovery.swift and
ci/verify-cloudy-window.swift.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


SETTINGS = read("Shared/Models/AppSettings.swift")
DETECTION = read("Shared/Models/CatDetection.swift")
RECORD = read("Shared/Models/AssetRecord.swift")
IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
REDISCOVERY = read("Shared/Storage/PersonalRediscoveryStore.swift")
CLOUDY = read("Shared/Storage/CloudyWindowStore.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
PRESENTATION = read("NekoWidget/Views/AppPresentationModels.swift")
PROFILES = read("NekoWidget/Views/CatProfilesPresentation.swift")
GROWTH = read("NekoWidget/Views/GrowthAlbumSelector.swift")
PROTOTYPE = read("NekoWidget/Views/AlbumPrototypeView.swift")
MONTHLY = read("NekoWidget/Views/MonthlyWindowPresentation.swift")
MOVIE = read("NekoWidget/Views/SeasonalMoviePresentation.swift")
MOVIE_SERVICE = read("NekoWidget/Services/SeasonalMovieCandidateService.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
LIKED = read("NekoWidget/Views/LikedPhotosView.swift")
SHOWCASE = read("NekoWidget/Services/ShowcasePhotoStore.swift")
CACHE = read("NekoWidget/Services/WidgetCacheBuilder.swift")
SELECTORS = read("NekoWidget/Services/PhotoSelectors.swift")
COVERAGE = read("NekoWidget/Services/CatPhotoCoverageMeasurement.swift")
SCANNER = read("NekoWidget/Services/PhotoLibraryScanner.swift")
TESTS = read("NekoWidgetTests/CatThresholdTests.swift")
QUICK = read("ci/run-quick-ios-checks.sh")


class TierTests(unittest.TestCase):
    def test_named_line_next_to_the_detection_line(self):
        self.assertIn("static let defaultConfidenceThreshold: Float = 0.5", SETTINGS)
        self.assertIn("static let confidentCatThreshold: Float = 0.7", SETTINGS)
        self.assertLess(SETTINGS.index("defaultConfidenceThreshold: Float = 0.5"),
                        SETTINGS.index("confidentCatThreshold: Float = 0.7"))
        # The detection line itself is untouched; nothing is rescanned.
        self.assertIn("confidenceThreshold: defaultConfidenceThreshold,", SETTINGS)
        self.assertIn("static let currentDetectorPolicyVersion = 2", SETTINGS)

    def test_one_shared_cheap_helper(self):
        tier = section(DETECTION, "enum CatPickTier {", "\n}\n")
        self.assertIn("static func isConfident(storedConfidence: Float) -> Bool", tier)
        # A missing (0) stored confidence is an old record that passed 0.7.
        self.assertIn("guard storedConfidence.isFinite, storedConfidence > 0 else { return true }", tier)
        self.assertIn("return storedConfidence >= AppSettings.confidentCatThreshold", tier)
        self.assertIn("static func confidentFirst<Item>(", tier)
        self.assertIn("var isConfidentCat: Bool { CatPickTier.isConfident(storedConfidence: confidence) }",
                      DETECTION)
        record = section(RECORD, "var isConfidentCat: Bool {", "}")
        self.assertIn("liked || cat.isConfidentCat", record)

    def test_user_vouched_photos(self):
        vouched = section(IDENTITY, "var userVouchedAssetIdentifiers: Set<String> {", "\n    }\n")
        for needle in ("photoAlbumLink?.lastKnownAssetLocalIdentifiers", "keyPhotoLocalIdentifier",
                       "membership.decision == .included"):
            self.assertIn(needle, vouched)
        self.assertNotIn("singleCat", vouched)
        picks = section(VIEW_MODEL, "func isConfidentCatForPicks(_ asset: AssetRecord) -> Bool {", "}")
        self.assertIn("asset.isConfidentCat || userVouchedCatPhotoIdentifiers.contains(asset.localIdentifier)", picks)
        # Built once per presentation version, not per photo.
        self.assertIn("cachedUserVouchedCatPhotoIdentifiers", VIEW_MODEL)

    def test_no_rescan_and_no_copy_of_the_line(self):
        self.assertNotIn("isConfidentCat", SCANNER)
        self.assertNotIn("0.70", MOVIE_SERVICE)
        self.assertIn("private static let catConfidenceThreshold = AppSettings.confidentCatThreshold", MOVIE_SERVICE)
        self.assertNotIn(">= 0.70", CACHE)
        self.assertIn("$0.confidence >= AppSettings.confidentCatThreshold", CACHE)


class PresentationTests(unittest.TestCase):
    def test_photo_presentation_carries_the_tier(self):
        self.assertIn("let isConfidentCat: Bool", PRESENTATION)
        self.assertIn("isConfidentCat: Bool = true", PRESENTATION)
        self.assertIn("isConfidentCat: isConfidentCat", section(PRESENTATION, "var householdGrowthCandidate", "\n}\n"))
        self.assertIn("isConfidentCat: viewModel.isConfidentCatForPicks(asset)", ROOT_VIEW)
        self.assertIn("isConfidentCat: isLinkedAlbumPhoto\n                || membership?.decision == .included", ROOT_VIEW)
        self.assertIn("var isConfidentCat: Bool", PROFILES)

    def test_covers_are_confident(self):
        self.assertEqual(PRESENTATION.count("photos.first(where: \\.isConfidentCat) ?? photos[0]"), 2)
        self.assertNotIn("var coverPhoto: PhotoPresentation { photos[0] }", PRESENTATION)
        # 「この子」 hero / cat thumbnail without a key photo.
        self.assertIn("}) ?? confirmed.first(where: \\.isConfidentCat) ?? confirmed.first,", ROOT_VIEW)
        # Onboarding 「見つかりました」 preview.
        self.assertIn("CatPickTier.confidentFirst(viewModel.catAssets,", ROOT_VIEW)

    def test_theme_membership_orders_confident_first_but_all_photos_stay(self):
        album = section(PRESENTATION, "    private func album(\n", "    private func albumPreservingOrder(")
        self.assertIn("CatPickTier.confidentFirst(\n            photos.sorted(by: newestFirst),", album)
        # The browse grid (すべての猫写真) keeps newest first, both tiers.
        self.assertIn("albumPreservingOrder(\n                .allCatPhotos,", PRESENTATION)
        highlights = section(PRESENTATION, "struct AlbumHighlightBuilder {", "func featured(")
        self.assertIn("sceneRepresentatives(from: photos.filter(\\.isConfidentCat))", highlights)
        self.assertIn("confidentScenes.count >= Self.minimumSceneCount", highlights)

    def test_growth_prefers_confident(self):
        select = section(GROWTH, "    func select(\n", "    func candidateGroups(")
        self.assertIn("group.photos.contains(where: \\.isConfidentCat)", select)
        self.assertIn("confidentGroups.count >= GrowthAlbumVisibilityPolicy.minimumComparablePeriods", select)
        preferred = section(GROWTH, "    private func isPreferred(", "    private func comparableArea(")
        self.assertLess(preferred.index("isConfidentCat"), preferred.index("isLiked"))
        self.assertIn("if candidate.confidentCount != current.confidentCount", GROWTH)
        self.assertIn("if candidate.confident != current.confident { return candidate.confident }", GROWTH)


class WorkTests(unittest.TestCase):
    def test_monthly_and_year_picks(self):
        self.assertIn("static func tiers(_ photos: [PhotoPresentation]) -> [[PhotoPresentation]]", PROTOTYPE)
        self.assertEqual(PROTOTYPE.count("for tier in tiers(photos) {"), 2)
        self.assertIn("if lhs.isConfidentCat != rhs.isConfidentCat { return lhs.isConfidentCat }", PROTOTYPE)
        self.assertIn("let candidates = Array(AlbumPrototype.ranked(source).prefix(24))", PROTOTYPE)
        self.assertNotIn("source.sorted { AlbumPrototype.score($0) > AlbumPrototype.score($1) }", PROTOTYPE)

    def test_monthly_window(self):
        build = section(MONTHLY, "    func build(\n", "    func buildMostRecent(")
        self.assertIn("let confidentScenes = scenePhotos.filter(\\.isConfidentCat)", build)
        self.assertIn("confidentScenes.count >= Self.minimumSceneCount", build)
        # The month's availability still counts both tiers.
        self.assertIn("availableSceneCount: scenePhotos.count", build)
        self.assertIn("return story.first(where: \\.isConfidentCat) ?? story.first", MONTHLY)
        self.assertIn("previewPhotos: month.previewPhotos", LIKED)

    def test_seasonal_movie(self):
        self.assertIn("probableCatIdentifiers: Set<String>", MOVIE)
        self.assertEqual(MAIN.count("probableCatIdentifiers: probableCatIdentifiers"), 2)
        self.assertIn(".filter { !$0.isConfidentCat }.map(\\.localIdentifier))", MAIN)

    def test_showcase_recommendation(self):
        recommender = section(SHOWCASE, "enum ShowcaseRecommender {", "private static func similar(")
        self.assertEqual(recommender.count("isConfidentCat != second"), 2)
        self.assertIn("for tier in tiers {", recommender)
        # The refresh rule of an おすすめ set is not touched here.
        self.assertIn("set made only by おすすめ", MAIN)


class WidgetTests(unittest.TestCase):
    def test_daily_photo_plan(self):
        self.assertIn("var isProbableCat: Bool? = nil", section(REDISCOVERY, "struct PersonalRediscoveryCandidate", "\n}\n"))
        ordered = section(REDISCOVERY, "    private func ordered(", "    private func lastUsage(")
        self.assertIn("remaining.filter { $0.isProbableCat != true }", ordered)
        self.assertIn("func updateCatTiers(probablePhotoIDs: Set<String>, now: Date = .now) throws", REDISCOVERY)
        defer = section(REDISCOVERY, "private func deferProbableCats(", "    private func entry(")
        # Today's slot and every issued Widget slot stay.
        self.assertIn("var firstMovable = Self.slot(at: now, in: plan) + 1", defer)
        self.assertIn("for issue in state.issues where !issue.invalidated", defer)
        self.assertIn("deferProbableCats(&state, now: now)", section(REDISCOVERY, "    func publish(", "    func withProtectedCacheFiles"))
        self.assertIn("PersonalRediscoveryStore.shared.updateCatTiers(", VIEW_MODEL)
        self.assertEqual(VIEW_MODEL.count("probablePhotoIDs: probable"), 2)
        self.assertIn("ordered = CatPickTier.confidentFirst(ordered) { !isProbable($0) }", CACHE)
        self.assertIn("isProbableCat: isProbable(record)", CACHE)

    def test_today_photo(self):
        policy = section(SELECTORS, "enum TodayPhotoSelectionPolicy {", "static func localDayKey(")
        self.assertIn("let confident = eligible.filter(isConfident)", policy)
        self.assertLess(policy.index("let retained"), policy.index("let confident"))
        self.assertIn("isConfident: isConfidentCatForPicks", VIEW_MODEL)

    def test_cloudy_window(self):
        metadata = section(CLOUDY, "struct CloudyWindowPhotoMetadata", "\n}\n")
        self.assertIn("var isProbableCat: Bool? = nil", metadata)
        choose = section(CLOUDY, "private func choose(state:", "private func similar(")
        self.assertIn("state.metadata[photo.photoID]?.isProbableCat == true", choose)
        self.assertLess(choose.index("isProbableCat"), choose.index("let last = previous.first"))
        self.assertIn("isProbableCat: !isConfidentCatForPicks(record))", VIEW_MODEL)


class MeasurementAndTests(unittest.TestCase):
    def test_coverage_measurement_keeps_v2(self):
        self.assertIn('lines.append("cat-photo-coverage v2")', COVERAGE)
        self.assertIn('lines.append("stored best cat, in linked albums: "', COVERAGE)
        self.assertIn('lines.append("stored best cat, elsewhere: "', COVERAGE)
        self.assertIn("return record.cat.isConfidentCat ? 2 : 1", COVERAGE)
        self.assertNotIn("record.cat.confidence < 0.7", COVERAGE)

    def test_native_tests_and_registration(self):
        self.assertIn("final class ConfidentCatPickTests: XCTestCase", TESTS)
        for name in ("testMissingStoredConfidenceIsAnOldConfidentRecord",
                     "testThemeCoversAreConfidentAndMembershipKeepsBoth",
                     "testGrowthLeavesOutAPeriodWithOnlyProbablePhotos",
                     "testMonthlyWorkFallsBackAndKeepsAConfidentCover",
                     "testTodayPhotoPrefersConfidentAndKeepsTodaysChoice"):
            self.assertIn(f"func {name}()", TESTS)
        self.assertIn("python3 ci/test-confident-cats.py", QUICK)
        self.assertIn("try probableCatsGoLast()", read("ci/verify-personal-rediscovery.swift"))
        self.assertIn("try probableCatsOnlyWhenNothingElse()", read("ci/verify-cloudy-window.swift"))
        self.assertTrue(re.search(r"python3 ci/test-cat-threshold.py\npython3 ci/test-confident-cats.py", QUICK))


if __name__ == "__main__":
    unittest.main()
