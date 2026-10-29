import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lostReply, storage }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private func rejects(_ expected: FamilyNotebookTransportError, _ action: () async throws -> Void) async throws {
    do { try await action() } catch let error as FamilyNotebookTransportError { try check(error == expected, "expected \(expected), got \(error)"); return }
    throw Failure.check("expected rejection \(expected)")
}
private struct Mutation: Codable {
    let operationID: String; let expectedGeneration: Int; let expectedEpoch: Int; let payload: String
}
private actor Relay: GroupHTTPTransport {
    enum Next: Equatable { case success, lostAfterCommit, lostBeforeCommit, stale, paused, badReceipt }
    let family: UUID, identity: GroupDeviceIdentity
    var next: Next = .success
    var requests: [URLRequest] = []
    var committed: [String: (body: Data, reply: Data)] = [:]
    init(family: UUID, identity: GroupDeviceIdentity) { self.family = family; self.identity = identity }
    func set(_ next: Next) { self.next = next }
    func count() -> Int { requests.count }
    func sent() -> [URLRequest] { requests }
    func storedCount() -> Int { committed.count }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        requests.append(request)
        let path = request.url!.path, body = request.httpBody!, deviceID = try identity.deviceID
        let timestamp = request.value(forHTTPHeaderField: "Neko-Timestamp")!, nonce = request.value(forHTTPHeaderField: "Neko-Nonce")!
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", deviceID, timestamp, nonce, "POST", path].map(GroupCanonical.text)
            + [GroupCanonical.hash(body)])
        try check(try identity.signingKey.publicKey.isValidSignature(GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Signature")!, count: 64),
                    for: transcript), "actual signed request binds family path/body/nonce")
        let value = try GroupWire.decode(Mutation.self, body), action = next; next = .success
        func error(_ code: String, _ status: Int) -> GroupHTTPReply {
            .init(status: status, data: Data("{\"error\":{\"code\":\"\(code)\"}}".utf8))
        }
        if action == .stale { return error("family_notebook_crypto_stale", 409) }
        if action == .paused { return error("family_notebook_paused", 403) }
        if action == .lostBeforeCommit { throw Failure.lostReply }
        struct Receipt: Encodable {
            let schemaVersion = 1; let familyID: UUID; let operationID: String; let action = "operation"
            let appliedEpoch: Int; let requestHash: Data
        }
        let reply: Data
        if let saved = committed[value.operationID] {
            if saved.body != body { return error("idempotency_conflict", 409) }
            reply = saved.reply
        } else {
            reply = try GroupWire.encode(Receipt(familyID: family, operationID: value.operationID, appliedEpoch: value.expectedEpoch,
                requestHash: FamilyNotebookTransport.requestHash(path: path, body: body)))
            committed[value.operationID] = (body, reply)
        }
        if action == .lostAfterCommit { throw Failure.lostReply }
        if action == .badReceipt { return .init(status: 200, data: Data("{}".utf8)) }
        return .init(status: 200, data: reply)
    }
}
private final class BrokenJournal: GroupSecretStore, @unchecked Sendable {
    func read(_ account: String) throws -> Data? { nil }
    func write(_ data: Data, account: String, createOnly: Bool) throws { throw Failure.storage }
    func remove(_ account: String) throws { throw Failure.storage }
}

