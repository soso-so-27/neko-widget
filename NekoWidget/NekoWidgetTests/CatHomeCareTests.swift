import XCTest
@testable import NekoWidget

/// The 「この子」 page's 「これからのこと」 (11/14): the four values, their
/// words and when they read in the text colour, and the hero's line on the
/// birthday and the day the cat came home. Synthetic values only.
final class CatHomeCareTests: XCTestCase {
    private typealias Core = CatHomeCareCore

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CatCareDay {
        CatCareDay(year: year, month: month, day: day)!
    }

    private func calendar(_ zone: String = "Asia/Tokyo") -> Calendar {
        var calendar = Calendar.nekoGregorian
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, zone: String = "Asia/Tokyo") -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func vaccination(given: CatCareDay, next: CatCareDay?, deleted: Bool = false) -> CatCareVaccination {
        CatCareVaccination(kind: "3種混合", givenOn: given, nextDueOn: next,
                           editedAt: Date(timeIntervalSince1970: 0), editedBy: "test",
                           deletedAt: deleted ? Date(timeIntervalSince1970: 0) : nil)
    }

    private func weight(_ grams: Int, _ measured: CatCareDay, edited: TimeInterval = 0,
                        deleted: Bool = false) -> CatCareWeight {
        CatCareWeight(measuredOn: measured, grams: grams, editedAt: Date(timeIntervalSince1970: edited),
                      editedBy: "test", deletedAt: deleted ? Date(timeIntervalSince1970: edited) : nil)
    }

    // MARK: 誕生日

    func testBirthdayCountsDaysAndTurnsTextColourWithinSevenDays() {
        let birthday = day(2021, 7, 10)
        XCTAssertEqual(Core.birthday(birthday, today: day(2026, 11, 13)),
                       Core.Value(text: "7月10日（あと239日）", tone: .quiet))
        XCTAssertEqual(Core.birthday(birthday, today: day(2026, 7, 2)),
                       Core.Value(text: "7月10日（あと8日）", tone: .quiet))
        XCTAssertEqual(Core.birthday(birthday, today: day(2026, 7, 3)),
                       Core.Value(text: "7月10日（あと7日）", tone: .soon))
        XCTAssertEqual(Core.birthday(birthday, today: day(2026, 7, 10)), Core.Value(text: "きょう", tone: .soon))
        // The day after: a year (365 days) to go.
        XCTAssertEqual(Core.birthday(birthday, today: day(2026, 7, 11))?.text, "7月10日（あと364日）")
        // No birthday: no row (never 未設定 on the page).
        XCTAssertNil(Core.birthday(nil, today: day(2026, 7, 11)))
    }

    func testBirthdayAcrossTheYearEnd() {
        XCTAssertEqual(Core.birthday(day(2020, 1, 2), today: day(2026, 12, 31)),
                       Core.Value(text: "1月2日（あと2日）", tone: .soon))
    }

    func testFebruary29BirthdayIsMarch1InOtherYears() {
        let leap = day(2020, 2, 29)
        XCTAssertEqual(Core.birthday(leap, today: day(2027, 3, 1)), Core.Value(text: "きょう", tone: .soon))
        XCTAssertEqual(Core.birthday(leap, today: day(2027, 2, 28))?.text, "2月29日（あと1日）")
        XCTAssertEqual(Core.birthday(leap, today: day(2028, 2, 29)), Core.Value(text: "きょう", tone: .soon))
        XCTAssertEqual(Core.birthday(leap, today: day(2028, 3, 1))?.text, "2月29日（あと365日）")
    }

    // MARK: ワクチン

    func testVaccinationNextDueAndItsTextColourWindow() {
        let given = day(2025, 11, 8)
        let items = [vaccination(given: given, next: day(2026, 11, 20))]
        // Before the due month: gray.
        XCTAssertEqual(Core.vaccination(items, today: day(2026, 10, 31)), Core.Value(text: "次は 11月ごろ", tone: .quiet))
        // From the 1st of the due month.
        XCTAssertEqual(Core.vaccination(items, today: day(2026, 11, 1)), Core.Value(text: "次は 11月ごろ", tone: .soon))
        // Until 60 days after the due day (2027-01-19), then 前回.
        XCTAssertEqual(Core.vaccination(items, today: day(2027, 1, 19)),
                       Core.Value(text: "次は 2026年11月ごろ", tone: .soon))
        XCTAssertEqual(Core.vaccination(items, today: day(2027, 1, 20)), Core.Value(text: "前回 2025年11月8日", tone: .quiet))
    }

