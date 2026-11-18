import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lostReply }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private actor Relay: GroupHTTPTransport {
    let family: UUID, identity: GroupDeviceIdentity, current: VerifiedFamilyNotebookRoster, key: Data
    var packets: [EncryptedFamilyNotebookOperation]
    var bodies: [UUID: Data] = [:]
    var paused = true, loseNext = false, tamper = false
    /// 11/16: every upload gets no answer; or the server refuses one operation.
    var failUploads = false, refused: UUID?
    var uploadedIDs: [UUID] = []
    func setFailUploads(_ value: Bool) { failUploads = value }
    func refuse(_ id: UUID?) { refused = id }
    func uploads() -> [UUID] { uploadedIDs }
    var requiredVersion: Int? = nil
    var requests = 0
    func requireVersion(_ version: Int) { requiredVersion = version }
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
                    let writeContract: FamilyNotebookWriteContract.Capability?
                }
                return .init(status: 200, data: try GroupWire.encode(State(familyID: family, roster: current.packet, writeContract: requiredVersion.map { .init(supportedVersion: $0, requiredVersion: $0) })))
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
        if failUploads { throw Failure.lostReply }
        if upload.operationID == refused {
            return .init(status: 400, data: Data("{\"error\":{\"code\":\"family_notebook_invalid_operation\"}}".utf8))
        }
        if requiredVersion == nil {
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            try check(Set(object.keys) == Set(["operationId", "expectedGeneration", "expectedEpoch", "payload"]), "old Worker accepts only the pre-contract fields")
        }
        if let version = requiredVersion {
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            if (object["writeContract"] as? [String: Any])?["version"] as? Int != version {
                return .init(status: 409, data: Data("{\"error\":{\"code\":\"photo_protocol_upgrade_required\"}}".utf8))
            }
        }
        _ = try FamilyNotebookOperationCrypto.openRetaining(upload.payload, roster: current, key: key)
        if let old = bodies[upload.operationID] { try check(old == body, "restart sent different ciphertext for an unknown outcome") }
        else { bodies[upload.operationID] = body; packets.append(upload.payload); uploadedIDs.append(upload.operationID) }
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
        if let phase = ProcessInfo.processInfo.environment["PHOTO_COMPAT_PHASE"] {
            try photoCompatibility(phase); return
        }
        if let phase = ProcessInfo.processInfo.environment["POSITION_PHASE"] {
            try await positionCompatibility(phase); return
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
        try await sendFailures(root: root, identity: identity, current: current, key: key, author: author)
        try sendHealthRule()
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

        // Unknown versions still download history, but retain edits without sending/ACK.
        await relay.requireVersion(2)
        let futurePending = try local.edit(target: .init(familyCatID: UUID(), field: .name), value: .text("pending protocol update"), author: author)
        do { _ = try await engine(local).synchronize(current: current, history: [:], keys: [1:key]); throw Failure.check("unknown protocol wrote") }
        catch FamilyNotebookTransportError.upgradeRequired { }
        try check(try local.pendingOperations().contains { $0.id == futurePending.id }, "unknown version retains pending edit")
        await relay.requireVersion(1)
        _ = try await engine(local).synchronize(current: current, history: [:], keys: [1:key])
        try check(try local.pendingOperations().isEmpty, "known version resumes pending edit")

        // An older/empty restored notebook must not trust the newer sidecar
        // cursor. Refill the complete history without deleting either copy.
        let older = try FamilyNotebookStore(directory: root.appendingPathComponent("older-copy"), familyID: family, deviceID: device)
        let refilled = try await engine(older).synchronize(current: current, history: [:], keys: [1: key])
        try check(refilled.downloaded == 3 && older.snapshot().operations.count == 3, "older local copy refills all history")
        try check(try local.snapshot().operations.count == 3, "original retained after refilling another copy")

        let tampered = try FamilyNotebookStore(directory: root.appendingPathComponent("tamper-check"), familyID: family, deviceID: device)
        await relay.setTamper()
        do { _ = try await engine(tampered).synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("forged history accepted") }
        catch FamilyNotebookCryptoError.untrusted { }
        try check(try tampered.snapshot().operations.isEmpty, "forged page never partially merges")

        // The ended file itself, so this check also builds against the older
        // stores in ci/fixtures (11/18: the current one records a reason).
        let localFile = local.localDirectory.appendingPathComponent("family-notebook.json")
        var endedState = try JSONSerialization.jsonObject(with: Data(contentsOf: localFile)) as! [String: Any]
        if endedState["schemaVersion"] as? Int == 1 { endedState["schemaVersion"] = 2 }
        endedState["sharingEnded"] = true
        try JSONSerialization.data(withJSONObject: endedState, options: .sortedKeys).write(to: localFile, options: .atomic)
        try check(try local.snapshot().sharingEnded, "the departed file reads as ended")
        let requestCount = await relay.count()
        do { _ = try await sync.synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("departed notebook sent traffic") }
        catch FamilyNotebookError.sharingEnded { }
        try check(await relay.count() == requestCount, "ended participation sends nothing")
        try check(try local.snapshot().operations.count == 3, "departure retains every original")
        print("Family notebook sync: authenticated encrypted merge, pause/resume, lost ACK restart, older-copy refill, tamper and departure retention passed")
    }
    /// 11/16: a failure to send was dropped without a trace, and one that
    /// could never go stopped everything after it.
    private static func sendFailures(root: URL, identity: GroupDeviceIdentity, current: VerifiedFamilyNotebookRoster,
                                     key: Data, author: FamilyNotebookAuthor) async throws {
        let family = current.roster.familyID, device = try identity.deviceID
        let fromFamily = FamilyNotebookOperation(familyID: family, target: .init(familyCatID: UUID(), field: .name),
            value: .text("合成の家族が書いた"), version: .init(clock: 1, deviceID: device, operationID: UUID()),
            author: author, editedAt: Date())
        let relay = try Relay(family: family, identity: identity, current: current, key: key,
            packets: [FamilyNotebookOperationCrypto.seal(fromFamily, roster: current, key: key, signingKey: identity.signingKey)])
        await relay.activate()
        let store = try FamilyNotebookStore(directory: root.appendingPathComponent("send-failures"), familyID: family, deviceID: device)
        func engine() throws -> FamilyNotebookSync {
            let journal = try GroupOperationStore(directory: root.appendingPathComponent("send-failures-journal"), maximumRecordBytes: 2_100_000)
            let network = try FamilyNotebookTransport(endpoint: URL(string: "https://family.invalid")!, identity: identity, transport: relay, journal: journal)
            return try .init(familyID: family, identity: identity, store: store, network: network, journal: journal, endpointID: "https://family.invalid")
        }
        let cat = UUID()
        let first = try store.edit(target: .init(familyCatID: cat, field: .water), value: .text("合成の1つ目"), author: author)
        let second = try store.edit(target: .init(familyCatID: cat, field: .litter), value: .text("合成の2つ目"), author: author)

        // (d) No answer to any upload: the order is kept, nothing is lost.
        await relay.setFailUploads(true)
        do { _ = try await engine().synchronize(current: current, history: [:], keys: [1: key]); throw Failure.check("a lost upload passed") }
        catch FamilyNotebookTransportError.unknownOutcome {
            try check(FamilyNotebookSendFailure.kind(of: FamilyNotebookTransportError.unknownOutcome) == .network, "no answer is the network")
        }
        // (a) What the family wrote still came in before the sending failed.
        try check(try store.snapshot().operations.contains { $0.id == fromFamily.id }, "the family's writing arrives while sending fails")
        // (b) This iPhone's writing stays, in its order.
        try check(try store.pendingOperations().map(\.id) == [first.id, second.id], "unsent writing stays in the outbox, in order")
        try check(await relay.uploads().isEmpty, "nothing after the failed one was tried")
        await relay.setFailUploads(false)
        let fixed = try await engine().synchronize(current: current, history: [:], keys: [1: key])
        try check(fixed.uploaded == 2 && fixed.heldBack == 0 && fixed.pending == 0, "once it answers, everything goes")
        try check(await relay.uploads() == [first.id, second.id], "and in the order it was written")

        // (c) The server refuses one: it is set aside (kept), the next goes.
        let third = try store.edit(target: .init(familyCatID: cat, field: .temperament), value: .text("合成の3つ目"), author: author)
        let fourth = try store.edit(target: .init(familyCatID: cat, field: .coat), value: .text("合成の4つ目"), author: author)
        await relay.refuse(third.id)
        let refused = try await engine().synchronize(current: current, history: [:], keys: [1: key])
        try check(refused.uploaded == 1 && refused.heldBack == 1 && refused.heldFailure == .rejected,
                  "one refused writing is set aside and the next is sent")
        try check(try store.pendingOperations().map(\.id) == [third.id], "the refused writing is kept, not dropped")
        try check(try await engine().held() == [third.id], "the mark keeps only its ID")
        let later = try await engine().synchronize(current: current, history: [:], keys: [1: key])
        try check(later.uploaded == 0 && later.heldBack == 1, "a later pass leaves it aside (no repeated refusals)")
        let fifth = try store.edit(target: .init(familyCatID: cat, field: .marks), value: .text("合成の5つ目"), author: author)
        let around = try await engine().synchronize(current: current, history: [:], keys: [1: key])
        let sentSoFar = await relay.uploads()
        try check(around.uploaded == 1 && sentSoFar.last == fifth.id, "new writing goes around it")
        // The person's 「もう一度」, and the server takes it now.
        await relay.refuse(nil)
        let retried = try await engine().synchronize(current: current, history: [:], keys: [1: key], retryHeld: true)
        try check(retried.uploaded == 1 && retried.heldBack == 0 && retried.pending == 0, "もう一度 sends the set-aside writing")
        try check(try await engine().held().isEmpty, "and the mark goes")
        _ = fourth

        // Which failures wait in order, which set one aside.
        let mine = first
        let wait: [Error] = [FamilyNotebookTransportError.unknownOutcome, FamilyNotebookTransportError.authenticationRequired,
            FamilyNotebookTransportError.notMember, FamilyNotebookTransportError.unavailable, FamilyNotebookTransportError.stale,
            FamilyNotebookTransportError.upgradeRequired, FamilyNotebookTransportError.server(code: "rate_limited", status: 429),
            FamilyNotebookTransportError.server(code: "x", status: 503), FamilyNotebookTransportError.server(code: "x", status: 403),
            FamilyNotebookSyncError.missingKey(epoch: 1), FamilyNotebookCryptoError.untrusted, FamilyNotebookError.sharingEnded]
        for error in wait {
            try check(FamilyNotebookSendFailure.disposition(of: error, operation: mine, deviceID: device, personID: identity.personID) == .waitInOrder,
                      "waits in order: \(error)")
        }
        let aside: [Error] = [FamilyNotebookTransportError.server(code: "x", status: 400), FamilyNotebookTransportError.server(code: "x", status: 413),
            FamilyNotebookTransportError.idempotencyConflict, FamilyNotebookCryptoError.tooLarge, FamilyNotebookError.invalidOperation]
        for error in aside {
            try check(FamilyNotebookSendFailure.disposition(of: error, operation: mine, deviceID: device, personID: identity.personID) == .setAside,
                      "set aside: \(error)")
        }
        try check(FamilyNotebookSendFailure.disposition(of: FamilyNotebookCryptoError.untrusted, operation: mine,
                                                        deviceID: "another-device", personID: identity.personID) == .setAside,
                  "writing of another device can never be signed here: set aside")
        try check(FamilyNotebookSendFailure.kind(of: FamilyNotebookTransportError.server(code: "rate_limited", status: 429)) == .rateLimited, "429")
        try check(FamilyNotebookSendFailure.kind(of: FamilyNotebookTransportError.stale) == .generation, "stale generation")
        try check(FamilyNotebookSendFailure.kind(of: FamilyNotebookSyncError.missingKey(epoch: 2)) == .keys, "keys")
        try check(FamilyNotebookSendFailure.code(kind: "rejected", unsent: 3) == "RJ-3"
                  && FamilyNotebookSendFailure.code(kind: nil, unsent: 1) == "00-1",
                  "the code: the kind's short symbol and the number unsent")
        try check(Set(FamilyNotebookSendFailure.allCases.map(\.code)).count == FamilyNotebookSendFailure.allCases.count, "one code per kind")
    }

    /// (e) The line 「家族に届けられていない書き込みがあります。」, on a synthetic clock.
    private static func sendHealthRule() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var health = FamilyNotebookSendHealth()
        health.record(.sent(heldBack: 0, failure: nil), unsent: 0, at: t)
        try check(!health.showsLine(unsent: 0, now: t), "nothing while all is sent")
        health.record(.failed("network"), unsent: 2, at: t)
        health.record(.failed("network"), unsent: 2, at: t.addingTimeInterval(5))
        health.record(.failed("network"), unsent: 2, at: t.addingTimeInterval(10))
        try check(!health.showsLine(unsent: 2, now: t.addingTimeInterval(10)), "three quick failures (a key change) do not show it yet")
        health.record(.failed("network"), unsent: 2, at: t.addingTimeInterval(70))
        try check(health.showsLine(unsent: 2, now: t.addingTimeInterval(70)), "failing for a minute, three times: the line shows")
        try check(health.last == FamilyNotebookSendHealth.Failure(kind: "network", at: t.addingTimeInterval(70)), "the last kind and time only")
        health.record(nil, unsent: 2, at: t.addingTimeInterval(80))
        try check(health.showsLine(unsent: 2, now: t.addingTimeInterval(80)), "a read that did not get to sending changes nothing")
        health.record(.sent(heldBack: 0, failure: nil), unsent: 0, at: t.addingTimeInterval(90))
        try check(!health.showsLine(unsent: 0, now: t.addingTimeInterval(90)) && health.failures == 0, "sent: the line goes")
        // Ten minutes of failing, whatever the count.
        health.record(.failed("keys"), unsent: 1, at: t.addingTimeInterval(100))
        try check(!health.showsLine(unsent: 1, now: t.addingTimeInterval(100)), "one failure: nothing yet")
        health.record(.failed("keys"), unsent: 1, at: t.addingTimeInterval(700))
        try check(health.showsLine(unsent: 1, now: t.addingTimeInterval(700)), "ten minutes: the line shows")
        // Set aside counts as not reaching the family.
        var aside = FamilyNotebookSendHealth()
        for second in [0.0, 30, 60] { aside.record(.sent(heldBack: 1, failure: "rejected"), unsent: 1, at: t.addingTimeInterval(second)) }
        try check(aside.showsLine(unsent: 1, now: t.addingTimeInterval(60)) && aside.last?.kind == "rejected", "set-aside writing shows the line")
        aside.record(.sent(heldBack: 0, failure: nil), unsent: 0, at: t.addingTimeInterval(90))
        try check(!aside.showsLine(unsent: 0, now: t.addingTimeInterval(90)), "sent again: gone")
        let saved = try JSONDecoder().decode(FamilyNotebookSendHealth.self, from: JSONEncoder().encode(health))
        try check(saved == health, "kept on this iPhone as it was")
        let text = String(decoding: try JSONEncoder().encode(health), as: UTF8.self)
        try check(!text.contains("合成"), "no content is kept")
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

    // 11/15: the family order of cats (`position`), run with the frozen
    // readers (before #985, and main before the order) and the new one.
    // The old binaries do not know the field: it is reached by its raw name.
    private static func photoCompatibility(_ phase: String) throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTO_COMPAT_ROOT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct Fixture: Codable { let family: UUID; let cat: UUID; let device: String; let author: FamilyNotebookAuthor; let text: String }
        let file = root.appendingPathComponent("fixture.json")
        let f: Fixture
        if phase == "new-write" {
            let identity = GroupDeviceIdentity.firstDevice()
            let reference = FamilyNotebookRepresentativePhotoReference(schemaVersion: 1, assetID: UUID(), slotID: UUID(), revision: 1,
                keyEpoch: 1, rosterHash: Data(repeating: 2, count: 32), ciphertextSHA256: Data(repeating: 3, count: 32),
                ciphertextBytes: 100, contentKey: Data(repeating: 4, count: 32), mediaType: "image/jpeg", pixelWidth: 100, pixelHeight: 100)
            try reference.validate()
            f = Fixture(family: UUID(), cat: UUID(), device: try identity.deviceID,
                author: .init(personID: identity.personID, displayName: "Synthetic"), text: String(decoding: try GroupWire.encode(reference), as: UTF8.self))
            try JSONEncoder().encode(f).write(to: file)
        } else { f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file)) }
        let store = try FamilyNotebookStore(directory: root.appendingPathComponent("store"), familyID: f.family, deviceID: f.device)
        let field = FamilyNotebookField(rawValue: "representativePhoto")
        if phase == "new-write" {
            guard let field else { throw Failure.check("new photo field") }
            _ = try store.edit(target: .init(familyCatID: f.cat, field: .name), value: .text("Synthetic"), author: f.author)
            _ = try store.edit(target: .init(familyCatID: f.cat, field: field), value: .text(f.text), author: f.author)
        } else if phase == "old-edit" {
            try check(try store.snapshot().opaqueOperations.count == 1, "frozen reader preserves photo reference")
            _ = try store.edit(target: .init(familyCatID: f.cat, field: .name), value: .text("old edit"), author: f.author)
        } else {
            guard let field else { throw Failure.check("new photo field") }
            let snapshot = try store.snapshot()
            try check(snapshot.fieldState(for: .init(familyCatID: f.cat, field: field))?.operation.value == .text(f.text), "reference restored exactly")
            try check(snapshot.fieldState(for: .init(familyCatID: f.cat, field: .name))?.operation.value == .text("old edit"), "old edit retained")
            try check(try store.pendingOperations().filter { $0.target.field == field }.count == 1, "unsent photo restored once")
        }
        print("photo compatibility: \(phase) PASS")
    }

    private static func positionCompatibility(_ phase: String) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSITION_ROOT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct Fixture: Codable { let identity: GroupDeviceIdentity; let family: UUID; let cats: [UUID] }
        let fixtureURL = root.appendingPathComponent("fixture.json")
        let f: Fixture
        if phase == "new-write" {
            var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
            f = Fixture(identity: identity, family: UUID(), cats: [UUID(), UUID(), UUID()])
            try JSONEncoder().encode(f).write(to: fixtureURL)
        } else { f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)) }
        let identity = f.identity, device = try identity.deviceID, family = f.family
        let author = FamilyNotebookAuthor(personID: identity.personID, displayName: "合成")
        let key = Data(repeating: 23, count: 32)
        let rosterURL = root.appendingPathComponent("roster.json")
        let signed: SignedFamilyNotebookRoster
        if phase == "new-write" {
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
        let position = FamilyNotebookField(rawValue: "position")
        func place(_ cat: UUID, in snapshot: FamilyNotebookSnapshot) -> Int? {
            guard let position, let state = snapshot.fieldState(for: .init(familyCatID: cat, field: position)), !state.isDeleted,
                  case .integer(let value) = state.operation.value else { return nil }
            return value
        }
        if phase == "new-write" {
            guard let position else { throw Failure.check("the new reader knows position") }
            var clock: UInt64 = 0
            func op(_ cat: UUID, _ field: FamilyNotebookField, _ value: FamilyNotebookValue) -> FamilyNotebookOperation {
                clock += 1
                return FamilyNotebookOperation(familyID: family, target: .init(familyCatID: cat, field: field), value: value,
                    version: .init(clock: clock, deviceID: device, operationID: UUID()), author: author, editedAt: Date())
            }
            // A and B share a place (a tie); C has a far place an old app cannot read.
            var ops = f.cats.enumerated().map { op($0.element, .name, .text("猫" + String($0.offset))) }
            ops += [op(f.cats[0], position, .integer(1)), op(f.cats[1], position, .integer(1)), op(f.cats[2], position, .integer(5_000))]
            packets = try ops.map { try FamilyNotebookOperationCrypto.seal($0, roster: current, key: key, signingKey: identity.signingKey) }
        } else { packets = try JSONDecoder().decode([EncryptedFamilyNotebookOperation].self, from: Data(contentsOf: packetsURL)) }
        let store = try FamilyNotebookStore(directory: root.appendingPathComponent("store"), familyID: family, deviceID: device)
        let relay = Relay(family: family, identity: identity, current: current, key: key, packets: packets)
        await relay.activate()
        let journal = try GroupOperationStore(directory: root.appendingPathComponent("journal-" + phase), maximumRecordBytes: 2_100_000)
        let network = try FamilyNotebookTransport(endpoint: URL(string: "https://compat.invalid")!, identity: identity, transport: relay, journal: journal)
        let engine = try FamilyNotebookSync(familyID: family, identity: identity, store: store, network: network, journal: journal, endpointID: "https://compat.invalid")
        if phase == "old-edit" {
            try check(position == nil, "the frozen reader does not know position")
            try check(try store.snapshot().opaqueOperations.count == 4, "the old reader keeps every place, received and pending, as it is")
            // Ordinary edits on the old app: a name, and taking cat B out of the notebook.
            _ = try store.edit(target: .init(familyCatID: f.cats[0], field: .name), value: .text("古い版の編集"), author: author)
            _ = try store.edit(target: .init(familyCatID: f.cats[1], field: .sharingEnded), value: nil, author: author)
        }
        _ = try await engine.synchronize(current: current, history: [:], keys: [1: key])
        if phase == "new-write" {
            guard let position else { throw Failure.check("the new reader knows position") }
            let snapshot = try store.snapshot()
            try check(place(f.cats[2], in: snapshot) == 5_000 && place(f.cats[0], in: snapshot) == 1, "the new reader receives places")
            // A new place written on this phone, not sent yet.
            _ = try store.edit(target: .init(familyCatID: f.cats[2], field: position), value: .integer(0), author: author)
        }
        if phase == "old-edit" {
            let state = try JSONDecoder().decode(FamilyNotebookStore.State.self, from: Data(contentsOf: root.appendingPathComponent("store/family-notebook.json")))
            let backup = try FamilyNotebookBackup.encode(.init(copies: [.init(id: UUID(), state: state)]))
            let restored = try FamilyNotebookBackup.decode(FamilyNotebookBackup.restored(backup))
            try check(restored.copies[0].state.opaqueOperations?.count == 4, "old backup and restore keep every place")
            let dir = root.appendingPathComponent("restored")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(restored.copies[0].state).write(to: dir.appendingPathComponent("family-notebook.json"))
        }
        if phase == "new-verify" {
            let snapshot = try store.snapshot()
            try check(place(f.cats[2], in: snapshot) == 0, "the place written before the old app ran is back, and the newest wins")
            try check(place(f.cats[0], in: snapshot) == 1, "a tied place is kept as written")
            try check(snapshot.operations.contains { $0.value == .text("古い版の編集") }, "the old app's name edit survives")
            try check(snapshot.unsharedCatIDs == [f.cats[1]], "the cat the old app took out stays out")
            try check(try store.pendingOperations().isEmpty, "the pending place is sent after the old app ran")
            let restored = try FamilyNotebookStore(directory: root.appendingPathComponent("restored"), familyID: family, deviceID: device)
            try check(place(f.cats[2], in: try restored.snapshot()) == 0, "the new app opens the old app's restored backup with its places")
            try check(try restored.pendingOperations().isEmpty, "a restored private copy never sends")
        }
        try JSONEncoder().encode(await relay.savedPackets()).write(to: packetsURL)
        print("Position compatibility phase passed: " + phase)
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
