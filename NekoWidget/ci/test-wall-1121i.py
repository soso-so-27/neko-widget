#!/usr/bin/env python3
"""11/21: the update notice is not a wall, and every wait ends (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


APP = source("NekoWidget/App/NekoWidgetApp.swift")
UPGRADE = source("Shared/Sharing/ClientUpgradeRequirement.swift")
SHOWCASE_STORE = source("NekoWidget/Services/ShowcasePhotoStore.swift")
SHOWCASE_VIEW = source("NekoWidget/Views/ShowcasePhotoView.swift")
MAIN = source("NekoWidget/Views/MainTabView.swift")
ALBUM = source("NekoWidget/Views/AlbumPrototypeView.swift")
MOVIE_VIEW = source("NekoWidget/Views/SeasonalMovieView.swift")
MOVIE_EXPORT = source("NekoWidget/Services/SeasonalMovieExportService.swift")


class UpgradeNoticeTests(unittest.TestCase):
    def test_the_notice_closes_and_stays_closed_for_the_launch(self):
        presenter = section(APP, "private final class ClientUpgradePresenter {", "#if DEBUG")
        self.assertIn("private var isClosed = false", presenter)
        self.assertIn("guard ClientUpgradeRequirement.shared.isRequired, !isClosed else { return }", presenter)
        self.assertIn("ClientUpgradeRequiredView(onClose: { [weak self] in self?.close() })", presenter)
        close = section(presenter, "private func close() {", "private func presentIfRequired()")
        self.assertIn("isClosed = true", close)
        self.assertIn("window.isHidden = true", close)

    def test_the_view_offers_a_way_forward_without_a_store_page(self):
        view = section(UPGRADE, "struct ClientUpgradeRequiredView: View {", "#endif")
        self.assertIn("var onClose: (() -> Void)? = nil", view)
        self.assertIn('Button("閉じる", action: onClose)', view)
        # The store page is still not published; the flag has one owner.
        self.assertIn("static let isPagePublished = false", UPGRADE)
        # Server requests still stop; nothing local is gated.
        self.assertIn("if isRequired { throw ClientUpgradeRequiredError() }", UPGRADE)


class ShowcaseMissingOriginalTests(unittest.TestCase):
    def test_a_missing_original_shows_from_its_kept_copy(self):
        available = section(SHOWCASE_STORE, "var availableEntries: [Entry] {", "func availableEntries(in scopeID")
        self.assertIn("if asset.isHidden { hidden.insert(asset.localIdentifier) }", available)
        self.assertIn("!hidden.contains($0.photoIdentifier)", available)
        self.assertNotIn("accessible.contains", available)

    def test_unshowable_photos_can_be_taken_out(self):
        remove = section(SHOWCASE_STORE, "func removeUnavailable(in scopeID: String) throws {", "func setPinned(")
        self.assertIn("try commit(next, undoable: true)", remove)
        self.assertIn("scope.excluded.insert(entry.photoIdentifier)", remove)
        self.assertEqual(SHOWCASE_VIEW.count("{ removeUnavailable() }"), 2)
        self.assertIn("try store.removeUnavailable(in: scopeID)", SHOWCASE_VIEW)
        self.assertIn('Button("外して選び直す") { removeUnavailable() }', SHOWCASE_VIEW)
        self.assertIn('Button("写真を選ぶ") { showsPreparation = true }', SHOWCASE_VIEW)
        self.assertIn('"showcase-gallery-reselect"', SHOWCASE_VIEW)


class YearNoticeCalendarTests(unittest.TestCase):
    def test_year_and_trigger_are_gregorian(self):
        sync = section(MAIN, "private func synchronizeAlbumArrival() {", "private func openAlbumArrivalIfReady()")
        self.assertIn("let calendar = Calendar.nekoGregorian", sync)
        self.assertNotIn("Calendar.current", sync)
        trigger = section(ALBUM, "private static func calendarTrigger(", "private static func add(")
        self.assertIn("let calendar = Calendar.nekoGregorian", trigger)
        self.assertIn("parts.calendar = calendar", trigger)
        self.assertIn("parts.timeZone = calendar.timeZone", trigger)


class AlbumPermissionTests(unittest.TestCase):
    def test_a_launch_into_the_album_still_asks_when_a_work_is_found(self):
        self.assertIn(".task { await AlbumArrivalNotice.albumAppeared() }", ALBUM)
        self.assertIn(".onDisappear { AlbumArrivalNotice.albumDisappeared() }", ALBUM)
        schedule = section(ALBUM, "static func schedule(month:", "static func permissionChangedSinceSet()")
        self.assertIn("if albumIsShown { Task { await askIfNeeded() } }", schedule)
        appeared = section(ALBUM, "static func albumAppeared() async {", "static func albumDisappeared()")
        self.assertIn("removeDeliveredNotifications(withIdentifiers: [monthID, yearID])", appeared)
        self.assertIn("await askIfNeeded()", appeared)
        # Still only the existing two requests (album ask, test-only try).
        self.assertEqual(ALBUM.count("requestAuthorization(options: [.alert])"), 2)


class AlbumWaitsEndTests(unittest.TestCase):
    def test_monthly_book_build_ends_and_keeps_its_page(self):
        book = section(ALBUM, "struct MonthlyBookView: View {", "@ViewBuilder private var shareButton")
        self.assertIn(".task(id: BookBuildID(key: key, attempt: buildAttempt)) {", book)
        self.assertIn("failedKey = current", book)
        self.assertIn('Text("作品を開けませんでした")', book)
        self.assertIn('Button("もう一度試す")', book)
        self.assertIn("index = samePeriod ? min(index, max(0, next.count - 1)) : 0", book)
        self.assertIn("if showsLeaves {", book)

    def test_share_buttons_never_spin_forever(self):
        self.assertEqual(ALBUM.count(".task(id: BookShareTaskID(input: shareInput, attempt: shareAttempt)) {"), 2)
        self.assertEqual(ALBUM.count("shareFailed = request.input"), 2)
        self.assertEqual(ALBUM.count("} else if shareFailed == input {"), 2)


class SeasonalMovieExportTests(unittest.TestCase):
    def test_a_record_that_cannot_be_kept_does_not_refuse_the_export(self):
        self.assertIn("try? await freezeRecipe(.export)", MOVIE_VIEW)
        self.assertNotIn("try await freezeRecipe(.export)", MOVIE_VIEW)

    def test_a_lock_in_the_middle_does_not_stop_the_export(self):
        self.assertIn("attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]", MOVIE_EXPORT)
        self.assertIn(".completeFileProtectionUntilFirstUserAuthentication", MOVIE_EXPORT)
        self.assertNotIn("[.protectionKey: FileProtectionType.complete]", MOVIE_EXPORT)
        self.assertIn("UIApplication.shared.beginBackgroundTask(", MOVIE_VIEW)


if __name__ == "__main__":
    unittest.main()
