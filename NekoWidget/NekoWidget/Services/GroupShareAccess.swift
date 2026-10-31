import Foundation
import Security

/// Non-secret installation identifier. Keychain remnants alone are not enough
/// to enable a new installation. Both files are excluded from device backups.
#if os(iOS)
enum GroupShareInstallation {
    private static var sharedFile: URL? {
        SharedContainer.containerURL?.appendingPathComponent("group-share-installation-v1")
    }
    private static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count == 36, let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil else {
            throw GroupClientError.authenticationRequired
        }
        return value
    }
    private static func write(_ value: String, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: destination, options: [.atomic, .completeFileProtection])
        var url = destination, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func prepareInHost() throws -> String {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let sharedFile else { throw GroupClientError.authenticationRequired }
        let privateFile = root.appendingPathComponent("group-share-installation-v1")
        let value = try read(privateFile) ?? UUID().uuidString.lowercased()
        if try read(privateFile) == nil { try write(value, to: privateFile) }
        if try read(sharedFile) != value { try write(value, to: sharedFile) }
        return value
    }
    static func existingForShare() throws -> String? {
        guard let sharedFile else { throw GroupClientError.authenticationRequired }
        return try read(sharedFile)
    }
}
#endif

/// A separate Keychain group belongs to the app and its Share Extension only.
/// It must never be added to the Widget or used for billing/personal storage.
/// The original app-private Keychain remains authoritative and is not migrated.
enum GroupShareAccess {
    static var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GroupShareKeychainGroup") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    static func redacted(_ bytes: Data, account: String) throws -> Data? {
        if account == "identity" {
            let identity = try GroupWire.decode(GroupDeviceIdentity.self, bytes)
            guard identity.registered else { return nil }
            // Owner root authority is unnecessary for a photo. Keep it app-private.
            return try GroupWire.encode(GroupDeviceIdentity(personPrivateKey: nil,
                personPublicKey: identity.personPublicKey, signingPrivateKey: identity.signingPrivateKey,
                agreementPrivateKey: identity.agreementPrivateKey,
                windowCertificates: [:], registered: true))
        }
        guard account.hasPrefix("window:") else { return nil }
        let window = try GroupWire.decode(GroupLocalWindow.self, bytes)
        guard account == "window:" + window.anchor.windowID,
              !window.left, window.closed != true, try window.verified() != nil else { return nil }
        return bytes
    }
}

/// Uses Keychain, not App Group files/defaults, for all credential bytes.
final class GroupShareKeychain: GroupSecretStore, Sendable {
    private let service: String
    private let accessGroup: String
    init(namespace: String, accessGroup: String) {
        service = namespace + ".share-snapshot.v1"
        self.accessGroup = accessGroup
    }
    private func query(_ account: String? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false]
        if let account { value[kSecAttrAccount as String] = account }
        return value
    }
    func read(_ account: String) throws -> Data? {
        var value = query(account)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GroupClientError.authenticationRequired }
        return data
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        var value = query(account)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        value[kSecValueData as String] = data
        let status = SecItemAdd(value as CFDictionary, nil)
        if status == errSecDuplicateItem, !createOnly {
            guard SecItemUpdate(query(account) as CFDictionary,
                                [kSecValueData as String: data] as CFDictionary) == errSecSuccess
            else { throw GroupClientError.authenticationRequired }
        } else if status != errSecSuccess { throw GroupClientError.authenticationRequired }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GroupClientError.authenticationRequired }
    }
    func accounts(prefix: String) throws -> [String] {
        var value = query()
        value[kSecReturnAttributes as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw GroupClientError.authenticationRequired }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }
}

