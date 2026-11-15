#if DEBUG || INTERNAL_PRESENTATION
import Foundation
import CryptoKit
import Security

// P2 only. Deliberately absent from the ordinary production compilation.
// No default identity, automatic key generation, migration or recovery issuance.
protocol RootSyncKeychain: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
struct SystemRootSyncKeychain: RootSyncKeychain {
    func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct SyncedRoot: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "SyncedRoot(redacted)" }
    var debugDescription: String { description }
    let privateKey: Data
    var id: String {
        // Construction is validated by the store before this value is returned.
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else { return "" }
        return SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }
}
enum RootSyncFailure: Error, Equatable, Sendable {
    case invalidInput, invalidRecord, updateRequired, temporarilyUnavailable, keychain(OSStatus), conflict
}
enum RootSyncRead: Sendable, Equatable {
    case found(SyncedRoot), missing, failed(RootSyncFailure)
}
enum RootSyncWrite: Sendable, Equatable { case created, existing, failed(RootSyncFailure) }
enum RootSyncRemoval: Sendable, Equatable { case removedLocally, alreadyMissing, failed(RootSyncFailure) }
enum RootSyncCandidates: Sendable, Equatable {
    case none, one(String), unresolved([String]), failed(RootSyncFailure)
}

/// The actor serializes blocking Security calls away from the MainActor.
/// A successful local operation makes no claim about remote arrival or authority.
actor RootSyncStore {
    enum Environment: String, Codable, Sendable { case production, staging, synthetic }
    private struct Record: Codable {
        let version: Int
        let environment: Environment
        let root: Data
    }
    private let service: String
    private let environment: Environment
    private let keychain: any RootSyncKeychain

    init(bundleID: String, environment: Environment, keychain: any RootSyncKeychain = SystemRootSyncKeychain()) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 180,
              bundleID.utf8.allSatisfy({ ($0 == 45 || $0 == 46 || (48...57).contains($0)) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw RootSyncFailure.invalidInput }
        self.service = bundleID + "." + environment.rawValue + ".root-sync.v1"
        self.environment = environment
        self.keychain = keychain
    }
    private func query(_ id: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: true]
        if let id { q[kSecAttrAccount as String] = id }
        return q
    }
    private func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func failure(_ status: OSStatus) -> RootSyncFailure {
        if status == errSecInteractionNotAllowed || status == errSecNotAvailable { return .temporarilyUnavailable }
        return .keychain(status)
    }
    private func decode(_ value: Any?, id: String) -> RootSyncRead {
        guard let data = value as? Data, data.count <= 1024,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == Set(["version", "environment", "root"]),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return .failed(.invalidRecord) }
        guard record.version > 0 else { return .failed(.invalidRecord) }
        guard record.version == 1 else { return .failed(.updateRequired) }
        guard record.environment == environment, record.root.count == 32,
              (try? Curve25519.Signing.PrivateKey(rawRepresentation: record.root)) != nil
        else { return .failed(.invalidRecord) }
        let root = SyncedRoot(privateKey: record.root)
        guard root.id == id else { return .failed(.invalidRecord) }
        return .found(root)
    }
    func read(expectedRootID id: String) -> RootSyncRead {
        guard validID(id) else { return .failed(.invalidInput) }
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = keychain.copy(q)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failed(failure(status)) }
        return decode(value, id: id)
    }
    func storeIfAbsent(explicitRoot bytes: Data) -> RootSyncWrite {
        guard bytes.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
            return .failed(.invalidInput)
        }
        let root = SyncedRoot(privateKey: key.rawRepresentation)
        guard let data = try? JSONEncoder().encode(Record(version: 1, environment: environment, root: bytes)) else {
            return .failed(.invalidInput)
        }
        var q = query(root.id)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        q[kSecValueData as String] = data
        let status = keychain.add(q)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return .failed(failure(status)) }
        switch read(expectedRootID: root.id) {
        case .found(let existing) where existing == root: return status == errSecSuccess ? .created : .existing
        case .failed(let error): return .failed(error)
        default: return .failed(.conflict)
        }
    }
    func candidates() -> RootSyncCandidates {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, value) = keychain.copy(q)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess else { return .failed(failure(status)) }
        guard let rows = value as? [[String: Any]] else { return .failed(.invalidRecord) }
        var ids: [String] = []
        for row in rows {
            guard row[kSecAttrService as String] as? String == service,
                  row[kSecAttrSynchronizable as String] as? Bool == true,
                  let id = row[kSecAttrAccount as String] as? String, validID(id), !ids.contains(id)
            else { return .failed(.invalidRecord) }
            // Validate each candidate; never choose by creation time or enumeration order.
            switch read(expectedRootID: id) {
            case .found: ids.append(id)
            case .failed(let error): return .failed(error)
            case .missing: return .failed(.conflict)
            }
        }
        ids.sort()
        if ids.isEmpty { return .none }
        if ids.count == 1 { return .one(ids[0]) }
        return .unresolved(ids)
    }
    func removeExact(expectedRootID id: String) -> RootSyncRemoval {
        guard validID(id) else { return .failed(.invalidInput) }
        let status = keychain.delete(query(id))
        if status == errSecItemNotFound { return .alreadyMissing }
        guard status == errSecSuccess else { return .failed(failure(status)) }
        return .removedLocally
    }
}
#endif
