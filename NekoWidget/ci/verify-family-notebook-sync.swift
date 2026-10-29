import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lostReply }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private actor Relay: GroupHTTPTransport {
    let family: UUID, identity: GroupDeviceIdentity, current: VerifiedFamilyNotebookRoster, key: Data
    var packets: [EncryptedFamilyNotebookOperation]
    var bodies: [UUID: Data] = [:]
    var paused = true, loseNext = false, tamper = false
    var requests = 0
    init(family: UUID, identity: GroupDeviceIdentity, current: VerifiedFamilyNotebookRoster, key: Data, packets: [EncryptedFamilyNotebookOperation]) {
        self.family = family; self.identity = identity; self.current = current; self.key = key; self.packets = packets
    }
    func resumeAndLoseReply() { paused = false; loseNext = true }
    func setTamper() { tamper = true }
    func count() -> Int { requests }
    func packetCount() -> Int { packets.count }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        requests += 1
        let path = request.url!.path
        if request.httpMethod == "GET" {
            if path.hasSuffix("/payer") {
                return .init(status: 200, data: try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1, "familyId": family.uuidString.lowercased(), "generation": 1,
                    "sharingStatus": paused ? "paused" : "active", "pauseReason": paused ? "payer_plus_unverified" as Any : NSNull(),
                    "payerPersonId": identity.personID, "role": "payer", "nominationPending": false, "canClaimPayer": false,
                    "canRemoveMember": true, "canDissolve": true,
                ]))
            }
            if path.hasSuffix("/crypto/state") {
                struct State: Encodable {
                    let schemaVersion = 1; let familyID: UUID; let generation = 1; let currentEpoch = 1
                    let roster: SignedFamilyNotebookRoster; let ready = true
                }
                return .init(status: 200, data: try GroupWire.encode(State(familyID: family, roster: current.packet)))
            }
            let cursor = Int(path.split(separator: "/").last!)!
            struct Page: Encodable {
                struct Entry: Encodable { let sequence: Int; let packet: EncryptedFamilyNotebookOperation }
                let schemaVersion = 1; let familyID: UUID; let generation = 1; let currentEpoch = 1
                let nextCursor: Int; let headCursor: Int; let operations: [Entry]
            }
            var entries = packets.enumerated().filter { $0.offset >= cursor }.map { Page.Entry(sequence: $0.offset + 1, packet: $0.element) }
            if tamper, let first = entries.first {
                let p = first.packet
                entries[0] = .init(sequence: first.sequence, packet: .init(familyID: p.familyID, keyEpoch: p.keyEpoch, rosterHash: p.rosterHash,
                    operationID: p.operationID, personID: p.personID, deviceID: p.deviceID,
                    ciphertext: Data(repeating: 0, count: p.ciphertext.count), signature: p.signature))
            }
            return .init(status: 200, data: try GroupWire.encode(Page(familyID: family, nextCursor: packets.count, headCursor: packets.count, operations: entries)))
        }
        struct Upload: Decodable { let operationID: UUID; let expectedGeneration: Int; let expectedEpoch: Int; let payload: EncryptedFamilyNotebookOperation }
        let body = request.httpBody!, upload = try GroupWire.decode(Upload.self, body)
        _ = try FamilyNotebookOperationCrypto.open(upload.payload, roster: current, key: key)
        if let old = bodies[upload.operationID] { try check(old == body, "restart sent different ciphertext for an unknown outcome") }
        else { bodies[upload.operationID] = body; packets.append(upload.payload) }
        if loseNext { loseNext = false; throw Failure.lostReply }
        struct Receipt: Encodable {
            let schemaVersion = 1; let familyID: UUID; let operationID: UUID; let action = "operation"
            let appliedEpoch = 1; let requestHash: Data
        }
        return .init(status: 200, data: try GroupWire.encode(Receipt(familyID: family, operationID: upload.operationID,
            requestHash: FamilyNotebookTransport.requestHash(path: path, body: body))))
    }
}

