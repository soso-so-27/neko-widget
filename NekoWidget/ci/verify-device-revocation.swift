import CryptoKit
import Foundation

// 11/20 (#1102): a device taken off by another iPhone of the same person. The
// relay answers 401 `invalid_authentication` with `reason: device_revoked`
// only to a request signed by that pair. This checks the client side over a
// scripted relay: the decoding, the pair, the mark before anything else,
// every automatic path refusing under the mark, the notebook's entrance, the
// old relay's plain 401 unchanged, and the person's own new device.
// Synthetic keys only; no Keychain, network or photo.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws { if !value { throw Failure.check(name) } }

/// One ordered list of what happened (the relay's sends, the mark's write, the
/// notebook's letting go), so "the mark first" is checked as an order.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class MemorySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    let events: Events?
    init(events: Events? = nil) { self.events = events }
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }
        values[account] = data
        if account.hasPrefix(GroupDeviceRevocation.accountPrefix) { events?.add("mark") }
    }
    func accounts(prefix: String) throws -> [String] { lock.lock(); defer { lock.unlock() }; return values.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

private let revokedBody = Data(#"{"error":{"code":"invalid_authentication","message":"Group authentication failed.","reason":"device_revoked"}}"#.utf8)
private let plainBody = Data(#"{"error":{"code":"invalid_authentication","message":"Group authentication failed."}}"#.utf8)

/// Answers by a rule per request; records every send.
private final class ScriptedRelay: GroupHTTPTransport, @unchecked Sendable {
    enum Answer { case reply(Int, Data), offline }
    private let lock = NSLock()
    private var rule: @Sendable (URLRequest) -> Answer
    private(set) var sends: [(method: String, path: String, device: String?)] = []
    let events: Events
    init(events: Events, rule: @escaping @Sendable (URLRequest) -> Answer) { self.events = events; self.rule = rule }
    func answer(_ next: @escaping @Sendable (URLRequest) -> Answer) { lock.lock(); rule = next; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return sends.count }
    var log: [(method: String, path: String, device: String?)] { lock.lock(); defer { lock.unlock() }; return sends }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let path = request.url?.path ?? ""
        lock.lock()
        sends.append((request.httpMethod ?? "GET", path, request.value(forHTTPHeaderField: "Neko-Device-Id")))
        let current = rule
        lock.unlock()
        events.add("send " + path)
        switch current(request) {
        case .reply(let status, let data): return GroupHTTPReply(status: status, data: data)
        case .offline: throw GroupClientError.offline
        }
    }
}

private func registered(_ identity: GroupDeviceIdentity) -> GroupDeviceIdentity {
    var value = identity; value.registered = true; return value
}

private let emptyList = Data(#"{"items":[],"next":null}"#.utf8)

/// The list, and a new device's registration (challenge, identity).
private func healthy(_ request: URLRequest) -> ScriptedRelay.Answer {
    let path = request.url?.path ?? ""
    if path == "/v3/group-identities/challenges" {
        return .reply(201, Data(#"{"challengeId":"9b2a3c8e-6f0e-4d36-8a1c-6f7c1d1f0a01","challenge":"c2ludGhldGlj","expiresAt":4102444800}"#.utf8))
    }
    if path == "/v3/group-identities", let body = request.httpBody,
       let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let person = object["personPublicKey"] as? String, let signing = object["signingPublicKey"] as? String,
       let hpke = object["hpkePublicKey"] as? String,
       let personID = try? GroupWire.base64(GroupCanonical.hash(GroupWire.bytes(person, count: 32))),
       let deviceID = try? GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([GroupWire.bytes(signing, count: 32), GroupWire.bytes(hpke, count: 32)]))) {
        return .reply(201, Data(#"{"personId":"\#(personID)","deviceId":"\#(deviceID)","state":"registered"}"#.utf8))
    }
    if path == "/v3/group-windows/list" { return .reply(200, emptyList) }
    if path == "/v3/group-identities/deletion-requests", let body = request.httpBody,
       let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = object["operationId"] as? String {
        return .reply(202, Data(#"{"protocolVersion":3,"requestId":"\#(id)","state":"processing","acceptedAt":1763600000,"completedAt":null}"#.utf8))
    }
    return .reply(404, Data(#"{"error":{"code":"not_found"}}"#.utf8))
}

@main
enum DeviceRevocationChecks {
    @MainActor static func main() async {
        do {
            try decoding()
            try await windowClient()
            try await notebookTransport()
            try identityChoice()
            try await notebookService()
            try sources()
            print("Device revocation checks passed")
        } catch {
            FileHandle.standardError.write(Data("Device revocation check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static let endpoint = URL(string: "https://group.invalid")!

    // MARK: 1. The answer and the pair

    static func decoding() throws {
        let says = GroupDeviceRevocation.says
        try check(says(.init(status: 401, data: revokedBody)), "401 + invalid_authentication + device_revoked")
        try check(!says(.init(status: 401, data: plainBody)), "an older relay's plain 401")
        try check(!says(.init(status: 401, data: Data(#"{"error":{"code":"replay","reason":"device_revoked"}}"#.utf8))), "another code")
        try check(!says(.init(status: 401, data: Data(#"{"error":{"code":"invalid_authentication","reason":"other"}}"#.utf8))), "another reason")
        for status in [200, 403, 404, 409, 429, 500, 503] {
            try check(!says(.init(status: status, data: revokedBody)), "status \(status) with the same body")
        }
        try check(!says(.init(status: 401, data: Data("not json".utf8))), "an unreadable body")
        try check(!says(.init(status: 401, data: Data(#"{"code":"invalid_authentication","reason":"device_revoked"}"#.utf8))), "not under error")

        let a = registered(.firstDevice()), b = registered(.firstDevice())
        let signed = try GroupHTTPRequest.make(endpoint: endpoint, path: "/v3/group-windows/list", body: Data("{}".utf8), identity: a)
        let reply = GroupHTTPReply(status: 401, data: revokedBody)
        let pair = GroupDeviceRevocation.pair(reply, request: signed, identity: a, endpoint: endpoint)
        try check(pair == .init(personID: a.personID, deviceID: try a.deviceID), "the pair that signed")
        try check(GroupDeviceRevocation.pair(reply, request: signed, identity: b, endpoint: endpoint) == nil, "another pair is never named")
        try check(GroupDeviceRevocation.pair(reply, request: signed, identity: nil, endpoint: endpoint) == nil, "an unsigned request")
        try check(GroupDeviceRevocation.pair(reply, request: signed, identity: a, endpoint: URL(string: "https://other.invalid")!) == nil,
                  "only the configured endpoint")
        try check(GroupDeviceRevocation.pair(.init(status: 401, data: plainBody), request: signed, identity: a, endpoint: endpoint) == nil,
                  "a plain 401 names nobody")

        let store = MemorySecrets()
        try check(!(try GroupDeviceRevocation.isMarked(a, in: store)), "nothing marked")
        try GroupDeviceRevocation.mark(.init(personID: a.personID, deviceID: try a.deviceID), in: store)
        let markedA = try GroupDeviceRevocation.isMarked(a, in: store), markedB = try GroupDeviceRevocation.isMarked(b, in: store)
        try check(markedA && !markedB, "the mark is per pair")
        try store.write(Data("x".utf8), account: GroupDeviceRevocation.account(try b.deviceID), createOnly: false)
        try check(try GroupDeviceRevocation.isMarked(b, in: store), "an unreadable mark counts")
    }

    // MARK: 2. まど (ProductionGroupWindowClient)

    static func windowClient() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("device-revocation-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 2a. An older relay: plain 401s change nothing.
        do {
            let me = registered(.firstDevice()), store = MemorySecrets(), events = Events()
            try store.write(GroupWire.encode(me), account: "identity", createOnly: true)
            let relay = ScriptedRelay(events: events) { _ in .reply(401, plainBody) }
            let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: store, transport: relay,
                outboxDirectory: folder.appendingPathComponent("plain"))
            for _ in 0..<2 {
                do { _ = try await client.windows(); throw Failure.check("a plain 401 lists nothing") }
                catch GroupClientError.authenticationRequired {}
            }
            try check(relay.count == 2, "a plain 401 leaves the next read as before (got \(relay.count))")
            try check(!(try GroupDeviceRevocation.isMarked(me, in: store)), "a plain 401 marks nothing")
            let usable = try await client.hasExistingIdentity(), marked = try await client.usualRevoked()
            try check(usable && !marked, "the identity stays usable")
            // Timeouts and 5xx with the same body: nothing either.
            relay.answer { _ in .offline }
            do { _ = try await client.windows() } catch GroupClientError.offline {}
            relay.answer { _ in .reply(503, revokedBody) }
            do { _ = try await client.windows() } catch {}
            try check(!(try GroupDeviceRevocation.isMarked(me, in: store)), "an offline or 5xx answer marks nothing")
        }

        // 2b. The reasoned answer: the mark first, then nothing automatic.
        let me = registered(.firstDevice()), store = MemorySecrets(), events = Events()
        let marks = MemorySecrets(events: events)
        try store.write(GroupWire.encode(me), account: "identity", createOnly: true)
        let relay = ScriptedRelay(events: events) { _ in .reply(401, revokedBody) }
        let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: store, transport: relay,
            outboxDirectory: folder.appendingPathComponent("revoked"), revocations: marks)
        do { _ = try await client.windows(); throw Failure.check("a revoked device lists nothing") }
        catch GroupClientError.authenticationRequired { events.add("error") }
        try check(events.all == ["send /v3/group-windows/list", "mark", "error"], "one send, the mark, then the error (got \(events.all))")
        try check(try GroupDeviceRevocation.isMarked(me, in: marks), "the pair is marked")
        try check(!(try GroupDeviceRevocation.isMarked(me, in: store)), "the mark is in the revocation store")

        let sent = relay.count
        try check(try await client.windows().isEmpty, "the list is the existing empty state")
        let opens = try await client.hasExistingIdentity(), local = try await client.hasLocalGroupState()
        try check(!opens && !local, "no identity to open with, no local state")
        try check(!(try await client.acceptsNotification(windowID: GroupWire.randomID(), requestID: nil, kind: "photo_added")), "no notification route")
        do { _ = try await client.familyNotebookIdentity(); throw Failure.check("the notebook never signs with it") }
        catch GroupClientError.authenticationRequired {}
        do { _ = try await client.familyPhotoReportReplies(); throw Failure.check("replies are not read") }
        catch GroupClientError.authenticationRequired {}
        try await client.updatePushSubscriptions(deviceToken: Data(repeating: 7, count: 32), environment: "production")
        _ = try await client.reconcileAdmissions()
        await client.backfillAnchorReceipts()
        do { _ = try await client.createWindow(name: "合成", operationID: UUID()) } catch {}
        try check(relay.count == sent, "no automatic or registering request under the mark (got \(relay.log.dropFirst(sent).map { $0.path }))")
        let kept = try store.read("identity").map { try GroupWire.decode(GroupDeviceIdentity.self, $0) }
        let keptDevice = try kept?.deviceID, myDevice = try me.deviceID
        try check(kept?.personPrivateKey == me.personPrivateKey && keptDevice == myDevice && kept?.registered == true,
                  "the identity and the person key stay as they were (not cleared, not re-registered)")

        // 2c. A late answer about another pair names that pair only.
        do {
            let usual = registered(.firstDevice()), other = registered(.firstDevice())
            let usualStore = MemorySecrets(), otherMarks = MemorySecrets()
            try usualStore.write(GroupWire.encode(usual), account: "identity", createOnly: true)
            let otherDevice = try other.deviceID
            let mixed = ScriptedRelay(events: Events()) { request in
                request.value(forHTTPHeaderField: "Neko-Device-Id") == otherDevice ? .reply(401, revokedBody) : healthy(request)
            }
            let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: usualStore, transport: mixed,
                outboxDirectory: folder.appendingPathComponent("late"), revocations: otherMarks)
            do { _ = try await client.familyPhotoReportReplies(as: other) } catch {}
            try check(try GroupDeviceRevocation.isMarked(other, in: otherMarks), "the pair that signed is marked")
            try check(!(try GroupDeviceRevocation.isMarked(usual, in: otherMarks)), "the usual pair is not")
            let listed = try await client.windows()
            try check(listed.isEmpty && mixed.log.last?.path == "/v3/group-windows/list", "the usual pair still reads (nothing it shows was closed)")
        }

        // 2d. The person's own 作る / 参加: a fresh start, a new person and device.
        do {
            try check(!(try await ProductionGroupWindowClient(endpoint: endpoint, secrets: MemorySecrets(), transport: relay,
                outboxDirectory: folder.appendingPathComponent("none")).startFreshAfterRevocation()), "nothing to restart without an identity")
            relay.answer(healthy)
            let before = relay.count
            try check(try await client.startFreshAfterRevocation(), "a revoked identity starts fresh")
            try check(!(try await client.startFreshAfterRevocation()), "only once")
            let fresh = try required(try store.read("identity").map { try GroupWire.decode(GroupDeviceIdentity.self, $0) })
            let freshDevice = try fresh.deviceID, oldDevice = try me.deviceID
            try check(fresh.personID != me.personID && fresh.personPrivateKey != me.personPrivateKey && freshDevice != oldDevice
                      && !fresh.registered, "a new person and device, not yet registered")
            let aside = try store.read(ProductionGroupWindowClient.setAsidePrefix + oldDevice)
            try check(aside != nil, "the old identity, person key included, is set aside")
            let roots = try ProductionGroupWindowClient.setAsideRoots(in: store)
            try check(roots == [me.personPrivateKey!], "機種変更 is offered the set-aside person")
            let stillMarked = try GroupDeviceRevocation.isMarked(me, in: marks)
            try check(stillMarked, "the old pair's mark stays")
            try check(relay.count == before, "starting fresh itself sends nothing")
            try check(try await client.windows().isEmpty, "the new person lists")
            let paths = relay.log.dropFirst(before).map { $0.path }
            try check(paths == ["/v3/group-identities/challenges", "/v3/group-identities", "/v3/group-windows/list"],
                      "registered as a first device registers, then read (got \(paths))")
            try check(relay.log.last?.device == freshDevice, "signed by the new device")
            try check(try await client.hasExistingIdentity(), "the new person opens")
            let personNow = try await client.existingPersonID()
            try check(personNow == fresh.personID, "the usual identity is the new person")
        }

        // 2e. A device linked without the person key starts fresh the same way.
        do {
            let linked = GroupDeviceIdentity(personPrivateKey: nil, personPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, windowCertificates: [:], registered: true)
            let linkedStore = MemorySecrets()
            try linkedStore.write(GroupWire.encode(linked), account: "identity", createOnly: true)
            try GroupDeviceRevocation.mark(.init(personID: linked.personID, deviceID: try linked.deviceID), in: linkedStore)
            let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: linkedStore, transport: relay,
                outboxDirectory: folder.appendingPathComponent("linked"))
            try check(try await client.startFreshAfterRevocation(), "a linked device starts fresh too")
            let roots = try ProductionGroupWindowClient.setAsideRoots(in: linkedStore)
            try check(roots.isEmpty, "no person key to offer")
        }

        // 2f. Deleting the data (#1104) leaves no mark or set-aside identity behind,
        //     and its clean-up is not confused by them.
        do {
            let old = registered(.firstDevice()), deletionStore = MemorySecrets()
            try deletionStore.write(GroupWire.encode(old), account: "identity", createOnly: true)
            try GroupDeviceRevocation.mark(.init(personID: old.personID, deviceID: try old.deviceID), in: deletionStore)
            let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: deletionStore, transport: relay,
                outboxDirectory: folder.appendingPathComponent("deletion"))
            try check(try await client.startFreshAfterRevocation(), "fresh start before the deletion")
            let pending = try await client.identityDeletionNeedingLocalCleanup()
            try check(pending == nil, "no deletion: nothing to clean up")
            _ = try await client.windows()
            _ = try await client.requestIdentityDeletion()
            let left = try deletionStore.accounts(prefix: GroupDeviceRevocation.accountPrefix)
                + deletionStore.accounts(prefix: ProductionGroupWindowClient.setAsidePrefix) + deletionStore.accounts(prefix: "identity")
            try check(left.allSatisfy { $0 == "identity-deletion" || $0.hasPrefix("identity-deletion-history:") },
                      "no mark, set-aside or current identity is left (got \(left))")
            let again = try await client.identityDeletionNeedingLocalCleanup()
            try check(again != nil, "the accepted deletion still asks for its local clean-up")
        }
    }

    // MARK: 3. The notebook's transport

    static func notebookTransport() async throws {
        let me = registered(.firstDevice()), events = Events()
        let marks = MemorySecrets(events: events), journal = MemorySecrets()
        let relay = ScriptedRelay(events: events) { _ in .reply(401, revokedBody) }
        let wire = try FamilyNotebookTransport(endpoint: endpoint, identity: me, transport: relay, journal: journal, revocations: marks)
        do { _ = try await wire.read("/v3/family-notebooks/me"); throw Failure.check("a revoked read") }
        catch FamilyNotebookTransportError.authenticationRequired { events.add("error") }
        try check(events.all == ["send /v3/family-notebooks/me", "mark", "error"], "no second try; the mark first (got \(events.all))")
        try check(try GroupDeviceRevocation.isMarked(me, in: marks), "the read marks the pair")

        let operation = UUID(), body = Data(#"{"operationId":"x"}"#.utf8)
        do {
            _ = try await wire.mutate(operationID: operation, intent: Data(repeating: 1, count: 32),
                path: "/v3/family-notebooks/" + UUID().uuidString.lowercased() + "/crypto/operations", body: body) { _, _ in }
            throw Failure.check("a revoked write")
        } catch FamilyNotebookTransportError.authenticationRequired {}
        let parked = try journal.read("op:family:" + operation.uuidString.lowercased())
        try check(parked != nil, "the write stays in the journal, unsent, with this pair")
        do { try await wire.pushSubscription(family: UUID(), token: Data(repeating: 2, count: 32), environment: "production") }
        catch FamilyNotebookTransportError.authenticationRequired {}

        // An older relay: the existing one retry, nothing marked.
        let plainMarks = MemorySecrets(), plainRelay = ScriptedRelay(events: Events()) { _ in .reply(401, plainBody) }
        let plainWire = try FamilyNotebookTransport(endpoint: endpoint, identity: me, transport: plainRelay, journal: MemorySecrets(), revocations: plainMarks)
        do { _ = try await plainWire.read("/v3/family-notebooks/me") } catch FamilyNotebookTransportError.authenticationRequired {}
        let plainMarked = try GroupDeviceRevocation.isMarked(me, in: plainMarks)
        try check(plainRelay.count == 2 && !plainMarked, "a plain 401: one retry, no mark")
        // Without a mark store the reasoned answer still ends the read at once.
        let bare = ScriptedRelay(events: Events()) { _ in .reply(401, revokedBody) }
        do { _ = try await FamilyNotebookTransport(endpoint: endpoint, identity: me, transport: bare, journal: MemorySecrets()).read("/v3/family-notebooks/me") }
        catch FamilyNotebookTransportError.authenticationRequired {}
        try check(bare.count == 1, "no retry of a reasoned answer")
    }

    // MARK: 4. 機種変更's link and identity

    static func identityChoice() throws {
        let recovered = registered(.firstDevice()), marks = MemorySecrets()
        let scope = GroupCanonical.hash(recovered.personPublicKey).map { String(format: "%02x", $0) }.joined()
        let recoveryStore = MemorySecrets(), links = MemorySecrets()
        try recoveryStore.write(GroupWire.encode(recovered), account: "identity", createOnly: true)
        try links.write(GroupWire.encode(FamilyNotebookIdentityChoice.Link(version: 1, scope: scope, personID: recovered.personID,
            familyIDs: [UUID()])), account: FamilyNotebookIdentityChoice.linkAccount, createOnly: true)
        func load() throws -> GroupDeviceIdentity? {
            try FamilyNotebookIdentityChoice.load(links: links, recoveryStore: { _ in recoveryStore }, usualPersonID: nil,
                                                  usualDeviceID: nil, revocations: marks)
        }
        try check(try load() != nil, "an unmarked recovered device is picked")
        let pair = GroupDeviceRevocation.Pair(personID: recovered.personID, deviceID: try recovered.deviceID)
        try GroupDeviceRevocation.mark(pair, in: marks)
        try check(try load() == nil, "a marked recovered device is never picked")
        try FamilyNotebookIdentityChoice.forgetLink(links: links, pair: .init(personID: recovered.personID, deviceID: "another"),
                                                    recoveryStore: { _ in recoveryStore })
        try check(try links.read(FamilyNotebookIdentityChoice.linkAccount) != nil, "another pair keeps the link")
        try FamilyNotebookIdentityChoice.forgetLink(links: links, pair: pair, recoveryStore: { _ in recoveryStore })
        try check(try links.read(FamilyNotebookIdentityChoice.linkAccount) == nil, "the pair's link goes")

        // 「引き継ぐ」 (the person's tap) makes a new device for a root whose
        // recovered device here carries the mark: its drafts go, only then.
        let root = try Curve25519.Signing.PrivateKey(rawRepresentation: recovered.personPrivateKey!)
        let journal = MemorySecrets()
        try journal.write(Data("draft".utf8), account: "op:recovery:old", createOnly: true)
        try journal.write(Data("material".utf8), account: "op:rf:old", createOnly: true)
        try journal.write(Data("other".utf8), account: "op:keep", createOnly: true)
        let same = try GroupRecoveryLiveBuilder.deviceIdentity(root: root, secrets: recoveryStore, journal: journal)
        let sameDevice = try same.deviceID
        try check(sameDevice == pair.deviceID, "without the mark store the device is reused")
        let unmarkedJournal = MemorySecrets()
        try unmarkedJournal.write(Data("draft".utf8), account: "op:recovery:kept", createOnly: true)
        let otherRoot = Curve25519.Signing.PrivateKey(), otherStore = MemorySecrets()
        let first = try GroupRecoveryLiveBuilder.deviceIdentity(root: otherRoot, secrets: otherStore, journal: unmarkedJournal, revocations: marks)
        let reused = try GroupRecoveryLiveBuilder.deviceIdentity(root: otherRoot, secrets: otherStore, journal: unmarkedJournal, revocations: marks)
        let firstDevice = try first.deviceID, reusedDevice = try reused.deviceID
        let keptDraft = try unmarkedJournal.read("op:recovery:kept")
        try check(firstDevice == reusedDevice && keptDraft != nil, "an unmarked device and its drafts stay")
        let fresh = try GroupRecoveryLiveBuilder.deviceIdentity(root: root, secrets: recoveryStore, journal: journal, revocations: marks)
        let freshDevice = try fresh.deviceID
        try check(freshDevice != pair.deviceID && fresh.personID == pair.personID && !fresh.registered, "a new device of the root")
        let aside = try recoveryStore.read("identity-revoked:" + pair.deviceID)
        try check(aside != nil, "the old keys are kept aside")
        let draft = try journal.read("op:recovery:old"), material = try journal.read("op:rf:old"), other = try journal.read("op:keep")
        try check(draft == nil && material == nil && other != nil, "only the old device's drafts go")
        let again = try GroupRecoveryLiveBuilder.deviceIdentity(root: root, secrets: recoveryStore, journal: journal, revocations: marks)
        try check((try again.deviceID) == freshDevice, "the new device is reused")

        // The schedule: no family shown, no identity to open with: it never reads.
        try check(!FamilyAutoCheckPolicy.eligible(.init(real: true, hasFamily: false, awaitingApproval: false,
            awaitingApprovalUnknown: false, unreadThisLaunch: true, hasIdentity: false, resumeProbeDue: false)),
                  "the notebook's schedule does not read after the detach")
    }

    // MARK: 5. The notebook service: the entrance, not an error

    @MainActor static func notebookService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-revocation-service-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = registered(.firstDevice()), events = Events(), marks = MemorySecrets(events: events)
        let relay = ScriptedRelay(events: events) { _ in .reply(401, revokedBody) }
        func session(_ transport: ScriptedRelay) throws -> FamilyNotebookSession {
            let folder = root.appendingPathComponent(UUID().uuidString)
            return try .init(endpoint: endpoint, identity: me, transport: transport,
                journal: GroupOperationStore(directory: folder.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000),
                secrets: GroupOperationStore(directory: folder.appendingPathComponent("synthetic-secrets")),
                directory: folder.appendingPathComponent("notebooks"), revocations: marks)
        }

        // An older relay: the existing error, nothing let go.
        do {
            let plain = ScriptedRelay(events: Events()) { _ in .reply(401, plainBody) }
            let service = ProductionFamilyNotebookSharingService(provider: { try session(plain) }, billing: {},
                displayName: { "合成" }, catNames: { [] }, revocations: marks)
            do { _ = try await service.loadState(); throw Failure.check("a plain 401 is not the entrance") }
            catch FamilySharingError.signInExpired {}
            let marked = try GroupDeviceRevocation.isMarked(me, in: marks)
            try check(!service.takeRevokedDetach() && !marked, "a plain 401 lets nothing go")
        }

        var forgotten: [GroupDeviceRevocation.Pair] = []
        var renewals = 0
        let service = ProductionFamilyNotebookSharingService(provider: { try session(relay) }, billing: {},
            displayName: { "合成" }, catNames: { [] },
            hasExistingIdentity: { !(try GroupDeviceRevocation.isMarked(me, in: marks)) }, revocations: marks,
            forgetRevoked: { events.add("forget"); forgotten.append($0) },
            renewForEntrance: { renewals += 1; return false })
        let state = try await service.loadState()
        try check(state == .notInFamily, "the entrance, as with no notebook (got \(state))")
        try check(events.all == ["send /v3/family-notebooks/me", "mark", "forget"], "the mark before letting go (got \(events.all))")
        try check(forgotten == [.init(personID: me.personID, deviceID: try me.deviceID)], "the pair's link is looked at")
        try check(service.takeRevokedDetach() && !service.takeRevokedDetach(), "the screens are told once")
        try check(service.notebook == nil && service.currentFamilyID == nil && service.lastSend == nil, "nothing of it is shown")
        try check(service.isRevoked(personID: me.personID, deviceID: try me.deviceID), "the screens can ask about a kept binding")

        let sent = relay.count
        try check(try await service.loadState() == .notInFamily, "the next read is the entrance")
        await service.updatePushSubscription(token: Data(repeating: 3, count: 32), environment: "production")
        do { _ = try await service.pendingRequests() } catch {}
        try check(relay.count == sent, "no request after the mark (got \(relay.log.dropFirst(sent).map { $0.path }))")

        // The person's own create and join ask for a new device first; reads never do.
        try check(renewals == 0, "no renewal on a read")
        do { try await service.createFamily(operationID: UUID()) } catch {}
        do { _ = try await service.previewInvitation(URL(string: "https://group.invalid/f#x")) } catch {}
        try check(renewals == 2, "作る and opening an invitation renew first (got \(renewals))")

        // A mark written by the まど first: the open session lets go without a call.
        let other = MemorySecrets(), quiet = ScriptedRelay(events: Events()) { _ in .reply(200, Data("{}".utf8)) }
        let open = try FamilyNotebookSession(endpoint: endpoint, identity: me, transport: quiet,
            journal: GroupOperationStore(directory: root.appendingPathComponent("open/journal"), maximumRecordBytes: 2_100_000),
            secrets: GroupOperationStore(directory: root.appendingPathComponent("open/secrets")),
            directory: root.appendingPathComponent("open/notebooks"), revocations: other)
        let held = ProductionFamilyNotebookSharingService(provider: { open }, billing: {}, displayName: { "合成" }, catNames: { [] },
            revocations: other)
        _ = try? await held.loadState()
        let before = quiet.count
        try GroupDeviceRevocation.mark(.init(personID: me.personID, deviceID: try me.deviceID), in: other)
        let heldState = try await held.loadState()
        try check(heldState == .notInFamily && held.takeRevokedDetach(), "a marked session is let go")
        try check(quiet.count == before, "without another call")
    }

    // MARK: 6. The screens' wiring (UIKit files, checked as text)

    static func sources() throws {
        func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
        let sharing = try read("NekoWidget/Services/FamilyNotebookSharing.swift")
        let detach = try required(sharing.range(of: "detachIfRevoked(loaded)"))
        let ended = try required(sharing.range(of: "FamilyNotebookPrototype.shared.noteEndedNotice()"))
        try check(detach.lowerBound < ended.lowerBound, "the screens let go before the ended notice is considered")
        let view = try read("NekoWidget/Views/FamilyNotebookView.swift")
        try check(view.contains("UserDefaults.standard.removeObject(forKey: Self.bindingKey)")
                  && view.contains("UserDefaults.standard.removeObject(forKey: FamilyNotebookLocalBinding.legacyKey)"),
                  "the binding goes (both versions)")
        let factory = try read("NekoWidget/Services/FamilyNotebookServiceFactory.swift")
        try check(factory.contains("revocations: client.revocations)") && factory.contains("return try await client.startFreshAfterRevocation()"),
                  "the factory wires the marks and the entrance")
        for (path, call) in [("NekoWidget/Views/GroupWindowView.swift", "client.createWindow(name: trimmed, ownerDisplayName: owner"),
                             ("NekoWidget/Views/GroupWindowSetupView.swift", "let request = try await client.apply(")] {
            let text = try read(path)
            let renew = try required(text.range(of: "(client as? ProductionGroupWindowClient)?.startFreshAfterRevocation()"))
            let action = try required(text.range(of: call))
            try check(renew.lowerBound < action.lowerBound, "\(path): the person's tap renews before it calls")
        }
    }
}

private func required<T>(_ value: T?) throws -> T {
    guard let value else { throw Failure.check("missing value") }
    return value
}
