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
    func append(_ packet: EncryptedFamilyNotebookOperation) { packets.append(packet) }
    func packetCount() -> Int { packets.count }
    func savedPackets() -> [EncryptedFamilyNotebookOperation] { packets }
    func activate() { paused = false }
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
        _ = try FamilyNotebookOperationCrypto.openRetaining(upload.payload, roster: current, key: key)
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
        if let phase = ProcessInfo.processInfo.environment["ADOPTION_PHASE"] {
            try await adoptionCompatibility(phase); return
        }
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
        try await verifyFuture(root: root, identity: identity, current: current, key: key, author: author)
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
    // The shell runs this identical fixture with the actual pre-change and new binaries.
    private static func adoptionCompatibility(_ phase: String) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ADOPTION_ROOT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct Fixture: Codable { let identity: GroupDeviceIdentity; let family: UUID; let cat: UUID }
        let fixtureURL = root.appendingPathComponent("fixture.json")
        let f: Fixture
        if phase == "new-receive" {
            var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
            f = Fixture(identity: identity, family: UUID(), cat: UUID())
            try JSONEncoder().encode(f).write(to: fixtureURL)
        } else { f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)) }
        let identity = f.identity, device = try identity.deviceID, family = f.family
        let author = FamilyNotebookAuthor(personID: identity.personID, displayName: "合成")
        let key = Data(repeating: 17, count: 32)
        let rosterURL = root.appendingPathComponent("roster.json")
        let signed: SignedFamilyNotebookRoster
        if phase == "new-receive" {
            let member = FamilyNotebookCryptoMember(personID: identity.personID, identityPublicKey: identity.personPublicKey,
                devices: [try identity.certificate(windowID: family.uuidString.lowercased())])
            let roster = FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32), keyCommitment: GroupCanonical.hash(key), members: [member])
            signed = try FamilyNotebookRosterCrypto.sign(roster, deviceID: device, signingKey: identity.signingKey)
            try JSONEncoder().encode(signed).write(to: rosterURL)
        } else {
            signed = try JSONDecoder().decode(SignedFamilyNotebookRoster.self, from: Data(contentsOf: rosterURL))
        }
        let current = try FamilyNotebookRosterCrypto.restore(signed, trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(signed.roster.canonicalBytes())))
        let packetsURL = root.appendingPathComponent("packets.json")
        var packets: [EncryptedFamilyNotebookOperation] = []
        if phase == "new-receive" {
            let op = FamilyNotebookOperation(familyID: family, target: .init(familyCatID: f.cat, field: FamilyNotebookField(rawValue: "adoptionDay")!),
                value: .text("2020-02-29|1"), version: .init(clock: 1, deviceID: device, operationID: UUID()), author: author, editedAt: Date())
            packets = [try FamilyNotebookOperationCrypto.seal(op, roster: current, key: key, signingKey: identity.signingKey)]
        } else { packets = try JSONDecoder().decode([EncryptedFamilyNotebookOperation].self, from: Data(contentsOf: packetsURL)) }
        let store = try FamilyNotebookStore(directory: root.appendingPathComponent("store"), familyID: family, deviceID: device)
        let relay = Relay(family: family, identity: identity, current: current, key: key, packets: packets)
        await relay.activate()
        let journal = try GroupOperationStore(directory: root.appendingPathComponent("journal-" + phase), maximumRecordBytes: 2_100_000)
        let network = try FamilyNotebookTransport(endpoint: URL(string: "https://compat.invalid")!, identity: identity, transport: relay, journal: journal)
        let engine = try FamilyNotebookSync(familyID: family, identity: identity, store: store, network: network, journal: journal, endpointID: "https://compat.invalid")
        if phase == "old-edit" {
            try check(try store.snapshot().opaqueOperations.count == 2, "old reader retains received and pending adoption")
            _ = try store.edit(target: .init(familyCatID: f.cat, field: .name), value: .text("古い版の編集"), author: author)
        }
        _ = try await engine.synchronize(current: current, history: [:], keys: [1: key])
        if phase == "new-receive" {
            try check(try store.snapshot().operations.contains { $0.target.field?.rawValue == "adoptionDay" }, "new receives and projects adoption")
            _ = try store.edit(target: .init(familyCatID: f.cat, field: FamilyNotebookField(rawValue: "adoptionDay")!), value: .text("2020-03-01|0"), author: author)
        }
        if phase == "old-edit" {
            let state = try JSONDecoder().decode(FamilyNotebookStore.State.self, from: Data(contentsOf: root.appendingPathComponent("store/family-notebook.json")))
            let backup = try FamilyNotebookBackup.encode(.init(copies: [.init(id: UUID(), state: state)]))
            let restored = try FamilyNotebookBackup.decode(FamilyNotebookBackup.restored(backup))
            try check(restored.copies[0].state.opaqueOperations?.count == 2, "old backup and restore retain both adoption values")
            let dir = root.appendingPathComponent("restored")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(restored.copies[0].state).write(to: dir.appendingPathComponent("family-notebook.json"))
        }
        if phase == "new-verify" {
            let snapshot = try store.snapshot()
            try check(snapshot.operations.filter { $0.target.field?.rawValue == "adoptionDay" }.count == 2, "new recovers complete adoption history")
            try check(snapshot.operations.contains { $0.value == .text("古い版の編集") }, "old name edit survives resync")
            try check(try store.pendingOperations().isEmpty, "new sends retained pending adoption")
            let restored = try FamilyNotebookStore(directory: root.appendingPathComponent("restored"), familyID: family, deviceID: device)
            try check(try restored.snapshot().operations.filter { $0.target.field?.rawValue == "adoptionDay" }.count == 2, "new opens old restored backup")
            try check(try restored.pendingOperations().isEmpty, "restored private copy never sends")
        }
        try JSONEncoder().encode(await relay.savedPackets()).write(to: packetsURL)
        print("Adoption compatibility phase passed: " + phase)
    }

    private static func verifyFuture(root: URL, identity: GroupDeviceIdentity, current: VerifiedFamilyNotebookRoster,
                                     key: Data, author: FamilyNotebookAuthor) async throws {
        let family = current.roster.familyID, device = try identity.deviceID, cat = UUID()
        let directory = root.appendingPathComponent("forward")
        let store = try FamilyNotebookStore(directory: directory, familyID: family, deviceID: device)
        func operation(_ clock: UInt64) -> FamilyNotebookOperation {
            .init(familyID: family, target: .init(familyCatID: cat, field: .name), value: .text("既知"),
                version: .init(clock: clock, deviceID: device, operationID: UUID()), author: author, editedAt: Date())
        }
        // Independent future writer uses the unchanged signed AES-GCM envelope.
        func sealRaw(_ bytes: Data, identityOperation op: FamilyNotebookOperation) throws -> EncryptedFamilyNotebookOperation {
            let aad = try GroupCanonical.fields([GroupCanonical.text("FNB1.OPERATION"), GroupCanonical.text(family.uuidString.lowercased()),
                GroupCanonical.text(String(current.roster.epoch)), current.hash, GroupCanonical.text(op.id.uuidString.lowercased()),
                GroupCanonical.text(author.personID), GroupCanonical.text(device), GroupCanonical.text(String(bytes.count + 28))])
            let cipher = try AES.GCM.seal(bytes, using: SymmetricKey(data: key), authenticating: aad).combined!
            let signed = try GroupCanonical.fields([GroupCanonical.text("FNB1.OPERATION.SIGN"), aad, GroupCanonical.hash(cipher)])
            return .init(familyID: family, keyEpoch: current.roster.epoch, rosterHash: current.hash, operationID: op.id,
                personID: author.personID, deviceID: device, ciphertext: cipher, signature: try identity.signingKey.signature(for: signed))
        }
        var raws: [Data] = [], packets: [EncryptedFamilyNotebookOperation] = []
        for kind in 0..<4 {
            let op = operation(UInt64(kind + 1))
            var json = try JSONSerialization.jsonObject(with: GroupWire.encode(op)) as! [String: Any]
            if kind == 0 {
                var target = json["target"] as! [String: Any]; target["field"] = "futureField"; json["target"] = target
            } else if kind == 1 {
                json["futureOperation"] = ["mode": "future", "largeInteger": "18446744073709551616"]
            } else if kind == 2 {
                json["value"] = ["futureValue": ["_0": ["data": [1, 2, 3]]]]
            } else {
                var target = json["target"] as! [String: Any]; target["collection"] = "futureCollection"; json["target"] = target
            }
            let raw = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            raws.append(raw); packets.append(try sealRaw(raw, identityOperation: op))
        }
        let known = operation(5)
        packets.append(try FamilyNotebookOperationCrypto.seal(known, roster: current, key: key, signingKey: identity.signingKey))
        let relay = Relay(family: family, identity: identity, current: current, key: key, packets: packets)
        let journal = try GroupOperationStore(directory: root.appendingPathComponent("forward-journal"), maximumRecordBytes: 2_100_000)
        func engine(_ local: FamilyNotebookStore) throws -> FamilyNotebookSync {
            let network = try FamilyNotebookTransport(endpoint: URL(string: "https://future.invalid")!, identity: identity, transport: relay, journal: journal)
            return try .init(familyID: family, identity: identity, store: local, network: network, journal: journal, endpointID: "https://future.invalid")
        }
        let first = try await engine(store).synchronize(current: current, history: [:], keys: [1: key])
        try check(first.downloaded == 5 && store.snapshot().operations == [known], "mixed page progresses; future operations not projected")
        try check(try store.snapshot().opaqueOperations.map(\.plaintext) == raws, "future plaintext retained byte-for-byte")
        _ = try store.edit(target: known.target, value: .text("編集後"), author: author)
        let reopened = try FamilyNotebookStore(directory: directory, familyID: family, deviceID: device)
        try check(try reopened.snapshot().opaqueOperations.map(\.plaintext) == raws, "local edit/reopen retains all unknown data")
        let second = try await engine(reopened).synchronize(current: current, history: [:], keys: [1: key])
        try check(second.downloaded == 0, "cursor includes opaque operations")
        await relay.resumeAndLoseReply()
        do { _ = try await engine(reopened).synchronize(current: current, history: [:], keys: [1: key]) }
        catch FamilyNotebookTransportError.unknownOutcome { }
        _ = try await engine(reopened).synchronize(current: current, history: [:], keys: [1: key])
        try check(try reopened.snapshot().opaqueOperations.map(\.plaintext) == raws && reopened.pendingOperations().isEmpty,
                  "known edit upload leaves future originals intact")
        let stateBytes = try Data(contentsOf: directory.appendingPathComponent("family-notebook.json"))
        let state = try JSONDecoder().decode(FamilyNotebookStore.State.self, from: stateBytes)
        let backup = try FamilyNotebookBackup.encode(.init(copies: [.init(id: UUID(), state: state)]))
        let restored = try FamilyNotebookBackup.decode(FamilyNotebookBackup.restored(backup))
        try check(restored.copies[0].state.opaqueOperations?.map(\.plaintext) == raws, "backup and private restore retain opaque bytes")
        var ended = state
        ended.schemaVersion = 3
        ended.sharingEnded = true
        let privateCopy = FamilyNotebookBackup.Copy(id: UUID(), state: ended)
        let localBytes = try FamilyNotebookBackup.encode(.init(copies: [privateCopy]))
        let combined = try FamilyNotebookBackup.restored(backup, keeping: localBytes)
        let restoredCopies = try FamilyNotebookBackup.decode(combined).copies
        try check(restoredCopies.count == 2 && restoredCopies.first(where: { $0.id == privateCopy.id })?.state == ended,
                  "legacy restore preserves the on-device notebook and its contents")
        try check(try Data(contentsOf: directory.appendingPathComponent("family-notebook.json")) == stateBytes,
                  "filtering and restoration never change the on-device source")

        // Unknown semantic content still needs a valid common identity and signature.
        let bad = operation(20)
        var json = try JSONSerialization.jsonObject(with: GroupWire.encode(bad)) as! [String: Any]
        json["futureOperation"] = true
        json["value"] = ["integer": ["_0": 9]] // invalid for KNOWN name field
        let malformed = try sealRaw(JSONSerialization.data(withJSONObject: json), identityOperation: bad)
        await relay.append(malformed)
        let before = try reopened.snapshot()
        do { _ = try await engine(reopened).synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("malformed known value hidden as future") }
        catch FamilyNotebookError.invalidValue { }
        try check(try reopened.snapshot() == before, "failed page leaves original state intact")
        let tampered = EncryptedFamilyNotebookOperation(familyID: packets[0].familyID, keyEpoch: packets[0].keyEpoch,
            rosterHash: packets[0].rosterHash, operationID: packets[0].operationID, personID: packets[0].personID,
            deviceID: packets[0].deviceID, ciphertext: packets[0].ciphertext, signature: Data(repeating: 0, count: 64))
        do { _ = try FamilyNotebookOperationCrypto.openRetaining(tampered, roster: current, key: key); throw Failure.check("unsigned future accepted") }
        catch FamilyNotebookCryptoError.untrusted { }
        print("Family forward format: mixed page, exact bytes, edit/upload/reopen, backup/restore, cursor, malformed known value and forged future rejection passed")
    }

}