@main
private enum VerifyFamilyNotebookSync {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
        let family = UUID(), device = try identity.deviceID, author = FamilyNotebookAuthor(personID: identity.personID, displayName: "合成の家族")
        let member = FamilyNotebookCryptoMember(personID: identity.personID, identityPublicKey: identity.personPublicKey,
            devices: [try identity.certificate(windowID: family.uuidString.lowercased())])
        let key = Data(repeating: 9, count: 32)
        let roster = FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(key), members: [member])
        let packet = try FamilyNotebookRosterCrypto.sign(roster, deviceID: device, signingKey: identity.signingKey)
        let current = try FamilyNotebookRosterCrypto.restore(packet,
            trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(roster.canonicalBytes())))
        let local = try FamilyNotebookStore(directory: root.appendingPathComponent("original"), familyID: family, deviceID: device)
        let pending = try local.edit(target: .init(familyCatID: UUID(), field: .name), value: .text("合成の未送信"), author: author)
        let remote = FamilyNotebookOperation(familyID: family, target: .init(familyCatID: UUID(), field: .name), value: .text("合成の受信"),
            version: .init(clock: 2, deviceID: device, operationID: UUID()), author: author, editedAt: Date())
        let relay = try Relay(family: family, identity: identity, current: current, key: key,
            packets: [FamilyNotebookOperationCrypto.seal(remote, roster: current, key: key, signingKey: identity.signingKey)])
        func engine(_ store: FamilyNotebookStore) throws -> FamilyNotebookSync {
            let journal = try GroupOperationStore(directory: root.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000)
            let network = try FamilyNotebookTransport(endpoint: URL(string: "https://family.invalid")!, identity: identity, transport: relay, journal: journal)
            return try .init(familyID: family, identity: identity, store: store, network: network, journal: journal, endpointID: "https://family.invalid")
        }
        let sync = try engine(local)
        let paused = try await sync.synchronize(current: current, history: [:], keys: [1: key])
        try check(paused.paused && paused.downloaded == 1 && paused.uploaded == 0 && paused.pending == 1, "Plus pause retains pending edits and permits reading")
        try check(try local.snapshot().operations.count == 2, "received and personal pending originals both remain")
        await relay.resumeAndLoseReply()
        do { _ = try await sync.synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("lost response accepted") }
        catch FamilyNotebookTransportError.unknownOutcome { }
        try check(try local.pendingOperations().map(\.id) == [pending.id], "lost ACK keeps local outbox")
        let resumed = try await engine(local).synchronize(current: current, history: [:], keys: [1: key])
        let packetCount = await relay.packetCount()
        try check(resumed.uploaded == 1 && resumed.pending == 0 && packetCount == 2, "reopen reconciles the exact operation once")

        // An older/empty restored notebook must not trust the newer sidecar
        // cursor. Refill the complete history without deleting either copy.
        let older = try FamilyNotebookStore(directory: root.appendingPathComponent("older-copy"), familyID: family, deviceID: device)
        let refilled = try await engine(older).synchronize(current: current, history: [:], keys: [1: key])
        try check(refilled.downloaded == 2 && older.snapshot().operations.count == 2, "older local copy refills all history")
        try check(try local.snapshot().operations.count == 2, "original retained after refilling another copy")

        let tampered = try FamilyNotebookStore(directory: root.appendingPathComponent("tamper-check"), familyID: family, deviceID: device)
        await relay.setTamper()
        do { _ = try await engine(tampered).synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("forged history accepted") }
        catch FamilyNotebookCryptoError.untrusted { }
        try check(try tampered.snapshot().operations.isEmpty, "forged page never partially merges")

        _ = try local.endSharing()
        let requestCount = await relay.count()
        do { _ = try await sync.synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("departed notebook sent traffic") }
        catch FamilyNotebookError.sharingEnded { }
        try check(await relay.count() == requestCount, "ended participation sends nothing")
        try check(try local.snapshot().operations.count == 2, "departure retains every original")
        print("Family notebook sync: authenticated encrypted merge, pause/resume, lost ACK restart, older-copy refill, tamper and departure retention passed")
    }
}
