import CryptoKit
import Foundation

// S14 (11/20, #1102): a device taken off by another iPhone of the same person
// (機種変更 「外す」). The Worker answers that device's signed requests with
// 401 `invalid_authentication` and `reason: device_revoked`.

/// The comparison of S14: each request goes to the Worker twice with the same
/// nonce, and the app gets the second answer. The Worker gives its reasoned
/// answer at most once per nonce, so the app sees the plain 401 that an older
/// Worker sends. Both answers are the real Worker's; the first is only counted.
final class PlainAnswerTransport: GroupHTTPTransport, @unchecked Sendable {
    private let base: LoopbackTransport
    private let lock = NSLock()
    private var firsts: [Bool] = [], seconds: [Bool] = []
    init(_ base: LoopbackTransport) { self.base = base }
    /// How many first answers carried the reason, and how many second ones did.
    var reasoned: (first: Int, second: Int, sends: Int) {
        lock.lock(); defer { lock.unlock() }
        return (firsts.filter { $0 }.count, seconds.filter { $0 }.count, firsts.count)
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let first = try await base.send(request, maximumBytes: maximumBytes)
        let second = try await base.send(request, maximumBytes: maximumBytes)
        lock.lock(); firsts.append(GroupDeviceRevocation.says(first)); seconds.append(GroupDeviceRevocation.says(second)); lock.unlock()
        return second
    }
}

/// The real Worker's answers, with whether each carried the reason.
final class AnswerLog: GroupHTTPTransport, @unchecked Sendable {
    struct Answer: Sendable { let path: String; let status: Int; let reasoned: Bool }
    private let base: LoopbackTransport
    private let lock = NSLock()
    private var values: [Answer] = []
    init(_ base: LoopbackTransport) { self.base = base }
    var answers: [Answer] { lock.lock(); defer { lock.unlock() }; return values }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let reply = try await base.send(request, maximumBytes: maximumBytes)
        lock.lock(); values.append(.init(path: request.url?.path ?? "", status: reply.status, reasoned: GroupDeviceRevocation.says(reply))); lock.unlock()
        return reply
    }
}