    func testVaccinationYearWhenNotThisYearAndEarliestDue() {
        let items = [vaccination(given: day(2026, 9, 14), next: day(2027, 9, 1)),
                     vaccination(given: day(2026, 1, 5), next: day(2027, 1, 5)),
                     vaccination(given: day(2026, 3, 1), next: day(2026, 12, 1), deleted: true)]
        XCTAssertEqual(Core.vaccination(items, today: day(2026, 11, 13)), Core.Value(text: "次は 2027年1月ごろ", tone: .quiet))
    }

    func testVaccinationLastGivenWithoutDueAndNothing() {
        let items = [vaccination(given: day(2026, 4, 2), next: nil), vaccination(given: day(2025, 3, 1), next: nil)]
        XCTAssertEqual(Core.vaccination(items, today: day(2026, 11, 13)), Core.Value(text: "前回 4月2日", tone: .quiet))
        // Never a worked-out next day: a vaccination a year ago stays 「前回」.
        let old = [vaccination(given: day(2025, 11, 13), next: nil)]
        XCTAssertEqual(Core.vaccination(old, today: day(2026, 11, 13))?.text, "前回 2025年11月13日")
        // Nothing recorded: no row (never 未記入 on the page).
        XCTAssertNil(Core.vaccination([], today: day(2026, 11, 13)))
        // Only a day given in the future is no 「前回」, so no row either.
        XCTAssertNil(Core.vaccination([vaccination(given: day(2026, 12, 1), next: nil)], today: day(2026, 11, 13)))
    }

    // MARK: 病院

    func testVetUnfinishedMemoWins() {
        let memos = [Core.VetMemo(completedAt: nil, hasContent: true, nextVisit: nil),
                     Core.VetMemo(completedAt: date(2026, 11, 1), hasContent: true, nextVisit: day(2026, 12, 10))]
        XCTAssertEqual(Core.vet(memos, today: day(2026, 11, 13), calendar: calendar()),
                       Core.Value(text: "書きかけ", tone: .unfinished))
        // An empty open memo says nothing: no row.
        let empty = [Core.VetMemo(completedAt: nil, hasContent: false, nextVisit: nil)]
        XCTAssertNil(Core.vet(empty, today: day(2026, 11, 13), calendar: calendar()))
    }

    func testVetNextVisitDayWithinSevenDaysAndOnTheDay() {
        let memos = [Core.VetMemo(completedAt: date(2026, 11, 11), hasContent: true, nextVisit: day(2026, 12, 10))]
        let today = day(2026, 11, 13)
        XCTAssertEqual(Core.vet(memos, today: today, calendar: calendar()), Core.Value(text: "次は 12月10日", tone: .quiet))
        XCTAssertEqual(Core.vet(memos, today: day(2026, 12, 2), calendar: calendar())?.tone, .quiet)
        XCTAssertEqual(Core.vet(memos, today: day(2026, 12, 3), calendar: calendar()),
                       Core.Value(text: "次は 12月10日", tone: .soon))
        XCTAssertEqual(Core.vet(memos, today: day(2026, 12, 10), calendar: calendar()), Core.Value(text: "きょう", tone: .soon))
        // The day after: the last finished memo.
        XCTAssertEqual(Core.vet(memos, today: day(2026, 12, 11), calendar: calendar()),
                       Core.Value(text: "前回 11月11日", tone: .quiet))
        let nextYear = [Core.VetMemo(completedAt: date(2026, 11, 11), hasContent: true, nextVisit: day(2027, 2, 1))]
        XCTAssertEqual(Core.vet(nextYear, today: today, calendar: calendar())?.text, "次は 2027年2月1日")
    }

