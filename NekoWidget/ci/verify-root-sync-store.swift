import Foundation
import CryptoKit
import Security

private enum Failure: Error { case check(String) }
private func check(_ result: Bool, _ name: String) throws {
    if !result { throw Failure.check(name) }
}
// Synthetic adapter only. Mutations happen between awaited actor operations.
private final class FakeKeychain: RootSyncKeychain, @unchecked Sendable {
    var items: [String: [String: Any]] = [:]
    var queries: [[String: Any]] = []
    var reads: OSStatus?
    var adds: OSStatus?
    var deletes: OSStatus?
    var addCount = 0
    var deleteCount = 0
    var injectedRows: [[String: Any]]?
    func key(_ q: [String: Any]) -> String {
        (q[kSecAttrService as String] as! String) + "|" + (q[kSecAttrAccount as String] as! String)
    }
    func copy(_ q: [String: Any]) -> (OSStatus, Any?) {
        queries.append(q)
        if let reads { return (reads, nil) }
        if q[kSecReturnAttributes as String] as? Bool == true {
            if let injectedRows { return (errSecSuccess, injectedRows) }
            let rows = items.values.filter { $0[kSecAttrService as String] as? String == q[kSecAttrService as String] as? String }
            return rows.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, Array(rows))
        }
        guard let row = items[key(q)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, row[kSecValueData as String])
    }
    func add(_ q: [String: Any]) -> OSStatus {
        queries.append(q); addCount += 1
        if let adds { return adds }
        guard items[key(q)] == nil else { return errSecDuplicateItem }
        items[key(q)] = q
        return errSecSuccess
    }
    func delete(_ q: [String: Any]) -> OSStatus {
        queries.append(q); deleteCount += 1
        if let deletes { return deletes }
        return items.removeValue(forKey: key(q)) == nil ? errSecItemNotFound : errSecSuccess
    }
}

