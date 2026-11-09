import Foundation

/// What StoreKit says about renewal, for the screen only (11/9). It never
/// grants or withdraws Plus: access stays with the server-confirmed authority.
struct PlusRenewalSnapshot: Equatable, Sendable {
    let willAutoRenew: Bool
    let expirationDate: Date?

    /// Several current subscriptions (e.g. monthly and annual): any renewing
    /// one means Plus continues; otherwise the latest end date is the end.
    static func combined(_ items: [PlusRenewalSnapshot]) -> PlusRenewalSnapshot? {
        guard !items.isEmpty else { return nil }
        if let renewing = items.first(where: \.willAutoRenew) { return renewing }
        return PlusRenewalSnapshot(willAutoRenew: false,
                                   expirationDate: items.compactMap(\.expirationDate).max())
    }
}

/// The words for a member whose Plus was cancelled but is still usable:
/// 「Plus（11月9日まで）」 in Settings and 「11月9日まで使えます」 on the Plus
/// screen. While it renews, or when the end is unknown or past, the usual
/// 「Plus（利用中）」 / 「Plusを利用中です」 stay.
enum PlusRenewalPresentation {
    static let renewingSettingsHeader = "Plus（利用中）"
    static let renewingOfferTitle = "Plusを利用中です"

    /// 「11月9日」, or 「2027年1月9日」 when the end is not in this year.
    /// nil while it renews, or when the end is unknown or already past.
    static func endDateText(willAutoRenew: Bool?, expiration: Date?, now: Date,
                            calendar: Calendar) -> String? {
        guard willAutoRenew == false, let expiration, expiration > now else { return nil }
        let end = calendar.dateComponents([.year, .month, .day], from: expiration)
        guard let year = end.year, let month = end.month, let day = end.day else { return nil }
        let monthDay = "\(month)月\(day)日"
        return year == calendar.component(.year, from: now) ? monthDay : "\(year)年\(monthDay)"
    }

    static func settingsHeader(willAutoRenew: Bool?, expiration: Date?, now: Date,
                               calendar: Calendar) -> String {
        endDateText(willAutoRenew: willAutoRenew, expiration: expiration, now: now, calendar: calendar)
            .map { "Plus（\($0)まで）" } ?? renewingSettingsHeader
    }

    /// The one line on the Plus screen when it will not renew; nil otherwise.
    static func offerEndLine(willAutoRenew: Bool?, expiration: Date?, now: Date,
                             calendar: Calendar) -> String? {
        endDateText(willAutoRenew: willAutoRenew, expiration: expiration, now: now, calendar: calendar)
            .map { "\($0)まで使えます" }
    }
}
