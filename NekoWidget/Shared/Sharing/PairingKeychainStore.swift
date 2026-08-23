import Foundation
import Security

enum PairingKeychainStore {
    /// Room credentials are deliberately stored in the containing app's
    /// default Keychain access group. An App Group is required for the
    /// non-secret handoff files, but it must not also grant the Share
    /// Extension access to the room key.
    private static let service = "jp.nekowidget.sharing.credentials.v2.host"
    private static let legacySharedService = "jp.nekowidget.sharing.credentials.v1"

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
        // Do not leave a second copy in the former App Group-backed service.
        // We intentionally never migrate or load that copy: an existing v1
        // state is reset by PairingInstallationGuard and must pair again.
        try deleteLegacySharedCredential(account: credential.account)
        let data = try JSONEncoder().encode(credential)
        let query = itemQuery(account: credential.account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // Moment networking is host-foreground only. Keeping the room key
            // unavailable while the device is locked is stricter than the old
            // Widget-oriented AfterFirstUnlock policy.
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
        try deleteLegacySharedCredential(account: account)
    }

    /// Only credentials owned by this app's two exact sharing services are
    /// deleted. No broad Keychain query is ever issued. The legacy query is
    /// deletion-only; stale App Group credentials are never loaded or copied
    /// into the host-only service.
    static func deleteAllSharingCredentials() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingError.keychainUnavailable(status)
        }
        try deleteAllLegacySharedCredentials()
    }

    private static func itemQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }

    private static func deleteLegacySharedCredential(account: String) throws {
        var query = legacySharedQuery()
        query[kSecAttrAccount] = account
        try deleteLegacy(query)
    }

    private static func deleteAllLegacySharedCredentials() throws {
        try deleteLegacy(legacySharedQuery())
    }

    private static func legacySharedQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacySharedService,
            kSecAttrAccessGroup: SharedContainer.appGroupIdentifier,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }

    private static func deleteLegacy(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        // A profile that never granted the former group cannot see such an
        // item, which is already the desired isolation boundary. Any other
        // failure leaves lifecycle cleanup fail-closed instead of silently
        // retaining an accessible legacy room credential.
        switch status {
        case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
            return
        default:
            throw PairingError.keychainUnavailable(status)
        }
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

/// Device-local, non-secret presentation metadata for the current private
/// window. Keeping this outside PairingState means changing a label never
/// increments PairingState.storageRevision or makes a concurrent pairing
/// refresh/cancel lose its exact-state CAS.
struct PrivateWindowPresentationState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    var storageRevision: Int = 0
    var pairingBindingSHA256: Data
    var displayName: String
    var updatedAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              storageRevision >= 0,
              pairingBindingSHA256.count == 32,
              PrivateWindowDisplayName.isValid(displayName),
              updatedAt > Date(timeIntervalSince1970: 0)
        else { throw PairingError.stateUnavailable }
        return self
    }
}

enum PrivateWindowPresentationStore {
    /// Missing, stale, or malformed presentation metadata is not sharing
    /// authority. Callers may always fall back without blocking encryption or
    /// delivery; a later explicit rename replaces the cache atomically.
    static func resolvedDisplayName(
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) -> String {
        (try? load(pairing: pairing, validating: lifecycleToken))?.displayName
            ?? PrivateWindowDisplayName.fallback
    }

    static func load(
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> PrivateWindowPresentationState? {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let currentPairing = try PairingStateStore.load(),
                  try binding(for: currentPairing) == binding(for: pairing)
            else { throw PairingError.stateUnavailable }
            guard let value = try loadWhileLifecycleLocked() else { return nil }
            guard value.pairingBindingSHA256 == (try binding(for: currentPairing))
            else { return nil }
            return value
        }
    }

    @discardableResult
    static func save(
        displayName rawValue: String,
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> PrivateWindowPresentationState {
        let normalized = PrivateWindowDisplayName.normalized(rawValue)
        let displayName = normalized.isEmpty
            ? PrivateWindowDisplayName.fallback
            : normalized
        guard PrivateWindowDisplayName.isValid(displayName)
        else { throw PairingError.invalidWindowDisplayName }

        return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let currentPairing = try PairingStateStore.load() else {
                throw PairingError.stateUnavailable
            }
            let expectedBinding = try binding(for: pairing)
            let currentBinding = try binding(for: currentPairing)
            guard currentBinding == expectedBinding else {
                throw PairingError.stateUnavailable
            }
            let current = try? loadWhileLifecycleLocked()
            let revision: Int
            if let current,
               current.pairingBindingSHA256 == currentBinding {
                let increment = current.storageRevision.addingReportingOverflow(1)
                guard !increment.overflow else {
                    throw PairingError.stateUnavailable
                }
                revision = increment.partialValue
            } else {
                revision = 0
            }
            let next = try PrivateWindowPresentationState(
                storageRevision: revision,
                pairingBindingSHA256: currentBinding,
                displayName: displayName,
                updatedAt: now
            ).validated()
            try writeWhileLifecycleLocked(next)
            guard let committed = try loadWhileLifecycleLocked(),
                  committed.schemaVersion == next.schemaVersion,
                  committed.storageRevision == next.storageRevision,
                  committed.pairingBindingSHA256 == next.pairingBindingSHA256,
                  committed.displayName == next.displayName
            else { throw PairingError.stateUnavailable }
            return committed
        }
    }

    private static func binding(for pairing: PairingState) throws -> Data {
        guard let spaceID = pairing.spaceID,
              let participantID = pairing.participantID
        else { throw PairingError.stateUnavailable }
        return try MomentShareHandoffStore.makeBindingSHA256(
            installationMarker: pairing.installationMarker,
            spaceID: spaceID,
            participantID: participantID
        )
    }

    private static func loadWhileLifecycleLocked() throws
        -> PrivateWindowPresentationState? {
        guard let url = SharedContainer.privateWindowPresentationURL else {
            throw PairingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PrivateWindowPresentationState.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        ).validated()
    }

    private static func writeWhileLifecycleLocked(
        _ value: PrivateWindowPresentationState
    ) throws {
        guard let url = SharedContainer.privateWindowPresentationURL else {
            throw PairingError.stateUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(try encoder.encode(value.validated()), to: url)
    }
}
