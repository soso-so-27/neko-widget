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
    /// 11/16: writing of this iPhone set aside (kept, not sent): the server
    /// will not take it, or it can never be sent from here.
    var heldBack = 0
    /// Why the last one was set aside in this pass (the kind only).
    var heldFailure: FamilyNotebookSendFailure? = nil
}

/// 11/16: why writing of this iPhone did not reach the family. The kind only:
/// no operation, person, device or content. Every failure used to be dropped
/// without a trace, and one that could never be sent stopped all after it.
enum FamilyNotebookSendFailure: String, Codable, CaseIterable, Sendable {
    /// No answer, or an answer that did not arrive (the outcome is unknown).
    case network
    /// This iPhone could not prove who it is.
    case authentication
    /// Not (or no longer) in the family on the server.
    case membership
    /// Keys or the roster are not there yet, or do not match.
    case keys
    /// The family's generation or key epoch moved (409 stale).
    case generation
    /// A 409 other than stale: the same ID with other content.
    case conflict
    /// 429.
    case rateLimited
    /// The payer's Plus is not confirmed: sharing is paused.
    case paused
    /// The service is off or could not answer (5xx).
    case unavailable
    /// The family needs a newer app to write.
    case upgrade
    /// The server refused this writing (400, 413, 422).
    case rejected
    /// The writing is not in a shape that can be sent (too large, invalid).
    case invalid
    case other

    /// 11/16: the short code shown under the unsent line when asked
    /// (「コード：RJ-3」): meaningless to most people, said to support.
    var code: String {
        switch self {
        case .network: "NW"
        case .authentication: "AU"
        case .membership: "MB"
        case .keys: "KY"
        case .generation: "GN"
        case .conflict: "CF"
        case .rateLimited: "RL"
        case .paused: "PS"
        case .unavailable: "UA"
        case .upgrade: "UP"
        case .rejected: "RJ"
        case .invalid: "IV"
        case .other: "OT"
        }
    }

    /// The code with the number not sent yet; 「00」 when no failure is known.
    static func code(kind: String?, unsent: Int) -> String {
        (kind.flatMap(Self.init(rawValue:))?.code ?? "00") + "-" + String(unsent)
    }

    /// What the upload does with the failed operation.
    enum Disposition: Equatable, Sendable {
        /// The family, the network or the keys: the same for every operation.
        /// Stop, keep the order, try again on a later pass.
        case waitInOrder
        /// Only this operation: keep it in the outbox with a mark and send
        /// the ones after it. The person's 「もう一度」 tries it again.
        case setAside
    }

    static func kind(of error: Error) -> Self {
        switch error {
        case let error as FamilyNotebookTransportError:
            switch error {
            case .unknownOutcome, .operationInFlight: return .network
            case .authenticationRequired: return .authentication
            case .notMember: return .membership
            case .paused: return .paused
            case .unavailable: return .unavailable
            case .stale: return .generation
            case .idempotencyConflict: return .conflict
            case .upgradeRequired: return .upgrade
            case .invalidResponse: return .other
            case let .server(_, status):
                switch status {
                case 429: return .rateLimited
                case 409: return .conflict
                case 400, 413, 422: return .rejected
                case 401: return .authentication
                case 403, 404: return .membership
                case 500...599: return .unavailable
                default: return .other
                }
            }
        case let error as FamilyNotebookSyncError:
            switch error { case .missingKey, .missingRoster: return .keys }
        case let error as FamilyNotebookCryptoError:
            switch error {
            case .untrusted, .stale: return .keys
            case .invalid, .tooLarge: return .invalid
            }
        case let error as FamilyNotebookError:
            switch error {
            case .invalidValue, .invalidTarget, .invalidOperation: return .invalid
            case .sharingEnded: return .membership
            default: return .other
            }
        case is URLError: return .network
        default: return .other
        }
    }

    /// One operation that failed to go. Only a reason that belongs to this
    /// operation alone sets it aside; anything about the family, the network,
    /// the keys or the budget keeps the order (the next pass tries again).
    static func disposition(of error: Error, operation: FamilyNotebookOperation,
                            deviceID: String, personID: String) -> Disposition {
        if case FamilyNotebookCryptoError.untrusted = error {
            // Written by another device or person than this one: it can never
            // be signed here. This device not in the roster yet: wait.
            let foreign = operation.version.deviceID != deviceID || operation.author.personID != personID
            return foreign ? .setAside : .waitInOrder
        }
        if case FamilyNotebookTransportError.idempotencyConflict = error { return .setAside }
        switch kind(of: error) {
        case .rejected, .invalid: return .setAside
        default: return .waitInOrder
        }
    }
}

