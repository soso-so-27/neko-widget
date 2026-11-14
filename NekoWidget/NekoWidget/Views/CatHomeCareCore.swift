import Foundation

// MARK: - 「この子」 page: 「これからのこと」 (11/14, 「猫を大切にできるページ」)
//
// Under the five buttons a cat's page has one card: 誕生日, ワクチン, 病院,
// 体重 in this order, each only when something is written for it (11/14: no
// 未設定・未記入・なし on the page; an empty 「ワクチン 未記入」 in a shared
// screenshot reads as a judgement), then 「この子のこと」. Each value is read from what is
// already written (この子のこと and 病院で見せる); nothing is stored and no
// schedule is ever worked out (no 「one year after the last vaccine」).
// The hero's day-specific line (誕生日, うちに来た日) is here too. This file is
// Foundation only, so unit tests pin every word and boundary.

enum CatHomeCareCore {
    /// How a value reads: gray, in the text colour (soon), or orange (the one
    /// accent, an unfinished vet memo).
    enum Tone: Equatable, Sendable {
        case quiet
        case soon
        case unfinished
    }

    struct Value: Equatable, Sendable {
        let text: String
        var tone: Tone = .quiet
    }

    /// A vet memo of 病院で見せる: only what the 病院 row needs.
    struct VetMemo: Equatable, Sendable {
        var completedAt: Date?
        /// Something is written in it (the same test as the old orange dot).
        var hasContent: Bool
        var nextVisit: CatCareDay?

        init(completedAt: Date?, hasContent: Bool, nextVisit: CatCareDay?) {
            self.completedAt = completedAt
            self.hasContent = hasContent
            self.nextVisit = nextVisit
        }

        init(_ visit: VeterinaryVisit) {
            completedAt = visit.completedAt
            hasContent = !visit.observations.isEmpty || !visit.questions.isEmpty || !visit.entries.isEmpty
                || visit.hasResults
            nextVisit = visit.nextVisitOn.flatMap { CatCareDay(isoDay: $0) }
        }

        var isUnfinished: Bool { completedAt == nil && hasContent }
    }

    /// The birthday and the next vet visit read in the text colour from this
    /// many days before.
    static let soonDays = 7
    /// A vaccination stays 「次は…ごろ」 this many days after its due day.
    static let vaccinationGraceDays = 60

    // MARK: 誕生日

    /// 「7月10日（あと239日）」, 「きょう」 on the day; nil without one.
    static func birthday(_ birthday: CatCareDay?, today: CatCareDay) -> Value? {
        guard let birthday, let next = nextOccurrence(of: birthday, onOrAfter: today),
              let days = days(from: today, to: next) else { return nil }
        if days == 0 { return Value(text: "きょう", tone: .soon) }
        return Value(text: "\(birthday.month)月\(birthday.day)日（あと\(days)日）",
                     tone: days <= soonDays ? .soon : .quiet)
    }

    // MARK: ワクチン

    /// 「次は 11月ごろ」 from a recorded next due day (ahead, or at most 60
    /// days past); else 「前回 2025年11月8日」; else nil.
    static func vaccination(_ vaccinations: [CatCareVaccination], today: CatCareDay) -> Value? {
        let active = vaccinations.filter { $0.deletedAt == nil }
        if let earliest = adding(-vaccinationGraceDays, to: today),
           let due = active.compactMap(\.nextDueOn).filter({ $0 >= earliest }).min() {
            let text = due.year == today.year ? "次は \(due.month)月ごろ" : "次は \(due.year)年\(due.month)月ごろ"
            let from = CatCareDay(year: due.year, month: due.month, day: 1) ?? due
            let until = adding(vaccinationGraceDays, to: due) ?? due
            return Value(text: text, tone: today >= from && today <= until ? .soon : .quiet)
        }
        if let last = active.map(\.givenOn).filter({ $0 <= today }).max() {
            return Value(text: "前回 " + dayText(last, today: today))
        }
        return nil
    }

    // MARK: 病院

    /// 「書きかけ」 for an unfinished memo with something in it; else the
    /// next visit day of the newest finished memo that has one, when today or
    /// later; else 「前回」 and the newest finished memo's day; else nil.
    static func vet(_ memos: [VetMemo], today: CatCareDay, calendar: Calendar = .nekoGregorian) -> Value? {
        if memos.contains(where: \.isUnfinished) { return Value(text: "書きかけ", tone: .unfinished) }
        let finished = memos.compactMap { memo in memo.completedAt.map { (at: $0, memo: memo) } }
            .sorted { $0.at > $1.at }
        if let next = finished.lazy.compactMap({ $0.memo.nextVisit }).first, next >= today,
           let days = days(from: today, to: next) {
            if days == 0 { return Value(text: "きょう", tone: .soon) }
            return Value(text: "次は " + dayText(next, today: today), tone: days <= soonDays ? .soon : .quiet)
        }
        if let last = finished.first, let day = CatCareDay(date: last.at, calendar: calendar) {
            return Value(text: "前回 " + dayText(day, today: today))
        }
        return nil
    }

    // MARK: 体重

    /// 「5.50kg（10月21日）」 from the newest weight; nil without one.
    static func weight(_ weights: [CatCareWeight], today: CatCareDay) -> Value? {
        let latest = weights.filter { $0.deletedAt == nil }.max { left, right in
            left.measuredOn != right.measuredOn ? left.measuredOn < right.measuredOn : left.editedAt < right.editedAt
        }
        guard let latest else { return nil }
        return Value(text: CatCareFormat.weight(latest.grams) + "（" + dayText(latest.measuredOn, today: today) + "）")
    }

