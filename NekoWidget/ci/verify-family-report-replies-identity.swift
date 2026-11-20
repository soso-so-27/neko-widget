import CryptoKit
import Foundation

// 11/20 (two-device S5): 「通報への返答」 is read with the identity the family
// notebook uses. A recovered iPhone (機種変更) signs with the recovered device;
// without a recovery link the usual device signs, as before. Synthetic keys
// and a synthetic relay only; no Keychain, network or photo.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws { if !value { throw Failure.check(name) } }

private final class MemorySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }; values[account] = data
    }
    func accounts(prefix: String) throws -> [String] { lock.lock(); defer { lock.unlock() }; return values.keys.filter { $0.hasPrefix(prefix) } }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

/// Answers the reply list only for a registered device; records who signed.
private actor ReplyRelay: GroupHTTPTransport {
    private let registered: Set<String>
    private(set) var signers: [String] = []
    init(registered: Set<String>) { self.registered = registered }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard request.url?.path == "/v3/family-notebooks/report-replies", request.httpMethod == "GET",
              let device = request.value(forHTTPHeaderField: "Neko-Device-Id") else {
            return GroupHTTPReply(status: 404, data: Data(#"{"error":{"code":"not_found"}}"#.utf8))
        }
        signers.append(device)
        guard registered.contains(device) else {
            return GroupHTTPReply(status: 401, data: Data(#"{"error":{"code":"invalid_authentication"}}"#.utf8))
        }
        let receipt = GroupWire.base64(Data(repeating: 3, count: 16))
        return GroupHTTPReply(status: 200, data: Data(#"{"schemaVersion":1,"replies":[{"receiptNumber":"\#(receipt)","receivedAt":1763600000,"status":"photo_stopped"}]}"#.utf8))
    }
}

private func registered(_ identity: GroupDeviceIdentity) -> GroupDeviceIdentity {
    var value = identity; value.registered = true; return value
}

@main
enum FamilyReportRepliesIdentityChecks {
    static func main() async {
        do {
            let endpoint = URL(string: "https://group.invalid")!
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("report-replies-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            // The recovered person's identity, kept under its root's scope.
            let recovered = registered(.firstDevice())
            let recoveredDevice = try recovered.deviceID
            let scope = GroupCanonical.hash(recovered.personPublicKey).map { String(format: "%02x", $0) }.joined()
            let recoveryStore = MemorySecrets()
            try recoveryStore.write(GroupWire.encode(recovered), account: "identity", createOnly: true)
            let links = MemorySecrets()
            try links.write(GroupWire.encode(FamilyNotebookIdentityChoice.Link(version: 1, scope: scope,
                personID: recovered.personID, familyIDs: [UUID()])), account: FamilyNotebookIdentityChoice.linkAccount, createOnly: true)

            // 1. A new iPhone recovered only through the notebook: no usual identity.
            do {
                let relay = ReplyRelay(registered: [recoveredDevice])
                let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: MemorySecrets(), transport: relay,
                    outboxDirectory: folder.appendingPathComponent("recovered"))
                let choice = try FamilyNotebookIdentityChoice.load(links: links, recoveryStore: { try check($0 == scope, "recovery scope"); return recoveryStore },
                    usualPersonID: try await client.existingPersonID(), usualDeviceID: try await client.existingDeviceID())
                try check(choice != nil, "the recovered identity is chosen")
                var failedAsUsual = false
                do { _ = try await client.familyPhotoReportReplies() } catch GroupClientError.authenticationRequired { failedAsUsual = true }
                try check(failedAsUsual, "the usual identity alone cannot read (the S5 finding)")
                let replies = try await client.familyPhotoReportReplies(as: choice)
                try check(replies.map(\.status) == [.photoStopped], "the recovered device reads photo_stopped")
                try await check(relay.signers == [recoveredDevice], "the read is signed by the recovered device")
            }

            // 2. A usual identity left on the iPhone (another person) plus the
            //    recovery link: the recovered device still signs.
            do {
                let usual = registered(.firstDevice()), usualDevice = try usual.deviceID
                let usualStore = MemorySecrets()
                try usualStore.write(GroupWire.encode(usual), account: "identity", createOnly: true)
                let relay = ReplyRelay(registered: [recoveredDevice, usualDevice])
                let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: usualStore, transport: relay,
                    outboxDirectory: folder.appendingPathComponent("both"))
                let choice = try FamilyNotebookIdentityChoice.load(links: links, recoveryStore: { _ in recoveryStore },
                    usualPersonID: try await client.existingPersonID(), usualDeviceID: try await client.existingDeviceID())
                _ = try await client.familyPhotoReportReplies(as: choice)
                try await check(relay.signers == [recoveredDevice], "the recovery link wins over a leftover usual device")
            }

            // 3. No recovery: the usual device signs, unchanged.
            do {
                let usual = registered(.firstDevice()), usualDevice = try usual.deviceID
                let usualStore = MemorySecrets()
                try usualStore.write(GroupWire.encode(usual), account: "identity", createOnly: true)
                let relay = ReplyRelay(registered: [usualDevice])
                let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: usualStore, transport: relay,
                    outboxDirectory: folder.appendingPathComponent("usual"))
                let choice = try FamilyNotebookIdentityChoice.load(links: MemorySecrets(), recoveryStore: { _ in MemorySecrets() },
                    usualPersonID: try await client.existingPersonID(), usualDeviceID: try await client.existingDeviceID())
                try check(choice == nil, "no link keeps the usual identity")
                let replies = try await client.familyPhotoReportReplies(as: choice)
                try check(replies.count == 1, "the usual device reads its replies")
                _ = try await client.familyPhotoReportReplies()
                try await check(relay.signers == [usualDevice, usualDevice], "both reads are signed by the usual device")
            }

            // 5. Without the flag (機種変更, or a reinstall that wiped UserDefaults)
            //    the notebook asks once for replies to reports sent before; never
            //    when the row already shows, the gate is off, or "none" was read
            //    in this launch (11/20: no longer only after 機種変更).
            let read = FamilyReportRepliesDiscovery.shouldRead
            try check(read(false, false, true, true), "no flag: one read")
            try check(!read(true, false, true, true), "the flag set: no extra read")
            try check(!read(false, false, true, false), "the gate off: no read")
            try check(!read(false, false, false, true), "the notebook not loaded: no read")
            try check(!read(false, true, true, true), "none read in this launch: no read")
            var asked = 0
            let found = await FamilyReportRepliesDiscovery.discover(flagSet: false, checkedNone: false, notebookLoaded: true,
                                                                    gateOpen: true) { asked += 1; return true }
            let empty = await FamilyReportRepliesDiscovery.discover(flagSet: false, checkedNone: false, notebookLoaded: true,
                                                                   gateOpen: true) { asked += 1; return false }
            let failed = await FamilyReportRepliesDiscovery.discover(flagSet: false, checkedNone: false, notebookLoaded: true,
                                                                     gateOpen: true) { asked += 1; throw GroupClientError.offline }
            let skipped = await FamilyReportRepliesDiscovery.discover(flagSet: false, checkedNone: true, notebookLoaded: true,
                                                                      gateOpen: true) { asked += 1; return true }
            try check(found == .found && empty == .noReplies && failed == .failed && skipped == .skipped && asked == 3,
                      "a reply sets the flag, none is remembered, a failure asks again, a known answer asks nothing")
            let view = try String(contentsOfFile: "NekoWidget/Views/FamilyNotebookView.swift", encoding: .utf8)
            try check(view.contains("gateOpen: FamilyNotebookServiceFactory.representativePhotoBackend() != nil"),
                      "the view passes the relay's photo gate")
            try check(view.contains("guard model.isReal, model.hasFamily, !askedReportReplies else { return }"),
                      "at most one read per notebook open")
            try check(view.contains("checkedNone: checkedNone, notebookLoaded: notebookLoaded,")
                      && view.contains("case .noReplies: checkedNone = true") && view.contains("case .found: markSent()"),
                      "the view remembers none for the launch and sets the flag on a reply")
            try check(!view.contains("recoveryLinked:"), "the read no longer needs the recovery link")

            // 4. The app's wiring passes the notebook's choice (FamilyNotebookServiceFactory
            //    needs UIKit, so its one line is checked as text).
            let factory = try String(contentsOfFile: "NekoWidget/Services/FamilyNotebookServiceFactory.swift", encoding: .utf8)
            try check(factory.contains("client.familyPhotoReportReplies(as: recoveredIdentity(client))"),
                      "reportReplies reads with the notebook's identity choice")
            print("Family report replies identity checks passed")
        } catch {
            FileHandle.standardError.write(Data("Family report replies identity check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
