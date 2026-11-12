import Foundation

private enum Failure: Error { case check(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.check(message) }
}

@main struct VerifyPlusAuthorityCache {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        func context(account: String = "owner", key: String = "key", installation: String = "install",
                     environment: String = "Sandbox", endpoint: String = "https://billing.invalid") -> PlusCacheContext {
            PlusCacheContext(billingAccountID: account, billingKeyID: key, installationMarker: installation,
                environment: environment, endpoint: endpoint)
        }
        func authority(access: TimeInterval = 3600, freshness: TimeInterval = 1800, evaluated: TimeInterval = -60,
                       received: TimeInterval = -30, status: String = "active") -> PlusCachedAuthority {
            PlusCachedAuthority(status: status, productID: "plus", accessUntil: now.addingTimeInterval(access),
                authorityStaleAt: now.addingTimeInterval(freshness), serverEvaluatedAt: now.addingTimeInterval(evaluated),
                receivedAt: now.addingTimeInterval(received))
        }
        let expected = context()
        var cache = PlusPurchaseCache(context: expected, authority: authority())
        // Simulates app restart by encoding/decoding the exact persisted bytes.
        cache = try JSONDecoder().decode(PlusPurchaseCache.self, from: JSONEncoder().encode(cache))
        let originalDeadline = cache.authority!.authorityStaleAt
        for offset in [0.0, 60.0, 1799.0] {
            try check(cache.usableAuthority(context: expected, now: now.addingTimeInterval(offset)) != nil, "fresh cache survives launch")
            try check(cache.authority!.authorityStaleAt == originalDeadline, "launch does not extend freshness")
        }
        try check(cache.usableAuthority(context: expected, now: now.addingTimeInterval(1800)) == nil, "freshness boundary")
        for other in [context(account: "other"), context(key: "new-key"), context(installation: "reinstall"),
                      context(environment: "Production"), context(endpoint: "https://other.invalid")] {
            try check(cache.usableAuthority(context: other, now: now) == nil, "identity/install/environment binding")
        }
        for invalid in [authority(access: 0), authority(freshness: 0), authority(evaluated: 1),
                        authority(received: 1), authority(freshness: 37 * 3600), authority(status: "revoked"),
                        authority(status: "unconfirmed")] {
            let bad = PlusPurchaseCache(context: expected, authority: invalid)
            try check(bad.usableAuthority(context: expected, now: now) == nil, "expiry/rollback/denial refused")
        }
        cache.authority = authority(status: "gracePeriod")
        try check(cache.usableAuthority(context: expected, now: now) != nil, "server-confirmed grace remains bounded")
        let event = PlusRecordedTransaction(transactionID: "1", originalTransactionID: "root",
            signedContentDigest: PlusRecordedTransaction.digest("synthetic-signed-content"), recordedAt: now)
        try check(!cache.alreadyRecorded(event, context: expected, now: now), "no ACK means POST")
        cache.acknowledge(event)
        try check(cache.alreadyRecorded(event, context: expected, now: now), "exact acknowledged content skips POST")
        let changed = PlusRecordedTransaction(transactionID: "1", originalTransactionID: "root",
            signedContentDigest: PlusRecordedTransaction.digest("changed-revocation-content"), recordedAt: now)
        try check(!cache.alreadyRecorded(changed, context: expected, now: now), "same transaction changed content must POST")
        let renewed = PlusRecordedTransaction(transactionID: "2", originalTransactionID: "root",
            signedContentDigest: event.signedContentDigest, recordedAt: now)
        try check(!cache.alreadyRecorded(renewed, context: expected, now: now), "renewed transaction must POST")
        try check(!cache.alreadyRecorded(event, context: expected, now: now.addingTimeInterval(-1)), "clock before acknowledgement must POST")
        try check(!cache.alreadyRecorded(event, context: context(account: "other"), now: now), "other account must POST")
        try check(!cache.alreadyRecorded(event, context: expected, now: now.addingTimeInterval(1800)), "stale authority must POST")
        cache.authority = nil
        try check(!cache.alreadyRecorded(event, context: expected, now: now), "denial withdraws cache and POST shortcut")
        cache.version = 2
        cache.authority = authority()
        try check(cache.usableAuthority(context: expected, now: now) == nil, "unknown cache version refused")
        // Foreground with no usable Keychain value must keep an existing
        // serverConfirmed/indeterminate grant, without replacing its deadline.
        let memory = authority()
        let foreground = PlusAuthorityRestoreDecision.resolve(memoryIsUsable: memory.isUsable(at: now),
            identityChanged: false, cachedAuthority: nil)
        try check(foreground == .keepMemory, "foreground + cache absent + valid memory does not become checking")
        try check(PlusAuthorityRestoreDecision.resolve(memoryIsUsable: true, identityChanged: true,
            cachedAuthority: memory) == .identityChanged, "known identity change overrides valid memory and disk")
        try check(PlusAuthorityRestoreDecision.resolve(memoryIsUsable: memory.isUsable(at: now.addingTimeInterval(1800)),
            identityChanged: false, cachedAuthority: nil) == .checking, "expired memory cannot bridge a missing cache")
        try verifyRetainedWorksAndTrialDates()
        try verifyRenewalWords()
        try verifyOfferSteadiness()
        print("Plus foreground: valid memory survives missing cache; identity changes and expiry still withdraw access")
        print("Plus cache: expiry, clock rollback, identity, environment, reinstall and exact-ACK boundaries passed")
        print("Plus transport policy: unchanged acknowledged transaction 1 POST + 1 GET -> 0 POST + 1 GET; device latency unmeasured")
    }

    static func verifyRetainedWorksAndTrialDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d))!
        }
        let start = date(2026, 10, 25), end = date(2026, 11, 8), now = date(2026, 12, 10)
        let signedPeriods = [PlusWorkHistory.Period(originalID: 1, start: start, end: end)]
        let firstInstall = PlusWorkHistory(periods: signedPeriods)
        let reinstalled = PlusWorkHistory(periods: signedPeriods)
        for history in [firstInstall, reinstalled] {
            try check(history.contains(arrival: date(2026, 11, 1), now: now), "expired trial retains arrived October work")
            try check(!history.contains(arrival: date(2026, 10, 1), now: now), "pre-subscription work not retained")
            try check(!history.contains(arrival: date(2026, 12, 1), now: now), "post-subscription work not retained")
            try check(history.contains(arrival: start, now: now), "inclusive purchase boundary")
            try check(!history.contains(arrival: end, now: now), "exclusive expiration boundary")
            try check(!history.contains(arrival: start, now: start.addingTimeInterval(-1)), "future work excluded")
        }
        try check(!PlusWorkHistory(periods: []).contains(arrival: start, now: now), "never joined")
        for period in [PlusWorkHistory.Period(originalID: 1, start: start, end: end, purchased: false),
                       .init(originalID: 1, start: start, end: end, revoked: true),
                       .init(originalID: 1, start: start, end: end, upgraded: true)] {
            try check(!PlusWorkHistory(periods: [period]).contains(arrival: start, now: now), "family/refund/unresolved upgrade excluded")
        }
        let upgrade = date(2026, 11, 1)
        let replaced = PlusWorkHistory(periods: [
            .init(originalID: 1, start: start, end: end, upgraded: true),
            .init(originalID: 1, start: upgrade, end: now, revoked: true)])
        try check(replaced.contains(arrival: start, now: now), "valid pre-upgrade interval retained")
        try check(!replaced.contains(arrival: upgrade, now: now), "revoked successor cannot extend replaced interval")
        for (from, expected) in [(date(2026, 10, 25), date(2026, 11, 8)),
                                  (date(2026, 12, 25), date(2027, 1, 8))] {
            try check(PlusRenewalPresentation.trialEnd(from: from, component: .day, value: 7,
                count: 2, calendar: calendar) == expected, "StoreKit period count crosses month/year")
        }
        try check(PlusRenewalPresentation.trialEnd(from: date(2026, 1, 31), component: .month,
            value: 1, count: 1, calendar: calendar) == date(2026, 2, 28), "calendar month rather than fixed days")
        try check(PlusRenewalPresentation.trialEnd(from: start, component: .day,
            value: Int.max, count: 2, calendar: calendar) == nil, "overflow refused")
        let trialNow = date(2026, 11, 1)
        try check(PlusRenewalPresentation.settingsHeader(willAutoRenew: true, expiration: end,
            now: trialNow, calendar: calendar, trialEndsAt: end, displayPrice: "¥980")
            == "Plus（お試し中・11月8日から月額¥980）", "active trial header uses actual expiry/price")
        try check(PlusRenewalPresentation.settingsHeader(willAutoRenew: false, expiration: end,
            now: trialNow, calendar: calendar, trialEndsAt: end, displayPrice: "¥980")
            == "Plus（11月8日まで）", "cancelled trial keeps until header")
        try check(PlusRenewalPresentation.settingsHeader(willAutoRenew: true, expiration: now,
            now: end, calendar: calendar, trialEndsAt: end, displayPrice: "¥980")
            == "Plus（利用中）", "finished trial no longer advertised")
        print("PASS retained works: expired/trial/reinstall/refund/family/upgrade/date boundaries; trial dates and headers")
    }

    /// 11/9: a cancelled member sees the end date; a renewing one sees 利用中.
    static func verifyRenewalWords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        let now = date(2026, 11, 2)
        let end = date(2026, 11, 9)
        typealias P = PlusRenewalPresentation
        func header(_ renews: Bool?, _ expiration: Date?, at moment: Date? = nil) -> String {
            P.settingsHeader(willAutoRenew: renews, expiration: expiration, now: moment ?? now, calendar: calendar)
        }
        func line(_ renews: Bool?, _ expiration: Date?) -> String? {
            P.offerEndLine(willAutoRenew: renews, expiration: expiration, now: now, calendar: calendar)
        }
        try check(header(true, end) == "Plus（利用中）", "renewing stays 利用中")
        try check(line(true, end) == nil, "renewing keeps 「Plusを利用中です」")
        try check(header(false, end) == "Plus（11月9日まで）", "cancelled shows its end date")
        try check(line(false, end) == "11月9日まで使えます", "cancelled offer line")
        try check(header(nil, end) == "Plus（利用中）" && line(nil, end) == nil, "unknown renewal stays 利用中")
        try check(header(false, nil) == "Plus（利用中）" && line(false, nil) == nil, "unknown end stays 利用中")
        try check(header(false, end, at: end) == "Plus（利用中）", "a past end never shows as a future date")
        try check(header(false, date(2027, 1, 9)) == "Plus（2027年1月9日まで）", "another year shows the year")
        try check(line(false, date(2027, 1, 9)) == "2027年1月9日まで使えます", "another year on the offer line")
        try check(header(false, date(2026, 11, 9, 0).addingTimeInterval(60)) == "Plus（11月9日まで）",
                  "the calendar's own day, not UTC's")
        try check(P.renewingOfferTitle == "Plusを利用中です", "renewing offer title")
        let renewing = PlusRenewalSnapshot(willAutoRenew: true, expirationDate: end)
        let monthly = PlusRenewalSnapshot(willAutoRenew: false, expirationDate: end)
        let annual = PlusRenewalSnapshot(willAutoRenew: false, expirationDate: date(2027, 1, 9))
        try check(PlusRenewalSnapshot.combined([]) == nil, "no subscription, no words")
        try check(PlusRenewalSnapshot.combined([monthly, renewing]) == renewing, "any renewing one renews")
        try check(PlusRenewalSnapshot.combined([monthly, annual])?.expirationDate == date(2027, 1, 9),
                  "the latest end when none renews")
        print("Plus renewal words: 利用中 while renewing, 「11月9日まで」 once cancelled, the year only when it differs")
    }
    /// 11/10: the Plus screen reloaded over and over. One read per settled
    /// catalog, the price kept through a refresh, the unavailable line only
    /// with no price, and Settings keeps its last answer while re-checking.
    static func verifyOfferSteadiness() throws {
        typealias R = PlusOfferReloadPolicy
        try check(R.shouldReload(observedRevision: nil, currentRevision: 2, catalogLoading: false), "first settled catalog loads")
        try check(!R.shouldReload(observedRevision: 2, currentRevision: 2, catalogLoading: false), "same catalog never reloads again")
        try check(!R.shouldReload(observedRevision: 2, currentRevision: 3, catalogLoading: true), "no read while products load")
        try check(R.shouldReload(observedRevision: 2, currentRevision: 4, catalogLoading: false), "a new settled catalog reloads once")
        // Every publish of one refresh (loading, products, availability, revision) reads at most once.
        var observed: UInt64? = 2
        var reads = 0
        for (revision, loading) in [(3, true), (3, true), (4, false), (4, false), (4, false)] as [(UInt64, Bool)] {
            if R.shouldReload(observedRevision: observed, currentRevision: revision, catalogLoading: loading) {
                observed = revision; reads += 1
            }
        }
        try check(reads == 1, "one refresh, one offer read")
        try check(R.displayed(previous: "$5.99", loaded: "¥980", settled: true) == "¥980", "a new price replaces the old")
        try check(R.displayed(previous: "$5.99", loaded: nil, settled: false) == "$5.99", "an overtaken read keeps the price")
        try check(R.displayed(previous: "$5.99", loaded: nil, settled: true) == nil, "a settled empty catalog shows no price")
        try check(!R.showsUnavailable(loadFinishedWithoutOffer: true, showsPrice: true, isMember: false),
                  "never 料金を確認できません next to a price")
        try check(!R.showsUnavailable(loadFinishedWithoutOffer: false, showsPrice: false, isMember: false),
                  "not before loading finished")
        try check(!R.showsUnavailable(loadFinishedWithoutOffer: true, showsPrice: false, isMember: true), "not for a member")
        try check(R.showsUnavailable(loadFinishedWithoutOffer: true, showsPrice: false, isMember: false),
                  "finished with no product shows it")
        try check(R.unavailableMessage == "料金を確認できません。時間をおいて開き直してください。", "unavailable words")
        typealias S = PlusSettingsRowStatus
        try check(S.steady(.checking, lastAnswer: nil) == .checking, "first launch check shows 確認しています")
        try check(S.steady(.checking, lastAnswer: .notMember) == .notMember, "a re-check keeps the Plus row")
        try check(S.steady(.checking, lastAnswer: .member) == .member, "a re-check keeps the member row")
        try check(S.steady(.unknown, lastAnswer: .notMember) == .unknown, "a real answer always wins")
        try check(S.steady(.member, lastAnswer: .notMember) == .member, "a purchase shows at once")
        print("Plus screen: one offer read per settled catalog; price kept through refresh; Settings rows steady while re-checking")
    }
}