/// 11/16: whether this iPhone's writing has been failing to reach the
/// family. Kept on this iPhone only: the last failure's kind and time, when
/// the failing began and how many reads in a row failed. Pure, so the line's
/// rule is checked on a synthetic clock.
struct FamilyNotebookSendHealth: Codable, Equatable, Sendable {
    /// What one whole read did about this iPhone's writing.
    enum Outcome: Equatable, Sendable {
        /// It got to sending: `heldBack` operations stay set aside.
        case sent(heldBack: Int, failure: String?)
        /// It stopped with this kind (FamilyNotebookSendFailure.rawValue).
        case failed(String)
    }
    struct Failure: Codable, Equatable, Sendable {
        let kind: String
        let at: Date
    }

    /// The line shows after this many failed reads in a row, the first at
    /// least a minute ago (a key change after joining fails a few times in
    /// seconds), or after 10 minutes of failing whatever the count.
    static let failuresBeforeLine = 3
    static let shortestBeforeLine: TimeInterval = 60
    static let longestBeforeLine: TimeInterval = 600

    private(set) var last: Failure?
    private(set) var failingSince: Date?
    private(set) var failures = 0

    init() {}

    /// What is worth saving: the kind and the start of the failing.
    var persisted: String { "\(last?.kind ?? "")|\(failingSince?.timeIntervalSince1970 ?? 0)" }

    /// After a whole read. `unsent`: the outbox after it, set-aside included.
    /// nil: the read did not get as far as sending, without an error (sharing
    /// paused, keys still moving): nothing changes, unless all was sent.
    mutating func record(_ outcome: Outcome?, unsent: Int, at now: Date) {
        switch outcome {
        case nil:
            if unsent == 0 { clear() }
        case let .failed(kind):
            last = .init(kind: kind, at: now)
            fail(unsent: unsent, at: now)
        case let .sent(heldBack, failure):
            if let failure { last = .init(kind: failure, at: now) }
            if heldBack > 0 { fail(unsent: unsent, at: now) } else { clear() }
        }
    }

    private mutating func fail(unsent: Int, at now: Date) {
        guard unsent > 0 else { clear(); return }
        failures += 1
        if failingSince == nil { failingSince = now }
    }

    private mutating func clear() { failures = 0; failingSince = nil }