    // MARK: The hero's line on the day

    /// 「きょうで5歳」 (「きょうは誕生日」 when the year is not known) on the
    /// birthday; 「うちに来て 4年」 on the day the cat came home, from the
    /// first year. Nil on every other day. 2/29 counts on 3/1 in other years.
    static func heroDayLine(birthday: CatCareDay?, birthdayYearKnown: Bool, adoption: CatCareDay?,
                            today: CatCareDay) -> String? {
        if let birthday, birthday <= today, nextOccurrence(of: birthday, onOrAfter: today) == today {
            let years = completedYears(from: birthday, to: today)
            return birthdayYearKnown && years >= 1 ? "きょうで\(years)歳" : "きょうは誕生日"
        }
        if let adoption, adoption < today, nextOccurrence(of: adoption, onOrAfter: today) == today {
            let years = completedYears(from: adoption, to: today)
            if years >= 1 { return "うちに来て \(years)年" }
        }
        return nil
    }

    // MARK: Days

    /// 「11月9日」, or 「2025年11月9日」 when not this year.
    static func dayText(_ day: CatCareDay, today: CatCareDay) -> String {
        day.year == today.year ? "\(day.month)月\(day.day)日" : "\(day.year)年\(day.month)月\(day.day)日"
    }

    /// The day's month and day in `year`; 2/29 is 3/1 in a year without it.
    static func occurrence(of day: CatCareDay, in year: Int) -> CatCareDay? {
        CatCareDay(year: year, month: day.month, day: day.day) ?? CatCareDay(year: year, month: 3, day: 1)
    }

    /// This year's day if it is today or later, else next year's.
    static func nextOccurrence(of day: CatCareDay, onOrAfter today: CatCareDay) -> CatCareDay? {
        if let this = occurrence(of: day, in: today.year), this >= today { return this }
        return occurrence(of: day, in: today.year + 1)
    }

    /// Whole years from `start` to `end`; on 3/1 of a year without 2/29, a
    /// 2/29 has had its year.
    static func completedYears(from start: CatCareDay, to end: CatCareDay) -> Int {
        let reached = occurrence(of: start, in: end.year).map { $0 <= end } ?? true
        return end.year - start.year - (reached ? 0 : 1)
    }

    /// Days between two calendar days; counted in UTC, so no clock change
    /// or time zone moves a day.
    static func days(from start: CatCareDay, to end: CatCareDay) -> Int? {
        guard let first = utcDate(start), let second = utcDate(end) else { return nil }
        return utc.dateComponents([.day], from: first, to: second).day
    }

    static func adding(_ count: Int, to day: CatCareDay) -> CatCareDay? {
        guard let date = utcDate(day), let moved = utc.date(byAdding: .day, value: count, to: date) else { return nil }
        return CatCareDay(date: moved, calendar: utc)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static func utcDate(_ day: CatCareDay) -> Date? {
        utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }
}

// MARK: - 「この子」 page: the name and the dots on the photo (11/14)

/// Pure layout rules of the hero, pinned by unit tests: the name's size
/// ladder and the page dots beyond seven cats.
enum CatHomeHeroLayout {
    /// The name's sizes at the default text size, largest first.
    static let nameLadder: [Double] = [56, 48, 40, 34]
    /// Dynamic Type scales the ladder up to this (56 → 84, as before).
    static let nameScaleCap = 1.5
    /// The name takes at most this share of the photo's width at rest.
    static let nameWidthShare = 0.62
    /// The middle of the name's glyphs above its baseline, as a share of
    /// its size (kana, kanji and capitals alike); the menu button sits there.
    static let glyphCentre = 0.36

    struct NameFit: Equatable {
        var size: Double
        var lines: Int
    }

    /// The largest ladder size whose one-line width (`width(size)`) fits
    /// `maxWidth`; else two lines at the smallest size.
    static func nameFit(scale: Double, maxWidth: Double, width: (Double) -> Double) -> NameFit {
        let factor = min(max(scale, 0.5), nameScaleCap)
        let sizes = nameLadder.map { ($0 * factor).rounded() }
        for size in sizes where width(size) <= maxWidth {
            return NameFit(size: size, lines: 1)
        }
        return NameFit(size: sizes.last ?? nameLadder[nameLadder.count - 1], lines: 2)
    }

    struct Dot: Equatable {
        var index: Int
        /// 1, or smaller at an end that has more pages beyond it.
        var scale: Double
    }

    /// At most this many dots, as the system page control.
    static let maxDots = 7

    /// The dots for `count` pages (none for one page): every page up to
    /// seven; beyond that the seven around `current`, the end dot at half
    /// size and the one next to it at three quarters on a side with more
    /// pages beyond. The current page is always a full dot.
    static func dots(count: Int, current: Int) -> [Dot] {
        guard count > 1 else { return [] }
        let current = min(max(current, 0), count - 1)
        guard count > maxDots else { return (0..<count).map { Dot(index: $0, scale: 1) } }
        let start = min(max(current - maxDots / 2, 0), count - maxDots)
        let end = start + maxDots
        return (start..<end).map { index in
            var scale = 1.0
            if start > 0 {
                if index == start { scale = 0.5 } else if index == start + 1 { scale = 0.75 }
            }
            if end < count {
                if index == end - 1 { scale = 0.5 } else if index == end - 2 { scale = 0.75 }
            }
            return Dot(index: index, scale: index == current ? 1 : scale)
        }
    }
}
