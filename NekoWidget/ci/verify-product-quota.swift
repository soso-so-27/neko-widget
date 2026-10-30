import Foundation

enum ManagedPreservationError: Error { case invalidResponse, requestRejected, accountingUnavailable, authenticationRequired }
final class UsageTransportFixture {
    var calls: [[URLQueryItem]] = []
    let legacy: Bool
    let denied: Bool
    init(legacy: Bool = false, denied: Bool = false) { self.legacy = legacy; self.denied = denied }
    func authenticated(_ method: String, path: String, query: [URLQueryItem], maximumBytes: Int) async throws -> Data {
        precondition(method == "GET" && path == "/v1/usage" && maximumBytes == 4096)
        calls.append(query)
        if denied { throw ManagedPreservationError.authenticationRequired }
        if legacy && !query.isEmpty { throw ManagedPreservationError.requestRejected }
        let policy: [String: Any] = ["version": legacy ? 1 : 2, "byteUnit": "decimal", "recordUnit": "visible-records-v1",
            "plus": ["limitBytes": 3_000_000_000, "maximumRecords": 3000, "includesAppleFamily": legacy],
            "trial": ["limitBytes": 250_000_000, "maximumRecords": 3000, "durationDays": 14],
            "familyParticipationRequiresPersonalStoragePurchase": false]
        return try JSONSerialization.data(withJSONObject: ["version": 1, "accounting": "encrypted-records-v1",
            "storage": ["usedBytes": 10, "reservedBytes": 0, "limitBytes": 100, "availableBytes": 90, "overLimit": false],
            "records": ["saved": 1, "pending": 0, "maximumRecords": 100, "creationLimitReached": false],
            "productQuota": ["policy": policy, "configurationStatus": "valid", "accountingStatus": "not_available", "enforcementStatus": "not_enabled"]])
    }
    func decode<T: Decodable>(_ data: Data) throws -> T { try JSONDecoder().decode(T.self, from: data) }
}
@main enum ProductQuotaVerifier {
    static func main() async throws {
        try testManagedPreservationUsageBoundary()
        let current = UsageTransportFixture()
        let fresh = try await current.usage()
        precondition(fresh.productQuota?.policy?.plus.includesAppleFamily == false)
        precondition(current.calls.count == 1 && current.calls[0].first?.value == "2")
        let old = UsageTransportFixture(legacy: true)
        let fallback = try await old.usage()
        precondition(fallback.productQuota == nil && fallback.records.saved == 1 && fallback.storage.usedBytes == 10)
        precondition(old.calls.count == 2 && old.calls[1].isEmpty)
        let denied = UsageTransportFixture(denied: true)
        var rejected = false
        do { _ = try await denied.usage() } catch ManagedPreservationError.authenticationRequired { rejected = true }
        precondition(rejected && denied.calls.count == 1)
        print("PASS product quota: family sharing OFF, v2, legacy usage fallback and no auth retry")
    }
}
