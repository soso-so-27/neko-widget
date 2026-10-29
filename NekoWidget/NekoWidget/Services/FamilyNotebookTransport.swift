import Foundation

enum FamilyNotebookTransportError: Error, Equatable {
    case invalidResponse, authenticationRequired, notMember, paused, unavailable
    case stale, unknownOutcome, idempotencyConflict, operationInFlight
    case server(code: String, status: Int)
}

/// Family protocol traffic uses the registered app identity. It never imports
/// photo-window membership as family consent. Only encrypted/public request
/// bodies and receipts enter the app-private journal; keys use a separate store.
actor FamilyNotebookTransport {
    private let endpoint: URL
    private let identity: GroupDeviceIdentity
    private let transport: any GroupHTTPTransport
    private let journal: any GroupSecretStore
    private var inFlight = Set<UUID>()

    private struct Record: Codable {
        let operationID: UUID
        let deviceID: String
        let endpoint: String
        let intent: Data
        let path: String
        var body: Data
        var response: Data?
        // Only a definitive, authenticated CAS rejection permits resealing
        // the SAME logical edit with a current epoch. Unknown outcomes never do.
        var rejectedAsStale: Bool
    }

    init(endpoint: URL, identity: GroupDeviceIdentity, transport: any GroupHTTPTransport, journal: any GroupSecretStore) throws {
        guard identity.registered else { throw FamilyNotebookTransportError.authenticationRequired }
        _ = try GroupHTTPRequest.make(endpoint: endpoint, path: "/v3/family-notebooks/me", body: nil, identity: identity)
        self.endpoint = endpoint; self.identity = identity; self.transport = transport; self.journal = journal
    }
    private func pathAllowed(_ path: String) throws {
        guard path == "/v3/family-notebooks" || path.hasPrefix("/v3/family-notebooks/") else {
            throw FamilyNotebookTransportError.invalidResponse
        }
    }
    func read(_ path: String) async throws -> Data {
        try pathAllowed(path)
        let request = try GroupHTTPRequest.make(endpoint: endpoint, path: path, body: nil, identity: identity)
        let reply: GroupHTTPReply
        do { reply = try await transport.send(request, maximumBytes: 1_600_000) }
        catch { throw FamilyNotebookTransportError.unavailable }
        return try Self.check(reply)
    }

    /// intent hashes the semantic operation (family, target, author, value),
    /// never just a button name. On retry, the original body wins even if fresh
    /// encryption/metadata supplied by the caller differs. validate must check
    /// the response against the body that was actually sent, including IDs.
    func mutate(operationID: UUID, intent: Data, path: String, body: Data, replaceAfterStale: Bool = false,
                validate: @Sendable (Data, Data) throws -> Void) async throws -> Data {
        try pathAllowed(path)
        guard intent.count == 32, (1...1_500_000).contains(body.count) else { throw FamilyNotebookTransportError.invalidResponse }
        guard inFlight.insert(operationID).inserted else { throw FamilyNotebookTransportError.operationInFlight }
        defer { inFlight.remove(operationID) }
        let account = "op:family:" + operationID.uuidString.lowercased()
        var record: Record
        if let bytes = try journal.read(account) {
            record = try GroupWire.decode(Record.self, bytes)
            guard record.operationID == operationID, record.deviceID == (try identity.deviceID), record.endpoint == endpoint.absoluteString,
                  record.intent == intent, record.path == path,
                  (1...1_500_000).contains(record.body.count) else { throw FamilyNotebookTransportError.idempotencyConflict }
            if let response = record.response {
                try validate(response, record.body)
                return response
            }
            if replaceAfterStale {
                guard record.rejectedAsStale else { throw FamilyNotebookTransportError.unknownOutcome }
                record.body = body; record.rejectedAsStale = false
                try journal.write(GroupWire.encode(record), account: account, createOnly: false)
            }
        } else {
            guard !replaceAfterStale else { throw FamilyNotebookTransportError.invalidResponse }
            record = try .init(operationID: operationID, deviceID: identity.deviceID, endpoint: endpoint.absoluteString, intent: intent, path: path,
                               body: body, response: nil, rejectedAsStale: false)
            try journal.write(GroupWire.encode(record), account: account, createOnly: true)
        }
        // Persist first; the network is never attempted after a failed write.
        // A previous rejection cannot authorize resealing after a NEW send
        // whose outcome becomes unknown (e.g. a formerly future generation).
        if record.rejectedAsStale {
            record.rejectedAsStale = false
            try journal.write(GroupWire.encode(record), account: account, createOnly: false)
        }
        let request = try GroupHTTPRequest.make(endpoint: endpoint, path: record.path, body: record.body, identity: identity)
        let reply: GroupHTTPReply
        do { reply = try await transport.send(request, maximumBytes: 262_144) }
        catch { throw FamilyNotebookTransportError.unknownOutcome }
        let response: Data
        do { response = try Self.check(reply) }
        catch FamilyNotebookTransportError.stale {
            record.rejectedAsStale = true
            try journal.write(GroupWire.encode(record), account: account, createOnly: false)
            throw FamilyNotebookTransportError.stale
        }
        // A malformed receipt cannot turn a pending local edit into an ACK.
        try validate(response, record.body)
        record.response = response
        try journal.write(GroupWire.encode(record), account: account, createOnly: false)
        return response
    }

    static func requestHash(path: String, body: Data) throws -> Data {
        GroupCanonical.hash(try GroupCanonical.fields([GroupCanonical.text("NW3.OPERATION"), GroupCanonical.text("POST"),
            GroupCanonical.text(path), GroupCanonical.hash(body)]))
    }
    static func validateCryptoReceipt(_ response: Data, body: Data, familyID: UUID, operationID: UUID, action: String, path: String) throws {
        struct Receipt: Decodable {
            let schemaVersion: Int; let familyID: UUID; let operationID: UUID
            let action: String; let appliedEpoch: Int; let requestHash: Data
        }
        struct Request: Decodable { let expectedEpoch: Int }
        let request = try GroupWire.decode(Request.self, body)
        let value = try GroupWire.decode(Receipt.self, response)
        guard value.schemaVersion == 1, value.familyID == familyID, value.operationID == operationID, value.action == action,
              (0...1_000_000_000).contains(request.expectedEpoch), (0...1_000_000_000).contains(value.appliedEpoch),
              value.appliedEpoch == request.expectedEpoch + (action == "roster" ? 1 : 0),
              value.requestHash == (try requestHash(path: path, body: body)) else {
            throw FamilyNotebookTransportError.invalidResponse
        }
    }
    private static func check(_ reply: GroupHTTPReply) throws -> Data {
        guard reply.status == 200 || reply.status == 201 else {
            struct ErrorBody: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            guard let error = try? GroupWire.decode(ErrorBody.self, reply.data).error else { throw FamilyNotebookTransportError.unknownOutcome }
            switch error.code {
            case "invalid_authentication", "invalid_proof", "replay": throw FamilyNotebookTransportError.authenticationRequired
            case "not_found": throw FamilyNotebookTransportError.notMember
            case "family_notebook_paused": throw FamilyNotebookTransportError.paused
            case "family_notebook_stale_generation", "family_notebook_crypto_stale":
                guard reply.status == 409 else { throw FamilyNotebookTransportError.unknownOutcome }
                throw FamilyNotebookTransportError.stale
            case "idempotency_conflict": throw FamilyNotebookTransportError.idempotencyConflict
            case "family_notebook_disabled", "family_notebook_unavailable": throw FamilyNotebookTransportError.unavailable
            default: throw FamilyNotebookTransportError.server(code: error.code, status: reply.status)
            }
        }
        return reply.data
    }
}
