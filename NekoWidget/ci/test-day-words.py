"""Source contracts for the cloudy window's date line and 節目 days (11/15).

Rules (ねこのまど_毎日の1枚の決まり_v2_1115.md, 日付の表示・節目):

- A date day, after clearing only: one line 「1年前のきょう」 (the same month
  and day) or 「1年前の今ごろ」 (within 3 days), in the same part as an
  official window's name, coming in by opacity after the tag has gone.
- A 節目 day comes before every other kind: a cat of the window has its
  birthday (year known, not the first year) or the day it came home (a year
  or more on), counted as on the cat's page (CatHomeCareCore.heroDay). A
  birthday comes before a day a cat came home; the monthly work before both.
- Tag while cloudy: 「きょうは むぎの誕生日」 / 「きょうは むぎと雨の誕生日」 /
  「きょうは 3匹の誕生日」, short 「きょうは 誕生日」; 「むぎが来て 4年」 /
  「うちに来て 4年」 / 「うちに来た日」. After clearing: 「むぎ 5歳」
  (「5歳の誕生日」) or 「うちに来て 4年」.
- VoiceOver: 「きょうは むぎの誕生日。くもりを晴らして、きょうの1枚を見る」 on the
  tag, and 「、むぎ 5歳」 / 「、1年前のきょう」 after the photo.

Native behaviour: ci/verify-cloudy-window.swift (milestoneDays, dayWords).
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
WIDGET = read("NekoWidgetWidget/NekoWidgetView.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
CORE = read("NekoWidget/Views/CatHomeCareCore.swift")
VERIFY = read("ci/verify-cloudy-window.swift")
QUICK = read("ci/run-quick-ios-checks.sh")
TEXT = section(CLOUDY, "enum CloudyWindowDayText {", "struct CloudyWindowPreparedPhoto")


class WordsTests(unittest.TestCase):
    def test_tag_words(self) -> None:
        for words in ('"きょうは \\(catNames[0])の誕生日"', '"きょうは \\(catNames[0])と\\(catNames[1])の誕生日"',
                      '"きょうは \\(catNames.count)匹の誕生日"', '"きょうは 誕生日"',
                      '"\\(catNames[0])が来て \\(milestone.cats[0].years)年"',
                      '"うちに来て \\(milestone.cats[0].years)年"', '"うちに来た日"'):
            self.assertIn(words, TEXT)
        self.assertIn("static let maximumNameLength = 20", TEXT)

    def test_line_words(self) -> None:
        self.assertIn('"\\(years)年前の" + (selection.dateSameDay == true ? "きょう" : "今ごろ")', TEXT)
        self.assertIn('"\\($0.0) \\($0.1.years)歳"', TEXT)
        self.assertIn('.joined(separator: "・")', TEXT)
        self.assertIn('"\\(shown[0].years)歳の誕生日"', TEXT)
        self.assertIn('"うちに来て \\(shown[0].years)年"', TEXT)
        line = section(TEXT, "static func revealedLine(", "static func spokenTagPrefix(")
        self.assertIn("guard selection.revealedAt != nil, selection.albumPeriod == nil else { return nil }", line)
        self.assertIn("let shown = milestone.cats.filter { $0.inPhoto }", line)

    def test_spoken_words(self) -> None:
        self.assertIn('tag(selection).map { $0[0] + "。" } ?? ""', TEXT)
        self.assertIn('selection.flatMap(revealedLine).map { "、" + $0[0] } ?? ""', TEXT)

    def test_no_other_words(self) -> None:
        strings = [part.split('"')[0] for part in TEXT.split('"')[1::2]]
        self.assertNotIn("…", TEXT)
        self.assertNotIn("おめでとう", TEXT)
        self.assertTrue(all("通知" not in text for text in strings))


class WidgetTests(unittest.TestCase):
    def test_tag_falls_back_to_the_short_form(self) -> None:
        capsule = section(WIDGET, "if let tags = CloudyWindowDayText.tag(selection) {", "} else {")
        self.assertIn("ViewThatFits(in: .horizontal) {", capsule)
        self.assertIn("revealCapsule(tags[0])", capsule)
        self.assertIn("if tags.count > 1 { revealCapsule(tags[1]) }", capsule)
        reveal = section(WIDGET, "private func revealCapsule(", "/// Used only inside")
        self.assertIn(".lineLimit(1)", reveal)
        self.assertNotIn("minimumScaleFactor", reveal)
        self.assertIn('.accessibilityLabel(CloudyWindowDayText.spokenTagPrefix(selection) + (selection.albumPeriod == nil',
                      WIDGET)

    def test_line_after_clearing_uses_the_official_name_part(self) -> None:
        line = section(WIDGET, "} else if let lines = CloudyWindowDayText.revealedLine(selection) {",
                       "} else if let photo = entry.officialPhoto {")
        self.assertIn("footerName {", line)
        self.assertIn("ViewThatFits(in: .horizontal) {", line)
        self.assertIn("AnyTransition.opacity.animation(CloudyRevealMotion.line)", line)
        self.assertIn("static let line = Animation.easeInOut(duration: 0.6).delay(0.3)", WIDGET)
        name = section(WIDGET, "private func footerName<Content: View>(", "private func revealCapsule(")
        for modifier in (".font(.caption2)", ".foregroundStyle(.white.opacity(0.92))",
                         ".background { footerBand(fadeHeight: 16) }", ".accessibilityHidden(true)"):
            self.assertIn(modifier, name)
        # The reveal's own motion is unchanged.
        self.assertIn("return .asymmetric(insertion: .opacity, removal: .scale(scale: 0.999))", WIDGET)
        self.assertIn("static let photo = Animation.easeInOut(duration: 1.9)", WIDGET)

    def test_photo_label_adds_the_line(self) -> None:
        label = section(WIDGET, "private var loadedPhotoAccessibilityLabel: String {", "/// One quiet footer")
        self.assertIn('"このiPhoneで見つけた猫の写真" + CloudyWindowDayText.spokenPhotoSuffix(entry.cloudyWindowSelection)',
                      label)


class ChooseTests(unittest.TestCase):
    def test_milestone_comes_first(self) -> None:
        choose = section(CLOUDY, "private func choose(state:", "private func similar(")
        self.assertLess(choose.index("for kind in [CloudyWindowMilestoneKind.birthday, .adoption] {"),
                        choose.index("if !hadKind(.new,"))
        cats = section(CLOUDY, "private func milestoneCats(", "private func milestonePhoto(")
        self.assertIn("$0.day == date && $0.kind == kind.rawValue && $0.years >= 1", cats)
        photo = section(CLOUDY, "private func milestonePhoto(", "private func choose(")
        self.assertLess(photo.index("everyone.isSubset(of:"), photo.index("for cat in cats.sorted("))
        self.assertIn("let unshown = photos.filter { !recent.contains($0.photoID) }", photo)

    def test_kind_and_marks_are_optional(self) -> None:
        self.assertIn("case milestone, new, date, ordinary", CLOUDY)
        self.assertIn("var milestone: CloudyWindowMilestone? = nil", CLOUDY)
        self.assertIn("var profileMilestones: [String: [CloudyWindowMilestoneDay]]? = nil", CLOUDY)
        self.assertIn("state.selections[index].milestone = nil", CLOUDY)

    def test_pools_keep_the_coming_week(self) -> None:
        prep = section(CLOUDY, "func preparation(now: Date", "func publish(")
        self.assertIn("for candidate in Array(newPhotos) + datePhotos + milestonePhotos", prep)
        self.assertIn(".union(cloudyWindowMilestonePhotoIDs(cloudyWindowMilestones()))", VIEW_MODEL)


class CountTests(unittest.TestCase):
    def test_same_count_as_the_cat_page(self) -> None:
        self.assertIn("switch heroDay(birthday: birthday, birthdayYearKnown: birthdayYearKnown, adoption: adoption, today: today) {", CORE)
        self.assertIn("return .birthday(years: birthdayYearKnown && years >= 1 ? years : nil)", CORE)
        host = section(VIEW_MODEL, "private func cloudyWindowMilestones(", "private func cloudyWindowMilestonePhotoIDs(")
        self.assertIn("CatHomeCareCore.heroDay(birthday: birthday, birthdayYearKnown: !birthdayApproximate,", host)
        self.assertIn("case let .birthday(years?)?:", host)
        self.assertNotIn("case .birthday(nil)", host)
        self.assertIn("profile.isLifeReferenceApproximate(for: .birthday)", host)
        self.assertIn("CatFarewell.departedIdentifiers()", host)
        self.assertNotIn("UNUserNotificationCenter", host)


class DepartedTests(unittest.TestCase):
    def test_departed_cats_never_make_a_date_day(self) -> None:
        self.assertIn("var departedProfileIDs: Set<String>? = nil", CLOUDY)
        only = section(CLOUDY, "private static func showsOnlyDeparted(", "private func quality(")
        self.assertIn("guard let cats = metadata?.profileIDs, !cats.isEmpty", only)
        self.assertIn("return cats.isSubset(of: departed)", only)
        choose = section(CLOUDY, "private func choose(state:", "private func similar(")
        self.assertIn("!(profile.map { state.departedProfileIDs?.contains($0) == true } ?? false)", choose)
        self.assertIn("&& !Self.showsOnlyDeparted(state.metadata[photo.photoID], in: state)", choose)
        prep = section(CLOUDY, "func preparation(now: Date", "func publish(")
        self.assertIn("!Self.showsOnlyDeparted(state.metadata[candidate.item.localIdentifier], in: state)", prep)
        self.assertIn("departed: cloudyWindowDepartedProfileIDs())", VIEW_MODEL)
        self.assertIn(".union(cloudyWindowDatePhotoIDs(cats))", VIEW_MODEL)
        self.assertIn("return !profiles.isSubset(of: departed)", VIEW_MODEL)
        self.assertIn("        try departedCatsAndDateDays()\n", VERIFY)


class RegistrationTests(unittest.TestCase):
    def test_checks_run(self) -> None:
        self.assertIn("        try milestoneDays()\n", VERIFY)
        self.assertIn("        try dayWords()\n", VERIFY)
        self.assertIn("python3 ci/test-day-words.py", QUICK)


if __name__ == "__main__":
    unittest.main()
