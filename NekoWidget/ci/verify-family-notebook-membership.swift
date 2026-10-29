import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lostReply, storage }
private func check(_ value: Bool, _ text: String) throws { if !value { throw Failure.check(text) } }
private func rejects(_ expected: FamilySharingError, line: UInt = #line, _ work: () async throws -> Void) async throws {
    do { try await work() } catch let error as FamilySharingError { try check(error == expected, "line \(line): expected \(expected), got \(error)"); return }
    throw Failure.check("line \(line): expected \(expected)")
}
private actor Relay: GroupHTTPTransport {
    enum Next { case success, lostAfterCommit, lostBeforeCommit, badReceipt, stale, rejectedClaim, denied }
    let family: UUID, identity: GroupDeviceIdentity
    var next = Next.success
    var payer: String?, generation: Int64 = 4, paused = false, invalidPayer = false, invalidHandover = false
    var nominee: String?, nomination: UUID?
    var requests: [URLRequest] = [], committed: [String: (Data, Data)] = [:]
    init(family: UUID, identity: GroupDeviceIdentity) { self.family = family; self.identity = identity; payer = identity.personID }
    func configure(_ next: Next) { self.next = next }
    func configurePayer(_ value: String?, paused: Bool = false, invalid: Bool = false) { payer = value; self.paused = paused; invalidPayer = invalid }
    func configureHandover(nominee: String?, nomination: UUID?, invalid: Bool = false) { self.nominee = nominee; self.nomination = nomination; invalidHandover = invalid }
    func sent() -> [URLRequest] { requests }
    func count() -> Int { committed.count }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        requests.append(request)
        let path = request.url!.path, body = request.httpBody ?? Data(), method = request.httpMethod!
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", identity.deviceID,
            request.value(forHTTPHeaderField: "Neko-Timestamp")!, request.value(forHTTPHeaderField: "Neko-Nonce")!, method, path].map(GroupCanonical.text) + [GroupCanonical.hash(body)])
        try check(try identity.signingKey.publicKey.isValidSignature(GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Signature")!, count: 64), for: transcript), "actual signed request")
        func reply(_ object: [String: Any], _ status: Int = 200) throws -> GroupHTTPReply {
            .init(status: status, data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }
        if method == "GET" {
            let owner = payer == identity.personID
            if path.hasSuffix("/handover") {
                return try reply(["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "generation": generation,
                    "payerPersonId": payer as Any? ?? NSNull(), "nomineePersonId": nominee as Any? ?? NSNull(),
                    "nominationId": nomination?.uuidString.lowercased() as Any? ?? NSNull(), "nominationState": "confirmed",
                    "canNominate": owner && nomination == nil, "canAccept": nominee == identity.personID || invalidHandover,
                    "canCancel": nomination != nil && (owner || nominee == identity.personID)])
            }
            let isPaused = payer == nil || paused
            let pauseReason: String? = payer == nil ? "no_payer" : paused ? "payer_plus_unverified" : nil
            return try reply(["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "generation": generation,
                "payerPersonId": payer as Any? ?? NSNull(), "role": owner ? "payer" : "member",
                "sharingStatus": isPaused ? "paused" : "active", "pauseReason": pauseReason as Any? ?? NSNull(),
                "nominationPending": false, "canClaimPayer": payer == nil, "canRemoveMember": owner || invalidPayer, "canDissolve": owner])
        }
        let value = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let op = value["operationId"] as! String, gen = (value["expectedGeneration"] as! NSNumber).int64Value
        let action = path.split(separator: "/").last!.description, mode = next; next = .success
        if mode == .stale { return try reply(["error": ["code": "family_notebook_stale_generation"]], 409) }
        if mode == .rejectedClaim { return try reply(["error": ["code": "family_notebook_claim_unavailable"]], 409) }
        if mode == .denied { return try reply(["error": ["code": "plus_entitlement_required"]], 403) }
        if mode == .lostBeforeCommit { throw Failure.lostReply }
        let result: Data
        if let saved = committed[op] {
            try check(saved.0 == body, "retry matches original body despite UI UUID/generation change")
            result = saved.1
        } else {
            var object: [String: Any] = ["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "operationId": op,
                "appliedGeneration": gen + 1, action == "claim" || action == "leave" ? "operation" : "action": action]
            if action == "nominate" { object["targetPersonId"] = value["personId"]; object["nominationId"] = op }
            if action == "accept" || action == "cancel" { object["targetPersonId"] = identity.personID; object["nominationId"] = value["nominationId"] }
            if action == "remove" { object["targetPersonId"] = path.split(separator: "/").dropLast().last!.description }
            result = try reply(object).data; committed[op] = (body, result); generation = gen + 1
        }
        if mode == .lostAfterCommit { throw Failure.lostReply }
        if mode == .badReceipt { return try reply([:]) }
        return .init(status: 200, data: result)
    }
}
private final class FailingJournal: GroupSecretStore, @unchecked Sendable {
    func read(_ account: String) throws -> Data? { nil }
    func write(_ data: Data, account: String, createOnly: Bool) throws { throw Failure.storage }
    func remove(_ account: String) throws { throw Failure.storage }
}
private final class SwitchWriter: @unchecked Sendable {
    private let lock = NSLock(); private var failing = false
    func fail(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failing = value }
    func write(_ data: Data, _ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw Failure.storage }
        try FamilyNotebookStore.secureWrite(data, to: url)
    }
}

