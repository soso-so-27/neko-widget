import Foundation

/// What StoreKit says about renewal, for the screen only (11/9). It never
/// grants or withdraws Plus: access stays with the server-confirmed authority.
struct PlusRenewalSnapshot: Equatable, Sendable {
    let willAutoRenew: Bool
    let expirationDate: Date?
    var trialEndsAt: Date? = nil
    var productID: String? = nil

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
/// screen. While it renews, Settings says 「Plus（12月24日に更新）」 (11/24);
/// when the date is unknown or past, the usual 「Plus（利用中）」 /
/// 「Plusを利用中です」 stay.
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
                               calendar: Calendar, trialEndsAt: Date? = nil, displayPrice: String? = nil) -> String {
        if willAutoRenew == true, let trialEndsAt, trialEndsAt > now, let displayPrice {
            return "Plus（お試し中・\(monthDay(trialEndsAt, calendar: calendar))から月額\(displayPrice)）"
        }
        if let ending = endDateText(willAutoRenew: willAutoRenew, expiration: expiration, now: now, calendar: calendar)
            .map({ "Plus（\($0)まで）" }) { return ending }
        // 11/24: while it renews, the next renewal day when StoreKit has it.
        return renewalDateText(willAutoRenew: willAutoRenew, expiration: expiration, now: now, calendar: calendar)
            .map { "Plus（\($0)に更新）" } ?? renewingSettingsHeader
    }

    /// 「12月24日」 (or with the year) for a renewing Plus; nil when unknown or past.
    static func renewalDateText(willAutoRenew: Bool?, expiration: Date?, now: Date,
                                calendar: Calendar) -> String? {
        guard willAutoRenew == true, let expiration, expiration > now else { return nil }
        let next = calendar.dateComponents([.year, .month, .day], from: expiration)
        guard let year = next.year, let month = next.month, let day = next.day else { return nil }
        let monthDay = "\(month)月\(day)日"
        return year == calendar.component(.year, from: now) ? monthDay : "\(year)年\(monthDay)"
    }

    static func monthDay(_ date: Date, calendar: Calendar) -> String {
        "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    static func trialEnd(from date: Date, component: Calendar.Component, value: Int,
                         count: Int, calendar: Calendar) -> Date? {
        let (amount, overflow) = value.multipliedReportingOverflow(by: count)
        guard !overflow, value > 0, count > 0 else { return nil }
        return calendar.date(byAdding: component, value: amount, to: calendar.startOfDay(for: date))
    }

    /// The one line on the Plus screen when it will not renew; nil otherwise.
    static func offerEndLine(willAutoRenew: Bool?, expiration: Date?, now: Date,
                             calendar: Calendar) -> String? {
        endDateText(willAutoRenew: willAutoRenew, expiration: expiration, now: now, calendar: calendar)
            .map { "\($0)まで使えます" }
    }
}

/// Rebuilt from StoreKit's verified transaction history, including expired
/// renewals. No opened-work stamp or locally persisted grant is an input.
struct PlusWorkHistory: Equatable, Sendable {
    struct Period: Equatable, Sendable {
        let originalID: UInt64
        let start: Date
        let end: Date
        var purchased = true
        var revoked = false
        var upgraded = false
    }
    let periods: [Period]
    var complete = true

    func contains(arrival: Date, now: Date) -> Bool {
        guard arrival <= now, arrival.timeIntervalSinceReferenceDate.isFinite else { return false }
        return periods.contains { period in
            guard period.purchased, !period.revoked, period.start <= arrival,
                  period.start < period.end else { return false }
            var end = period.end
            if period.upgraded {
                // An upgrade replaces the old period early. Without the signed
                // successor there is no trustworthy end, so do not grant it.
                guard let successor = periods.filter({ $0.originalID == period.originalID && $0.start > period.start })
                    .map(\.start).min() else { return false }
                end = min(end, successor)
            }
            return arrival < end
        }
    }
}

/// The Plus row in Settings (11/10). Every launch/foreground refresh passes
/// through `.checking` again, even for a known non-member; showing that
/// swapped the rows and the Plus sheet hung on this section each time.
enum PlusSettingsRowStatus: Equatable, Sendable {
    case notMember, member, unknown, checking

    /// A re-check keeps the last answer on screen. Only the very first check,
    /// with no answer yet, shows 「確認しています…」.
    static func steady(_ current: Self, lastAnswer: Self?) -> Self {
        current == .checking ? (lastAnswer ?? .checking) : current
    }

    /// 11/16: the row from the store's answer. A usable server answer is Plus
    /// even when it will not renew (cancelled, still in its period). Only a
    /// missing answer is 「確認できません」; an ended Plus is `.notMember`,
    /// which offers Plus again.
    /// 11/25: `linkedPlusOnSave` is the save server's own answer that this
    /// person's linked Plus is active (自動保存 is saving). It settles an open
    /// question (checking, no answer, a purchase not yet confirmed) as Plus,
    /// so 設定 never says 「購入を確かめられません」 next to a working 自動保存.
    /// It never overrides this iPhone's own "ended" answer, and it is display
    /// only: it grants nothing here.
    /// 11/25 (TestFlight 413): `linkedPlusPending` is that answer not read yet
    /// in this app session (or being read). An open question then waits as
    /// 「確認しています…」 instead of saying 「確かめられません」 and flipping to
    /// Plus a moment later.
    static func live(usableServerAnswer: Bool, firstCheck: Bool, answerMissing: Bool,
                     purchaseWaiting: Bool, linkedPlusOnSave: Bool = false,
                     linkedPlusPending: Bool = false) -> Self {
        if usableServerAnswer { return .member }
        let open = firstCheck || answerMissing || purchaseWaiting
        if open && linkedPlusOnSave { return .member }
        if firstCheck || (open && linkedPlusPending) { return .checking }
        if answerMissing || purchaseWaiting { return .unknown }
        return .notMember
    }

    /// 11/25: how long 設定 waits for 自動保存's Plus answer before saying
    /// 「確かめられません」 (no endless 「確認しています…」).
    static let linkedPlusWait: TimeInterval = 10

    static func linkedPlusPending(readPending: Bool, waited: TimeInterval) -> Bool {
        readPending && waited < linkedPlusWait
    }
}

/// When the Plus screen re-reads its price (11/10: it reloaded over and over,
/// and 「料金を確認できません」 showed next to the price).
enum PlusOfferReloadPolicy {
    /// 11/22 (1122n): 「もう一度読み込む」 sits right below; no second instruction.
    static let unavailableMessage = "料金を確認できません。"

    /// Once per settled catalog: never while products are still loading, and
    /// never twice for the same catalog revision.
    static func shouldReload(observedRevision: UInt64?, currentRevision: UInt64,
                             catalogLoading: Bool) -> Bool {
        !catalogLoading && observedRevision != currentRevision
    }

    /// The price on screen: a new one as soon as it loads; nothing only when a
    /// settled load found no product; otherwise (a load overtaken by a newer
    /// catalog) the last price stays instead of blinking away.
    static func displayed<Offer>(previous: Offer?, loaded: Offer?, settled: Bool) -> Offer? {
        if let loaded { return loaded }
        return settled ? nil : previous
    }

    /// The unavailable line only when loading finished with no product at all,
    /// never while a price is shown and never for a member.
    static func showsUnavailable(loadFinishedWithoutOffer: Bool, showsPrice: Bool, isMember: Bool) -> Bool {
        loadFinishedWithoutOffer && !showsPrice && !isMember
    }
}