/// Publish only records already read/written by the host's ordinary client.
/// A publication failure never changes the host record or its completed action.
final class GroupSharePublishingStore: GroupSecretStore, Sendable {
    let original: any GroupSecretStore
    let snapshot: any GroupSecretStore
    init(original: any GroupSecretStore, snapshot: any GroupSecretStore) {
        self.original = original
        self.snapshot = snapshot
    }
    private func publish(_ data: Data?, account: String) {
        guard account == "identity" || account.hasPrefix("window:") else { return }
        do {
            if account == "identity" {
                if data == nil {
                    try snapshot.write(Data([1]), account: "host-confirmed-empty", createOnly: false)
                } else {
                    try snapshot.remove("host-confirmed-empty")
                }
            }
            if let data, let permitted = try GroupShareAccess.redacted(data, account: account) {
                try snapshot.write(permitted, account: account, createOnly: false)
            } else {
                try snapshot.remove(account)
            }
        } catch {
            // Do not silently keep an older grant if this update was rejected.
            try? snapshot.remove(account)
            try? snapshot.remove("host-confirmed-empty")
        }
    }
    func read(_ account: String) throws -> Data? {
        let data = try original.read(account)
        publish(data, account: account)
        return data
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        try original.write(data, account: account, createOnly: createOnly)
        publish(data, account: account)
    }
    func remove(_ account: String) throws {
        try original.remove(account)
        publish(nil, account: account)
    }
    func accounts(prefix: String) throws -> [String] { try original.accounts(prefix: prefix) }
}

/// Share-side checkpoints never overwrite the host's private records. Every
/// access still requires the host snapshot to exist; an older local checkpoint
/// cannot restore a removed/closed membership. The relay checks current access
/// again on list, reservation, upload and commit.
final class GroupShareReadingStore: GroupSecretStore, Sendable {
    let snapshot: any GroupSecretStore
    let checkpoints: any GroupSecretStore
    init(snapshot: any GroupSecretStore, checkpoints: any GroupSecretStore) {
        self.snapshot = snapshot
        self.checkpoints = checkpoints
    }
    func read(_ account: String) throws -> Data? {
        guard account == "identity" || account.hasPrefix("window:"),
              let host = try snapshot.read(account) else { throw GroupClientError.authenticationRequired }
        if account == "identity" {
            let identity = try GroupWire.decode(GroupDeviceIdentity.self, host)
            guard identity.registered, identity.personPrivateKey == nil else { throw GroupClientError.authenticationRequired }
            return host
        }
        let window = try GroupWire.decode(GroupLocalWindow.self, host)
        guard !window.left, window.closed != true, try window.verified() != nil else { throw GroupClientError.notMember }
        if let saved = try checkpoints.read(account) {
            var newer = try GroupWire.decode(GroupLocalWindow.self, saved)
            guard newer.anchor == window.anchor else { throw GroupClientError.invalidResponse }
            newer.minimumAdmissionRevision = max(newer.minimumAdmissionRevision, window.minimumAdmissionRevision)
            if newer.pinnedRevision == window.pinnedRevision, newer.pinnedHash != window.pinnedHash {
                throw GroupClientError.invalidResponse
            }
            if newer.pinnedRevision > window.pinnedRevision { return try GroupWire.encode(newer) }
            if newer.pinnedRevision == window.pinnedRevision,
               let localName = newer.nameCheckpoint,
               localName.rosterRevision == newer.pinnedRevision {
                if let hostName = window.nameCheckpoint,
                   hostName.nameRevision == localName.nameRevision,
                   hostName.ciphertextHash != localName.ciphertextHash { throw GroupClientError.invalidResponse }
                if localName.nameRevision >= (window.nameCheckpoint?.nameRevision ?? 0) { return try GroupWire.encode(newer) }
            }
        }
        return host
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        guard account.hasPrefix("window:"), let current = try read(account) else { throw GroupClientError.authenticationRequired }
        let previous = try GroupWire.decode(GroupLocalWindow.self, current)
        let next = try GroupWire.decode(GroupLocalWindow.self, data)
        guard next.anchor == previous.anchor, next.pinnedRevision >= previous.pinnedRevision,
              next.pinnedRevision != previous.pinnedRevision || next.pinnedHash == previous.pinnedHash,
              !next.left, next.closed != true, try next.verified() != nil else { throw GroupClientError.invalidResponse }
        try checkpoints.write(data, account: account, createOnly: false)
    }
    func remove(_ account: String) throws { throw GroupClientError.authenticationRequired }
    func accounts(prefix: String) throws -> [String] { try snapshot.accounts(prefix: prefix) }
}
