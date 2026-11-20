"""Source contracts for the daily photo rules v2 and the album notices (11/15).

The rules were counted in a one-year simulation (7 kinds of people), see
ねこのまど_毎日の1枚の決まり_v2_1115.md. In order, a day is:

1. a new day: no new day in the previous 2 days, a photo taken within 30
   days and never shown, the newest capture day first (ハート, お気に入り, a
   fitting cat within a day);
2. a date day: no date day in the previous 6 days, a photo from an earlier
   year on this month and day, else within 3 days; a year not yet shown on
   a date day first; never a photo shown in the last 30 days;
3. an ordinary day: only photos taken more than 30 days ago, with the old
   rules (bursts as one, not the previous day, not the last 30 days, cats in
   turn, たぶん猫 last, one day in three the same season of an earlier year).

With fewer than 30 such older photos the days are not split: one rotation,
and a new photo never two days running. The kind of day is recorded on the
selection (optional keys). Tomorrow's cloudy photo is chosen again after the
app read photos; today's never is, nor the monthly cover's day. The 32 and
the pool of 100 keep new photos (8 at most), the coming week's date photos
and older photos.

Album notices: set again after each read that adds photos, and on return to
the app when the notification permission changed.

Native behaviour: ci/verify-cloudy-window.swift.
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


CLOUDY = read("Shared/Storage/CloudyWindowStore.swift")
VERIFY = read("ci/verify-cloudy-window.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
ALBUM = read("NekoWidget/Views/AlbumPrototypeView.swift")
CHOOSE = section(CLOUDY, "private func choose(state:", "private func similar(")


class DayRuleNumberTests(unittest.TestCase):
    def test_numbers(self) -> None:
        for line in ("static let newPhotoDays = 30", "static let newDayGap = 3", "static let dateDayGap = 7",
                     "static let dateWindowDays = 3", "static let splitPhotoCount = 30",
                     "static let preparedNewPhotoCount = 8", "static let preparedDateDays = 7",
                     "static let maximumPhotoCount = 32"):
            self.assertIn(line, CLOUDY)

    def test_new_and_old_are_by_capture_date(self) -> None:
        new = section(CLOUDY, "static func isNewPhoto(", "static func isOldPhoto(")
        self.assertIn("guard !previouslyShown, let captured", new)
        self.assertIn("date.timeIntervalSince(captured) <= Double(newPhotoDays) * 86_400", new)
        old = section(CLOUDY, "static func isOldPhoto(", "static func dayNumber(_ date: Date)")
        self.assertIn("date.timeIntervalSince($0) > Double(newPhotoDays) * 86_400 } ?? true", old)
        check = section(CLOUDY, "private func isNew(_ photoID: String", "private func quality(")
        self.assertIn("!state.seenPhotoIDs.contains(photoID)", check)
        self.assertIn("$0.scopeID == scopeID && $0.day < date && $0.photoID == photoID", check)


class ChooseOrderTests(unittest.TestCase):
    def test_existing_rules_come_first(self) -> None:
        kinds = CHOOSE.index("let splits = older >= Self.splitPhotoCount")
        self.assertLess(CHOOSE.index("similar(photo, $0, metadata: state.metadata)"), kinds)
        self.assertLess(CHOOSE.index("if !surest.isEmpty { candidates = surest }"), kinds)
        self.assertLess(CHOOSE.index("candidates.removeAll { $0.photoID == last.photoID }"), kinds)

    def test_new_then_date_then_ordinary(self) -> None:
        new = CHOOSE.index("if !hadKind(.new, within: splits ? Self.newDayGap : 2, before: date, in: previous) {")
        date = CHOOSE.index("if splits, !hadKind(.date, within: Self.dateDayGap, before: date, in: previous),")
        ordinary = CHOOSE.index("// Ordinary day. With enough older photos, only those.")
        turns = CHOOSE.index("var selectedProfile = profile")
        self.assertLess(new, date)
        self.assertLess(date, ordinary)
        self.assertLess(ordinary, turns)
        self.assertIn("return made(newest, .new, profileID: profile)", CHOOSE[new:date])
        self.assertIn("return made(best.photo, .date, profileID: profile,", CHOOSE[date:ordinary])
        self.assertIn("dayKind: CloudyWindowDayKind.ordinary.rawValue, chosenAt: now)", CHOOSE)

    def test_gaps_are_counted_from_recorded_kinds(self) -> None:
        had = section(CLOUDY, "private func hadKind(", "private func choose(")
        self.assertIn("$0.kind == kind && date.timeIntervalSince($0.day) < (Double(gap) - 0.5) * 86_400", had)

    def test_new_day_orders_by_capture_day_then_quality(self) -> None:
        new = section(CHOOSE, "let newest = candidates.filter { isNew(", "if let newest {")
        self.assertLess(new.index("if dayA != dayB { return dayA > dayB }"),
                        new.index("if qualityA != qualityB { return qualityA < qualityB }"))
        quality = section(CLOUDY, "private func quality(", "private func hadKind(")
        # The app's heart (record.liked), then the Photos favorite, as the
        # pool's weights (liked 3x, favorite 2x).
        self.assertIn("(metadata?.isLiked == true ? 0 : 4) + (metadata?.isPhotosFavorite == true ? 0 : 2) + (fits ? 0 : 1)",
                      quality)
        selectors = read("NekoWidget/Services/PhotoSelectors.swift")
        self.assertLess(selectors.index("if asset.liked { value *= 3 }"), selectors.index("if asset.isFavorite { value *= 2 }"))
        self.assertIn("$0.compositionMode == .catFullBleed", quality)

    def test_date_day_prefers_same_day_and_unshown_years(self) -> None:
        date = section(CHOOSE, "if splits, !hadKind(.date,", "// Ordinary day.")
        self.assertIn("for photo in candidates where !recent.contains(photo.photoID)\n", date)
        self.assertIn("let rank = [match.offset > 0 ? 1 : 0, datedYears.contains(year) ? 1 : 0,", date)
        match = section(CLOUDY, "static func dateMatch(capturedDay: Int, targetDay: Int)", "static func dateMatch(takenAt")
        self.assertIn("if offset <= dateWindowDays", match)
        self.assertIn("target.month == 2 && target.day == 29 && !leap ? 28 : target.day", match)

    def test_ordinary_day_uses_older_photos_only_when_split(self) -> None:
        ordinary = section(CHOOSE, "// Ordinary day. With enough older photos, only those.", "var selectedProfile")
        self.assertIn("if splits {", ordinary)
        self.assertIn("if !old.isEmpty { candidates = old }", ordinary)
        self.assertIn("let unusedRecently = candidates.filter { !recent.contains($0.photoID) }", CHOOSE)
        self.assertIn("case 0: return !splits && !metadata.previouslyShown", CHOOSE)
        self.assertIn("guard !splits, let captured = metadata.creationDate else { return false }", CHOOSE)

    def test_recorded_kind_is_optional_text(self) -> None:
        selection = section(CLOUDY, "struct CloudyWindowSelection: Codable", "/// The host supplies")
        for line in ("var dayKind: String? = nil", "var dateYearsAgo: Int? = nil",
                     "var dateSameDay: Bool? = nil", "var chosenAt: Date? = nil"):
            self.assertIn(line, selection)
        metadata = section(CLOUDY, "struct CloudyWindowPhotoMetadata: Codable", "enum CloudyWindowDayKind")
        self.assertIn("var isLiked: Bool? = nil", metadata)
        self.assertIn("var isPhotosFavorite: Bool? = nil", metadata)
        state = section(CLOUDY, "private struct CloudyWindowState: Codable {", "/// All experiment metadata")
        self.assertIn("var version = 1", state)
        self.assertIn("var libraryChangedAt: Date? = nil", state)
        self.assertIn("var datedYears: Set<Int>? = nil", state)
        self.assertIn("isLiked: record.liked, isPhotosFavorite: record.isFavorite)", VIEW_MODEL)
        # Selections are kept 40 days: enough for the 2- and 6-day gaps.
        self.assertIn("now.timeIntervalSince(selection.day) > 40 * 86_400", CLOUDY)


class TomorrowTests(unittest.TestCase):
    def test_tomorrow_is_chosen_again_but_never_today(self) -> None:
        timeline = section(CLOUDY, "func timeline(scopeID: String", "func reveal(selectionID:")
        swap = section(timeline, "if maySelect, date > today, let planned = selection,", "if selection == nil && maySelect,")
        self.assertIn("planned.revealedAt == nil, planned.albumPeriod == nil", swap)
        self.assertIn("(planned.chosenAt ?? .distantPast) < changed", swap)
        self.assertLess(timeline.index("selection?.albumPeriod != arrival.period"), timeline.index(swap))
        sync = section(CLOUDY, "func synchronize(metadata:", "func synchronizeAlbumArrival(")
        self.assertIn("if state.metadata != kept || state.profiles != profiles || (state.profileMilestones ?? [:]) != coming\n", sync)
        self.assertIn("|| (state.departedProfileIDs ?? []) != gone {", sync)
        publish = section(CLOUDY, "func publish(_ photo:", "func timeline(")
        self.assertIn("state.libraryChangedAt = now", publish)


class PoolTests(unittest.TestCase):
    def test_the_32_hold_new_date_and_older_photos(self) -> None:
        prep = section(CLOUDY, "func preparation(now: Date", "func publish(")
        self.assertIn("pools = pools.map { pool in pool.filter { Self.isOldPhoto(takenAt: taken($0), at: now) } }", prep)
        self.assertIn("}.prefix(Self.preparedNewPhotoCount)", prep)
        self.assertIn("for _ in 0..<Self.preparedDateDays {", prep)
        self.assertLess(prep.index("for candidate in Array(newPhotos) + datePhotos"),
                        prep.index("let groups = state.profiles.keys.sorted()"))
        self.assertIn("var ordered = available.filter { $0.item.localIdentifier == arrivalID }", prep)

    def test_the_pool_of_100_gets_them_from_loaded_dates(self) -> None:
        rebuild = section(VIEW_MODEL, "private func performRebuildWidgetCache(", "private func clearOutputsAfterStartupFailure(")
        self.assertIn("CloudyWindowStore.newPhotoIDs(cats.filter { $0.lastShownAt == nil },", rebuild)
        self.assertIn(".union(cloudyWindowDatePhotoIDs(cats))", rebuild)
        self.assertIn("CloudyWindowStore.datePhotoIDs(cats, id: { $0.localIdentifier }, takenAt: { $0.creationDate })", VIEW_MODEL)
        self.assertEqual(rebuild.count("albumPriorityPhotoIDs().union(cloudyPriorityPhotos)"), 2)
        dates = section(CLOUDY, "static func datePhotoIDs<", "func configuration()")
        self.assertNotIn("calendar", dates.lower().replace("no calendar", ""))
        self.assertIn("Array(list.prefix(2))", dates)
        self.assertNotRegex(rebuild, re.compile(r"PHAsset\.fetchAssets"))


class NativeCheckTests(unittest.TestCase):
    def test_native_checks_run(self) -> None:
        for name in ("newPhotoGoesOutTomorrow", "dateDays", "fewPhotosKeepOneRotation",
                     "olderSavesRead", "dailyShooterSixtyDays"):
            self.assertIn(f"        try {name}()\n", VERIFY)
        for phrase in ("today's photo is never swapped",
                       "a new day at most once in 3 days",
                       "an ordinary day never shows a photo of the last 30 days",
                       "the 32 hold 8 new photos and older photos",
                       "a date day at most once a week",
                       "the same month and day comes before one within 3 days",
                       "few photos: the days are not split",
                       "few photos: a new photo comes, never two days running",
                       "an older selection reads without a kind",
                       "a daily photographer gets a new day about one day in three",
                       "a daily photographer's ordinary days stay older photos"):
            self.assertIn(phrase, VERIFY)


class AlbumNoticeTests(unittest.TestCase):
    def test_notice_is_set_after_each_read_that_adds_photos(self) -> None:
        version = section(VIEW_MODEL, "var presentationVersion: LibraryPresentationVersion {", "var catAssets:")
        self.assertIn("snapshotAssetCount: snapshot.assets.count", version)
        key = section(MAIN, "private var monthlyWindowCollectionKey: MonthlyWindowCollectionKey {", "private var latestMonthlyWindowPeriodIdentifier")
        self.assertIn("photoPresentationVersion: photoPresentationVersion", key)
        self.assertIn(".task(id: monthlyWindowCollectionKey) {", MAIN)
        prepare = section(MAIN, "private func prepareMonthlyWindowCollection() async {", "private func synchronizeAlbumArrival() {")
        self.assertIn("synchronizeAlbumArrival()", prepare[prepare.index("completedMonthlyWindowCollectionKey = key"):])
        sync = section(MAIN, "private func synchronizeAlbumArrival() {", "private func openAlbumArrivalIfReady()")
        self.assertIn("Task { await AlbumArrivalNotice.schedule(month: notices.month, year: notices.year) }", sync)

    def test_permission_turned_on_later_sets_the_notice_on_return(self) -> None:
        phase = section(MAIN, ".task(id: scenePhase) {", "private var photoLibrary: some View")
        self.assertIn("if await AlbumArrivalNotice.permissionChangedSinceSet() { synchronizeAlbumArrival() }", phase)
        schedule = section(ALBUM, "static func schedule(month:", "static func permissionChangedSinceSet()")
        self.assertIn("permissionWhenSet = permission", schedule)
        self.assertIn("guard month != nil || year != nil else { permissionWhenSet = nil; return }", schedule)
        self.assertIn("center.removePendingNotificationRequests(withIdentifiers: [monthID, yearID])", schedule)
        self.assertLess(schedule.index("removePendingNotificationRequests"), schedule.index("await add(monthID"))
        changed = section(ALBUM, "static func permissionChangedSinceSet()", "static func askIfNeeded()")
        self.assertIn("guard let permissionWhenSet else { return false }", changed)
        self.assertEqual(ALBUM.count("requestAuthorization(options: [.alert])"), 2)
        self.assertIn("private static let hour = 9", ALBUM)


if __name__ == "__main__":
    unittest.main()