    func testVetLastFinishedMemoAndNothing() {
        let memos = [Core.VetMemo(completedAt: date(2025, 6, 3), hasContent: true, nextVisit: nil),
                     Core.VetMemo(completedAt: date(2026, 9, 20), hasContent: true, nextVisit: nil)]
        XCTAssertEqual(Core.vet(memos, today: day(2026, 11, 13), calendar: calendar()), Core.Value(text: "前回 9月20日"))
        // No memo: no row (never なし on the page).
        XCTAssertNil(Core.vet([], today: day(2026, 11, 13), calendar: calendar()))
        // The finished day is the iPhone's day: 23:30 in Tokyo is still 9/20.
        let late = [Core.VetMemo(completedAt: date(2026, 9, 20, hour: 23), hasContent: true, nextVisit: nil)]
        XCTAssertEqual(Core.vet(late, today: day(2026, 11, 13), calendar: calendar())?.text, "前回 9月20日")
        XCTAssertEqual(Core.vet(late, today: day(2026, 11, 13), calendar: calendar("UTC"))?.text, "前回 9月20日")
        XCTAssertEqual(Core.vet(late, today: day(2026, 11, 13), calendar: calendar("Pacific/Auckland"))?.text, "前回 9月21日")
    }

    func testVetMemoFromAVisitUsesTheSameContentTest() {
        let cat = UUID()
        let open = VeterinaryVisit(id: UUID(), catID: cat, catName: "猫", revision: UUID(), startedOn: nil,
                                   observations: "", questions: "", entries: [], completedAt: nil,
                                   nextVisitOn: "2026-12-10")
        let memo = Core.VetMemo(open)
        XCTAssertTrue(memo.isUnfinished)
        XCTAssertEqual(memo.nextVisit, day(2026, 12, 10))
        let blank = VeterinaryVisit(id: UUID(), catID: cat, catName: "猫", revision: UUID(), startedOn: nil,
                                    observations: "", questions: "", entries: [], completedAt: nil)
        XCTAssertFalse(Core.VetMemo(blank).isUnfinished)
    }

    // MARK: 体重

    func testWeightNewestWithItsDay() {
        let items = [weight(5_400, day(2026, 9, 1)), weight(5_500, day(2026, 10, 21)),
                     weight(5_600, day(2026, 10, 25), deleted: true)]
        XCTAssertEqual(Core.weight(items, today: day(2026, 11, 13)), Core.Value(text: "5.50kg（10月21日）"))
        XCTAssertEqual(Core.weight(items, today: day(2027, 1, 2))?.text, "5.50kg（2026年10月21日）")
        // Two on one day: the one written last.
        let same = [weight(4_000, day(2026, 10, 21), edited: 10), weight(4_100, day(2026, 10, 21), edited: 20)]
        XCTAssertEqual(Core.weight(same, today: day(2026, 11, 13))?.text, "4.10kg（10月21日）")
        XCTAssertEqual(Core.weight([weight(850, day(2026, 11, 1))], today: day(2026, 11, 13))?.text, "850g（11月1日）")
        // No weight: no row (never 未記入 on the page).
        XCTAssertNil(Core.weight([], today: day(2026, 11, 13)))
    }

    // MARK: The hero's line

    func testHeroLineOnTheBirthday() {
        let birthday = day(2021, 7, 10)
        XCTAssertEqual(Core.heroDayLine(birthday: birthday, birthdayYearKnown: true, adoption: nil, today: day(2026, 7, 10)),
                       "きょうで5歳")
        XCTAssertEqual(Core.heroDayLine(birthday: birthday, birthdayYearKnown: false, adoption: nil, today: day(2026, 7, 10)),
                       "きょうは誕生日")
        XCTAssertNil(Core.heroDayLine(birthday: birthday, birthdayYearKnown: true, adoption: nil, today: day(2026, 7, 9)))
        XCTAssertNil(Core.heroDayLine(birthday: birthday, birthdayYearKnown: true, adoption: nil, today: day(2026, 7, 11)))
        XCTAssertNil(Core.heroDayLine(birthday: nil, birthdayYearKnown: true, adoption: nil, today: day(2026, 7, 10)))
    }

    func testHeroLineOnTheDayTheCatCameHome() {
        let adoption = day(2022, 11, 13)
        XCTAssertEqual(Core.heroDayLine(birthday: nil, birthdayYearKnown: true, adoption: adoption, today: day(2026, 11, 13)),
                       "うちに来て 4年")
        // Not on the day itself, and not before a year.
        XCTAssertNil(Core.heroDayLine(birthday: nil, birthdayYearKnown: true, adoption: adoption, today: day(2022, 11, 13)))
        XCTAssertNil(Core.heroDayLine(birthday: nil, birthdayYearKnown: true, adoption: adoption, today: day(2026, 11, 14)))
        // The birthday wins when both fall on one day.
        XCTAssertEqual(Core.heroDayLine(birthday: day(2020, 11, 13), birthdayYearKnown: true, adoption: adoption,
                                        today: day(2026, 11, 13)), "きょうで6歳")
    }