@main struct RootSyncChecks {
    static func main() async throws {
        let fake = FakeKeychain()
        let store = try RootSyncStore(bundleID: "jp.synthetic", environment: .synthetic, keychain: fake)
        let raw = Data(repeating: 7, count: 32), root = SyncedRoot(privateKey: raw)
        let other = SyncedRoot(privateKey: Data(repeating: 8, count: 32))
        try check(await store.read(expectedRootID: root.id) == .missing, "missing distinguished")
        try check(fake.addCount == 0, "read does not create")
        do {
            try await store.publishCurrentRoot(authenticate: { false }, load: { throw Failure.check("read before verifying") })
            throw Failure.check("explicit verification was bypassed")
        } catch RootSyncFailure.verificationDeclined { }
        try check(fake.addCount == 0, "declined verification writes nothing")
        try await store.publishCurrentRoot(authenticate: { true }, load: { raw })
        try check(await store.read(expectedRootID: root.id) == .found(root), "approved publish added the current root")
        try check(await store.removeExact(expectedRootID: root.id) == .removedLocally, "clear in-memory test fixture")
        fake.deleteCount = 0
        try check(await store.storeIfAbsent(explicitRoot: raw) == .created, "create")
        try check(await store.read(expectedRootID: root.id) == .found(root), "validated read")
        try check(await store.storeIfAbsent(explicitRoot: raw) == .existing, "equal duplicate")
        try check(await store.candidates() == .one(root.id), "one candidate")
        let itemKey = "jp.synthetic.synthetic.root-sync.v1|" + root.id
        let original = fake.items[itemKey]!
        let originalBytes = original[kSecValueData as String] as! Data
        let fields = try JSONSerialization.jsonObject(with: originalBytes) as! [String: Any]
        for (name, replacement, expected) in [
            ("version", 2 as Any, RootSyncFailure.updateRequired),
            ("version", 0 as Any, .invalidRecord),
            ("environment", "production" as Any, .invalidRecord),
            ("root", other.privateKey.base64EncodedString() as Any, .invalidRecord),
            ("extra", "not allowed" as Any, .invalidRecord)
        ] {
            var changed = fields; changed[name] = replacement
            fake.items[itemKey]![kSecValueData as String] = try JSONSerialization.data(withJSONObject: changed)
            try check(await store.read(expectedRootID: root.id) == .failed(expected), "invalid record: " + name)
            try check(await store.storeIfAbsent(explicitRoot: raw) == .failed(expected), "duplicate never overwrites: " + name)
            try check(fake.deleteCount == 0, "failure never deletes")
        }
        fake.items[itemKey] = original
        fake.reads = errSecInteractionNotAllowed
        try check(await store.read(expectedRootID: root.id) == .failed(.temporarilyUnavailable), "locked is not missing")
        try check(await store.candidates() == .failed(.temporarilyUnavailable), "locked enumeration")
        fake.reads = errSecAuthFailed
        try check(await store.read(expectedRootID: root.id) == .failed(.keychain(errSecAuthFailed)), "error is not missing")
        fake.reads = nil
        fake.adds = errSecNotAvailable
        try check(await store.storeIfAbsent(explicitRoot: other.privateKey) == .failed(.temporarilyUnavailable), "add failure")
        fake.adds = nil
        try check(await store.storeIfAbsent(explicitRoot: other.privateKey) == .created, "second root retained")
        try check(await store.candidates() == .unresolved([root.id, other.id].sorted()), "no automatic choice")
        try check(try await store.availableRoots().map(\.id) == [root.id, other.id].sorted(), "read both verified root keys")
        fake.reads = errSecInteractionNotAllowed
        do {
            _ = try await store.availableRoots()
            throw Failure.check("locked enumeration became an empty list")
        } catch RootSyncFailure.temporarilyUnavailable { }
        fake.reads = nil
        let staging = try RootSyncStore(bundleID: "jp.synthetic", environment: .staging, keychain: fake)
        try check(await staging.candidates() == .none, "environment scoped")
        try check(try await staging.availableRoots().isEmpty, "empty production input is not a keychain failure")
        try check(await staging.read(expectedRootID: root.id) == .missing, "no cross-environment read")
        fake.injectedRows = [[kSecAttrAccount as String: root.id, kSecAttrService as String: "other", kSecAttrSynchronizable as String: true]]
        try check(await store.candidates() == .failed(.invalidRecord), "foreign enumeration rejected")
        fake.injectedRows = nil
        let calls = fake.queries.count
        try check(await store.read(expectedRootID: "*") == .failed(.invalidInput), "bad ID read")
        try check(await store.removeExact(expectedRootID: "") == .failed(.invalidInput), "bad ID deletion")
        try check(await store.storeIfAbsent(explicitRoot: Data()) == .failed(.invalidInput), "bad root")
        try check(fake.queries.count == calls, "invalid input never reaches keychain")
        fake.deletes = errSecAuthFailed
        try check(await store.removeExact(expectedRootID: root.id) == .failed(.keychain(errSecAuthFailed)), "delete refusal")
        fake.deletes = nil
        try check(await store.removeExact(expectedRootID: root.id) == .removedLocally, "exact deletion")
        try check(await store.removeExact(expectedRootID: root.id) == .alreadyMissing, "idempotent local removal")
        try check(await store.read(expectedRootID: other.id) == .found(other), "other root retained")
        for q in fake.queries {
            try check(q[kSecAttrSynchronizable as String] as? Bool == true, "synchronizable always exact true")
            try check(q[kSecAttrAccessGroup as String] == nil, "no extension access group")
            try check(q[kSecClass as String] as? String == kSecClassGenericPassword as String, "class restricted")
            try check((q[kSecAttrService as String] as? String)?.hasPrefix("jp.synthetic.") == true, "namespace restricted")
            if q[kSecValueData as String] != nil {
                try check(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String, "unlocked access only")
            }
        }
        let privateGroup = "EXAMPLETEAM.jp.synthetic"
        let scopedFake = FakeKeychain()
        let privateStore = try RootSyncStore(bundleID: "jp.synthetic", environment: .production,
                                             accessGroup: privateGroup, keychain: scopedFake)
        try check(await privateStore.storeIfAbsent(explicitRoot: raw) == .created, "private production write")
        try check(try await privateStore.availableRoots() == [root], "private production read")
        try check(scopedFake.queries.allSatisfy { $0[kSecAttrAccessGroup as String] as? String == privateGroup }, "only the private app group is queried")
        try check(scopedFake.items.keys.allSatisfy { $0.hasPrefix("jp.synthetic.production.root-sync.v1|") }, "stable production service name")
        do {
            _ = try RootSyncStore(bundleID: "jp.synthetic", environment: .production,
                                  accessGroup: privateGroup + ".group-share", keychain: scopedFake)
            throw Failure.check("shared access group accepted")
        } catch RootSyncFailure.invalidInput { }
        print("PASS: P2 synthetic adapter, validation, no overwrite, scoped reads/removal, unavailable != missing")
    }
}
