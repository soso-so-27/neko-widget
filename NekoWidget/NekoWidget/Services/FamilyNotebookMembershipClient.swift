import Foundation

/// Display state only. Server mutations independently recheck these rights.
struct FamilyPayerHandover: Decodable, Equatable, Sendable {
    enum NominationState: String, Decodable, Sendable { case confirmed, unavailable }
    let schemaVersion: Int
    let familyId: UUID
    let generation: Int64
    let payerPersonId: String?
    let nominationId: UUID?
    let nomineePersonId: String?
    let canNominate: Bool
    let canAccept: Bool
    let canCancel: Bool
    let nominationState: NominationState

    func validated(family: UUID, person: String, minimumGeneration: Int64 = 0) throws -> Self {
        guard schemaVersion == 1, familyId == family, (1...1_000_000_001).contains(generation),
              generation >= minimumGeneration, GroupCanonical.validID(person),
              payerPersonId.map(GroupCanonical.validID) ?? true,
              nomineePersonId.map(GroupCanonical.validID) ?? true else { throw FamilySharingError.serviceUnavailable }
        if nominationState == .unavailable {
            guard !canNominate, !canAccept, !canCancel else { throw FamilySharingError.serviceUnavailable }
            return self
        }
        let payer = payerPersonId == person, nominated = nomineePersonId == person
        guard (nominationId == nil) == (nomineePersonId == nil),
              nomineePersonId == nil || nomineePersonId != payerPersonId,
              canNominate == (payer && nominationId == nil),
              !canAccept || (nominated && nominationId != nil),
              canCancel == (nominationId != nil && (payer || nominated)) else { throw FamilySharingError.serviceUnavailable }
        return self
    }
}

