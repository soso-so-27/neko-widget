import XCTest
@testable import NekoWidget

/// The 「この子」 page's records (11/13): merge and order, the weight change,
/// the 「1年前のきょう」 pick and the date words. Synthetic values only.
final class CatHomeRecordsTests: XCTestCase {
    private let cat = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func calendar(_ zone: String = "Asia/Tokyo") -> Calendar {
        var calendar = Calendar.nekoGregorian
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, zone: String = "Asia/Tokyo") -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CatCareDay {
        CatCareDay(year: year, month: month, day: day)!
    }

    private func memo(_ text: String, on captured: Date?, cats: [UUID], written: Date? = nil,
                      photo: String = "photo") -> PhotoMemoryNoteRecord {
        let note = PhotoMemoryNote(text: text, updatedAt: written ?? captured ?? Date(timeIntervalSince1970: 0),
                                   revision: UUID().uuidString, writtenAt: written,
                                   context: PhotoMemoryNoteContext(capturedAt: captured,
                                       cats: cats.map { PhotoMemoryNoteCat(id: $0, name: "猫") }))
        return PhotoMemoryNoteRecord(photoIdentifier: photo, note: note)
    }

    private func weight(_ grams: Int, _ measured: CatCareDay, edited: Date = Date(timeIntervalSince1970: 0),
                        deleted: Bool = false) -> CatCareWeight {
        CatCareWeight(measuredOn: measured, grams: grams, editedAt: edited, editedBy: "test",
                      deletedAt: deleted ? edited : nil)
    }

    private func visit(catID: UUID, finished: Date?, doctor: String? = nil, observations: String = "",
                       next: String? = nil) -> VeterinaryVisit {
        VeterinaryVisit(id: UUID(), catID: catID, catName: "猫", revision: UUID(), startedOn: nil,
                        observations: observations, questions: "", entries: [], completedAt: finished,
                        doctorNote: doctor, nextVisitOn: next)
    }

    // MARK: Merge and order

    func testMergesFourKindsNewestFirstAndOnlyThisCat() {
        let now = date(2026, 11, 13)
        let rows = CatHomeRecordsCore.snapshot(
            catIDs: [cat],
            memos: [memo("あごの下をかくと、目を細める。", on: date(2026, 11, 9), cats: [cat]),
                    memo("別の猫", on: date(2026, 11, 10), cats: [other]),
                    memo("   ", on: date(2026, 11, 11), cats: [cat])],
            visits: [visit(catID: cat, finished: date(2026, 9, 14), doctor: "体重は順調です。\n次は春。", next: "2026-12-03"),
                     visit(catID: cat, finished: nil, observations: "書きかけ"),
                     visit(catID: other, finished: date(2026, 10, 1), doctor: "別の猫")],
            weights: [weight(5_500, day(2026, 10, 21)), weight(5_400, day(2026, 8, 1)),
                      weight(9_000, day(2026, 10, 30), deleted: true)],
            vaccinations: [CatCareVaccination(kind: "3種混合", givenOn: day(2025, 9, 14), nextDueOn: day(2026, 9, 1),
                                              editedAt: now, editedBy: "test")],
            photos: [], now: now, calendar: calendar()).rows
        XCTAssertEqual(rows.map(\.title), ["あごの下をかくと、目を細める。", "体重 5.50kg", "病院　体重は順調です。",
                                           "体重 5.40kg", "ワクチン　3種混合"])
        XCTAssertEqual(rows.map(\.dateText), ["11月9日", "10月21日", "9月14日", "8月1日", "2025年9月14日"])
        XCTAssertEqual(rows.map(\.caption), ["メモ", "前回より +0.10kg", "次は12月3日", nil, "次は2026年9月ごろ"])
        XCTAssertEqual(rows[0].spoken, "11月9日、メモ、あごの下をかくと、目を細める。")
        XCTAssertEqual(rows[1].spoken, "10月21日、体重、5.50kg、前回より +0.10kg")
        XCTAssertEqual(rows[2].spoken, "9月14日、病院、体重は順調です。、次は12月3日")
        if case .vet = rows[2].kind {} else { XCTFail("a finished vet memo") }
    }

