import Foundation
import CryptoKit

final class ShareMemoryStore: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }
        values[account] = data
    }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
    func accounts(prefix: String) throws -> [String] { lock.lock(); defer { lock.unlock() }; return values.keys.filter { $0.hasPrefix(prefix) } }
}

final class ShareFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

func requireRejection(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Expected rejection") } catch { }
}

actor ShareStub: GroupShareServing {
    var values: [GroupWindow]
    var failOnce: Bool
    var calls: [(String, UUID, String?)] = []
    init(_ values: [GroupWindow], failOnce: Bool = false) {
        self.values = values
        self.failOnce = failOnce
    }
    func destinations() async throws -> [GroupWindow] { values }
    func send(jpeg: Data, caption: String?, windowID: String, operationID: UUID) async throws {
        calls.append((windowID, operationID, caption))
        if failOnce { failOnce = false; throw GroupClientError.offline }
    }
    func attempts() -> [(String, UUID, String?)] { calls }
}

/// 11/21m: answers each send with the next result (nil: delivered).
actor ScriptedShareStub: GroupShareServing {
    let values: [GroupWindow]
    var results: [Error?]
    var calls: [(String, UUID)] = []
    init(_ values: [GroupWindow], results: [Error?]) { self.values = values; self.results = results }
    func destinations() async throws -> [GroupWindow] { values }
    func send(jpeg: Data, caption: String?, windowID: String, operationID: UUID) async throws {
        calls.append((windowID, operationID))
        if !results.isEmpty, let error = results.removeFirst() { throw error }
    }
    func attempts() -> [(String, UUID)] { calls }
}