@main
private enum VerifyFamilyNotebookTransport {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-transport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
        let family = UUID(), path = "/v3/family-notebooks/\(family.uuidString.lowercased())/crypto/operations"
        let relay = Relay(family: family, identity: identity), intent = GroupCanonical.hash(Data("synthetic logical edit".utf8))
        func client(endpoint: String = "https://family.invalid") throws -> FamilyNotebookTransport {
            try .init(endpoint: URL(string: endpoint)!, identity: identity, transport: relay,
                journal: GroupOperationStore(directory: root, maximumRecordBytes: 2_100_000))
        }
        func body(_ operation: UUID, epoch: Int = 1, large: Bool = false) throws -> Data {
            try GroupWire.encode(Mutation(operationID: operation.uuidString.lowercased(), expectedGeneration: epoch, expectedEpoch: epoch,
                payload: large ? String(repeating: "a", count: 1_400_000) : UUID().uuidString))
        }
        func send(_ client: FamilyNotebookTransport, _ operation: UUID, _ data: Data, replace: Bool = false) async throws -> Data {
            try await client.mutate(operationID: operation, intent: intent, path: path, body: data, replaceAfterStale: replace) { reply, sent in
                try FamilyNotebookTransport.validateCryptoReceipt(reply, body: sent, familyID: family, operationID: operation, action: "operation", path: path)
            }
        }
        let first = try client(), op = UUID(), original = try body(op, large: true)
        await relay.set(.lostAfterCommit)
        try await rejects(.unknownOutcome) { _ = try await send(first, op, original) }
        let restart = try client()
        try await rejects(.unknownOutcome) { _ = try await send(restart, op, body(op, epoch: 2), replace: true) }
        _ = try await send(restart, op, body(op, epoch: 2))
        let requests = await relay.sent()
        try check(requests.count == 2 && requests[0].httpBody == original && requests[1].httpBody == original, "restart retries exactly the persisted large ciphertext")
        try check(requests[0].value(forHTTPHeaderField: "Neko-Nonce") != requests[1].value(forHTTPHeaderField: "Neko-Nonce"), "retry uses a fresh authentication nonce")
        try check(await relay.storedCount() == 1, "lost ACK never duplicates the edit")
        _ = try await send(client(), op, body(op))
        try check(await relay.count() == 2, "confirmed receipt survives reopen without network")
        try await rejects(.idempotencyConflict) { _ = try await send(client(endpoint: "https://other.invalid"), op, original) }

        let staleOp = UUID(), staleBody = try body(staleOp)
        await relay.set(.stale)
        try await rejects(.stale) { _ = try await send(first, staleOp, staleBody) }
        let resealed = try body(staleOp, epoch: 2)
        _ = try await send(client(), staleOp, resealed, replace: true)
        try check(await relay.sent().last?.httpBody == resealed, "definitive CAS rejection permits the same logical edit at the current epoch")

        let uncertain = UUID(), uncertainBody = try body(uncertain)
        await relay.set(.stale)
        try await rejects(.stale) { _ = try await send(first, uncertain, uncertainBody) }
        await relay.set(.lostBeforeCommit)
        try await rejects(.unknownOutcome) { _ = try await send(first, uncertain, uncertainBody) }
        try await rejects(.unknownOutcome) { _ = try await send(client(), uncertain, body(uncertain, epoch: 2), replace: true) }

        let paused = UUID(), pausedBody = try body(paused)
        await relay.set(.paused)
        try await rejects(.paused) { _ = try await send(first, paused, pausedBody) }
        _ = try await send(client(), paused, body(paused))
        try check(await relay.sent().last?.httpBody == pausedBody, "Plus pause keeps the original pending body")

        let malformed = UUID(), malformedBody = try body(malformed)
        await relay.set(.badReceipt)
        do { _ = try await send(first, malformed, malformedBody); throw Failure.check("malformed receipt accepted") }
        catch is DecodingError { }
        let beforeRetry = await relay.count()
        _ = try await send(client(), malformed, body(malformed))
        try check(await relay.count() == beforeRetry + 1, "malformed receipt was never cached as an ACK")

        let blocked = try FamilyNotebookTransport(endpoint: URL(string: "https://family.invalid")!, identity: identity, transport: relay, journal: BrokenJournal())
        let beforeWrite = await relay.count(), failed = UUID()
        do { _ = try await send(blocked, failed, body(failed)); throw Failure.check("journal write failure ignored") }
        catch Failure.storage { }
        try check(await relay.count() == beforeWrite, "failed durable write sends nothing")
        print("Family notebook transport: signed requests, durable large-body restart, unknown/stale distinction, pause, receipts and write-failure checks passed")
    }
}
