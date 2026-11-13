import Foundation

// MARK: - 「この子」 page: the cat's records (11/13, 「記録が並ぶ」)
//
// The lower part of a cat's page gathers what already exists elsewhere: the
// photo memos, weights and vaccinations of 「この子のこと」, and finished vet
// memos. Nothing new is stored. This file is Foundation only: the merge, the
// order, the words and the 「1年前のきょう」 pick, so unit tests can pin them.

/// One row of 「{name}の記録」.
struct CatHomeRecordRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Opens the memo's photo, as the 写真 tab's memo list does.
        case memo(recordID: UUID, photoIdentifier: String)
        /// Opens 体重 of この子のこと.
        case weight
        /// Opens this finished memo of 病院で見せる.
        case vet(visitID: UUID)
        /// Opens ワクチン of この子のこと.
        case vaccination
    }

    let id: String
    let kind: Kind
    let day: CatCareDay
    /// Orders rows of the same day, newest first.
    let at: Date
    /// 「11月9日」, with the year when not this year.
    let dateText: String
    /// 「体重 5.50kg」 / 「病院　…」 / 「ワクチン　…」 / the memo's text.
    let title: String
    /// 「メモ」 / 「前回より +0.10kg」 / 「次は12月3日」 / 「次は2027年9月ごろ」.
    let caption: String?
    /// What VoiceOver reads: date, kind, text.
    let spoken: String
}

/// 「1年前のきょう」: a memo of this cat on today's month and day in an
/// earlier year, else a photo of this cat taken on it.
struct CatHomeYearsAgo: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case memo(recordID: UUID)
        case photo
    }

    let source: Source
    let photoIdentifier: String
    let years: Int
    /// The memo's text; nil for a photo.
    let text: String?

    var label: String { "\(years)年前のきょう" }
}

struct CatHomeRecordsSnapshot: Equatable, Sendable {
    var yearsAgo: CatHomeYearsAgo?
    /// Every row, newest first; the page shows the first few.
    var rows: [CatHomeRecordRow] = []

    static let empty = CatHomeRecordsSnapshot()
}

enum CatHomeRecordsCore {
    /// Rows shown at first, and how many more each 「もっと見る」 shows.
    static let firstRows = 5
    static let moreRows = 20

    /// A photo of the cat: only what the pick needs.
    struct Photo: Equatable, Sendable {
        let identifier: String
        let creationDate: Date?
    }

    static func snapshot(catIDs: Set<UUID>, memos: [PhotoMemoryNoteRecord], visits: [VeterinaryVisit],
                         weights: [CatCareWeight], vaccinations: [CatCareVaccination], photos: [Photo],
                         now: Date, calendar: Calendar = .nekoGregorian) -> CatHomeRecordsSnapshot {
        guard let today = CatCareDay(date: now, calendar: calendar) else { return .empty }
        let ownMemos = memos.filter { belongs($0, to: catIDs) }
        var rows: [CatHomeRecordRow] = []
        rows += ownMemos.compactMap { memoRow($0, today: today, calendar: calendar) }
        rows += weightRows(weights, today: today)
        rows += visits.compactMap { visit in
            catIDs.contains(visit.catID) ? vetRow(visit, today: today, calendar: calendar) : nil
        }
        rows += vaccinations.filter { $0.deletedAt == nil }.map { vaccinationRow($0, today: today) }
        return CatHomeRecordsSnapshot(
            yearsAgo: yearsAgo(today: today, memos: ownMemos, photos: photos, calendar: calendar),
            rows: sorted(rows))
    }

    /// Newest day first; within a day the newest written first; then by id,
    /// so the order never changes between two readings.
    static func sorted(_ rows: [CatHomeRecordRow]) -> [CatHomeRecordRow] {
        rows.sorted { left, right in
            if left.day != right.day { return left.day > right.day }
            if left.at != right.at { return left.at > right.at }
            return left.id < right.id
        }
    }

    // MARK: Memos

    /// A memo the user put this cat in (its cats are chosen explicitly).
    static func belongs(_ record: PhotoMemoryNoteRecord, to catIDs: Set<UUID>) -> Bool {
        (record.note.context?.cats ?? []).contains { catIDs.contains($0.id) }
    }

    /// The memo's day, as the memo list dates it: taken, else written, else edited.
    static func memoDate(_ note: PhotoMemoryNote) -> Date {
        note.context?.capturedAt ?? note.writtenAt ?? note.updatedAt
    }