@main struct GroupShareChecks {
    @MainActor static func main() async throws {
        let origin = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
        var configuration: [String: Any] = ["GroupShareExtensionEnabled": "YES", "GroupWindowsEnabled": "YES",
            "SharingFeatureEnabled": "YES", "SharingMediaEnabled": "YES", "SharingShareExtensionSendEnabled": "NO",
            "SharingReviewPreviewEnabled": false, "SharingInternalEncryptedReportEnabled": false,
            "SharingInternalEncryptedReportScope": "", "SharingReleaseMode": "media-staging", "GroupShareAPIBaseURL": origin]
        precondition(GroupShareConfiguration(info: configuration)?.endpoint.absoluteString == origin)
        for (key, value) in [("GroupWindowsEnabled", "NO"), ("SharingShareExtensionSendEnabled", "YES"),
            ("SharingModerationKeyID", "moderation-v2"), ("SharingAPIBaseURL", origin),
            ("SharingInternalEncryptedReportScope", "internal-owner-first-connection"),
            ("GroupShareAPIBaseURL", "https://foreign.example")] {
            var changed = configuration; changed[key] = value
            precondition(GroupShareConfiguration(info: changed) == nil)
        }
        configuration["SharingReleaseMode"] = "production"
        configuration["GroupShareAPIBaseURL"] = "https://photos.example.com"
        precondition(GroupShareConfiguration(info: configuration) != nil)
        for endpoint in [origin, "", "http://photos.example.com", "https://person@photos.example.com",
                         "https://photos.example.com/path", "https://photos.example.com?x=1"] {
            var changed = configuration; changed["GroupShareAPIBaseURL"] = endpoint
            precondition(GroupShareConfiguration(info: changed) == nil)
        }
        print("PASS configuration: photo-only production/internal routes; reports and wrong endpoints denied")
        let me = GroupMember(id: "person", personID: "person", displayName: "自分", role: .member, state: .active, devices: [])
        let active = GroupWindow(id: "aaaaaaaaaaaaaaaaaaaaaa", name: "みんな", revision: 1, keyEpoch: 1,
            myParticipantID: me.id, myRole: .member, state: .active, members: [me], deliveryStatus: .active)
        var paused = active
        paused.deliveryStatus = .paused
        var unknown = active
        unknown.deliveryStatus = nil
        var emptyCalls = 0
        let empty = GroupShareComposerModel(jpeg: Data(), service: ShareStub([]), onEmpty: { emptyCalls += 1 })
        await empty.load()
        precondition(!empty.loading && empty.windows.isEmpty && empty.message == nil && emptyCalls == 1)
        print("PASS empty: creation hint only after a confirmed empty list")

        let pausedModel = GroupShareComposerModel(jpeg: Data(), service: ShareStub([paused]))
        await pausedModel.load()
        pausedModel.select(paused)
        precondition(pausedModel.windows.count == 1 && pausedModel.selected == nil)
        precondition(!GroupShareComposerModel.canDeliver(unknown))
        print("PASS paused/unknown: visible but never selectable")

        let service = ShareStub([active], failOnce: true)
        let ready = GroupShareComposerModel(jpeg: Data([1]), service: service)
        await ready.load()
        ready.select(active)
        precondition(ready.selected?.id == active.id && !ready.delivered)
        ready.caption = String(repeating: "猫", count: 101)
        await ready.send()
        let invalidAttempts = await service.attempts()
        precondition(invalidAttempts.isEmpty)
        ready.caption = "朝のまど\nお昼寝\nまたあした"
        await ready.send()
        precondition(!ready.delivered && ready.message != nil && !ready.canEdit)
        await ready.send()
        let calls = await service.attempts()
        precondition(ready.delivered && calls.count == 2 && calls[0].0 == active.id && calls[0].1 == calls[1].1)
        precondition(calls[0].2 == calls[1].2)
        await ready.send()
        let finalAttempts = await service.attempts()
        precondition(finalAttempts.count == 2)
        print("PASS active: preview, caption bounds, exact retry, committed success only")

        // 11/21m: a refusal frees the window choice and starts a new operation;
        // after an unknown result the same window and operation stay.
        let refusing = ScriptedShareStub([active], results: [GroupClientError.dailyLimit, nil])
        let refused = GroupShareComposerModel(jpeg: Data([1]), service: refusing)
        await refused.load()
        refused.select(active)
        await refused.send()
        precondition(!refused.delivered && refused.message != nil && refused.canEdit)
        refused.back()
        precondition(refused.selected == nil)
        refused.select(active)
        await refused.send()
        let refusedCalls = await refusing.attempts()
        precondition(refused.delivered && refusedCalls.count == 2 && refusedCalls[0].1 != refusedCalls[1].1)
        let uncertain = ScriptedShareStub([active], results: [GroupClientError.offline, GroupClientError.dailyLimit, nil])
        let held = GroupShareComposerModel(jpeg: Data([1]), service: uncertain)
        await held.load()
        held.select(active)
        await held.send()
        await held.send()
        precondition(!held.canEdit)
        await held.send()
        let heldCalls = await uncertain.attempts()
        precondition(held.delivered && heldCalls.count == 3 && Set(heldCalls.map(\.1)).count == 1)
        print("PASS refusal: choose again or go back; an unknown result keeps the same operation")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-share-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = root.appendingPathComponent("request")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for age: TimeInterval in [0, 599.999, 600] {
            try GroupShareCreateRequest.record(at: request, now: date)
            precondition(GroupShareCreateRequest.consume(at: request, now: date.addingTimeInterval(age)))
            precondition(!GroupShareCreateRequest.consume(at: request, now: date.addingTimeInterval(age)))
        }
        for age: TimeInterval in [-1, 600.001, 3600] {
            try GroupShareCreateRequest.record(at: request, now: date)
            precondition(!GroupShareCreateRequest.consume(at: request, now: date.addingTimeInterval(age)))
            precondition(!FileManager.default.fileExists(atPath: request.path))
        }
        try Data("invalid".utf8).write(to: request)
        precondition(!GroupShareCreateRequest.consume(at: request, now: date))
        let remains = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(remains.isEmpty)
        print("PASS create route: 10-minute boundary, future/expired/corrupt rejection, consume once")

        let original = ShareMemoryStore(), snapshot = ShareMemoryStore(), checkpoints = ShareMemoryStore()
        let publisher = GroupSharePublishingStore(original: original, snapshot: snapshot)
        _ = try publisher.read("identity")
        let emptyMarker = try snapshot.read("host-confirmed-empty")
        precondition(emptyMarker == Data([1]))
        var identity = GroupDeviceIdentity.firstDevice()
        try publisher.write(GroupWire.encode(identity), account: "identity", createOnly: false)
        let unfinishedMarker = try snapshot.read("host-confirmed-empty")
        precondition(unfinishedMarker == nil)
        identity.registered = true
        try publisher.write(GroupWire.encode(identity), account: "identity", createOnly: false)
        let sharedIdentity = try GroupWire.decode(GroupDeviceIdentity.self, snapshot.read("identity")!)
        precondition(sharedIdentity.personPrivateKey == nil && sharedIdentity.windowCertificates.isEmpty)
        precondition(sharedIdentity.signingPrivateKey == identity.signingPrivateKey)
        let privateIdentity = try GroupWire.decode(GroupDeviceIdentity.self, original.read("identity")!)
        precondition(privateIdentity.personPrivateKey == identity.personPrivateKey)
        try publisher.write(Data([4]), account: "billing-connection", createOnly: false)
        let leaked = try snapshot.read("billing-connection")
        precondition(leaked == nil)
        for account in ["anchor-receipt:room", "anchor-receipt-pending:room"] {
            try publisher.write(Data([7]), account: account, createOnly: true)
            let privateReceipt = try original.read(account)
            let sharedReceipt = try snapshot.read(account)
            precondition(privateReceipt == Data([7]))
            precondition(sharedReceipt == nil)
        }

        let windowID = GroupWire.randomID()
        let anchor = GroupTrustAnchor(windowID: windowID, ownerPersonID: identity.personID, ownerIdentityPublicKey: identity.personPublicKey)
        let member = try GroupRosterMember(participantID: GroupWire.randomID(), personID: identity.personID,
            identityPublicKey: identity.personPublicKey, role: .owner, devices: [identity.certificate(windowID: windowID)])
        let roster = GroupRoster(windowID: windowID, revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32),
            ownerPersonID: identity.personID, members: [member])
        let packet = try GroupRosterVerifier.sign(roster, deviceID: identity.deviceID, privateKey: identity.signingKey)
        let hash = try GroupCanonical.hash(roster.canonicalBytes())
        var record = GroupLocalWindow.empty(anchor: anchor)
        record.packet = packet; record.pinnedRevision = 1; record.pinnedHash = hash
        record.keys = ["1": Data(repeating: 7, count: 32)]
        record.rosterHashes = ["1": hash]
        // A pre-update destination is seeded without opening its app screen.
        try original.write(GroupWire.encode(record), account: "window:" + windowID, createOnly: false)
        publisher.refreshSnapshot()
        let seeded = try snapshot.read("window:" + windowID)
        precondition(seeded != nil)
        let reader = GroupShareReadingStore(snapshot: snapshot, checkpoints: checkpoints)
        record.nameCheckpoint = .init(rosterRevision: 1, nameRevision: 2, ciphertextHash: Data(repeating: 8, count: 32))
        try reader.write(GroupWire.encode(record), account: "window:" + windowID, createOnly: false)
        let pinned = try GroupWire.decode(GroupLocalWindow.self, reader.read("window:" + windowID)!)
        precondition(pinned.nameCheckpoint?.nameRevision == 2)
        let untouched = try GroupWire.decode(GroupLocalWindow.self, original.read("window:" + windowID)!)
        precondition(untouched.nameCheckpoint == nil)
        requireRejection { try reader.write(GroupWire.encode(identity), account: "identity", createOnly: false) }
        requireRejection { _ = try reader.read("billing-connection") }
        try publisher.remove("window:" + windowID)
        requireRejection { _ = try reader.read("window:" + windowID) }
        print("PASS credentials: owner root/billing excluded, host unchanged, revocation beats extension checkpoint")

