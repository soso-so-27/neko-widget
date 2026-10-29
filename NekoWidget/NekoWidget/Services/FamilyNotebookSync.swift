import Foundation

enum FamilyNotebookSyncError: Error, Equatable {
    case missingKey(epoch: Int), missingRoster(epoch: Int)
}

struct FamilyNotebookSyncResult: Equatable, Sendable {
    let downloaded: Int
    let uploaded: Int
    let pending: Int
    let moreHistory: Bool
    let paused: Bool
    let needsRotation: Bool
}

/// Authenticated, encrypted transport over the retained local notebook. Trust
/// pins and verified epoch keys are supplied by admission/key delivery, never
/// inferred from relay JSON. No personal notebook is automatically imported.
actor FamilyNotebookSync {
    private let familyID: UUID
    private let identity: GroupDeviceIdentity
    private let store: FamilyNotebookStore
    private let network: FamilyNotebookTransport
    private let journal: any GroupSecretStore
    private let endpointID: String
    private var isRunning = false

    private struct Cursor: Codable {
        let schemaVersion: Int
        let familyID: UUID
        let deviceID: String
        let endpointID: String
        let sequence: Int
        let notebookRevision: UInt64
        let notebookOperationCount: Int
    }
    private struct State: Decodable {
        let schemaVersion: Int; let familyID: UUID; let generation: Int64
        let currentEpoch: Int; let roster: SignedFamilyNotebookRoster?; let ready: Bool
    }
    private struct Page: Decodable {
        struct Entry: Decodable { let sequence: Int; let packet: EncryptedFamilyNotebookOperation }
        let schemaVersion: Int; let familyID: UUID; let generation: Int64; let currentEpoch: Int
        let nextCursor: Int; let headCursor: Int; let operations: [Entry]
    }
    private struct Upload: Encodable {
        let operationID: String; let expectedGeneration: Int64; let expectedEpoch: Int
        let payload: EncryptedFamilyNotebookOperation
    }

    init(familyID: UUID, identity: GroupDeviceIdentity, store: FamilyNotebookStore, network: FamilyNotebookTransport,
         journal: any GroupSecretStore, endpointID: String) throws {
        guard identity.registered, !endpointID.isEmpty, try store.snapshot().familyID == familyID else {
            throw FamilyNotebookTransportError.invalidResponse
        }
        self.familyID = familyID; self.identity = identity; self.store = store
        self.network = network; self.journal = journal; self.endpointID = endpointID
    }

    /// At most eight bounded pages per call. `moreHistory` schedules another
    /// pass; no head/cursor is marked complete until all preceding edits land.
    /// The caller retains trusted rosters/keys across calls and app restarts.
    func synchronize(current: VerifiedFamilyNotebookRoster, history: [Int: SignedFamilyNotebookRoster],
                     keys: [Int: Data]) async throws -> FamilyNotebookSyncResult {
        guard !isRunning else { throw FamilyNotebookTransportError.operationInFlight }
        isRunning = true; defer { isRunning = false }
        guard try !store.snapshot().sharingEnded else { throw FamilyNotebookError.sharingEnded }
        guard current.roster.familyID == familyID,
              current.roster.device(try identity.deviceID)?.person.personID == identity.personID else {
            throw FamilyNotebookCryptoError.untrusted
        }
        let path = "/v3/family-notebooks/" + familyID.uuidString.lowercased()
        let state = try GroupWire.decode(State.self, await network.read(path + "/crypto/state"))
        guard state.schemaVersion == 1, state.familyID == familyID, (1...1_000_000_000).contains(state.generation),
              state.currentEpoch == current.roster.epoch, let packet = state.roster else { throw FamilyNotebookTransportError.stale }
        _ = try FamilyNotebookRosterCrypto.restore(packet, trustedPin: current.pin)
        // PayerState deliberately uses its existing JSON field spelling and
        // validates before any pause/permission interpretation.
        let payer = try JSONDecoder().decode(FamilyNotebookPayerState.self, from: await network.read(path + "/payer"))
            .validated(family: familyID.uuidString.lowercased(), person: identity.personID, minimumGeneration: state.generation)
        guard payer.generation == state.generation else { throw FamilyNotebookTransportError.stale }
        var paused = payer.sharingStatus == .paused
        let cursorAccount = "op:fnb-cursor:" + familyID.uuidString.lowercased()
        var cursor = 0
        if let bytes = try journal.read(cursorAccount) {
            let saved = try GroupWire.decode(Cursor.self, bytes)
            guard saved.schemaVersion == 1, saved.familyID == familyID, saved.deviceID == (try identity.deviceID),
                  saved.endpointID == endpointID, (0...1_000_000_000).contains(saved.sequence), saved.notebookOperationCount >= 0 else {
                throw FamilyNotebookTransportError.invalidResponse
            }
            let local = try store.snapshot()
            // A restored/older local copy must refill history rather than use
            // a newer cursor to skip records that it does not contain yet.
            if local.revision >= saved.notebookRevision && local.operations.count >= saved.notebookOperationCount {
                cursor = saved.sequence
            }
        }
        var downloaded = 0, uploaded = 0, more = false
        var contexts: [Int: FamilyNotebookKeyContext] = [current.roster.epoch: .current(current)]
        func source(_ epoch: Int) throws -> VerifiedFamilyNotebookRoster {
            guard epoch > 0, epoch <= current.roster.epoch else { throw FamilyNotebookCryptoError.untrusted }
            if let context = contexts[epoch] { return context.source }
            var context = FamilyNotebookKeyContext.current(current)
            while context.source.roster.epoch > epoch {
                let previousEpoch = context.source.roster.epoch - 1
                guard let previous = history[previousEpoch] else { throw FamilyNotebookSyncError.missingRoster(epoch: previousEpoch) }
                context = try context.previous(previous); contexts[previousEpoch] = context
            }
            return context.source
        }
        for _ in 0..<8 {
            let page = try GroupWire.decode(Page.self, await network.read(path + "/crypto/operations/" + String(cursor)))
            guard page.generation == state.generation, page.currentEpoch == current.roster.epoch else { throw FamilyNotebookTransportError.stale }
            guard page.schemaVersion == 1, page.familyID == familyID, page.operations.count <= 64,
                  page.nextCursor >= cursor, page.nextCursor <= page.headCursor, page.headCursor <= 1_000_000_000,
                  !page.operations.isEmpty || page.headCursor == cursor else { throw FamilyNotebookTransportError.invalidResponse }
            var sequence = cursor
            let incoming = try page.operations.map { entry in
                sequence += 1
                guard entry.sequence == sequence else { throw FamilyNotebookTransportError.invalidResponse }
                guard let key = keys[entry.packet.keyEpoch] else { throw FamilyNotebookSyncError.missingKey(epoch: entry.packet.keyEpoch) }
                return try FamilyNotebookOperationCrypto.open(entry.packet, roster: source(entry.packet.keyEpoch), key: key)
            }
            guard sequence == page.nextCursor else { throw FamilyNotebookTransportError.invalidResponse }
            // Commit plaintext only after EVERY envelope on this page verifies.
            // Save the cursor last; a crash/write failure merely replays a page
            // through the operation-ID collision checks, never skips it.
            if !incoming.isEmpty { _ = try store.receive(incoming) }
            let committed = try store.snapshot()
            try journal.write(GroupWire.encode(Cursor(schemaVersion: 1, familyID: familyID, deviceID: identity.deviceID,
                endpointID: endpointID, sequence: sequence, notebookRevision: committed.revision,
                notebookOperationCount: committed.operations.count)), account: cursorAccount, createOnly: false)
            cursor = sequence; downloaded += incoming.count; more = cursor < page.headCursor
            if !more { break }
        }
        // Download/reading remains available during a Plus pause or while a
        // new participant waits for key rotation. No outbox entry is removed.
        if !paused && state.ready {
            guard let key = keys[current.roster.epoch] else { throw FamilyNotebookSyncError.missingKey(epoch: current.roster.epoch) }
            for operation in try store.pendingOperations().prefix(64) {
                guard try !store.snapshot().sharingEnded else { throw FamilyNotebookError.sharingEnded }
                let encrypted = try FamilyNotebookOperationCrypto.seal(operation, roster: current, key: key, signingKey: identity.signingKey)
                let body = try GroupWire.encode(Upload(operationID: operation.id.uuidString.lowercased(), expectedGeneration: state.generation,
                    expectedEpoch: current.roster.epoch, payload: encrypted))
                let intent = GroupCanonical.hash(try GroupWire.encode(operation)), uploadPath = path + "/crypto/operations"
                let family = familyID, operationID = operation.id
                let validate: @Sendable (Data, Data) throws -> Void = { reply, sent in
                    try FamilyNotebookTransport.validateCryptoReceipt(reply, body: sent, familyID: family, operationID: operationID,
                        action: "operation", path: uploadPath)
                }
                do {
                    do {
                        _ = try await network.mutate(operationID: operationID, intent: intent, path: uploadPath, body: body, validate: validate)
                    } catch FamilyNotebookTransportError.stale {
                        // Exactly one reseal attempt after an explicit reject.
                        // A racing membership change rejects this one too.
                        _ = try await network.mutate(operationID: operationID, intent: intent, path: uploadPath, body: body,
                            replaceAfterStale: true, validate: validate)
                    }
                } catch FamilyNotebookTransportError.paused { paused = true; break }
                _ = try store.acknowledge(.init(familyID: familyID, operationID: operationID, version: operation.version))
                uploaded += 1
            }
        }
        return .init(downloaded: downloaded, uploaded: uploaded, pending: try store.pendingOperations().count,
            moreHistory: more, paused: paused, needsRotation: !state.ready)
    }
}
