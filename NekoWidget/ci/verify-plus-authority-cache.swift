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
        try verifyRenewalWords()
        print("Plus foreground: valid memory survives missing cache; identity changes and expiry still withdraw access")
        print("Plus cache: expiry, clock rollback, identity, environment, reinstall and exact-ACK boundaries passed")
        print("Plus transport policy: unchanged acknowledged transaction 1 POST + 1 GET -> 0 POST + 1 GET; device latency unmeasured")
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
}