        // 11/21m: a window not handed over yet concerns that window alone.
        do { _ = try reader.read("window:" + GroupWire.randomID()); preconditionFailure("Expected rejection") }
        catch let error as GroupClientError { precondition(error == .notMember) }
        // The share copy that cannot open yet (locked) opens later and seeds.
        let lockedOriginal = ShareMemoryStore(), lateSnapshot = ShareMemoryStore()
        try lockedOriginal.write(GroupWire.encode(identity), account: "identity", createOnly: false)
        try lockedOriginal.write(GroupWire.encode(record), account: "window:" + windowID, createOnly: false)
        let unlocked = ShareFlag()
        let deferred = GroupSharePublishingStore(original: lockedOriginal, makeSnapshot: {
            unlocked.isOn ? lateSnapshot as any GroupSecretStore : nil
        })
        _ = try deferred.read("identity")
        let nothingYet = try lateSnapshot.accounts(prefix: "")
        precondition(nothingYet.isEmpty && deferred.snapshot == nil)
        unlocked.isOn = true
        precondition(deferred.snapshot == nil)  // asked again at most every 10 s
        let reopened = GroupSharePublishingStore(original: lockedOriginal, makeSnapshot: { lateSnapshot })
        _ = try reopened.read("identity")
        let seededWindow = try lateSnapshot.read("window:" + windowID), seededIdentity = try lateSnapshot.read("identity")
        precondition(seededWindow != nil && seededIdentity != nil)
        // 「データを消す」 leaves nothing behind but the marker.
        try lateSnapshot.write(Data([9]), account: "window:stale", createOnly: false)
        reopened.clearSnapshot()
        let left = try lateSnapshot.accounts(prefix: "")
        precondition(left == ["host-confirmed-empty"])
        print("PASS share copy: one missing window, opening after unlock, cleared at once")

        let path = "/v3/group-windows/" + windowID
        precondition(GroupShareTransport.allows(method: "GET", path: path))
        precondition(GroupShareTransport.allows(method: "POST", path: path + "/moments/reserve"))
        precondition(GroupShareTransport.allows(method: "PUT", path: path + "/moments/" + windowID + "/ciphertext"))
        for forbidden in ["/v3/group-identities/register", "/v3/group-windows/billing-connection", "/v3/family-notebooks",
                          path + "/members/remove", path + "/close", path + "/invitations", path + "/reports"] {
            precondition(!GroupShareTransport.allows(method: "POST", path: forbidden))
        }
        print("PASS transport: photo/list only; registration, billing, family, reports and management denied")
    }
}