@main private enum VerifyFamilyNotebookMembership {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-membership-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
        let family = UUID(), relay = Relay(family: family, identity: identity)
        func client(endpoint: String = "https://family.invalid", journal: (any GroupSecretStore)? = nil) throws -> FamilyNotebookMembershipClient {
            try .init(endpoint: URL(string: endpoint)!, identity: identity, transport: relay,
                      journal: journal ?? GroupOperationStore(directory: root.appendingPathComponent("journal")))
        }
        let first = try client(), nominationOp = UUID()
        await relay.configure(.lostAfterCommit)
        try await rejects(.unknownOutcome) { try await first.nominatePayer(familyID: family, personID: "other-person", expectedGeneration: 4, operationID: nominationOp) }
        let reopened = try client()
        try check(try await reopened.hasPendingOperation(), "pending survives process reopen")
        try await rejects(.unknownOutcome) { try await reopened.nominatePayer(familyID: family, personID: "different-person", expectedGeneration: 5, operationID: UUID()) }
        try await rejects(.unknownOutcome) { try await client(endpoint: "https://other.invalid").nominatePayer(familyID: family, personID: "other-person", expectedGeneration: 5, operationID: UUID()) }
        try await reopened.nominatePayer(familyID: family, personID: "other-person", expectedGeneration: 5, operationID: UUID())
        let sent = await relay.sent()
        try check(sent.count == 2 && sent[0].httpBody == sent[1].httpBody, "new UI ID resumes original request")
        let committedCount = await relay.count(), stillPending = try await reopened.hasPendingOperation()
        try check(committedCount == 1 && !stillPending, "one committed operation and cleared intent after ACK")

        await relay.configurePayer(nil)
        try check(try await reopened.loadPause(familyID: family) == .noPayer(canClaim: true, handoverPending: false), "validated state projects pause")
        await relay.configurePayer(nil, invalid: true)
        try await rejects(.serviceUnavailable) { _ = try await reopened.loadPause(familyID: family) }
        await relay.configurePayer("another-payer")
        await relay.configure(.stale)
        try await rejects(.payerAlreadyChosen) { try await reopened.claimPayer(familyID: family, expectedGeneration: 4, operationID: UUID()) }
        await relay.configurePayer(nil)
        await relay.configure(.rejectedClaim)
        try await rejects(.staleRoster) { try await reopened.claimPayer(familyID: family, expectedGeneration: 4, operationID: UUID()) }
        await relay.configurePayer(identity.personID)
        let handover = try await reopened.loadHandover(familyID: family)
        try check(handover.canNominate && !handover.canAccept, "payer can nominate but cannot accept own nomination")
        await relay.configureHandover(nominee: nil, nomination: nil, invalid: true)
        try await rejects(.serviceUnavailable) { _ = try await reopened.loadHandover(familyID: family) }
        await relay.configureHandover(nominee: identity.personID, nomination: UUID())
        await relay.configurePayer("another-payer")
        try check(try await reopened.loadHandover(familyID: family).canAccept, "nominee can accept verified capability")

        await relay.configure(.denied)
        try await rejects(.plusRequired) { try await reopened.acceptPayer(familyID: family, nominationID: UUID(), expectedGeneration: 5, operationID: UUID()) }
        try check(!(try await reopened.hasPendingOperation()), "explicit Plus rejection clears UI intent, no purchase")
        let acceptedNomination = UUID()
        await relay.configure(.badReceipt)
        try await rejects(.unknownOutcome) { try await reopened.acceptPayer(familyID: family, nominationID: acceptedNomination, expectedGeneration: 5, operationID: UUID()) }
        try check(try await reopened.hasPendingOperation(), "malformed ACK never clears a pending action")
        try await client().acceptPayer(familyID: family, nominationID: acceptedNomination, expectedGeneration: 6, operationID: UUID())
        let writer = SwitchWriter()
        let notebook = try FamilyNotebookStore(directory: root.appendingPathComponent("notebook"), familyID: family, deviceID: identity.deviceID,
                                              write: { try writer.write($0, $1) })
        _ = try notebook.edit(target: .init(familyCatID: UUID(), field: .name), value: .text("synthetic cat"), author: .init(personID: identity.personID, displayName: "synthetic"))
        let before = try notebook.snapshot()
        await relay.configure(.lostAfterCommit)
        try check(try await reopened.leaveFamily(familyID: family, expectedGeneration: 5, operationID: UUID(), notebook: notebook) == .pending, "lost leave ACK stays pending")
        try check(!(try notebook.snapshot().sharingEnded), "never end local sharing before ACK")
        writer.fail(true)
        try check(try await client().leaveFamily(familyID: family, expectedGeneration: 6, operationID: UUID(), notebook: notebook) == .pending, "local completion failure retains received ACK and pending state")
        writer.fail(false)
        let countBefore = await relay.sent().count
        try check(try await client().leaveFamily(familyID: family, expectedGeneration: 6, operationID: UUID(), notebook: notebook) == .confirmed, "retry cached receipt completes local leave")
        let after = try notebook.snapshot()
        try check(after.sharingEnded && after.operations == before.operations && after.outbox == before.outbox, "leave retains all data and unsent copy")
        try check(await relay.sent().count == countBefore, "local retry uses cached receipt without network")

        let beforeBroken = await relay.sent().count
        try await rejects(.serviceUnavailable) { try await client(journal: FailingJournal()).nominatePayer(familyID: family, personID: "someone", expectedGeneration: 7, operationID: UUID()) }
        try check(await relay.sent().count == beforeBroken, "storage failure sends no request")
        let otherFamily = try FamilyNotebookStore(directory: root.appendingPathComponent("other"), familyID: UUID(), deviceID: identity.deviceID)
        try await rejects(.notAllowed) { _ = try await reopened.dissolveFamily(familyID: family, expectedGeneration: 7, operationID: UUID(), notebook: otherFamily) }
        print("Family notebook membership: signed governance, durable UI retries, validated pause/handover, losing claims, ACK-only leave and local-copy retention passed")
    }
}