/// Registered-identity management client. The UI service delegates here; no
/// prototype membership, purchases, identity creation or runtime enabling.
actor FamilyNotebookMembershipClient {
    enum Action: String, Codable, Sendable { case leave, claim, remove, dissolve, nominate, accept, cancel }
    private struct Intent: Codable, Equatable, Sendable {
        let familyID: UUID
        let action: Action
        let personID: String?
        let nominationID: UUID?
    }
    private struct Pending: Codable, Sendable {
        let schemaVersion: Int
        let endpoint: String
        let personID: String
        let deviceID: String
        let intent: Intent
        let operationID: UUID
        let expectedGeneration: Int64
        let path: String
        let body: Data
    }
    private struct Body: Codable {
        let operationID: String
        let expectedGeneration: Int64
        let personID: String?
        let nominationID: String?
    }
    private struct Receipt: Decodable {
        let schemaVersion: Int
        let familyID: UUID
        let operationID: UUID
        let operation: String?
        let action: String?
        let targetPersonID: String?
        let nominationID: UUID?
        let appliedGeneration: Int64
    }
    private let wire: FamilyNotebookTransport
    private let journal: any GroupSecretStore
    private let endpoint: String, personID: String, deviceID: String
    private let pendingAccount = "op:family:management:pending"
    private var working = false

    init(endpoint: URL, identity: GroupDeviceIdentity, transport: any GroupHTTPTransport, journal: any GroupSecretStore) throws {
        self.wire = try .init(endpoint: endpoint, identity: identity, transport: transport, journal: journal)
        self.journal = journal; self.endpoint = endpoint.absoluteString
        self.personID = identity.personID; self.deviceID = try identity.deviceID
    }

    func loadPayer(familyID: UUID, minimumGeneration: Int64 = 0) async throws -> FamilyNotebookPayerState {
        do {
            let data = try await wire.read(path(familyID) + "/payer")
            return try JSONDecoder().decode(FamilyNotebookPayerState.self, from: data)
                .validated(family: familyID.uuidString.lowercased(), person: personID, minimumGeneration: minimumGeneration)
        } catch { throw Self.presentation(error) }
    }

    func loadPause(familyID: UUID) async throws -> FamilySharingPause? {
        // Keep validation ahead of the lossy display conversion.
        FamilySharingPause(try await loadPayer(familyID: familyID))
    }

    func loadHandover(familyID: UUID, minimumGeneration: Int64 = 0) async throws -> FamilyPayerHandover {
        do {
            let data = try await wire.read(path(familyID) + "/payer/handover")
            return try JSONDecoder().decode(FamilyPayerHandover.self, from: data)
                .validated(family: familyID, person: personID, minimumGeneration: minimumGeneration)
        } catch { throw Self.presentation(error) }
    }

    func nominatePayer(familyID: UUID, personID: String, expectedGeneration: Int64, operationID: UUID) async throws {
        guard GroupCanonical.validID(personID), personID != self.personID else { throw FamilySharingError.notAllowed }
        try await perform(.init(familyID: familyID, action: .nominate, personID: personID, nominationID: nil), generation: expectedGeneration, operationID: operationID)
    }
    func acceptPayer(familyID: UUID, nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        try await perform(.init(familyID: familyID, action: .accept, personID: nil, nominationID: nominationID), generation: expectedGeneration, operationID: operationID)
    }
    func cancelPayerNomination(familyID: UUID, nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        try await perform(.init(familyID: familyID, action: .cancel, personID: nil, nominationID: nominationID), generation: expectedGeneration, operationID: operationID)
    }
    func removeMember(familyID: UUID, personID: String, expectedGeneration: Int64, operationID: UUID) async throws {
        guard GroupCanonical.validID(personID), personID != self.personID else { throw FamilySharingError.notAllowed }
        try await perform(.init(familyID: familyID, action: .remove, personID: personID, nominationID: nil), generation: expectedGeneration, operationID: operationID)
    }
    func claimPayer(familyID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        do {
            try await perform(.init(familyID: familyID, action: .claim, personID: nil, nominationID: nil), generation: expectedGeneration, operationID: operationID)
        } catch FamilySharingError.staleRoster {
            // A losing claim is not proof that the caller should buy Plus, nor
            // proof that someone won. Confirm the current, validated payer.
            let state = try await loadPayer(familyID: familyID, minimumGeneration: expectedGeneration)
            if let payer = state.payerPersonId, payer != personID { throw FamilySharingError.payerAlreadyChosen }
            throw FamilySharingError.staleRoster
        }
    }
    func leaveFamily(familyID: UUID, expectedGeneration: Int64, operationID: UUID,
                     notebook: FamilyNotebookStore) async throws -> FamilyExitResult {
        try await exit(.leave, familyID: familyID, generation: expectedGeneration, operationID: operationID, notebook: notebook)
    }
    func dissolveFamily(familyID: UUID, expectedGeneration: Int64, operationID: UUID,
                        notebook: FamilyNotebookStore) async throws -> FamilyExitResult {
        try await exit(.dissolve, familyID: familyID, generation: expectedGeneration, operationID: operationID, notebook: notebook)
    }
    private func exit(_ action: Action, familyID: UUID, generation: Int64, operationID: UUID,
                      notebook: FamilyNotebookStore) async throws -> FamilyExitResult {
        guard try notebook.snapshot().familyID == familyID else { throw FamilySharingError.notAllowed }
        do {
            try await perform(.init(familyID: familyID, action: action, personID: nil, nominationID: nil), generation: generation,
                              operationID: operationID, afterAcknowledgement: { _ = try notebook.endSharing() })
            return .confirmed
        } catch FamilySharingError.unknownOutcome { return .pending }
    }
    func hasPendingOperation() throws -> Bool { try pending() != nil }

    /// Resolve an interrupted UI operation before reading a new membership.
    /// A departure ACK must close its retained local outbox even after restart.
    func resumePending(notebook: FamilyNotebookStore?) async throws {
        guard let saved = try pending() else { return }
        let exits = saved.intent.action == .leave || saved.intent.action == .dissolve
        if exits {
            guard let notebook, try notebook.snapshot().familyID == saved.intent.familyID else {
                throw FamilySharingError.unknownOutcome
            }
            try await perform(saved.intent, generation: saved.expectedGeneration, operationID: saved.operationID,
                              afterAcknowledgement: { _ = try notebook.endSharing() })
        } else {
            try await perform(saved.intent, generation: saved.expectedGeneration, operationID: saved.operationID)
        }
    }

    private func path(_ familyID: UUID) -> String { "/v3/family-notebooks/" + familyID.uuidString.lowercased() }
    private func path(_ intent: Intent) -> String {
        let root = path(intent.familyID)
        switch intent.action {
        case .leave: return root + "/leave"
        case .dissolve: return root + "/dissolve"
        case .remove: return root + "/members/" + (intent.personID ?? "") + "/remove"
        default: return root + "/payer/" + intent.action.rawValue
        }
    }
    private func pending() throws -> Pending? {
        guard let data = try journal.read(pendingAccount) else { return nil }
        let value = try GroupWire.decode(Pending.self, data)
        guard value.schemaVersion == 1, value.endpoint == endpoint, value.personID == personID, value.deviceID == deviceID,
              value.path == path(value.intent), (1...1_000_000_000).contains(value.expectedGeneration),
              value.body == (try makeBody(value.intent, generation: value.expectedGeneration, operationID: value.operationID)) else {
            throw FamilySharingError.unknownOutcome
        }
        return value
    }
    private func makeBody(_ intent: Intent, generation: Int64, operationID: UUID) throws -> Data {
        try GroupWire.encode(Body(operationID: operationID.uuidString.lowercased(), expectedGeneration: generation,
            personID: intent.action == .nominate ? intent.personID : nil, nominationID: intent.nominationID?.uuidString.lowercased()))
    }
    private func perform(_ intent: Intent, generation: Int64, operationID: UUID,
                         afterAcknowledgement: @Sendable () throws -> Void = {}) async throws {
        guard !working else { throw FamilySharingError.unknownOutcome }
        working = true; defer { working = false }
        guard (1...1_000_000_000).contains(generation) else { throw FamilySharingError.staleRoster }
        let operation: Pending
        do {
            if let saved = try pending() {
                guard saved.intent == intent else { throw FamilySharingError.unknownOutcome }
                operation = saved // A fresh UI UUID or generation cannot replace an unknown result.
            } else {
                operation = try .init(schemaVersion: 1, endpoint: endpoint, personID: personID, deviceID: deviceID,
                    intent: intent, operationID: operationID, expectedGeneration: generation, path: path(intent),
                    body: makeBody(intent, generation: generation, operationID: operationID))
                try journal.write(GroupWire.encode(operation), account: pendingAccount, createOnly: true)
            }
        } catch { throw Self.presentation(error) }
        do {
            _ = try await wire.mutate(operationID: operation.operationID, intent: GroupCanonical.hash(try GroupWire.encode(operation.intent)),
                                      path: operation.path, body: operation.body) { response, sent in
                guard sent == operation.body else { throw FamilyNotebookTransportError.invalidResponse }
                let receipt = try GroupWire.decode(Receipt.self, response)
                let payer = intent.action == .leave || intent.action == .claim
                guard receipt.schemaVersion == 1, receipt.familyID == intent.familyID,
                      receipt.operationID == operation.operationID, receipt.appliedGeneration == operation.expectedGeneration + 1,
                      (payer ? receipt.operation : receipt.action) == intent.action.rawValue,
                      (payer ? receipt.action : receipt.operation) == nil else { throw FamilyNotebookTransportError.invalidResponse }
                switch intent.action {
                case .nominate:
                    guard receipt.targetPersonID == intent.personID, receipt.nominationID == operation.operationID else { throw FamilyNotebookTransportError.invalidResponse }
                case .remove:
                    guard receipt.targetPersonID == intent.personID, receipt.nominationID == nil else { throw FamilyNotebookTransportError.invalidResponse }
                case .accept, .cancel:
                    guard receipt.nominationID == intent.nominationID, receipt.targetPersonID.map(GroupCanonical.validID) == true,
                          intent.action != .accept || receipt.targetPersonID == operation.personID else { throw FamilyNotebookTransportError.invalidResponse }
                case .leave, .claim, .dissolve:
                    guard receipt.targetPersonID == nil, receipt.nominationID == nil else { throw FamilyNotebookTransportError.invalidResponse }
                }
            }
        } catch {
            // Only explicit transaction rejection clears the pending UI
            // intent. Network/5xx/bad receipts/storage failures retain it.
            if Self.definitiveRejection(error) {
                do { try journal.remove(pendingAccount) } catch { throw FamilySharingError.unknownOutcome }
            }
            if error is DecodingError { throw FamilySharingError.unknownOutcome }
            throw Self.presentation(error)
        }
        do {
            try afterAcknowledgement()
            try journal.remove(pendingAccount)
        } catch { throw FamilySharingError.unknownOutcome }
    }
    private static func definitiveRejection(_ error: Error) -> Bool {
        guard let value = error as? FamilyNotebookTransportError else { return false }
        switch value {
        case .stale, .notMember: return true
        case .server(let code, let status):
            return (status == 403 && ["family_notebook_not_allowed", "plus_entitlement_required"].contains(code))
                || (status == 409 && ["family_notebook_nomination_changed", "family_notebook_claim_unavailable"].contains(code))
        default: return false
        }
    }
    static func presentation(_ error: Error) -> FamilySharingError {
        if let value = error as? FamilySharingError { return value }
        guard let value = error as? FamilyNotebookTransportError else { return .serviceUnavailable }
        switch value {
        case .authenticationRequired: return .signInExpired
        case .notMember: return .removedOrDissolved
        case .stale: return .staleRoster
        case .unavailable: return .serviceUnavailable
        case .operationInFlight, .unknownOutcome, .idempotencyConflict, .invalidResponse: return .unknownOutcome
        case .paused: return .membershipChecking
        case .server(let code, let status):
            if status == 403 && code == "plus_entitlement_required" { return .plusRequired }
            if status == 403 && code == "family_notebook_not_allowed" { return .notAllowed }
            if status == 409 && ["family_notebook_nomination_changed", "family_notebook_claim_unavailable"].contains(code) { return .staleRoster }
            if status == 429 { return .rateLimited }
            return .unknownOutcome
        }
    }
}
