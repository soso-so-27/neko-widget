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
        print("Plus cache: expiry, clock rollback, identity, environment, reinstall and exact-ACK boundaries passed")
        print("Plus transport policy: unchanged acknowledged transaction 1 POST + 1 GET -> 0 POST + 1 GET; device latency unmeasured")
    }
}
