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
    case invalidInput, invalidRecord, updateRequired, temporarilyUnavailable, keychain(OSStatus), conflict, verificationDeclined
    var diagnosticCode: String {
        switch self {
        case .invalidInput: return "invalid-input"
        case .invalidRecord: return "invalid-record"
        case .updateRequired: return "update-required"
        case .temporarilyUnavailable: return "temporarily-unavailable"
        case .keychain(let status): return "keychain-status-\(status)"
        case .conflict: return "conflict"
        case .verificationDeclined: return "verification-declined"
        }
    }
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
    private let accessGroup: String?
    private let keychain: any RootSyncKeychain

    init(bundleID: String, environment: Environment, accessGroup: String? = nil,
         keychain: any RootSyncKeychain = SystemRootSyncKeychain()) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 180,
              bundleID.utf8.allSatisfy({ ($0 == 45 || $0 == 46 || (48...57).contains($0)) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw RootSyncFailure.invalidInput }
        if let accessGroup {
            let suffix = "." + bundleID
            let prefix = accessGroup.dropLast(suffix.count)
            guard accessGroup.hasSuffix(suffix), !prefix.isEmpty,
                  prefix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
            else { throw RootSyncFailure.invalidInput }
        }
        self.service = bundleID + "." + environment.rawValue + ".root-sync.v1"
        self.environment = environment
        self.accessGroup = accessGroup
        self.keychain = keychain
    }
    private func query(_ id: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: true]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
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
    /// Authentication is requested by the explicitly tapped setup action.
    /// Load the existing root after that check. A cancelled action writes nothing.
    func publishCurrentRoot(authenticate: @Sendable () async throws -> Bool,
                            load: @Sendable () throws -> Data) async throws {
        guard try await authenticate() else { throw RootSyncFailure.verificationDeclined }
        try Task.checkCancellation()
        let root = try load()
        try Task.checkCancellation()
        if case .failed(let error) = storeIfAbsent(explicitRoot: root) { throw error }
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
    /// Return the roots only after all candidate records have been validated.
    /// A locked Keychain or a disappearing record must not become an empty list.
    func availableRoots() throws -> [SyncedRoot] {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, value) = keychain.copy(q)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw failure(status) }
        guard let rows = value as? [[String: Any]] else { throw RootSyncFailure.invalidRecord }
        var roots: [SyncedRoot] = []
        var seen: Set<String> = []
        for row in rows {
            guard row[kSecAttrService as String] as? String == service,
                  row[kSecAttrSynchronizable as String] as? Bool == true,
                  let id = row[kSecAttrAccount as String] as? String, validID(id), seen.insert(id).inserted
            else { throw RootSyncFailure.invalidRecord }
            switch read(expectedRootID: id) {
            case .found(let root): roots.append(root)
            case .failed(let error): throw error
            case .missing: throw RootSyncFailure.conflict
            }
        }
        return roots.sorted { $0.id < $1.id }
    }

    func candidates() -> RootSyncCandidates {
        do {
            let ids = try availableRoots().map(\.id)
            if ids.isEmpty { return .none }
            if ids.count == 1 { return .one(ids[0]) }
            return .unresolved(ids)
        } catch let error as RootSyncFailure {
            return .failed(error)
        } catch {
            return .failed(.invalidRecord)
        }
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
