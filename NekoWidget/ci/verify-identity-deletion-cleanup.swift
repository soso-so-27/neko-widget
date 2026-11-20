import CryptoKit
import Foundation

// 11/20: 「まどと家族の手帳のデータを消す」 leaves no sharing state behind on the
// iPhone. ProductionGroupWindowClient removes its own keys only after the
// relay accepted the deletion, keeps the deletion record, and hands the rest
// (FamilySharingLocalData) a record that names the deleted identity; that
// clean-up is tried to the end, reports a failure, and finishes on a second
// run. Synthetic keys, a synthetic relay, in-memory Keychain stores and a
// temporary folder only; no Keychain, network or photo.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws { if !value { throw Failure.check(name) } }

private final class MemorySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    /// Accounts whose removal fails (a Keychain error).
    var stuck = Set<String>()
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }; values[account] = data
    }
    func accounts(prefix: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }; return values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if stuck.contains(account) { throw GroupClientError.authenticationRequired }
        values.removeValue(forKey: account)
    }
}

/// The iPhone's device-only Keychain: one store per namespace.
private final class Keychain: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: MemorySecrets] = [:]
    var listingFails = false
    func store(_ namespace: String) -> MemorySecrets {
        lock.lock(); defer { lock.unlock() }
        if let existing = stores[namespace] { return existing }
        let created = MemorySecrets(); stores[namespace] = created; return created
    }
    func namespaces(prefix: String) throws -> [String] {
        if listingFails { throw GroupClientError.authenticationRequired }
        lock.lock(); let all = stores; lock.unlock()
        return all.filter { $0.key.hasPrefix(prefix) && !((try? $0.value.accounts(prefix: "")) ?? []).isEmpty }.keys.sorted()
    }
    func isEmpty(_ namespace: String) -> Bool { ((try? store(namespace).accounts(prefix: "")) ?? []).isEmpty }
}