    func testSameDayKeepsNewestWrittenFirstAndIsStable() {
        let today = day(2026, 11, 13)
        let first = CatHomeRecordRow(id: "b", kind: .weight, day: day(2026, 11, 1), at: Date(timeIntervalSince1970: 10),
                                     dateText: "", title: "", caption: nil, spoken: "")
        let later = CatHomeRecordRow(id: "a", kind: .weight, day: day(2026, 11, 1), at: Date(timeIntervalSince1970: 20),
                                     dateText: "", title: "", caption: nil, spoken: "")
        let tie = CatHomeRecordRow(id: "c", kind: .vaccination, day: day(2026, 11, 1), at: Date(timeIntervalSince1970: 10),
                                   dateText: "", title: "", caption: nil, spoken: "")
        let older = CatHomeRecordRow(id: "z", kind: .weight, day: day(2026, 10, 31), at: Date(timeIntervalSince1970: 99),
                                     dateText: "", title: "", caption: nil, spoken: "")
        XCTAssertEqual(CatHomeRecordsCore.sorted([older, tie, first, later]).map(\.id), ["a", "b", "c", "z"])
        XCTAssertEqual(CatHomeRecordsCore.dayText(day(2026, 1, 2), today: today), "1月2日")
    }

    func testVetMemoFallsBackToObservationsThenToTheWordAlone() {
        let today = day(2026, 11, 13)
        let observed = CatHomeRecordsCore.vetRow(visit(catID: cat, finished: date(2026, 11, 1), doctor: "  \n",
                                                       observations: "\n食欲が少しない\nそれから"),
                                                 today: today, calendar: calendar())
        XCTAssertEqual(observed?.title, "病院　食欲が少しない")
        XCTAssertNil(observed?.caption)
        let bare = CatHomeRecordsCore.vetRow(visit(catID: cat, finished: date(2026, 11, 1)), today: today, calendar: calendar())
        XCTAssertEqual(bare?.title, "病院")
        XCTAssertEqual(bare?.spoken, "11月1日、病院")
        XCTAssertNil(CatHomeRecordsCore.vetRow(visit(catID: cat, finished: nil, doctor: "まだ"), today: today, calendar: calendar()))
    }

    func testTheCareCatIDAlsoMatches() {
        let careID = UUID()
        let snapshot = CatHomeRecordsCore.snapshot(
            catIDs: [cat, careID], memos: [memo("家族の手帳の猫", on: date(2026, 11, 2), cats: [careID])],
            visits: [visit(catID: careID, finished: date(2026, 11, 3))], weights: [], vaccinations: [],
            photos: [], now: date(2026, 11, 13), calendar: calendar())
        XCTAssertEqual(snapshot.rows.count, 2)
    }

    // MARK: Weight change

    func testWeightChangeWords() {
        XCTAssertNil(CatHomeRecordsCore.weightChange(5_500, previous: nil))
        XCTAssertEqual(CatHomeRecordsCore.weightChange(5_500, previous: 5_400), "前回より +0.10kg")
        XCTAssertEqual(CatHomeRecordsCore.weightChange(5_450, previous: 5_500), "前回より \u{2212}0.05kg")
        XCTAssertEqual(CatHomeRecordsCore.weightChange(5_500, previous: 5_500), "前回と同じ")
        XCTAssertEqual(CatHomeRecordsCore.weightChange(980, previous: 1_000), "前回より \u{2212}0.02kg")
    }

    func testWeightRowsCompareWithTheOneMeasuredBefore() {
        let rows = CatHomeRecordsCore.weightRows([weight(4_000, day(2026, 1, 1)), weight(4_300, day(2026, 3, 1)),
                                                  weight(4_100, day(2026, 2, 1))], today: day(2026, 11, 13))
        XCTAssertEqual(rows.map(\.title), ["体重 4.30kg", "体重 4.10kg", "体重 4.00kg"])
        XCTAssertEqual(rows.map(\.caption), ["前回より +0.20kg", "前回より +0.10kg", nil])
    }

    // MARK: 1年前のきょう

    func testPrefersTheMemoOfTheMostRecentYear() {
        let pick = CatHomeRecordsCore.yearsAgo(
            today: day(2026, 11, 13),
            memos: [memo("2年前", on: date(2024, 11, 13), cats: [cat], photo: "two"),
                    memo("1年前", on: date(2025, 11, 13), cats: [cat], photo: "one"),
                    memo("きのう", on: date(2025, 11, 12), cats: [cat], photo: "nope"),
                    memo("きょう", on: date(2026, 11, 13), cats: [cat], photo: "today")],
            photos: [.init(identifier: "photo", creationDate: date(2025, 11, 13))], calendar: calendar())
        XCTAssertEqual(pick, CatHomeYearsAgo(source: .memo(recordID: pick?.sourceMemoID ?? UUID()),
                                             photoIdentifier: "one", years: 1, text: "1年前"))
        XCTAssertEqual(pick?.label, "1年前のきょう")
    }

