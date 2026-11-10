import Foundation

/// When the App Store review prompt may be asked for (11/10). The monthly
/// book's last page asks once, but only Plus reaches it. Free users get one
/// more moment: the first cat photo opened in a launch, once the widget is set
/// up and the app has been used on 3 different days. Apple's own prompt, no
/// text of ours; Apple still decides whether it shows. Asked once from here, ever.
enum ReviewPromptPolicy {
    /// Up to `requiredDays` 西暦 days ("2026-11-10") the app became active on.
    static let usedDaysKey = "review.usedDays.v1"
    static let askedAfterPhotoKey = "review.requestedAfterPhoto.v1"
    /// AlbumPrototypeView's @AppStorage key: one prompt is enough.
    static let askedAfterMonthlyBookKey = "review.requestedAfterMonthlyBook.v1"
    static let requiredDays = 3

    static func dayKey(_ date: Date, calendar: Calendar = .nekoGregorian) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The kept days with `day` added; nil when nothing changes (no write).
    /// Only the first `requiredDays` are kept: that is all the rule needs.
    static func adding(_ day: String, to days: [String]) -> [String]? {
        guard !days.contains(day), days.count < requiredDays else { return nil }
        return days + [day]
    }

    static func mayAskAfterPhoto(usedDays: [String], widgetPlaced: Bool, onboardingDone: Bool,
                                 askedAfterPhoto: Bool, askedAfterMonthlyBook: Bool,
                                 askedThisSession: Bool) -> Bool {
        onboardingDone && widgetPlaced && Set(usedDays).count >= requiredDays
            && !askedAfterPhoto && !askedAfterMonthlyBook && !askedThisSession
    }

    // MARK: UserDefaults (on becoming active and once at the prompt; never while scrolling)

    static func noteActive(now: Date = Date(), defaults: UserDefaults = .standard) {
        let days = defaults.stringArray(forKey: usedDaysKey) ?? []
        guard let next = adding(dayKey(now), to: days) else { return }
        defaults.set(next, forKey: usedDaysKey)
    }
}
