"""Source contracts for 撮ったら、あした出る and the album notices (11/15).

1. A cat photo taken in the last 7 days and never shown is the cloudy
   window's next photo: it replaces tomorrow's photo while tomorrow is still
   cloudy and not here yet, never today's. Several go out one a day, newest
   first, ahead of the cats' turns for that day only. Bursts, たぶん猫 and the
   previous day keep their rules. The host asks the bounded personal pool for
   the newest few, and the 32 prepared images take them first.
2. The monthly/yearly notice is set again after every read that adds photos
   (the album collection key carries the asset count), and also on the next
   return to the app when the notification permission changed.

Native behaviour: ci/verify-cloudy-window.swift (newPhotoGoesOutTomorrow).
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


CLOUDY = read("Shared/Storage/CloudyWindowStore.swift")
VERIFY = read("ci/verify-cloudy-window.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
ALBUM = read("NekoWidget/Views/AlbumPrototypeView.swift")


class NewPhotoTomorrowTests(unittest.TestCase):
    def test_new_means_taken_within_seven_days_and_never_shown(self) -> None:
        self.assertIn("static let newPhotoDays = 7", CLOUDY)
        new = section(CLOUDY, "static func isNewPhoto(", "static func newPhotoIDs<")
        self.assertIn("guard !previouslyShown, let captured", new)
        self.assertIn("date.timeIntervalSince(captured) <= Double(newPhotoDays) * 86_400", new)
        check = section(CLOUDY, "private func isNew(_ photoID: String", "private func choose(")
        self.assertIn("!state.seenPhotoIDs.contains(photoID)", check)
        self.assertIn("$0.scopeID == scopeID && $0.day < date && $0.photoID == photoID", check)

    def test_newest_new_photo_comes_first_after_the_existing_rules(self) -> None:
        choose = section(CLOUDY, "private func choose(state:", "private func similar(")
        new = choose.index("let newest = candidates.filter { isNew(")
        # Bursts, たぶん猫 and the previous day are sorted out before it.
        self.assertLess(choose.index("similar(photo, $0, metadata: state.metadata)"), new)
        self.assertLess(choose.index("if !surest.isEmpty { candidates = surest }"), new)
        self.assertLess(choose.index("candidates.removeAll { $0.photoID == last.photoID }"), new)
        # Ahead of the cats' turns, newest first.
        self.assertLess(new, choose.index("var selectedProfile = profile"))
        self.assertIn("return a == b ? lhs.photoID < rhs.photoID : a > b", choose[new:])
        self.assertIn("if onlyNew { return nil }", choose)

    def test_tomorrow_is_replaced_but_never_today(self) -> None:
        timeline = section(CLOUDY, "func timeline(scopeID: String", "func reveal(selectionID:")
        swap = section(timeline, "if maySelect, date > today, let planned = selection,", "if selection == nil && maySelect,")
        self.assertIn("planned.revealedAt == nil, planned.albumPeriod == nil", swap)
        self.assertIn("!isNew(planned.photoID, scopeID: scopeID, date: date, in: state)", swap)
        self.assertIn("choose(state: state, scopeID: scopeID, date: date, onlyNew: true)", swap)
        # The monthly work's cover keeps its day.
        self.assertLess(timeline.index("selection?.albumPeriod != arrival.period"), timeline.index(swap))
        self.assertEqual(CLOUDY.count("onlyNew: true"), 1)

    def test_new_photos_enter_the_prepared_32_and_the_pool(self) -> None:
        prep = section(CLOUDY, "func preparation(now: Date", "func publish(")
        new = prep.index("let newPhotos = available.filter")
        self.assertLess(prep.index("ordered += candidates.filter { pinned.contains("), new)
        self.assertLess(new, prep.index("let groups = state.profiles.keys.sorted()"))
        self.assertIn("}.prefix(Self.newPhotoDays)", prep)
        self.assertIn("static let maximumPhotoCount = 32", CLOUDY)
        rebuild = section(VIEW_MODEL, "private func performRebuildWidgetCache(", "private func clearAlbumAndWidgetOutputs(")
        self.assertIn("CloudyWindowStore.newPhotoIDs(", rebuild)
        self.assertIn("$0.isCatCandidate && !$0.isScreenshot && $0.lastShownAt == nil", rebuild)
        self.assertEqual(rebuild.count("albumPriorityPhotoIDs().union(newPhotos)"), 2)
        self.assertIn(".prefix(newPhotoDays)", section(CLOUDY, "static func newPhotoIDs<", "func configuration()"))

    def test_storage_format_is_unchanged(self) -> None:
        state = section(CLOUDY, "private struct CloudyWindowState: Codable {", "/// All experiment metadata")
        self.assertIn("var version = 1", state)
        self.assertNotIn("newPhoto", state)

    def test_native_check_runs(self) -> None:
        self.assertIn("try newPhotoGoesOutTomorrow()", VERIFY)
        body = section(VERIFY, "private static func newPhotoGoesOutTomorrow()", "private static func takenLongAgo(")
        for phrase in ("today's photo is never swapped",
                       "the newest new photo becomes tomorrow's, ahead of the cats' turns",
                       "the next new photo goes out the day after, one a day",
                       "a new photo goes out once",
                       "a new photo outside the 32 is prepared first",
                       "new means taken within 7 days and never shown"):
            self.assertIn(phrase, body)


class AlbumNoticeTests(unittest.TestCase):
    def test_notice_is_set_after_each_read_that_adds_photos(self) -> None:
        version = section(VIEW_MODEL, "var presentationVersion: LibraryPresentationVersion {", "var catAssets:")
        self.assertIn("snapshotAssetCount: snapshot.assets.count", version)
        key = section(MAIN, "private var monthlyWindowCollectionKey: MonthlyWindowCollectionKey {", "private var latestMonthlyWindowPeriodIdentifier")
        self.assertIn("photoPresentationVersion: photoPresentationVersion", key)
        self.assertIn(".task(id: monthlyWindowCollectionKey) {", MAIN)
        prepare = section(MAIN, "private func prepareMonthlyWindowCollection() async {", "private func synchronizeAlbumArrival() {")
        self.assertIn("completedMonthlyWindowCollectionKey = key", prepare)
        self.assertIn("synchronizeAlbumArrival()", prepare[prepare.index("completedMonthlyWindowCollectionKey = key"):])
        sync = section(MAIN, "private func synchronizeAlbumArrival() {", "private func openAlbumArrivalIfReady()")
        self.assertIn("Task { await AlbumArrivalNotice.schedule(month: notices.month, year: notices.year) }", sync)

    def test_permission_turned_on_later_sets_the_notice_on_return(self) -> None:
        phase = section(MAIN, ".task(id: scenePhase) {", "private var photoLibrary: some View")
        self.assertIn("if await AlbumArrivalNotice.permissionChangedSinceSet() { synchronizeAlbumArrival() }", phase)
        schedule = section(ALBUM, "static func schedule(month:", "static func permissionChangedSinceSet()")
        self.assertIn("permissionWhenSet = permission", schedule)
        self.assertIn("guard month != nil || year != nil else { permissionWhenSet = nil; return }", schedule)
        # Never twice: the same two identifiers are taken away and set again.
        self.assertIn("center.removePendingNotificationRequests(withIdentifiers: [monthID, yearID])", schedule)
        self.assertLess(schedule.index("removePendingNotificationRequests"), schedule.index("await add(monthID"))
        changed = section(ALBUM, "static func permissionChangedSinceSet()", "static func askIfNeeded()")
        self.assertIn("guard let permissionWhenSet else { return false }", changed)
        # Asking stays in the album tab only; words and time unchanged.
        self.assertEqual(ALBUM.count("requestAuthorization(options: [.alert])"), 2)
        self.assertIn("private static let hour = 9", ALBUM)


if __name__ == "__main__":
    unittest.main()