    func testFallsBackToThePhotoOfTheMostRecentYear() {
        let pick = CatHomeRecordsCore.yearsAgo(
            today: day(2026, 11, 13), memos: [],
            photos: [.init(identifier: "three", creationDate: date(2023, 11, 13)),
                     .init(identifier: "none", creationDate: nil),
                     .init(identifier: "two", creationDate: date(2024, 11, 13)),
                     .init(identifier: "today", creationDate: date(2026, 11, 13))],
            calendar: calendar())
        XCTAssertEqual(pick, CatHomeYearsAgo(source: .photo, photoIdentifier: "two", years: 2, text: nil))
        XCTAssertEqual(pick?.label, "2年前のきょう")
        XCTAssertNil(CatHomeRecordsCore.yearsAgo(today: day(2026, 11, 13), memos: [],
                                                 photos: [.init(identifier: "x", creationDate: date(2025, 11, 14))],
                                                 calendar: calendar()))
    }

    func testFebruary29CountsOnMarch1OfOtherYearsOnly() {
        let leapPhoto = CatHomeRecordsCore.Photo(identifier: "leap", creationDate: date(2024, 2, 29))
        let onMarch1 = CatHomeRecordsCore.yearsAgo(today: day(2026, 3, 1), memos: [], photos: [leapPhoto], calendar: calendar())
        XCTAssertEqual(onMarch1?.photoIdentifier, "leap")
        XCTAssertEqual(onMarch1?.years, 2)
        XCTAssertNil(CatHomeRecordsCore.yearsAgo(today: day(2026, 2, 28), memos: [], photos: [leapPhoto], calendar: calendar()))
        // In a leap year 3/1 is 3/1, and 2/29 is its own day.
        XCTAssertNil(CatHomeRecordsCore.yearsAgo(today: day(2028, 3, 1), memos: [], photos: [leapPhoto], calendar: calendar()))
        XCTAssertEqual(CatHomeRecordsCore.yearsAgo(today: day(2028, 2, 29), memos: [], photos: [leapPhoto],
                                                   calendar: calendar())?.years, 4)
    }

    func testTheDayIsTheIPhonesTimeZoneDay() {
        // 2025-11-12 16:00 UTC is 11/13 01:00 in Tokyo.
        let utc = date(2025, 11, 12, hour: 16, zone: "UTC")
        let photo = CatHomeRecordsCore.Photo(identifier: "night", creationDate: utc)
        XCTAssertEqual(CatHomeRecordsCore.yearsAgo(today: day(2026, 11, 13), memos: [], photos: [photo],
                                                   calendar: calendar("Asia/Tokyo"))?.photoIdentifier, "night")
        XCTAssertNil(CatHomeRecordsCore.yearsAgo(today: day(2026, 11, 13), memos: [], photos: [photo],
                                                 calendar: calendar("UTC")))
        let snapshot = CatHomeRecordsCore.snapshot(catIDs: [cat], memos: [memo("夜", on: utc, cats: [cat])], visits: [],
                                                   weights: [], vaccinations: [], photos: [],
                                                   now: date(2026, 11, 13), calendar: calendar("Asia/Tokyo"))
        XCTAssertEqual(snapshot.rows.first?.dateText, "2025年11月13日")
        XCTAssertEqual(snapshot.yearsAgo?.text, "夜")
    }

    // MARK: Words

    func testDateWordsAndBirthday() {
        let today = day(2026, 11, 13)
        XCTAssertEqual(CatHomeRecordsCore.dayText(day(2026, 11, 9), today: today), "11月9日")
        XCTAssertEqual(CatHomeRecordsCore.dayText(day(2025, 11, 9), today: today), "2025年11月9日")
        XCTAssertEqual(CatHomeRecordsCore.dayText(day(2027, 1, 5), today: today), "2027年1月5日")
        XCTAssertEqual(CatHomeRecordsCore.birthdayLine("あと23日"), "誕生日まで あと23日")
        XCTAssertEqual(CatHomeRecordsCore.birthdayLine("きょう"), "きょうは誕生日")
        XCTAssertEqual(CatHomeRecordsCore.memoText("\n  一行目  \n\n二行目\n三行目\n四行目"), "一行目\n二行目\n三行目")
        XCTAssertNil(CatHomeRecordsCore.memoText(" \n "))
    }

    func testMemoDayIsTakenThenWrittenThenEdited() {
        let taken = date(2026, 5, 1), written = date(2026, 6, 1)
        XCTAssertEqual(CatHomeRecordsCore.memoDate(memo("a", on: taken, cats: [cat], written: written).note), taken)
        XCTAssertEqual(CatHomeRecordsCore.memoDate(memo("a", on: nil, cats: [cat], written: written).note), written)
    }
}

private extension CatHomeYearsAgo {
    var sourceMemoID: UUID? {
        if case let .memo(id) = source { return id }
        return nil
    }
}
