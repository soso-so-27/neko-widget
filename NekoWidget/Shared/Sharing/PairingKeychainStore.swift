import Foundation
import Security

enum PairingKeychainStore {
    /// Room credentials are deliberately stored in the containing app's
    /// default Keychain access group. An App Group is required for the
    /// non-secret handoff files, but it must not also grant the Share
    /// Extension access to the room key.
    private static let service = "jp.nekowidget.sharing.credentials.v2.host"
    private static let legacySharedService = "jp.nekowidget.sharing.credentials.v1"

    /// A Keychain read is destructive only when the item is conclusively
    /// absent. Data Protection and Keychain daemon availability failures do
    /// not prove that the credential is missing or malformed.
    enum ReadFailureReason: String, Equatable, Sendable {
        case protectedDataUnavailable = "keychain-protected-data-unavailable"
        case keychainUnavailable = "keychain-unavailable"
    }

    struct RetryableReadError: LocalizedError, Equatable, Sendable {
        let reason: ReadFailureReason

        var errorDescription: String? {
            "共有鍵を一時的に確認できませんでした。iPhoneのロックを解除したまま、もう一度お試しください。"
        }
    }

    enum ReadStatusDisposition: Equatable, Sendable {
        case success
        case missing
        case retryable(ReadFailureReason)
    }

