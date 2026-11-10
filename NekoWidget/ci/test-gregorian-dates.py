#!/usr/bin/env python3
"""西暦 dates (11/10): an iPhone set to 和暦 or 仏暦 still saves and counts 2026.

Stored days, ages and year works use Calendar.nekoGregorian
(Shared/Models/NekoCalendar.swift). Calendar.current is only for relative
checks (today, same day) and the notification triggers that match in it.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def lines_with(text: str, needle: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if needle in line]


class GregorianDatesTests(unittest.TestCase):
    def test_one_shared_calendar(self) -> None:
        helper = source("Shared/Models/NekoCalendar.swift")
        self.assertIn("static var nekoGregorian: Calendar", helper)
        self.assertIn("Calendar(identifier: .gregorian)", helper)
        self.assertIn('Locale(identifier: "ja_JP")', helper)
        self.assertIn("calendar: .nekoGregorian", helper)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertIn("A26111100000000000000002 /* NekoCalendar.swift in Sources */,", project)
        self.assertIn("A26111100000000000000004 /* ReviewPromptPolicy.swift in Sources */,", project)

    def test_stored_days_never_follow_the_device_calendar(self) -> None:
        core = source("NekoWidget/Services/CatCareCore.swift")
        self.assertNotIn("Calendar.current", core)
        self.assertNotRegex(core, r"Calendar\s*=\s*\.current")
        self.assertNotIn(".autoupdatingCurrent", core)
        self.assertIn("init?(date: Date, calendar: Calendar = .nekoGregorian)", core)
        self.assertIn("Calendar.nekoGregorian(in: calendar).dateComponents", core)
        settings = source("Shared/Models/AppSettings.swift")
        life = settings[settings.index("struct CatLifeDate"):settings.index("struct CatLifeReference")]
        # The iPhone's calendar only reads a year saved in it before 11/10.
        self.assertEqual(re.findall(r"Calendar\s*=\s*\.current\b.*", life), ["Calendar = .current) -> Date? {"])
        self.assertIn("isDeviceCalendarYear(year", life)
        self.assertIn("init?(date: Date, calendar: Calendar = .nekoGregorian)", life)
        self.assertIn("func date(in inputCalendar: Calendar = .nekoGregorian", life)

    def test_fixed_places_use_the_shared_calendar(self) -> None:
        care = source("NekoWidget/Views/CatCareView.swift")
        self.assertNotIn("Calendar.current", care)
        self.assertIn("recorded.date()", care)
        self.assertIn("day.date() ?? Date()", care)
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        # Only the notification trigger, which matches in the iPhone's own calendar.
        self.assertEqual(lines_with(album, "Calendar.current"), [
            "let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)",
        ])
        for needle in ("static func yearArrivalDate", "static func arrivedYears", "static func photos(inYear",
                       "private var arrivalDay: String"):
            body = album[album.index(needle):]
            body = body[:body.index("\n    }\n")]
            self.assertIn("Calendar.nekoGregorian", body, needle)
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertIn("Calendar.nekoGregorian.dateComponents([.year, .month], from: date)", home)
        notes = source("NekoWidget/Views/PhotoMemoryNoteLibraryView.swift")
        self.assertNotIn("Calendar.current.component(.year", notes)
        liked = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertNotIn("Calendar.current.dateComponents([.year", liked)
        offer = source("NekoWidget/Services/MembershipOfferModel.swift")
        self.assertNotIn("now: .now, calendar: .current", offer)

    def test_exports_print_gregorian_days(self) -> None:
        for path in ("NekoWidget/Services/CareHandoffExporter.swift", "NekoWidget/Services/EvacuationExporter.swift",
                     "NekoWidget/Services/EvacuationStore.swift", "NekoWidget/Views/VeterinaryVisitView.swift"):
            text = source(path)
            self.assertNotRegex(text, r"\.formatted\(date: \.numeric", path)
            self.assertIn(".nekoExportText(", text, path)

    def test_review_prompt_reaches_free_users_conservatively(self) -> None:
        policy = source("NekoWidget/Services/ReviewPromptPolicy.swift")
        self.assertIn("static let requiredDays = 3", policy)
        self.assertIn('"review.requestedAfterMonthlyBook.v1"', policy)
        self.assertIn('"review.requestedAfterMonthlyBook.v1"', source("NekoWidget/Views/AlbumPrototypeView.swift"))
        tab = source("NekoWidget/Views/MainTabView.swift")
        ask = tab[tab.index("private func askForReviewAfterPhotoIfDue"):]
        ask = ask[:ask.index("\n    }\n")]
        self.assertIn("ReviewPromptPolicy.mayAskAfterPhoto(", ask)
        self.assertIn("UsageCounter.anyWidgetPlaced() == true", ask)
        self.assertIn("requestReview()", ask)
        self.assertEqual(len(re.findall(r"requestReview\(\)", tab)), 1)
        self.assertIn("mayAskForReview: false", tab)  # never from the first-run photo
        app = source("NekoWidget/App/NekoWidgetApp.swift")
        self.assertIn("ReviewPromptPolicy.noteActive()", app)
        self.assertIn("ci/verify-usage-report.swift", source("ci/run-cheap-safety-checks.sh"))
        self.assertIn("NekoWidget/Services/ReviewPromptPolicy.swift", source("ci/run-cheap-safety-checks.sh"))


if __name__ == "__main__":
    unittest.main()
