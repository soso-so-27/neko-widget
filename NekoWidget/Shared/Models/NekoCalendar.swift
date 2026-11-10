import Foundation

extension Calendar {
    /// 西暦 in the iPhone's time zone. Stored days and every year/month number
    /// the app counts or shows use it, so an iPhone set to 和暦 or 仏暦 still
    /// saves 2026-11-09 and shows 「2026年」, never 「8年」. Relative checks
    /// (today, same day, adding days) may keep using the iPhone's calendar.
    static var nekoGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    /// 西暦 in `other`'s time zone, whatever calendar `other` is.
    static func nekoGregorian(in other: Calendar) -> Calendar {
        var calendar = nekoGregorian
        calendar.timeZone = other.timeZone
        return calendar
    }
}

extension Date {
    /// The day as exports print it (PDFs, sheets): 「2026/11/09」, 西暦 and
    /// Japanese even when the iPhone shows 令和 or 仏暦.
    func nekoExportText(time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        formatted(Date.FormatStyle(date: .numeric, time: time, locale: Locale(identifier: "ja_JP"),
                                   calendar: .nekoGregorian, timeZone: .current))
    }
}
