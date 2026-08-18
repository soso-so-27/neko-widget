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

    init?(date: Date, calendar: Calendar = .current) {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = values.year,
              let month = values.month,
              let day = values.day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    func date(in inputCalendar: Calendar = .current) -> Date? {
        var calendar = inputCalendar
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
        "cat-v2:\(confidenceThreshold.bitPattern):\(minimumCatAreaRatio.bitPattern):\(analysisRevision)"
    }
}