    /// Pure status classification used by bootstrap and DEBUG runtime tests.
    /// No raw OSStatus leaves this boundary for a read availability failure.
    static func readStatusDisposition(_ status: OSStatus) -> ReadStatusDisposition {
        switch status {
        case errSecSuccess:
            return .success
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .retryable(.protectedDataUnavailable)
        default:
            // An unexpected Keychain failure is still not evidence that the
            // item is absent. Keep the credential/state and let a later read
            // retry; explicit decode and binding failures remain fail-closed.
            return .retryable(.keychainUnavailable)
        }
    }

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
        switch readStatusDisposition(status) {
        case .success:
            break
        case .missing:
            throw PairingError.malformedCredential
        case let .retryable(reason):
            throw RetryableReadError(reason: reason)
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
    /// Positive proof that readable pairing-state bytes failed the closed
    /// schema or cryptographic validation. Availability failures retain their
    /// original error and can never authorize credential deletion.
    enum LoadError: Error, Equatable, Sendable {
        case invalidState
    }

    struct OperationSnapshot: Sendable {
        let lifecycleToken: SharingLifecycleGate.Token
        let state: PairingState?
    }

    /// Atomically captures authorization epoch and the disk state. View models
    /// must never pair a freshly issued token with an older in-memory state.
    static func beginOperation() throws -> OperationSnapshot {
        try SharingLifecycleGate.withExclusive {
            let state = try loadWhileLifecycleLockedMigratingDiagnostics()
            // With multiple local windows, an unpaired active slot does not
            // prove that every credential in this app-owned Keychain service
            // is orphaned. Full service deletion is reserved for installation
            // invalidation; ordinary window cleanup deletes its exact account.
            let token = try SharingLifecycleGate.issueTokenWhileLocked()
            return OperationSnapshot(lifecycleToken: token, state: state)
        }
    }

    static func load() throws -> PairingState? {
        return try decodedStateWithNormalizedDiagnostics().state
    }

    /// Reads one catalog window without changing the process-wide active
    /// window. This is intentionally read-only: background services use it to
    /// reconcile every independently paired window while UI and Widget paths
    /// continue to resolve through the active catalog entry.
    static func load(localWindowID: String) throws -> PairingState? {
        guard let catalog = try PrivateWindowCatalogStore.load(),
              catalog.windows.contains(where: {
                  $0.localWindowID == localWindowID
              }),
              let directory = SharedContainer.windowSharingDirectoryURL(
                  localWindowID: localWindowID
              )
        else { throw PairingError.stateUnavailable }
        let url = directory.appendingPathComponent(
            "pairing-state.json",
            isDirectory: false
        )
        return try decodedStateWithNormalizedDiagnostics(at: url).state
    }

    private static func decodedStateWithNormalizedDiagnostics() throws -> (
        state: PairingState?,
        didNormalize: Bool
    ) {
        guard let url = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        return try decodedStateWithNormalizedDiagnostics(at: url)
    }

    private static func decodedStateWithNormalizedDiagnostics(
        at url: URL
    ) throws -> (state: PairingState?, didNormalize: Bool) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard SharingFileReadFailureClassifier.disposition(error) == .missing else {
                throw error
            }
            return (nil, false)
        }
        // Keep filesystem access outside the integrity catch. Data Protection,
        // App Group availability, and storage I/O do not prove corruption.
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var value = try decoder.decode(PairingState.self, from: data)
            var didNormalize = false
            if value.storageRevision == nil {
                value.storageRevision = 0
                didNormalize = true
            }
            let normalizedLastError = DiagnosticLogPrivacy.normalizedPairingLastError(
                value.lastError
            )
            if value.lastError != normalizedLastError {
                value.lastError = normalizedLastError
                didNormalize = true
            }
            let originalLocalMomentDeviceID = value.localMomentDeviceID
            value = try value.validated()
            if value.localMomentDeviceID != originalLocalMomentDeviceID {
                didNormalize = true
            }
            return (value, didNormalize)
        } catch {
            throw LoadError.invalidState
        }
    }

    /// Physical cleanup is allowed only while the caller owns the pairing
    /// lifecycle flock. Ordinary read APIs normalize in memory so they cannot
    /// overwrite a newer authorization state with a stale decoded snapshot.
    private static func loadWhileLifecycleLockedMigratingDiagnostics() throws -> PairingState? {
        let result = try decodedStateWithNormalizedDiagnostics()
        if result.didNormalize, let state = result.state {
            try saveWhileLifecycleLocked(state)
        }
        return result.state
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
                  state.phase == .creatingInvitation || state.phase == .joining
                    || state.phase == .claimingRecovery,
                  state.credentialAccount == credential.account,
                  state.installationMarker == credential.installationMarker
            else { throw PairingError.stateUnavailable }
            // Reject a stale concurrent operation before it can replace this
            // slot's catalog cleanup authority or create another secret.
            guard try loadWhileLifecycleLockedMigratingDiagnostics() == expected
            else { throw PairingError.stateUnavailable }
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let activeEntry = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  })
            else { throw PairingError.stateUnavailable }

            // A previous interrupted pre-commit may have left one exact
            // candidate account in this active slot. Remove it before
            // replacing the catalog binding so it cannot become unreachable.
            if let previousCandidate = activeEntry.credentialAccount,
               previousCandidate != credential.account {
                try PairingKeychainStore.delete(account: previousCandidate)
            }

            // Persist the non-secret exact-account cleanup authority before
            // the secret. A crash after the Keychain write but before the
            // PairingState rename can then delete only this window's orphan,
            // without issuing a broad service query that affects other rooms.
            try PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked(
                spaceID: state.spaceID,
                credentialAccount: credential.account
            )
            do {
                try PairingKeychainStore.saveWhileLifecycleLocked(credential)
                return try saveCASWhileLifecycleLocked(state, expected: expected)
            } catch {
                // A post-rename read can fail even though PairingState already
                // committed. Delete only when an authoritative reread still
                // proves the old unpaired state; otherwise retain the catalog
                // binding so bootstrap can safely reconcile it later.
                if let current = try? loadWhileLifecycleLockedMigratingDiagnostics(),
                   current == expected {
                    do {
                        try PairingKeychainStore.delete(account: credential.account)
                        try PrivateWindowCatalogStore
                            .updateActiveMetadataWhileLifecycleLocked(
                                spaceID: expected.spaceID,
                                credentialAccount: expected.credentialAccount
                            )
                    } catch {
                        // Keep the exact catalog binding if cleanup is
                        // unavailable; the next bootstrap retries it.
                    }
                }
                throw error
            }
        }
    }

    private static func saveCASWhileLifecycleLocked(
        _ state: PairingState,
        expected: PairingState
    ) throws -> PairingState {
        let current = try loadWhileLifecycleLockedMigratingDiagnostics()
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
        var state = state
        state.lastError = DiagnosticLogPrivacy.normalizedPairingLastError(
            state.lastError
        )
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

/// Describes both local projections affected by an authenticated owner-name
/// application. Callers must not infer UI refresh work from the presentation
/// record alone: a recovered/additional device may already have the current
/// presentation while its device-local window catalog still has a stale name.
struct PrivateWindowPresentationApplyResult: Equatable, Sendable {
    let presentation: PrivateWindowPresentationState
    let presentationDisplayNameChanged: Bool
    let catalogMetadataChanged: Bool

    var requiresPresentationRefresh: Bool {
        presentationDisplayNameChanged || catalogMetadataChanged
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
        // The person who creates the private window names it. An invited
        // participant receives that encrypted label but cannot race a second
        // authority into the single-window protocol.
        guard pairing.role == .inviter else {
            throw PairingError.stateUnavailable
        }
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
            guard currentBinding == expectedBinding,
                  currentPairing.role == .inviter else {
                throw PairingError.stateUnavailable
            }
            try PrivateWindowCatalogStore
                .validateDisplayNameAvailableForActiveWindowWhileLifecycleLocked(
                    displayName
                )
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

    /// Applies a creator-authored value after its AEAD context and relay
    /// metadata have been validated. Creator revisions are authoritative for
    /// invitees. On the creator device, a locally newer edit always wins and
    /// will be published by the next synchronization pass.
    @discardableResult
    static func applySynchronizedOwnerName(
        displayName rawValue: String,
        ownerRevision: Int,
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> PrivateWindowPresentationApplyResult {
        let displayName = PrivateWindowDisplayName.normalized(rawValue)
        guard ownerRevision >= 0,
              PrivateWindowDisplayName.isValid(displayName),
              !displayName.isEmpty,
              pairing.role == .inviter || pairing.role == .invitee
        else { throw PairingError.stateUnavailable }

        return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let currentPairing = try PairingStateStore.load() else {
                throw PairingError.stateUnavailable
            }
            let expectedBinding = try binding(for: pairing)
            let currentBinding = try binding(for: currentPairing)
            guard currentBinding == expectedBinding,
                  currentPairing.role == pairing.role else {
                throw PairingError.stateUnavailable
            }
            // The presentation record is the authority for the encrypted
            // owner label, while the catalog is the authority used by the
            // window picker and Widget configuration. Keep the two local
            // projections in one lifecycle boundary: a newly added iPhone
            // commonly begins with only the catalog fallback, and must not
            // keep showing that fallback after an authenticated owner name
            // has been accepted.
            func mirrorCatalog(
                _ presentation: PrivateWindowPresentationState,
                presentationDisplayNameChanged: Bool
            ) throws -> PrivateWindowPresentationApplyResult {
                guard let catalog = try PrivateWindowCatalogStore.load(),
                      let active = catalog.windows.first(where: {
                          $0.localWindowID == catalog.activeWindowID
                      })
                else { throw PairingError.stateUnavailable }
                let catalogMetadataChanged =
                    active.displayName != presentation.displayName
                    || active.spaceID != currentPairing.spaceID
                    || active.credentialAccount != currentPairing.credentialAccount
                if catalogMetadataChanged {
                    try PrivateWindowCatalogStore
                        .updateActiveMetadataWhileLifecycleLocked(
                            displayName: presentation.displayName,
                            spaceID: currentPairing.spaceID,
                            credentialAccount: currentPairing.credentialAccount,
                            now: now
                        )
                }
                return PrivateWindowPresentationApplyResult(
                    presentation: presentation,
                    presentationDisplayNameChanged: presentationDisplayNameChanged,
                    catalogMetadataChanged: catalogMetadataChanged
                )
            }
            try PrivateWindowCatalogStore
                .validateDisplayNameAvailableForActiveWindowWhileLifecycleLocked(
                    displayName
                )
            let loaded = try? loadWhileLifecycleLocked()
            let current = loaded?.pairingBindingSHA256 == currentBinding ? loaded : nil
            let displayNameBeforeApply = current?.displayName
                ?? PrivateWindowDisplayName.fallback

            if pairing.role == .inviter, let current {
                if current.storageRevision > ownerRevision {
                    return try mirrorCatalog(
                        current,
                        presentationDisplayNameChanged: false
                    )
                }
                if current.storageRevision == ownerRevision {
                    guard current.displayName == displayName else {
                        throw PairingError.stateUnavailable
                    }
                    return try mirrorCatalog(
                        current,
                        presentationDisplayNameChanged: false
                    )
                }
            }
            let localRevision: Int
            if pairing.role == .inviter {
                localRevision = ownerRevision
            } else if let current, current.displayName != displayName {
                let increment = current.storageRevision.addingReportingOverflow(1)
                guard !increment.overflow else { throw PairingError.stateUnavailable }
                localRevision = increment.partialValue
            } else if let current {
                return try mirrorCatalog(
                    current,
                    presentationDisplayNameChanged: false
                )
            } else {
                localRevision = 0
            }
            let next = try PrivateWindowPresentationState(
                storageRevision: localRevision,
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
            return try mirrorCatalog(
                committed,
                presentationDisplayNameChanged:
                    committed.displayName != displayNameBeforeApply
            )
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

/// Rollback floor and exact ambiguous-retry bytes for the encrypted creator
/// label. This file contains no plaintext name and remains independent from
/// both PairingState CAS and photo outbox/inbox state.
struct PrivateWindowNameSyncState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let legacyPendingTranscriptEncodingVersion = 1
    static let currentPendingTranscriptEncodingVersion = 2

    var schemaVersion: Int = Self.schemaVersion
    var storageRevision: Int = 0
    var pairingBindingSHA256: Data
    var acceptedOwnerRevision: Int?
    var acceptedCiphertextSHA256: Data?
    var pendingPayload: PrivateWindowNamePreparedPayload?
    var pendingClientRequestID: String?
    /// Build 33 omitted this field and used UInt32-prefixed signature/AAD
    /// transcripts. A missing value therefore means the legacy encoding and
    /// must never be retried verbatim by a corrected build.
    var pendingTranscriptEncodingVersion: Int?
    var updatedAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              storageRevision >= 0,
              pairingBindingSHA256.count == 32,
              (acceptedOwnerRevision == nil) == (acceptedCiphertextSHA256 == nil),
              acceptedOwnerRevision == nil
                || acceptedOwnerRevision.map({
                    (0...PrivateWindowNameSyncProtocol.maximumClientRevision)
                        .contains($0)
                }) == true,
              (acceptedCiphertextSHA256.map({ $0.count == 32 }) ?? true),
              (pendingPayload == nil) == (pendingClientRequestID == nil),
              pendingPayload != nil
                || pendingTranscriptEncodingVersion == nil,
              pendingPayload == nil
                || [
                    Self.legacyPendingTranscriptEncodingVersion,
                    Self.currentPendingTranscriptEncodingVersion
                ].contains(
                    pendingTranscriptEncodingVersion
                        ?? Self.legacyPendingTranscriptEncodingVersion
                ),
              pendingClientRequestID == nil
                || pendingClientRequestID.flatMap(UUID.init(uuidString:)) != nil,
              updatedAt > Date(timeIntervalSince1970: 0)
        else { throw PairingError.stateUnavailable }
        if let pendingPayload { _ = try pendingPayload.validated() }
        return self
    }
}

enum PrivateWindowNameSyncStore {
    static func load(
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> PrivateWindowNameSyncState? {
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

    static func pending(
        ownerRevision: Int,
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> (payload: PrivateWindowNamePreparedPayload, clientRequestID: UUID)? {
        guard ownerRevision >= 0 else { throw PairingError.stateUnavailable }
        guard let state = try load(pairing: pairing, validating: lifecycleToken),
              let payload = state.pendingPayload,
              state.pendingTranscriptEncodingVersion
                == PrivateWindowNameSyncState.currentPendingTranscriptEncodingVersion,
              payload.context.ownerRevision == ownerRevision,
              let requestValue = state.pendingClientRequestID,
              let requestID = UUID(uuidString: requestValue)
        else { return nil }
        try validate(payload: payload, pairing: pairing, ownerOnly: true)
        return (payload, requestID)
    }

    /// Drops only the Build 33 ambiguous-retry envelope after the caller has
    /// completed an authenticated GET and rollback-floor check. Accepted
    /// revision/hash state is retained; the corrected transcript is prepared
    /// with a new request ID by `stagePending`.
    @discardableResult
    static func discardLegacyPendingAfterAuthoritativeRead(
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Bool {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let currentPairing = try PairingStateStore.load(),
                  try binding(for: currentPairing) == binding(for: pairing)
            else { throw PairingError.stateUnavailable }
            let currentBinding = try binding(for: currentPairing)
            guard var state = try loadWhileLifecycleLocked(),
                  state.pairingBindingSHA256 == currentBinding,
                  state.pendingPayload != nil
            else { return false }
            let encodingVersion = state.pendingTranscriptEncodingVersion
                ?? PrivateWindowNameSyncState.legacyPendingTranscriptEncodingVersion
            guard encodingVersion
                    < PrivateWindowNameSyncState.currentPendingTranscriptEncodingVersion
            else { return false }
            let increment = state.storageRevision.addingReportingOverflow(1)
            guard !increment.overflow else { throw PairingError.stateUnavailable }
            state.storageRevision = increment.partialValue
            state.pendingPayload = nil
            state.pendingClientRequestID = nil
            state.pendingTranscriptEncodingVersion = nil
            state.updatedAt = now
            try writeWhileLifecycleLocked(state)
            return true
        }
    }

    static func stagePending(
        _ payload: PrivateWindowNamePreparedPayload,
        clientRequestID: UUID,
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> (payload: PrivateWindowNamePreparedPayload, clientRequestID: UUID) {
        let payload = try payload.validated()
        try validate(payload: payload, pairing: pairing, ownerOnly: true)
        return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let currentPairing = try PairingStateStore.load(),
                  try binding(for: currentPairing) == binding(for: pairing)
            else { throw PairingError.stateUnavailable }
            let currentBinding = try binding(for: currentPairing)
            var state = try loadWhileLifecycleLocked()
                ?? PrivateWindowNameSyncState(
                    pairingBindingSHA256: currentBinding,
                    updatedAt: now
                )
            guard state.pairingBindingSHA256 == currentBinding else {
                throw PairingError.stateUnavailable
            }
            if let existing = state.pendingPayload,
               state.pendingTranscriptEncodingVersion
                == PrivateWindowNameSyncState.currentPendingTranscriptEncodingVersion,
               existing.context.ownerRevision == payload.context.ownerRevision,
               let existingRequest = state.pendingClientRequestID,
               let existingRequestID = UUID(uuidString: existingRequest) {
                try validate(payload: existing, pairing: pairing, ownerOnly: true)
                return (existing, existingRequestID)
            }
            let increment = state.storageRevision.addingReportingOverflow(1)
            guard !increment.overflow else { throw PairingError.stateUnavailable }
            state.storageRevision = increment.partialValue
            state.pendingPayload = payload
            state.pendingClientRequestID = clientRequestID.uuidString.lowercased()
            state.pendingTranscriptEncodingVersion =
                PrivateWindowNameSyncState.currentPendingTranscriptEncodingVersion
            state.updatedAt = now
            try writeWhileLifecycleLocked(state)
            return (payload, clientRequestID)
        }
    }

    /// Returns true for a new value and for an exact duplicate. Exact
    /// duplicates remain applicable so a crash between floor persistence and
    /// presentation persistence repairs itself on the next GET.
    static func recordAccepted(
        _ payload: PrivateWindowNamePreparedPayload,
        pairing: PairingState,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Bool {
        let payload = try payload.validated()
        try validate(payload: payload, pairing: pairing, ownerOnly: false)
        return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let currentPairing = try PairingStateStore.load(),
                  try binding(for: currentPairing) == binding(for: pairing)
            else { throw PairingError.stateUnavailable }
            let currentBinding = try binding(for: currentPairing)
            var state = try loadWhileLifecycleLocked()
                ?? PrivateWindowNameSyncState(
                    pairingBindingSHA256: currentBinding,
                    updatedAt: now
                )
            guard state.pairingBindingSHA256 == currentBinding else {
                throw PairingError.stateUnavailable
            }
            var isExactDuplicate = false
            if let accepted = state.acceptedOwnerRevision {
                if accepted > payload.context.ownerRevision { return false }
                if accepted == payload.context.ownerRevision {
                    guard state.acceptedCiphertextSHA256 == payload.ciphertextSHA256 else {
                        throw PairingError.stateUnavailable
                    }
                    isExactDuplicate = true
                }
            }
            let clearsPending = state.pendingPayload.map {
                $0.context.ownerRevision <= payload.context.ownerRevision
            } == true
            if isExactDuplicate, !clearsPending { return true }
            let increment = state.storageRevision.addingReportingOverflow(1)
            guard !increment.overflow else { throw PairingError.stateUnavailable }
            state.storageRevision = increment.partialValue
            state.acceptedOwnerRevision = payload.context.ownerRevision
            state.acceptedCiphertextSHA256 = payload.ciphertextSHA256
            if clearsPending {
                state.pendingPayload = nil
                state.pendingClientRequestID = nil
                state.pendingTranscriptEncodingVersion = nil
            }
            state.updatedAt = now
            try writeWhileLifecycleLocked(state)
            return true
        }
    }

    private static func validate(
        payload: PrivateWindowNamePreparedPayload,
        pairing: PairingState,
        ownerOnly: Bool
    ) throws {
        guard let spaceID = pairing.spaceID,
              let ownerID = pairing.role == .inviter
                ? pairing.memberID
                : pairing.peerMemberID,
              payload.context.spaceID == spaceID,
              payload.context.ownerMemberID == ownerID,
              payload.context.keyEpoch == 1,
              (!ownerOnly || pairing.role == .inviter)
        else { throw PairingError.stateUnavailable }
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

    private static func loadWhileLifecycleLocked() throws -> PrivateWindowNameSyncState? {
        guard let url = SharedContainer.privateWindowNameSyncStateURL else {
            throw PairingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PrivateWindowNameSyncState.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        ).validated()
    }

    private static func writeWhileLifecycleLocked(_ value: PrivateWindowNameSyncState) throws {
        guard let url = SharedContainer.privateWindowNameSyncStateURL else {
            throw PairingError.stateUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(try encoder.encode(value.validated()), to: url)
    }
}
