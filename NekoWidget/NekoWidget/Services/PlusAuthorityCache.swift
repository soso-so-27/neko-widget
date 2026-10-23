import CryptoKit
import Foundation
import Security

/// A cache namespace, never a new billing identity. The installation marker
/// lives outside Keychain and is excluded from backup by its existing store.
struct PlusCacheContext: Codable, Equatable, Sendable {
    let billingAccountID: String
    let billingKeyID: String
    let installationMarker: String
    let environment: String
    let endpoint: String
}

struct PlusCachedAuthority: Codable, Equatable, Sendable {
    let status: String
    let productID: String
    let accessUntil: Date
    let authorityStaleAt: Date
    let serverEvaluatedAt: Date
    let receivedAt: Date

    func isUsable(at now: Date) -> Bool {
        let dates = [accessUntil, authorityStaleAt, serverEvaluatedAt, receivedAt, now]
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }),
              ["active", "gracePeriod"].contains(status), !productID.isEmpty,
              now >= serverEvaluatedAt, now >= receivedAt,
              accessUntil > serverEvaluatedAt, authorityStaleAt > serverEvaluatedAt,
              authorityStaleAt.timeIntervalSince(serverEvaluatedAt) <= 36 * 3600 + 300
        else { return false }
        return now < min(accessUntil, authorityStaleAt)
    }
}

/// A missing disk cache is not a server denial. Foreground reconciliation
/// keeps the existing, still-bounded decision until fresh authority arrives.
enum PlusAuthorityRestoreDecision: Equatable {
    case keepMemory
    case restore(PlusCachedAuthority)
    case checking
    case identityChanged

    static func resolve(memoryIsUsable: Bool, identityChanged: Bool,
                        cachedAuthority: PlusCachedAuthority?) -> Self {
        if identityChanged { return .identityChanged }
        if memoryIsUsable { return .keepMemory }
        if let cachedAuthority { return .restore(cachedAuthority) }
        return .checking
    }
}

struct PlusRecordedTransaction: Codable, Equatable, Sendable {
    let transactionID: String
    let originalTransactionID: String
    let signedContentDigest: Data
    let recordedAt: Date

    static func digest(_ jws: String) -> Data { Data(SHA256.hash(data: Data(jws.utf8))) }
}

struct PlusPurchaseCache: Codable, Equatable, Sendable {
    var version = 1
    let context: PlusCacheContext
    var authority: PlusCachedAuthority?
    var recorded: [PlusRecordedTransaction] = []

    func usableAuthority(context expected: PlusCacheContext, now: Date) -> PlusCachedAuthority? {
        guard version == 1, context == expected, ["Sandbox", "Production"].contains(context.environment),
              let authority, authority.isUsable(at: now) else { return nil }
        return authority
    }

    func alreadyRecorded(_ event: PlusRecordedTransaction, context expected: PlusCacheContext, now: Date) -> Bool {
        guard usableAuthority(context: expected, now: now) != nil else { return false }
        return recorded.contains {
            $0.transactionID == event.transactionID && $0.originalTransactionID == event.originalTransactionID
                && $0.signedContentDigest == event.signedContentDigest && $0.recordedAt <= now
        }
    }

    mutating func acknowledge(_ event: PlusRecordedTransaction) {
        recorded.removeAll { $0.transactionID == event.transactionID }
        recorded.append(event)
        recorded = Array(recorded.suffix(16))
    }
}

/// App-only, non-synchronizing, device-only storage. No receipt/JWS or key is
/// saved here. Read/write failure merely disables this optimization.
enum PlusAuthorityKeychainCache {
    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "jp.nekowidget.billing.authority-cache.v1.host",
         kSecAttrAccount: "primary", kSecAttrSynchronizable: kCFBooleanFalse as Any]
    }
    static func load() -> PlusPurchaseCache? {
        var request = query
        request[kSecReturnData] = true; request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= 65_536,
              let cache = try? JSONDecoder().decode(PlusPurchaseCache.self, from: data),
              cache.version == 1, cache.recorded.count <= 16 else { return nil }
        return cache
    }
    static func save(_ cache: PlusPurchaseCache) {
        guard let data = try? JSONEncoder().encode(cache), data.count <= 65_536 else { return }
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
