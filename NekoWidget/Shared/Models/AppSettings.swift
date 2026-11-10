import Foundation

enum PhotoDateRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case recentYear

    var id: Self { self }
}

enum CatLifeReferenceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case birthday
    case adoptionDay

    var id: Self { self }
}

/// A calendar-only value avoids moving the cat's birthday/adoption day when a
/// device changes time zone. It is local metadata and is never logged.
struct CatLifeDate: Codable, Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    /// Always 西暦, in `calendar`'s time zone: a 和暦 calendar still gives 2026.
    init?(date: Date, calendar: Calendar = .nekoGregorian) {
        let values = Calendar.nekoGregorian(in: calendar).dateComponents([.year, .month, .day], from: date)
        guard let year = values.year,
              let month = values.month,
              let day = values.day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    func date(in inputCalendar: Calendar = .nekoGregorian,
              deviceCalendar: Calendar = .current) -> Date? {
        var calendar = inputCalendar
        if Self.isDeviceCalendarYear(year, reading: inputCalendar, device: deviceCalendar) {
            // Saved before 11/10 on an iPhone set to 和暦 or 仏暦: the year is
            // that calendar's (「8」, 「2569」). Read it as it was read then.
            calendar = deviceCalendar
            calendar.timeZone = inputCalendar.timeZone
        }
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    /// A 西暦 year no cat could have (before 1900 or after next year), on an
    /// iPhone whose own calendar is not 西暦: an old value in that calendar.
    static func isDeviceCalendarYear(_ year: Int, reading calendar: Calendar, device: Calendar) -> Bool {
        guard calendar.identifier == .gregorian, device.identifier != .gregorian else { return false }
        let nextYear = calendar.component(.year, from: Date()) + 1
        return year < 1900 || year > nextYear
    }
}

struct CatLifeReference: Codable, Equatable, Sendable {
    var kind: CatLifeReferenceKind
    var date: CatLifeDate
}

struct AppSettings: Codable, Equatable, Sendable {
    var dateRange: PhotoDateRange
    var albumMaximum: Int
    var confidenceThreshold: Float
    var minimumCatAreaRatio: Double
    var albumName: String
    var quickScanLimit: Int
    var widgetEntryCount: Int
    var widgetEntryIntervalMinutes: Int
    var analysisRevision: Int
    /// Changing this only regroups dates; it must not invalidate Vision work.
    var catLifeReference: CatLifeReference? = nil

    static let `default` = AppSettings(
        dateRange: .all,
        albumMaximum: 300,
        confidenceThreshold: 0.7,
        minimumCatAreaRatio: 0.08,
        albumName: "うちの子",
        quickScanLimit: 500,
        widgetEntryCount: 20,
        widgetEntryIntervalMinutes: 20,
        analysisRevision: 1
    )

    func normalized() -> AppSettings {
        var value = self
        value.albumMaximum = min(2_000, max(1, albumMaximum))
        value.confidenceThreshold = min(1, max(0, confidenceThreshold))
        value.minimumCatAreaRatio = min(1, max(0, minimumCatAreaRatio))
        value.quickScanLimit = min(2_000, max(1, quickScanLimit))
        value.widgetEntryCount = min(20, max(15, widgetEntryCount))
        value.widgetEntryIntervalMinutes = min(30, max(10, widgetEntryIntervalMinutes))
        value.analysisRevision = max(1, analysisRevision)
        let today = Calendar.current.startOfDay(for: .now)
        let startOfTomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)
        if let referenceDate = value.catLifeReference?.date.date(),
           let startOfTomorrow,
           referenceDate < startOfTomorrow {
            // Keep the validated date-only value.
        } else {
            value.catLifeReference = nil
        }
        return value
    }

    var analysisFingerprint: String {
        // Minimum area is a Widget presentation policy, not detector input.
        // Changing it must not invalidate otherwise identical Vision evidence.
        "cat-v3:\(confidenceThreshold.bitPattern):\(analysisRevision)"
    }
}
