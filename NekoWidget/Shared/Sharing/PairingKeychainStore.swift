import Foundation
import Security

enum PairingKeychainStore {
    private static let service = "jp.nekowidget.sharing.credentials.v1"

    static func save(
        _ credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try saveWhileLifecycleLocked(credential)
        }
    }

    static func saveWhileLifecycleLocked(_ credential: PairingCredential) throws {
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
    struct OperationSnapshot: Sendable {
        let lifecycleToken: SharingLifecycleGate.Token
        let state: PairingState?
    }

    /// Atomically captures authorization epoch and the disk state. View models
    /// must never pair a freshly issued token with an older in-memory state.
    static func beginOperation() throws -> OperationSnapshot {
        try SharingLifecycleGate.withExclusive {
            let state = try load()
            if state?.phase == .unpaired, state?.credentialAccount == nil {
                // Recover a crash/write-failure orphan before a same-process
                // retry. This cleanup is serialized with the initial atomic
                // credential+state publication below.
                try PairingKeychainStore.deleteAllSharingCredentials()
            }
            let token = try SharingLifecycleGate.issueTokenWhileLocked()
            return OperationSnapshot(lifecycleToken: token, state: state)
        }
    }

    static func load() throws -> PairingState? {
        guard let url = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var value = try AtomicJSON.read(PairingState.self, from: url).validated()
        if value.storageRevision == nil { value.storageRevision = 0 }
        return value
    }

    @discardableResult
    static func save(
        _ state: PairingState,
        expected: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> PairingState {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try saveCASWhileLifecycleLocked(state, expected: expected)
        }
    }

    /// The first credential and its non-secret account binding must become
    /// visible under one lifecycle critical section. Otherwise bootstrap can
    /// observe an unpaired state between the Keychain and state writes, delete
    /// the new credential as an orphan, and still leave the operation's epoch
    /// valid enough for its later state CAS to commit.
    static func saveInitialCredentialAndState(
        credential: PairingCredential,
        state: PairingState,
        expected: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> PairingState {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard expected.phase == .unpaired,
                  expected.credentialAccount == nil,
                  state.phase == .creatingInvitation || state.phase == .joining,
                  state.credentialAccount == credential.account,
                  state.installationMarker == credential.installationMarker
            else { throw PairingError.stateUnavailable }
            try PairingKeychainStore.saveWhileLifecycleLocked(credential)
            // Do not delete on an uncertain post-rename read failure: state may
            // already durably reference this credential. A true pre-commit
            // orphan is removed by beginOperation/bootstrap under this lock.
            return try saveCASWhileLifecycleLocked(state, expected: expected)
        }
    }

    private static func saveCASWhileLifecycleLocked(
        _ state: PairingState,
        expected: PairingState
    ) throws -> PairingState {
        let current = try load()
        guard current == expected,
              let expectedStorageRevision = expected.storageRevision,
              state.storageRevision == expectedStorageRevision
        else { throw PairingError.stateUnavailable }
        var next = state
        next.storageRevision = expectedStorageRevision + 1
        try saveWhileLifecycleLocked(next)
        guard let committed = try load(),
              committed.storageRevision == next.storageRevision
        else { throw PairingError.stateUnavailable }
        return committed
    }

    /// Installation cleanup already owns the lifecycle flock and has bumped
    /// its epoch. This bypass is deliberately unavailable to ordinary pairing
    /// operations, which must present their pre-await token and CAS revision.
    static func saveWhileLifecycleLocked(_ state: PairingState) throws {
        guard let url = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try SharingSecureFile.write(
                try encoder.encode(try state.validated()),
                to: url
            )
        } catch {
            throw PairingError.stateUnavailable
        }
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
