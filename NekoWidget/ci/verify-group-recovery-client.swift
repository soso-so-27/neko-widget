import Foundation
import CryptoKit
private enum TestFailure: Error { case failed }
private func check(_ value: Bool) throws { if !value { throw TestFailure.failed } }
private final class RecoverySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw TestFailure.failed }; values[account] = data
    }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}
private actor Relay: GroupHTTPTransport {
    enum Mode { case normal, wrongEnvironment, ready, offline }
    var mode: Mode = .normal
    var challenges: [String: [String: Any]] = [:]
    var operations: [String] = []
    var proof: [String: Any]?
    var freshHashes: [String] = []
    var loseFreshReply = false
    func loseNextFreshReply() { loseFreshReply = true }
    func freshCount() -> Int { freshHashes.count }
    func installProof(_ bytes: Data) throws { proof = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] }
    func set(_ mode: Mode) { self.mode = mode }
    func seen() -> [String] { operations }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        if mode == .offline { throw TestFailure.failed }
        let b = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let path = request.url!.path, now = Int(Date().timeIntervalSince1970)
        func reply(_ fields: [String: Any], status: Int = 200) throws -> GroupHTTPReply {
            GroupHTTPReply(status: status, data: try JSONSerialization.data(withJSONObject: fields))
        }
        if path.hasSuffix("/challenges") {
            let id = UUID().uuidString.lowercased(), key = b["identityPublicKey"] as! String
            let c: [String: Any] = ["id": id, "person_id": GroupWire.base64(GroupCanonical.hash(try GroupWire.bytes(key, count: 32))),
                "identity_public_key": key, "operation_id": b["operationId"]!, "purpose": b["purpose"]!,
                "environment": mode == .wrongEnvironment ? "production" : "staging",
                "nonce": GroupWire.base64(Data(repeating: 11, count: 32)), "issued_at": now, "expires_at": now + 300, "consumed_at": NSNull()]
            challenges[id] = c
            return try reply(["challenge": c], status: 201)
        }
        let c = challenges.removeValue(forKey: b["challengeId"] as! String)!
        let person = c["person_id"] as! String
        let transcript = try GroupCanonical.fields(["NW3.RECOVERY.CATALOG.V1", "staging", c["purpose"] as! String,
            c["id"] as! String, person].map(GroupCanonical.text) + [GroupWire.bytes(c["identity_public_key"] as! String),
                GroupCanonical.text(c["operation_id"] as! String), GroupWire.bytes(c["nonce"] as! String),
                GroupCanonical.text(String(c["issued_at"] as! Int)), GroupCanonical.text(String(c["expires_at"] as! Int))])
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: GroupWire.bytes(c["identity_public_key"] as! String))
        if path.hasSuffix("/devices/remove") {
            let device = b["deviceId"] as! String
            let bytes = try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.REMOVE-DEVICE.V1"), transcript, GroupWire.bytes(device, count: 32)])
            try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: bytes))
            return try reply(["personId": person, "operationId": c["operation_id"]!, "deviceId": device, "state": "revoked"])
        }
        if path.hasSuffix("/fresh") {
            let packet = try GroupWire.decode(SignedGroupRoster.self, JSONSerialization.data(withJSONObject: b["packet"]!))
            let hash = GroupWire.base64(try GroupCanonical.hash(packet.roster.canonicalBytes()))
            if let first = freshHashes.first { try check(first == hash) }
            freshHashes.append(hash)
            if freshHashes.count == 1 {
                print("RECOVERY_FRESH_WIRE=" + String(data: try JSONSerialization.data(withJSONObject: ["body": b, "challenge": c]), encoding: .utf8)!)
            }
            if loseFreshReply { loseFreshReply = false; throw TestFailure.failed }
            return try reply(["personId": person, "operationId": c["operation_id"]!, "windowId": packet.roster.windowID,
                "deviceId": packet.signerDeviceID, "revision": packet.roster.revision, "rosterHash": hash, "state": "freshGenerationCommitted"])
        }
        if path.hasSuffix("/catalog") {
            try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: transcript))
            return try reply(["personId": person, "windows": [], "notebooks": [], "devices": [], "windowCount": 0, "notebookCount": 0, "serverNow": now])
        }
        let registering = !path.hasSuffix("/status"), window = b["windowId"] as! String
        let intent = registering ? try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.PENDING.INTENT.V1"), GroupCanonical.text(window),
            GroupWire.bytes(b["signingPublicKey"] as! String), GroupWire.bytes(b["hpkePublicKey"] as! String), GroupCanonical.text(b["model"] as! String)]) : Data()
        func message(_ who: String) throws -> Data {
            try GroupCanonical.fields([GroupCanonical.text(registering ? "NW3.RECOVERY.PENDING.REGISTER.V1" : "NW3.RECOVERY.PENDING.STATUS.V1"), GroupCanonical.text(who), transcript, GroupCanonical.text(window), intent])
        }
        try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: message("root")))
        if registering {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: GroupWire.bytes(b["signingPublicKey"] as! String))
            try check(key.isValidSignature(GroupWire.bytes(b["deviceSignature"] as! String), for: message("device")))
        }
        operations.append(c["operation_id"] as! String)
        if mode == .normal, var proof {
            proof["operationId"] = c["operation_id"]!; proof["personId"] = person; proof["windowId"] = window
            return try reply(proof)
        }
        return try reply(["operationId": c["operation_id"]!, "personId": person, "windowId": window,
            "state": mode == .ready ? "ready" : "needsOriginalDeviceOrInvitation", "canOpen": mode == .ready,
            "canSend": mode == .ready, "exists": true])
    }
}
@main enum VerifyRecoveryClient {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try GroupOperationStore(directory: directory), relay = Relay(), secrets = RecoverySecrets()
        let root = Curve25519.Signing.PrivateKey(), device = Curve25519.Signing.PrivateKey(), hpke = Curve25519.KeyAgreement.PrivateKey()
        func client(_ enabled: Bool = true) throws -> GroupRecoveryClient {
            try GroupRecoveryClient(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging", root: root.rawRepresentation,
                transport: relay, journal: journal, secrets: secrets, enabled: enabled)
        }
        let c = try client(), window = GroupWire.randomID()
        let draft = try await c.prepare(windowID: window, signingPublicKey: device.publicKey.rawRepresentation, hpkePublicKey: hpke.publicKey.rawRepresentation, model: "iPhone")
        let reopened = try client()
        let same = try await reopened.prepare(windowID: window, signingPublicKey: device.publicKey.rawRepresentation, hpkePublicKey: hpke.publicKey.rawRepresentation, model: "iPhone")
        try check(same == draft)
        let catalog = try await c.catalog(); try check(catalog.windowCount == 0)
        let registration = try await c.register(draft, signingKey: device.rawRepresentation)
        try check(registration.state == .needsOriginalDeviceOrInvitation(operationID: draft.operationID))
        _ = try await reopened.status(draft)
        let seen = await relay.seen(); try check(seen == Array(repeating: draft.operationID.uuidString.lowercased(), count: 2))
        let ownerDevice = Curve25519.Signing.PrivateKey(), ownerHPKE = Curve25519.KeyAgreement.PrivateKey()
        let person = GroupWire.base64(GroupCanonical.hash(root.publicKey.rawRepresentation))
        let ownerID = GroupWire.base64(try GroupCanonical.hash(GroupCanonical.fields([ownerDevice.publicKey.rawRepresentation, ownerHPKE.publicKey.rawRepresentation])))
        let unsigned = GroupRosterDevice(id: ownerID, signingPublicKey: ownerDevice.publicKey.rawRepresentation,
            hpkePublicKey: ownerHPKE.publicKey.rawRepresentation, personAuthorization: Data())
        let authorized = GroupRosterDevice(id: ownerID, signingPublicKey: unsigned.signingPublicKey, hpkePublicKey: unsigned.hpkePublicKey,
            personAuthorization: try root.signature(for: unsigned.authorizationBytes(windowID: window, personID: person)))
        let roster = GroupRoster(windowID: window, revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32),
            ownerPersonID: person, members: [.init(participantID: GroupWire.randomID(), personID: person,
                identityPublicKey: root.publicKey.rawRepresentation, role: .owner, devices: [authorized])])
        let packet = try GroupRosterVerifier.sign(roster, deviceID: ownerID, privateKey: ownerDevice)
        let anchor = try GroupAnchorReceipt.make(environment: "staging", anchor: .init(windowID: window, ownerPersonID: person,
            ownerIdentityPublicKey: root.publicKey.rawRepresentation), root: root)
        let pendingID = GroupWire.base64(try GroupCanonical.hash(GroupCanonical.fields([device.publicKey.rawRepresentation, hpke.publicKey.rawRepresentation])))
        var proof: [String: Any] = ["state": "registeredWaitingForKeys", "exists": true, "canOpen": false, "canSend": false,
            "deviceId": pendingID, "model": "iPhone", "registeredAt": Int(Date().timeIntervalSince1970),
            "canRequestFreshGeneration": false, "revision": 1, "rosterHash": GroupWire.base64(try GroupCanonical.hash(roster.canonicalBytes())),
            "roster": try JSONSerialization.jsonObject(with: GroupWire.encode(packet)),
            "anchorReceipt": ["environment": "staging", "personId": person, "windowId": window, "ownerPersonId": person,
                "ownerPublicKey": GroupWire.base64(root.publicKey.rawRepresentation), "rootSignature": GroupWire.base64(anchor.rootSignature)]]
        try await relay.installProof(JSONSerialization.data(withJSONObject: proof))
        let waiting = try await c.status(draft)
        try check(waiting.state == .registeredWaitingForKeys(operationID: draft.operationID, deviceID: pendingID))
        try check(!waiting.state.canOpen && !waiting.state.canSend && waiting.model == "iPhone")
        let identity = GroupDeviceIdentity(personPrivateKey: root.rawRepresentation, personPublicKey: root.publicKey.rawRepresentation,
            signingPrivateKey: device.rawRepresentation, agreementPrivateKey: hpke.rawRepresentation, windowCertificates: [:], registered: false)
        proof["state"] = "noKeyProvider"; proof["canRequestFreshGeneration"] = true
        try await relay.installProof(JSONSerialization.data(withJSONObject: proof))
        await relay.loseNextFreshReply()
        do { _ = try await c.freshGeneration(draft, identity: identity, newName: "新しいまど"); throw GroupRecoveryClient.Failure.invalidResponse } catch is TestFailure {}
        try check(secrets.read("window:" + window) == nil)
        let resumed = try await reopened.resumeFreshGeneration(draft, identity: identity)
        try check(resumed?.state == .ready(operationID: draft.operationID, deviceID: pendingID))
        let installed = try GroupWire.decode(GroupLocalWindow.self, secrets.read("window:" + window)!)
        try check(installed.pinnedRevision == 2 && installed.keys.count == 1 && installed.keys["1"] == nil)
        try check(await relay.freshCount() == 2)
        try await c.removeDevice(ownerID, operationID: UUID())
        proof["rosterHash"] = GroupWire.base64(Data(repeating: 0, count: 32))
        try await relay.installProof(JSONSerialization.data(withJSONObject: proof))
        do { _ = try await c.status(draft); throw TestFailure.failed } catch is GroupRecoveryProofError {}
        await relay.set(.ready)
        do { _ = try await c.status(draft); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {} 
        await relay.set(.wrongEnvironment)
        do { _ = try await c.catalog(); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {}
        await relay.set(.normal)
        do { _ = try await client(false).catalog(); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {}
        await relay.set(.offline)
        do { _ = try await c.catalog(); throw GroupRecoveryClient.Failure.invalidResponse } catch is TestFailure {}
        print("recovery client: PASS (stable journal, root/device signatures, environment, no unverified ready, OFF, offline)")
        try await verifyRecoveryAdapter()
    }
}

private actor DelayedRecovery: GroupRecoverySession {
    let operation: UUID
    let delay: Duration
    init(_ operation: UUID, _ delay: Duration) { self.operation = operation; self.delay = delay }
    func catalog() async throws -> GroupRecoveryClient.Catalog { throw TestFailure.failed }
    func remove(_ device: String, operationID: UUID) async throws {}
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState {
        // Deliberately ignores cancellation like a delayed network callback.
        await withCheckedContinuation { continuation in
            Task { try? await Task.sleep(for: delay); continuation.resume() }
        }
        return .registeredWaitingForKeys(operationID: operation, deviceID: "synthetic")
    }
}
@MainActor private func verifyRecoveryAdapter() async throws {
    let a = UUID(), b = UUID()
    func context(_ root: String, _ id: UUID) -> GroupRecoveryAdapter.Context {
        .init(candidate: .init(summary: .init(rootID: root, windowIDs: [root], notebookIDs: []), openableWindowNames: []),
            session: DelayedRecovery(id, .milliseconds(150)), items: [.init(windowID: root, name: nil, state: .notStarted(operationID: id))])
    }
    let model = GroupRecoveryAdapter(contexts: [context("a", a), context("b", b)], timeout: .milliseconds(30))
    await model.handle(.chooseRoot("a")); await model.handle(.perform(.submitSameOperation(a)))
    try await Task.sleep(for: .milliseconds(60))
    try check(model.items[0].state == .unavailable(operationID: a))
    try await Task.sleep(for: .milliseconds(160))
    try check(model.items[0].state == .unavailable(operationID: a))
    await model.handle(.perform(.queryStatus(a))); await model.handle(.chooseRoot("b"))
    try await Task.sleep(for: .milliseconds(200))
    try check(model.selectedRootID == "b" && model.items[0].state == .notStarted(operationID: b))
    await model.handle(.chooseRoot("absent")); try check(model.selectedRootID == "b")
    await model.handle(.dismiss); try check(model.dismissed)
    print("recovery adapter: PASS (timeout, late completion, root switch, unknown root, dismissal)")
}
