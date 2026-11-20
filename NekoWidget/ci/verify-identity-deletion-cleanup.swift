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

final class MemorySecrets: GroupSecretStore, @unchecked Sendable {
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
final class Keychain: @unchecked Sendable {
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
actor DeletionRelay: GroupHTTPTransport {
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

    /// FamilySharingLocalData: only what provably is the deleted person's.
    static func localDataChecks(_ folder: URL) throws {
        let manager = FileManager.default
        func make(_ url: URL) throws {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: url.appendingPathComponent("file"))
        }
        func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }
        let shared: [(suffix: String, prefix: String)] = [(".display-name", ""), (FamilyHiddenOperationsMemory.namespaceSuffix, ""),
            (FamilyCatLinkAnswersMemory.namespaceSuffix, ""), (GroupWindowKept.namespaceSuffix, GroupWindowKept.choicesAccountPrefix)]

        /// One iPhone: the usual identity `usual`, the same person's recovered
        /// device, optionally another person's recovered device and the link.
        struct Phone {
            let keychain = Keychain()
            let support: URL
            let usual: GroupDeviceIdentity
            let ownRecovered: GroupDeviceIdentity
            let other: GroupDeviceIdentity
            var local: FamilySharingLocalData {
                let keychain = self.keychain
                return FamilySharingLocalData(namespace: IdentityDeletionCleanupChecks.namespace, support: support,
                    store: { keychain.store($0) }, namespaces: { try keychain.namespaces(prefix: $0) })
            }
            func notebook(_ scope: String) -> URL {
                support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
            }
            func outbox(_ scope: String) -> URL {
                support.appendingPathComponent("GroupTransport-v3", isDirectory: true).appendingPathComponent("recovery-" + scope, isDirectory: true)
            }
        }
        func phone(_ name: String, other: Bool, linkOther: Bool = false) throws -> Phone {
            let usual = registered(.firstDevice())
            // The same person's recovered device: another device key, the same person key.
            var ownRecovered = registered(.firstDevice())
            ownRecovered = GroupDeviceIdentity(personPrivateKey: usual.personPrivateKey, personPublicKey: usual.personPublicKey,
                signingPrivateKey: ownRecovered.signingPrivateKey, agreementPrivateKey: ownRecovered.agreementPrivateKey,
                windowCertificates: [:], registered: true)
            let value = Phone(support: folder.appendingPathComponent(name, isDirectory: true), usual: usual,
                              ownRecovered: ownRecovered, other: registered(.firstDevice()))
            var people = [ownRecovered]
            if other { people.append(value.other) }
            for identity in [usual] + people {
                let scope = try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: identity.personID, deviceID: identity.deviceID)
                try make(value.notebook(scope).appendingPathComponent("notebooks"))
                for account in ["op:fnb-trust:x", "op:fnb-key:x:1"] {
                    try value.keychain.store(namespace + ".family." + scope).write(Data("k".utf8), account: account, createOnly: true)
                }
            }
            for identity in people {
                let scope = FamilySharingLocalData.recoveryScope(personID: identity.personID)!
                try value.keychain.store(namespace + ".recovery." + scope).write(GroupWire.encode(identity), account: "identity", createOnly: true)
                try value.keychain.store(namespace + ".recovery-journal." + scope).write(Data("j".utf8), account: "op:x", createOnly: true)
                try make(value.outbox(scope))
            }
            if linkOther {
                let linked = value.other
                let link = FamilyNotebookIdentityChoice.Link(version: 1, scope: FamilySharingLocalData.recoveryScope(personID: linked.personID)!,
                                                             personID: linked.personID, familyIDs: [UUID()])
                try value.keychain.store(namespace + ".notebook-recovery").write(GroupWire.encode(link),
                    account: FamilyNotebookIdentityChoice.linkAccount, createOnly: true)
            }
            for choice in shared.dropLast() {
                try value.keychain.store(namespace + choice.suffix).write(Data("c".utf8), account: "kept", createOnly: true)
            }
            let windowChoices = value.keychain.store(namespace + GroupWindowKept.namespaceSuffix)
            try windowChoices.write(Data("c".utf8), account: GroupWindowKept.choicesAccountPrefix + "w", createOnly: true)
            try windowChoices.write(Data("r".utf8), account: "reports:w", createOnly: true)
            // A notebook copy nobody can be named for, the person's own records, another namespace.
            let unknown = try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: "older", deviceID: "older-device")
            try make(value.notebook(unknown))
            try value.keychain.store(namespace + ".family." + unknown).write(Data("k".utf8), account: "op:fnb-trust:z", createOnly: true)
            try make(value.support.appendingPathComponent("AppRecords").appendingPathComponent("CatCare"))
            try value.keychain.store("jp.nekowidget.other.recovery." + String(repeating: "b", count: 64)).write(Data("i".utf8), account: "identity", createOnly: true)
            return value
        }
        func scope(_ identity: GroupDeviceIdentity) throws -> String {
            try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: identity.personID, deviceID: identity.deviceID)
        }
        func gone(_ p: Phone, _ identity: GroupDeviceIdentity) throws -> Bool {
            let notebook = try scope(identity)
            return !exists(p.notebook(notebook)) && p.keychain.isEmpty(namespace + ".family." + notebook)
        }
        func stays(_ p: Phone, _ identity: GroupDeviceIdentity) throws -> Bool {
            let notebook = try scope(identity)
            return exists(p.notebook(notebook)) && !p.keychain.isEmpty(namespace + ".family." + notebook)
        }
        func untouchedCommon(_ p: Phone) throws {
            let unknown = try FamilySharingLocalData.notebookScope(endpoint: endpoint, personID: "older", deviceID: "older-device")
            try check(exists(p.notebook(unknown)) && !p.keychain.isEmpty(namespace + ".family." + unknown), "a notebook copy nobody can be named for stays")
            try check(exists(p.support.appendingPathComponent("AppRecords").appendingPathComponent("CatCare")), "the person's own records stay")
            try check(!p.keychain.isEmpty("jp.nekowidget.other.recovery." + String(repeating: "b", count: 64)), "another namespace stays")
            try check(try p.keychain.store(namespace + GroupWindowKept.namespaceSuffix).accounts(prefix: "reports:") == ["reports:w"], "the report copy stays")
        }

        // 1. Another person's recovered device is in use (the link names it):
        //    only the deleted person's copies go; the other's and the shared ones stay.
        do {
            let p = try phone("with-other", other: true, linkOther: true)
            let ownScope = FamilySharingLocalData.recoveryScope(personID: p.usual.personID)!
            let otherScope = FamilySharingLocalData.recoveryScope(personID: p.other.personID)!
            let outcome = p.local.removeAfterIdentityDeletion(endpoint: endpoint, personID: p.usual.personID,
                deviceID: try p.usual.deviceID, linkSuffix: ".notebook-recovery")
            try check(outcome == .init(complete: true, otherIdentityRemains: true), "done, and another identity remains")
            try check(try gone(p, p.usual) && gone(p, p.ownRecovered), "the deleted person's notebook copies go")
            try check(p.keychain.isEmpty(namespace + ".recovery." + ownScope) && p.keychain.isEmpty(namespace + ".recovery-journal." + ownScope)
                      && !exists(p.outbox(ownScope)), "the deleted person's recovered device goes")
            try check(try stays(p, p.other), "the other person's notebook copy stays")
            try check(!p.keychain.isEmpty(namespace + ".recovery." + otherScope) && !p.keychain.isEmpty(namespace + ".recovery-journal." + otherScope)
                      && exists(p.outbox(otherScope)), "the other person's recovered device stays")
            try check(!p.keychain.isEmpty(namespace + ".notebook-recovery"), "the link naming the other person stays")
            for choice in shared.dropLast() { try check(!p.keychain.isEmpty(namespace + choice.suffix), "\(choice.suffix) stays (not removed here)") }
            try untouchedCommon(p)
        }

        // 2. Only the deleted person on this iPhone: its link goes, no other
        //    identity remains, and the shared copies (but the reports) go.
        do {
            let p = try phone("alone", other: false)
            let linked = p.ownRecovered
            let link = FamilyNotebookIdentityChoice.Link(version: 1, scope: FamilySharingLocalData.recoveryScope(personID: linked.personID)!,
                                                         personID: linked.personID, familyIDs: [UUID()])
            try p.keychain.store(namespace + ".notebook-recovery").write(GroupWire.encode(link), account: FamilyNotebookIdentityChoice.linkAccount, createOnly: true)
            // A Keychain error on one item: the rest still goes, and it says so.
            p.keychain.store(namespace + ".family." + (try scope(p.usual))).stuck = ["op:fnb-key:x:1"]
            var outcome = p.local.removeAfterIdentityDeletion(endpoint: endpoint, personID: p.usual.personID,
                deviceID: try p.usual.deviceID, linkSuffix: ".notebook-recovery")
            try check(!outcome.complete && !outcome.otherIdentityRemains, "a failed step is reported; no other identity")
            try check(try gone(p, p.ownRecovered) && p.keychain.isEmpty(namespace + ".notebook-recovery"), "the rest went anyway")
            p.keychain.store(namespace + ".family." + (try scope(p.usual))).stuck = []
            outcome = p.local.removeAfterIdentityDeletion(endpoint: endpoint, personID: p.usual.personID,
                deviceID: try p.usual.deviceID, linkSuffix: ".notebook-recovery")
            try check(outcome == .init(complete: true, otherIdentityRemains: false), "the second run finishes")
            try check(try gone(p, p.usual), "the deleted person's notebook copy is gone")
            try check(p.local.removeSharedCopies(shared), "the shared copies go")
            for choice in shared.dropLast() { try check(p.keychain.isEmpty(namespace + choice.suffix), "\(choice.suffix) is empty") }
            try untouchedCommon(p)
            // Listing the Keychain fails: reported, and nothing shared is offered for removal.
            p.keychain.listingFails = true
            outcome = p.local.removeAfterIdentityDeletion(endpoint: endpoint, personID: p.usual.personID,
                deviceID: try p.usual.deviceID, linkSuffix: ".notebook-recovery")
            try check(!outcome.complete && outcome.otherIdentityRemains, "an unreadable Keychain list is reported and keeps the shared copies")
        }

        // 3. A record from before 11/20 (no person): nothing is touched.
        do {
            let p = try phone("old-record", other: true, linkOther: true)
            let outcome = p.local.removeAfterIdentityDeletion(endpoint: endpoint, personID: nil, deviceID: nil, linkSuffix: ".notebook-recovery")
            try check(outcome == .init(complete: true, otherIdentityRemains: true), "nothing to do, shared copies kept")
            try check(try stays(p, p.usual) && stays(p, p.ownRecovered) && stays(p, p.other), "every notebook copy stays")
            for identity in [p.ownRecovered, p.other] {
                try check(!p.keychain.isEmpty(namespace + ".recovery." + FamilySharingLocalData.recoveryScope(personID: identity.personID)!),
                          "every recovered device stays")
            }
            try untouchedCommon(p)
        }
        print("identity deletion: only the deleted person's recovered device, link and notebook copies; another person's and unknown ones stay")
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