    func testHeroLineFebruary29() {
        let leap = day(2020, 2, 29)
        XCTAssertEqual(Core.heroDayLine(birthday: leap, birthdayYearKnown: true, adoption: nil, today: day(2027, 3, 1)),
                       "きょうで7歳")
        XCTAssertNil(Core.heroDayLine(birthday: leap, birthdayYearKnown: true, adoption: nil, today: day(2027, 2, 28)))
        XCTAssertEqual(Core.heroDayLine(birthday: leap, birthdayYearKnown: true, adoption: nil, today: day(2028, 2, 29)),
                       "きょうで8歳")
        XCTAssertNil(Core.heroDayLine(birthday: leap, birthdayYearKnown: true, adoption: nil, today: day(2028, 3, 1)))
        XCTAssertEqual(Core.heroDayLine(birthday: nil, birthdayYearKnown: true, adoption: leap, today: day(2021, 3, 1)),
                       "うちに来て 1年")
    }

    func testFactsUseTheDayLineOnlyOnTheDay() {
        let profileID = "11111111-1111-4111-8111-111111111111"
        let cat = CatHomeCat(id: profileID, name: "むぎ", kind: .toolCat(UUID(uuidString: profileID)!))
        var record = CatCareRecord(catID: UUID(uuidString: profileID)!)
        record.birthday = CatCareStamped<CatCareDay?>(value: day(2021, 7, 10), editedAt: Date(timeIntervalSince1970: 0), editedBy: "t")
        let onTheDay = CatHomeFacts.make(cat: cat, record: record, farewell: nil, now: date(2026, 7, 10), calendar: calendar())
        XCTAssertEqual(onTheDay.line, "きょうで5歳")
        XCTAssertEqual(onTheDay.birthday, day(2021, 7, 10))
        let other = CatHomeFacts.make(cat: cat, record: record, farewell: nil, now: date(2026, 7, 11), calendar: calendar())
        XCTAssertEqual(other.line, "5歳")
        // A departed cat keeps its farewell line, never the day's words.
        let departed = CatHomeFacts.make(cat: cat, record: record, farewell: day(2026, 1, 3), now: date(2026, 7, 10),
                                         calendar: calendar())
        XCTAssertTrue(departed.departed)
        XCTAssertEqual(departed.line?.hasPrefix("旅立った日"), true)
    }

    // MARK: Rows of a page

    func testRowsForEachKindOfCat() {
        let id = UUID()
        let now = date(2026, 11, 13)
        // 11/14: only rows with something written. A profile with nothing
        // written has no rows (its card is 「この子のこと」 alone).
        XCTAssertNil(CatHomeCareRows.make(hasProfile: true, record: nil, birthday: nil, vetMemos: [],
                                          now: now, calendar: calendar()))
        let birthdayOnly = CatHomeCareRows.make(hasProfile: true, record: nil, birthday: day(2021, 7, 10), vetMemos: [],
                                                now: now, calendar: calendar())
        XCTAssertEqual(birthdayOnly?.birthday?.text, "7月10日（あと239日）")
        XCTAssertNil(birthdayOnly?.vaccination)
        XCTAssertNil(birthdayOnly?.vet)
        XCTAssertNil(birthdayOnly?.weight)
        // A cat known only from the tools: just its vet memos, else no rows.
        XCTAssertNil(CatHomeCareRows.make(hasProfile: false, record: nil, birthday: nil, vetMemos: [],
                                          now: now, calendar: calendar()))
        let toolOnly = CatHomeCareRows.make(hasProfile: false, record: nil, birthday: nil,
                                            vetMemos: [.init(completedAt: nil, hasContent: true, nextVisit: nil)],
                                            now: now, calendar: calendar())
        XCTAssertEqual(toolOnly, CatHomeCareRows(vet: Core.Value(text: "書きかけ", tone: .unfinished)))
        // A family cat with its shared record: the rows its record has.
        XCTAssertNil(CatHomeCareRows.make(hasProfile: false, record: CatCareRecord(catID: id), birthday: nil,
                                          vetMemos: [], now: now, calendar: calendar()))
        var record = CatCareRecord(catID: id)
        record.weights = [weight(5_500, day(2026, 10, 21))]
        let family = CatHomeCareRows.make(hasProfile: false, record: record, birthday: nil, vetMemos: [],
                                          now: now, calendar: calendar())
        XCTAssertEqual(family, CatHomeCareRows(weight: Core.Value(text: "5.50kg（10月21日）")))
    }