extension Scenarios {
    static func s14(_ relay: Relay) async throws -> String? {
        Log.step("A: a Sandbox billing account with test Plus; A creates the family notebook")
        let billing = try await relay.bootstrapBilling()
        try await relay.grantPlus(billing)
        let a = try await Device.make("A", relay: relay, cloud: PersonCloud(), billing: billing)
        a.rememberName("合成のA")
        let family = UUID()
        try await a.service.createFamily(operationID: family)
        try await settle("A's first key", [a]) { a.inFamily }
        let root = try required(try a.usualRoot(), "A has no person key")
        a.cloud.publish(root)
        let person = try required(a.notebookIdentity?.personID, "A has no person")

        Log.step("A puts a cat and its photo into the notebook")
        let cat = try shareCat(a, name: "合成のしろ", profile: UUID(), tool: UUID())
        let aStore = try required(a.service.notebook, "A has no notebook copy")
        try await settle("A's cat sent", [a]) { try aStore.pendingOperations().isEmpty }
        let photo = try await deliver(a, cat, shade: 2)

        Log.step("B: a second iPhone of the same person (its usual identity: the person key, its own device key)")
        // B's own Sandbox account with Plus (for its fresh start below) and its
        // own iCloud Keychain, which never held the person key.
        let bBilling = try await relay.bootstrapBilling()
        try await relay.grantPlus(bBilling)
        let b = try await Device.make("B", relay: relay, cloud: PersonCloud(), billing: bBilling)
        // Written by the test: the usual identity holds the person key and its
        // own device key (registered by the app on its first call).
        let seeded = seededIdentity(root)
        let usualStore = b.keychain.store(Device.namespace)
        try usualStore.write(GroupWire.encode(seeded), account: "identity", createOnly: true)
        let oldDevice = try seeded.deviceID
        b.rememberName("合成のA")
        try await settle("B's device has the notebook keys", [b, a]) { b.inFamily }
        try expect(b.notebookDeviceID == oldDevice && b.notebookIdentity?.personID == person,
                   "B reads the notebook as the same person with its own device")

        Log.step("Both read まど (the signed list) and the notebook's photo")
        let aWindows = try await a.client.windows(), bWindows = try await b.client.windows()
        try expect(aWindows.isEmpty && bWindows.isEmpty, "no まど in this family (got \(aWindows.count), \(bWindows.count))")
        let listRoute = "/v3/group-windows/list"
        try expect(relay.transport.log.contains { $0.device == oldDevice && $0.path == listRoute && $0.status == 200 },
                   "the Worker answered B's まど list")
        _ = try await seePhoto(b, cat, asset: photo.asset)
        let listed = try b.notebookScreenCats()
        try expect(listed == [cat] && b.bindingSaved, "B's notebook shows the cat and keeps its binding")
        let bStore = try required(b.service.notebook, "B has no notebook copy")
        let bIdentity = try required(b.notebookIdentity, "B has no notebook identity")

        Log.step("A takes B's device off (機種変更 「外す」, signed with the person key)")
        let remover = try GroupRecoveryClient(endpoint: relay.endpoint, environment: Device.recoveryEnvironment, root: root,
            transport: relay.transport, journal: MemorySecrets(), enabled: true)
        try await SharingPersonAction.run { try await remover.removeDevice(oldDevice, operationID: UUID()) }

        Log.step("B writes a line before it hears of it (unsent, with B's device)")
        let bAuthor = try required(b.service.author, "B has no author")
        let parked = try bStore.edit(target: .init(familyCatID: cat, field: .marks), value: .text("合成のしるしB"), author: bAuthor)
        try expect(try bStore.pendingOperations().contains { $0.id == parked.id }, "B's line waits to be sent")

        Log.step("Comparison: the Worker's plain 401 (as an older Worker answers) leaves B alone")
        let plain = PlainAnswerTransport(relay.transport)
        let plainClient = try ProductionGroupWindowClient(endpoint: relay.endpoint, secrets: usualStore, transport: plain,
            outboxDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("s14-plain-" + UUID().uuidString, isDirectory: true))
        do {
            _ = try await plainClient.windows()
            throw E2EFailure(description: "\(Log.location): B's まど list was answered after the removal")
        } catch GroupClientError.authenticationRequired {}
        let plainWire = try FamilyNotebookTransport(endpoint: relay.endpoint, identity: bIdentity, transport: plain,
            journal: MemorySecrets(), revocations: usualStore)
        do {
            _ = try await plainWire.read("/v3/family-notebooks/me")
            throw E2EFailure(description: "\(Log.location): B's notebook was answered after the removal")
        } catch FamilyNotebookTransportError.authenticationRequired {}
        let counted = plain.reasoned
        Log.note("comparison: \(counted.sends) requests, reasoned first answers \(counted.first), reasoned second answers \(counted.second)")
        try expect(counted.first >= 2 && counted.second == 0, "the Worker's first answers carried the reason, the repeated nonce's did not")
        let plainMarked = try GroupDeviceRevocation.isMarked(bIdentity, in: usualStore)
        let stillOpens = try await b.client.hasExistingIdentity()
        try expect(!plainMarked && stillOpens, "a plain 401 marks nothing; B's identity still opens")
        try expect(b.service.notebook != nil && b.bindingSaved, "B's notebook copy and binding stay")

        Log.step("B's notebook read gets the reasoned 401: the mark first, then the entrance")
        var mark = relay.transport.log.count
        let state = await b.pass()
        try expect(state == .notInFamily, "B's notebook is at the entrance, as with no notebook (got \(String(describing: state)))")
        let marked = try GroupDeviceRevocation.isMarked(bIdentity, in: usualStore)
        try expect(marked, "B's pair is marked in its device-only Keychain")
        let notebookCalls = relay.transport.log.dropFirst(mark)
        try expect(notebookCalls.count == 1 && notebookCalls.allSatisfy { $0.device == oldDevice && $0.status == 401 && $0.path.hasPrefix("/v3/family-notebooks") },
                   "one notebook request, answered 401, no second try (got \(notebookCalls.map { "\($0.path) \($0.status)" }))")
        try expect(b.service.notebook == nil && b.service.currentFamilyID == nil && b.service.lastMembers.isEmpty,
                   "B's membership leaves what is shown")
        try expect(!b.bindingSaved && !b.screenHasFamily, "the binding goes; the screen has no family")
        let kept = try bStore.snapshot()
        try expect(!kept.sharingEnded && kept.outbox.contains { $0.id == parked.id }, "B's copy and its unsent line stay on disk")

        Log.step("B's まど read gets the reasoned 401 too (a second client over B's Keychain with its own mark store)")
        let answers = AnswerLog(relay.transport), probeMarks = MemorySecrets()
        let probe = try ProductionGroupWindowClient(endpoint: relay.endpoint, secrets: usualStore, transport: answers,
            outboxDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("s14-probe-" + UUID().uuidString, isDirectory: true),
            revocations: probeMarks)
        do {
            _ = try await probe.windows()
            throw E2EFailure(description: "\(Log.location): the まど list was answered after the removal")
        } catch GroupClientError.authenticationRequired {}
        let listAnswer = answers.answers
        try expect(listAnswer.count == 1 && listAnswer[0].path == listRoute && listAnswer[0].status == 401 && listAnswer[0].reasoned,
                   "the まど route carried the reason (got \(listAnswer.map { "\($0.path) \($0.status) \($0.reasoned)" }))")
        let probeMarked = try GroupDeviceRevocation.isMarked(bIdentity, in: probeMarks)
        try expect(probeMarked, "the まど client marked the pair")
        mark = relay.transport.log.count
        let shown = try await b.client.windows()
        try expect(shown.isEmpty && relay.transport.log.count == mark, "B's まど shows its existing empty state, without a call")

        Log.step("B closes the app and opens it again: no registration, no send, no automatic call")
        try await b.relaunch()
        mark = relay.transport.log.count
        let scheduled = await b.automaticPass()
        try expect(!scheduled, "the schedule does not read")
        let again = await b.pass()
        try expect(again == .notInFamily, "the notebook opens at its entrance (got \(String(describing: again)))")
        let windowsAgain = try await b.client.windows()
        try expect(windowsAgain.isEmpty, "まど shows its empty state")
        await b.client.backfillAnchorReceipts()
        try? await b.client.updatePushSubscriptions(deviceToken: b.pushToken, environment: "production")
        _ = try? await b.client.reconcileAdmissions()
        await b.service.updatePushSubscription(token: b.pushToken, environment: "production")
        let quiet = relay.transport.log.dropFirst(mark)
        try expect(quiet.isEmpty, "B sent nothing (got \(quiet.map { $0.path }))")
        let opens = try await b.client.hasExistingIdentity()
        try expect(!opens, "no identity to open with")
        let keptRoot = try b.usualRoot(), keptIdentity = try usualStore.read("identity")
        try expect(keptRoot == root && keptIdentity != nil, "B keeps its identity and the person key")
        try expect(try bStore.pendingOperations().contains { $0.id == parked.id }, "the line is still parked with B's old device")

        Log.step("A still reads and writes; the family and its photo are intact")
        // The removal moves the notebook's keys on (a new epoch without B's device).
        try await settle("A reads the family after the removal", [a]) { a.inFamily }
        try expect(a.service.lastMembers.map(\.personID) == [person], "the family still lists the person (got \(a.service.lastMembers.count))")
        let line = try aStore.edit(target: .init(familyCatID: cat, field: .marks), value: .text("合成のしるしA"),
                                   author: try required(a.service.author, "A has no author"))
        try await settle("A's line sent", [a]) { try aStore.pendingOperations().isEmpty }
        let own = try await a.photo(cat)
        guard case .shown(let ownAsset, _, let ownJPEG)? = own, ownAsset == photo.asset, ownJPEG == photo.jpeg else {
            throw E2EFailure(description: "\(Log.location): A reads its photo as \(String(describing: own))")
        }
        _ = try await a.client.windows()
        let aIdentity = try required(a.notebookIdentity, "A has no identity")
        let aMarked = try GroupDeviceRevocation.isMarked(aIdentity, in: a.keychain.store(Device.namespace))
        try expect(!aMarked, "A is not marked")

        Log.step("B's person taps 作る: a fresh start, a new person with its own family")
        mark = relay.transport.log.count
        let freshFamily = UUID()
        try await SharingPersonAction.run { try await b.service.createFamily(operationID: freshFamily) }
        try await settle("B's new person has its own family", [b]) { b.inFamily }
        let fresh = try required(b.notebookIdentity, "B has no notebook identity")
        try expect(fresh.personID != person && b.service.currentFamilyID == freshFamily, "a new person in its own family, not A's")
        try expect(relay.transport.log.dropFirst(mark).allSatisfy { $0.device != oldDevice }, "the old device sent nothing")
        let setAside = try usualStore.read(ProductionGroupWindowClient.setAsidePrefix + oldDevice)
        try expect(setAside != nil, "the old identity is set aside")
        let stillMarked = try GroupDeviceRevocation.isMarked(bIdentity, in: usualStore)
        try expect(stillMarked, "the old pair's mark stays")
        try expect(try bStore.pendingOperations().contains { $0.id == parked.id }, "the old line stays parked")
        let outsider = try FamilyNotebookTransport(endpoint: relay.endpoint, identity: fresh, transport: relay.transport, journal: MemorySecrets())
        var readable = true
        do { _ = try await outsider.read("/v3/family-notebooks/" + family.uuidString.lowercased() + "/members") } catch { readable = false }
        try expect(!readable, "the new person cannot read A's family")
        try await settle("A still reads its family", [a]) { a.inFamily }
        try expect(a.service.lastMembers.map(\.personID) == [person], "A's family still lists only the person")

        Log.step("Two more iPhones of the person register: its three iPhones are taken")
        var extras: [String] = []
        for index in 0..<2 {
            let identity = seededIdentity(root)
            let store = MemorySecrets()
            try store.write(GroupWire.encode(identity), account: "identity", createOnly: true)
            let extra = try ProductionGroupWindowClient(endpoint: relay.endpoint, secrets: store, transport: relay.transport,
                outboxDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("s14-extra-\(index)-" + UUID().uuidString, isDirectory: true))
            _ = try await extra.windows()
            extras.append(try identity.deviceID)
        }

        Log.step("B taps 「前のiPhoneから引き継ぐ」 for the person: the 3-iPhone limit is the row's existing 3台まで")
        let links = b.keychain.store(Device.namespace + Device.recoveryLinkSuffix)
        let screen = try await b.openRecoveryScreen()
        try expect(screen.rootChoice.count == 2, "the person set aside and the new one are offered (got \(screen.rootChoice.count))")
        let limited = try await b.confirmNotebook(on: screen, rootID: person)
        guard case .deviceLimit(let rowID) = limited else {
            throw E2EFailure(description: "\(Log.location): the notebook row answered \(limited)")
        }
        let linkAfterLimit = try links.read(FamilyNotebookIdentityChoice.linkAccount)
        try expect(linkAfterLimit == nil, "nothing is linked")
        await b.pass()
        try expect(b.inFamily && b.notebookIdentity?.personID == fresh.personID, "B's own family stays as it was")

        Log.step("B takes one of the person's other iPhones off from that row (外す) and the same 続ける goes on")
        let row = try required(screen.items.first { $0.notebook }, "no notebook row")
        try expect(row.devices.contains { $0.id == extras[1] }, "the row lists the person's iPhones")
        await SharingPersonAction.run { await screen.handle(.removeDevice(operationID: rowID, deviceID: extras[1])) }
        let answered = try await rowAnswer(screen)
        Log.note("notebook row: \(answered)")
        let recovered = try required(try await b.recoveredIdentity(), "the identity choice picks the person again")
        let recoveredDevice = try recovered.deviceID
        try expect(recovered.personID == person && recovered.registered && recoveredDevice != oldDevice, "the person with a new device key")
        await b.pass()
        try expect(b.notebookDeviceID == recoveredDevice, "B's notebook opens with the new device")
        try await settle("B's new device has the keys", [a, b]) { b.inFamily }
        try await settle("B reads A's line", [b]) {
            try b.service.notebook?.snapshot().operations.contains { $0.id == line.id } == true
        }
        let atA = try aStore.snapshot().operations
        try expect(!atA.contains { $0.id == parked.id }, "B's parked line never reached A under another device")

        Log.step("A takes that recovered device off too; B's next read lets it go and drops its link")
        try await SharingPersonAction.run { try await remover.removeDevice(recoveredDevice, operationID: UUID()) }
        let letGo = await b.pass()
        try expect(letGo == .notInFamily, "the entrance (got \(String(describing: letGo)))")
        let recoveredMarked = try GroupDeviceRevocation.isMarked(recovered, in: usualStore)
        let linkAfterRemoval = try links.read(FamilyNotebookIdentityChoice.linkAccount)
        try expect(recoveredMarked && linkAfterRemoval == nil, "marked, link removed")

        Log.step("「引き継ぐ」 again: the taken-off recovered device's drafts go and a new device key is made")
        let again = try await b.openRecoveryScreen()
        let state = try await b.confirmNotebook(on: again, rootID: person)
        Log.note("notebook row: \(state)")
        let second = try required(try await b.recoveredIdentity(), "the identity choice picks the person again")
        let secondDevice = try second.deviceID
        try expect(second.personID == person && secondDevice != recoveredDevice && secondDevice != oldDevice, "another new device key")
        let scope = GroupCanonical.hash(second.personPublicKey).map { String(format: "%02x", $0) }.joined()
        let keptAside = try b.keychain.store(Device.namespace + ".recovery." + scope).read(ProductionGroupWindowClient.setAsidePrefix + recoveredDevice)
        try expect(keptAside != nil, "the taken-off recovered keys are kept aside")
        await b.pass()
        try await settle("B's second recovered device has the keys", [a, b]) { b.inFamily }
        try expect(b.notebookDeviceID == secondDevice, "B's notebook uses it")
        return "real: the local Worker's removals, its reasoned/plain 401 bodies and its 3-iPhone limit, the app's client, session, service, transports, "
            + "fresh start and 機種変更 (builder, adapter, notebook row); modelled: B's first usual identity and two more iPhones of the person "
            + "hold the person key written by the test, the plain 401 is the Worker's answer to a repeated nonce, the まど route's mark is read on "
            + "a second client with its own mark store, FamilyNotebookSharing/FamilyNotebookPrototype's detach is Device.bindingSaved, the 作る tap "
            + "is the service's createFamily (the まど 作る/参加 call the same startFreshAfterRevocation, checked in verify), and the family has no まど window"
    }

    /// An identity with the person key `root` and a new device key, not registered.
    static func seededIdentity(_ root: Data) -> GroupDeviceIdentity {
        let person = try! Curve25519.Signing.PrivateKey(rawRepresentation: root)
        return GroupDeviceIdentity(personPrivateKey: root, personPublicKey: person.publicKey.rawRepresentation,
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, windowCertificates: [:], registered: false)
    }

    /// The notebook row once it is no longer checking.
    static func rowAnswer(_ screen: GroupRecoveryAdapter) async throws -> GroupRecoveryRegistrationState {
        for _ in 0..<600 {
            guard let item = screen.items.first(where: { $0.notebook }) else { break }
            if case .checking = item.state { try await Task.sleep(for: .milliseconds(100)); continue }
            return item.state
        }
        throw E2EFailure(description: "\(Log.location): the notebook row did not answer")
    }
}