    /// The memo's words for a row: blank lines dropped, a long text cut.
    static func memoText(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.prefix(3).joined(separator: "\n").prefix(140))
    }

    static func memoRow(_ record: PhotoMemoryNoteRecord, today: CatCareDay, calendar: Calendar) -> CatHomeRecordRow? {
        let at = memoDate(record.note)
        guard let text = memoText(record.note.text), let day = CatCareDay(date: at, calendar: calendar) else { return nil }
        let date = dayText(day, today: today)
        return CatHomeRecordRow(id: "memo-" + record.note.id.uuidString,
                                kind: .memo(recordID: record.note.id, photoIdentifier: record.photoIdentifier),
                                day: day, at: at, dateText: date, title: text, caption: "メモ",
                                spoken: [date, "メモ", text.replacingOccurrences(of: "\n", with: " ")].joined(separator: "、"))
    }

    // MARK: Weights

    /// Each weight with the change from the one measured before it.
    static func weightRows(_ weights: [CatCareWeight], today: CatCareDay) -> [CatHomeRecordRow] {
        let active = weights.filter { $0.deletedAt == nil }.sorted {
            $0.measuredOn != $1.measuredOn ? $0.measuredOn > $1.measuredOn : $0.editedAt > $1.editedAt
        }
        return active.enumerated().map { index, weight in
            let previous = index + 1 < active.count ? active[index + 1].grams : nil
            let caption = weightChange(weight.grams, previous: previous)
            let date = dayText(weight.measuredOn, today: today)
            let value = CatCareFormat.weight(weight.grams)
            return CatHomeRecordRow(id: "weight-" + weight.id.uuidString, kind: .weight, day: weight.measuredOn,
                                    at: weight.editedAt, dateText: date, title: "体重 " + value, caption: caption,
                                    spoken: ([date, "体重", value] + [caption].compactMap { $0 }).joined(separator: "、"))
        }
    }

    /// 「前回より +0.10kg」 / 「前回より −0.05kg」 / 「前回と同じ」; nil for the first.
    static func weightChange(_ grams: Int, previous: Int?) -> String? {
        guard let previous else { return nil }
        let change = grams - previous
        guard change != 0 else { return "前回と同じ" }
        let amount = String(format: "%.2f", Double(abs(change)) / 1000)
        return "前回より " + (change > 0 ? "+" : "\u{2212}") + amount + "kg"
    }

    // MARK: Vet memos

    /// A finished memo (「診察済み」), on the day it was finished.
    static func vetRow(_ visit: VeterinaryVisit, today: CatCareDay, calendar: Calendar) -> CatHomeRecordRow? {
        guard let finished = visit.completedAt, let day = CatCareDay(date: finished, calendar: calendar) else { return nil }
        let words = [visit.doctorNote ?? "", visit.observations]
            .compactMap { firstLine($0) }
            .first
        let next = visit.nextVisitOn.flatMap { CatCareDay(isoDay: $0) }.map { "次は" + dayText($0, today: today) }
        let date = dayText(day, today: today)
        return CatHomeRecordRow(id: "vet-" + visit.id.uuidString, kind: .vet(visitID: visit.id), day: day, at: finished,
                                dateText: date, title: words.map { "病院　" + $0 } ?? "病院", caption: next,
                                spoken: ([date, "病院"] + [words, next].compactMap { $0 }).joined(separator: "、"))
    }

    /// The first written line, cut to fit one line.
    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { String($0.prefix(60)) }
    }

    // MARK: Vaccinations

    static func vaccinationRow(_ vaccination: CatCareVaccination, today: CatCareDay) -> CatHomeRecordRow {
        let name = vaccination.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = vaccination.nextDueOn.map { "次は\($0.year)年\($0.month)月ごろ" }
        let date = dayText(vaccination.givenOn, today: today)
        return CatHomeRecordRow(id: "vaccination-" + vaccination.id.uuidString, kind: .vaccination,
                                day: vaccination.givenOn, at: vaccination.editedAt, dateText: date,
                                title: name.isEmpty ? "ワクチン" : "ワクチン　" + name, caption: next,
                                spoken: ([date, "ワクチン"] + [name.isEmpty ? nil : name, next].compactMap { $0 })
                                    .joined(separator: "、"))
    }

    // MARK: Days

    /// 「11月9日」, or 「2025年11月9日」 when not this year.
    static func dayText(_ day: CatCareDay, today: CatCareDay) -> String {
        day.year == today.year ? "\(day.month)月\(day.day)日" : "\(day.year)年\(day.month)月\(day.day)日"
    }

    /// The same month and day as today in an earlier year. On 3/1 of a year
    /// without 2/29, a 2/29 counts (as a birthday on 2/29 does).
    static func isSameDay(_ day: CatCareDay, earlierThan today: CatCareDay) -> Bool {
        guard day.year < today.year else { return false }
        if day.month == today.month && day.day == today.day { return true }
        let leap = CatCareDay(year: today.year, month: 2, day: 29) != nil
        return !leap && today.month == 3 && today.day == 1 && day.month == 2 && day.day == 29
    }

    /// The memo of the most recent such year, else the photo of it.
    static func yearsAgo(today: CatCareDay, memos: [PhotoMemoryNoteRecord], photos: [Photo],
                         calendar: Calendar) -> CatHomeYearsAgo? {
        var bestMemo: (record: PhotoMemoryNoteRecord, day: CatCareDay, text: String, at: Date)?
        for record in memos {
            let at = memoDate(record.note)
            guard let text = memoText(record.note.text), let day = CatCareDay(date: at, calendar: calendar),
                  isSameDay(day, earlierThan: today) else { continue }
            if let best = bestMemo, best.day.year > day.year || (best.day.year == day.year && best.at >= at) { continue }
            bestMemo = (record, day, text, at)
        }
        if let memo = bestMemo {
            return CatHomeYearsAgo(source: .memo(recordID: memo.record.note.id),
                                   photoIdentifier: memo.record.photoIdentifier,
                                   years: today.year - memo.day.year, text: memo.text)
        }
        var bestPhoto: (photo: Photo, year: Int, at: Date)?
        for photo in photos {
            guard let at = photo.creationDate, let day = CatCareDay(date: at, calendar: calendar),
                  isSameDay(day, earlierThan: today) else { continue }
            if let best = bestPhoto, best.year > day.year || (best.year == day.year && best.at >= at) { continue }
            bestPhoto = (photo, day.year, at)
        }
        return bestPhoto.map {
            CatHomeYearsAgo(source: .photo, photoIdentifier: $0.photo.identifier, years: today.year - $0.year, text: nil)
        }
    }

    /// 「誕生日まで あと23日」 / 「きょうは誕生日」 from CatHomeFacts.birthdayIn.
    static func birthdayLine(_ birthdayIn: String) -> String {
        birthdayIn == "きょう" ? "きょうは誕生日" : "誕生日まで " + birthdayIn
    }
}