    func testDayArithmeticIgnoresClockChanges() {
        // US daylight saving ends 2026-11-01; days stay whole.
        XCTAssertEqual(Core.days(from: day(2026, 10, 31), to: day(2026, 11, 2)), 2)
        XCTAssertEqual(Core.adding(-60, to: day(2026, 1, 19)), day(2025, 11, 20))
        XCTAssertEqual(Core.completedYears(from: day(2020, 2, 29), to: day(2021, 2, 28)), 0)
        XCTAssertEqual(Core.completedYears(from: day(2020, 2, 29), to: day(2021, 3, 1)), 1)
    }
    // MARK: The name and the dots on the photo

    /// Width of a name of `characters` full-width glyphs at `size` (each
    /// glyph as wide as the size, as heavy kana and kanji nearly are).
    private func fullWidth(_ characters: Int) -> (Double) -> Double {
        { size in Double(characters) * size }
    }

    func testNameLadderKeepsShortNamesAtFiftySix() {
        typealias Layout = CatHomeHeroLayout
        // iPhone SE / standard width 375: 62% is 232.
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(1)), .init(size: 56, lines: 1))
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(2)), .init(size: 56, lines: 1))
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(3)), .init(size: 56, lines: 1))
        // Four at 56 is 224 (fits), five steps down to 40 (5 × 48 = 240 does not fit).
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(4)), .init(size: 56, lines: 1))
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(5)), .init(size: 40, lines: 1))
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(6)), .init(size: 34, lines: 1))
        // Longer: two lines at the smallest size.
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(9)), .init(size: 34, lines: 2))
        XCTAssertEqual(Layout.nameFit(scale: 1, maxWidth: 232, width: fullWidth(80)), .init(size: 34, lines: 2))
    }

    func testNameLadderScalesWithTextSizeUpToTheCap() {
        typealias Layout = CatHomeHeroLayout
        // Larger text: every step grows; the cap keeps 56 at 84 at most.
        XCTAssertEqual(Layout.nameFit(scale: 1.2, maxWidth: 400, width: fullWidth(2)), .init(size: 67, lines: 1))
        XCTAssertEqual(Layout.nameFit(scale: 3, maxWidth: 400, width: fullWidth(2)), .init(size: 84, lines: 1))
        // The same width rule at the accessibility sizes: 3 × 84 = 252 > 232.
        XCTAssertEqual(Layout.nameFit(scale: 3, maxWidth: 232, width: fullWidth(3)), .init(size: 72, lines: 1))
        XCTAssertEqual(Layout.nameFit(scale: 3, maxWidth: 232, width: fullWidth(6)), .init(size: 51, lines: 2))
    }

    func testPageDotsCapAtSevenWithShrinkingEnds() {
        typealias Layout = CatHomeHeroLayout
        XCTAssertEqual(Layout.dots(count: 1, current: 0), [])
        XCTAssertEqual(Layout.dots(count: 3, current: 1).map(\.scale), [1, 1, 1])
        XCTAssertEqual(Layout.dots(count: 7, current: 6).count, 7)
        // Eight cats, the first page: dots 0…6, the far end shrinks.
        let first = Layout.dots(count: 8, current: 0)
        XCTAssertEqual(first.map(\.index), Array(0...6))
        XCTAssertEqual(first.map(\.scale), [1, 1, 1, 1, 1, 0.75, 0.5])
        // The last page: dots 1…7, the near end shrinks.
        let last = Layout.dots(count: 8, current: 7)
        XCTAssertEqual(last.map(\.index), Array(1...7))
        XCTAssertEqual(last.map(\.scale), [0.5, 0.75, 1, 1, 1, 1, 1])
        // In the middle of twelve: both ends shrink, the current page is in the middle.
        let middle = Layout.dots(count: 12, current: 6)
        XCTAssertEqual(middle.map(\.index), Array(3...9))
        XCTAssertEqual(middle.map(\.scale), [0.5, 0.75, 1, 1, 1, 0.75, 0.5])
        XCTAssertTrue(middle.contains(.init(index: 6, scale: 1)))
    }
}
