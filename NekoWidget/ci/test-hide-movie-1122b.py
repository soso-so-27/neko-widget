#!/usr/bin/env python3
"""11/22: the seasonal movie is hidden in 1.0 (owner's decision), not removed.

One switch, `SeasonalMovieRelease.isAvailable`, is false in the production
configuration and true in DEBUG / INTERNAL_PRESENTATION builds. When off, no
card, row, badge or copy names the movie, and nothing is built, read, checked
or cleaned for it. Stored archive records are left as they are.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


SWITCH = "SeasonalMovieRelease.isAvailable"
PRESENTATION = source("NekoWidget/Views/SeasonalMoviePresentation.swift")
MAIN = source("NekoWidget/Views/MainTabView.swift")
APP = source("NekoWidget/App/NekoWidgetApp.swift")
LIKED = source("NekoWidget/Views/LikedPhotosView.swift")
ALBUM = source("NekoWidget/Views/AlbumPrototypeView.swift")
OFFER_MODEL = source("NekoWidget/Services/MembershipOfferModel.swift")
OFFER_VIEW = source("NekoWidget/Views/MembershipOfferView.swift")
POLICY = source("Shared/MembershipAccessPolicy.swift")
ARCHIVE = source("NekoWidget/Services/SeasonalMovieArchiveStore.swift")


class SwitchTests(unittest.TestCase):
    def test_one_switch_off_in_production_on_in_internal_builds(self):
        declaration = section(PRESENTATION, "enum SeasonalMovieRelease {", "\n}\n")
        self.assertIn(
            "    #if DEBUG || INTERNAL_PRESENTATION\n"
            "    static let isAvailable = true\n"
            "    #else\n"
            "    static let isAvailable = false\n"
            "    #endif",
            declaration)
        # The type itself is outside any conditional, so production code compiles.
        before = PRESENTATION[:PRESENTATION.index("enum SeasonalMovieRelease {")]
        self.assertEqual(before.count("#if"), before.count("#endif"))
        # Only one switch.
        for path in sorted((ROOT / "NekoWidget").rglob("*.swift")) + sorted((ROOT / "Shared").rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            if path.name != "SeasonalMoviePresentation.swift":
                self.assertNotIn("enum SeasonalMovieRelease", text, str(path))


class HiddenEntryPointTests(unittest.TestCase):
    def test_every_card_row_badge_and_destination_reads_the_guarded_list(self):
        records = section(MAIN, "private var currentSeasonalMovieRecords: [SeasonalMovieArchiveRecord] {",
                          "private func resolveSeasonalMovieArchiveVideos")
        self.assertIn("guard SeasonalMovieRelease.isAvailable else { return [] }", records)
        self.assertLess(records.index(SWITCH), records.index("seasonalMovieArchive.records"))
        # The album root (new movie card, これまでの作品), the album lists, the
        # tab's mark and the movie destination all come from that list.
        self.assertIn("movies: hasPhotoAccess ? currentSeasonalMovieRecords : [],", MAIN)
        self.assertIn("seasonalMovies: scope == .everyone ? currentSeasonalMovieRecords : [],", MAIN)
        self.assertIn("currentSeasonalMovieRecords.first.map { !$0.isFrozen } ?? false", MAIN)
        self.assertIn("latestMonthlyWindowIsUnread || latestSeasonalMovieIsNew", MAIN)
        destination = section(MAIN, "private func seasonalMovieDestination(", "private var hasAutomaticAlbumContent")
        self.assertIn("currentSeasonalMovieRecords.first(where: { $0.periodID == periodID })", destination)
        # No other view source reads the archive directly.
        self.assertEqual(MAIN.count("SeasonalMovieArchiveLibrary()"), 1)
        for path in ("NekoWidget/Views/AlbumPrototypeView.swift", "NekoWidget/Views/LikedPhotosView.swift",
                     "NekoWidget/Views/HomeView.swift", "NekoWidget/Views/SettingsView.swift",
                     "NekoWidget/App/AppRootView.swift"):
            self.assertNotIn("SeasonalMovieArchiveLibrary", source(path), path)
            self.assertNotIn("SeasonalMovieArchiveStore.shared", source(path), path)
        # The album root shows a movie only when it is handed one.
        self.assertIn("if let movie = movies.first, !movie.isFrozen {", ALBUM)
        self.assertIn("if !movies.isEmpty {\n                    Text(\"季節のムービー\")", ALBUM)

    def test_widgets_and_notifications_never_name_the_movie(self):
        for folder in ("NekoWidgetWidget", "NekoWidgetShareExtension"):
            for path in sorted((ROOT / folder).rglob("*.swift")):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("ムービー", text, str(path))
                self.assertNotIn("SeasonalMovie", text, str(path))
        notice = section(ALBUM, "enum AlbumArrivalNotice", "\n}\n")
        self.assertNotIn("ムービー", notice)


class NoBackgroundWorkTests(unittest.TestCase):
    def test_nothing_is_built_read_checked_or_cleaned(self):
        prepare = section(MAIN, "private func prepareSeasonalMovie() async {", "private func backfillEarlierSeasonalMovies")
        self.assertTrue(prepare.split("\n", 2)[2].lstrip().startswith(
            "guard SeasonalMovieRelease.isAvailable else { return }"), prepare[:300])
        backfill = section(MAIN, "private func backfillEarlierSeasonalMovies() async {", "private var currentMonthlyWindowCollection")
        self.assertTrue(backfill.split("\n", 1)[1].lstrip().startswith(
            "guard SeasonalMovieRelease.isAvailable else { return }"))
        resolve = section(MAIN, "private func resolveSeasonalMovieArchiveVideos() async {", "private func refreshedMonthlyWindow")
        self.assertTrue(resolve.split("\n", 1)[1].lstrip().startswith(
            "guard SeasonalMovieRelease.isAvailable else { return }"))
        # The archive file is not read at launch or on each return.
        self.assertIn("if SeasonalMovieRelease.isAvailable { await seasonalMovieArchive.load() }", MAIN)
        self.assertEqual(MAIN.count("seasonalMovieArchive.load()"), 1)
        # Drawing the tabs does not fetch the quarter's videos (catalog digest).
        key = section(MAIN, "private var seasonalMoviePreparationKey: SeasonalMoviePreparationKey {",
                      "private func prepareSeasonalMovie")
        self.assertIn("if SeasonalMovieRelease.isAvailable, hasPhotoAccess, sourceIsAvailable, !isScanning,", key)
        self.assertLess(key.index("if SeasonalMovieRelease.isAvailable"), key.index("seasonalMovieVideoCatalogDigest.digest("))
        self.assertIn("canPrepare: SeasonalMovieRelease.isAvailable\n                && hasPhotoAccess", key)
        # No temp-file work for it at launch.
        cleanup = section(APP, "if SeasonalMovieRelease.isAvailable {", "#if DEBUG")
        self.assertIn("SeasonalMovieExportService.shared.cleanupStaleExports(", cleanup)
        self.assertEqual(APP.count("SeasonalMovieExportService"), 1)

    def test_stored_records_are_left_untouched(self):
        # Hiding never deletes, migrates or rewrites the archive.
        for line in (MAIN + APP).splitlines():
            if SWITCH in line:
                self.assertNotRegex(line, r"removeItem|delete|clear|migrat", line)
        self.assertNotIn(SWITCH, ARCHIVE)
        self.assertIn('appendingPathComponent("SeasonalMovies"', ARCHIVE)


class CopyTests(unittest.TestCase):
    def test_plus_names_the_year_work_instead_of_the_movie(self):
        self.assertIn('(SeasonalMovieRelease.isAvailable ? "月の作品、季節のムービー" : "月の作品、1年の作品", "rectangle.stack"),',
                      OFFER_VIEW)
        self.assertEqual(OFFER_VIEW.count("ムービー"), 1)
        self.assertIn('case .monthlySummary: SeasonalMovieRelease.isAvailable ? "Plusで作品とムービーを見る" : "Plusで作品を見る"',
                      OFFER_MODEL)
        self.assertIn('case .monthlySummary: SeasonalMovieRelease.isAvailable\n'
                      '            ? "季節のムービーができています。Plusで見られます。" : "作品ができています。Plusで開けます。"',
                      OFFER_MODEL)
        for line in re.findall(r'^.*ムービー.*$', OFFER_MODEL, re.M):
            if line.lstrip().startswith("//") or line.lstrip().startswith("///"):
                continue
            self.assertTrue(SWITCH in line or "? \"季節のムービー" in line, line)

    def test_album_lines_name_the_movie_only_while_it_ships(self):
        self.assertIn('static let reflectionsTitle = SeasonalMovieRelease.isAvailable ? "月の作品・季節のムービー" : "月の作品"', LIKED)
        self.assertIn('showsReflectionArchive ? Self.reflectionsTitle :', LIKED)
        self.assertIn('NavigationLink("これまでの" + Self.reflectionsTitle, value: MemoriesRoute.reflectionsArchive)', LIKED)
        self.assertIn('if seasonalMovies.isEmpty && SeasonalMovieRelease.isAvailable {\n'
                      '                Label("季節のムービーは、いろいろな日の写真が2か月分たまるとできます。"', LIKED)
        self.assertIn('if SeasonalMovieRelease.isAvailable {\n'
                      '                    Text("いろいろな日の写真が2か月分たまると、季節のムービーができます。")', LIKED)
        self.assertIn('Text(SeasonalMovieRelease.isAvailable ? "月の作品と季節のムービーは、Plusで見られます。" : "月の作品は、Plusで見られます。")', LIKED)
        self.assertIn('ContentUnavailableView(SeasonalMovieRelease.isAvailable ? "月の作品・ムービーはありません" : "月の作品はありません"', LIKED)

    def test_membership_cost_is_unchanged(self):
        # No movie-only action exists; opening a work stays the same Plus action.
        self.assertIn("case openGrowingSummary", POLICY)
        self.assertNotIn("Movie", re.sub(r"///.*", "", POLICY))
        self.assertNotIn(SWITCH, POLICY)


class PublicPageTests(unittest.TestCase):
    def test_guide_and_policy_stop_naming_the_movie(self):
        guide = (REPO / "docs" / "guide" / "index.html").read_text(encoding="utf-8")
        policy = (REPO / "docs" / "privacy" / "index.html").read_text(encoding="utf-8")
        for text in (guide, policy):
            self.assertNotIn("ムービー", text)
        self.assertIn("<li>月の作品、1年の作品</li>", guide)
        self.assertIn("<li>「これまでの作品」からは、前の年の作品を見られます。</li>", guide)
        self.assertIn("<li>月の作品・1年の作品を開くのはPlusの機能です。</li>", guide)
        self.assertIn("あなたが共有や書き出しを選んだ作品の画像・PDFも", policy)
        self.assertIn("月と年の作品、ウィジェットの画像は、iPhoneの中で処理します。", policy)
        self.assertIn("PDFは、作るあいだiPhoneの中に一時ファイルを作ります。共有が終わると消します。", policy)
        self.assertIn("2026年11月21日", policy)


if __name__ == "__main__":
    unittest.main()