    /// 「家族に届けられていない書き込みがあります。」 Never while all is sent.
    func showsLine(unsent: Int, now: Date) -> Bool {
        guard unsent > 0, let since = failingSince else { return false }
        let waited = now.timeIntervalSince(since)
        return (failures >= Self.failuresBeforeLine && waited >= Self.shortestBeforeLine) || waited >= Self.longestBeforeLine
    }
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
        let writeContract: FamilyNotebookWriteContract.Capability?
    }
    private struct Page: Decodable {
        struct Entry: Decodable { let sequence: Int; let packet: EncryptedFamilyNotebookOperation }
        let schemaVersion: Int; let familyID: UUID; let generation: Int64; let currentEpoch: Int
        let nextCursor: Int; let headCursor: Int; let operations: [Entry]
    }
    private struct Upload: Encodable {
        let operationID: String; let expectedGeneration: Int64; let expectedEpoch: Int
        let payload: EncryptedFamilyNotebookOperation
        var writeContract: FamilyNotebookWriteContract.Envelope? = nil
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
                     keys: [Int: Data], retryHeld: Bool = false) async throws -> FamilyNotebookSyncResult {
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
            if local.revision >= saved.notebookRevision && local.retainedOperationCount >= saved.notebookOperationCount {
                cursor = saved.sequence
            }
        }
        var downloaded = 0, uploaded = 0, more = false
        var heldBack = 0, heldFailure: FamilyNotebookSendFailure?
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
                return try FamilyNotebookOperationCrypto.openRetaining(entry.packet, roster: source(entry.packet.keyEpoch), key: key)
            }
            guard sequence == page.nextCursor else { throw FamilyNotebookTransportError.invalidResponse }
            // Commit plaintext only after EVERY envelope on this page verifies.
            // Save the cursor last; a crash/write failure merely replays a page
            // through the operation-ID collision checks, never skips it.
            if !incoming.isEmpty { try store.receiveRetaining(incoming) }
            let committed = try store.snapshot()
            try journal.write(GroupWire.encode(Cursor(schemaVersion: 1, familyID: familyID, deviceID: identity.deviceID,
                endpointID: endpointID, sequence: sequence, notebookRevision: committed.revision,
                notebookOperationCount: committed.retainedOperationCount)), account: cursorAccount, createOnly: false)
            cursor = sequence; downloaded += incoming.count; more = cursor < page.headCursor
            if !more { break }
        }
        // Download/reading remains available during a Plus pause or while a
        // new participant waits for key rotation. No outbox entry is removed.
        if !paused && state.ready {
            if let capability = state.writeContract, !capability.canWrite {
                throw FamilyNotebookTransportError.upgradeRequired
            }
            guard let key = keys[current.roster.epoch] else { throw FamilyNotebookSyncError.missingKey(epoch: current.roster.epoch) }
            // 11/16: set aside earlier (kept in the outbox): skipped, unless
            // the person asked to send them again.
            let waiting = Set(try store.pendingOperations().map(\.id))
            var aside: Set<UUID> = try retryHeld ? [] : held().intersection(waiting)
            let thisDevice = try identity.deviceID
            try saveHeld(aside)
            for operation in try store.pendingOperations().filter({ !aside.contains($0.id) }).prefix(64) {
                guard try !store.snapshot().sharingEnded else { throw FamilyNotebookError.sharingEnded }
                // Recheck the live outbox, not only the earlier array: consent
                // may have been withdrawn while another operation was in flight.
                guard try store.pendingOperations().contains(where: { $0.id == operation.id }) else { continue }
                do {
                let encrypted = try FamilyNotebookOperationCrypto.seal(operation, roster: current, key: key, signingKey: identity.signingKey)
                let body = try GroupWire.encode(Upload(operationID: operation.id.uuidString.lowercased(), expectedGeneration: state.generation,
                    expectedEpoch: current.roster.epoch, payload: encrypted,
                    writeContract: state.writeContract == nil ? nil : .init(effects:
                        operation.target.collection == .cat && (operation.target.field == nil || operation.target.field == .sharingEnded)
                            ? [.init(kind: "retireCat", slotID: FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: familyID, catID: operation.target.familyCatID))]
                            : operation.target.collection == .cat && operation.target.field?.rawValue == "representativePhoto" && operation.value == .clear
                                ? [.init(kind: "clearPhoto", slotID: FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: familyID, catID: operation.target.familyCatID))] : [])))
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
                } catch {
                    guard FamilyNotebookSendFailure.disposition(of: error, operation: operation,
                            deviceID: thisDevice, personID: identity.personID) == .setAside else { throw error }
                    aside.insert(operation.id)
                    try saveHeld(aside)
                    heldFailure = FamilyNotebookSendFailure.kind(of: error)
                }
            }
            heldBack = aside.count
        }
        var result = FamilyNotebookSyncResult(downloaded: downloaded, uploaded: uploaded, pending: try store.pendingOperations().count,
            moreHistory: more, paused: paused, needsRotation: !state.ready)
        result.heldBack = heldBack; result.heldFailure = heldFailure
        return result
    }

    // MARK: Set aside (11/16)

    private var heldAccount: String { "op:fnb-held:" + familyID.uuidString.lowercased() }

    /// Operations of the outbox set aside on this iPhone. Only their IDs are
    /// kept (no content); the operations stay in the outbox.
    func held() throws -> Set<UUID> {
        guard let bytes = try journal.read(heldAccount) else { return [] }
        return Set(try JSONDecoder().decode([UUID].self, from: bytes))
    }

    private func saveHeld(_ ids: Set<UUID>) throws {
        guard try held() != ids else { return }
        if ids.isEmpty { try journal.remove(heldAccount); return }
        let sorted = ids.sorted { $0.uuidString < $1.uuidString }
        try journal.write(JSONEncoder().encode(sorted), account: heldAccount, createOnly: false)
    }
}