/// Takes the deletion request (or answers 503 while `down`); records requests.
private actor DeletionRelay: GroupHTTPTransport {
    var down = false
    private(set) var deletions = 0
    func setDown(_ value: Bool) { down = value }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard request.url?.path == "/v3/group-identities/deletion-requests", request.httpMethod == "POST" else {
            return GroupHTTPReply(status: 404, data: Data(#"{"error":{"code":"not_found"}}"#.utf8))
        }
        deletions += 1
        guard !down else { return GroupHTTPReply(status: 503, data: Data(#"{"error":{"code":"unavailable"}}"#.utf8)) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let id = body?["operationId"] as? String ?? ""
        return GroupHTTPReply(status: 202, data: Data(#"{"protocolVersion":3,"requestId":"\#(id)","state":"processing","acceptedAt":1763600000,"completedAt":null}"#.utf8))
    }
}

private func registered(_ identity: GroupDeviceIdentity) -> GroupDeviceIdentity {
    var value = identity; value.registered = true; return value
}

@main
enum IdentityDeletionCleanupChecks {
    static let endpoint = URL(string: "https://group.invalid")!
    static let namespace = "jp.nekowidget.verify"

    static func client(_ secrets: MemorySecrets, _ relay: DeletionRelay, _ folder: URL) throws -> ProductionGroupWindowClient {
        try ProductionGroupWindowClient(endpoint: endpoint, secrets: secrets, transport: relay,
            outboxDirectory: folder.appendingPathComponent("outbox-" + UUID().uuidString))
    }

    /// The client's part: its own keys only after the relay accepted.
    static func clientChecks(_ folder: URL) async throws {
        let relay = DeletionRelay()
        let secrets = MemorySecrets()
        let identity = registered(.firstDevice())
        try secrets.write(GroupWire.encode(identity), account: "identity", createOnly: true)
        try secrets.write(Data("w".utf8), account: "window:synthetic", createOnly: true)
        let c = try client(secrets, relay, folder)

        // The relay does not answer: nothing is removed, nothing is cleaned up.
        await relay.setDown(true)
        var failed = false
        do { _ = try await c.requestIdentityDeletion() } catch { failed = true }
        try check(failed, "a failed request says so")
        let saved = try GroupWire.decode(GroupIdentityDeletion.self, try secrets.read("identity-deletion") ?? Data())
        try check(saved.acceptedAt == nil && saved.personID == identity.personID && saved.deviceID == (try identity.deviceID),
                  "the record is kept before sending and names the identity")
        try check(try secrets.read("identity") != nil && secrets.read("window:synthetic") != nil, "no key is removed before acceptance")
        try check(try await c.identityDeletionNeedingLocalCleanup() == nil, "no clean-up before acceptance")
        try check(try secrets.read("identity") != nil, "and the keys stay")

        // Accepted, with one Keychain item that cannot be removed: no failure shown.
        await relay.setDown(false)
        secrets.stuck = ["window:synthetic"]
        let accepted = try await c.requestIdentityDeletion()
        try check(accepted.acceptedAt != nil && accepted.operationID == saved.operationID, "the same operation is accepted")
        try check(try secrets.read("identity") == nil, "the identity is removed")
        try check(try secrets.read("window:synthetic") != nil, "the stuck item is still there")

        // The next launch: the stuck item goes, the record stays, the clean-up is handed on once.
        secrets.stuck = []
        let pending = try await c.identityDeletionNeedingLocalCleanup()
        try check(pending?.personID == identity.personID && pending?.deviceID == (try identity.deviceID), "the clean-up gets the deleted identity")
        try check(try secrets.accounts(prefix: "") == ["identity-deletion"], "only the deletion record stays")
        try check(try await c.identityDeletionNeedingLocalCleanup() != nil, "it is offered again until it is done")
        try await c.markIdentityDeletionLocalCleanupDone()
        try check(try await c.identityDeletionNeedingLocalCleanup() == nil, "never again once done")
        let done = try GroupWire.decode(GroupIdentityDeletion.self, try secrets.read("identity-deletion") ?? Data())
        try check(done.localDataRemovedAt != nil && done.acceptedAt != nil, "the record keeps its acceptance and the clean-up time")

        // A new identity moves the record to its history (as before) and is never cleaned up.
        _ = try? await c.familyNotebookIdentity()
        try check(try secrets.read("identity-deletion") == nil
                  && secrets.accounts(prefix: "identity-deletion-history:").count == 1, "the old record moved to its history")
        try check(try await c.identityDeletionNeedingLocalCleanup() == nil, "a new identity is not cleaned up")
        try check(try secrets.read("identity") != nil, "and keeps its keys")
        print("identity deletion: client keys only after acceptance, failure-tolerant, handed on once, then never")
    }

    /// The app closed between the relay's acceptance and the key removal.
    static func interruptedChecks(_ folder: URL) async throws {
        let relay = DeletionRelay()
        func accepted(for identity: GroupDeviceIdentity?) throws -> MemorySecrets {
            let secrets = MemorySecrets()
            let record = GroupIdentityDeletion(operationID: UUID(), receipt: GroupWire.base64(Data(repeating: 1, count: 32)),
                acceptedAt: Date(), completedAt: nil, personID: identity?.personID, deviceID: try identity?.deviceID)
            try secrets.write(GroupWire.encode(record), account: "identity-deletion", createOnly: true)
            return secrets
        }
        let deleted = registered(.firstDevice())
        let same = try accepted(for: deleted)
        try same.write(GroupWire.encode(deleted), account: "identity", createOnly: true)
        try check(try await client(same, relay, folder).identityDeletionNeedingLocalCleanup() != nil, "the deleted identity's keys are removed later")
        try check(try same.read("identity") == nil, "its identity is gone")

        let other = try accepted(for: deleted)
        try other.write(GroupWire.encode(registered(.firstDevice())), account: "identity", createOnly: true)
        try check(try await client(other, relay, folder).identityDeletionNeedingLocalCleanup() == nil, "another person's identity is left alone")
        try check(try other.read("identity") != nil, "and kept")

        let old = try accepted(for: nil)
        try old.write(GroupWire.encode(deleted), account: "identity", createOnly: true)
        try check(try await client(old, relay, folder).identityDeletionNeedingLocalCleanup() == nil, "a record from before 11/20 never removes an identity")

        let linking = try accepted(for: deleted)
        try linking.write(Data("draft".utf8), account: "device-link", createOnly: true)
        try check(try await client(linking, relay, folder).identityDeletionNeedingLocalCleanup() == nil, "a device link in progress is left alone")
        try check(try await relay.deletions == 0, "nothing is sent again")
        print("identity deletion: an interrupted clean-up resumes for the deleted identity only")
    }

    /// FamilySharingLocalData: every notebook copy, recovered device and kept choice.
    static func localDataChecks(_ folder: URL) throws {
        let keychain = Keychain()
        let support = folder.appendingPathComponent("support", isDirectory: true)
        let manager = FileManager.default
        func make(_ url: URL) throws {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: url.appendingPathComponent("file"))
        }
        func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }
        let notebooks = support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true)
        let transport = support.appendingPathComponent("GroupTransport-v3", isDirectory: true)

        // The deleted identity: its notebook copy, whose Keychain is already empty.
        let usual = registered(.firstDevice())
        let usualScope = try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: usual.personID, deviceID: usual.deviceID)
        try make(notebooks.appendingPathComponent(usualScope).appendingPathComponent("notebooks"))
        // An older notebook of this namespace, with its trust pin and epoch key.
        let older = try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: "older", deviceID: "older-device")
        try make(notebooks.appendingPathComponent(older))
        for account in ["op:fnb-trust:x", "op:fnb-key:x:1", "family-photo-visibility.v1:x"] {
            try keychain.store(namespace + ".family." + older).write(Data("k".utf8), account: account, createOnly: true)
        }
        // A recovered device (機種変更) with its own notebook copy and outbox.
        let recovered = registered(.firstDevice())
        let recoveryScope = GroupCanonical.hash(recovered.personPublicKey).map { String(format: "%02x", $0) }.joined()
        try keychain.store(namespace + ".recovery." + recoveryScope).write(GroupWire.encode(recovered), account: "identity", createOnly: true)
        try keychain.store(namespace + ".recovery-journal." + recoveryScope).write(Data("j".utf8), account: "op:x", createOnly: true)
        let recoveredScope = try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: recovered.personID, deviceID: recovered.deviceID)
        try keychain.store(namespace + ".family." + recoveredScope).write(Data("k".utf8), account: "op:fnb-trust:y", createOnly: true)
        try make(notebooks.appendingPathComponent(recoveredScope))
        try make(transport.appendingPathComponent("recovery-" + recoveryScope).appendingPathComponent("outbox"))
        // A journal whose recovery store is already gone.
        let orphan = String(repeating: "a", count: 64)
        try keychain.store(namespace + ".recovery-journal." + orphan).write(Data("j".utf8), account: "op:y", createOnly: true)
        // The kept choices and the recovery link.
        let suffixes = [".notebook-recovery", ".display-name", FamilyHiddenOperationsMemory.namespaceSuffix,
                        FamilyCatLinkAnswersMemory.namespaceSuffix, GroupWindowKept.namespaceSuffix]
        for suffix in suffixes.dropLast() { try keychain.store(namespace + suffix).write(Data("c".utf8), account: "kept", createOnly: true) }
        let windowChoices = keychain.store(namespace + GroupWindowKept.namespaceSuffix)
        try windowChoices.write(Data("c".utf8), account: GroupWindowKept.choicesAccountPrefix + "w", createOnly: true)
        try windowChoices.write(Data("r".utf8), account: "reports:w", createOnly: true)

        // Not this deletion's: the identity's own store, another namespace, the
        // まど's own outbox, the person's own records and an unsafe scope name.
        try keychain.store(namespace).write(Data("d".utf8), account: "identity-deletion", createOnly: true)
        let otherNamespace = "jp.nekowidget.other"
        try keychain.store(otherNamespace + ".family." + older).write(Data("k".utf8), account: "op:fnb-trust:z", createOnly: true)
        try keychain.store(namespace + ".family.../escape").write(Data("k".utf8), account: "x", createOnly: true)
        let mainOutbox = transport.appendingPathComponent("main").appendingPathComponent("outbox")
        try make(mainOutbox)
        let records = support.appendingPathComponent("AppRecords").appendingPathComponent("CatCare")
        try make(records)
        let otherNotebook = try FamilySharingLocalData.notebookScope(endpoint: URL(string: "https://other.invalid")!, personID: "p", deviceID: "d")
        try make(notebooks.appendingPathComponent(otherNotebook))

        let local = FamilySharingLocalData(namespace: namespace, support: support,
            store: { keychain.store($0) }, namespaces: { try keychain.namespaces(prefix: $0) })
        func run() -> Bool {
            local.removeAfterIdentityDeletion(endpoint: endpoint, personID: usual.personID, deviceID: try? usual.deviceID,
                                              choices: suffixes.map { (suffix: $0, prefix: $0 == GroupWindowKept.namespaceSuffix ? GroupWindowKept.choicesAccountPrefix : "") })
        }

        // A Keychain error on one item: the rest still goes, and it says so.
        keychain.store(namespace + ".family." + older).stuck = ["op:fnb-key:x:1"]
        try check(!run(), "a failed step is reported")
        try check(!exists(notebooks.appendingPathComponent(usualScope)) && !exists(notebooks.appendingPathComponent(recoveredScope)),
                  "the other notebook copies went anyway")
        try check(keychain.isEmpty(namespace + ".display-name"), "the kept choices went anyway")
        try check(!keychain.isEmpty(namespace + ".family." + older), "the stuck notebook Keychain is left for the next run")

        // The next run finishes it.
        keychain.store(namespace + ".family." + older).stuck = []
        try check(run(), "the second run finishes")
        for scope in [older, recoveredScope] { try check(keychain.isEmpty(namespace + ".family." + scope), "notebook Keychain \(scope.prefix(6)) is empty") }
        for name in [".recovery." + recoveryScope, ".recovery-journal." + recoveryScope, ".recovery-journal." + orphan] {
            try check(keychain.isEmpty(namespace + name), "\(name.prefix(18)) is empty")
        }
        for suffix in suffixes.dropLast() { try check(keychain.isEmpty(namespace + suffix), "\(suffix) is empty") }
        try check(try windowChoices.accounts(prefix: "") == ["reports:w"], "the まど choices go, the report copy stays")
        try check(!exists(notebooks.appendingPathComponent(older)) && !exists(transport.appendingPathComponent("recovery-" + recoveryScope)),
                  "the notebook folders and the recovered outbox are gone")
        try check(!keychain.isEmpty(namespace) && !keychain.isEmpty(otherNamespace + ".family." + older)
                  && !keychain.isEmpty(namespace + ".family.../escape"), "other namespaces, the deletion record and unsafe names stay")
        try check(exists(mainOutbox) && exists(records) && exists(notebooks.appendingPathComponent(otherNotebook)),
                  "the まど outbox, the person's records and another endpoint's notebook stay")
        try check(run(), "running it again changes nothing")

        // Listing the Keychain fails: reported, nothing else breaks.
        keychain.listingFails = true
        try check(!run(), "an unreadable Keychain list is reported")
        print("identity deletion: every notebook copy, recovered device and kept choice of the namespace, finished on a second run")
    }

    static func main() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("identity-deletion-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try await clientChecks(folder)
            try await interruptedChecks(folder)
            try localDataChecks(folder)
            print("Identity deletion clean-up checks passed")
        } catch {
            print("Identity deletion clean-up checks failed: \(error)")
            exit(1)
        }
    }
}
