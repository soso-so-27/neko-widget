import Foundation
import Security

enum PairingKeychainStore {
    private static let service = "jp.nekowidget.sharing.credentials.v1"

    static func save(_ credential: PairingCredential) throws {
        let credential = try credential.validated()
        let data = try JSONEncoder().encode(credential)
        let query = itemQuery(account: credential.account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(
            query.merging(attributes) { _, new in new } as CFDictionary,
            nil
        )
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else {
            throw PairingError.keychainUnavailable(status)
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw PairingError.keychainUnavailable(updateStatus)
        }
    }

    static func load(account: String, installationMarker: String) throws -> PairingCredential {
        var query = itemQuery(account: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? PairingError.malformedCredential
                : PairingError.keychainUnavailable(status)
        }
        guard let data = result as? Data else {
            throw PairingError.malformedCredential
        }
        let credential: PairingCredential
        do {
            credential = try JSONDecoder().decode(PairingCredential.self, from: data).validated()
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.malformedCredential
        }
        guard credential.account == account,
              credential.installationMarker == installationMarker
        else {
            throw PairingError.installationChanged
        }
        return credential
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingError.keychainUnavailable(status)
        }
    }

    /// Only credentials owned by this app's sharing service and App Group are
    /// deleted. No broad Keychain query is ever issued.
    static func deleteAllSharingCredentials() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: SharedContainer.appGroupIdentifier,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingError.keychainUnavailable(status)
        }
    }

    private static func itemQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            // Apple permits an existing App Group identifier to be used as a
            // Keychain access group. This avoids a second provisioning
            // capability and gives the app and Widget extension the same key.
            kSecAttrAccessGroup: SharedContainer.appGroupIdentifier,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }
}

enum PairingStateStore {
    static func load() throws -> PairingState? {
        guard let url = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AtomicJSON.read(PairingState.self, from: url).validated()
    }

    static func save(_ state: PairingState) throws {
        guard let url = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        try AtomicJSON.write(try state.validated(), to: url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    static func delete() throws {
        guard let url = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func purgeAllSharingFiles() throws {
        guard let directory = SharedContainer.sharingCacheDirectoryURL,
              FileManager.default.fileExists(atPath: directory.path)
        else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
