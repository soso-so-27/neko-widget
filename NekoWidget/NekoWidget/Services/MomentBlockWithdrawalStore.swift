import Foundation
import Security

struct MomentBlockWithdrawalAuthorization: Sendable {
    let id: String
    let tokenSHA256: String
}

/// This host-only capability can withdraw one block; it cannot sign a photo
/// request or decrypt the old window. It deliberately survives window cleanup.
enum MomentBlockWithdrawalStore {
    enum Phase: String, Codable, Sendable {
        case pending, blocked, withdrawn
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let windowDisplayName: String
        let createdAt: Date
        let phase: Phase
    }

    struct Record: Codable, Equatable, Sendable {
        let id: String
        let installationMarker: String
        let spaceID: String
        let blockerParticipantID: String
        let blockedParticipantID: String
        let localWindowID: String
        let windowDisplayName: String
        let createdAt: Date
        let blockRequestID: UUID
        let withdrawalRequestID: UUID
        var phase: Phase
        var token: Data?

        var entry: Entry {
            Entry(id: id, windowDisplayName: windowDisplayName,
                  createdAt: createdAt, phase: phase)
        }

        func validated() throws -> Self {
            guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                  UUID(uuidString: installationMarker) != nil,
                  UUID(uuidString: localWindowID) != nil,
                  PairingValidation.isOpaqueIdentifier(spaceID),
                  PairingValidation.isOpaqueIdentifier(blockerParticipantID),
                  PairingValidation.isOpaqueIdentifier(blockedParticipantID),
                  blockerParticipantID != blockedParticipantID,
                  PrivateWindowDisplayName.isValid(windowDisplayName),
                  createdAt > Date(timeIntervalSince1970: 0),
                  (phase == .withdrawn ? token == nil : token?.count == 32)
            else { throw PairingError.stateUnavailable }
            return self
        }

        func authorization() throws -> MomentBlockWithdrawalAuthorization {
            _ = try validated()
            guard phase != .withdrawn, let token else {
                throw PairingError.stateUnavailable
            }
            return MomentBlockWithdrawalAuthorization(
                id: id,
                tokenSHA256: PairingCrypto.sha256(token)
                    .map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    private struct Document: Codable {
        var schemaVersion = 1
        let installationMarker: String
        var records: [Record]
    }

    private static let service = "jp.nekowidget.sharing.block-withdrawals.v1.host"
    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "records", kSecAttrSynchronizable: kCFBooleanFalse as Any]
    }

    /// Persist the secret and both request IDs BEFORE sending the block. A
    /// timeout or app restart must reuse the same authority, never replace it.
    static func prepare(
        participantID: String,
        pairingState: PairingState,
        windowDisplayName: String,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Record {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard try PairingStateStore.load() == pairingState,
                  pairingState.phase == .paired,
                  let spaceID = pairingState.spaceID,
                  let blockerID = pairingState.participantID,
                  let catalog = try PrivateWindowCatalogStore.load(),
                  let window = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  }),
                  window.spaceID == spaceID,
                  window.credentialAccount == pairingState.credentialAccount
            else { throw PairingError.stateUnavailable }
            var document = try readWhileLocked(marker: pairingState.installationMarker)
            if let existing = document.records.first(where: {
                $0.spaceID == spaceID && $0.blockerParticipantID == blockerID
                    && $0.blockedParticipantID == participantID && $0.phase != .withdrawn
            }) {
                return existing
            }
            let record = try Record(
                id: UUID().uuidString.lowercased(),
                installationMarker: pairingState.installationMarker,
                spaceID: spaceID, blockerParticipantID: blockerID,
                blockedParticipantID: participantID, localWindowID: window.localWindowID,
                windowDisplayName: windowDisplayName, createdAt: .now,
                blockRequestID: UUID(), withdrawalRequestID: UUID(), phase: .pending,
                token: PairingCrypto.randomData(count: 32)
            ).validated()
            document.records.append(record)
            try writeWhileLocked(document)
            return record
        }
    }

    static func entries(installationMarker: String) throws -> [Entry] {
        try SharingLifecycleGate.withExclusive {
            try requireCurrentInstallation(installationMarker)
            return try readWhileLocked(marker: installationMarker).records
                .sorted { $0.createdAt > $1.createdAt }.map(\.entry)
        }
    }

    static func record(id: String, installationMarker: String) throws -> Record {
        try SharingLifecycleGate.withExclusive {
            try recordWhileLifecycleLocked(id: id, installationMarker: installationMarker)
        }
    }

    static func recordWhileLifecycleLocked(id: String, installationMarker: String) throws -> Record {
        try requireCurrentInstallation(installationMarker)
        guard let record = try readWhileLocked(marker: installationMarker)
            .records.first(where: { $0.id == id })
        else { throw PairingError.stateUnavailable }
        return record
    }

    static func markBlocked(_ record: Record) throws {
        try SharingLifecycleGate.withExclusive {
            try transitionWhileLocked(record, to: .blocked)
        }
    }

    static func markWithdrawnWhileLifecycleLocked(_ record: Record) throws {
        try transitionWhileLocked(record, to: .withdrawn)
    }

    private static func transitionWhileLocked(_ expected: Record, to phase: Phase) throws {
        try requireCurrentInstallation(expected.installationMarker)
        var document = try readWhileLocked(marker: expected.installationMarker)
        guard let index = document.records.firstIndex(where: { $0.id == expected.id })
        else { throw PairingError.stateUnavailable }
        let current = document.records[index]
        if current.phase == phase { return }
        guard current == expected, current.phase != .withdrawn,
              phase == .blocked || phase == .withdrawn
        else { throw PairingError.stateUnavailable }
        document.records[index].phase = phase
        if phase == .withdrawn { document.records[index].token = nil }
        try writeWhileLocked(document)
    }

    /// Called only as part of installation-wide cleanup, not block/unpair.
    static func deleteAllWhileLifecycleLocked() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingError.keychainUnavailable(status)
        }
    }

    private static func requireCurrentInstallation(_ marker: String) throws {
        guard try PairingStateStore.load()?.installationMarker == marker else {
            throw PairingError.installationChanged
        }
    }

    private static func readWhileLocked(marker: String) throws -> Document {
        var request = query
        request[kSecReturnData] = kCFBooleanTrue
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch PairingKeychainStore.readStatusDisposition(status) {
        case .missing: return Document(installationMarker: marker, records: [])
        case let .retryable(reason):
            throw PairingKeychainStore.RetryableReadError(reason: reason)
        case .success: break
        }
        guard let data = result as? Data else { throw PairingError.stateUnavailable }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1,
              UUID(uuidString: document.installationMarker) != nil,
              Set(document.records.map(\.id)).count == document.records.count
        else { throw PairingError.stateUnavailable }
        // Keychain survives reinstallation. Never expose or reuse the old
        // installation's names or capabilities, even if its item is readable.
        guard document.installationMarker == marker else {
            return Document(installationMarker: marker, records: [])
        }
        for record in document.records {
            guard record.installationMarker == marker else {
                throw PairingError.stateUnavailable
            }
            _ = try record.validated()
        }
        return document
    }

    private static func writeWhileLocked(_ document: Document) throws {
        let data = try JSONEncoder().encode(document)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(
            query.merging(attributes) { _, new in new } as CFDictionary, nil
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
}
