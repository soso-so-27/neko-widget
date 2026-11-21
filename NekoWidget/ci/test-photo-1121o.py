#!/usr/bin/env python3
"""11/21: photo reading, the album and works, and onboarding (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


APP = source("NekoWidget/App/NekoWidgetApp.swift")
MAIN = source("NekoWidget/Views/MainTabView.swift")
ALBUM = source("NekoWidget/Views/AlbumPrototypeView.swift")
ONBOARDING = source("NekoWidget/Views/OnboardingView.swift")
LIKED = source("NekoWidget/Views/LikedPhotosView.swift")
PDF = source("NekoWidget/Services/PhotoBookPDFExporter.swift")
LOADER = source("NekoWidget/Services/PhotoImageLoader.swift")
SCANNER = source("NekoWidget/Services/PhotoLibraryScanner.swift")


class DuplicateIdentifierTests(unittest.TestCase):
    def test_saved_photo_views_never_trap_on_a_repeated_id(self):
        self.assertNotIn("uniqueKeysWithValues: browserPhotos", LIKED)
        self.assertNotIn("uniqueKeysWithValues: parent.photos", LIKED)
        self.assertNotIn("uniqueKeysWithValues: pendingAssignmentIdentifiers", LIKED)
        self.assertGreaterEqual(LIKED.count("uniquingKeysWith: { first, _ in first }"), 5)
        self.assertNotIn("Dictionary(uniqueKeysWithValues: catProfilesPresentation.profiles", MAIN)


class OwnWorksTests(unittest.TestCase):
    def test_works_use_own_photos_without_excluded_ones(self):
        works = section(MAIN, "private var albumWorkPhotos: [PhotoPresentation] {", "private var householdAlbumCatalogKey")
        self.assertIn("let photos = albumEligibleCatPhotos", works)
        self.assertIn("!excluded.contains($0.localIdentifier)", works)
        root = section(MAIN, "private var albumRoot: some View {", "private var albumMonthlyWindowLetters")
        self.assertIn("catPhotos: hasPhotoAccess ? albumWorkPhotos : [],", root)
        self.assertNotIn("catPhotos: hasPhotoAccess ? catPhotos", root)
        self.assertIn("MonthlyStoryView(letter: current, catPhotos: albumWorkPhotos,", MAIN)
        arrival = section(MAIN, "private func synchronizeAlbumArrival() {", "private func openAlbumArrivalIfReady() {")
        self.assertIn("let eligiblePhotos = albumWorkPhotos", arrival)
        self.assertIn("AlbumPrototype.cover(of: letter, from: eligiblePhotos)", arrival)
        self.assertNotIn("from: catPhotos", arrival)


class TemporaryExportTests(unittest.TestCase):
    def test_stale_export_folders_are_swept_off_the_main_thread(self):
        sweep = section(PDF, "enum StaleExportFolderSweep {", "/// A finished PDF")
        self.assertIn('["PhotoBookExports", "PhotoMemoryNoteExports", "ReadablePreservationExports"]', sweep)
        self.assertIn("static let minimumAge: TimeInterval = 60 * 60", sweep)
        self.assertIn("UUID(uuidString: item.lastPathComponent) != nil", sweep)
        self.assertIn("values.isSymbolicLink != true", sweep)
        self.assertIn("now.timeIntervalSince(modified) >= minimumAge", sweep)
        cleanup = section(APP, "if shouldRunLaunchCleanup {", "#if DEBUG")
        self.assertIn("Task.detached(priority: .background) {\n                StaleExportFolderSweep.removeStaleFolders()", cleanup)


class PhotoReadingTests(unittest.TestCase):
    def test_pdf_says_unreadable_photos_and_offers_retry(self):
        self.assertIn("case photosNotReadable", PDF)
        self.assertIn('"写真を読み込めませんでした。iCloudとの接続を確かめて、もう一度お試しください。"', PDF)
        self.assertIn("if unreadablePhotoCount > 0 { throw PhotoBookPDFExportError.photosNotReadable }", PDF)
        self.assertIn("photoBookErrorCanRetry = (error as? PhotoBookPDFExportError) == .photosNotReadable", LIKED)
        self.assertIn('Button("もう一度") {\n                    photoBookErrorMessage = nil\n                    createPhotoBookPDF()', LIKED)

    def test_network_reads_end_after_a_timeout(self):
        self.assertIn("static let networkTimeoutSeconds: TimeInterval = 120", LOADER)
        self.assertIn("semaphore.wait(timeout: .now() + Self.networkTimeoutSeconds) == .success", LOADER)
        self.assertIn("request.abandon()", LOADER)
        self.assertIn("if request.isAbandoned { stop.pointee = true }", LOADER)
        # The Widget's network-disabled read stays inline.
        self.assertIn("guard networkAccessAllowed else {", LOADER)

    def test_icloud_only_photos_are_read_again_once_a_day_within_the_budget(self):
        self.assertIn(
            "} else if reused.analysisStatus == .unavailableLocally,\n"
            "                              lowFidelityRetryBudget > 0,\n"
            "                              ScanRetryPolicy.retriesFailedPhoto(",
            SCANNER,
        )


class FirstRunAndAlbumTests(unittest.TestCase):
    def test_found_title_needs_a_cat(self):
        title = section(ONBOARDING, "    private var title: String {", "    private var isFinalZero: Bool {")
        self.assertNotIn("|| scan.hasFinalResult", title)
        self.assertIn("return scan.displayedCatCount > 0", title)

    def test_only_a_stopped_search_is_a_loading_failure(self):
        failure = section(ONBOARDING, "private var scanFailureMessage: String? {", "private var otherMessage: String? {")
        self.assertIn("scan.hasFailed || scan.startupLoadFailed", failure)
        self.assertIn("(!scan.isScanning && !scan.hasPreliminaryResult)", failure)
        self.assertIn("if let scanErrorMessage = scanFailureMessage, !scan.hasPreliminaryResult {", ONBOARDING)
        self.assertIn("scanErrorMessage: scanFailureMessage,", ONBOARDING)

    def test_album_says_it_is_preparing(self):
        self.assertIn("var lettersAreLoading = false", ALBUM)
        self.assertIn('Text("作品を準備しています")', ALBUM)
        self.assertIn("lettersAreLoading: albumMonthlyWindowLettersAreLoading", MAIN)
        loading = section(MAIN, "private var albumMonthlyWindowLettersAreLoading: Bool {", "private var cachedMonthlyWindowSnapshot")
        self.assertIn("photoLibraryLoadSucceeded == nil || isScanning || monthlyWindowCollectionKey.canBuild", loading)

    def test_launch_tab_choice_never_moves_a_person_who_started(self):
        self.assertIn("guard path.isEmpty else { didApplyInitialTab = true; return }", MAIN)
        self.assertIn("if count > 0 { didApplyInitialTab = true }", MAIN)
        self.assertIn("Button { photoLibraryProfileIdentifier = identifier; didApplyInitialTab = true } label: {", MAIN)


class SeasonalMovieBackfillTests(unittest.TestCase):
    def test_earlier_quarters_are_built_one_at_a_time(self):
        backfill = section(MAIN, "private func backfillEarlierSeasonalMovies() async {", "private var currentMonthlyWindowCollection")
        self.assertIn("Task.detached(priority: .utility) {\n            SeasonalMovieBackfill.photoCounts", backfill)
        self.assertIn("!recorded.contains(periodID)", backfill)
        self.assertIn("count >= SeasonalMovieBuilder.minimumDistinctSceneCount", backfill)
        self.assertIn("through: quarter.end,", backfill)
        self.assertIn("await seasonalMovieArchive.recordDraft(presentation)", backfill)
        self.assertNotIn("videoCandidateBatch", backfill)
        prepare = section(MAIN, "private func prepareSeasonalMovie() async {", "private func backfillEarlierSeasonalMovies")
        self.assertEqual(prepare.count("await backfillEarlierSeasonalMovies()"), 2)


if __name__ == "__main__":
    unittest.main()
