#!/usr/bin/env python3
"""11/22 (owner's decisions ④ and ⑦, 点検「使い続けた先」).

④ The first Plus offer keeps its timing and conditions. With no work to open
yet (a kitten just met), the same four rows are shown with the works' row
last; the rows and their words do not change.

⑦ The month's 「◯月の作品がとどきました。」 still goes to everyone. Two month
notices in a row that led to no work rest the person's work notices; opening
a work, tapping its notice, or its cover leading to the Plus screen brings
them back. The album and the Widget's 「作品がとどきました」 stay as they are.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


MAIN = source("NekoWidget/Views/MainTabView.swift")
ALBUM = source("NekoWidget/Views/AlbumPrototypeView.swift")
OFFER_MODEL = source("NekoWidget/Services/MembershipOfferModel.swift")
OFFER_VIEW = source("NekoWidget/Views/MembershipOfferView.swift")
PRESENTATION = source("NekoWidget/Views/OnboardingPresentation.swift")
SERVICE = source("NekoWidget/Services/MomentBackgroundRefreshService.swift")


class FirstOfferRowOrderTests(unittest.TestCase):
    def test_same_rows_works_last_without_a_work(self):
        self.assertIn("static func values(worksFirst: Bool) -> [(String, String)] {", OFFER_VIEW)
        self.assertIn("worksFirst ? values : Array(values.dropFirst()) + values.prefix(1)", OFFER_VIEW)
        self.assertIn("ForEach(Self.values(worksFirst: worksFirst), id: \\.0)", OFFER_VIEW)
        self.assertNotIn("ForEach(Self.values, id:", OFFER_VIEW)
        # The works' row is still the first of the decided rows.
        values = section(OFFER_VIEW, "static let values = [", "    ]\n")
        self.assertLess(values.index("月の作品、1年の作品"), values.index("まどを作って"))

    def test_only_the_first_offer_passes_it(self):
        self.assertIn("worksFirst: Bool = true", OFFER_VIEW)
        self.assertIn("reasonOverride: String? = nil, worksFirst: Bool = true,", OFFER_MODEL)
        self.assertIn("worksFirst: worksFirst\n        )", OFFER_MODEL)
        self.assertEqual(MAIN.count("worksFirst:"), 1)
        self.assertIn("worksFirst: firstPlusOfferHasWork) { _ in showsFirstPlusOffer = false }", MAIN)

    def test_read_when_shown_timing_unchanged(self):
        offer = section(MAIN, "private func offerFirstPlusIfDue() async {", "\n    }\n")
        read = offer.index("firstPlusOfferHasWork = !albumMonthlyWindowLetters.isEmpty")
        self.assertLess(offer.index("FirstPlusOfferPolicy.isDue("), read)
        self.assertLess(read, offer.index("showsFirstPlusOffer = true"))
        policy = section(PRESENTATION, "enum FirstPlusOfferPolicy {", "extension Notification.Name {")
        is_due = section(policy, "static func isDue(", "\n    }\n")
        self.assertNotIn("Work", is_due)
        self.assertNotIn("letters", is_due)

    def test_first_work_line_unchanged(self):
        self.assertIn('year.map { "\\(String($0))年の作品ができています。Plusで開けます。" }', ALBUM)


class MonthNoticeRestTests(unittest.TestCase):
    def notice(self) -> str:
        return section(ALBUM, "enum AlbumArrivalNotice", "\n}\n")

    def test_rests_after_two_unopened(self):
        notice = self.notice()
        self.assertIn('static let pendingMonthKey = "albumArrival.month.pending.v1"', notice)
        self.assertIn('static let unopenedKey = "albumArrival.month.unopened.v1"', notice)
        self.assertIn("static let restAfterUnopened = 2", notice)
        self.assertIn("return unopened.count >= restAfterUnopened", notice)

    def test_schedule_sets_nothing_while_resting(self):
        schedule = section(self.notice(), "static func schedule(", "\n    }\n")
        rest = schedule.index("let resting = restsAfterShownNotices()")
        self.assertLess(schedule.index("removePendingNotificationRequests"), rest)
        self.assertIn("let month = resting ? nil : month", schedule)
        # The year's work notice is never rested (once a year).
        self.assertNotIn("let year = resting ? nil : year", schedule)
        self.assertLess(rest, schedule.index("guard month != nil || year != nil"))
        # The words of the notice are unchanged.
        self.assertIn('"\\(number)月の作品がとどきました。"', schedule)
        self.assertIn("notePending(month?.at)", schedule)

    def test_writes_only_when_changed(self):
        pending = section(self.notice(), "static func notePending(", "\n    }\n")
        self.assertIn("defaults.double(forKey: pendingMonthKey) != value else { return }", pending)
        opened = section(self.notice(), "static func noteOpened(", "\n    }\n")
        self.assertIn("if defaults.object(forKey: unopenedKey) != nil {", opened)

    def test_what_counts_as_opened(self):
        mark = section(ALBUM, "static func markOpened(_ period: String) {", "\n    }\n")
        self.assertLess(mark.index("AlbumArrivalNotice.noteOpened()"), mark.index("defaults.set(opened"))
        gate = section(ALBUM, "struct AlbumWorkGate<Content: View>: View {", "\n}\n")
        self.assertIn(".onAppear { AlbumArrivalNotice.noteOpened() }", gate)
        tap = section(SERVICE, "userInfo[AlbumArrivalNotice.userInfoKey] != nil {", "return")
        self.assertIn("AlbumArrivalNotice.noteOpened()", tap)

    def test_everyone_still_gets_it_album_and_widget_unchanged(self):
        sync = section(MAIN, "private func synchronizeAlbumArrival() {", "\n    }\n")
        self.assertNotIn("hasPersonalPlus", sync)
        self.assertNotIn("noteOpened", sync)
        self.assertNotIn("restsAfterShownNotices", sync)
        self.assertIn("Task { await AlbumArrivalNotice.schedule(month: notices.month, year: notices.year) }", sync)


if __name__ == "__main__":
    unittest.main()
